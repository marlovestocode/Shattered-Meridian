--!strict
--[[
	LiveConsoleSystem.lua

	Owns: authorization + rate-limiting, and every Constants.LiveConsole.RemoteNames remote, for the
	Live Admin Console (F7). Mirrors MoveEditorSystem.lua's shape exactly: its own isAuthorized
	(AdminConfig.AuthorizedUserIds), its own checkLiveConsolePreconditions (authorization + rate
	limit), its own dedicated RateLimiter bucket -- a dedicated copy rather than a cross-file call,
	since DevMenuSystem.lua's own checkDevMenuPreconditions is a local, non-exported function, the
	same reasoning MoveEditorSystem.lua's own header gives for its copy.

	The one real difference from every other admin-tooling System in this codebase: this one exists
	specifically to keep working in a live server, streaming this server's own real-time log
	activity to a whitelisted admin's client. Shared/Logger.lua's own print()/warn() path stays
	exactly as Studio-gated as it always was -- this System never touches that gate. It reads
	Logger.lua's separate, always-on capture buffer instead (GetBufferSnapshot/OnEntry), which is
	what makes a live-server console possible without weakening Logger's own production-safety
	contract. See Logger.lua's own header for the full reasoning.

	Subscribe (RemoteFunction) doubles as both the authorization check and the fetch that populates
	a freshly-opened console -- fired by Client/LiveConsole/LiveConsoleClient.lua the moment the
	panel actually opens, not eagerly at boot, so the snapshot it returns is never stale from having
	sat in a closed panel. Unsubscribe (RemoteEvent, fire-and-forget) stops this System from pushing
	to a player whose panel just closed -- no precondition check, matching RateLimiter.lua's own
	guidance that a "stop" action should never be blocked. Stream (RemoteEvent) is this System's own
	batched push to current subscribers only -- see flushPendingBatch below -- NEVER FireAllClients:
	a live log line can carry information (player names, internal state, error text) that has no
	business reaching a non-admin, the same reasoning every other admin-only remote in this codebase
	already rests on.

	Does not own: what gets captured (Shared/Logger.lua's emit()/CaptureEngineEntry), or the console
	panel itself (Client/UI/Screens/LiveConsole/init.lua) -- this System only gates and transports.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local AdminConfig = require(script.Parent.Parent.Config.AdminConfig)

local LiveConsoleSystem = {}

local logger = Logger.scope("LiveConsoleSystem")

local Config = Constants.LiveConsole

-- Own bucket, separate from DevMenuSystem's/MoveEditorSystem's -- see DevMenuSystem.lua's own
-- rateLimiter comment for why every dev-tool domain gets its own budget.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

-- Reads Server/Config/AdminConfig.lua, not Constants -- same reasoning as DevMenuSystem.isAuthorized/
-- MoveEditorSystem.isAuthorized.
local function isAuthorized(player: Player): boolean
	return AdminConfig.AuthorizedUserIds[player.UserId] == true
end

-- Shared auth + rate-limit precondition -- see DevMenuSystem.lua's checkDevMenuPreconditions for
-- the identical shape/reasoning this mirrors.
local function checkLiveConsolePreconditions(player: Player, actionName: string): (boolean, string?)
	if not isAuthorized(player) then
		logger:warn(actionName .. " rejected: not authorized", { player = player.Name, userId = player.UserId })
		return false, "NotAuthorized"
	end
	if rateLimiter:IsLimited(player) then
		logger:debug(actionName .. " rejected: rate limited", { player = player.Name, userId = player.UserId })
		return false, "RateLimited"
	end
	return true, nil
end

-- Currently-open admin consoles this server should push new entries to -- populated by Subscribe,
-- cleared by Unsubscribe and by Players.PlayerRemoving. A player can be authorized without being a
-- member of this set (e.g. their panel is simply closed); this set is the ONLY thing
-- flushPendingBatch below consults.
local subscribers: { [Player]: true } = {}

-- Entries captured since the last flush, in the order Logger.OnEntry fired them (which is already
-- Sequence order -- see that function's own header). Cleared on every flush regardless of whether
-- any subscriber was actually online to receive it, so this table can never grow unbounded between
-- flushes even with zero subscribers.
local pendingBatch: { Types.LogEntry } = {}

local function handleSubscribe(player: Player): Types.LiveConsoleSubscribeResult
	logger:debug("Subscribe received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkLiveConsolePreconditions(player, "Subscribe")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	subscribers[player] = true
	logger:info("Subscribe accepted", { player = player.Name })
	return { Success = true, Snapshot = Logger.GetBufferSnapshot() }
end

local function handleUnsubscribe(player: Player): ()
	subscribers[player] = nil
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
	-- Engine alike, this server's own) to pendingBatch. Cheap and non-yielding by design (a plain
	-- table.insert), so it can never stall whatever gameplay code just logged something.
	Logger.OnEntry(function(entry: Logger.LogEntry)
		table.insert(pendingBatch, entry)
	end)

	task.spawn(function()
		while true do
			task.wait(Config.StreamFlushIntervalSeconds)
			flushPendingBatch(streamRemote)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		subscribers[player] = nil
		rateLimiter:Clear(player)
	end)

	logger:info("LiveConsoleSystem.Init() complete")
end

return LiveConsoleSystem :: Types.SystemModule
