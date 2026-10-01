--!strict
--[[
	MoveEditorSystem.lua

	Owns: the Move Editor's server half -- every Constants.MoveEditor.RemoteNames remote, admin gating,
	DataStore persistence of custom moves and Default-move overrides, and building the MoveEditorTypes
	entries the editor reads. The "System" half of the pairing whose registries are Server/Combat/
	MoveRegistryManager.lua (custom moves) and Server/Combat/DefaultMoveRegistry.lua (weapon stages).

	REBUILT 2026-09-29, together with the whole editor. Three things the old System did not do and this one
	is built around:

	  * IT KNOWS WHAT IS SAVED. The persisted state of every move is held here (savedMoves), loaded at boot
	    and replaced on every Save. So "is this unsaved?" is a fact the server states in each entry
	    (SavedFingerprint), not something the client reconstructs from what it happens to remember -- it
	    survives closing and reopening the editor, and two admins see the same answer. It is also what
	    makes Revert possible at all: undoing unsaved work needs the saved version to go back to.

	  * IT SAYS WHAT THE MOVE WILL ACTUALLY DO. Each entry carries AttackCatalog's resolved timeline -- the
	    windup a strike marker set, the recovery the clip's length left -- plus plain-language notes (a Box
	    whose size the blade replaces, a custom move no player can reach). The old editor showed only the
	    numbers typed into it, which is how a move could look right in the editor and play differently.

	  * TEST IS A REAL SWING. TestFire throws the move from the admin's own character through
	    AttackRequestSystem.ThrowMove -- every gate, the engine, the damage layer -- not through a
	    Move-Editor-owned combat path that could drift from the real one.

	Save is explicit. Preview makes a draft LIVE (the next swing uses it) with no DataStore write; only
	Save persists. An unreviewed mid-edit value reaching disk, where another admin could load it, is worse
	than an admin losing an unsaved draft to a crash.

	IDENTITY IS STAMPED HERE, never taken from the client: MoveId (generated for a new move), Author and
	CreatedAt (kept from the existing move) and UpdatedAt (now) are set before Validate ever sees the
	candidate. A Default move's identity is fixed by its place in the roster and DefaultMoveRegistry
	.ApplyEdit ignores whatever the payload claims.

	Persistence shape: one key per custom move ("Move_<MoveId>") plus an index record ("MoveIndex" ->
	{ MoveIds }, maintained atomically through Support/AuthoredContentStore) because DataStore cannot list
	keys; one key per overridden Default move ("DefaultOverride_<MoveId>"), no index needed since the
	Default id set is enumerable. Every record is Support/MoveRecordCodec's -- which also upgrades records
	written before the rebuild.

	MUST NOT BE OMITTED FROM ANY BUILD. Init is the only thing that hydrates MoveRegistryManager and the
	Default overrides from DataStore; a server without it boots with no custom moves, no arts and every
	weapon at its built values, with no error anywhere. See CLAUDE.md's two-build-configs section.

	Does not own: validation (MoveRegistryManager.Validate), the override layer (DefaultMoveRegistry), the
	record format (MoveRecordCodec), resolving a move for combat (AttackCatalog), throwing it
	(AttackRequestSystem), or what an art unlocks (ArtSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)

local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)
local AttackCatalog = require(script.Parent.Parent.Combat.AttackCatalog)
local AttackRequestSystem = require(script.Parent.Parent.Combat.Attack.AttackRequestSystem)
local AuthoredMoveLibrary = require(script.Parent.Parent.Combat.AuthoredMoveLibrary)
local DefaultMoveRegistry = require(script.Parent.Parent.Combat.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.Parent.Combat.MoveRegistryManager)
local ArtTreeManager = require(script.Parent.Parent.Managers.ArtTreeManager)
local AdminActionSystem = require(script.Parent.AdminActionSystem)
local ArtSystem = require(script.Parent.ArtSystem)
local AuthoredContentStore = require(script.Parent.Support.AuthoredContentStore)
local MoveBalance = require(script.Parent.Support.MoveBalance)
local MoveRecordCodec = require(script.Parent.Support.MoveRecordCodec)
local MoveSourceWriter = require(script.Parent.Support.MoveSourceWriter)
local PresentationAudit = require(script.Parent.Support.PresentationAudit)

type MoveDefinition = MoveTypes.MoveDefinition
type MoveEntry = MoveEditorTypes.MoveEntry
type MoveSource = MoveEditorTypes.MoveSource

local MoveEditorSystem = {}

local logger = Logger.scope("MoveEditorSystem")

local Config = Constants.MoveEditor

local rateLimiter = RateLimiter.New(Config.MaxCallsPerSecond)

local wrapHandler = RemoteHandler.Scoped(logger, { Success = false, Reason = "InternalError" })
local withRetry = DataStoreRetry.Scoped(logger, Constants.Storage.RetryPolicy)

-- Obtained in Init, never at require time, so requiring this module has no side effects.
local mainStore: DataStore? = nil

local INDEX_KEY = "MoveIndex"
-- The persisted field name inside the index document. KitEditorSystem's is "Ids"; the two are not
-- interchangeable, which is why AuthoredContentStore takes it explicitly.
local INDEX_FIELD = "MoveIds"

local function recordKey(moveId: string): string
	return "Move_" .. moveId
end

local function overrideKey(moveId: string): string
	return "DefaultOverride_" .. moveId
end

-- Every saved version of one move (custom or Default), newest last -- see the Version history section.
local function historyKey(moveId: string): string
	return "MoveHistory_" .. moveId
end

-- The persisted state of every move that has one: a custom move's stored record, a Default move's stored
-- override (resolved). Absent for a custom move that was only ever previewed, and for a Default move with
-- no stored override -- whose saved state is simply its built self.
local savedMoves: { [string]: MoveDefinition } = {}

-- Classification ---------------------------------------------------------------------------------------

-- A move is Default when the Default registry knows the id and no custom move has taken it over -- the
-- same precedence AttackCatalog resolves with, so the editor edits the move combat would actually throw.
local function sourceOf(moveId: string): MoveSource?
	if MoveRegistryManager.Get(moveId) then
		return "Custom"
	end
	if DefaultMoveRegistry.Get(moveId) then
		return "Default"
	end
	return nil
end

local function liveMove(moveId: string, source: MoveSource): MoveDefinition?
	if source == "Custom" then
		return MoveRegistryManager.Get(moveId)
	end
	return DefaultMoveRegistry.Get(moveId)
end

-- What the move would be after a restart.
local function savedMove(moveId: string, source: MoveSource): MoveDefinition?
	local saved = savedMoves[moveId]
	if saved then
		return saved
	end
	if source == "Default" then
		return DefaultMoveRegistry.GetBuilt(moveId)
	end
	-- A custom move with no DataStore record may still ship in source; that file is its saved state.
	return AuthoredMoveLibrary.GetShippedMove(moveId)
end

-- Entries -----------------------------------------------------------------------------------------------

local function artExists(artId: string): boolean
	local art = MoveRegistryManager.Get(artId)
	return art ~= nil and art.Art ~= nil
end

-- AttackCatalog's resolved timeline for the move, plus what its clip says about the authored numbers:
-- where the strike marker lands, and the authored windup/recovery that would match the clip
-- (MoveBalance.MatchClip). The clip facts ride along because they come from the same resolution -- a
-- second catalogue lookup could straddle an edit.
local function effectiveTiming(move: MoveDefinition): (MoveEditorTypes.EffectiveTiming?, MoveEditorTypes.ClipMatch?)
	local entry = AttackCatalog.Get(move.MoveId)
	if not entry then
		return nil, nil
	end
	local clipLength = AttackWindows.ClipLength(entry.AnimationId)
	-- A borrowed clip carries the LENDER's marker (AttackCatalog step 0), and is retimed to this move, so
	-- it has a strike to draw but nothing to match the move to.
	local marker = AttackWindows.WindupOverride(entry.BorrowedFrom or move.MoveId, entry.AnimationId)
	local effective: MoveEditorTypes.EffectiveTiming = {
		WindupSeconds = entry.Definition.WindupSeconds,
		ActiveSeconds = entry.Definition.ActiveSeconds,
		RecoverySeconds = entry.Definition.RecoverySeconds,
		Cooldown = entry.Cooldown,
		PlaybackSpeed = entry.PlaybackSpeed,
		AnimationId = entry.AnimationId,
		ClipSeconds = if clipLength and entry.PlaybackSpeed > 0 then clipLength / entry.PlaybackSpeed else nil,
		StrikeSeconds = if marker then MoveBalance.StrikeSeconds(move, marker, entry.PlaybackSpeed) else nil,
	}
	local clipMatch = if entry.BorrowedFrom then nil else MoveBalance.MatchClip(move, marker, clipLength)
	return effective, clipMatch
end

-- The plain-language facts an author should know before trusting what they see. PURE -- exported for the
-- spec -- and phrased for the person reading the editor, not for a log.
function MoveEditorSystem.DescribeMove(
	move: MoveDefinition,
	source: MoveSource,
	effective: MoveEditorTypes.EffectiveTiming?,
	isArt: (string) -> boolean
): { string }
	local notes: { string } = {}

	if effective == nil then
		table.insert(notes, "The combat catalogue cannot resolve this move, so nothing can throw it.")
	end

	if source == "Custom" and move.Art == nil then
		table.insert(
			notes,
			"Not an art, so no player can reach it: only an art can sit in a hotbar slot. Test still throws it."
		)
	end

	local projectile = move.Projectile
	if projectile then
		local shots = ProjectileTypes.ShotCount(projectile)
		table.insert(
			notes,
			string.format(
				"Projectile: %d shot%s launch when the active window opens, and fly up to %.0f studs or %.2fs.",
				shots,
				if shots == 1 then "" else "s",
				math.min(projectile.MaxRange, projectile.Speed * projectile.LifetimeSeconds),
				projectile.LifetimeSeconds
			)
		)
		if projectile.SpreadPattern == "Single" and projectile.Count > 1 then
			table.insert(notes, "Single fires one shot: Count only applies to the other spread patterns.")
		end
		if projectile.Homing and projectile.HomingStrength <= 0 then
			table.insert(notes, "Homing is on with zero strength, so no shot ever turns.")
		end
		if projectile.SpawnDirection == "Target" or projectile.Homing then
			if projectile.HomingRange <= 0 or projectile.HomingMaxAngle <= 0 then
				table.insert(notes, "Target range or angle is zero, so no target can ever be picked.")
			end
		end
		if projectile.ParryResponse == "ExistingParry" and projectile.ParryBehavior ~= "CannotParry" then
			table.insert(
				notes,
				"A parried shot staggers its thrower wherever they are, exactly as a parried swing does."
			)
		end
		if projectile.MaxRange > projectile.Speed * projectile.LifetimeSeconds + 1e-3 then
			table.insert(
				notes,
				string.format(
					"Its lifetime runs out first: at %.0f studs/s a %.2fs shot only reaches %.0f of its %.0f-stud range.",
					projectile.Speed,
					projectile.LifetimeSeconds,
					projectile.Speed * projectile.LifetimeSeconds,
					projectile.MaxRange
				)
			)
		end
	end

	-- A projectile flies from its anchor but its volume does not ride it, so only a swing's box is the blade.
	if projectile == nil and move.AttachmentPart == "Weapon" and move.Shape == "Box" then
		table.insert(
			notes,
			"Anchored to the weapon: a Box takes the equipped blade's own size, so Width, Height and Length are ignored."
		)
	elseif move.AttachmentPart ~= "Root" then
		table.insert(
			notes,
			`Anchored to {move.AttachmentPart}: the offset is measured from that part, which moves with the animation.`
		)
	end

	if effective then
		if effective.AnimationId == "" then
			table.insert(notes, "No clip: the swing plays no animation and keeps its authored timing.")
		elseif effective.ClipSeconds == nil then
			table.insert(
				notes,
				"The clip has not been read yet, so the timeline shows authored timing. Test once to sync it."
			)
		elseif effective.WindupSeconds + effective.ActiveSeconds > effective.ClipSeconds + 1e-3 then
			table.insert(
				notes,
				string.format(
					"The hitbox is still open when the clip ends (%.2fs): shorten the windup or active window, or use a longer clip.",
					effective.ClipSeconds
				)
			)
		end
	end

	if move.Grab and move.Knockback then
		table.insert(
			notes,
			"Grab and Knockback are both set: on a clean hit the grab's hold takes over from the knockback."
		)
	end

	if move.Art and move.Art.Prerequisite and not isArt(move.Art.Prerequisite) then
		table.insert(notes, `Prerequisite "{move.Art.Prerequisite}" is not an art, so this art can never be unlocked.`)
	end

	return notes
end

local function groupOf(move: MoveDefinition, source: MoveSource): string
	if source == "Default" then
		return DefaultMoveRegistry.GroupOf(move.MoveId) or DefaultMoveRegistry.StandaloneGroup
	end
	if move.Art then
		return "Arts"
	end
	return if move.Category ~= "" then move.Category else "Custom"
end

-- DescribeMove's notes, then the presentation block's own (Support/PresentationAudit.lua): unresolvable or
-- wrong-kind assets, missing templates, cues on moments this move never reaches.
local function notesFor(
	move: MoveDefinition,
	source: MoveSource,
	effective: MoveEditorTypes.EffectiveTiming?
): { string }
	local notes = MoveEditorSystem.DescribeMove(move, source, effective, artExists)
	for _, note in PresentationAudit.Describe(move, PresentationAudit.AssetStatus, PresentationAudit.TemplateExists) do
		table.insert(notes, note)
	end
	return notes
end

local function buildEntry(move: MoveDefinition, source: MoveSource): MoveEntry
	local effective, clipMatch = effectiveTiming(move)
	local saved = savedMove(move.MoveId, source)
	return {
		Move = move,
		Source = source,
		Group = groupOf(move, source),
		SavedFingerprint = if saved then MoveTypes.Fingerprint(saved) else nil,
		Overridden = source == "Default" and DefaultMoveRegistry.IsOverridden(move.MoveId),
		Stage = if source == "Default" then DefaultMoveRegistry.StageOf(move.MoveId) else nil,
		Shipped = AuthoredMoveLibrary.IsShipped(move.MoveId),
		Effective = effective,
		Balance = if effective then MoveBalance.Compute(effective, move) else nil,
		ClipMatch = clipMatch,
		Notes = notesFor(move, source, effective),
	}
end

local function entryFor(moveId: string): MoveEntry?
	local source = sourceOf(moveId)
	if not source then
		return nil
	end
	local move = liveMove(moveId, source)
	return if move then buildEntry(move, source) else nil
end

-- A clip the boot warm pass never saw (a custom move just given one) starts reading now, so the next
-- entry built for it can show its synced timeline. Request yields, hence the spawn.
local function warmClip(move: MoveDefinition): ()
	if move.AnimationId ~= "" then
		task.spawn(AttackWindows.Request, move.AnimationId)
	end
end

-- Applying a draft ------------------------------------------------------------------------------------

-- Stamps trusted identity onto a client draft -- see this file's header. A draft with no MoveId, or one
-- naming a move that does not exist, is a NEW move.
local function stampCustom(player: Player, raw: { [string]: unknown }): { [string]: unknown }
	local stamped = table.clone(raw)
	local existing = if typeof(raw.MoveId) == "string" then MoveRegistryManager.Get(raw.MoveId :: string) else nil
	if existing then
		stamped.MoveId = existing.MoveId
		stamped.Author = existing.Author
		stamped.CreatedAt = existing.CreatedAt
	else
		local displayName = if typeof(raw.DisplayName) == "string" then raw.DisplayName :: string else "Move"
		stamped.MoveId = MoveRegistryManager.GenerateMoveId(displayName)
		stamped.Author = player.Name
		stamped.CreatedAt = os.time()
	end
	stamped.UpdatedAt = os.time()
	return stamped
end

-- Validates a draft and makes it live, for either source. Returns the live move and its source, or
-- (nil, nil, reason).
local function applyDraft(player: Player, rawDraft: unknown): (MoveDefinition?, MoveSource?, string?)
	if typeof(rawDraft) ~= "table" then
		return nil, nil, "InvalidShape"
	end
	local raw = rawDraft :: { [string]: unknown }
	local moveId = raw.MoveId
	if typeof(moveId) == "string" and sourceOf(moveId) == "Default" then
		local updated, reason = DefaultMoveRegistry.ApplyEdit(moveId, raw)
		if not updated then
			return nil, nil, reason
		end
		return updated, "Default", nil
	end

	local validated, reason = MoveRegistryManager.Validate(stampCustom(player, raw))
	if not validated then
		return nil, nil, reason
	end
	MoveRegistryManager.Upsert(validated)
	warmClip(validated)
	return validated, "Custom", nil
end

-- Persistence --------------------------------------------------------------------------------------------

local function store(): DataStore?
	return mainStore
end

local function writeRecord(key: string, record: { [string]: any }, operation: string): boolean
	local dataStore = store()
	if not dataStore then
		return false
	end
	return withRetry(operation, function()
		(dataStore :: DataStore):SetAsync(key, record)
	end)
end

local function removeRecord(key: string, operation: string): boolean
	local dataStore = store()
	if not dataStore then
		return false
	end
	return withRetry(operation, function()
		(dataStore :: DataStore):RemoveAsync(key)
	end)
end

-- Version history -----------------------------------------------------------------------------------------
--
-- Every successful Save appends the record it wrote to "MoveHistory_<id>", capped at
-- Constants.MoveEditor.HistoryDepth. The record is the SAME bytes the save wrote (MoveRecordCodec's), so a
-- restored version decodes through the path every stored move already loads through, and an old version
-- written before a schema change is upgraded exactly like an old record. A Default move whose save CLEARED
-- its override still gets a version: its record is the built move's own encoding, so restoring it means
-- "back to built", which is what that save meant.
--
-- A failed history write logs and never fails the save: the record write already succeeded, and telling
-- the admin their move is unsaved when it is saved would be the worse lie.

export type StoredVersion = {
	Version: number,
	SavedAt: number,
	AdminName: string,
	AdminUserId: number,
	Record: MoveRecordCodec.Record,
}

export type HistoryDoc = { Versions: { StoredVersion } }

local function isStoredVersion(value: unknown): boolean
	if typeof(value) ~= "table" then
		return false
	end
	local version = value :: { [string]: unknown }
	return typeof(version.Version) == "number" and typeof(version.Record) == "table"
end

-- The valid versions a stored document holds, oldest first. Tolerates anything: a missing document, a
-- corrupt one, a hand-edited entry.
local function versionsOf(doc: unknown): { StoredVersion }
	local versions: { StoredVersion } = {}
	if typeof(doc) == "table" and typeof((doc :: any).Versions) == "table" then
		for _, value in ipairs((doc :: any).Versions) do
			if isStoredVersion(value) then
				table.insert(versions, value :: StoredVersion)
			end
		end
	end
	return versions
end

-- `doc` with `entry` appended as the next version number and the oldest trimmed past `depth`. PURE and
-- non-mutating -- UpdateAsync's transform, exported for the spec.
function MoveEditorSystem.AppendVersion(
	doc: unknown,
	entry: {
		SavedAt: number,
		AdminName: string,
		AdminUserId: number,
		Record: MoveRecordCodec.Record,
	},
	depth: number
): HistoryDoc
	local versions = versionsOf(doc)
	local last = 0
	for _, version in versions do
		last = math.max(last, version.Version)
	end
	table.insert(versions, {
		Version = last + 1,
		SavedAt = entry.SavedAt,
		AdminName = entry.AdminName,
		AdminUserId = entry.AdminUserId,
		Record = entry.Record,
	})
	while #versions > math.max(depth, 1) do
		table.remove(versions, 1)
	end
	return { Versions = versions }
end

-- How many changed fields a summary names before it says "+N more".
local SUMMARY_FIELDS = 4

-- Keys a decoded record carries that are not authored content.
local NOT_AUTHORED: { [string]: boolean } = {
	MoveId = true,
	SchemaVersion = true,
	Author = true,
	CreatedAt = true,
	UpdatedAt = true,
}

local function formatValue(value: unknown): string
	if typeof(value) == "number" then
		local number = value :: number
		if number == math.floor(number) then
			return string.format("%d", number)
		end
		return string.format("%.2f", number)
	elseif value == nil then
		return "none"
	end
	return tostring(value)
end

-- A decoded record flattened to "Field" / "Block.Field" / "Block.Moment.Field" -> value, over the authored
-- keys only. Recursive: Presentation nests a cue per moment, one level deeper than every other block.
local function flattenInto(flat: { [string]: any }, prefix: string, value: any): ()
	if typeof(value) == "table" then
		for inner, innerValue in pairs(value) do
			flattenInto(flat, `{prefix}.{inner}`, innerValue)
		end
	else
		flat[prefix] = value
	end
end

local function flatten(candidate: { [string]: any }): { [string]: any }
	local flat: { [string]: any } = {}
	for key, value in pairs(candidate) do
		if NOT_AUTHORED[key] then
			continue
		end
		flattenInto(flat, key, value)
	end
	return flat
end

-- What `current` changed relative to `previous` (both decoded candidates), as the Tools tab lists it:
-- "WindupSeconds 0.30->0.26, Damage 10->12, +2 more". PURE, exported for the spec.
function MoveEditorSystem.SummarizeChange(previous: { [string]: any }?, current: { [string]: any }): string
	if previous == nil then
		return "The oldest version kept."
	end
	local before, after = flatten(previous), flatten(current)
	local seen: { [string]: boolean } = {}
	for key in pairs(before) do
		seen[key] = true
	end
	for key in pairs(after) do
		seen[key] = true
	end
	local keys: { string } = {}
	for key in pairs(seen) do
		local a, b = before[key], after[key]
		local differs = if typeof(a) == "number" and typeof(b) == "number" then math.abs(a - b) > 1e-6 else a ~= b
		if differs then
			table.insert(keys, key)
		end
	end
	if #keys == 0 then
		return "No authored change (saved again as it was)."
	end
	table.sort(keys)
	local parts: { string } = {}
	for index = 1, math.min(#keys, SUMMARY_FIELDS) do
		local key = keys[index]
		table.insert(parts, `{key} {formatValue(before[key])}->{formatValue(after[key])}`)
	end
	if #keys > SUMMARY_FIELDS then
		table.insert(parts, `+{#keys - SUMMARY_FIELDS} more`)
	end
	return table.concat(parts, ", ")
end

local function appendHistory(player: Player, moveId: string, record: MoveRecordCodec.Record): ()
	local dataStore = store()
	if not dataStore then
		return
	end
	local entry = { SavedAt = os.time(), AdminName = player.Name, AdminUserId = player.UserId, Record = record }
	local ok = withRetry("MoveEditor history append", function()
		(dataStore :: DataStore):UpdateAsync(historyKey(moveId), function(old: unknown)
			return MoveEditorSystem.AppendVersion(old, entry, Config.HistoryDepth)
		end)
	end)
	if not ok then
		logger:error("History: the version could not be recorded -- the move itself IS saved", { moveId = moveId })
	end
end

local function readHistory(moveId: string): (boolean, { StoredVersion })
	local dataStore = store()
	if not dataStore then
		return false, {}
	end
	local ok, raw = withRetry("MoveEditor history read", function()
		return (dataStore :: DataStore):GetAsync(historyKey(moveId))
	end)
	if not ok then
		return false, {}
	end
	return true, versionsOf(raw)
end

-- A stored version's record as a candidate for applyDraft, by the move's current source.
local function decodeVersion(moveId: string, source: MoveSource, record: MoveRecordCodec.Record): { [string]: any }?
	local candidate: MoveRecordCodec.Record?
	if source == "Default" then
		candidate = MoveRecordCodec.DecodeOverride(DefaultMoveRegistry.GetBuilt(moveId) :: MoveDefinition, record)
	else
		candidate = MoveRecordCodec.Decode(record)
	end
	if candidate then
		candidate.MoveId = moveId
	end
	return candidate
end

-- Handlers -----------------------------------------------------------------------------------------------

local function gate(player: Player, actionName: string): (boolean, string?)
	return AdminGate.Check(player, actionName, rateLimiter)
end

local function handleOpen(player: Player): MoveEditorTypes.OpenResult
	local allowed, reason = gate(player, "Open")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local entries: { MoveEntry } = {}
	for _, move in DefaultMoveRegistry.List() do
		-- A Default id a custom move has taken over is that custom move's, listed below instead.
		if MoveRegistryManager.Get(move.MoveId) == nil then
			table.insert(entries, buildEntry(move, "Default"))
		end
	end
	for _, move in MoveRegistryManager.List() do
		table.insert(entries, buildEntry(move, "Custom"))
	end
	return { Success = true, Entries = entries }
end

local function handlePreview(player: Player, rawDraft: unknown): MoveEditorTypes.EntryResult
	local allowed, reason = gate(player, "Preview")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local move, source, applyReason = applyDraft(player, rawDraft)
	if not move or not source then
		return { Success = false, Reason = applyReason }
	end
	return { Success = true, Entry = buildEntry(move, source) }
end

-- Persists a move that applyDraft has already made live: a custom move's record (and its index entry),
-- a Default move's override -- or, for a Default move equal to its built self, the override's REMOVAL.
-- Returns a failure reason, or nil. The one write path Save and bulk Save share, so the two can never
-- disagree about what "saved" means.
local function persist(player: Player, move: MoveDefinition, source: MoveSource): string?
	local moveId = move.MoveId
	if source == "Default" then
		-- An override identical to the built move is no override at all: storing it would pin today's
		-- built values over whatever the weapon is rebuilt to tomorrow. So it is cleared instead.
		local built = DefaultMoveRegistry.GetBuilt(moveId) :: MoveDefinition
		local record = MoveRecordCodec.EncodeOverride(move)
		if MoveTypes.Fingerprint(built) == MoveTypes.Fingerprint(move) then
			DefaultMoveRegistry.Reset(moveId)
			if not removeRecord(overrideKey(moveId), "MoveEditor Save clear override") then
				return "StorageError"
			end
			savedMoves[moveId] = nil
		else
			if not writeRecord(overrideKey(moveId), record, "MoveEditor Save override") then
				return "StorageError"
			end
			savedMoves[moveId] = MoveTypes.Clone(move)
		end
		appendHistory(player, moveId, record)
	else
		local record = MoveRecordCodec.Encode(move)
		if not writeRecord(recordKey(moveId), record, "MoveEditor Save record") then
			return "StorageError"
		end
		appendHistory(player, moveId, record)
		local dataStore = store() :: DataStore
		if not AuthoredContentStore.AddToIndex(withRetry, "MoveEditor", dataStore, INDEX_KEY, INDEX_FIELD, moveId) then
			logger:error("Save: index update failed -- the move is saved but may not load after a restart", {
				moveId = moveId,
			})
		end
		savedMoves[moveId] = MoveTypes.Clone(move)
	end

	logger:info("Move saved", { admin = player.Name, moveId = moveId, source = source })
	return nil
end

local function handleSave(player: Player, rawDraft: unknown): MoveEditorTypes.EntryResult
	local allowed, reason = gate(player, "Save")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local move, source, applyReason = applyDraft(player, rawDraft)
	if not move or not source then
		return { Success = false, Reason = applyReason }
	end
	local failure = persist(player, move, source)
	if failure then
		return { Success = false, Reason = failure }
	end
	return { Success = true, Entry = entryFor(move.MoveId) }
end

local function handleHistory(player: Player, rawMoveId: unknown): MoveEditorTypes.HistoryResult
	local allowed, reason = gate(player, "History")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local moveId = rawMoveId :: string
	local source = sourceOf(moveId)
	if not source then
		return { Success = false, Reason = "MoveNotFound" }
	end
	local ok, stored = readHistory(moveId)
	if not ok then
		return { Success = false, Reason = "StorageError" }
	end

	local versions: { MoveEditorTypes.HistoryVersion } = {}
	local previous: { [string]: any }? = nil
	-- Walked oldest first, so each summary is against the version before it; listed newest first.
	for _, version in stored do
		local candidate = decodeVersion(moveId, source, version.Record)
		table.insert(versions, 1, {
			Version = version.Version,
			SavedAt = version.SavedAt,
			AdminName = version.AdminName,
			Summary = if candidate then MoveEditorSystem.SummarizeChange(previous, candidate) else "Unreadable record.",
		})
		previous = candidate or previous
	end
	return { Success = true, Versions = versions }
end

-- Makes a saved version LIVE -- a Preview, never a Save -- so the admin reviews it before committing.
local function handleRestoreVersion(
	player: Player,
	rawMoveId: unknown,
	rawVersion: unknown
): MoveEditorTypes.EntryResult
	local allowed, reason = gate(player, "RestoreVersion")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	if typeof(rawVersion) ~= "number" then
		return { Success = false, Reason = "InvalidVersion" }
	end
	local moveId = rawMoveId :: string
	local source = sourceOf(moveId)
	if not source then
		return { Success = false, Reason = "MoveNotFound" }
	end
	local ok, stored = readHistory(moveId)
	if not ok then
		return { Success = false, Reason = "StorageError" }
	end
	local found: StoredVersion? = nil
	for _, version in stored do
		if version.Version == rawVersion then
			found = version
		end
	end
	if not found then
		return { Success = false, Reason = "VersionNotFound" }
	end
	local candidate = decodeVersion(moveId, source, found.Record)
	if not candidate then
		return { Success = false, Reason = "InvalidShape" }
	end
	local move, restoredSource, applyReason = applyDraft(player, candidate)
	if not move or not restoredSource then
		return { Success = false, Reason = applyReason }
	end
	logger:info("Version restored (live, not saved)", { admin = player.Name, moveId = moveId, version = rawVersion })
	return { Success = true, Entry = buildEntry(move, restoredSource) }
end

-- Writing moves into the game's source (Studio only) ------------------------------------------------------
--
-- A running server cannot write to the project, and play-mode edits are thrown away on Stop. So in Studio
-- the server generates the move's ModuleScript (Support/MoveSourceWriter) and POSTs it to
-- scripts/move-writer.py on localhost, which writes it under Server/Combat/AuthoredMoves; Rojo syncs it
-- in, and it ships with the build (Server/Combat/AuthoredMoveLibrary loads it at boot). The file is then
-- the move's single source of truth, so its DataStore copy is removed.
--
-- The remotes exist in every build (BootManifest checks every declared name is created) and refuse
-- NotStudio outside Studio. The write needs Game Settings > Security > Allow HTTP Requests.

local function studioGate(player: Player, actionName: string, rawMoveId: unknown): (string?, MoveSource?, string?)
	local allowed, reason = gate(player, actionName)
	if not allowed then
		return nil, nil, reason
	end
	if not RunService:IsStudio() then
		return nil, nil, "NotStudio"
	end
	if typeof(rawMoveId) ~= "string" then
		return nil, nil, "InvalidMoveId"
	end
	local source = sourceOf(rawMoveId :: string)
	if not source then
		return nil, nil, "MoveNotFound"
	end
	return rawMoveId :: string, source, nil
end

local function sourceTextFor(move: MoveDefinition, source: MoveSource): string
	local record = if source == "Custom" then MoveRecordCodec.Encode(move) else MoveRecordCodec.EncodeOverride(move)
	return MoveSourceWriter.ToLua(record)
end

-- POSTs to the helper. Returns (response body, nil) or (nil, reason).
local function postToWriter(route: string, payload: { [string]: any }): ({ [string]: any }?, string?)
	if not HttpService.HttpEnabled then
		return nil, "HttpDisabled"
	end
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = Config.SourceWriter.Url .. route,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(payload),
		})
	end)
	if not ok then
		logger:warn("Source writer unreachable", { route = route, error = tostring(response) })
		return nil, "WriterUnreachable"
	end
	local decodedOk, body = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not response.Success or not decodedOk or typeof(body) ~= "table" or body.ok ~= true then
		logger:warn("Source writer refused", { route = route, status = response.StatusCode, body = response.Body })
		return nil, "WriterRefused"
	end
	return body :: { [string]: any }, nil
end

local function kindOf(source: MoveSource): string
	return if source == "Custom" then "move" else "override"
end

local function handleWriteToSource(player: Player, rawMoveId: unknown): MoveEditorTypes.SourceResult
	local moveId, source, refusal = studioGate(player, "WriteToSource", rawMoveId)
	if not moveId or not source then
		return { Success = false, Reason = refusal }
	end
	local move = liveMove(moveId, source) :: MoveDefinition
	local body, writeRefusal = postToWriter("/write", {
		kind = kindOf(source),
		id = moveId,
		source = sourceTextFor(move, source),
	})
	if not body then
		return { Success = false, Reason = writeRefusal }
	end

	-- The file is the move's truth now: the shipped layer takes the live values, and the DataStore copy
	-- that would otherwise shadow the file goes.
	local storageFailed = false
	if source == "Custom" then
		AuthoredMoveLibrary.MarkShippedMove(moveId, move)
		savedMoves[moveId] = nil
		local dataStore = store()
		if dataStore then
			storageFailed = not removeRecord(recordKey(moveId), "MoveEditor WriteToSource drop record")
			if
				not AuthoredContentStore.RemoveFromIndex(
					withRetry,
					"MoveEditor",
					dataStore,
					INDEX_KEY,
					INDEX_FIELD,
					moveId
				)
			then
				storageFailed = true
			end
		end
	else
		DefaultMoveRegistry.SetShipped(moveId, MoveTypes.ToWire(move))
		DefaultMoveRegistry.Reset(moveId)
		savedMoves[moveId] = nil
		storageFailed = not removeRecord(overrideKey(moveId), "MoveEditor WriteToSource drop override")
	end
	if storageFailed then
		logger:error("WriteToSource: the file is written but its DataStore copy could not be removed", {
			moveId = moveId,
		})
	end
	logger:info("Move written to source", { admin = player.Name, moveId = moveId, path = body.path })
	return {
		Success = true,
		Reason = if storageFailed then "StorageError" else nil,
		Path = if typeof(body.path) == "string" then body.path else nil,
		Entry = entryFor(moveId),
	}
end

-- Deletes the move's file. The move stays LIVE this session -- unsaved -- and after a restart a custom
-- move is gone and a Default move is back to its weapon's values, unless it is saved first.
local function handleRemoveFromSource(player: Player, rawMoveId: unknown): MoveEditorTypes.SourceResult
	local moveId, source, refusal = studioGate(player, "RemoveFromSource", rawMoveId)
	if not moveId or not source then
		return { Success = false, Reason = refusal }
	end
	if not AuthoredMoveLibrary.IsShipped(moveId) then
		return { Success = false, Reason = "NotInSource" }
	end
	local live = liveMove(moveId, source) :: MoveDefinition
	local body, deleteRefusal = postToWriter("/delete", { kind = kindOf(source), id = moveId })
	if not body then
		return { Success = false, Reason = deleteRefusal }
	end
	if source == "Custom" then
		AuthoredMoveLibrary.MarkShippedMove(moveId, nil)
	else
		DefaultMoveRegistry.SetShipped(moveId, nil)
		-- Kept live as an ordinary unsaved override, so nothing changes under the admin mid-session.
		DefaultMoveRegistry.ApplyEdit(moveId, MoveTypes.ToWire(live))
	end
	logger:info("Move removed from source", { admin = player.Name, moveId = moveId, path = body.path })
	return {
		Success = true,
		Path = if typeof(body.path) == "string" then body.path else nil,
		Entry = entryFor(moveId),
	}
end

-- The text Write would produce -- the fallback when the helper cannot run, copied out by hand.
local function handleExportSource(player: Player, rawMoveId: unknown): MoveEditorTypes.SourceResult
	local moveId, source, refusal = studioGate(player, "ExportSource", rawMoveId)
	if not moveId or not source then
		return { Success = false, Reason = refusal }
	end
	local move = liveMove(moveId, source) :: MoveDefinition
	return {
		Success = true,
		Path = `src/ServerScriptService/Server/Combat/AuthoredMoves/{if source == "Custom"
			then "Moves"
			else "Overrides"}/{MoveSourceWriter.FileName(moveId)}`,
		Source = sourceTextFor(move, source),
	}
end

-- Bulk edit -----------------------------------------------------------------------------------------------

-- The fields bulk edit may scale, in the order the UI lists them. Timing and impact only: a shape's size
-- is a per-move decision, and scaling a group of differently-shaped volumes by one number means nothing.
local BULK_FIELDS = { "WindupSeconds", "ActiveSeconds", "RecoverySeconds", "Cooldown", "Damage", "PostureDamage" }

-- `move` as a wire draft with each field `scale` names multiplied -- clamped to BulkScaleLimits, and a
-- non-number or NaN factor ignored. PURE, exported for the spec. The result still goes through
-- applyDraft, so Validate clamps every product to Limits like any other edit.
function MoveEditorSystem.ScaleMove(move: MoveDefinition, scale: MoveEditorTypes.BulkScaleFactors): MoveTypes.MoveWire
	local wire = MoveTypes.ToWire(move)
	local limits = Config.BulkScaleLimits
	for _, field in BULK_FIELDS do
		local factor = (scale :: any)[field]
		if typeof(factor) == "number" and factor == factor then
			wire[field] = (move :: any)[field] * math.clamp(factor, limits.Min, limits.Max)
		end
	end
	return wire
end

-- A request the handler can trust the SHAPE of, or nil.
local function readBulkRequest(raw: unknown): MoveEditorTypes.BulkScaleRequest?
	if typeof(raw) ~= "table" then
		return nil
	end
	local request = raw :: { [string]: unknown }
	if typeof(request.Group) ~= "string" or typeof(request.Save) ~= "boolean" or typeof(request.Scale) ~= "table" then
		return nil
	end
	if request.Stage ~= nil and typeof(request.Stage) ~= "string" then
		return nil
	end
	local scale: MoveEditorTypes.BulkScaleFactors = {}
	local any = false
	for _, field in BULK_FIELDS do
		local factor = (request.Scale :: any)[field]
		if factor ~= nil then
			if typeof(factor) ~= "number" or factor ~= factor then
				return nil
			end
			(scale :: any)[field] = factor
			any = any or factor ~= 1
		end
	end
	if not any then
		return nil
	end
	return {
		Group = request.Group :: string,
		Stage = request.Stage :: string?,
		Scale = scale,
		Save = request.Save :: boolean,
	}
end

type Target = { Move: MoveDefinition, Source: MoveSource }

-- Every live move in `group` -- and, for a Default group, of `stage` when one is given -- by the same
-- classification the browser files them under (groupOf).
local function bulkTargets(group: string, stage: string?): { Target }
	local targets: { Target } = {}
	for _, move in DefaultMoveRegistry.List() do
		if MoveRegistryManager.Get(move.MoveId) ~= nil or groupOf(move, "Default") ~= group then
			continue
		end
		if stage == nil or DefaultMoveRegistry.StageOf(move.MoveId) == stage then
			table.insert(targets, { Move = move, Source = "Default" })
		end
	end
	for _, move in MoveRegistryManager.List() do
		if groupOf(move, "Custom") == group then
			table.insert(targets, { Move = move, Source = "Custom" })
		end
	end
	return targets
end

-- Scales every move in a group, live, and optionally saves each one. A move that fails to apply or to
-- save is skipped and counted, never fatal to the rest: the answer carries every move that DID change,
-- plus the first reason one did not.
local function handleBulkScale(player: Player, rawRequest: unknown): MoveEditorTypes.BulkScaleResult
	local allowed, reason = gate(player, "BulkScale")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	local request = readBulkRequest(rawRequest)
	if not request then
		return { Success = false, Reason = "InvalidRequest" }
	end
	local targets = bulkTargets(request.Group, request.Stage)
	if #targets == 0 then
		return { Success = false, Reason = "NoMovesMatched" }
	end
	if #targets > Config.BulkScaleMaxMoves then
		return { Success = false, Reason = "TooManyMoves" }
	end

	local entries: { MoveEntry } = {}
	local firstFailure: string? = nil
	for _, target in targets do
		local move, source, applyReason = applyDraft(player, MoveEditorSystem.ScaleMove(target.Move, request.Scale))
		if not move or not source then
			firstFailure = firstFailure or applyReason
			continue
		end
		if request.Save then
			local failure = persist(player, move, source)
			if failure then
				firstFailure = firstFailure or failure
			end
		end
		local entry = entryFor(move.MoveId)
		if entry then
			table.insert(entries, entry)
		end
	end

	logger:info("Bulk scale", {
		admin = player.Name,
		group = request.Group,
		stage = request.Stage,
		moves = #entries,
		saved = request.Save,
		failure = firstFailure,
	})
	return { Success = #entries > 0, Reason = firstFailure, Entries = entries }
end

-- Puts the live move back to its persisted state. A custom move that was never saved has no persisted
-- state and stops existing -- the Entry comes back nil, which is the client's cue to drop it.
local function handleRevert(player: Player, rawMoveId: unknown): MoveEditorTypes.EntryResult
	local allowed, reason = gate(player, "Revert")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local moveId = rawMoveId :: string
	local source = sourceOf(moveId)
	if not source then
		return { Success = false, Reason = "MoveNotFound" }
	end

	local saved = savedMove(moveId, source)
	if source == "Default" then
		if savedMoves[moveId] then
			DefaultMoveRegistry.ApplyEdit(moveId, MoveTypes.ToWire(saved))
		else
			DefaultMoveRegistry.Reset(moveId)
		end
	elseif saved then
		MoveRegistryManager.Upsert(saved)
	else
		MoveRegistryManager.Delete(moveId)
	end
	return { Success = true, Entry = entryFor(moveId) }
end

local function handleDelete(player: Player, rawMoveId: unknown): MoveEditorTypes.ActionResult
	local allowed, reason = gate(player, "Delete")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local moveId = rawMoveId :: string
	if sourceOf(moveId) ~= "Custom" then
		return { Success = false, Reason = "NotCustomMove" }
	end
	-- Deleting only the live copy would bring it straight back from its file at the next boot.
	if AuthoredMoveLibrary.IsShipped(moveId) then
		return { Success = false, Reason = "InSource" }
	end

	MoveRegistryManager.Delete(moveId)
	savedMoves[moveId] = nil
	local dataStore = store()
	if dataStore then
		removeRecord(recordKey(moveId), "MoveEditor Delete record")
		removeRecord(historyKey(moveId), "MoveEditor Delete history")
		if
			not AuthoredContentStore.RemoveFromIndex(withRetry, "MoveEditor", dataStore, INDEX_KEY, INDEX_FIELD, moveId)
		then
			logger:error("Delete: index update failed -- the record is gone but its id may linger in the index", {
				moveId = moveId,
			})
		end
	end
	logger:info("Move deleted", { admin = player.Name, moveId = moveId })
	return { Success = true }
end

local function handleResetDefault(player: Player, rawMoveId: unknown): MoveEditorTypes.EntryResult
	local allowed, reason = gate(player, "ResetDefault")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local moveId = rawMoveId :: string
	if sourceOf(moveId) ~= "Default" then
		return { Success = false, Reason = "NotDefaultMove" }
	end

	DefaultMoveRegistry.Reset(moveId)
	savedMoves[moveId] = nil
	-- Best effort, and loud when it fails: the live revert already happened, but a stored override that
	-- survives would quietly come back at the next boot.
	if not removeRecord(overrideKey(moveId), "MoveEditor ResetDefault") then
		logger:error("ResetDefault: the stored override could not be removed and will return after a restart", {
			moveId = moveId,
		})
	end
	logger:info("Default move reset", { admin = player.Name, moveId = moveId })
	return { Success = true, Entry = entryFor(moveId) }
end

local function handleTestFire(player: Player, rawMoveId: unknown): MoveEditorTypes.ActionResult
	local allowed, reason = gate(player, "TestFire")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawMoveId) ~= "string" then
		return { Success = false, Reason = "InvalidMoveId" }
	end
	local character = player.Character
	if not character then
		return { Success = false, Reason = "NoCharacter" }
	end
	local accepted, refusal = AttackRequestSystem.ThrowMove(character, rawMoveId :: string, os.clock())
	if not accepted then
		return { Success = false, Reason = refusal }
	end
	return { Success = true }
end

-- Binding a slot IS equipping an art (ArtSystem owns every slot); DevGrantAndEquip is the one unlock
-- bypass, so an admin can put a form they authored ten seconds ago under a key.
local function handleEquipArtSlot(player: Player, rawSlot: unknown, rawArtId: unknown): MoveEditorTypes.ActionResult
	local allowed, reason = gate(player, "EquipArtSlot")
	if not allowed then
		return { Success = false, Reason = reason }
	end
	if typeof(rawSlot) ~= "number" then
		return { Success = false, Reason = "InvalidSlot" }
	end
	if rawArtId ~= nil and typeof(rawArtId) ~= "string" then
		return { Success = false, Reason = "InvalidArtId" }
	end
	local refusal = ArtSystem.DevGrantAndEquip(player, rawSlot :: number, rawArtId :: string?)
	if refusal then
		return { Success = false, Reason = refusal }
	end
	return { Success = true }
end

-- Freezes the admin while the editor is open, through AdminActionSystem.SetFrozen so its own bookkeeping
-- stays authoritative. The CLOSE is exempt from the rate limit: a throttled close would leave the admin
-- frozen with the panel already gone and nothing on screen to press again.
local function handleSetEditorOpen(player: Player, rawIsOpen: unknown): ()
	if not AdminGate.IsAuthorized(player) or typeof(rawIsOpen) ~= "boolean" then
		return
	end
	if rawIsOpen and rateLimiter:IsLimited(player) then
		return
	end
	AdminActionSystem.SetFrozen(player, rawIsOpen :: boolean)
end

-- Boot load ---------------------------------------------------------------------------------------------

local function logDropped(moveId: string, dropped: { string }): ()
	if #dropped > 0 then
		logger:warn("Stored move carried fields with no runtime; they were dropped on load", {
			moveId = moveId,
			dropped = table.concat(dropped, ", "),
		})
	end
end

-- Every stored custom move into the registry. A record that fails to fetch, decode or validate is skipped
-- and logged, never fatal -- corrupt content degrades one move, not the boot.
local function loadPersistedMoves(dataStore: DataStore): ()
	local indexOk, indexRaw = withRetry("MoveEditor load index", function()
		return dataStore:GetAsync(INDEX_KEY)
	end)
	if not indexOk then
		logger:error("Load: the move index could not be read; starting with no custom moves")
		return
	end
	local moveIds = if typeof(indexRaw) == "table" then (indexRaw :: any)[INDEX_FIELD] else nil
	if typeof(moveIds) ~= "table" then
		logger:info("Load: no move index yet")
		return
	end

	local loaded = 0
	for _, rawMoveId in ipairs(moveIds :: { unknown }) do
		if typeof(rawMoveId) ~= "string" then
			continue
		end
		local moveId = rawMoveId :: string
		local getOk, raw = withRetry("MoveEditor load record", function()
			return dataStore:GetAsync(recordKey(moveId))
		end)
		if not getOk or raw == nil then
			logger:warn("Load: skipped a move whose record could not be fetched", { moveId = moveId })
			continue
		end
		local candidate, dropped = MoveRecordCodec.Decode(raw)
		if not candidate then
			logger:warn("Load: skipped a record that is not a move", { moveId = moveId })
			continue
		end
		local validated, reason = MoveRegistryManager.Validate(candidate)
		if not validated then
			logger:warn("Load: skipped an invalid move", { moveId = moveId, reason = reason })
			continue
		end
		logDropped(moveId, dropped)
		MoveRegistryManager.Upsert(validated)
		savedMoves[moveId] = validated
		loaded += 1
	end
	logger:info("Custom moves loaded", { count = loaded })

	-- The art roster is complete only now (an art is a move), so this is the one moment a prerequisite
	-- audit is meaningful. Never fatal.
	for _, problem in ipairs(ArtTreeManager.AuditPrerequisites()) do
		logger:warn("Art prerequisite problem", { problem = problem })
	end
end

local function loadDefaultMoveOverrides(dataStore: DataStore): ()
	local loaded = 0
	for _, built in DefaultMoveRegistry.List() do
		local moveId = built.MoveId
		local getOk, raw = withRetry("MoveEditor load override", function()
			return dataStore:GetAsync(overrideKey(moveId))
		end)
		if not getOk then
			logger:warn("Load: skipped an override that could not be fetched", { moveId = moveId })
			continue
		end
		if raw == nil then
			continue
		end
		local candidate, dropped =
			MoveRecordCodec.DecodeOverride(DefaultMoveRegistry.GetBuilt(moveId) :: MoveDefinition, raw)
		if not candidate then
			logger:warn("Load: skipped an override that is not a move", { moveId = moveId })
			continue
		end
		local applied, reason = DefaultMoveRegistry.ApplyEdit(moveId, candidate)
		if not applied then
			logger:warn("Load: skipped an invalid override", { moveId = moveId, reason = reason })
			continue
		end
		logDropped(moveId, dropped)
		savedMoves[moveId] = applied
		loaded += 1
	end
	logger:info("Default-move overrides loaded", { count = loaded })
end

-- Init --------------------------------------------------------------------------------------------------

-- Assumes MoveRegistryManager.Init and WeaponRoster.Start have run (Main.server's boot order).
function MoveEditorSystem.Init(): ()
	mainStore = DataStoreService:GetDataStore(StorageConfig.CustomMoveDataStoreName)
	local dataStore = mainStore :: DataStore
	-- Backgrounded so a slow page-through never blocks the synchronous boot chain.
	task.spawn(loadPersistedMoves, dataStore)
	task.spawn(loadDefaultMoveOverrides, dataStore)

	local names = Config.RemoteNames
	NetworkBridge.CreateRemoteFunction(names.Open).OnServerInvoke = wrapHandler("Open", handleOpen)
	NetworkBridge.CreateRemoteFunction(names.Preview).OnServerInvoke = wrapHandler("Preview", handlePreview)
	NetworkBridge.CreateRemoteFunction(names.Save).OnServerInvoke = wrapHandler("Save", handleSave)
	NetworkBridge.CreateRemoteFunction(names.Revert).OnServerInvoke = wrapHandler("Revert", handleRevert)
	NetworkBridge.CreateRemoteFunction(names.Delete).OnServerInvoke = wrapHandler("Delete", handleDelete)
	NetworkBridge.CreateRemoteFunction(names.ResetDefault).OnServerInvoke =
		wrapHandler("ResetDefault", handleResetDefault)
	NetworkBridge.CreateRemoteFunction(names.TestFire).OnServerInvoke = wrapHandler("TestFire", handleTestFire)
	NetworkBridge.CreateRemoteFunction(names.EquipArtSlot).OnServerInvoke =
		wrapHandler("EquipArtSlot", handleEquipArtSlot)
	NetworkBridge.CreateRemoteFunction(names.BulkScale).OnServerInvoke = wrapHandler("BulkScale", handleBulkScale)
	NetworkBridge.CreateRemoteFunction(names.History).OnServerInvoke = wrapHandler("History", handleHistory)
	NetworkBridge.CreateRemoteFunction(names.RestoreVersion).OnServerInvoke =
		wrapHandler("RestoreVersion", handleRestoreVersion)
	NetworkBridge.CreateRemoteFunction(names.WriteToSource).OnServerInvoke =
		wrapHandler("WriteToSource", handleWriteToSource)
	NetworkBridge.CreateRemoteFunction(names.RemoveFromSource).OnServerInvoke =
		wrapHandler("RemoveFromSource", handleRemoveFromSource)
	NetworkBridge.CreateRemoteFunction(names.ExportSource).OnServerInvoke =
		wrapHandler("ExportSource", handleExportSource)

	NetworkBridge.CreateRemoteEvent(names.SetEditorOpen).OnServerEvent
		:Connect(function(player: Player, rawIsOpen: unknown)
			local ok, errorMessage = pcall(handleSetEditorOpen, player, rawIsOpen)
			if not ok then
				logger:error(
					"SetEditorOpen handler errored",
					{ player = player.Name, errorMessage = tostring(errorMessage) }
				)
			end
		end)

	PlayerLifecycle.BindAllPlayers({
		Scope = "MoveEditorSystem",
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
		end,
	})

	logger:info("MoveEditorSystem.Init() complete")
end

-- Spec-only: forgets every saved state, so one case's saves cannot leak into the next.
function MoveEditorSystem.Reset(): ()
	table.clear(savedMoves)
end

return MoveEditorSystem
