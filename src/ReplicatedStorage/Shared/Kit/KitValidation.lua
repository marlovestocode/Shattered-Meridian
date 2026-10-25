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

	BUILT ON Shared/Schema (2026-10-25, W4): the ability and each modifier spec are declared as Record shapes, in the
	same field order the hand-written checks ran in, each field carrying the stable error code its callers switch on
	(`InvalidAbilityId`, `InvalidEffectKind`, ...). The answers are unchanged; the old validators are frozen in
	Tests/Fixtures/KitValidationLegacy.lua and Tests/Kit/KitValidatorsEquivalence.spec.lua runs both over one corpus.

	Does not own: which content type (Race trait, Bloodline stage) an ability belongs to, or any
	identity field outside the ability itself (TraitId, BloodlineId, RaceId, RequiredTier, StageIndex
	-- each owned by its own Manager's own Validate).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local Sanitize = require(ReplicatedStorage.Shared.Sanitize)
local Schema = require(ReplicatedStorage.Shared.Schema)

local KitValidation = {}

local KitLimits = Constants.Kit.Limits

-- Long enough for a real ability name/description, short enough that a pasted essay can't bloat a
-- future DataStore record -- same reasoning MoveRegistryManager's own MAX_DESCRIPTION_LENGTH gives.
local MAX_NAME_LENGTH = 64
local MAX_DESCRIPTION_LENGTH = 400
local MAX_TAG_LENGTH = 64

-- Re-exported rather than reimplemented: Shared/Sanitize.lua owns both primitives now (see its own
-- header on why the NaN branch is what earned them a module). Kept as KitValidation members because
-- RaceManager and BloodlineManager already reach for them through this module by name, and a
-- validator asking its own domain module for a clamp reads better than reaching past it.
KitValidation.ClampedNumber = Sanitize.ClampNumber
KitValidation.BoundedString = Sanitize.BoundedString

-- Each field fails with the STABLE CODE its callers (KitEditorSystem's replies, the specs) switch on, so every field
-- shape is wrapped in WithReason; the declared order is the order the first refusal is found in.
local function field(code: string, shape: Schema.Shape<any>): Schema.Shape<any>
	return Schema.WithReason(code, shape)
end

local function limited(limit: { Min: number, Max: number }): Schema.Shape<number>
	return Schema.Number(limit.Min, limit.Max)
end

-- A modifier spec is `{ Kind, Lifetime }` plus the fields its Kind needs plus, for a Timed lifetime, a duration. Which
-- OTHER fields are required is determined by Kind, matching Types.ActiveModifierSpec's own "only the fields meaningful
-- for the chosen Kind are populated" contract -- a spec missing the field its own Kind needs is a structural error, not
-- a numeric one, so it rejects rather than silently clamping into something else.
local MODIFIER_BASE = Schema.CodedRecord("InvalidEffect", {
	{ "Kind", field("InvalidEffectKind", Schema.Enum({ "AttributeDelta", "Tag", "QiRestore" })) },
	{ "Lifetime", field("InvalidEffectLifetime", Schema.Enum({ "Instant", "Timed", "Bound" })) },
})

local MODIFIER_BY_KIND: { [string]: Schema.Shape<{ [string]: any }> } = {
	AttributeDelta = Schema.CodedRecord("InvalidEffect", {
		{
			"AttributeKey",
			field(
				"InvalidEffectAttributeKey",
				Schema.Enum({ "Vitality", "Fortitude", "MeridianFlow", "Might", "Pressure", "Fleetness" })
			),
		},
		{ "Delta", field("InvalidEffectDelta", limited(KitLimits.Delta)) },
	}),
	Tag = Schema.CodedRecord("InvalidEffect", {
		{ "Tag", field("InvalidEffectTag", Schema.NonEmptyString(MAX_TAG_LENGTH)) },
		{ "Magnitude", field("InvalidEffectMagnitude", limited(KitLimits.Magnitude)) },
	}),
	QiRestore = Schema.CodedRecord("InvalidEffect", {
		{ "QiRestoreAmount", field("InvalidEffectQiRestoreAmount", limited(KitLimits.QiRestoreAmount)) },
	}),
}

local MODIFIER_TIMED = Schema.CodedRecord("InvalidEffect", {
	{ "DurationSeconds", field("InvalidEffectDuration", limited(KitLimits.DurationSeconds)) },
})

-- Validates+clamps one Types.ActiveModifierSpec. Kind/Lifetime must be one of the closed sets above
-- (hard reject).
function KitValidation.ValidateModifierSpec(raw: unknown): (Types.ActiveModifierSpec?, string?)
	if not Schema.IsTable(raw) then
		return nil, "InvalidEffect"
	end
	local base, baseReason = Schema.Decode(MODIFIER_BASE, raw)
	if base == nil then
		return nil, baseReason
	end
	local spec: { [string]: any } = base

	local byKind, kindReason = Schema.Decode(MODIFIER_BY_KIND[spec.Kind], raw)
	if byKind == nil then
		return nil, kindReason
	end
	for key, value in byKind do
		spec[key] = value
	end

	if spec.Lifetime == "Timed" then
		local timed, timedReason = Schema.Decode(MODIFIER_TIMED, raw)
		if timed == nil then
			return nil, timedReason
		end
		spec.DurationSeconds = timed.DurationSeconds
	end

	return spec :: Types.ActiveModifierSpec, nil
end

function KitValidation.ValidateEffects(raw: unknown): ({ Types.ActiveModifierSpec }?, string?)
	if not Schema.IsTable(raw) then
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

-- A shape that defers to a validator with its own stable error codes.
local EFFECTS = Schema.Custom(function(raw: unknown)
	local effects, err = KitValidation.ValidateEffects(raw)
	if err then
		return nil, Schema.Failure(err)
	end
	return effects, nil
end)

-- CooldownSeconds/QiCost are validated and clamped regardless of Kind -- see KitAbilityDefinition's own header on why a
-- Passive entry is not required to author them as 0; the owning System (RaceSystem/BloodlineSystem) simply ignores both
-- at use time for a Passive. Either cost failing is the one code, InvalidAbilityCost.
local ABILITY = Schema.CodedRecord("InvalidAbility", {
	{ "Id", field("InvalidAbilityId", Schema.NonEmptyString()) },
	{ "DisplayName", field("InvalidAbilityDisplayName", Schema.String(MAX_NAME_LENGTH)) },
	{ "Kind", field("InvalidAbilityKind", Schema.Enum({ "Passive", "Active" })) },
	{ "CooldownSeconds", field("InvalidAbilityCost", limited(KitLimits.CooldownSeconds)) },
	{ "QiCost", field("InvalidAbilityCost", limited(KitLimits.QiCost)) },
	{ "Effects", EFFECTS },
	-- Last, because it cannot fail: a missing or non-string description is "" (the one NORMALISED field).
	{ "Description", Schema.Default(Schema.String(MAX_DESCRIPTION_LENGTH), "") },
})

-- Validates+clamps one KitTypes.KitAbilityDefinition.
function KitValidation.ValidateAbility(raw: unknown): (KitTypes.KitAbilityDefinition?, string?)
	if not Schema.IsTable(raw) then
		return nil, "InvalidAbility"
	end
	local ability, reason = Schema.Decode(ABILITY, raw)
	if ability == nil then
		return nil, reason
	end
	return ability :: KitTypes.KitAbilityDefinition, nil
end

return KitValidation
