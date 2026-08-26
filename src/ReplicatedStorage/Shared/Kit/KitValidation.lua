--!strict
--[[
	KitValidation.lua

	Owns: validation for the ONE ability shape Race Traits and Bloodline stage grants both build on
	(Shared/Kit/KitTypes.KitAbilityDefinition) and the modifier specs an ability's Effects list
	carries (Types.ActiveModifierSpec) -- shared here for the same reason KitTypes.lua itself is
	shared rather than duplicated: Server/Managers/RaceManager.Validate and
	Server/Managers/BloodlineManager.Validate both need to validate the identical shape, and two
	independently-maintained copies of this logic is exactly the failure this codebase's own "reach
	for a shared module before hand-rolling" rule exists to prevent (see CLAUDE.md's module table).

	Clamps every numeric field against Constants.Kit.Limits -- the SAME table
	Server/Systems/KitEditorSystem.lua's own client will render its field bounds from, once that
	editor exists (a later phase of the Race Traits + Bloodline Abilities plan). A structural error
	(an unrecognized Kind/Lifetime, a missing field the chosen Kind requires) is a hard reject; an
	in-range numeric field clamps instead -- the identical "hard-reject on structure, clamp on
	numbers" split MoveRegistryManager.Validate already establishes for moves.

	Does not own: which content type (Race trait, Bloodline stage) an ability belongs to, or any
	identity field outside the ability itself (TraitId, BloodlineId, RaceId, RequiredTier, StageIndex
	-- each owned by its own Manager's own Validate).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)

local KitValidation = {}

local KitLimits = Constants.Kit.Limits

local ABILITY_KINDS: { [string]: boolean } = { Passive = true, Active = true }
local MODIFIER_KINDS: { [string]: boolean } = { AttributeDelta = true, Tag = true, QiRestore = true }
local MODIFIER_LIFETIMES: { [string]: boolean } = { Instant = true, Timed = true, Bound = true }
local ATTRIBUTE_KEYS: { [string]: boolean } =
	{ Vitality = true, Fortitude = true, MeridianFlow = true, Might = true, Pressure = true, Fleetness = true }

-- Long enough for a real ability name/description, short enough that a pasted essay can't bloat a
-- future DataStore record -- same reasoning MoveRegistryManager's own MAX_DESCRIPTION_LENGTH gives.
local MAX_NAME_LENGTH = 64
local MAX_DESCRIPTION_LENGTH = 400
local MAX_TAG_LENGTH = 64

local function isNonEmptyString(value: unknown): boolean
	return typeof(value) == "string" and (value :: string) ~= ""
end

-- Exported: both callers' own Validate (BloodlineId/RaceId/TraitId/RequiredTier/StageIndex) need the
-- identical numeric-clamp/string-bound primitives this module already has for its own fields, rather
-- than each keeping a second copy.
function KitValidation.ClampedNumber(value: unknown, min: number, max: number): number?
	if typeof(value) ~= "number" then
		return nil
	end
	local number = value :: number
	if number ~= number then
		-- NaN passes typeof but survives math.clamp -- same defensive check MoveRegistryManager's own
		-- clampedNumber makes.
		return nil
	end
	return math.clamp(number, min, max)
end

function KitValidation.BoundedString(value: unknown, maxLength: number): string
	if typeof(value) ~= "string" then
		return ""
	end
	local text = value :: string
	if #text > maxLength then
		return text:sub(1, maxLength)
	end
	return text
end

-- Validates+clamps one Types.ActiveModifierSpec. Kind/Lifetime must be one of the closed sets above
-- (hard reject); which OTHER fields are required is determined by Kind, matching
-- Types.ActiveModifierSpec's own "only the fields meaningful for the chosen Kind are populated"
-- contract -- a spec missing the field its own Kind needs is a structural error, not a numeric one,
-- so it rejects rather than silently clamping into something else.
function KitValidation.ValidateModifierSpec(raw: unknown): (Types.ActiveModifierSpec?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidEffect"
	end
	local candidate = raw :: { [string]: unknown }

	if typeof(candidate.Kind) ~= "string" or not MODIFIER_KINDS[candidate.Kind :: string] then
		return nil, "InvalidEffectKind"
	end
	local kind = candidate.Kind :: Types.ActiveModifierKind

	if typeof(candidate.Lifetime) ~= "string" or not MODIFIER_LIFETIMES[candidate.Lifetime :: string] then
		return nil, "InvalidEffectLifetime"
	end
	local lifetime = candidate.Lifetime :: Types.ActiveModifierLifetime

	local spec: Types.ActiveModifierSpec = { Kind = kind, Lifetime = lifetime }

	if kind == "AttributeDelta" then
		if typeof(candidate.AttributeKey) ~= "string" or not ATTRIBUTE_KEYS[candidate.AttributeKey :: string] then
			return nil, "InvalidEffectAttributeKey"
		end
		local delta = KitValidation.ClampedNumber(candidate.Delta, KitLimits.Delta.Min, KitLimits.Delta.Max)
		if delta == nil then
			return nil, "InvalidEffectDelta"
		end
		spec.AttributeKey = candidate.AttributeKey :: Types.ActiveModifierAttributeKey
		spec.Delta = delta
	elseif kind == "Tag" then
		if not isNonEmptyString(candidate.Tag) then
			return nil, "InvalidEffectTag"
		end
		local magnitude =
			KitValidation.ClampedNumber(candidate.Magnitude, KitLimits.Magnitude.Min, KitLimits.Magnitude.Max)
		if magnitude == nil then
			return nil, "InvalidEffectMagnitude"
		end
		spec.Tag = KitValidation.BoundedString(candidate.Tag, MAX_TAG_LENGTH)
		spec.Magnitude = magnitude
	elseif kind == "QiRestore" then
		local amount = KitValidation.ClampedNumber(
			candidate.QiRestoreAmount,
			KitLimits.QiRestoreAmount.Min,
			KitLimits.QiRestoreAmount.Max
		)
		if amount == nil then
			return nil, "InvalidEffectQiRestoreAmount"
		end
		spec.QiRestoreAmount = amount
	end

	if lifetime == "Timed" then
		local duration = KitValidation.ClampedNumber(
			candidate.DurationSeconds,
			KitLimits.DurationSeconds.Min,
			KitLimits.DurationSeconds.Max
		)
		if duration == nil then
			return nil, "InvalidEffectDuration"
		end
		spec.DurationSeconds = duration
	end

	return spec, nil
end

function KitValidation.ValidateEffects(raw: unknown): ({ Types.ActiveModifierSpec }?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidEffects"
	end
	local effects: { Types.ActiveModifierSpec } = {}
	for _, rawEffect in ipairs(raw :: { unknown }) do
		local spec, err = KitValidation.ValidateModifierSpec(rawEffect)
		if err then
			return nil, err
		end
		table.insert(effects, spec :: Types.ActiveModifierSpec)
	end
	return effects, nil
end

-- Validates+clamps one KitTypes.KitAbilityDefinition. CooldownSeconds/QiCost are validated and
-- clamped regardless of Kind -- see KitAbilityDefinition's own header on why a Passive entry is not
-- required to author them as 0; the owning System (RaceSystem/BloodlineSystem) simply ignores both at
-- use time for a Passive.
function KitValidation.ValidateAbility(raw: unknown): (KitTypes.KitAbilityDefinition?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidAbility"
	end
	local candidate = raw :: { [string]: unknown }

	if not isNonEmptyString(candidate.Id) then
		return nil, "InvalidAbilityId"
	end
	if typeof(candidate.DisplayName) ~= "string" then
		return nil, "InvalidAbilityDisplayName"
	end
	if typeof(candidate.Kind) ~= "string" or not ABILITY_KINDS[candidate.Kind :: string] then
		return nil, "InvalidAbilityKind"
	end
	local cooldownSeconds = KitValidation.ClampedNumber(
		candidate.CooldownSeconds,
		KitLimits.CooldownSeconds.Min,
		KitLimits.CooldownSeconds.Max
	)
	local qiCost = KitValidation.ClampedNumber(candidate.QiCost, KitLimits.QiCost.Min, KitLimits.QiCost.Max)
	if cooldownSeconds == nil or qiCost == nil then
		return nil, "InvalidAbilityCost"
	end
	local effects, effectsError = KitValidation.ValidateEffects(candidate.Effects)
	if effectsError then
		return nil, effectsError
	end

	return {
		Id = candidate.Id :: string,
		DisplayName = KitValidation.BoundedString(candidate.DisplayName, MAX_NAME_LENGTH),
		Description = KitValidation.BoundedString(candidate.Description, MAX_DESCRIPTION_LENGTH),
		Kind = candidate.Kind :: KitTypes.KitAbilityKind,
		CooldownSeconds = cooldownSeconds,
		QiCost = qiCost,
		Effects = effects :: { Types.ActiveModifierSpec },
	},
		nil
end

return KitValidation
