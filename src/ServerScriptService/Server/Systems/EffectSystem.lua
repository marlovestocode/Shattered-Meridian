--!strict
--[[
	EffectSystem.lua

	Owns: the generic modifier engine the Race Traits + Bloodline Abilities plan builds as reusable
	foundational work -- Types.ActiveModifierSpec in, Types.ActiveModifier tracked, out through this
	module's own read API. Content-agnostic by design: this file has no notion of "race" or
	"bloodline" anywhere in it, the same way HitboxEngine has no notion of which move threw a swing.
	RaceSystem/BloodlineSystem (later phases of that plan) are its only intended callers, but nothing
	here imports or references either.

	THREE MODIFIER LIFETIMES (Types.ActiveModifierLifetime's own header has the full contract; this is
	the runtime side of it):
	  * "Instant" -- applied once, never tracked afterward. v1's only target is Kind == "QiRestore",
	    which calls QiSystem.Restore below and returns immediately -- see EffectSystem.Apply.
	  * "Timed" -- tracked with an ExpiresAt, reclaimed by this module's own GameplayEvents.
	    OnHeartbeatTick sweep. What an Active kit ability's buff uses.
	  * "Bound" -- tracked with no timer, added/removed only via SetBoundModifiers' atomic replace,
	    never touched by the tick sweep. What a Passive kit ability uses.

	THREE EFFECT KINDS (Types.ActiveModifierKind's own header has the full contract):
	  * "AttributeDelta" -- summed by GetAttributeDelta, the ready seam a future QiSystem.ComputeMaxQi-
	    style derivation point for Fortitude/Might/Pressure/Fleetness would read from. NOT wired into
	    any gameplay math this pass -- see the Race Traits + Bloodline Abilities plan's own non-goals.
	  * "Tag" -- an opaque marker queried via HasTag/GetTagMagnitude, for a future system to key a
	    check off without EffectSystem needing to know what the tag means.
	  * "QiRestore" -- Instant-only (see above); grants Qi through QiSystem.Restore.

	PERSISTENCE: none, and none is planned. Every precedent in this codebase (Qi, Health, Posture,
	CombatState) is combat/session state rebuilt fresh on load; only permanent progression persists.
	A "Timed" modifier is lost on rejoin like any other mid-fight resource. A "Bound" modifier is
	fully re-derivable from already-persisted facts (a race trait from profile.raceId + tier, a
	bloodline stage from profile.bloodlineIds + bloodlineStageProgress) -- RaceSystem/BloodlineSystem
	are expected to simply re-push SetBoundModifiers from scratch on PlayerDataSystem.OnProfileLoaded,
	not to have this module remember anything across a rejoin.

	Per-player state seeds LAZILY on first Apply/SetBoundModifiers call, unlike QiSystem's own
	OnProfileLoaded-seeded table -- deliberately: QiSystem has real profile-derived values (tier,
	MeridianFlow) to seed max/regen with, where this module's per-player table starts, and would stay,
	empty for a player nothing has ever granted a modifier to. Seeding on demand means there is no
	"called before seeded, silently does nothing" footgun for a caller that races EffectSystem's own
	Init() -- there is nothing to race, since nothing needs seeding.

	Does not own: content-specific eligibility (which trait/stage a player currently qualifies for --
	RaceSystem/BloodlineSystem), the trigger/remote path that resolves a player's request into a
	CanUseAbility/UseAbility call (KitAbilitySystem, a later phase), or QiSystem's own resource
	(QiSystem.Restore lives there, called from here -- see this file's Apply for the one narrow seam).
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local QiSystem = require(script.Parent.QiSystem)

local logger = Logger.scope("EffectSystem")

local EffectSystem = {}

-- Per-player live modifier table, keyed by ActiveModifier.Id for O(1) Clear -- the same "auxiliary
-- per-player table, never exposed directly" shape QiSystem.lua's own qiStates already establishes;
-- see GetActiveModifiers below for why every read hands back a copy instead of this table's own
-- references.
local playerModifiers: { [Player]: { [string]: Types.ActiveModifier } } = {}

local function ensureState(player: Player): { [string]: Types.ActiveModifier }
	local state = playerModifiers[player]
	if not state then
		state = {}
		playerModifiers[player] = state
	end
	return state
end

-- Deep-enough copy of one ActiveModifier -- Spec is the one nested table this shape carries (Types.
-- ActiveModifierSpec's own header), so a one-level table.clone plus one more for Spec is sufficient,
-- the same "no third level of nesting" reasoning PlayerDataSystem.CopyProfile's own header gives for
-- an identically shallow shape.
local function cloneModifier(modifier: Types.ActiveModifier): Types.ActiveModifier
	local clone = table.clone(modifier)
	clone.Spec = table.clone(modifier.Spec)
	return clone
end

-- Applies ONE modifier spec to `player`, attributed to (sourceKind, sourceId). Valid for
-- Lifetime == "Instant"/"Timed" only -- a "Bound" spec is refused with a warning: SetBoundModifiers
-- below is the only correct way to manage a grant that must last exactly as long as it holds true,
-- and letting Apply track one individually would leave it invisible to that function's own diff on
-- the next recompute.
--
-- Returns the new ActiveModifier's Id for a "Timed" spec (what a caller would pass to Clear), or nil
-- for an "Instant" spec -- never tracked, per this file's own header -- or on refusal.
function EffectSystem.Apply(
	player: Player,
	sourceKind: Types.ActiveModifierSource,
	sourceId: string,
	spec: Types.ActiveModifierSpec
): string?
	if spec.Lifetime == "Bound" then
		logger:warn("Apply refused a Bound-lifetime spec -- use SetBoundModifiers instead", {
			player = player.Name,
			sourceKind = sourceKind,
			sourceId = sourceId,
		})
		return nil
	end

	if spec.Lifetime == "Instant" then
		if spec.Kind == "QiRestore" then
			if typeof(spec.QiRestoreAmount) == "number" and spec.QiRestoreAmount > 0 then
				QiSystem.Restore(player, spec.QiRestoreAmount)
			end
		else
			logger:warn("Apply refused an Instant spec with no supported effect -- v1 only supports QiRestore", {
				player = player.Name,
				sourceKind = sourceKind,
				sourceId = sourceId,
				kind = spec.Kind,
			})
		end
		return nil
	end

	-- spec.Lifetime == "Timed" from here on -- the only remaining case Types.ActiveModifierLifetime
	-- allows.
	local state = ensureState(player)
	local id = HttpService:GenerateGUID(false)
	local now = os.clock()
	state[id] = {
		Id = id,
		Spec = spec,
		SourceKind = sourceKind,
		SourceId = sourceId,
		AppliedAt = now,
		ExpiresAt = now + (spec.DurationSeconds or 0),
	}
	return id
end

-- The only way a "Bound" modifier is created, refreshed, or removed. Removes every PREVIOUS Bound
-- modifier this exact (sourceKind, sourceId) held on `player`, then adds back the given set -- a full
-- replace rather than a field-by-field diff, since a spec carries no stable identity of its own to
-- diff against (two structurally-identical grants from the same source are indistinguishable, and
-- don't need to be). Callers always pass their FULL current set, never an incremental delta -- this
-- is what RaceSystem/BloodlineSystem call every time eligibility is recomputed (a tier-up, a stage
-- advance, a profile load).
--
-- A non-"Bound" entry in `specs` is dropped with a warning rather than silently mis-tracked -- the
-- same defensive-decode posture PlayerDataSystem.DecodeProfile takes for a malformed persisted field.
function EffectSystem.SetBoundModifiers(
	player: Player,
	sourceKind: Types.ActiveModifierSource,
	sourceId: string,
	specs: { Types.ActiveModifierSpec }
): ()
	local state = ensureState(player)

	for id, modifier in state do
		if
			modifier.SourceKind == sourceKind
			and modifier.SourceId == sourceId
			and modifier.Spec.Lifetime == "Bound"
		then
			state[id] = nil
		end
	end

	local now = os.clock()
	for _, spec in specs do
		if spec.Lifetime ~= "Bound" then
			logger:warn("SetBoundModifiers dropped a non-Bound spec", {
				player = player.Name,
				sourceKind = sourceKind,
				sourceId = sourceId,
				lifetime = spec.Lifetime,
			})
		else
			local id = HttpService:GenerateGUID(false)
			state[id] = {
				Id = id,
				Spec = spec,
				SourceKind = sourceKind,
				SourceId = sourceId,
				AppliedAt = now,
				ExpiresAt = nil,
			}
		end
	end
end

-- Removes ONE specific tracked modifier by Id, regardless of its lifetime. Returns true if it was
-- present and removed. The low-level primitive both ClearAllFromSource below and a future ability's
-- own early-cancel path (e.g. dispelling a Timed buff before it expires) build on.
function EffectSystem.Clear(player: Player, id: string): boolean
	local state = playerModifiers[player]
	if not state or not state[id] then
		return false
	end
	state[id] = nil
	return true
end

-- Removes every modifier -- Timed AND Bound alike -- currently tracked from (sourceKind, sourceId) on
-- `player`. The coarse "this source no longer grants anything at all" primitive, distinct from
-- SetBoundModifiers' own per-recompute diff (which only ever touches Bound entries): a future
-- bloodline-revocation path, or a test asserting a source's footprint is fully gone, wants this one
-- instead. Returns how many were removed.
function EffectSystem.ClearAllFromSource(
	player: Player,
	sourceKind: Types.ActiveModifierSource,
	sourceId: string
): number
	local state = playerModifiers[player]
	if not state then
		return 0
	end
	local removed = 0
	for id, modifier in state do
		if modifier.SourceKind == sourceKind and modifier.SourceId == sourceId then
			state[id] = nil
			removed += 1
		end
	end
	return removed
end

-- Sums Delta across every currently-tracked modifier (any lifetime -- an Instant one is never
-- tracked, so it can never appear here regardless) whose Spec.Kind == "AttributeDelta" and
-- Spec.AttributeKey == key. The ready seam a future QiSystem.ComputeMaxQi-style derivation point for
-- Fortitude/Might/Pressure/Fleetness reads from -- not called by anything yet, per this file's header.
function EffectSystem.GetAttributeDelta(player: Player, key: Types.ActiveModifierAttributeKey): number
	local state = playerModifiers[player]
	if not state then
		return 0
	end
	local total = 0
	for _, modifier in state do
		if modifier.Spec.Kind == "AttributeDelta" and modifier.Spec.AttributeKey == key then
			total += modifier.Spec.Delta or 0
		end
	end
	return total
end

-- True if `player` currently holds ANY modifier tagged `tag`, regardless of its Magnitude -- presence
-- and strength are deliberately separate questions (Types.ActiveModifierSpec's own header), so a
-- Magnitude of 0 still answers true here.
function EffectSystem.HasTag(player: Player, tag: string): boolean
	local state = playerModifiers[player]
	if not state then
		return false
	end
	for _, modifier in state do
		if modifier.Spec.Kind == "Tag" and modifier.Spec.Tag == tag then
			return true
		end
	end
	return false
end

-- Sums Magnitude across every currently-tracked modifier tagged `tag` -- lets several stacking grants
-- of the same tag (from different sources) combine into one strength rather than each shadowing the
-- last. 0 if `player` holds none.
function EffectSystem.GetTagMagnitude(player: Player, tag: string): number
	local state = playerModifiers[player]
	if not state then
		return 0
	end
	local total = 0
	for _, modifier in state do
		if modifier.Spec.Kind == "Tag" and modifier.Spec.Tag == tag then
			total += modifier.Spec.Magnitude or 0
		end
	end
	return total
end

-- Read-only snapshot of every modifier currently tracked for `player`, for replication/inspection --
-- never the live table itself, and never a live modifier's own reference, per cloneModifier above.
-- The same "read-only projection, never the live mutable state" contract CombatSystem.GetCombatState/
-- PlayerDataSystem.GetProfile already establish for their own per-player state.
function EffectSystem.GetActiveModifiers(player: Player): { Types.ActiveModifier }
	local snapshot: { Types.ActiveModifier } = {}
	local state = playerModifiers[player]
	if not state then
		return snapshot
	end
	for _, modifier in state do
		table.insert(snapshot, cloneModifier(modifier))
	end
	return snapshot
end

-- Reclaims every expired "Timed" modifier, across every player. `now` is taken as a parameter rather
-- than read internally via os.clock() -- the same "pure decision logic takes the clock as an
-- argument" contract PlayerDataSystem.IsLockHeldByOther already establishes -- specifically so a spec
-- can trigger a deterministic sweep without a live Heartbeat connection or a real wait; see this
-- file's own EffectSystem.spec.lua. Exported for that reason, the same "pure logic gets its own
-- export" precedent PlayerDataSystem.ApplyMutation/BugReportSystem.ValidateCategory already
-- established -- onHeartbeatTick below is the only thing that actually calls this from a live frame,
-- and nothing about the reclaim logic itself depends on being called from there.
--
-- A "Bound" modifier has no ExpiresAt (nil, checked below) and is therefore never touched here,
-- exactly as this file's header says: it is added/removed only by SetBoundModifiers. A plain full
-- walk rather than Shared/AmortizedReclaim.lua -- that module is for reclaiming entries tied to a
-- despawned Model with no other per-entry work, a different problem shape than a small per-player set
-- of TTL'd modifiers, and typical modifier counts per player are small enough that the same "walk
-- every player every tick" QiSystem.lua's own onHeartbeatTick already does is the right tool here too.
function EffectSystem.ReclaimExpiredModifiers(now: number): ()
	for _, state in playerModifiers do
		for id, modifier in state do
			if modifier.ExpiresAt and now >= modifier.ExpiresAt then
				state[id] = nil
			end
		end
	end
end

-- How often the reclaim sweep above actually runs, and how long since it last did.
--
-- The sweep used to run at 60 Hz, walking every player's whole modifier set to drop entries that had
-- expired -- and NOTHING reads the result of that promptness. Every reader of a modifier already
-- compares its own `now` against ExpiresAt (that is the contract that makes an expired-but-not-yet-
-- reclaimed modifier invisible), which is exactly the argument Server/Combat/Damage/DamageSystem.lua
-- uses to amortize its own reclaim. So the sweep is bookkeeping, not behaviour: running it four times
-- a second instead of sixty leaves at most a quarter-second of dead table entries lying around and
-- changes no answer anybody can observe.
--
-- Deliberately still a full walk when it does run, not Shared/AmortizedReclaim.lua -- see
-- ReclaimExpiredModifiers' own comment on why a small per-player TTL set is a different problem shape
-- from a per-Model map keyed on despawned instances.
local RECLAIM_INTERVAL_SECONDS = 0.25
local secondsSinceReclaim = 0

local function onHeartbeatTick(deltaTime: number): ()
	secondsSinceReclaim += deltaTime
	if secondsSinceReclaim < RECLAIM_INTERVAL_SECONDS then
		return
	end
	secondsSinceReclaim = 0
	EffectSystem.ReclaimExpiredModifiers(os.clock())
end

local function onPlayerRemoving(player: Player): ()
	playerModifiers[player] = nil
end

function EffectSystem.Init(): ()
	playerModifiers = {}
	-- Reset alongside the state it sweeps, so an idempotent re-Init cannot inherit a partly-elapsed
	-- interval from the previous one.
	secondsSinceReclaim = 0

	PlayerLifecycle.BindAllPlayers({ Scope = "EffectSystem", OnPlayerRemoving = onPlayerRemoving })
	GameplayEvents.OnHeartbeatTick(onHeartbeatTick)

	logger:info("EffectSystem.Init() complete")
end

return EffectSystem :: Types.SystemModule
