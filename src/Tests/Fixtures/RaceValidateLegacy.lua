--!strict
-- FROZEN COPY, taken before the validators were converted to Shared/Schema (2026-10-25, coworking plan W4). It exists only
-- so Tests/Kit/KitValidatorsEquivalence.spec.lua can run the old hand-written `typeof` validators and the converted ones
-- over one corpus and assert identical answers. Nothing under src/ outside Tests requires it. Do not edit it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local KitValidation = require(ServerScriptService.Tests.Fixtures.KitValidationLegacy)

local RaceManager = {}

local KitLimits = Constants.Kit.Limits

local RACE_IDS: { [string]: boolean } = { Human = true, Firmborn = true, Rivenkin = true, Hollowborn = true }

local function isNonEmptyString(value: unknown): boolean
	return typeof(value) == "string" and (value :: string) ~= ""
end

-- The one strict allow-list gate every RaceTraitDefinition-shaped table passes through -- see this
-- file's header. `candidate` is `unknown` deliberately, same reasoning as MoveRegistryManager.
-- Validate: it may be a raw client RemoteFunction argument, a DataStore-decoded record, or (in a
-- test) a hand-written table literal, and this treats all three identically.
function RaceManager.Validate(candidate: unknown): (RaceTraitTypes.RaceTraitDefinition?, string?)
	if typeof(candidate) ~= "table" then
		return nil, "InvalidShape"
	end
	local raw = candidate :: { [string]: unknown }

	if not isNonEmptyString(raw.TraitId) then
		return nil, "InvalidTraitId"
	end
	if typeof(raw.RaceId) ~= "string" or not RACE_IDS[raw.RaceId :: string] then
		return nil, "InvalidRaceId"
	end
	local requiredTier =
		KitValidation.ClampedNumber(raw.RequiredTier, KitLimits.RequiredTier.Min, KitLimits.RequiredTier.Max)
	if requiredTier == nil then
		return nil, "InvalidRequiredTier"
	end
	local ability, abilityError = KitValidation.ValidateAbility(raw.Ability)
	if abilityError then
		return nil, abilityError
	end

	return {
		TraitId = raw.TraitId :: string,
		RaceId = raw.RaceId :: Types.RaceId,
		RequiredTier = math.floor(requiredTier),
		Ability = ability :: KitTypes.KitAbilityDefinition,
	},
		nil
end

return RaceManager
