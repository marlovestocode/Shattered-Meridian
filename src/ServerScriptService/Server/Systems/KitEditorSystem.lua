--!strict
--[[
	KitEditorSystem.lua

	Owns: authorization + rate-limiting, every Constants.KitEditor.RemoteNames RemoteFunction, and
	DataStore persistence for BOTH Race Trait and Bloodline content -- the "System" half of the
	Manager/System pairing whose "Manager" halves are Server/Managers/RaceManager.lua and
	Server/Managers/BloodlineManager.lua. Mirrors MoveEditorSystem.lua's own shape closely: AdminGate.
	Check (auth + rate limit) with its own dedicated rateLimiter bucket, one DataStore key per
	definition plus a small fixed-key index record maintained via UpdateAsync for atomicity (DataStore
	has no native "list all keys", and an admin-authored content count is small -- tens, not
	thousands), schema-versioned records, and explicit-Save-only persistence -- UpdateDraft mutates the
	live in-memory registry immediately with NO DataStore write, the same "an unreviewed mid-edit value
	reaching disk is worse than a lost draft" rule MoveEditorSystem.lua's own header states.

	ONE SYSTEM FOR TWO CONTENT TYPES, not two -- Race Traits and Bloodlines share one editor screen
	(the Race Traits + Bloodline Abilities plan's own "the roster sidebar just has two groups" design),
	so this System owns both content types' remotes rather than splitting into RaceEditorSystem/
	BloodlineEditorSystem, which would duplicate every one of the ten request handlers below for
	nothing. addToIndex/removeFromIndex ARE genuinely shared (both content types' index records are
	the identical `{ Ids: {string} }` shape, just under different keys) -- the ten request handlers
	themselves stay separate, unabstracted functions, matching how MoveEditorSystem itself keeps
	handleListMoves/handleListDefaultMoves as two plain functions rather than one generic over two
	Result payload shapes Luau's type system would fight to express cleanly.

	NO CANDIDATE-TO-ROBLOX-TYPE RECONSTRUCTION, unlike MoveEditorSystem's own candidateFromStoredRecord
	-- every field on a RaceTraitDefinition/BloodlineDefinition (and everything KitAbilityDefinition/
	ActiveModifierSpec carry) is already a DataStore-safe primitive (string/number/boolean, nested in
	plain tables, no Vector3/CFrame/Color3 anywhere in either schema), so a stored record can be handed
	to RaceManager.Validate/BloodlineManager.Validate directly as its own decode step -- the identical
	"Validate is what both a client candidate and a DataStore-loaded record go through" contract
	MoveRegistryManager.Validate already establishes, just without a geometry-decomposition step
	in between.

	Does not own: the live in-memory registries themselves, either content type's Validate allow-list
	(RaceManager.lua/BloodlineManager.lua), or the admin whitelist (Server/Config/AdminConfig.lua).
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)
local RaceManager = require(script.Parent.Parent.Managers.RaceManager)
local BloodlineManager = require(script.Parent.Parent.Managers.BloodlineManager)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local AuthoredContentStore = require(script.Parent.Support.AuthoredContentStore)

local KitEditorSystem = {}

local logger = Logger.scope("KitEditorSystem")

local Config = Constants.KitEditor

-- Same shared admin-tooling budget MoveEditorSystem/DevMenuSystem/LiveConsoleSystem's own
-- rateLimiter each draw from, rather than a new per-feature Constants.KitEditor tunable -- this
-- module has no balance surface of its own, only an authoring rate to cap.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

local raceTraitStore: DataStore? = nil
local bloodlineStore: DataStore? = nil

local RACE_TRAIT_INDEX_KEY = "RaceTraitIndex"
local BLOODLINE_INDEX_KEY = "BloodlineIndex"

local function raceTraitRecordKey(traitId: string): string
	return "RaceTrait_" .. traitId
end

local function bloodlineRecordKey(bloodlineId: string): string
	return "Bloodline_" .. bloodlineId
end

-- Shared auth + rate-limit precondition -- Server/Network/AdminGate.lua's own Check, the same module
-- MoveEditorSystem's checkMoveEditorPreconditions already wraps.
local function checkKitEditorPreconditions(player: Player, actionName: string): (boolean, string?)
	return AdminGate.Check(player, actionName, rateLimiter)
end

-- The pcall boundary every RemoteFunction handler below goes through, bound once to this module's own
-- logger and error result -- see Shared/RemoteHandler.Scoped. This used to be a ten-line local that
-- WAS that binding written out longhand, kept on the grounds that "generalizing that one too was
-- ruled out"; the only difference it actually had from WrapInvoke was baking in the two things
-- WrapInvoke already takes as parameters. Every call site below is unchanged.
local wrapHandler = RemoteHandler.Scoped(logger, { Success = false, Reason = "InternalError" })

-- The retry/backoff wrapper every DataStore call below goes through, bound once to this module's own
-- logger and to the ONE policy (Constants.Storage.RetryPolicy). Five Systems each held this same
-- three-line local, differing only in which Constants table they read the same two numbers out of;
-- see Shared/DataStoreRetry.Scoped's own header. Call sites are unchanged -- still
-- withRetry(operationName, attempt).
local withRetry = DataStoreRetry.Scoped(logger, Constants.Storage.RetryPolicy)

--
-- Encode -- explicit field lists, never a raw pass-through of the live struct, matching
-- PlayerDataSystem.EncodeProfile/MoveEditorSystem.encodeMoveRecord's own defensive posture: a live
-- shape can grow a field a pass-through would silently start dropping or a blind clone would silently
-- start persisting unreviewed. Exported at the bottom of this file so a spec can round-trip these
-- against RaceManager.Validate/BloodlineManager.Validate headlessly -- see this codebase's own
-- postmortem on exactly this bug class (Art/Grab silently not persisting because an encode function
-- forgot to write them).
--

local function encodeModifierSpec(spec: Types.ActiveModifierSpec): { [string]: any }
	return {
		Kind = spec.Kind,
		Lifetime = spec.Lifetime,
		AttributeKey = spec.AttributeKey,
		Delta = spec.Delta,
		Tag = spec.Tag,
		Magnitude = spec.Magnitude,
		QiRestoreAmount = spec.QiRestoreAmount,
		DurationSeconds = spec.DurationSeconds,
	}
end

local function encodeEffects(effects: { Types.ActiveModifierSpec }): { { [string]: any } }
	local encoded = {}
	for _, effect in ipairs(effects) do
		table.insert(encoded, encodeModifierSpec(effect))
	end
	return encoded
end

local function encodeAbility(ability: KitTypes.KitAbilityDefinition): { [string]: any }
	return {
		Id = ability.Id,
		DisplayName = ability.DisplayName,
		Description = ability.Description,
		Kind = ability.Kind,
		CooldownSeconds = ability.CooldownSeconds,
		QiCost = ability.QiCost,
		Effects = encodeEffects(ability.Effects),
	}
end

local function encodeRaceTraitRecord(trait: RaceTraitTypes.RaceTraitDefinition): { [string]: any }
	return {
		SchemaVersion = Config.SchemaVersion,
		TraitId = trait.TraitId,
		RaceId = trait.RaceId,
		RequiredTier = trait.RequiredTier,
		Ability = encodeAbility(trait.Ability),
	}
end

local function encodeStage(stage: BloodlineTypes.BloodlineStageDefinition): { [string]: any }
	return {
		StageIndex = stage.StageIndex,
		DisplayName = stage.DisplayName,
		PassiveEffects = encodeEffects(stage.PassiveEffects),
		GrantedAbility = if stage.GrantedAbility then encodeAbility(stage.GrantedAbility) else nil,
	}
end

local function encodeBloodlineRecord(bloodline: BloodlineTypes.BloodlineDefinition): { [string]: any }
	local stages = {}
	for _, stage in ipairs(bloodline.Stages) do
		table.insert(stages, encodeStage(stage))
	end
	return {
		SchemaVersion = Config.SchemaVersion,
		BloodlineId = bloodline.BloodlineId,
		DisplayName = bloodline.DisplayName,
		RarityTier = bloodline.RarityTier,
		FlavorText = bloodline.FlavorText,
		NativeRaceId = bloodline.NativeRaceId,
		AwakeningCondition = {
			Kind = bloodline.AwakeningCondition.Kind,
			Params = bloodline.AwakeningCondition.Params,
		},
		Stages = stages,
	}
end

--
-- Index maintenance -- genuinely shared between both content types (see this file's own header):
-- both index records are the identical `{ Ids: {string} }` shape, just under different keys.
-- Atomic (UpdateAsync, not a separate Get-then-Set) so two admins saving/deleting different entries
-- of the SAME content type at nearly the same moment can never clobber each other's index entry --
-- same reasoning MoveEditorSystem.addToIndex/removeFromIndex's own header gives.
--

-- Both halves live in Systems/Support/AuthoredContentStore.lua now -- MoveEditorSystem held the same
-- twenty lines twice over, differing only in the field name and the log prefix.
--
-- "Ids" IS THE PERSISTED FIELD NAME and must stay exactly that: it is the key
-- loadPersistedRaceTraits/loadPersistedBloodlines below read back out of the index document
-- (`(indexRaw :: { [string]: any }).Ids`). MoveEditorSystem's is "MoveIds". The two are not
-- interchangeable, which is why the shared helper takes the field explicitly rather than assuming.
local INDEX_FIELD = "Ids"

local function addToIndex(store: DataStore, indexKey: string, id: string): boolean
	return AuthoredContentStore.AddToIndex(withRetry, "KitEditor", store, indexKey, INDEX_FIELD, id)
end

local function removeFromIndex(store: DataStore, indexKey: string, id: string): boolean
	return AuthoredContentStore.RemoveFromIndex(withRetry, "KitEditor", store, indexKey, INDEX_FIELD, id)
end

--
-- Race Trait remotes
--

local function handleListRaceTraits(player: Player): RaceTraitTypes.RaceTraitEditorListResult
	local allowed, reason = checkKitEditorPreconditions(player, "ListRaceTraits")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	return { Success = true, Traits = RaceManager.List() }
end

local function handleGetRaceTrait(player: Player, rawTraitId: unknown): RaceTraitTypes.RaceTraitEditorTraitResult
	local allowed, reason = checkKitEditorPreconditions(player, "GetRaceTrait")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawTraitId) ~= "string" then
		return { Success = false, Reason = "InvalidTraitId" }
	end
	local trait = RaceManager.Get(rawTraitId)
	if not trait then
		return { Success = false, Reason = "TraitNotFound" }
	end
	return { Success = true, Trait = trait }
end

-- In-memory only -- no DataStore write, see this file's header for why this is what makes an edit
-- take effect immediately in RaceManager's live registry.
local function handleUpdateRaceTraitDraft(player: Player, rawTrait: unknown): RaceTraitTypes.RaceTraitEditorTraitResult
	local allowed, reason = checkKitEditorPreconditions(player, "UpdateRaceTraitDraft")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local validated, validateReason = RaceManager.Validate(rawTrait)
	if not validated then
		return { Success = false, Reason = validateReason }
	end
	RaceManager.Upsert(validated)
	return { Success = true, Trait = validated }
end

local function handleSaveRaceTrait(player: Player, rawTrait: unknown): RaceTraitTypes.RaceTraitEditorTraitResult
	local allowed, reason = checkKitEditorPreconditions(player, "SaveRaceTrait")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local validated, validateReason = RaceManager.Validate(rawTrait)
	if not validated then
		return { Success = false, Reason = validateReason }
	end
	RaceManager.Upsert(validated)

	if not raceTraitStore then
		return { Success = false, Reason = "StorageError" }
	end
	local setOk = withRetry("KitEditor SaveRaceTrait SetAsync", function()
		(raceTraitStore :: DataStore):SetAsync(raceTraitRecordKey(validated.TraitId), encodeRaceTraitRecord(validated))
	end)
	if not setOk then
		return { Success = false, Reason = "StorageError" }
	end
	if not addToIndex(raceTraitStore :: DataStore, RACE_TRAIT_INDEX_KEY, validated.TraitId) then
		logger:error(
			"SaveRaceTrait: index update failed, trait saved but may not list after a restart",
			{ traitId = validated.TraitId }
		)
	end

	logger:info("SaveRaceTrait accepted", { admin = player.Name, traitId = validated.TraitId })
	return { Success = true, Trait = validated }
end

local function handleDeleteRaceTrait(player: Player, rawTraitId: unknown): RaceTraitTypes.RaceTraitEditorActionResult
	local allowed, reason = checkKitEditorPreconditions(player, "DeleteRaceTrait")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawTraitId) ~= "string" then
		return { Success = false, Reason = "InvalidTraitId" }
	end

	RaceManager.Delete(rawTraitId)

	if raceTraitStore then
		withRetry("KitEditor DeleteRaceTrait RemoveAsync", function()
			(raceTraitStore :: DataStore):RemoveAsync(raceTraitRecordKey(rawTraitId))
		end)
		if not removeFromIndex(raceTraitStore :: DataStore, RACE_TRAIT_INDEX_KEY, rawTraitId) then
			logger:error(
				"DeleteRaceTrait: index update failed, record removed but may reappear after a restart",
				{ traitId = rawTraitId }
			)
		end
	end

	logger:info("DeleteRaceTrait accepted", { admin = player.Name, traitId = rawTraitId })
	return { Success = true }
end

--
-- Bloodline remotes
--

local function handleListBloodlines(player: Player): BloodlineTypes.BloodlineEditorListResult
	local allowed, reason = checkKitEditorPreconditions(player, "ListBloodlines")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	return { Success = true, Bloodlines = BloodlineManager.List() }
end

local function handleGetBloodline(
	player: Player,
	rawBloodlineId: unknown
): BloodlineTypes.BloodlineEditorBloodlineResult
	local allowed, reason = checkKitEditorPreconditions(player, "GetBloodline")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawBloodlineId) ~= "string" then
		return { Success = false, Reason = "InvalidBloodlineId" }
	end
	local bloodline = BloodlineManager.Get(rawBloodlineId)
	if not bloodline then
		return { Success = false, Reason = "BloodlineNotFound" }
	end
	return { Success = true, Bloodline = bloodline }
end

local function handleUpdateBloodlineDraft(
	player: Player,
	rawBloodline: unknown
): BloodlineTypes.BloodlineEditorBloodlineResult
	local allowed, reason = checkKitEditorPreconditions(player, "UpdateBloodlineDraft")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local validated, validateReason = BloodlineManager.Validate(rawBloodline)
	if not validated then
		return { Success = false, Reason = validateReason }
	end
	BloodlineManager.Upsert(validated)
	return { Success = true, Bloodline = validated }
end

local function handleSaveBloodline(player: Player, rawBloodline: unknown): BloodlineTypes.BloodlineEditorBloodlineResult
	local allowed, reason = checkKitEditorPreconditions(player, "SaveBloodline")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local validated, validateReason = BloodlineManager.Validate(rawBloodline)
	if not validated then
		return { Success = false, Reason = validateReason }
	end
	BloodlineManager.Upsert(validated)

	if not bloodlineStore then
		return { Success = false, Reason = "StorageError" }
	end
	local setOk = withRetry("KitEditor SaveBloodline SetAsync", function()
		(bloodlineStore :: DataStore):SetAsync(
			bloodlineRecordKey(validated.BloodlineId),
			encodeBloodlineRecord(validated)
		)
	end)
	if not setOk then
		return { Success = false, Reason = "StorageError" }
	end
	if not addToIndex(bloodlineStore :: DataStore, BLOODLINE_INDEX_KEY, validated.BloodlineId) then
		logger:error(
			"SaveBloodline: index update failed, bloodline saved but may not list after a restart",
			{ bloodlineId = validated.BloodlineId }
		)
	end

	logger:info("SaveBloodline accepted", { admin = player.Name, bloodlineId = validated.BloodlineId })
	return { Success = true, Bloodline = validated }
end

local function handleDeleteBloodline(
	player: Player,
	rawBloodlineId: unknown
): BloodlineTypes.BloodlineEditorActionResult
	local allowed, reason = checkKitEditorPreconditions(player, "DeleteBloodline")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawBloodlineId) ~= "string" then
		return { Success = false, Reason = "InvalidBloodlineId" }
	end

	BloodlineManager.Delete(rawBloodlineId)

	if bloodlineStore then
		withRetry("KitEditor DeleteBloodline RemoveAsync", function()
			(bloodlineStore :: DataStore):RemoveAsync(bloodlineRecordKey(rawBloodlineId))
		end)
		if not removeFromIndex(bloodlineStore :: DataStore, BLOODLINE_INDEX_KEY, rawBloodlineId) then
			logger:error(
				"DeleteBloodline: index update failed, record removed but may reappear after a restart",
				{ bloodlineId = rawBloodlineId }
			)
		end
	end

	logger:info("DeleteBloodline accepted", { admin = player.Name, bloodlineId = rawBloodlineId })
	return { Success = true }
end

--
-- Boot-time load -- backgrounded (task.spawn, same reasoning MoveEditorSystem.loadPersistedMoves'
-- own header gives) so a slow index page-through never blocks Main.server.lua's synchronous boot
-- chain. A record that fails to decode/validate is skipped and logged, never crashes the load --
-- corrupt or hand-edited DataStore content degrades safely, same as PlayerDataSystem's own
-- DecodeProfile contract.
--

local function loadPersistedRaceTraits(): ()
	if not raceTraitStore then
		return
	end
	local indexOk, indexRaw = withRetry("KitEditor loadPersistedRaceTraits index GetAsync", function()
		return (raceTraitStore :: DataStore):GetAsync(RACE_TRAIT_INDEX_KEY)
	end)
	if not indexOk then
		logger:error("loadPersistedRaceTraits: index GetAsync failed, starting with an empty registry")
		return
	end
	if typeof(indexRaw) ~= "table" then
		logger:info("loadPersistedRaceTraits: no existing trait index, starting empty")
		return
	end
	local ids = (indexRaw :: { [string]: any }).Ids
	if typeof(ids) ~= "table" then
		return
	end

	local loadedCount = 0
	for _, rawId in ipairs(ids :: { unknown }) do
		if typeof(rawId) == "string" then
			local getOk, raw = withRetry("KitEditor loadPersistedRaceTraits record GetAsync", function()
				return (raceTraitStore :: DataStore):GetAsync(raceTraitRecordKey(rawId))
			end)
			if getOk and raw ~= nil then
				local validated, reason = RaceManager.Validate(raw)
				if validated then
					RaceManager.Upsert(validated)
					loadedCount += 1
				else
					logger:warn("loadPersistedRaceTraits: skipped invalid record", { traitId = rawId, reason = reason })
				end
			else
				logger:warn("loadPersistedRaceTraits: skipped record that failed to fetch", { traitId = rawId })
			end
		end
	end
	logger:info("loadPersistedRaceTraits complete", { loadedCount = loadedCount })
end

local function loadPersistedBloodlines(): ()
	if not bloodlineStore then
		return
	end
	local indexOk, indexRaw = withRetry("KitEditor loadPersistedBloodlines index GetAsync", function()
		return (bloodlineStore :: DataStore):GetAsync(BLOODLINE_INDEX_KEY)
	end)
	if not indexOk then
		logger:error("loadPersistedBloodlines: index GetAsync failed, starting with an empty registry")
		return
	end
	if typeof(indexRaw) ~= "table" then
		logger:info("loadPersistedBloodlines: no existing bloodline index, starting empty")
		return
	end
	local ids = (indexRaw :: { [string]: any }).Ids
	if typeof(ids) ~= "table" then
		return
	end

	local loadedCount = 0
	for _, rawId in ipairs(ids :: { unknown }) do
		if typeof(rawId) == "string" then
			local getOk, raw = withRetry("KitEditor loadPersistedBloodlines record GetAsync", function()
				return (bloodlineStore :: DataStore):GetAsync(bloodlineRecordKey(rawId))
			end)
			if getOk and raw ~= nil then
				local validated, reason = BloodlineManager.Validate(raw)
				if validated then
					BloodlineManager.Upsert(validated)
					loadedCount += 1
				else
					logger:warn(
						"loadPersistedBloodlines: skipped invalid record",
						{ bloodlineId = rawId, reason = reason }
					)
				end
			else
				logger:warn("loadPersistedBloodlines: skipped record that failed to fetch", { bloodlineId = rawId })
			end
		end
	end
	logger:info("loadPersistedBloodlines complete", { loadedCount = loadedCount })

	-- Audited HERE rather than in BloodlineManager.Init, which is the only place the records exist
	-- to audit -- see that function's own note. Never fatal: a bad authored entry should cost the
	-- bloodline an unreachable stage and show up in a log, not stop the server, the same contract
	-- Validate/AuditStages already split between them.
	for _, problem in ipairs(BloodlineManager.AuditAll()) do
		logger:warn("Bloodline stage problem", { problem = problem })
	end
end

-- Assumes RaceManager.Init()/BloodlineManager.Init() have already run (Main.server.lua boots both
-- before this System -- see that file's boot-order comments) -- this function only POPULATES the
-- already-initialized registries.
function KitEditorSystem.Init(): ()
	raceTraitStore = DataStoreService:GetDataStore(StorageConfig.RaceTraitDataStoreName)
	bloodlineStore = DataStoreService:GetDataStore(StorageConfig.BloodlineDataStoreName)

	task.spawn(loadPersistedRaceTraits)
	task.spawn(loadPersistedBloodlines)

	local listRaceTraitsRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.ListRaceTraits)
	listRaceTraitsRemote.OnServerInvoke = wrapHandler("ListRaceTraits", handleListRaceTraits)

	local getRaceTraitRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.GetRaceTrait)
	getRaceTraitRemote.OnServerInvoke = wrapHandler("GetRaceTrait", handleGetRaceTrait)

	local updateRaceTraitDraftRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.UpdateRaceTraitDraft)
	updateRaceTraitDraftRemote.OnServerInvoke = wrapHandler("UpdateRaceTraitDraft", handleUpdateRaceTraitDraft)

	local saveRaceTraitRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.SaveRaceTrait)
	saveRaceTraitRemote.OnServerInvoke = wrapHandler("SaveRaceTrait", handleSaveRaceTrait)

	local deleteRaceTraitRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.DeleteRaceTrait)
	deleteRaceTraitRemote.OnServerInvoke = wrapHandler("DeleteRaceTrait", handleDeleteRaceTrait)

	local listBloodlinesRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.ListBloodlines)
	listBloodlinesRemote.OnServerInvoke = wrapHandler("ListBloodlines", handleListBloodlines)

	local getBloodlineRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.GetBloodline)
	getBloodlineRemote.OnServerInvoke = wrapHandler("GetBloodline", handleGetBloodline)

	local updateBloodlineDraftRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.UpdateBloodlineDraft)
	updateBloodlineDraftRemote.OnServerInvoke = wrapHandler("UpdateBloodlineDraft", handleUpdateBloodlineDraft)

	local saveBloodlineRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.SaveBloodline)
	saveBloodlineRemote.OnServerInvoke = wrapHandler("SaveBloodline", handleSaveBloodline)

	local deleteBloodlineRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.DeleteBloodline)
	deleteBloodlineRemote.OnServerInvoke = wrapHandler("DeleteBloodline", handleDeleteBloodline)

	PlayerLifecycle.BindAllPlayers({
		Scope = "KitEditorSystem",
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
		end,
	})

	logger:info("KitEditorSystem.Init() complete")
end

-- Exported specifically so this System's regression tests can exercise the DataStore encode round
-- trip headlessly (encode a definition, run the result back through RaceManager.Validate/
-- BloodlineManager.Validate, assert nothing was lost) -- the same "pure logic gets its own export"
-- precedent MoveEditorSystem.EncodeMoveRecord/CandidateFromStoredRecord already establish, and
-- exactly the pairing that would have caught this codebase's own prior Art/Grab-never-persisted bug
-- before it shipped.
KitEditorSystem.EncodeRaceTraitRecord = encodeRaceTraitRecord
KitEditorSystem.EncodeBloodlineRecord = encodeBloodlineRecord

return KitEditorSystem :: Types.SystemModule
