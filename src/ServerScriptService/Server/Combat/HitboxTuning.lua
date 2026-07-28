--!strict
--[[
	HitboxTuning.lua

	Owns: LIVE, IN-MEMORY tuning of hitbox timing (and, for the standalone-attack section near the
	bottom of this file, hitbox forward offset too) -- a Studio-only dev tool (DevMenuSystem.lua's
	ListHitboxStages/AdjustHitboxTiming/ResetHitboxStage, and ListStandaloneAttacks/
	AdjustStandaloneField/ResetStandaloneAttack, actions) that lets an authorized admin nudge a real
	attack's feel while playtesting and immediately feel the result, without stopping and
	restarting the Studio session. Exists because CombatSystem.lua's selectAttackDefinition/
	commitAndThrowAttack/throwDashPunch/throwDashHit and HitboxResolver.lua's Update all read their
	attack definition's fields LIVE, by reference, on every throw/tick -- no snapshot or cache
	anywhere holds a copy -- so mutating a field on that SAME table object here takes effect on the
	very next swing, and even on an ALREADY IN-FLIGHT one: HitboxResolver.Update re-reads
	swing.definition.WindupSeconds/ActiveSeconds every single Heartbeat to recompute the
	active-window boundaries, it never snapshots them at swing-start. (One asymmetry worth knowing:
	CombatSystem.lua's OWN commitment-lock fields -- state.attackEndsAt, state.basicAttackReadyAt/
	heavyAttackReadyAt -- ARE snapshotted as plain numbers at throw time, so a mid-swing edit
	changes when the hitbox samples/ends but NOT when the attacker is allowed to act again for that
	one already-thrown swing; the next swing picks up the new numbers everywhere.)

	Two independent sections, split by how their attack definitions are addressed:
	  * Weapon stages (top half) -- Constants.Combat.Weapons[...].Stages[...], keyed by
	    (weaponId, category, stageIndex). TIMING only (WindupSeconds/ActiveSeconds/
	    RecoverySeconds) -- Damage/PostureDamage/Size/Offset/ArcDegrees/MaxTargets are untouched,
	    this section exists specifically for the animation/hitbox sync work (see CombatAnimator.
	    lua's "Animation/hitbox sync" note), not as a general balance editor.
	  * Standalone attacks (bottom half) -- Constants.Combat.DashPunch/DashHit/AirSlam, which aren't a
	    weapon stage at all (CombatSystem.lua's handleDashRequest/handleAirSlamRequest throw them
	    directly), so they're keyed by Types.StandaloneAttackName instead. ALSO exposes
	    OffsetForwardStuds on top of the same three timing fields -- see Types.HitboxStandaloneInfo's
	    own header for why this section's scope is deliberately wider (these attacks' hand-tracked
	    hitbox position needed hands-on playtesting to dial in, the same way timing did).

	Captures every attack's ORIGINAL values once, lazily, the first time any public function here
	runs (guaranteed to be well after Constants.lua has fully loaded, since the only caller is
	DevMenuSystem.lua's remote handlers, which can't fire before the server has finished booting) --
	so Reset can restore known-good values without a full Studio restart. These captured defaults
	are the ONLY backup that exists: there is no persistence (DataStore) and none is wanted here --
	a fresh Play session always starts from Constants.lua's own file values regardless of anything
	this module did in a previous session, and a satisfying live-tuned result is meant to be copied
	BY HAND back into Constants.lua once found (this module never writes to disk).

	Does not own: authorization or rate-limiting (DevMenuSystem.lua's job, identical to every other
	admin action), or deciding what a "reasonable" value is beyond basic sanity clamping (an admin
	dialing in feel is trusted to know what they're doing -- see the CLAMP_MIN/MAX constants' own
	comments for the only floors/ceilings enforced).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local HitboxTuning = {}

-- Sanity floor/ceiling for every adjustable field -- prevents a fat-fingered or spammed
-- AdjustField from driving a duration to zero/negative (breaks HitboxResolver's Windup/Active-
-- window math and CombatSystem's attackEndsAt arithmetic) or to an absurd multi-second stall. Not
-- a balance opinion -- wide enough to cover any real tuning range, just closed enough that this
-- tool can never hand back a broken swing.
local CLAMP_MIN_SECONDS = 0.01
local CLAMP_MAX_SECONDS = 5

-- Same reasoning as CLAMP_MIN/MAX_SECONDS above, for AdjustStandaloneField's OffsetForwardStuds --
-- wide enough to cover "well behind the attacker" through "a genuine lunge's worth of reach," not
-- a balance opinion, just a floor against a value that would read as broken (a hitbox spawning
-- absurdly far from the character).
local CLAMP_MIN_OFFSET_STUDS = -5
local CLAMP_MAX_OFFSET_STUDS = 10

-- Original Windup/Active/RecoverySeconds per stage, captured once (see ensureDefaultsCaptured) so
-- ResetStage/ResetAll can restore them -- see this file's header for why no other persistence
-- exists. Keyed by the same composite string stageKey() every lookup in this module uses.
type Defaults = { WindupSeconds: number, ActiveSeconds: number, RecoverySeconds: number }
local defaultsByKey: { [string]: Defaults } = {}
local capturedOnce = false

local function stageKey(weaponId: Types.WeaponId, category: Types.HitboxStageCategory, stageIndex: number): string
	return weaponId .. ":" .. category .. ":" .. tostring(stageIndex)
end

local function toStageInfo(
	weaponId: Types.WeaponId,
	category: Types.HitboxStageCategory,
	stageIndex: number,
	definition: Types.HitboxAttackDefinition
): Types.HitboxStageInfo
	return {
		WeaponId = weaponId,
		Category = category,
		StageIndex = stageIndex,
		DebugName = definition.DebugName,
		WindupSeconds = definition.WindupSeconds,
		ActiveSeconds = definition.ActiveSeconds,
		RecoverySeconds = definition.RecoverySeconds,
	}
end

-- Every tunable stage across both weapons, in a stable display order (Primary before Secondary,
-- Basic before Heavy before Finisher, array order within each) -- the one enumeration every other
-- function in this module (capture, resolve, list) is built from, so the order can never drift
-- between them.
local function listStagesUncaptured(): { Types.HitboxStageInfo }
	local result: { Types.HitboxStageInfo } = {}
	for _, weaponId in ipairs({ "Primary", "Secondary" } :: { Types.WeaponId }) do
		local weapon = if weaponId == "Primary"
			then Constants.Combat.Weapons.Primary
			else Constants.Combat.Weapons.Secondary
		for index, definition in ipairs(weapon.Stages.Basic) do
			table.insert(result, toStageInfo(weaponId, "Basic", index, definition))
		end
		for index, definition in ipairs(weapon.Stages.Heavy) do
			table.insert(result, toStageInfo(weaponId, "Heavy", index, definition))
		end
		-- Finisher is a single stage, not an array -- StageIndex 0 marks it (see Types.HitboxStageInfo
		-- and resolveStageTable below, which is the one other place that 0 sentinel is interpreted).
		table.insert(result, toStageInfo(weaponId, "Finisher", 0, weapon.Stages.Finisher))
	end
	return result
end

-- Captures every stage's current (file-default) timing exactly once, on whichever public function
-- runs first -- guaranteed to be before this module has ever mutated anything, since capture and
-- every mutation both only ever happen from within this module's own public functions, and this is
-- the first thing each of them calls.
local function ensureDefaultsCaptured(): ()
	if capturedOnce then
		return
	end
	capturedOnce = true
	for _, info in ipairs(listStagesUncaptured()) do
		defaultsByKey[stageKey(info.WeaponId, info.Category, info.StageIndex)] = {
			WindupSeconds = info.WindupSeconds,
			ActiveSeconds = info.ActiveSeconds,
			RecoverySeconds = info.RecoverySeconds,
		}
	end
end

-- Resolves a (weaponId, category, stageIndex) triple to the LIVE Constants stage table -- the
-- EXACT same table object CombatSystem.lua's selectAttackDefinition/commitAndThrowAttack read, so
-- a mutation here is a mutation there (see this file's header). Returns nil for any out-of-range
-- combination (a bad stageIndex for Basic/Heavy, or a non-zero stageIndex for Finisher) -- callers
-- treat nil as "InvalidRequest" and never index further.
local function resolveStageTable(
	weaponId: Types.WeaponId,
	category: Types.HitboxStageCategory,
	stageIndex: number
): Types.HitboxAttackDefinition?
	local weapon = if weaponId == "Primary"
		then Constants.Combat.Weapons.Primary
		else Constants.Combat.Weapons.Secondary
	if category == "Finisher" then
		if stageIndex ~= 0 then
			return nil
		end
		return weapon.Stages.Finisher
	end
	local stages = if category == "Heavy" then weapon.Stages.Heavy else weapon.Stages.Basic
	if stageIndex < 1 or stageIndex > #stages then
		return nil
	end
	return stages[stageIndex]
end

-- Every tunable stage, current live values -- DevMenuClient.lua fetches this ONCE (on DevMenu open/
-- Start) and caches it locally, cycling a selected index into it; it never re-fetches the whole
-- list, only ever applies the single-stage result of a later Adjust/Reset onto its own cached copy.
function HitboxTuning.ListStages(): { Types.HitboxStageInfo }
	ensureDefaultsCaptured()
	return listStagesUncaptured()
end

-- Mutates ONE timing field on the live stage table by `delta` (clamped to
-- [CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS]) -- see this file's header for why this takes effect
-- immediately, including on an already-in-flight swing of this exact stage. Returns the updated
-- Types.HitboxStageInfo, or nil for an invalid stage reference (caller returns "InvalidRequest").
function HitboxTuning.AdjustField(
	weaponId: Types.WeaponId,
	category: Types.HitboxStageCategory,
	stageIndex: number,
	field: Types.HitboxTimingField,
	delta: number
): Types.HitboxStageInfo?
	ensureDefaultsCaptured()
	local definition = resolveStageTable(weaponId, category, stageIndex)
	if not definition then
		return nil
	end
	if field == "WindupSeconds" then
		definition.WindupSeconds = math.clamp(definition.WindupSeconds + delta, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	elseif field == "ActiveSeconds" then
		definition.ActiveSeconds = math.clamp(definition.ActiveSeconds + delta, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	else
		definition.RecoverySeconds =
			math.clamp(definition.RecoverySeconds + delta, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	end
	return toStageInfo(weaponId, category, stageIndex, definition)
end

-- Restores ONE stage's three timing fields to their captured file defaults. Returns the restored
-- Types.HitboxStageInfo, or nil for an invalid stage reference.
function HitboxTuning.ResetStage(
	weaponId: Types.WeaponId,
	category: Types.HitboxStageCategory,
	stageIndex: number
): Types.HitboxStageInfo?
	ensureDefaultsCaptured()
	local definition = resolveStageTable(weaponId, category, stageIndex)
	if not definition then
		return nil
	end
	local defaults = defaultsByKey[stageKey(weaponId, category, stageIndex)]
	if not defaults then
		return nil
	end
	definition.WindupSeconds = defaults.WindupSeconds
	definition.ActiveSeconds = defaults.ActiveSeconds
	definition.RecoverySeconds = defaults.RecoverySeconds
	return toStageInfo(weaponId, category, stageIndex, definition)
end

--
-- Standalone-attack live tuning -- DashPunch/DashHit (CombatSystem.lua's handleDashRequest) and
-- AirSlam (handleAirSlamRequest) aren't a weapon combo stage, so they don't fit the (weaponId,
-- category, stageIndex) key the section above is built around; keyed by Types.StandaloneAttackName
-- instead. Same live-mutation guarantee as the weapon-stage tool above (throwDashPunch/throwDashHit/
-- throwAirSlam read Constants.Combat.DashPunch/DashHit/AirSlam by reference on every throw, never a
-- cached copy), and the
-- same capture-once/reset-to-captured-default shape -- but this section ALSO exposes
-- OffsetForwardStuds (see Types.HitboxStandaloneInfo's own header for why this tool's scope is
-- deliberately wider than the weapon-stage one).
--

-- Original Windup/Active/RecoverySeconds/OffsetForwardStuds per standalone attack, captured once
-- (mirrors defaultsByKey above) so ResetStandaloneAttack can restore them.
type StandaloneDefaults = {
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	OffsetForwardStuds: number,
}
local standaloneDefaultsByName: { [string]: StandaloneDefaults } = {}
local standaloneCapturedOnce = false

local STANDALONE_ATTACK_NAMES: { Types.StandaloneAttackName } = { "DashPunch", "DashHit", "AirSlam" }

local function resolveStandaloneDefinition(name: Types.StandaloneAttackName): Types.HitboxAttackDefinition
	if name == "DashPunch" then
		return Constants.Combat.DashPunch
	elseif name == "DashHit" then
		return Constants.Combat.DashHit
	end
	return Constants.Combat.AirSlam
end

-- Converts DashPunch/DashHit's Offset (a CFrame) to a plain forward-studs number for display/
-- adjustment -- ASSUMES Offset is a pure translation with no rotation component, true for both
-- attacks as of this writing (CFrame.new(0, 0, z), never CFrame.new(...) * CFrame.Angles(...)).
-- Reads the local Z translation directly (negative Z is "in front" per Roblox's own -Z-forward
-- convention) and negates it so this tool's own number reads as "studs forward" the way an admin
-- would expect, matching AdjustStandaloneField's inverse conversion below. If a future retune ever
-- gives either Offset a rotation component, this (and the inverse write below) would need
-- revisiting -- not a concern today, and out of scope for what this dev-only tool needs to handle.
local function offsetForwardStuds(definition: Types.HitboxAttackDefinition): number
	return -definition.Offset.Z
end

local function toStandaloneInfo(
	name: Types.StandaloneAttackName,
	definition: Types.HitboxAttackDefinition
): Types.HitboxStandaloneInfo
	return {
		Name = name,
		DebugName = definition.DebugName,
		WindupSeconds = definition.WindupSeconds,
		ActiveSeconds = definition.ActiveSeconds,
		RecoverySeconds = definition.RecoverySeconds,
		OffsetForwardStuds = offsetForwardStuds(definition),
	}
end

local function listStandaloneAttacksUncaptured(): { Types.HitboxStandaloneInfo }
	local result: { Types.HitboxStandaloneInfo } = {}
	for _, name in ipairs(STANDALONE_ATTACK_NAMES) do
		table.insert(result, toStandaloneInfo(name, resolveStandaloneDefinition(name)))
	end
	return result
end

local function ensureStandaloneDefaultsCaptured(): ()
	if standaloneCapturedOnce then
		return
	end
	standaloneCapturedOnce = true
	for _, info in ipairs(listStandaloneAttacksUncaptured()) do
		standaloneDefaultsByName[info.Name] = {
			WindupSeconds = info.WindupSeconds,
			ActiveSeconds = info.ActiveSeconds,
			RecoverySeconds = info.RecoverySeconds,
			OffsetForwardStuds = info.OffsetForwardStuds,
		}
	end
end

-- Both tunable standalone attacks, current live values -- same "fetch once, cache client-side"
-- contract as ListStages above.
function HitboxTuning.ListStandaloneAttacks(): { Types.HitboxStandaloneInfo }
	ensureStandaloneDefaultsCaptured()
	return listStandaloneAttacksUncaptured()
end

-- Mutates ONE field on the live attack definition by `delta` -- the three timing fields clamp to
-- the same [CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS] range AdjustField uses; OffsetForwardStuds
-- clamps to [CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS] and is written back as a fresh
-- pure-translation CFrame (see offsetForwardStuds' own header for the assumption this relies on).
-- Returns the updated Types.HitboxStandaloneInfo.
function HitboxTuning.AdjustStandaloneField(
	name: Types.StandaloneAttackName,
	field: Types.HitboxStandaloneField,
	delta: number
): Types.HitboxStandaloneInfo?
	ensureStandaloneDefaultsCaptured()
	local definition = resolveStandaloneDefinition(name)
	if field == "WindupSeconds" then
		definition.WindupSeconds = math.clamp(definition.WindupSeconds + delta, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	elseif field == "ActiveSeconds" then
		definition.ActiveSeconds = math.clamp(definition.ActiveSeconds + delta, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	elseif field == "RecoverySeconds" then
		definition.RecoverySeconds =
			math.clamp(definition.RecoverySeconds + delta, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	else
		local newForwardStuds =
			math.clamp(offsetForwardStuds(definition) + delta, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS)
		definition.Offset = CFrame.new(0, 0, -newForwardStuds)
	end
	return toStandaloneInfo(name, definition)
end

-- Restores ONE standalone attack's timing AND offset to its captured file defaults. Returns the
-- restored Types.HitboxStandaloneInfo, or nil if defaults were somehow never captured (can't
-- actually happen -- ensureStandaloneDefaultsCaptured always runs first -- but matches ResetStage's
-- own defensive nil-check shape).
function HitboxTuning.ResetStandaloneAttack(name: Types.StandaloneAttackName): Types.HitboxStandaloneInfo?
	ensureStandaloneDefaultsCaptured()
	local definition = resolveStandaloneDefinition(name)
	local defaults = standaloneDefaultsByName[name]
	if not defaults then
		return nil
	end
	definition.WindupSeconds = defaults.WindupSeconds
	definition.ActiveSeconds = defaults.ActiveSeconds
	definition.RecoverySeconds = defaults.RecoverySeconds
	definition.Offset = CFrame.new(0, 0, -defaults.OffsetForwardStuds)
	return toStandaloneInfo(name, definition)
end

return HitboxTuning
