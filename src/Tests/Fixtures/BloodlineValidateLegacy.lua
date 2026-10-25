--!strict
-- FROZEN COPY, taken before the validators were converted to Shared/Schema (2026-10-25, coworking plan W4). It exists only
-- so Tests/Kit/KitValidatorsEquivalence.spec.lua can run the old hand-written `typeof` validators and the converted ones
-- over one corpus and assert identical answers. Nothing under src/ outside Tests requires it. Do not edit it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local KitValidation = require(ServerScriptService.Tests.Fixtures.KitValidationLegacy)

local BloodlineManager = {}

local KitLimits = Constants.Kit.Limits

local RACE_IDS: { [string]: boolean } = { Human = true, Firmborn = true, Rivenkin = true, Hollowborn = true }

local MAX_NAME_LENGTH = 64
local MAX_FLAVOR_LENGTH = 800
local MAX_CONDITION_KIND_LENGTH = 64

local function isNonEmptyString(value: unknown): boolean
	return typeof(value) == "string" and (value :: string) ~= ""
end

-- Open string Kind (BloodlineAwakeningCondition's own header) -- only its PRESENCE is validated here,
-- never membership in a closed set, since a per-content trigger kind is a content decision, not a
-- structural one. Params entries are individually filtered (string key, number value) rather than
-- hard-rejecting the whole condition on one bad entry -- the same per-entry defensive posture
-- PlayerDataSystem.DecodeProfile already takes for an open dict it can't fully validate the shape of.
local function validateAwakeningCondition(raw: unknown): (BloodlineTypes.BloodlineAwakeningCondition?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidAwakeningCondition"
	end
	local candidate = raw :: { [string]: unknown }

	if not isNonEmptyString(candidate.Kind) then
		return nil, "InvalidAwakeningConditionKind"
	end
	local kind = KitValidation.BoundedString(candidate.Kind, MAX_CONDITION_KIND_LENGTH)

	local params: { [string]: number } = {}
	if candidate.Params ~= nil then
		if typeof(candidate.Params) ~= "table" then
			return nil, "InvalidAwakeningConditionParams"
		end
		for key, value in pairs(candidate.Params :: { [string]: unknown }) do
			if typeof(key) == "string" and typeof(value) == "number" then
				params[key] = value :: number
			end
		end
	end

	return { Kind = kind, Params = params }, nil
end

-- Validates+clamps one BloodlineStageDefinition. GrantedAbility is optional -- nil means a pure
-- stat-passive stage with no Active ability of its own (BloodlineStageDefinition's own header).
local function validateStage(raw: unknown): (BloodlineTypes.BloodlineStageDefinition?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidStage"
	end
	local candidate = raw :: { [string]: unknown }

	local stageIndex =
		KitValidation.ClampedNumber(candidate.StageIndex, KitLimits.StageIndex.Min, KitLimits.StageIndex.Max)
	if stageIndex == nil then
		return nil, "InvalidStageIndex"
	end
	if typeof(candidate.DisplayName) ~= "string" then
		return nil, "InvalidStageDisplayName"
	end
	local passiveEffects, effectsError = KitValidation.ValidateEffects(candidate.PassiveEffects)
	if effectsError then
		return nil, effectsError
	end

	local grantedAbility: KitTypes.KitAbilityDefinition? = nil
	if candidate.GrantedAbility ~= nil then
		local ability, abilityError = KitValidation.ValidateAbility(candidate.GrantedAbility)
		if abilityError then
			return nil, abilityError
		end
		grantedAbility = ability
	end

	return {
		StageIndex = math.floor(stageIndex),
		DisplayName = KitValidation.BoundedString(candidate.DisplayName, MAX_NAME_LENGTH),
		PassiveEffects = passiveEffects :: { Types.ActiveModifierSpec },
		GrantedAbility = grantedAbility,
	},
		nil
end

local function validateStages(raw: unknown): ({ BloodlineTypes.BloodlineStageDefinition }?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidStages"
	end
	local stages: { BloodlineTypes.BloodlineStageDefinition } = {}
	for _, rawStage in ipairs(raw :: { unknown }) do
		local stage, err = validateStage(rawStage)
		if err then
			return nil, err
		end
		table.insert(stages, stage :: BloodlineTypes.BloodlineStageDefinition)
	end
	return stages, nil
end

-- The one strict allow-list gate every BloodlineDefinition-shaped table passes through -- see this
-- file's header. `candidate` is `unknown` deliberately, same reasoning as MoveRegistryManager.
-- Validate/RaceManager.Validate.
function BloodlineManager.Validate(candidate: unknown): (BloodlineTypes.BloodlineDefinition?, string?)
	if typeof(candidate) ~= "table" then
		return nil, "InvalidShape"
	end
	local raw = candidate :: { [string]: unknown }

	if not isNonEmptyString(raw.BloodlineId) then
		return nil, "InvalidBloodlineId"
	end
	if typeof(raw.DisplayName) ~= "string" then
		return nil, "InvalidDisplayName"
	end
	if typeof(raw.RarityTier) ~= "string" then
		return nil, "InvalidRarityTier"
	end
	if typeof(raw.FlavorText) ~= "string" then
		return nil, "InvalidFlavorText"
	end

	local nativeRaceId: Types.RaceId? = nil
	if raw.NativeRaceId ~= nil then
		if typeof(raw.NativeRaceId) ~= "string" or not RACE_IDS[raw.NativeRaceId :: string] then
			return nil, "InvalidNativeRaceId"
		end
		nativeRaceId = raw.NativeRaceId :: Types.RaceId
	end

	local awakeningCondition, conditionError = validateAwakeningCondition(raw.AwakeningCondition)
	if conditionError then
		return nil, conditionError
	end

	local stages, stagesError = validateStages(raw.Stages)
	if stagesError then
		return nil, stagesError
	end

	return {
		BloodlineId = raw.BloodlineId :: string,
		DisplayName = KitValidation.BoundedString(raw.DisplayName, MAX_NAME_LENGTH),
		RarityTier = KitValidation.BoundedString(raw.RarityTier, MAX_NAME_LENGTH),
		FlavorText = KitValidation.BoundedString(raw.FlavorText, MAX_FLAVOR_LENGTH),
		NativeRaceId = nativeRaceId,
		AwakeningCondition = awakeningCondition :: BloodlineTypes.BloodlineAwakeningCondition,
		Stages = stages :: { BloodlineTypes.BloodlineStageDefinition },
	},
		nil
end

return BloodlineManager
