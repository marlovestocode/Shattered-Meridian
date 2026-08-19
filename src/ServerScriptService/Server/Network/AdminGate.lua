--!strict
--[[
	AdminGate.lua

	Owns: the auth-check + rate-limit + rejection-logging precondition every admin-gated remote
	handler needs before doing anything else -- the shape DevMenuSystem.checkDevMenuPreconditions,
	MoveEditorSystem.checkMoveEditorPreconditions, and LiveConsoleSystem.checkLiveConsolePreconditions
	each hand-duplicated verbatim (the latter two's own header comments admit they're copying the
	first). Lives under Server/Network/, a peer of Server/Config/Server/Events/Server/Managers, not
	ReplicatedStorage/Shared/ -- it requires Server/Config/AdminConfig.lua, which must never be
	reachable from a client-decompilable module. See AdminConfig.lua's own header.

	Does not own: which RateLimiter bucket to check against -- always caller-supplied, never
	constructed here. A default bucket would remove the per-category budget split every non-trivial
	System already relies on (EmoteSystem's play-vs-loadout split, AttackRequestSystem's
	request-vs-swap split, and every other System's own dedicated instance -- see RateLimiter.lua's
	own header for why one instance per category matters). Also does not own payload validation or
	what happens once a request passes the gate.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local AdminConfig = require(script.Parent.Parent.Config.AdminConfig)

local AdminGate = {}

local logger = Logger.scope("AdminGate")

-- Reads Server/Config/AdminConfig.lua directly, not Constants -- that whitelist deliberately lives
-- server-only so it never replicates. See AdminConfig.lua's own header.
function AdminGate.IsAuthorized(player: Player): boolean
	return AdminConfig.AuthorizedUserIds[player.UserId] == true
end

-- Shared auth + rate-limit precondition. `actionName` feeds the "X rejected: ..." log message, so
-- callers only need to name their action once. `limiter` is always caller-supplied -- see this
-- module's own header for why no default bucket lives here. Returns (true, nil) when the request
-- may proceed, or (false, Reason) with the same "NotAuthorized"/"RateLimited" strings every existing
-- Result shape already expects.
function AdminGate.Check(
	player: Player,
	actionName: string,
	limiter: RateLimiter.RateLimiterInstance
): (boolean, string?)
	if not AdminGate.IsAuthorized(player) then
		logger:warn(actionName .. " rejected: not authorized", { player = player.Name, userId = player.UserId })
		return false, "NotAuthorized"
	end
	if limiter:IsLimited(player) then
		logger:debug(actionName .. " rejected: rate limited", { player = player.Name, userId = player.UserId })
		return false, "RateLimited"
	end
	return true, nil
end

return AdminGate
