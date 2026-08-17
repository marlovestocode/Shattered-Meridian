--!strict
--[[
	DamageResolver.lua

	Owns: what one already-classified contact costs -- health, guard pressure, hitstun, and whether it
	escalates the attacker's string.

	PURE, for the same reason OutcomeResolver and HitboxGeometry are: no Instances, no clock, no
	services, no mutation of anything it is handed. Every interesting rule in this layer (does blocking
	cost the attacker their escalation, does a backstab hurt more, does a parry deal anything at all)
	is a decision about a handful of numbers, and keeping it pure means every one of them is
	table-driven testable with no rig at all.

	IT DOES NOT RE-DECIDE WHAT KIND OF HIT THIS WAS. DefenseSystem already did that, against the
	defender's posture at the contact's own SampleTime, which is a judgement this module could not
	reproduce even if it wanted to -- it has no access to the machine's history. It takes the outcome
	kind as given and prices it.

	Does not own: classification (Server/Combat/Defense/OutcomeResolver.lua), applying any of what it
	returns (DamageSystem), the combo counter itself (ComboEscalation), or the authored per-move
	numbers it multiplies (the Move Creation System, via AttackCatalog).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)

type DamageResult = DamageTypes.DamageResult
type DamageProfile = DamageTypes.DamageProfile
type OutcomeKind = DefenseTypes.OutcomeKind

local DamageResolver = {}

-- Whether an outcome earns the attacker escalation credit.
--
-- Split out as its own predicate because the CALLER has to know the answer before Resolve runs: the
-- stage a hit counts as is the stage AFTER this hit advances the counter, so DamageSystem must
-- advance first and pass the result in. Deriving it in two places would be two places to disagree, and
-- the disagreement would be silent -- an off-by-one here makes every hit of every string scale as
-- though it were the previous one.
function DamageResolver.AdvancesCombo(kind: OutcomeKind): boolean
	return kind == "Clean" or kind == "Backstab" or kind == "GuardBroken"
end

-- What a stage is worth. Stage 1 is exactly 1x, so the first hit of a string deals precisely its
-- authored damage and an author reading the Move Editor sees the number they typed.
function DamageResolver.ComboMultiplier(stage: number): number
	if stage ~= stage or stage <= 1 then
		return 1
	end
	local capped = math.min(stage, DamageConstants.Combo.MaxStage)
	return 1 + DamageConstants.Combo.DamageMultiplierPerStage * (capped - 1)
end

-- Guarded rather than trusted. These numbers come from the Move Editor by way of a DataStore, so a
-- record written by an older schema (or hand-edited) can carry a nil or a NaN, and a NaN damage value
-- would propagate into Humanoid:TakeDamage and take the health bar with it rather than erroring
-- anywhere useful.
local function safeNumber(value: number?): number
	if typeof(value) ~= "number" then
		return 0
	end
	local number = value :: number
	if number ~= number or number <= 0 then
		return 0
	end
	return number
end

--[[
	Prices one contact.

	`stage` is the stage THIS hit counts as -- already advanced by the caller when AdvancesCombo says
	it should be. So the first hit of a string arrives as stage 1 and scales by exactly 1x, and the
	second arrives as stage 2. Passing the pre-advance stage instead would make every hit scale as
	though it were the one before it, which is invisible in play until someone measures a combo.

	The rules, and why each is what it is:

	  * CLEAN -- full authored damage scaled by the string, full posture pressure, hitstun, escalates.
	    The ordinary case, and the baseline every other branch is a deviation from.

	  * BACKSTAB -- the same, multiplied. DefenseSystem has already decided the block did not apply
	    because the hit came from the rear hemisphere while the defender was guarding, and a punish for
	    the worst possible defensive read should read as worse than simply being caught standing still.
	    Posture pressure is multiplied too, so a backstab costs the guard it failed to cover with.

	  * GUARDBROKEN -- full damage, no posture pressure. Not a discount: per OutcomeResolver's own
	    contract, GuardBroken means the guard is GONE, which is a real opening rather than a mitigated
	    hit. The pressure is zero only because DefenseSystem already drained that same pool to empty on
	    this very contact -- draining again here would charge one hit twice against one meter.

	  * BLOCKED -- no health damage, no posture pressure (DefenseSystem already charged the block
	    through GuardMeter.DrainFor), no hitstun, and NO ESCALATION CREDIT.
	    That last one is the deliberate call, and the alternative was real: partial credit is easier on
	    the attacker and easier to tune around a long string. It loses because a defender who
	    successfully raises a guard deserves an unambiguous answer to "did that work," and partial
	    credit muddies exactly the readability the block is for. The attacker keeps their string ALIVE
	    (nothing here resets it, and their sequencer still cycles) -- they simply earn nothing from the
	    hit that was answered.
	    THE ONE EXCEPTION is a block held while Staggered, which is not free: DefenseConstants.Stagger.
	    MitigationMultiplier exists to say so and has had no consumer until now. A parried attacker who
	    turtles through their punish takes a fraction of the damage through their own guard, which is
	    what stops "a parried attacker can still block" from making the punish hollow -- a thing the
	    previous design measured happening and wrote down.

	  * PARRIED / TRADE -- nothing at all. DefenseSystem has already cancelled the attacker's swing and
	    (for a parry) staggered them; the exchange has been settled. The result is still returned with
	    its Kind intact so both clients get accurate feedback, but no resource moves.
]]
function DamageResolver.Resolve(
	kind: OutcomeKind,
	defenderStateAtContact: DefenseTypes.DefenseState,
	profile: DamageProfile,
	stage: number
): DamageResult
	local authoredDamage = safeNumber(profile.Damage)
	local authoredPosture = safeNumber(profile.PostureDamage)
	local comboScale = DamageResolver.ComboMultiplier(stage)

	local result: DamageResult = {
		Kind = kind,
		Damage = 0,
		GuardDrain = 0,
		HitstunSeconds = 0,
		-- One source of truth with the predicate above, never a second hand-written kind list.
		AdvancesCombo = DamageResolver.AdvancesCombo(kind),
		Knockback = nil,
	}

	if kind == "Clean" or kind == "Backstab" then
		local outcomeScale = if kind == "Backstab" then DamageConstants.Backstab.Multiplier else 1
		result.Damage = authoredDamage * comboScale * outcomeScale
		result.GuardDrain = authoredPosture * DamageConstants.Guard.PressurePerPostureDamage * outcomeScale
		result.HitstunSeconds = DamageConstants.Hitstun.Seconds
		result.Knockback = profile.Knockback
	elseif kind == "GuardBroken" then
		result.Damage = authoredDamage * comboScale
		result.HitstunSeconds = DamageConstants.Hitstun.Seconds
		result.Knockback = profile.Knockback
	elseif kind == "Blocked" then
		if defenderStateAtContact == "Staggered" then
			result.Damage = authoredDamage * comboScale * (1 - DefenseConstants.Stagger.MitigationMultiplier)
		end
	end

	return result
end

return DamageResolver
