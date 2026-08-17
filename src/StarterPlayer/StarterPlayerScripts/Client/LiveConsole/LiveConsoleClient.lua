--!strict
--[[
	LiveConsoleClient.lua

	Owns: the local admin's Live Admin Console UX -- binding F7 (OpenDevConsole, resolved through
	Client/Input/KeybindManager.lua, same as DevMenuClient.lua's own DevMenuToggle) to the panel's
	IsOpen, calling LiveConsole_Subscribe/Unsubscribe as the panel opens/closes, and appending
	LiveConsole_Stream batches into handle.ServerEntries. Also feeds handle.ClientEntries entirely
	locally -- this client's own require of Shared/Logger.lua already holds this client's own
	capture buffer (Logger.GetBufferSnapshot/OnEntry), so the "My Client" tab needs no remote at
	all.

	setOpen (below) is the ONE place IsOpen is ever written client-side -- the keybind toggle and
	the screen's own "X" button (which fires handle.CloseRequested instead of writing IsOpen
	directly) both route through it -- same precedent Client/MoveEditor/MoveEditorClient.lua's own
	setOpen establishes, needed here because Subscribe/Unsubscribe must stay in lockstep with EVERY
	open/close transition, not just the keybind-driven one.

	Unlike DevMenuClient.lua/MoveEditorClient.lua, this module does NOT gate whether to bind its
	input on a boot-time authorization round trip -- opening an empty panel pre-authorization is
	harmless, and the real gate is server-side on Subscribe, fired only once the panel actually
	opens. See LiveConsoleSystem.lua's own header for why deferring it to open-time, not boot-time,
	matters here specifically: an eager boot-time snapshot would already be stale by the time most
	admins actually open the panel.

	Does not own: whether a Subscribe request is actually allowed (LiveConsoleSystem.lua re-checks
	server-side regardless), capture (Shared/Logger.lua), or the panel itself (Client/UI/Screens/
	LiveConsole/init.lua) -- this module only drives that screen's handle from outside, the same
	"screen exposes state, client module drives it" pattern DevMenuClient.lua/MoveEditorClient.lua
	already use.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local LiveConsoleModule = require(script.Parent.Parent.UI.Screens.LiveConsole)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

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

-- Registered once at Start() regardless of whether the panel is open -- this VM's own Logger
-- buffer keeps capturing either way, so there is nothing to subscribe/unsubscribe from for this
-- tab; it simply mirrors what Logger.lua already holds.
local function startLocalClientFeed(handle: LiveConsoleHandle): ()
	handle.ClientEntries:set(capped(Logger.GetBufferSnapshot()))
	Logger.OnEntry(function(entry: Logger.LogEntry)
		appendEntries(handle.ClientEntries, { entry })
	end)
end

local function subscribe(handle: LiveConsoleHandle): ()
	local subscribeRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.Subscribe)
	local ok, result = pcall(function()
		return subscribeRemote:InvokeServer() :: Types.LiveConsoleSubscribeResult
	end)
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

function LiveConsoleClient.Start(handle: LiveConsoleHandle): ()
	startLocalClientFeed(handle)

	local streamRemote = NetworkBridge.GetRemoteEvent(Config.RemoteNames.Stream)
	streamRemote.OnClientEvent:Connect(function(batch: { Logger.LogEntry })
		appendEntries(handle.ServerEntries, batch)
	end)

	-- See file header -- the ONE place IsOpen is ever written client-side.
	local function setOpen(open: boolean): ()
		handle.IsOpen:set(open)
		if open then
			-- Spawned: Subscribe is a yielding RemoteFunction call, and this must never block the
			-- InputBegan connection below (or handle.CloseRequested's) from handling the next event.
			task.spawn(subscribe, handle)
		else
			unsubscribe()
		end
	end

	handle.CloseRequested.Event:Connect(function()
		setOpen(false)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("OpenDevConsole", input) then
			local nowOpen = not peek(handle.IsOpen)
			setOpen(nowOpen)
			logger:debug("Live Admin Console toggled", { open = nowOpen })
		end
	end)

	logger:info("LiveConsoleClient started")
end

return LiveConsoleClient
