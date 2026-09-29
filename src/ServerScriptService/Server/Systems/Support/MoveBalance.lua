--!strict
--[[
	MoveBalance.lua

	Owns: the numbers an author balances a move against that are not typed into it -- frame data (startup,
	active, recovery, advantage on hit and on block), how many hits kill or break a guard, damage per
	second -- and the two clip-derived facts the Move Editor's Timing tab needs: where the clip's strike
	marker lands in swing time, and which authored windup/recovery would make the authored timeline equal
	the clip-synced one ("Match timing to clip").

	PURE, AND FED BY THE REAL MODULES. Every constant is read from the module that owns it at call time --
	DamageResolver's combo curve and hitstun, GuardMeter's drain, DefenseConstants' pool -- never copied.
	A readout that restated a formula would be right until the day someone retuned the real one, which is
	exactly the "looks right in the editor, plays differently" failure the rebuild exists to end.

	Server-only because two of its inputs are (DamageResolver, GuardMeter). The Balance TYPE is
	Shared/Authoring/MoveEditorTypes', because the client renders it.

	EVERYTHING READS THE EFFECTIVE TIMELINE (AttackCatalog's, after the clip has had its say), never the
	authored one: frame data for numbers the swing does not actually use would be fiction.

	Does not own: building that timeline (AttackCatalog.Get), the entry it rides on (MoveEditorSystem), or
	how any of it is shown (Client/UI/Screens/DevTools/MoveEditor/Readout.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local DamageResolver = require(script.Parent.Parent.Parent.Combat.Damage.DamageResolver)
local GuardMeter = require(script.Parent.Parent.Parent.Combat.Defense.GuardMeter)

type Balance = MoveEditorTypes.Balance
type ClipMatch = MoveEditorTypes.ClipMatch
type EffectiveTiming = MoveEditorTypes.EffectiveTiming
type MoveDefinition = MoveTypes.MoveDefinition

local MoveBalance = {}

-- Float slack for "exactly divides": 100 / 12.5 must count as 8 hits, not 9.
local EPSILON = 1e-9

-- A string that never kills stops being counted here rather than looping forever on a 0.001 damage move.
local MAX_COUNTED_HITS = 10000

local function frames(seconds: number, frameRate: number): number
	return math.floor(seconds * frameRate + 0.5)
end

-- Hits of `perHit` needed to empty `pool`, or nil for "never".
local function hitsToEmpty(pool: number, perHit: number): number?
	if perHit ~= perHit or perHit <= 0 then
		return nil
	end
	return math.max(1, math.ceil(pool / perHit - EPSILON))
end

-- A positive multiplier as AttackCatalog sanitises it: anything else is 1.
local function multiplier(value: number?): number
	if typeof(value) ~= "number" or value ~= value or (value :: number) <= 0 then
		return 1
	end
	return value :: number
end

-- Hits to kill when each successive hit is one combo stage deeper -- DamageResolver.ComboMultiplier is
-- the curve, stage 1 is exactly the authored damage, and the stage holds at its cap.
local function stringHitsToKill(damage: number, health: number): number?
	if damage ~= damage or damage <= 0 then
		return nil
	end
	local dealt = 0
	for hit = 1, MAX_COUNTED_HITS do
		dealt += damage * DamageResolver.ComboMultiplier(hit)
		if dealt >= health - EPSILON then
			return hit
		end
	end
	return nil
end

-- Frame data and balance numbers for `move` swung on `effective`'s timeline.
--
-- Advantage counts from the moment of contact. On hit, the defender is stunned for
-- DamageConstants.Hitstun.Seconds while the attacker still owes whatever is left of their active window
-- and their recovery; Min puts the contact on the first active frame (the attacker's worst case), Max on
-- the last. On block there is NO blockstun (DamageResolver: a Blocked contact applies none), so the
-- defender acts at once and the numbers are simply minus the attacker's remaining commitment.
function MoveBalance.Compute(effective: EffectiveTiming, move: MoveDefinition): Balance
	local frameRate = Constants.MoveEditor.FrameRate
	local hitstun = DamageConstants.Hitstun.Seconds
	local windup, active, recovery = effective.WindupSeconds, effective.ActiveSeconds, effective.RecoverySeconds
	local totalSeconds = windup + active + recovery

	local powerLevel = MoveTypes.PowerLevelOf(move)
	local guardPool = DefenseConstants.Guard.Max
	-- The player pool: CombatConstants.MaxHealth is the Humanoid default every player character keeps.
	-- Dummies and bots carry more (DebugConstants/TrainingBotConstants), which is not the reference.
	local health = CombatConstants.MaxHealth

	local startupFrames = frames(windup, frameRate)
	local activeFrames = frames(active, frameRate)
	local recoveryFrames = frames(recovery, frameRate)

	return {
		FrameRate = frameRate,
		StartupFrames = startupFrames,
		ActiveFrames = activeFrames,
		RecoveryFrames = recoveryFrames,
		TotalFrames = startupFrames + activeFrames + recoveryFrames,
		CooldownFrames = frames(effective.Cooldown, frameRate),
		OnHitFrames = {
			Min = frames(hitstun - (active + recovery), frameRate),
			Max = frames(hitstun - recovery, frameRate),
		},
		OnBlockFrames = {
			Min = -frames(active + recovery, frameRate),
			Max = -frames(recovery, frameRate),
		},
		HitsToKill = hitsToEmpty(health, move.Damage),
		StringHitsToKill = stringHitsToKill(move.Damage, health),
		BlockedHitsToBreakGuard = hitsToEmpty(guardPool, GuardMeter.DrainFor(powerLevel, false)),
		StaggeredBlocksToBreakGuard = hitsToEmpty(guardPool, GuardMeter.DrainFor(powerLevel, true)),
		CleanHitsToBreakGuard = hitsToEmpty(
			guardPool,
			move.PostureDamage * DamageConstants.Guard.PressurePerPostureDamage
		),
		DamagePerSecond = move.Damage / math.max(totalSeconds, effective.Cooldown, EPSILON),
	}
end

-- Where the clip's strike marker lands in swing time: AttackCatalog plays the clip at `playbackSpeed`
-- (weapon speed x tempo, or a borrowed clip's retime) and adds the weapon's spawn delay after it.
-- `markerSeconds` is in CLIP time, as AttackWindows.WindupOverride returns it.
function MoveBalance.StrikeSeconds(move: MoveDefinition, markerSeconds: number, playbackSpeed: number): number
	return markerSeconds / multiplier(playbackSpeed) + math.max(move.SpawnDelaySeconds or 0, 0)
end

-- The authored WindupSeconds/RecoverySeconds under which AttackCatalog builds the same timeline whether
-- or not it knows the clip's length -- i.e. the authored numbers stop disagreeing with the clip. nil when
-- the clip's length is unknown, or so long the engine refuses to sync to it.
--
-- Derived from AttackCatalog.Get (re-derive it if that changes; MoveBalance.spec pins the equivalence by
-- running both timelines through the real catalogue). With ws = WeaponSpeed, t = Tempo, s = SpawnDelay,
-- A = ActiveSeconds and a marker m (clip seconds):
--   windup:   the catalogue swings W/t + s authored, m/(ws*t) + s off a marker -> equal when W = m/ws.
--             With no marker the windup is already the authored one and is kept.
--   recovery: unknown clip -> R/t; known clip of length L -> L/(ws*t) - (strike + A), where strike is
--             the windup above. Equal when R = L/ws - t*(strike + A).
-- Recovery is clamped to Limits.PhaseSeconds like any authored phase. When the clip ends before the hit
-- window does, the clamp holds it at the minimum and the entry's own note already says why.
function MoveBalance.MatchClip(move: MoveDefinition, markerSeconds: number?, clipLength: number?): ClipMatch?
	if clipLength == nil or clipLength ~= clipLength or clipLength <= 0 then
		return nil
	end
	local weaponSpeed = multiplier(move.WeaponSpeed)
	local tempo = multiplier(move.Tempo)
	if clipLength / (weaponSpeed * tempo) > HitboxEngineConstants.MaxSwingSeconds then
		return nil
	end
	local phase = Constants.MoveEditor.Limits.PhaseSeconds
	local spawnDelay = math.max(move.SpawnDelaySeconds or 0, 0)

	local windup = if markerSeconds then markerSeconds / weaponSpeed else move.WindupSeconds
	local strike = windup / tempo + spawnDelay
	local recovery = clipLength / weaponSpeed - tempo * (strike + move.ActiveSeconds)
	return {
		WindupSeconds = math.clamp(windup, phase.Min, phase.Max),
		RecoverySeconds = math.clamp(recovery, phase.Min, phase.Max),
	}
end

return MoveBalance
