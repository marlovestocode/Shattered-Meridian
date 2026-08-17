--!strict
--[[
	GuardMeter.lua

	Owns: one combatant's guard pool -- what a blocked hit costs it, when it refills, and the moment
	it empties.

	WHY A METER AT ALL. A block with no cost is a turtle strategy, and a turtle strategy is what makes
	a defensive system boring rather than tense. The meter is what turns "should I block" from a
	reflex into a budget: blocking answers one exchange and loses a sustained one, so the player has
	to eventually do something else. The something else is the parry, which is why a successful parry
	is the largest single source of guard in the system -- see DefenseConstants.Guard.ParryRestore.

	SPLIT INTO PURE MATH AND A HOLDER, deliberately. DrainFor/ApplyDrain are static and take
	everything they need as parameters, so OutcomeResolver can compute a contact's guard arithmetic
	without owning a meter and without a rig. The stateful half only holds a number and a timestamp.

	TIME COMES FROM THE CALLER, the same rule DefenseStateMachine and AttackStateMachine keep.

	Does not own: what a guard break DOES (DefenseStateMachine.BreakGuard), damage mitigation (nothing
	in this system applies damage), or when a block is legal (OutcomeResolver).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)

local GuardMeter = {}
GuardMeter.__index = GuardMeter

export type Meter = typeof(setmetatable(
	{} :: {
		_current: number,
		_max: number,
		-- When regeneration becomes allowed again. Pushed forward by every drain, so guard cannot
		-- refill between the hits of a combo -- without which the meter would never meaningfully
		-- deplete and the whole mechanic would be decorative.
		_regenBlockedUntil: number,
	},
	GuardMeter
))

-- Pure -------------------------------------------------------------------------------------------

-- What one blocked contact costs, before it is clamped against what remains.
--
-- Scaled by the attack's PowerLevel, which the hitbox engine already carries on every HitReport --
-- so a heavy costs proportionally more guard than a jab with no per-attack authoring here at all.
-- A negative or NaN power level is treated as zero rather than refunding guard.
function GuardMeter.DrainFor(powerLevel: number, staggered: boolean): number
	if powerLevel ~= powerLevel or powerLevel <= 0 then
		return 0
	end
	local drain = DefenseConstants.Guard.DrainPerPowerLevel * powerLevel
	if staggered then
		-- The counterweight that stops "a parried attacker can still block" from making the punish
		-- hollow -- which the previous design measured happening. See
		-- DefenseConstants.Stagger.GuardDrainMultiplier.
		drain *= DefenseConstants.Stagger.GuardDrainMultiplier
	end
	return drain
end

-- Applies a drain to a guard value, returning (remaining, actualDelta, broke). Pure, so
-- OutcomeResolver can answer "does this hit break the guard" without mutating anything -- pass 1
-- classifies without applying, and a resolver that had to mutate to decide could not do that.
--
-- `broke` is true when the drain met or exceeded what was left. Met, not merely exceeded: a hit that
-- takes the guard to exactly zero has broken it, and treating that as "held" would make the break
-- depend on floating-point luck.
function GuardMeter.ApplyDrain(current: number, drain: number): (number, number, boolean)
	if drain <= 0 then
		return current, 0, false
	end
	local remaining = current - drain
	if remaining <= 0 then
		return 0, -current, true
	end
	return remaining, -drain, false
end

-- Applies a restore, clamped at the pool's ceiling. Returns (value, actualDelta) -- the delta is what
-- was ACTUALLY granted, which at a nearly-full guard is less than what was offered, so a consumer
-- reporting "guard restored" reports the truth.
function GuardMeter.ApplyRestore(current: number, restore: number, max: number): (number, number)
	if restore <= 0 then
		return current, 0
	end
	local raised = math.min(current + restore, max)
	return raised, raised - current
end

-- Stateful ---------------------------------------------------------------------------------------

function GuardMeter.New(max: number?): Meter
	local ceiling = max or DefenseConstants.Guard.Max
	return setmetatable({
		_current = ceiling,
		_max = ceiling,
		_regenBlockedUntil = 0,
	}, GuardMeter) :: any
end

function GuardMeter.Get(self: Meter): number
	return self._current
end

function GuardMeter.GetMax(self: Meter): number
	return self._max
end

function GuardMeter.IsEmpty(self: Meter): boolean
	return self._current <= 0
end

-- Sets the pool directly, to whatever the pure math above already worked out. The stateful half
-- deliberately does no arithmetic of its own: two places computing a guard value is two places for
-- it to be computed differently.
function GuardMeter.Set(self: Meter, value: number, now: number, blockRegen: boolean): ()
	self._current = math.clamp(value, 0, self._max)
	if blockRegen then
		self._regenBlockedUntil = math.max(self._regenBlockedUntil, now + DefenseConstants.Guard.RegenDelaySeconds)
	end
end

-- One tick of regeneration. `allowed` is the caller's answer to "is this combatant in a posture that
-- regenerates at all" -- false while blocking (you cannot rebuild a guard you are actively spending)
-- and false while staggered (one of the three costs that keeps the punish real).
function GuardMeter.Regenerate(self: Meter, deltaTime: number, now: number, allowed: boolean): ()
	if not allowed or deltaTime <= 0 then
		return
	end
	if now < self._regenBlockedUntil then
		return
	end
	if self._current >= self._max then
		return
	end
	self._current = math.min(self._current + DefenseConstants.Guard.RegenPerSecond * deltaTime, self._max)
end

-- Back to full, with no regeneration delay outstanding. For a respawn or a spec reset -- a fight
-- should never open with a deficit inherited from the last one.
function GuardMeter.Reset(self: Meter): ()
	self._current = self._max
	self._regenBlockedUntil = 0
end

return GuardMeter
