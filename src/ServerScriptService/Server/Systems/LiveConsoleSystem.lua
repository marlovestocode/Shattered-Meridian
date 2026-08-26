--!strict
--[[
	LiveConsoleSystem.lua

	Owns: authorization + rate-limiting, and every Constants.LiveConsole.RemoteNames remote, for the
	Live Admin Console (F5). checkLiveConsolePreconditions is a thin wrapper over
	Server/Network/AdminGate.Check (auth + rate limit), with its own dedicated RateLimiter bucket
	passed in -- see AdminGate.lua's own header for why it never constructs or defaults one itself.

	The one real difference from every other admin-tooling System in this codebase: this one exists
	specifically to keep working in a live server, streaming this server's own real-time log
	activity to a whitelisted admin's client. Shared/Logger.lua's own print()/warn() path stays
	exactly as Studio-gated as it always was -- this System never touches that gate. It reads
	Logger.lua's separate, always-on capture buffer instead (GetBufferSnapshot/OnEntry), which is
	what makes a live-server console possible without weakening Logger's own production-safety
	contract. See Logger.lua's own header for the full reasoning.

	Subscribe (RemoteFunction) doubles as both the authorization check and the fetch that populates
	a freshly-opened console -- fired by Client/DevTools/LiveConsole/LiveConsoleClient.lua the moment the
	panel actually opens, not eagerly at boot, so the snapshot it returns is never stale from having
	sat in a closed panel. Unsubscribe (RemoteEvent, fire-and-forget) stops this System from pushing
	to a player whose panel just closed -- no precondition check, matching RateLimiter.lua's own
	guidance that a "stop" action should never be blocked. Stream (RemoteEvent) is this System's own
	batched push to current subscribers only -- see flushPendingBatch below -- NEVER FireAllClients:
	a live log line can carry information (player names, internal state, error text) that has no
	business reaching a non-admin, the same reasoning every other admin-only remote in this codebase
	already rests on.

	Does not own: what gets captured (Shared/Logger.lua's emit()/CaptureEngineEntry), or the console
	panel itself (Client/UI/Screens/DevTools/LiveConsole/init.lua) -- this System only gates and transports.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)

local LiveConsoleSystem = {}

local logger = Logger.scope("LiveConsoleSystem")

local Config = Constants.LiveConsole

-- Own bucket, separate from DevMenuSystem's/MoveEditorSystem's -- see DevMenuSystem.lua's own
-- rateLimiter comment for why every dev-tool domain gets its own budget.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

-- Shared auth + rate-limit precondition -- Server/Network/AdminGate.lua's own Check, the module
-- this used to hand-duplicate (see that module's header).
local function checkLiveConsolePreconditions(player: Player, actionName: string): (boolean, string?)
	return AdminGate.Check(player, actionName, rateLimiter)
end

-- Currently-open admin consoles this server should push new entries to -- populated by Subscribe,
-- cleared by Unsubscribe and by Players.PlayerRemoving. A player can be authorized without being a
-- member of this set (e.g. their panel is simply closed); this set is the ONLY thing
-- flushPendingBatch below consults.
local subscribers: { [Player]: true } = {}

-- Entries captured since the last flush, in the order Logger.OnEntry fired them (which is already
-- Sequence order -- see that function's own header).
--
-- Bounded two ways, because the flush interval alone bounds neither. Constants.LiveConsole.
-- StreamBatchCap caps the LENGTH (see that constant for why an uncapped batch is worst exactly when
-- an admin needs it most), and `subscriberCount` below gates whether anything accumulates at all --
-- on a live server with no admin watching, which is nearly all of them nearly all of the time, this
-- used to run a table.insert per log line for the whole uptime of the server and then throw the
-- result away every 0.25s. Nothing is lost by not accumulating while unsubscribed: handleSubscribe
-- answers a freshly-opened console with Logger.GetBufferSnapshot(), which is the same ring buffer
-- these entries were being copied out of.
local pendingBatch: { Types.LogEntry } = {}
-- How many entries were discarded from the front of pendingBatch since the last flush because the
-- cap was hit. Reported to the admin as a synthetic entry rather than silently swallowed -- a
-- console that hides its own gaps is worse than one that admits them.
local droppedSinceFlush = 0
-- Maintained alongside `subscribers` so the Logger.OnEntry callback -- which runs on every single
-- log call in the whole server VM -- can decide in one integer compare rather than by iterating a
-- table to see whether it is empty.
local subscriberCount = 0

local function handleSubscribe(player: Player): Types.LiveConsoleSubscribeResult
	logger:debug("Subscribe received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkLiveConsolePreconditions(player, "Subscribe")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	if not subscribers[player] then
		subscribers[player] = true
		subscriberCount += 1
	end
	logger:info("Subscribe accepted", { player = player.Name })
	return { Success = true, Snapshot = Logger.GetBufferSnapshot() }
end

-- Deliberately still free of the authorization/rate-limit gate every other entry point here carries,
-- per this file's header and RateLimiter.lua's own guidance that a "stop" action must never be
-- blocked -- an admin whose console is stuck subscribed because their Unsubscribe was throttled is a
-- worse outcome than an unauthorized player toggling a table entry that was already nil.
--
-- What it no longer does is LOG on every call. That debug line was the whole cost of this handler,
-- and it was reachable by any client at any rate: each rejected-in-effect call still allocated a
-- LogEntry, wrote it into Logger's 1000-entry ring (evicting real entries) and, with an admin
-- subscribed, forwarded it to their client -- so an unauthenticated player could flood the exact feed
-- this System exists to deliver. Only a call that actually changes state logs now, which bounds it to
-- one line per genuine console close.
local function handleUnsubscribe(player: Player): ()
	if not subscribers[player] then
		return
	end
	subscribers[player] = nil
	subscriberCount -= 1
	logger:debug("Unsubscribe received", { player = player.Name })
end

-- Pushes whatever accumulated in pendingBatch since the last flush to every current subscriber,
-- then clears it -- caps this feature at 1/Constants.LiveConsole.StreamFlushIntervalSeconds pushes
-- per second per admin regardless of log volume, independent of Logger.lua's own per-message
-- Output rate limit. A no-op (no FireClient calls at all) whenever nothing new was captured or
-- nobody is currently subscribed.
local function flushPendingBatch(streamRemote: RemoteEvent): ()
	if #pendingBatch == 0 then
		return
	end

	local batch = pendingBatch
	pendingBatch = {}

	-- Prepended, not appended: the drop happened to entries OLDER than everything still in the batch,
	-- so the notice belongs where the gap is. Shaped as a real LogEntry (Sequence 0 marks it as
	-- synthetic -- Logger's own counter starts at 1) so the client's renderer needs no special case.
	if droppedSinceFlush > 0 then
		table.insert(
			batch,
			1,
			{
				Sequence = 0,
				TimestampUnix = os.time(),
				Side = "Server",
				Scope = "LiveConsoleSystem",
				Level = "Warn",
				Message = `Stream over capacity -- {droppedSinceFlush} older entries dropped from this batch`,
				Fields = nil,
				Source = "App",
			} :: Types.LogEntry
		)
		droppedSinceFlush = 0
	end

	for player in pairs(subscribers) do
		streamRemote:FireClient(player, batch)
	end
end

function LiveConsoleSystem.Init(): ()
	local subscribeRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.Subscribe)
	subscribeRemote.OnServerInvoke = function(player: Player): Types.LiveConsoleSubscribeResult
		local ok, resultOrError = pcall(handleSubscribe, player)
		if not ok then
			logger:error("Subscribe handler errored", { player = player.Name, errorMessage = tostring(resultOrError) })
			return { Success = false, Reason = "InternalError" }
		end
		return resultOrError :: Types.LiveConsoleSubscribeResult
	end

	local unsubscribeRemote = NetworkBridge.CreateRemoteEvent(Config.RemoteNames.Unsubscribe)
	unsubscribeRemote.OnServerEvent:Connect(function(player: Player)
		local ok, errorMessage = pcall(handleUnsubscribe, player)
		if not ok then
			logger:error("Unsubscribe handler errored", { player = player.Name, errorMessage = tostring(errorMessage) })
		end
	end)

	local streamRemote = NetworkBridge.CreateRemoteEvent(Config.RemoteNames.Stream)

	-- Registered once for this VM's whole lifetime -- appends every newly captured entry (App and
	-- Engine alike, this server's own) to pendingBatch. Cheap and non-yielding by design (no
	-- allocation on the common path, never a yield), so it can never stall whatever gameplay code
	-- just logged something -- which matters more here than anywhere else in this file, because this
	-- callback runs on EVERY log call in the entire server VM, gameplay hot paths included.
	Logger.OnEntry(function(entry: Logger.LogEntry)
		if subscriberCount == 0 then
			return
		end
		if #pendingBatch >= Config.StreamBatchCap then
			-- Drop the oldest rather than refusing the newest: an admin watching a live incident wants
			-- the most recent lines, and table.remove(_, 1) on a batch this size is bounded work that
			-- only runs once the cap is already reached.
			table.remove(pendingBatch, 1)
			droppedSinceFlush += 1
		end
		table.insert(pendingBatch, entry)
	end)

	task.spawn(function()
		while true do
			task.wait(Config.StreamFlushIntervalSeconds)
			flushPendingBatch(streamRemote)
		end
	end)

	PlayerLifecycle.BindAllPlayers({
		Scope = "LiveConsoleSystem",
		OnPlayerRemoving = function(player: Player)
			if subscribers[player] then
				subscribers[player] = nil
				subscriberCount -= 1
			end
			rateLimiter:Clear(player)
		end,
	})

	logger:info("LiveConsoleSystem.Init() complete")
end

return LiveConsoleSystem :: Types.SystemModule
