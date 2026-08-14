--!strict
--[[
	HealthRegen.lua

	Owns: the arithmetic of passive health regeneration -- how fast a player recovers given how long
	they have been out of combat, and what that means for this tick's health value.

	Pure by construction: no Instances, no Players, no state of its own, no clock. Every input is a
	number passed in and the only output is the health this tick should end at. That is what lets the
	ramp curve, the ceiling and the whole family of edge cases (dying, already full, a stalled frame,
	a NaN delta) be specced directly, instead of being reachable only through a live CombatSystem with
	a real character and a real Heartbeat -- the same "extract the logic into a Server/Combat/ sibling
	and spec that" split the rest of this folder already follows.

	Does not own: WHEN regen is allowed to run. That is a gameplay-eligibility question with several
	inputs that are not arithmetic (is the player alive, is the body ragdolled or stunned, is the
	server currently holding root control), and it stays at the one call site in CombatSystem's tick
	that can see all of them. This module answers only "given that regen may run, how much." It also
	does not own the tuning numbers -- Constants.Combat.HealthRegen owns every one of those and
	documents the reasoning behind each.

	Does not write anything, either: the caller assigns Humanoid.Health, because Humanoid.Health is
	this game's authoritative health value (see CombatSystem.lua's header on why health, unlike
	posture, is not double-tracked as a separate number).
]]

local HealthRegen = {}

-- The subset of Constants.Combat.HealthRegen this module reads -- its own type rather than the whole
-- constants table, the same shape ParkourValidation.ValidationConfig and ObstacleClassifier.
-- ClassifierConfig already use, so a spec can hand in blunt round numbers instead of the shipped
-- tuning.
export type RegenConfig = {
	Enabled: boolean,
	StartFractionPerSecond: number,
	FullFractionPerSecond: number,
	RampSeconds: number,
	MaxFractionOfMax: number,
}

-- Smoothstep. Zero derivative at BOTH ends, which is the entire reason it is here rather than a plain
-- linear interpolation: the ramp is watched at exactly its two joins -- the moment regen begins and
-- the moment it reaches full rate -- and a linear ramp corners visibly at both. Cheap enough to be
-- uninteresting at one call per player per tick.
local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

-- The regen rate, in health per second, for a player who has been out of combat for
-- `secondsOutOfCombat`. Eases from StartFractionPerSecond to FullFractionPerSecond across
-- RampSeconds, then holds.
--
-- A non-positive `secondsOutOfCombat` means the in-combat window has not lapsed yet and the answer is
-- a hard zero -- the ramp is not merely at its floor during combat, it is off.
function HealthRegen.ComputeRatePerSecond(secondsOutOfCombat: number, maxHealth: number, config: RegenConfig): number
	if not config.Enabled then
		return 0
	end
	-- Self-inequality is the NaN test. A NaN here would otherwise fall through every comparison below
	-- and produce a NaN rate, which then poisons Humanoid.Health -- and a NaN health is unrecoverable
	-- without a respawn, because every clamp that would normally rescue it also returns NaN.
	if secondsOutOfCombat ~= secondsOutOfCombat or secondsOutOfCombat <= 0 then
		return 0
	end
	if maxHealth ~= maxHealth or maxHealth <= 0 then
		return 0
	end

	-- A RampSeconds of zero is a legitimate tuning choice ("no ramp, full rate immediately") and must
	-- not divide by zero into a NaN alpha.
	local alpha = if config.RampSeconds > 0 then math.clamp(secondsOutOfCombat / config.RampSeconds, 0, 1) else 1

	local fraction = config.StartFractionPerSecond
		+ (config.FullFractionPerSecond - config.StartFractionPerSecond) * smoothstep(alpha)
	return fraction * maxHealth
end

-- The health value this tick should end at, given the current health and how long the player has been
-- out of combat. Returns `currentHealth` unchanged whenever no regen is owed, so the caller's
-- "did anything actually change" test is a plain comparison and no separate eligibility flag has to
-- be threaded back.
--
-- Never decreases health under any input. That is a hard guarantee this function owes its caller:
-- CombatSystem assigns the result straight onto Humanoid.Health every tick, so a bug that returned
-- something lower than it was handed would silently become passive DAMAGE that no hit registered, no
-- feedback event explained, and no death attribution could account for. The MaxFractionOfMax ceiling
-- is therefore applied as a floor-guarded clamp rather than a plain min: a player already above the
-- ceiling (healed there by some other source, or a ceiling retuned downward mid-session) is left
-- exactly where they are rather than being dragged down to it.
function HealthRegen.ComputeHealedHealth(
	currentHealth: number,
	maxHealth: number,
	secondsOutOfCombat: number,
	deltaTime: number,
	config: RegenConfig
): number
	if currentHealth ~= currentHealth or maxHealth ~= maxHealth then
		return currentHealth
	end
	-- Dead or dying bodies do not regenerate. Guarded here rather than left to the caller because a
	-- character sitting at exactly 0 between the killing blow and confirmDeath is a real window, and
	-- healing out of it would resurrect someone the death pipeline has already committed to.
	if currentHealth <= 0 then
		return currentHealth
	end
	-- A non-positive or NaN delta contributes nothing. Both are real: Heartbeat can hand back a zero
	-- delta on a stalled frame, and a paused/resumed session can produce worse.
	if deltaTime ~= deltaTime or deltaTime <= 0 then
		return currentHealth
	end

	local ceiling = maxHealth * config.MaxFractionOfMax
	if currentHealth >= ceiling then
		return currentHealth
	end

	local rate = HealthRegen.ComputeRatePerSecond(secondsOutOfCombat, maxHealth, config)
	if rate <= 0 then
		return currentHealth
	end

	return math.min(currentHealth + rate * deltaTime, ceiling)
end

return HealthRegen
