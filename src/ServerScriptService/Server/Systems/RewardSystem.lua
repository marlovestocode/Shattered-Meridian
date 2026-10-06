--!strict
--[[
	RewardSystem.lua

	Owns: reward composition -- turning a confirmed gameplay fact into an immutable manifest of the
	reward kinds it is STRUCTURALLY eligible for, and handing that manifest to ProgressionSystem. It is
	the sole subscriber to GameplayEvents.PlayerKilled on the fight-to-grow path: no other System turns
	a kill into progression by listening for it directly.

	    PlayerKilled(victim, killer, deathId)      PlayerDeathSystem -- the only publisher
	      -> RewardSystem.HandlePlayerKilled       this module: eligible? for what?
	      -> ProgressionSystem.Apply(manifest)      legitimate? routed to whom?
	      -> MeridianSystem.AwardKillXP             how much; the write; MeridianXPAwarded
	      -> BloodlineSystem.CountKill              stage progress
	      -> BountySystem.PayClaim                  the victim's mark, if any
	      -> TierSystem (via MeridianXPAwarded)     promotion

	WHAT "ELIGIBLE" MEANS HERE, AND WHAT IT DOES NOT. Taxonomy, not judgement: a PlayerKilled with a
	non-nil killer who is not the victim is a "PvPKill", and REWARD_TAXONOMY says what a PvPKill can
	carry. An unattributed death (a fall, the void, a non-player's blow -- PlayerDeathSystem publishes
	killer = nil for all of them) composes nothing. Whether a composed manifest actually becomes
	progression is ProgressionSystem's legitimacy gate, deliberately not duplicated here; how much any
	component is worth is its owner's (MeridianSystem), deliberately not computed here. This module
	holds no damage math and trusts nothing a client said: its only input is a server-internal fact.

	EXACTLY ONCE PER FACT. PlayerDeathSystem already publishes one fact per life; this module still
	refuses to compose twice from one deathId, because a duplicate at this layer is a duplicated
	reward, and the causes it guards against are ones that layer cannot see -- a second subscription
	(Init run twice), or a future second publisher. deathIds are server-lifetime monotonic and delivered
	in fire order, so one high-water mark is the whole replay guard: no per-player table to lifecycle,
	nothing that grows.

	The fact is consumed BEFORE routing, so a manifest whose route fails (the killer's profile is not
	loaded, say) is refused and logged by its owner, never retried from here. A reward that could be
	retried is a reward that could be granted twice.

	Components today: Meridian XP, Bloodline stage progress and the victim's Bounty, if any (the last two
	joined 2026-10-06; before that both reached their owners through their own PlayerKilled subscriptions,
	outside the gate). software-architecture.md names absorbed essence as another PvP-kill reward, but
	AbsorbSystem is an empty roadmap entry with no balance authority; composing an "Absorb" component
	nobody can apply would be a promise, not a reward.

	No client remote, and there must never be one: a reward requested by a client is exactly the
	client-claimed progression project-vision.md's first pillar forbids.

	Does not own: kill confirmation or attribution (PlayerDeathSystem), progression legitimacy or routing
	(ProgressionSystem), any reward magnitude or balance (MeridianSystem), persistence (PlayerDataSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ReplicatedStorage.Shared.Logger)
local ProgressionTypes = require(ReplicatedStorage.Shared.Progression.ProgressionTypes)
local Types = require(ReplicatedStorage.Shared.Types)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local ProgressionSystem = require(script.Parent.ProgressionSystem)

type RewardManifest = ProgressionTypes.RewardManifest
type RewardComponentKind = ProgressionTypes.RewardComponentKind
type ProgressionOutcome = ProgressionTypes.ProgressionOutcome

local logger = Logger.scope("RewardSystem")

local RewardSystem = {}

-- Which reward kinds each source is structurally eligible for. Frozen: a new kind or source is a code
-- change with a review, never a runtime mutation.
local PVP_KILL_COMPONENTS: { RewardComponentKind } = table.freeze({
	"MeridianXP" :: RewardComponentKind,
	"BloodlineStage" :: RewardComponentKind,
	"BountyClaim" :: RewardComponentKind,
})
local REWARD_TAXONOMY: { [ProgressionTypes.RewardSource]: { RewardComponentKind } } = table.freeze({
	PvPKill = PVP_KILL_COMPONENTS,
})

-- Why a fact composed no manifest. Returned for specs and logged at debug; none of these is an error.
export type CompositionRefusal = "Unattributed" | "SelfKill" | "InvalidEventId" | "Replayed"

-- Highest deathId already composed (or refused as a replay). See this file's header.
local lastEventId = 0

local killedConnection: RBXScriptConnection? = nil
local started = false

-- Composes the manifest for one PlayerKilled fact, or says why there is none. Consumes the fact's id
-- when it composes, so the same deathId never composes twice.
function RewardSystem.ComposeKillManifest(
	victim: Player,
	killer: Player?,
	deathId: number
): (RewardManifest?, CompositionRefusal?)
	if typeof(deathId) ~= "number" or deathId ~= deathId or deathId <= 0 or deathId % 1 ~= 0 then
		return nil, "InvalidEventId"
	end
	if deathId <= lastEventId then
		return nil, "Replayed"
	end
	-- Consumed for every well-formed id, attributed or not, so an unattributed death can never be
	-- "upgraded" by a later replay that claims a killer for it.
	lastEventId = deathId

	if killer == nil then
		return nil, "Unattributed"
	end
	if killer == victim then
		return nil, "SelfKill"
	end

	local manifest: RewardManifest = {
		Event = table.freeze({
			Source = "PvPKill" :: ProgressionTypes.RewardSource,
			EventId = deathId,
			Recipient = killer,
			Victim = victim,
		}),
		Components = PVP_KILL_COMPONENTS,
	}
	return table.freeze(manifest), nil
end

-- The PlayerKilled handler: compose, then hand over. Returns ProgressionSystem's outcome, or nil when
-- the fact composed nothing -- public so a spec can drive the whole spine with stand-in Players, which
-- the BindableEvent path would deep-copy out from under it.
function RewardSystem.HandlePlayerKilled(victim: Player, killer: Player?, deathId: number): ProgressionOutcome?
	local manifest, refusal = RewardSystem.ComposeKillManifest(victim, killer, deathId)
	if manifest == nil then
		if refusal == "Replayed" or refusal == "InvalidEventId" then
			-- Never legitimately reachable from PlayerDeathSystem, so worth a warning when it happens.
			logger:warn("Refused a PlayerKilled fact", { refusal = refusal, deathId = deathId, victim = victim.Name })
		end
		return nil
	end
	return ProgressionSystem.Apply(manifest)
end

-- Subscribes to PlayerKilled. Idempotent: a second call does not subscribe twice, which is the first
-- line of defence against a duplicated reward (the deathId high-water mark is the second).
function RewardSystem.Attach(): ()
	if killedConnection then
		return
	end
	killedConnection = GameplayEvents.OnPlayerKilled(function(victim: Player, killer: Player?, deathId: number)
		RewardSystem.HandlePlayerKilled(victim, killer, deathId)
	end)
end

function RewardSystem.Init(): ()
	if started then
		return
	end
	-- Every kind this module can compose must have somewhere to go. Asserted at boot rather than
	-- discovered as a refused component on a player's first kill.
	for source, kinds in REWARD_TAXONOMY do
		for _, kind in kinds do
			assert(
				ProgressionSystem.CanRoute(kind),
				`RewardSystem: {source} composes {kind}, which ProgressionSystem cannot route`
			)
		end
	end
	started = true

	RewardSystem.Attach()

	logger:info("RewardSystem.Init() complete")
end

-- Drops the subscription and the replay mark. Spec-only.
function RewardSystem.Reset(): ()
	if killedConnection then
		killedConnection:Disconnect()
		killedConnection = nil
	end
	lastEventId = 0
	started = false
end

return RewardSystem :: Types.SystemModule & typeof(RewardSystem)
