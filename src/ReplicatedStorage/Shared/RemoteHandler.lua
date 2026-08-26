--!strict
--[[
	RemoteHandler.lua

	Owns: the pcall boundary around a RemoteFunction.OnServerInvoke handler -- catch whatever it
	throws, log it via the caller's own Logger scope, and answer with the caller's own typed error
	result instead of letting the error cross the remote boundary. The same shape DevMenuSystem,
	BugReportSystem, CharacterCreationSystem, ArtSystem, SettingsSystem, CharacterSheetSystem,
	RivalrySystem, and BountySystem each hand-wrote independently before adopting this module.

	ONE documented exception is left. ServerHopSystem's RequestTeleport handler returns
	(boolean, string?) -- a multi-return shape WrapInvoke's single-`Result` generic cannot express --
	so it hand-wraps its own single pcall in the identical catch/log/fallback shape instead. That
	rationale is about the type system and still holds.

	The other two -- MoveEditorSystem's and KitEditorSystem's structurally identical local
	`wrapHandler` -- are gone, and the rationale this header used to give for them ("generalizing that
	one too was ruled out during the Network-module design pass") did not survive being checked. The
	only thing those locals did that WrapInvoke does not was bake a fixed error result and a logger
	into the signature, and BOTH of those are already parameters here. What they actually needed was
	not a different wrapper but a BOUND one -- Scoped below, the same shape
	Shared/DataStoreRetry.Scoped takes, so their twenty-one call sites read exactly as they did.

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

-- Binds a logger and a fixed error result to WrapInvoke once, returning the
-- `wrapHandler(name, handler)` helper a System with many remotes wants at its call sites.
--
-- Exists for the same reason Shared/DataStoreRetry.Scoped does, and was found the same way: two
-- Systems each held a ten-line local that WAS this binding written out longhand, and both had
-- twenty-one call sites reading `wrapHandler("Name", handleName)`. Passing logger and errorResult at
-- each of those instead would have been the honest deduplication and the worse-reading code.
--
-- `errorResult` is `any` here rather than a generic, because one binding serves handlers with
-- different Result types (every one of them a `{ Success = false, Reason = ... }` shape, but not the
-- same named type). The cast is done once, here, instead of once per call site.
function RemoteHandler.Scoped(
	logger: Logger.LoggerScope,
	errorResult: any
): <Result, Args...>(
	name: string,
	handler: (Player, Args...) -> Result
) -> (Player, Args...) -> Result
	return function<Result, Args...>(name: string, handler: (Player, Args...) -> Result): (Player, Args...) -> Result
		return RemoteHandler.WrapInvoke(logger, name, errorResult :: Result, handler)
	end
end

return RemoteHandler
