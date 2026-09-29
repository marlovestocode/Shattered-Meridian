--!strict
--[[
	LiveConsoleClient.lua

	Owns: the local admin's Live Admin Console UX -- binding F5 (OpenDevConsole, resolved through
	Client/Input/KeybindManager.lua, same as DevMenuClient.lua's own DevMenuToggle) to the panel's
	IsOpen, calling LiveConsole_Subscribe/Unsubscribe as the panel opens/closes, and appending
	LiveConsole_Stream batches into handle.ServerEntries. Also feeds handle.ClientEntries entirely
	locally -- this client's own require of Shared/Logger.lua already holds this client's own
	capture buffer (Logger.GetBufferSnapshot/OnEntry), so the "My Client" tab needs no remote at
	all.

	setOpen (below) is the ONE place IsOpen is ever written client-side -- the keybind toggle and
	the screen's own "X" button (which fires handle.CloseRequested instead of writing IsOpen
	directly) both route through it -- same precedent Client/DevTools/MoveEditor/MoveEditorClient.lua's own
	setOpen keeps, needed here because Subscribe/Unsubscribe must stay in lockstep with EVERY
	open/close transition, not just the keybind-driven one.

	Unlike DevMenuClient.lua/MoveEditorClient.lua, this module does NOT gate whether to bind its
	input on a boot-time authorization round trip -- opening an empty panel pre-authorization is
	harmless, and the real gate is server-side on Subscribe, fired only once the panel actually
	opens. See LiveConsoleSystem.lua's own header for why deferring it to open-time, not boot-time,
	matters here specifically: an eager boot-time snapshot would already be stale by the time most
	admins actually open the panel.

	THE PANEL ITSELF IS MOUNTED ON FIRST OPEN, not at boot -- Start() is handed a Shared/Lazy.lua
	thunk rather than a mounted handle (Client/UI/init.lua's own header for why all three admin
	screens moved off the boot path). This module is the interesting one of the three, because it is
	the one that binds input for EVERY player rather than only for an authorized admin, so "when does
	the panel come into existence" had to be answered rather than inherited from a gate that already
	existed. The answer is the open-time gate that was already here: the first setOpen(true) forces
	the mount, and everything that can reach this module before that point is written to work without
	a panel. Concretely -- the Stream listener DROPS a batch that arrives for an unmounted panel (only
	possible for a stale in-flight push, since Subscribe is what starts a stream and Subscribe only
	fires on open), the local Logger feed was already gated to the open state, and open/closed is
	tracked in this module's own `isOpen` rather than read back out of the handle, so the toggle can
	ask "am I open" without a panel existing to answer.

	Does not own: whether a Subscribe request is actually allowed (LiveConsoleSystem.lua re-checks
	server-side regardless), capture (Shared/Logger.lua), or the panel itself (Client/UI/Screens/
	LiveConsole/init.lua) -- this module only drives that screen's handle from outside, the same
	"screen exposes state, client module drives it" pattern DevMenuClient.lua/MoveEditorClient.lua
	already use.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local LiveConsoleModule = require(script.Parent.Parent.Parent.UI.Screens.DevTools.LiveConsole)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local Chrome = require(script.Parent.Parent.Parent.UI.Shell.Chrome)
local RemoteInvoker = require(script.Parent.Parent.Parent.Network.RemoteInvoker)

type LiveConsoleHandle = LiveConsoleModule.LiveConsoleHandle

local peek = Fusion.peek

local logger = Logger.scope("LiveConsoleClient")

local Config = Constants.LiveConsole

local LiveConsoleClient = {}

-- Trims `entries` down to the newest Constants.LiveConsole.ClientRenderCap, oldest dropped --
-- shared by the Subscribe snapshot, every Stream batch, and the local "My Client" feed below, so
-- none of the three can grow this handle's rendered lists unbounded over a long-open session.
local function capped(entries: { Logger.LogEntry }): { Logger.LogEntry }
	local overflow = #entries - Config.ClientRenderCap
	if overflow <= 0 then
		return entries
	end
	local trimmed = table.create(Config.ClientRenderCap)
	for index = overflow + 1, #entries do
		table.insert(trimmed, entries[index])
	end
	return trimmed
end

local function appendEntries(target: Fusion.Value<{ Logger.LogEntry }>, newEntries: { Logger.LogEntry }): ()
	local merged = table.clone(peek(target))
	for _, entry in ipairs(newEntries) do
		table.insert(merged, entry)
	end
	target:set(capped(merged))
end

-- This VM's own Logger buffer keeps capturing regardless of panel state, so there is nothing lost
-- by only mirroring it into ClientEntries while the panel is open -- GetBufferSnapshot() below
-- backfills whatever was captured while closed. Registering Logger.OnEntry unconditionally at
-- Start() would mean every logger:info/debug/etc call anywhere on the client -- for every player,
-- open panel or not -- pays appendEntries' clone-and-copy cost forever; gating it to open/close
-- (called from setOpen below) removes that tax entirely for the common case of the panel being
-- closed.
local clientFeedDisconnect: (() -> ())? = nil

local function startLocalClientFeed(handle: LiveConsoleHandle): ()
	handle.ClientEntries:set(capped(Logger.GetBufferSnapshot()))
	clientFeedDisconnect = Logger.OnEntry(function(entry: Logger.LogEntry)
		appendEntries(handle.ClientEntries, { entry })
	end)
end

local function stopLocalClientFeed(): ()
	if clientFeedDisconnect then
		clientFeedDisconnect()
		clientFeedDisconnect = nil
	end
end

local function subscribe(handle: LiveConsoleHandle): ()
	local subscribeRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.Subscribe)
	-- Annotated on the local rather than cast inside the invoke, which is where the cast used to sit:
	-- RemoteInvoker.Invoke is generic over its result pack, so the shape is declared once here instead.
	local ok, result: Types.LiveConsoleSubscribeResult = RemoteInvoker.Invoke(subscribeRemote)
	if not ok then
		logger:warn("Subscribe invoke failed", { errorMessage = tostring(result) })
		handle.StatusText:set("Failed to reach the server.")
		return
	end

	if not result.Success then
		logger:debug("Subscribe rejected", { reason = result.Reason })
		handle.StatusText:set(
			if result.Reason == "NotAuthorized" then "Not authorized." else "Failed: " .. (result.Reason or "Unknown")
		)
		return
	end

	handle.StatusText:set("")
	handle.ServerEntries:set(capped(result.Snapshot or {}))
end

local function unsubscribe(): ()
	local unsubscribeRemote = NetworkBridge.GetRemoteEvent(Config.RemoteNames.Unsubscribe)
	unsubscribeRemote:FireServer()
end

function LiveConsoleClient.Start(deferredHandle: Lazy.Lazy<LiveConsoleHandle>, chrome: Chrome.ChromeHandle): ()
	-- This module's own copy of the open state, rather than peek(handle.IsOpen). The handle does not
	-- exist until the first open, so the toggle below cannot read the current state out of a panel --
	-- and once the panel does exist, setOpen is still the only writer of both, so the two can never
	-- disagree. See this file's header.
	local isOpen = false
	-- Set the first time the panel is forced. Kept alongside the Lazy rather than reading its own
	-- IsResolved(), because what this file needs to branch on is "mounted AND wired up by this
	-- module", which is a strictly later moment than "built".
	local mounted: LiveConsoleHandle? = nil
	-- Forward-declared: ensureMounted below connects CloseRequested, which calls back into setOpen.
	local setOpen: (open: boolean) -> ()

	-- Mounts the panel and connects the one signal that belongs to the panel rather than to this
	-- module. Idempotent by the same guard twice over: Lazy.Get() builds at most once, and the
	-- connection below sits in the same one-shot branch, so a second open never doubles it.
	local function ensureMounted(): LiveConsoleHandle
		local existing = mounted
		if existing then
			return existing
		end
		local handle = deferredHandle.Get()
		mounted = handle
		handle.CloseRequested.Event:Connect(function()
			setOpen(false)
		end)
		-- ADOPTED: F5 was the only way out of this panel. Bound HERE rather than in Start, because
		-- until this moment there is no handle.IsOpen to bind to -- and that costs nothing, because
		-- an unmounted console cannot be open, so there is no window in which Escape should have done
		-- something and did not. handle.IsOpen is still false at this point (setOpen writes it just
		-- after this returns), so the bind's initial sync pushes nothing and the Observer catches the
		-- open edge that follows.
		chrome:BindEscape("LiveConsole", handle.IsOpen, function()
			setOpen(false)
			logger:debug("Live Admin Console closed on Escape")
		end)
		return handle
	end

	local streamRemote = NetworkBridge.GetRemoteEvent(Config.RemoteNames.Stream)
	streamRemote.OnClientEvent:Connect(function(batch: { Logger.LogEntry })
		-- DROPPED, not mounted-to-receive. A batch can only reach a client that Subscribed, and
		-- Subscribe only fires on open, so the sole way to land here unmounted is a push already in
		-- flight when the panel closed -- and mounting a whole panel to append a stale batch nobody is
		-- looking at would invert the entire point of deferring it.
		local handle = mounted
		if not handle then
			return
		end
		appendEntries(handle.ServerEntries, batch)
	end)

	-- See file header -- the ONE place IsOpen is ever written client-side.
	function setOpen(open: boolean): ()
		if open then
			local handle = ensureMounted()
			isOpen = true
			handle.IsOpen:set(true)
			startLocalClientFeed(handle)
			-- Spawned: Subscribe is a yielding RemoteFunction call, and this must never block the
			-- InputBegan connection below (or handle.CloseRequested's) from handling the next event.
			task.spawn(subscribe, handle)
			return
		end

		isOpen = false
		-- A close before the panel has ever been opened has nothing to tear down and nothing to
		-- unsubscribe from -- and must not mount a panel in order to say so.
		local handle = mounted
		if not handle then
			return
		end
		handle.IsOpen:set(false)
		stopLocalClientFeed()
		unsubscribe()
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("OpenDevConsole", input) then
			local nowOpen = not isOpen
			setOpen(nowOpen)
			logger:debug("Live Admin Console toggled", { open = nowOpen })
		end
	end)

	logger:info("LiveConsoleClient started")
end

return LiveConsoleClient
