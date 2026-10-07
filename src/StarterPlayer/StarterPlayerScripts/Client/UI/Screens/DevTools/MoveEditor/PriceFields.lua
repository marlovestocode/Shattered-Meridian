--!strict
--[[
	MoveEditor/PriceFields.lua

	Owns: the fields that set what a hit from this move COSTS the body it lands on -- damage, posture
	damage, the power level a block is drained by, and the knockback -- built once here and mounted by two
	pages: the Impact tab (a swing's or a shot's price) and a domain expansion's Effects tab (STRIKE PRICE,
	the realm's own strike: a Strike effect with no move id hits for these, DomainTypes.EffectMayUseOwnMove).

	One builder rather than two copies, because they are the same four fields on the same MoveDefinition
	read by the same AttackCatalog -> DamageSystem path; a domain expansion only reaches them from a
	different page, since it has no Impact tab of its own (a realm has no volume of its own to land).

	The knockback is an OPTIONAL BLOCK behind its toggle, the ImpactTab convention: off is absent (nil), on
	seeds a solid shove rather than zeros.

	Does not own: the grab (ImpactTab -- a realm and a projectile cannot grab), the bounds (Constants
	.MoveEditor.Limits, MoveTypes.PowerLevelLimits).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local LIMITS = Constants.MoveEditor.Limits

-- What a freshly enabled knockback starts as: a solid shove, a little lift.
local DEFAULT_KNOCKBACK: MoveTypes.MoveKnockback = {
	UpVelocity = 15,
	HorizontalVelocity = 45,
	StartsAirCombo = false,
}

local PriceFields = {}

-- Damage, posture damage and power level. A Default move's power level is its stage's, shown as a fact.
function PriceFields.Cost(scope: Scope, context: Fields.FormContext): { Instance }
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	return {
		Fields.Number(scope, context, {
			Label = "Damage",
			Unit = "health",
			Range = LIMITS.Damage,
			Steps = { 1, 5 },
			Decimals = 1,
			LayoutOrder = 1,
			Get = function(move)
				return move.Damage
			end,
			Set = function(move, value)
				move.Damage = value
			end,
		}),
		Fields.Number(scope, context, {
			Label = "Posture damage",
			Unit = "guard",
			Range = LIMITS.PostureDamage,
			Steps = { 1, 5 },
			Decimals = 1,
			Hint = Copy.Hints.PostureDamage,
			LayoutOrder = 2,
			Get = function(move)
				return move.PostureDamage
			end,
			Set = function(move, value)
				move.PostureDamage = value
			end,
		}),
		Fields.Number(scope, context, {
			Label = "Power level",
			Range = MoveTypes.PowerLevelLimits,
			Steps = { 1 },
			Decimals = 0,
			Hint = Copy.Hints.PowerLevel,
			LayoutOrder = 3,
			Visible = isCustom,
			Get = function(move)
				return MoveTypes.PowerLevelOf(move)
			end,
			Set = function(move, value)
				move.PowerLevel = math.floor(value + 0.5)
			end,
		}),
		Fields.Fact(
			scope,
			"Power level  (by stage)",
			scope:Computed(function(use)
				local move = use(context.Draft)
				return if move then tostring(MoveTypes.PowerLevelOf(move)) else "-"
			end),
			4,
			context.IsDefault
		),
	}
end

-- The knockback toggle and, while it is on, its push, lift and launcher switch.
function PriceFields.Knockback(scope: Scope, context: Fields.FormContext): { Instance }
	local hasKnockback = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Knockback ~= nil
	end)
	local function velocity(label: string, field: string, order: number): Frame
		return Fields.Number(scope, context, {
			Label = label,
			Unit = "studs/s",
			Range = LIMITS.KnockbackVelocity,
			Steps = { 1, 10 },
			Decimals = 0,
			LayoutOrder = order,
			Visible = hasKnockback,
			Get = function(move)
				return if move.Knockback then (move.Knockback :: any)[field] else 0
			end,
			Set = function(move, value)
				if move.Knockback then
					(move.Knockback :: any)[field] = value
				end
			end,
		})
	end
	return {
		Fields.Toggle(scope, context, {
			Label = "Knock the target back",
			LayoutOrder = 1,
			Get = function(move)
				return move.Knockback ~= nil
			end,
			Set = function(move, on)
				move.Knockback = if on then table.clone(DEFAULT_KNOCKBACK) else nil
			end,
		}),
		velocity("Push", "HorizontalVelocity", 2),
		velocity("Lift", "UpVelocity", 3),
		Fields.Toggle(scope, context, {
			Label = "Launcher -- opens an air string",
			Hint = Copy.Hints.StartsAirCombo,
			LayoutOrder = 4,
			Visible = hasKnockback,
			Get = function(move)
				return move.Knockback ~= nil and move.Knockback.StartsAirCombo == true
			end,
			Set = function(move, on)
				if move.Knockback then
					move.Knockback.StartsAirCombo = on
				end
			end,
		}),
	}
end

-- One line summarising a price, for a folded section's heading ("12 dmg  ·  8 posture  ·  P2").
function PriceFields.Summary(move: MoveTypes.MoveDefinition?): string
	if not move then
		return ""
	end
	local text =
		string.format("%g dmg  ·  %g posture  ·  P%d", move.Damage, move.PostureDamage, MoveTypes.PowerLevelOf(move))
	return if move.Knockback then `{text}  ·  knockback` else text
end

return PriceFields
