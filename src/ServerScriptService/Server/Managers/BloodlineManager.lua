--!strict
--[[
	BloodlineManager.lua

	Owns: the live, in-memory registry of Bloodline content (Shared/Bloodline/BloodlineTypes.
	BloodlineDefinition), keyed by BloodlineId. The "Manager" half of the Race Traits + Bloodline
	Abilities plan's Bloodline layer -- Server/Systems/BloodlineSystem.lua is the "System" half that
	owns a player's awakening state and stage progress. Mirrors Server/Managers/RaceManager.lua's own
	role for the sibling Race layer, and MoveRegistryManager/MoveEditorSystem's own Manager/System
	split more generally.

	Same "no lower layer to derive from" position RaceManager.lua's own header describes: a bloodline
	isn't a move, so this module IS the one source of truth for bloodline content.

	Validate is the one gate every untrusted BloodlineDefinition-shaped table passes through -- same
	"a client-authored candidate and a DataStore-loaded record go through the identical function"
	contract MoveRegistryManager.Validate/RaceManager.Validate already establish. A structural error
	(wrong type, an unrecognized NativeRaceId, a missing AwakeningCondition.Kind) is a hard reject; an
	in-range numeric field clamps instead, against Constants.Kit.Limits. Each Stage's own
	GrantedAbility/PassiveEffects delegate to Shared/Kit/KitValidation.lua rather than reimplementing
	that validation here -- see that module's own header for why it's shared with RaceManager.Validate
	rather than duplicated.

	AuditStages is a SEPARATE, non-fatal check from Validate -- mirrors ArtTreeManager.
	AuditPrerequisites' own reasoning exactly: contiguity across a whole authored Stages array (no
	gaps, no duplicate StageIndex) is a cross-entry property Validate can't see while validating one
	stage at a time, and a bad edit here should cost the bloodline an unreachable stage, never crash
	the save or silently renumber what an author typed.

	Upsert/Delete mutate the in-memory table ONLY -- no DataStore I/O here. Persistence is
	Server/Systems/KitEditorSystem.lua's job: it validates through this module on the way in, writes
	the record, and replays every persisted bloodline back through Validate + Upsert at boot
	(loadPersistedBloodlines). An EMPTY registry is still a fully legal, tested state -- see Init().

	HOW A BLOODLINE ACTUALLY GETS AUTHORED, because the chain is long and every link is real: the
	admin opens the Kit Editor ([ -- Client/KitEditor/KitEditorClient.lua), which round-trips through
	KitEditorSystem's admin-gated remotes into Validate/Upsert here, and KitEditorSystem persists it.
	That client module had NO INBOUND REQUIRE until it was wired into Main.client.lua/UI/init.lua --
	so nothing ever called any of this, and the registry was empty in practice rather than in
	principle. Worth knowing before concluding from a quiet log that the content layer is unfinished.

	Does not own: per-player awakening/stage state (BloodlineSystem), the generic modifier engine a
	stage's PassiveEffects/GrantedAbility.Effects are applied through (EffectSystem), ability/effect
	validation itself (Shared/Kit/KitValidation.lua), or authorization/persistence (KitEditorSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local KitValidation = require(ReplicatedStorage.Shared.Kit.KitValidation)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("BloodlineManager")

local BloodlineManager = {}

local KitLimits = Constants.Kit.Limits

local RACE_IDS: { [string]: boolean } = { Human = true, Firmborn = true, Rivenkin = true, Hollowborn = true }

-- Long enough for a real name/flavor paragraph, short enough that a pasted essay can't bloat a future
-- DataStore record -- same reasoning MoveRegistryManager's own MAX_DESCRIPTION_LENGTH gives.
local MAX_NAME_LENGTH = 64
local MAX_FLAVOR_LENGTH = 800
local MAX_CONDITION_KIND_LENGTH = 64

local bloodlines: { [string]: BloodlineTypes.BloodlineDefinition } = {}

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

-- Deep-enough copy for a caller to freely mutate without corrupting the registry -- same "return a
-- copy, never the live table" contract RaceManager.lua's own copyTrait already establishes for its
-- identically-shaped problem. Stages is the one nested array this shape carries; each stage's own
-- PassiveEffects (and, if present, GrantedAbility.Effects) is the one level deeper than RaceManager's
-- copyTrait needs to go, since a bloodline's abilities live one level further down than a trait's.
local function copyBloodline(bloodline: BloodlineTypes.BloodlineDefinition): BloodlineTypes.BloodlineDefinition
	local copy = table.clone(bloodline)
	copy.AwakeningCondition = table.clone(bloodline.AwakeningCondition)
	copy.AwakeningCondition.Params = table.clone(bloodline.AwakeningCondition.Params)

	local stages: { BloodlineTypes.BloodlineStageDefinition } = {}
	for _, stage in ipairs(bloodline.Stages) do
		local stageCopy = table.clone(stage)

		local passiveEffects: { Types.ActiveModifierSpec } = {}
		for _, effect in ipairs(stage.PassiveEffects) do
			table.insert(passiveEffects, table.clone(effect))
		end
		stageCopy.PassiveEffects = passiveEffects

		if stage.GrantedAbility then
			local ability = table.clone(stage.GrantedAbility)
			local abilityEffects: { Types.ActiveModifierSpec } = {}
			for _, effect in ipairs(stage.GrantedAbility.Effects) do
				table.insert(abilityEffects, table.clone(effect))
			end
			ability.Effects = abilityEffects
			stageCopy.GrantedAbility = ability
		end

		table.insert(stages, stageCopy)
	end
	copy.Stages = stages

	return copy
end

function BloodlineManager.List(): { BloodlineTypes.BloodlineDefinition }
	local result = {}
	for _, bloodline in pairs(bloodlines) do
		table.insert(result, copyBloodline(bloodline))
	end
	return result
end

function BloodlineManager.Get(bloodlineId: string): BloodlineTypes.BloodlineDefinition?
	local bloodline = bloodlines[bloodlineId]
	if not bloodline then
		return nil
	end
	return copyBloodline(bloodline)
end

-- In-memory write only -- see this file's header for why this is what makes an edit take effect
-- immediately with no DataStore round trip. `validated` must already have passed Validate; this
-- function trusts its caller (KitEditorSystem, once it exists) on that, the same "Upsert-after-
-- Validate are two separate steps" contract MoveRegistryManager.Upsert/RaceManager.Upsert already
-- document.
function BloodlineManager.Upsert(validated: BloodlineTypes.BloodlineDefinition): ()
	bloodlines[validated.BloodlineId] = copyBloodline(validated)
end

function BloodlineManager.Delete(bloodlineId: string): ()
	bloodlines[bloodlineId] = nil
end

-- Reports (never repairs) a non-contiguous or duplicated StageIndex within ONE bloodline's authored
-- Stages array -- see this file's header for why this is a separate, non-fatal check from Validate.
-- {} for an unknown bloodlineId or one with zero authored stages (nothing to be non-contiguous about).
function BloodlineManager.AuditStages(bloodlineId: string): { string }
	local problems: { string } = {}
	local bloodline = bloodlines[bloodlineId]
	if not bloodline then
		return problems
	end

	local seen: { [number]: boolean } = {}
	local maxIndex = 0
	for _, stage in ipairs(bloodline.Stages) do
		if seen[stage.StageIndex] then
			table.insert(problems, `{bloodlineId}: duplicate StageIndex {stage.StageIndex}`)
		end
		seen[stage.StageIndex] = true
		maxIndex = math.max(maxIndex, stage.StageIndex)
	end
	for index = 1, maxIndex do
		if not seen[index] then
			table.insert(problems, `{bloodlineId}: missing StageIndex {index} -- stages are not contiguous`)
		end
	end
	return problems
end

-- Every stage problem across the WHOLE registry, in one call -- the shape
-- ArtTreeManager.AuditPrerequisites already has, and the shape a post-load caller actually needs
-- (it has just loaded N records and wants to know if any of them are bad, without knowing their
-- ids). AuditStages above stays public for the per-bloodline case the editor's own save path uses.
function BloodlineManager.AuditAll(): { string }
	local problems: { string } = {}
	for _, bloodline in ipairs(BloodlineManager.List()) do
		for _, problem in ipairs(BloodlineManager.AuditStages(bloodline.BloodlineId)) do
			table.insert(problems, problem)
		end
	end
	return problems
end

function BloodlineManager.Init(): ()
	bloodlines = {}

	-- STILL A PURE RESET, deliberately. The canon roster is seeded by DefaultBloodlineRegistry's own
	-- boot step immediately after this one, not from here: this function's "resets to empty" contract
	-- is what BloodlineManager.spec.lua uses to get a clean slate per test, and overloading it with
	-- content would make every count assertion in that file depend on the size of the roster.

	-- DELIBERATELY NO AUDIT HERE. There used to be one, and it could only ever find nothing: this
	-- Manager boots at Main.server.lua step 197 while the records it would audit are loaded by
	-- KitEditorSystem at step 365 (and asynchronously, inside a task.spawn, at that). It audited an
	-- empty registry every single boot and logged clean, which is worse than not auditing at all --
	-- it reads like a passing check. KitEditorSystem.loadPersistedBloodlines now calls AuditAll above
	-- the moment the records actually exist, which is the only point at which the answer means
	-- anything.

	logger:info("BloodlineManager.Init() complete")
end

return BloodlineManager :: Types.SystemModule
