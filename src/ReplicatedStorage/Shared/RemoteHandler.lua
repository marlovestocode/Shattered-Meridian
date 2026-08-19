--!strict
--[[
	RemoteHandler.lua

	Owns: the pcall boundary around a RemoteFunction.OnServerInvoke handler -- catch whatever it
	throws, log it via the caller's own Logger scope, and answer with the caller's own typed error
	result instead of letting the error cross the remote boundary. The same shape DevMenuSystem,
	BugReportSystem, CharacterCreationSystem, ArtSystem, SettingsSystem, CharacterSheetSystem,
	RivalrySystem, and BountySystem each hand-wrote independently before adopting this module.

	Two documented exceptions still hand-roll their own pcall boundary instead of calling this:
	MoveEditorSystem keeps a structurally identical local `wrapHandler` -- generalizing that one too
	was ruled out during the Network-module design pass, see that module's own header -- and
	ServerHopSystem's RequestTeleport handler returns (boolean, string?), a multi-return shape
	WrapInvoke's single-`Result` generic doesn't support, so it hand-wraps its own single pcall in the
	identical catch/log/fallback shape instead.

	Does not own: authorization or rate limiting (compose with Server/Network/AdminGate.Check, or an
	inline RateLimiter check, inside `handler` itself), remote creation/lookup (still
	NetworkBridge.Create*/Get*), or RemoteEvent handlers -- those have no return value to protect, so
	there's no pcall boundary worth centralizing there.
]]

local RemoteHandler = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)

-- Wraps `handler` so a thrown error inside it is caught, logged under `logger` as "<name> handler
-- errored", and answered with `errorResult` instead of throwing across the remote boundary.
-- `name` feeds only the error log message. `errorResult` is a literal value, not a factory --
-- every existing caller's error result is a fixed shape (e.g. { Success = false, Reason =
-- "InternalError" }), so there's nothing per-call that needs to vary.
function RemoteHandler.WrapInvoke<Result, Args...>(
	logger: Logger.LoggerScope,
	name: string,
	errorResult: Result,
	handler: (Player, Args...) -> Result
): (Player, Args...) -> Result
	return function(player: Player, ...: Args...): Result
		local ok, resultOrError = pcall(handler, player, ...)
		if not ok then
			logger:error(name .. " handler errored", { player = player.Name, errorMessage = tostring(resultOrError) })
			return errorResult
		end
		return resultOrError :: Result
	end
end

return RemoteHandler
