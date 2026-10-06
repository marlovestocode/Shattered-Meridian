--!strict
--[[
	CombatPower.lua

	Owns: the CULTIVATION-TO-COMBAT SEAM -- reading the tier a combatant fights at and turning the gap between
	two of them into the multipliers a hit takes. The one module both ends require: TierSystem writes the
	tier (AttributeConstants.CultivationTier, on the Player), DamageSystem reads the scales and hands them to
	DamageResolver.ApplyScales, CombatTrace reads the gap to explain a hit. Design:
	docs/design/cultivation-combat-power.md; tunables: CombatPowerConstants.

	WHY AN ATTRIBUTE AND NOT A CALL INTO TierSystem. TierSystem is a progression System; DamageSystem is a
	combat layer. A combat layer requiring a progression System would point the stack's dependency at
	something above it, and TierSystem's profile read is a deep copy that must never run per hit. The tier
	is published once per change and read here as a number -- the same shape DomainRules uses for realms.
	It also replicates, so a client can show an opponent's tier without a remote (readable power).

	MISSING MEANS NEUTRAL. A body with no tier -- a bot, a dummy, a player whose profile has not loaded -- has
	no gap with anyone, so the hit is unscaled. Defaulting a missing tier to 1 would make every bot hit a
	tier-9 player for a quarter of its damage the moment the flag is on.

	ADDING A SOURCE OF POWER LATER (a bloodline stage, an art's passive): it belongs here, composed into
	Scales, so DamageSystem keeps reading one pair of numbers. combat-philosophy.md asks that bloodline and
	art power expand a kit's decisions rather than only its numbers, so check whether it should be a scale at
	all before adding it as one.

	Does not own: what tier a player holds (TierSystem), whether the switch is on (CombatPowerConstants), or
	the arithmetic of a hit (DamageResolver).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CombatPowerConstants = require(ReplicatedStorage.Shared.Progression.CombatPowerConstants)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)

local CombatPower = {}

-- Spec seam: overrides CombatPowerConstants.Enabled. nil = follow the constant.
local enabledOverride: boolean? = nil

function CombatPower.IsEnabled(): boolean
	if enabledOverride ~= nil then
		return enabledOverride
	end
	return CombatPowerConstants.Enabled == true
end

function CombatPower.SetEnabledForTest(enabled: boolean?): ()
	enabledOverride = enabled
end

local function validTier(value: any): number?
	if typeof(value) ~= "number" or value ~= value then
		return nil
	end
	local tier = math.floor(value)
	if tier < 1 or tier > TierConstants.MaxTier then
		return nil
	end
	return tier
end

-- The tier `model` fights at, or nil when it has none. A player's character reads its Player; anything else
-- reads the Model itself (AttributeConstants.CultivationTier).
function CombatPower.TierOf(model: Model?): number?
	if model == nil then
		return nil
	end
	local player = Players:GetPlayerFromCharacter(model)
	local holder: Instance = if player then player else model
	return validTier(holder:GetAttribute(AttributeConstants.CultivationTier))
end

-- Attacker tier minus defender tier, clamped to MaxTierGap. 0 when either side has no tier. Ignores the
-- switch: this is the fact, IsEnabled decides whether it matters.
function CombatPower.TierGap(attacker: Model?, defender: Model?): number
	local attackerTier = CombatPower.TierOf(attacker)
	local defenderTier = CombatPower.TierOf(defender)
	if attackerTier == nil or defenderTier == nil then
		return 0
	end
	local limit = math.max(math.floor(CombatPowerConstants.MaxTierGap), 0)
	return math.clamp(attackerTier - defenderTier, -limit, limit)
end

-- Pure: the (damage, guard) multipliers for a gap. Exactly 1, 1 at a gap of 0.
function CombatPower.ScalesForGap(gap: number): (number, number)
	if gap == 0 or gap ~= gap then
		return 1, 1
	end
	local damage = (1 + CombatPowerConstants.DamagePerTier) ^ gap
	local guard = (1 + CombatPowerConstants.GuardPerTier) ^ gap
	return damage, guard
end

-- The (damage, guard) multipliers for `attacker` hitting `defender`. 1, 1 while the switch is off.
function CombatPower.Scales(attacker: Model?, defender: Model?): (number, number)
	if not CombatPower.IsEnabled() then
		return 1, 1
	end
	return CombatPower.ScalesForGap(CombatPower.TierGap(attacker, defender))
end

return CombatPower
