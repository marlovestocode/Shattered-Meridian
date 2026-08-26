--!strict
--[[
	RaceManager.lua

	Owns: the live, in-memory registry of Race Trait content (Shared/Race/RaceTraitTypes.
	RaceTraitDefinition), keyed by TraitId. The "Manager" half of the Race Traits + Bloodline
	Abilities plan's Race layer -- Server/Systems/RaceSystem.lua is the "System" half that owns a
	player's eligibility and use of these traits. Mirrors MoveRegistryManager/MoveEditorSystem's own
	Manager/System split.

	UNLIKE ArtTreeManager (which derives its whole index from MoveRegistryManager on every query --
	see that module's own header), there is no lower layer to derive from: a trait isn't a move, so
	this module IS the one source of truth for trait content, the same "live in-memory table, no
	DataStore I/O here" role MoveRegistryManager plays for moves.

	Validate is the one gate every untrusted RaceTraitDefinition-shaped table passes through -- the
	same "a client-authored candidate and a DataStore-loaded record go through the identical
	function" contract MoveRegistryManager.Validate already establishes. A structural error (wrong
	type, an unrecognized RaceId, a missing Ability field) is a hard reject; an in-range numeric field
	clamps instead, against Constants.Kit.Limits. Everything about validating the Ability itself
	(and the ActiveModifierSpec effects it carries) delegates to Shared/Kit/KitValidation.lua rather
	than reimplementing it here -- see that module's own header for why it's shared with
	BloodlineManager.Validate rather than duplicated.

	Upsert/Delete mutate the in-memory table ONLY -- no DataStore I/O here. That is
	KitEditorSystem's job, once it exists; until then this registry boots and stays empty, which is a
	fully legal, tested state -- see Init(). RaceSystem's own eligibility checks against an empty
	registry simply find nothing to grant, the same way ArtTreeManager/MoveRegistryManager behave
	before any content is authored.

	Does not own: per-player trait eligibility or use (RaceSystem), the generic modifier engine a
	trait's Ability.Effects is applied through (EffectSystem), ability/effect validation itself
	(Shared/Kit/KitValidation.lua), or authorization/persistence (KitEditorSystem, not built yet).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local KitValidation = require(ReplicatedStorage.Shared.Kit.KitValidation)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("RaceManager")

local RaceManager = {}

local KitLimits = Constants.Kit.Limits

local RACE_IDS: { [string]: boolean } = { Human = true, Firmborn = true, Rivenkin = true, Hollowborn = true }

local traits: { [string]: RaceTraitTypes.RaceTraitDefinition } = {}

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

-- Deep-enough copy for a caller to freely mutate without corrupting the registry -- the same "return
-- a copy, never the live table" contract PlayerDataSystem.GetProfile/MoveRegistryManager.Get already
-- establish. Ability.Effects is the one nested array this shape carries, so a fresh table plus a
-- fresh entry per effect is sufficient -- no third level of nesting anywhere in this shape.
local function copyTrait(trait: RaceTraitTypes.RaceTraitDefinition): RaceTraitTypes.RaceTraitDefinition
	local ability = table.clone(trait.Ability)
	local effects: { Types.ActiveModifierSpec } = {}
	for _, effect in ipairs(trait.Ability.Effects) do
		table.insert(effects, table.clone(effect))
	end
	ability.Effects = effects

	local copy = table.clone(trait)
	copy.Ability = ability
	return copy
end

function RaceManager.List(): { RaceTraitTypes.RaceTraitDefinition }
	local result = {}
	for _, trait in pairs(traits) do
		table.insert(result, copyTrait(trait))
	end
	return result
end

function RaceManager.Get(traitId: string): RaceTraitTypes.RaceTraitDefinition?
	local trait = traits[traitId]
	if not trait then
		return nil
	end
	return copyTrait(trait)
end

-- Every trait authored for `raceId`, RequiredTier ascending then TraitId for stability -- the same
-- "ties broken by a stable id, never left to pairs() order" reasoning
-- ArtTreeManager.GetArtsInTree's own header gives for its identical problem.
function RaceManager.GetTraitsForRace(raceId: Types.RaceId): { RaceTraitTypes.RaceTraitDefinition }
	local result: { RaceTraitTypes.RaceTraitDefinition } = {}
	for _, trait in pairs(traits) do
		if trait.RaceId == raceId then
			table.insert(result, copyTrait(trait))
		end
	end
	table.sort(result, function(a, b)
		if a.RequiredTier == b.RequiredTier then
			return a.TraitId < b.TraitId
		end
		return a.RequiredTier < b.RequiredTier
	end)
	return result
end

-- In-memory write only -- see this file's header for why this is what makes an edit take effect
-- immediately with no DataStore round trip. `validated` must already have passed Validate; this
-- function trusts its caller (KitEditorSystem, once it exists) on that, the same "Upsert-after-
-- Validate are two separate steps" contract MoveRegistryManager.Upsert already documents.
function RaceManager.Upsert(validated: RaceTraitTypes.RaceTraitDefinition): ()
	traits[validated.TraitId] = copyTrait(validated)
end

function RaceManager.Delete(traitId: string): ()
	traits[traitId] = nil
end

function RaceManager.Init(): ()
	traits = {}
	logger:info("RaceManager.Init() complete")
end

return RaceManager :: Types.SystemModule
