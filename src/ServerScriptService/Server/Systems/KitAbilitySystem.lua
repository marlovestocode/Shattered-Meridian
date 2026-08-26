--!strict
--[[
	KitAbilitySystem.lua

	Owns: the shared trigger/remote path a player's own Race Trait or Bloodline Stage Active ability
	request arrives through -- the ONE remote pair both content layers fire through, not two. Domain
	logic (eligibility, cooldown, Qi cost, effect application) stays entirely in
	RaceSystem.CanUseAbility/UseAbility and BloodlineSystem.CanUseAbility/UseAbility; this module is
	the thin AttackRequestSystem-shaped wrapper around them -- genuinely simpler than that precedent,
	since it's Player-keyed rather than Model-keyed, with none of AttackRequestSystem's hitbox-
	registration, per-Model cooldown chain, or buffered-press machinery: a utility press has no "swing
	rhythm" to protect the way a combat swing does.

	DISPATCH IS BY THE FULL (SourceKind, SourceId, AbilityId) TRIPLE, never AbilityId alone -- see
	Types.ActiveModifierSource's own header on why that makes a cross-content AbilityId collision
	structurally harmless: a Race trait and a Bloodline stage could reuse the same AbilityId string
	with no ambiguity, because SourceKind alone already decides which System's own UseAbility resolves
	it.

	Remote shape mirrors ArtSystem's UnlockArt/EquipArt precedent -- a RemoteFunction
	(Constants.Kit.RemoteNames.RequestAbility) because "the panel has to say why" a use was refused,
	and a low-frequency utility press needs no client-side prediction/input buffer the way a combat
	swing does. AbilityUsed (a RemoteEvent, server -> owning client only) is the post-success FX echo,
	the same "just enough for FX" shape AttackStartedPayload already carries for a swing.

	NO AdminGate -- any player may use their own kit, this is not admin tooling. Own dedicated
	RateLimiter bucket instead, same as every other public request remote in this codebase.

	Boots after both RaceSystem and BloodlineSystem -- shipping earlier would be a remote that always
	refuses, since dispatch has nobody real to call into yet.

	Does not own: eligibility/cooldown/cost/effect logic (RaceSystem/BloodlineSystem), trait/bloodline
	content (RaceManager/BloodlineManager), or the modifier engine an ability's effects apply through
	(EffectSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local RaceSystem = require(script.Parent.RaceSystem)
local BloodlineSystem = require(script.Parent.BloodlineSystem)

local logger = Logger.scope("KitAbilitySystem")

local KitAbilitySystem = {}

local abilityUsedRemote: RemoteEvent? = nil
local requestLimiter = RateLimiter.New(Constants.Kit.RequestMaxCallsPerSecond)

-- Same "defensive typeof, never trust the shape wholesale" posture
-- AttackRequestSystem.sanitizeRequest already establishes for its own client-submitted request --
-- exported so TestEZ can exercise it with no live Player/DataStore, the same "pure logic gets its own
-- export" precedent this codebase's own request handlers already follow.
function KitAbilitySystem.SanitizeRequest(raw: unknown): Types.KitAbilityRequest?
	if typeof(raw) ~= "table" then
		return nil
	end
	local candidate = raw :: { [string]: unknown }

	local sourceKind = candidate.SourceKind
	if sourceKind ~= "RaceTrait" and sourceKind ~= "BloodlineStage" then
		return nil
	end
	if typeof(candidate.SourceId) ~= "string" or (candidate.SourceId :: string) == "" then
		return nil
	end
	if typeof(candidate.AbilityId) ~= "string" or (candidate.AbilityId :: string) == "" then
		return nil
	end

	return {
		SourceKind = sourceKind :: Types.ActiveModifierSource,
		SourceId = candidate.SourceId :: string,
		AbilityId = candidate.AbilityId :: string,
	}
end

-- Dispatches to the owning System's own UseAbility -- the one place this module knows both Systems
-- exist at all. RaceSystem.UseAbility takes no AbilityId (a trait has exactly one ability, no
-- ambiguity to resolve -- RaceSystem.lua's own header); BloodlineSystem.UseAbility does, since a
-- bloodline's reachable ability changes as the player advances stages. Exported for the same TestEZ
-- reason SanitizeRequest is.
function KitAbilitySystem.Dispatch(player: Player, request: Types.KitAbilityRequest): string?
	if request.SourceKind == "RaceTrait" then
		return RaceSystem.UseAbility(player, request.SourceId)
	end
	return BloodlineSystem.UseAbility(player, request.SourceId, request.AbilityId)
end

local function sendAbilityUsed(player: Player, request: Types.KitAbilityRequest): ()
	if not abilityUsedRemote then
		return
	end
	local payload: Types.KitAbilityUsedPayload = {
		SourceKind = request.SourceKind,
		SourceId = request.SourceId,
		AbilityId = request.AbilityId,
	}
	abilityUsedRemote:FireClient(player, payload)
end

local function handleRequestAbility(player: Player, raw: unknown): Types.KitActionResult
	if requestLimiter:IsLimited(player) then
		return { Success = false, Reason = "RateLimited" }
	end
	local request = KitAbilitySystem.SanitizeRequest(raw)
	if not request then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local refusal = KitAbilitySystem.Dispatch(player, request)
	if refusal then
		return { Success = false, Reason = refusal }
	end

	sendAbilityUsed(player, request)
	return { Success = true }
end

function KitAbilitySystem.Init(): ()
	local requestRemote = NetworkBridge.CreateRemoteFunction(Constants.Kit.RemoteNames.RequestAbility)
	requestRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		"RequestAbility",
		{ Success = false, Reason = "InternalError" } :: Types.KitActionResult,
		handleRequestAbility
	)

	abilityUsedRemote = NetworkBridge.CreateRemoteEvent(Constants.Kit.RemoteNames.AbilityUsed)

	PlayerLifecycle.BindAllPlayers({
		Scope = "KitAbilitySystem",
		OnPlayerRemoving = function(player: Player)
			requestLimiter:Clear(player)
		end,
	})

	logger:info("KitAbilitySystem.Init() complete")
end

return KitAbilitySystem :: Types.SystemModule
