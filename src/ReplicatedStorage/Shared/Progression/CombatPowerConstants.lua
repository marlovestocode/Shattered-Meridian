--!strict
--[[
	CombatPowerConstants.lua

	Owns: the tunables for how a cultivation tier gap changes a hit -- Shared/Progression/CombatPower.lua
	reads every value here, DamageSystem applies what it returns. Design: docs/design/cultivation-combat-power.md.

	OFF BY DEFAULT. `Enabled = false` makes every scale exactly 1, so shipping this file changes no fight. Turn
	it on after a playtest of the numbers below, not before: they are starting values chosen against
	combat-philosophy.md's "Skill vs. power balance" rule, not derived from play data.

	THE SHAPE, and why it is a GAP and not a stat. Both fighters grow, so an absolute per-tier bonus only
	shortens every fight at the top of the ladder without making anyone stronger than anyone else. What the
	design asks for is relative: inside a tier, execution decides; a one-tier gap should be winnable by the
	better player; a multi-tier gap very hard but not impossible. So the only input is attacker tier minus
	defender tier, and two fighters of the same tier multiply by exactly 1 at tier 1 and at tier 9 alike.

	Compounding, per tier of gap, applied to what the attacker deals: (1 + PerTier) ^ gap. The weaker side's
	hits shrink by the same factor, so the effective ratio between the two is the square:
	  gap   damage dealt   damage taken back   effective edge
	   1       1.08             0.93              1.17x
	   2       1.17             0.86              1.36x
	   3       1.26             0.79              1.59x
	   4       1.36             0.74              1.85x   <- MaxTierGap: a 9 against a 1 is still a 4
	MaxTierGap is what keeps "not mathematically impossible" true: past it, a bigger gap buys nothing more.

	WHAT IS DELIBERATELY NOT SCALED: hitstun. The M1 string's stun is derived from the clip timeline
	(DamageConstants.Hitstun.LinkBasicString) so the next hit lands inside it; scaling it by power would make
	a string drop against a higher tier and become a true infinite against a lower one. Power changes how
	much a hit is worth, never whether the combo system's timing holds.
]]

local CombatPowerConstants = {}

-- The master switch. False: CombatPower returns 1 for every scale and CombatTrace reports no gap.
CombatPowerConstants.Enabled = false

-- Per tier of gap, compounding. Health damage dealt.
CombatPowerConstants.DamagePerTier = 0.08

-- Per tier of gap, compounding. Posture (guard) drain. Lower than damage on purpose: posture is the
-- resource that lets aggression beat a healthier opponent (combat-philosophy.md), and the weaker fighter's
-- best tool for closing a gap is pressure, so it is scaled more gently.
CombatPowerConstants.GuardPerTier = 0.05

-- The largest gap that still counts. Must be a non-negative integer.
CombatPowerConstants.MaxTierGap = 4

return CombatPowerConstants
