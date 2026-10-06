--!strict
--[[
	ProgressionSystem.lua

	Owns: the fight-to-grow legitimacy gate and progression routing. It receives a composed reward
	manifest from RewardSystem, decides whether that manifest may become progression at all, and routes
	each accepted component to the public API of the one System that owns it. Coordinates; never
	calculates. See software-architecture.md's "ProgressionSystem: orchestration, not ownership".

	THE GATE. project-vision.md's first pillar -- meaningful progression is earned from real PvP combat,
	never passive or client-claimed activity -- is enforced HERE, once, for every source:
	  * the source must be in LEGITIMATE_SOURCES. Today that is "PvPKill" alone. A future boss kill or
	    quest does not become progression by existing; someone has to add it to that table, in review.
	  * the recipient may never be the victim (RewardSystem already refuses a self-kill; this is the
	    same rule held again at the layer that owns it, so a future second composer cannot skip it).
	  * a manifest must carry at least one component.
	The fact itself arrives already server-confirmed and attributed (PlayerDeathSystem -> RewardSystem);
	nothing in this module reads a value a client supplied, because none reaches it.

	  * THE REPEAT-VICTIM RULE (anti-farming). Each killer->victim pair keeps a run: a kill of that victim
	    within ProgressionConstants.RepeatVictim.WindowSeconds of the pair's PREVIOUS kill extends it, and
	    only a full window with no kill of that victim ends it. The Nth kill of a run counts for
	    Weights[N] of a kill, and past the end of that list for nothing -- the manifest is refused as
	    "RepeatVictim". Two friends trading kills on repeat, or one player killing their own alt, stop
	    progressing within a handful of kills, and a patient farmer who spaces kills just inside the
	    window stays at zero rather than earning again.

	THE WEIGHT IS LEGITIMACY, NOT MAGNITUDE. This module decides how much of a kill COUNTS (0..1) and
	hands that to each owner; the owner decides what a counted kill is worth. MeridianSystem.AwardKillXP
	scales its own BaseXPPerKill by it. No XP number ever appears here, which is the line
	software-architecture.md draws around this module.

	KEYED BY UserId, NOT Player. A Player instance is new on every rejoin, so a Player-keyed history
	would reset the moment a farming victim left and came back -- the cheapest exploit there is. UserIds
	also mean there is no Player reference to leak, so the history needs no PlayerRemoving scrub: it is
	pruned by time instead (sweepExpired, run on every kill -- kills are a few-a-minute event, and the
	table holds one small record per pair whose run is still open). What it does not survive
	is a server hop; that and alt-account detection are recorded as open in
	docs/architecture/2026-09-28-progression-spine-audit.md.

	Every progression a kill grants passes this rule: Meridian XP, Bloodline stage progress and Bounty
	payouts (the last two moved onto the spine 2026-10-06, closing the audit's O-1/O-3).

	THE ROUTES. ROUTES maps each component kind to its owner's API: MeridianSystem.AwardKillXP (which
	writes, replicates and publishes MeridianXPAwarded, what TierSystem promotes from),
	BloodlineSystem.CountKill and BountySystem.PayClaim. Each owner scales its own amount by the weight.
	The chain after this module is one-directional: no routed System ever calls back in here, and nothing
	here computes an XP amount, a stage or a tier.

	NO MILESTONE CHECK. software-architecture.md has this module trigger AchievementSystem after a
	pipeline run lands. AchievementSystem is an empty roadmap entry with no milestone definitions, so a
	call into it would be a fake check -- it is left out until there is something real to evaluate.

	Boot: needs its three route owners' modules (not their Init -- each route is a plain call); boots
	before RewardSystem, its one caller, which asserts at Init that every kind it composes is routable
	here (CanRoute).

	Does not own: what an event is eligible for (RewardSystem), any magnitude or balance (MeridianSystem),
	tier math (TierSystem), persistence (PlayerDataSystem), or kill attribution (PlayerDeathSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local ProgressionConstants = require(ReplicatedStorage.Shared.Progression.ProgressionConstants)
local ProgressionTypes = require(ReplicatedStorage.Shared.Progression.ProgressionTypes)
local Types = require(ReplicatedStorage.Shared.Types)
local BloodlineSystem = require(script.Parent.BloodlineSystem)
local BountySystem = require(script.Parent.BountySystem)
local MeridianSystem = require(script.Parent.MeridianSystem)

type RewardManifest = ProgressionTypes.RewardManifest
type RewardComponentKind = ProgressionTypes.RewardComponentKind
type ProgressionEvent = ProgressionTypes.ProgressionEvent
type ProgressionOutcome = ProgressionTypes.ProgressionOutcome
type ProgressionRefusal = ProgressionTypes.ProgressionRefusal

local logger = Logger.scope("ProgressionSystem")

local ProgressionSystem = {}

-- The sources the fight-to-grow pillar lets become progression. See this file's header.
local LEGITIMATE_SOURCES: { [ProgressionTypes.RewardSource]: boolean } = table.freeze({
	PvPKill = true,
})

-- Component kind -> the owning System's apply call, given the event and its legitimacy weight.
-- Returns whether the owner applied it. Each route is a closure over a PUBLIC API so the owner keeps
-- every decision about amount and validity.
local ROUTES: { [RewardComponentKind]: (event: ProgressionEvent, weight: number) -> boolean } = table.freeze({
	MeridianXP = function(event: ProgressionEvent, weight: number): boolean
		return MeridianSystem.AwardKillXP(event.Recipient, event.Victim, weight)
	end,
	BloodlineStage = function(event: ProgressionEvent, weight: number): boolean
		return BloodlineSystem.CountKill(event.Recipient, weight)
	end,
	BountyClaim = function(event: ProgressionEvent, weight: number): boolean
		return BountySystem.PayClaim(event.Victim, event.Recipient, event.EventId, weight)
	end,
})

-- One killer->victim run: kills so far (capped at #Weights -- past that every kill weighs 0 anyway)
-- and when the latest landed (os.clock).
type Run = { Count: number, LastAt: number }

-- recipient UserId -> victim UserId -> the pair's open run. See this file's header on the UserId keying.
local recentKills: { [number]: { [number]: Run } } = {}

local started = false

-- The pair's run if it is still open at `now`, else nil.
local function openRun(recipientId: number, victimId: number, now: number): Run?
	local victims = recentKills[recipientId]
	local run = if victims then victims[victimId] else nil
	if run and now - run.LastAt <= ProgressionConstants.RepeatVictim.WindowSeconds then
		return run
	end
	return nil
end

-- Drops every run that has closed, and any recipient left with none.
local function sweepExpired(now: number): ()
	local window = ProgressionConstants.RepeatVictim.WindowSeconds
	for recipientId, victims in recentKills do
		for victimId, run in victims do
			if now - run.LastAt > window then
				victims[victimId] = nil
			end
		end
		if next(victims) == nil then
			recentKills[recipientId] = nil
		end
	end
end

-- The weight the NEXT kill of `victimId` by `recipientId` would carry at `now`, without recording it.
function ProgressionSystem.RepeatWeight(recipientId: number, victimId: number, now: number): number
	local run = openRun(recipientId, victimId, now)
	local prior = if run then run.Count else 0
	return ProgressionConstants.RepeatVictim.Weights[prior + 1] or 0
end

-- Counts one kill of `victimId` by `recipientId`, extending the pair's run or opening a new one. Every
-- kill is counted, including one weighted to zero -- that is what keeps a farming pair's run open.
local function recordKill(recipientId: number, victimId: number, now: number): ()
	local run = openRun(recipientId, victimId, now)
	if run then
		run.Count = math.min(run.Count + 1, #ProgressionConstants.RepeatVictim.Weights)
		run.LastAt = now
		return
	end
	local victims = recentKills[recipientId]
	if victims == nil then
		victims = {}
		recentKills[recipientId] = victims
	end
	victims[victimId] = { Count = 1, LastAt = now }
end

-- Whether a component kind has an owner to route to. RewardSystem asserts this at boot for every kind
-- it can compose.
function ProgressionSystem.CanRoute(kind: RewardComponentKind): boolean
	return ROUTES[kind] ~= nil
end

local function refuse(manifest: RewardManifest, refusal: ProgressionRefusal): ProgressionOutcome
	logger:warn("Refused a reward manifest", {
		refusal = refusal,
		source = manifest.Event.Source,
		eventId = manifest.Event.EventId,
	})
	return { Accepted = false, Refusal = refusal, Weight = 0, Granted = {} }
end

-- Gates `manifest` and routes every component to its owner. Returns what happened; never throws on a
-- well-formed manifest. A component whose owner refuses is reported in Granted as false -- the owner
-- has already logged why in its own terms (MeridianSystem: profile not loaded). `now` defaults to
-- os.clock() and exists so a spec can walk the repeat-victim window without sleeping.
function ProgressionSystem.Apply(manifest: RewardManifest, now: number?): ProgressionOutcome
	local at = now or os.clock()
	local event = manifest.Event
	if not LEGITIMATE_SOURCES[event.Source] then
		return refuse(manifest, "IllegitimateSource")
	end
	if event.Recipient == event.Victim then
		return refuse(manifest, "SelfReward")
	end
	if #manifest.Components == 0 then
		return refuse(manifest, "NoComponents")
	end

	-- Repeat-victim rule. Weighed BEFORE this kill is recorded (it is the Nth kill's weight, reading
	-- the N-1 before it), and recorded whether or not it earns anything.
	sweepExpired(at)
	local recipientId = event.Recipient.UserId
	local victimId = event.Victim.UserId
	local weight = ProgressionSystem.RepeatWeight(recipientId, victimId, at)
	recordKill(recipientId, victimId, at)
	if weight <= 0 then
		-- Expected behaviour, not a fault: info, not warn.
		logger:info("Kill weighted to zero by the repeat-victim rule", {
			recipient = event.Recipient.Name,
			victim = event.Victim.Name,
			eventId = event.EventId,
		})
		return { Accepted = false, Refusal = "RepeatVictim", Weight = 0, Granted = {} }
	end

	local granted: { [RewardComponentKind]: boolean } = {}
	for _, kind in manifest.Components do
		local route = ROUTES[kind]
		if route == nil then
			logger:warn("No route for reward component", { kind = kind, eventId = event.EventId })
			granted[kind] = false
			continue
		end
		-- pcall'd so one owner's error cannot abort the rest of the manifest or unwind into the
		-- PlayerKilled dispatch that called RewardSystem.
		local ok, appliedOrError = pcall(route, event, weight)
		if not ok then
			logger:error("A progression route errored", {
				kind = kind,
				eventId = event.EventId,
				errorMessage = tostring(appliedOrError),
			})
		end
		granted[kind] = ok and appliedOrError == true
	end

	return { Accepted = true, Refusal = nil, Weight = weight, Granted = granted }
end

function ProgressionSystem.Init(): ()
	if started then
		return
	end
	-- Every route's owner must be up. A comment in Main.server.lua cannot fail a boot.
	assert(MeridianSystem.AwardKillXP ~= nil, "ProgressionSystem.Init() requires MeridianSystem to be available")
	assert(BloodlineSystem.CountKill ~= nil, "ProgressionSystem.Init() requires BloodlineSystem to be available")
	assert(BountySystem.PayClaim ~= nil, "ProgressionSystem.Init() requires BountySystem to be available")
	started = true

	logger:info("ProgressionSystem.Init() complete")
end

-- Forgets every recorded kill. Spec-only, so one case's farming history cannot weight the next's.
function ProgressionSystem.Reset(): ()
	table.clear(recentKills)
end

return ProgressionSystem :: Types.SystemModule & typeof(ProgressionSystem)
