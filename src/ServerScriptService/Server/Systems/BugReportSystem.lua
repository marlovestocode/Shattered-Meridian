--!strict
--[[
	BugReportSystem.lua

	Owns: the bug-report DataStore (both the main record store and the chronological ordered-index
	store used for admin pagination) and the PUBLIC BugReport_Submit remote -- any player may call
	it, no whitelist check, gated only by its own rate limiter + per-player cooldown. This was the
	FIRST DataStoreService usage anywhere in this codebase, predating PlayerDataSystem.lua (the
	long-term canonical owner of PLAYER PROGRESSION persistence specifically -- tier/bloodline/art/
	faction/etc.) -- bug reports are a distinct, unrelated record type with no reason to route
	through that module's PlayerProfile-shaped API, so this module keeps its own small,
	tightly-scoped storage layer rather than being folded into it. The two modules now share their
	retry/backoff implementation (Shared/DataStoreRetry.lua) but remain otherwise independent.
	Also owns the in-memory openReportCount counter the DevMenu Sidebar's stats header reads
	(GetOpenCount) -- seeded once at Init() and kept accurate incrementally at Submit/UpdateStatus,
	see openReportCount's own header for why it's never recomputed by re-paging on every read.

	Does not own: admin authorization for viewing/triaging reports -- DevMenuSystem.lua owns that
	(its existing whitelist + checkDevMenuPreconditions gate), and calls into this module's public
	ListReports/UpdateStatus the same way it already calls into CombatSystem/TrainingBotSystem for
	other admin actions. This module trusts its caller for those two functions the way
	CombatSystem.SpawnTrainingDummy trusts DevMenuSystem already.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)

local BugReportSystem = {}

local logger = Logger.scope("BugReportSystem")

local Config = Constants.BugReport

-- Own bucket, separate from every other System's -- a flood of BugReport_Submit calls shouldn't
-- compete with (or be starved by) a player's combat/dev-menu remote budget, and vice versa.
local submitRateLimiter = RateLimiter.New(Config.SubmitMaxCallsPerSecond)

-- os.clock()-keyed per-player cooldown, separate from the per-second rate limiter above -- that
-- one catches raw call-spam; this one enforces the actual "one report per N seconds" product rule.
local lastSubmitAt: { [Player]: number } = {}

-- Live pagination cursor per admin session -- a DataStorePages object can't cross a Remote
-- boundary, so the server holds it here and advances it on request instead. Cleared on
-- PlayerRemoving below.
local adminPagingSessions: { [Player]: DataStorePages? } = {}

-- Obtained lazily inside Init(), never at module load time, so require()-ing this module stays
-- side-effect-free (no DataStore I/O merely from requiring it) -- this is what keeps it safe for
-- the headless test harness's load-check to require().
local mainStore: DataStore? = nil
local orderedStore: OrderedDataStore? = nil

-- In-memory count of every report currently Status == "Open" -- the DevMenu Sidebar's "Bug Reports"
-- stat (DevMenu_GetSidebarStats). Seeded ONCE in Init() from the persisted OPEN_COUNT_KEY counter
-- (a single GetAsync -- see seedOpenReportCount below, and OPEN_COUNT_KEY/persistOpenCountDelta's own
-- headers for why this replaced an earlier version that paged the full OrderedDataStore, and
-- GetAsync'd every report ever submitted, on every server boot), then kept accurate incrementally in
-- memory AND on the persisted key at exactly the two points that can change it: Submit (a new report
-- always starts Open, unconditional +1) and UpdateStatus (adjust by ComputeOpenCountDelta's
-- transition delta). Never recomputed by re-paging on every read -- GetOpenCount is called from the
-- Sidebar's eager fetch-at-mount path, which would otherwise pay a full DataStore page-through per
-- Sidebar mount for a number this counter already tracks for free.
local openReportCount = 0

function BugReportSystem.GetOpenCount(): number
	return openReportCount
end

-- Pure delta for a Status transition's effect on openReportCount -- exported specifically so TestEZ
-- can exercise the increment/decrement logic without any DataStore, same "pure logic gets its own
-- export" precedent as ValidateCategory/ValidateDescription/IsValidStatus below. Every status pair
-- outside "one side is Open, the other isn't" nets to 0 (including a same-status no-op).
function BugReportSystem.ComputeOpenCountDelta(
	oldStatus: Types.BugReportStatus,
	newStatus: Types.BugReportStatus
): number
	if oldStatus == newStatus then
		return 0
	end
	if oldStatus == "Open" then
		return -1
	end
	if newStatus == "Open" then
		return 1
	end
	return 0
end

-- The retry/backoff wrapper every DataStore call below goes through, bound once to this module's own
-- logger and to the ONE policy (Constants.Storage.RetryPolicy). Five Systems each held this same
-- three-line local, differing only in which Constants table they read the same two numbers out of;
-- see Shared/DataStoreRetry.Scoped's own header. Call sites are unchanged -- still
-- withRetry(operationName, attempt).
local withRetry = DataStoreRetry.Scoped(logger, Constants.Storage.RetryPolicy)

-- Dedicated key on mainStore holding the persisted openReportCount -- see seedOpenReportCount's own
-- header for why this replaced a full OrderedDataStore page-walk on every server boot. Lives on
-- mainStore (report metadata), not orderedStore (the chronological index) -- namespaced with a
-- leading "__" so it can never collide with a report's own key (HttpService:GenerateGUID(false)
-- never produces that shape).
local OPEN_COUNT_KEY = "__OpenReportCount"

-- Pure UpdateAsync merge function for OPEN_COUNT_KEY, exported specifically so TestEZ can exercise
-- it without any DataStore -- same "extract the pure logic" precedent ComputeOpenCountDelta above
-- already establishes in this file. `old` is exactly what UpdateAsync hands its callback: nil for a
-- never-written key, or whatever was last stored -- coerced to 0 if it isn't a number (a corrupt or
-- pre-migration value should never propagate rather than degrade). Clamped to never go negative.
function BugReportSystem.ComputeOpenCountAfterDelta(old: unknown, delta: number): number
	local current = if typeof(old) == "number" then old else 0
	return math.max(0, current + delta)
end

-- Atomic (UpdateAsync, not a separate GetAsync-then-SetAsync) so two servers' Submit/UpdateStatus
-- calls landing at nearly the same moment can never clobber each other's delta -- same reasoning
-- MoveEditorSystem.lua's addToIndex/removeFromIndex already established for their own index key.
-- Best-effort: a failure here is logged but never fails the caller's own Submit/UpdateStatus (same
-- "the report is still durably saved even if this side-write fails" posture Submit's own
-- ordered-index write already has) -- the in-memory openReportCount the caller already updated stays
-- correct for THIS server for the rest of its life either way; only a future boot's seed would read a
-- stale persisted value.
local function persistOpenCountDelta(delta: number): ()
	if not mainStore or delta == 0 then
		return
	end
	local ok = withRetry("BugReport persistOpenCountDelta UpdateAsync", function()
		(mainStore :: DataStore):UpdateAsync(OPEN_COUNT_KEY, function(old: unknown)
			return BugReportSystem.ComputeOpenCountAfterDelta(old, delta)
		end)
	end)
	if not ok then
		logger:error("persistOpenCountDelta: UpdateAsync failed -- persisted counter may drift stale", {
			delta = delta,
		})
	end
end

-- DataStore/JSON has no native Vector3 -- encode/decode are the one place the persisted shape and
-- the live Types.BugReportRecord shape genuinely diverge (every other field is already a
-- DataStore-safe primitive).
local function encodeRecord(record: Types.BugReportRecord): { [string]: any }
	local encoded: { [string]: any } = {
		Id = record.Id,
		ReporterUserId = record.ReporterUserId,
		ReporterName = record.ReporterName,
		Category = record.Category,
		Description = record.Description,
		CreatedAt = record.CreatedAt,
		PlaceId = record.PlaceId,
		JobId = record.JobId,
		Status = record.Status,
		StatusUpdatedAt = record.StatusUpdatedAt,
		StatusUpdatedByUserId = record.StatusUpdatedByUserId,
		Priority = record.Priority,
		AssignedAdminUserId = record.AssignedAdminUserId,
		AssignedAdminName = record.AssignedAdminName,
		Notes = record.Notes,
	}
	if record.Position then
		encoded.Position = { X = record.Position.X, Y = record.Position.Y, Z = record.Position.Z }
	end
	return encoded
end

local function decodeRecord(id: string, raw: { [string]: any }?): Types.BugReportRecord?
	if typeof(raw) ~= "table" then
		return nil
	end

	local position: Vector3? = nil
	if typeof(raw.Position) == "table" then
		position = Vector3.new(raw.Position.X, raw.Position.Y, raw.Position.Z)
	end

	local notes: { Types.BugReportNote } = {}
	if typeof(raw.Notes) == "table" then
		notes = raw.Notes :: { Types.BugReportNote }
	end

	return {
		Id = id,
		ReporterUserId = raw.ReporterUserId,
		ReporterName = raw.ReporterName,
		Category = raw.Category,
		Description = raw.Description,
		CreatedAt = raw.CreatedAt,
		PlaceId = raw.PlaceId,
		JobId = raw.JobId,
		Position = position,
		Status = raw.Status,
		StatusUpdatedAt = raw.StatusUpdatedAt,
		StatusUpdatedByUserId = raw.StatusUpdatedByUserId,
		-- Defaults cover records written before these fields existed -- see Types.BugReportRecord's
		-- own header. A pre-existing report just reads as unassigned/Normal-priority/no-notes the
		-- first time this decodes it, not a decode failure.
		Priority = (raw.Priority :: Types.BugReportPriority?) or Config.DefaultPriority,
		AssignedAdminUserId = raw.AssignedAdminUserId,
		AssignedAdminName = raw.AssignedAdminName,
		Notes = notes,
	}
end

-- Pure validators, exported specifically so TestEZ can exercise them without any DataStore.

local CATEGORY_SET: { [string]: Types.BugReportCategory } = {}
for _, category in ipairs(Config.Categories) do
	CATEGORY_SET[category] = category
end

function BugReportSystem.ValidateCategory(raw: unknown): Types.BugReportCategory?
	if typeof(raw) ~= "string" then
		return nil
	end
	return CATEGORY_SET[raw]
end

-- Generous slack above DescriptionMaxLength so a few stray leading/trailing whitespace characters
-- never turn a legitimate submission into a rejection, while still bounding the two gsub passes
-- below to a small fixed multiple of the intended cap rather than whatever length a client sends --
-- see this function's own TooLong check, which used to run AFTER (and therefore not bound) them.
local RAW_DESCRIPTION_LENGTH_SLACK = 256

function BugReportSystem.ValidateDescription(raw: unknown): (string?, string?)
	if typeof(raw) ~= "string" then
		return nil, "InvalidType"
	end
	if #raw > Config.DescriptionMaxLength + RAW_DESCRIPTION_LENGTH_SLACK then
		return nil, "TooLong"
	end
	local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
	if #trimmed < Config.DescriptionMinLength then
		return nil, "TooShort"
	end
	if #trimmed > Config.DescriptionMaxLength then
		return nil, "TooLong"
	end
	return trimmed, nil
end

-- Every status accepts every other status as a target -- a free graph, not a restricted state
-- machine like CombatSystem's ACTION_GATES -- an admin can freely re-open a Resolved/Dismissed
-- report. Deliberate, documented choice, not an oversight. Derived from Config.Statuses the same
-- way CATEGORY_SET above derives from Config.Categories, so adding "InProgress" was a one-line
-- Constants.lua change, not a second hand-written literal here.
local STATUS_SET: { [string]: Types.BugReportStatus } = {}
for _, status in ipairs(Config.Statuses) do
	STATUS_SET[status] = status
end

function BugReportSystem.IsValidStatus(raw: unknown): boolean
	return typeof(raw) == "string" and STATUS_SET[raw] ~= nil
end

local PRIORITY_SET: { [string]: Types.BugReportPriority } = {}
for _, priority in ipairs(Config.Priorities) do
	PRIORITY_SET[priority] = priority
end

function BugReportSystem.IsValidPriority(raw: unknown): boolean
	return typeof(raw) == "string" and PRIORITY_SET[raw] ~= nil
end

-- Shared TextService filter wrapper -- Submit's own description filtering below and AddNote's note
-- filtering need the exact same "run it through PublicChat filtering, treat a pcall failure as
-- FilterFailed" shape.
local function filterText(player: Player, text: string): (string?, string?)
	local filterOk, filteredOrError = pcall(function(): string
		local filterResult = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not filterOk then
		return nil, "FilterFailed"
	end
	return filteredOrError :: string, nil
end

-- BugReport_Submit handler. Order: rate limit -> cooldown -> category/description validation ->
-- server-derived context -> content filtering -> persist. The cooldown timestamp is set BEFORE the
-- storage write below (not after confirmed success) -- deliberate: this is what stops a client from
-- retry-spamming the DataStore write path during a transient outage. The trade-off is a player who
-- hits a genuine one-off storage failure has to wait out the same cooldown before trying again.
function BugReportSystem.Submit(
	player: Player,
	rawCategory: unknown,
	rawDescription: unknown
): Types.BugReportSubmitResult
	logger:debug("Submit received", { player = player.Name, userId = player.UserId })

	if submitRateLimiter:IsLimited(player) then
		logger:debug("Submit rejected: rate limited", { player = player.Name })
		return { Success = false, Reason = "RateLimited" }
	end

	local now = os.clock()
	local lastAt = lastSubmitAt[player]
	if lastAt and now - lastAt < Config.SubmitCooldownSeconds then
		logger:debug("Submit rejected: cooldown active", { player = player.Name })
		return { Success = false, Reason = "CooldownActive" }
	end

	local category = BugReportSystem.ValidateCategory(rawCategory)
	if not category then
		return { Success = false, Reason = "InvalidCategory" }
	end

	local description, descriptionFailureReason = BugReportSystem.ValidateDescription(rawDescription)
	if not description then
		return { Success = false, Reason = descriptionFailureReason or "InvalidDescription" }
	end

	-- Set the cooldown now, before the storage write -- see this function's own header.
	lastSubmitAt[player] = now

	local position: Vector3? = nil
	local character = player.Character
	if character then
		local rootPart = CharacterUtil.RootOf(character)
		if rootPart then
			position = rootPart.Position
		end
	end

	local filtered, filterFailReason = filterText(player, description)
	if not filtered then
		logger:warn("Submit rejected: filtering failed", { player = player.Name, reason = filterFailReason })
		return { Success = false, Reason = filterFailReason or "FilterFailed" }
	end

	local id = HttpService:GenerateGUID(false)
	local record: Types.BugReportRecord = {
		Id = id,
		ReporterUserId = player.UserId,
		ReporterName = player.Name,
		Category = category,
		Description = filtered,
		CreatedAt = os.time(),
		PlaceId = game.PlaceId,
		JobId = game.JobId,
		Position = position,
		Status = "Open",
		Priority = Config.DefaultPriority,
		Notes = {},
	}

	local mainOk = false
	if mainStore then
		mainOk = (
			withRetry("BugReport main SetAsync", function()
				(mainStore :: DataStore):SetAsync(id, encodeRecord(record))
			end)
		)
	end
	if not mainOk then
		return { Success = false, Reason = "StorageError" }
	end

	-- A brand-new report always starts "Open" -- unconditional +1, no transition delta needed (there
	-- is no "old status" for a record that didn't exist a moment ago).
	openReportCount += 1
	persistOpenCountDelta(1)

	-- If the ordered-index write fails, the report is still durably saved -- it just may not
	-- surface promptly in the admin's chronological list. Logged loudly, not silently swallowed,
	-- but does not fail the whole submission (an accepted, explicitly-flagged limitation).
	if orderedStore then
		local orderedOk = withRetry("BugReport ordered-index SetAsync", function()
			(orderedStore :: OrderedDataStore):SetAsync(id, record.CreatedAt)
		end)
		if not orderedOk then
			logger:error("Submit: ordered-index write failed, report saved but may not list promptly", { id = id })
		end
	end

	logger:info("Submit accepted", { player = player.Name, id = id, category = category })
	return { Success = true, ReportId = id }
end

-- Called only by DevMenuSystem, after its own checkDevMenuPreconditions gate has already passed --
-- this function does not re-check admin authorization itself.
function BugReportSystem.ListReports(
	admin: Player,
	cursorMode: Types.BugReportListCursorMode
): ({ Types.BugReportRecord }?, boolean?, string?)
	if not orderedStore then
		return nil, nil, "StorageError"
	end

	local pages = adminPagingSessions[admin]
	if cursorMode == "First" or not pages then
		local ok, newPages, failReason = withRetry("BugReport ListReports GetSortedAsync", function()
			return (orderedStore :: OrderedDataStore):GetSortedAsync(false, Config.ListPageSize)
		end)
		if not ok or not newPages then
			return nil, nil, failReason or "StorageError"
		end
		pages = newPages
		adminPagingSessions[admin] = pages
	elseif cursorMode == "Next" then
		if (pages :: DataStorePages).IsFinished then
			return {}, false, nil
		end
		local ok, _, failReason = withRetry("BugReport ListReports AdvanceToNextPageAsync", function()
			(pages :: DataStorePages):AdvanceToNextPageAsync()
		end)
		if not ok then
			return nil, nil, failReason or "StorageError"
		end
	end

	local currentPages = pages :: DataStorePages
	local records: { Types.BugReportRecord } = {}
	for _, entry in ipairs(currentPages:GetCurrentPage()) do
		local key = entry.key
		local ok, raw = withRetry("BugReport ListReports GetAsync", function()
			return (mainStore :: DataStore):GetAsync(key)
		end)
		if ok then
			local record = decodeRecord(key, raw :: { [string]: any }?)
			if record then
				table.insert(records, record)
			else
				logger:warn("ListReports: skipped undecodable record", { id = key })
			end
		else
			logger:warn("ListReports: skipped record that failed to fetch", { id = key })
		end
	end

	return records, not currentPages.IsFinished, nil
end

-- Called only by DevMenuSystem, after its own checkDevMenuPreconditions gate AND its own
-- IsValidStatus check have already passed -- this function trusts newStatus is one of the three
-- known values.
function BugReportSystem.UpdateStatus(
	admin: Player,
	reportId: string,
	newStatus: Types.BugReportStatus
): (Types.BugReportRecord?, string?)
	if not mainStore then
		return nil, "StorageError"
	end

	local getOk, raw, getFailReason = withRetry("BugReport UpdateStatus GetAsync", function()
		return (mainStore :: DataStore):GetAsync(reportId)
	end)
	if not getOk then
		return nil, getFailReason or "StorageError"
	end

	local record = decodeRecord(reportId, raw :: { [string]: any }?)
	if not record then
		return nil, "NotFound"
	end

	local oldStatus = record.Status
	record.Status = newStatus
	record.StatusUpdatedAt = os.time()
	record.StatusUpdatedByUserId = admin.UserId

	local setOk, _, setFailReason = withRetry("BugReport UpdateStatus SetAsync", function()
		(mainStore :: DataStore):SetAsync(reportId, encodeRecord(record))
	end)
	if not setOk then
		return nil, setFailReason or "StorageError"
	end

	local delta = BugReportSystem.ComputeOpenCountDelta(oldStatus, newStatus)
	openReportCount = math.max(0, openReportCount + delta)
	persistOpenCountDelta(delta)

	logger:info("UpdateStatus accepted", { admin = admin.Name, id = reportId, status = newStatus })
	return record, nil
end

-- Read-only single-record fetch, for callers (DevMenuSystem.handleJumpToReporter) that need one
-- report's data without going through the get-modify-SetAsync shape UpdateStatus/AddNote/
-- SetPriority/AssignReport below all share. Same "called only after the caller's own
-- checkDevMenuPreconditions gate has already passed" trust boundary as ListReports/UpdateStatus.
function BugReportSystem.GetRecord(reportId: string): (Types.BugReportRecord?, string?)
	if not mainStore then
		return nil, "StorageError"
	end
	local getOk, raw, failReason = withRetry("BugReport GetRecord GetAsync", function()
		return (mainStore :: DataStore):GetAsync(reportId)
	end)
	if not getOk then
		return nil, failReason or "StorageError"
	end
	local record = decodeRecord(reportId, raw :: { [string]: any }?)
	if not record then
		return nil, "NotFound"
	end
	return record, nil
end

-- Appends one internal triage note (never shown to the reporter -- see Types.BugReportNote's own
-- header). Same get-validate-mutate-SetAsync shape as UpdateStatus above; unlike UpdateStatus this
-- never touches openReportCount (a note never changes Status).
function BugReportSystem.AddNote(admin: Player, reportId: string, rawText: unknown): (Types.BugReportRecord?, string?)
	if typeof(rawText) ~= "string" then
		return nil, "InvalidRequest"
	end
	local trimmed = rawText:gsub("^%s+", ""):gsub("%s+$", "")
	if #trimmed == 0 then
		return nil, "TooShort"
	end
	if #trimmed > Config.NoteMaxLength then
		return nil, "TooLong"
	end

	if not mainStore then
		return nil, "StorageError"
	end
	local getOk, raw, getFailReason = withRetry("BugReport AddNote GetAsync", function()
		return (mainStore :: DataStore):GetAsync(reportId)
	end)
	if not getOk then
		return nil, getFailReason or "StorageError"
	end
	local record = decodeRecord(reportId, raw :: { [string]: any }?)
	if not record then
		return nil, "NotFound"
	end

	local filtered, filterFailReason = filterText(admin, trimmed)
	if not filtered then
		return nil, filterFailReason or "FilterFailed"
	end

	table.insert(record.Notes, {
		Id = HttpService:GenerateGUID(false),
		AuthorUserId = admin.UserId,
		AuthorName = admin.Name,
		Text = filtered,
		CreatedAt = os.time(),
	})

	local setOk, _, setFailReason = withRetry("BugReport AddNote SetAsync", function()
		(mainStore :: DataStore):SetAsync(reportId, encodeRecord(record))
	end)
	if not setOk then
		return nil, setFailReason or "StorageError"
	end

	logger:info("AddNote accepted", { admin = admin.Name, id = reportId })
	return record, nil
end

-- Called only by DevMenuSystem, after its own checkDevMenuPreconditions gate AND its own
-- IsValidPriority check have already passed -- same trust boundary as UpdateStatus.
function BugReportSystem.SetPriority(
	admin: Player,
	reportId: string,
	newPriority: Types.BugReportPriority
): (Types.BugReportRecord?, string?)
	if not mainStore then
		return nil, "StorageError"
	end
	local getOk, raw, getFailReason = withRetry("BugReport SetPriority GetAsync", function()
		return (mainStore :: DataStore):GetAsync(reportId)
	end)
	if not getOk then
		return nil, getFailReason or "StorageError"
	end
	local record = decodeRecord(reportId, raw :: { [string]: any }?)
	if not record then
		return nil, "NotFound"
	end

	record.Priority = newPriority

	local setOk, _, setFailReason = withRetry("BugReport SetPriority SetAsync", function()
		(mainStore :: DataStore):SetAsync(reportId, encodeRecord(record))
	end)
	if not setOk then
		return nil, setFailReason or "StorageError"
	end

	logger:info("SetPriority accepted", { admin = admin.Name, id = reportId, priority = newPriority })
	return record, nil
end

-- Claim/release toggle. `assign = true` claims (only allowed when currently unassigned OR already
-- claimed by this same admin, so a second admin can't silently steal an in-progress claim out from
-- under the first); `assign = false` releases (only allowed when THIS admin holds the claim -- an
-- admin can't release someone else's). Both rejections return "AlreadyAssigned"/"NotYourAssignment"
-- rather than silently no-opping, so the client can surface a clear reason.
function BugReportSystem.AssignReport(
	admin: Player,
	reportId: string,
	assign: boolean
): (Types.BugReportRecord?, string?)
	if not mainStore then
		return nil, "StorageError"
	end
	local getOk, raw, getFailReason = withRetry("BugReport AssignReport GetAsync", function()
		return (mainStore :: DataStore):GetAsync(reportId)
	end)
	if not getOk then
		return nil, getFailReason or "StorageError"
	end
	local record = decodeRecord(reportId, raw :: { [string]: any }?)
	if not record then
		return nil, "NotFound"
	end

	if assign then
		if record.AssignedAdminUserId ~= nil and record.AssignedAdminUserId ~= admin.UserId then
			return nil, "AlreadyAssigned"
		end
		record.AssignedAdminUserId = admin.UserId
		record.AssignedAdminName = admin.Name
	else
		if record.AssignedAdminUserId ~= admin.UserId then
			return nil, "NotYourAssignment"
		end
		record.AssignedAdminUserId = nil
		record.AssignedAdminName = nil
	end

	local setOk, _, setFailReason = withRetry("BugReport AssignReport SetAsync", function()
		(mainStore :: DataStore):SetAsync(reportId, encodeRecord(record))
	end)
	if not setOk then
		return nil, setFailReason or "StorageError"
	end

	logger:info("AssignReport accepted", { admin = admin.Name, id = reportId, assign = assign })
	return record, nil
end

-- One-time migration fallback ONLY -- pages the full OrderedDataStore and decodes every record
-- across every page, counting Status == "Open". This is the ORIGINAL seedOpenReportCount body
-- (every server boot used to pay this in full -- one GetAsync per report ever submitted, since
-- reports are never deleted and UpdateStatus never RemoveAsyncs a resolved one). Now called at most
-- ONCE per DataStore, ever, by seedOpenReportCount below, the first time it finds no persisted
-- OPEN_COUNT_KEY -- see that function's own header. A failure partway through (a failed
-- GetSortedAsync, or a failed AdvanceToNextPageAsync) stops the walk early and returns whatever
-- partial count was accumulated so far, logged loudly rather than silently -- an under-count here is
-- a stale sidebar stat, not a gameplay-affecting failure.
local function migrateOpenReportCountFromFullWalk(): number
	if not orderedStore then
		return 0
	end

	local ok, pages, failReason = withRetry("BugReport migrateOpenReportCount GetSortedAsync", function()
		return (orderedStore :: OrderedDataStore):GetSortedAsync(false, Config.ListPageSize)
	end)
	if not ok or not pages then
		logger:error("migrateOpenReportCountFromFullWalk: initial GetSortedAsync failed -- count stays 0", {
			reason = failReason,
		})
		return 0
	end

	local currentPages = pages :: DataStorePages
	local count = 0
	while true do
		for _, entry in ipairs(currentPages:GetCurrentPage()) do
			local getOk, raw = withRetry("BugReport migrateOpenReportCount GetAsync", function()
				return (mainStore :: DataStore):GetAsync(entry.key)
			end)
			if getOk then
				local record = decodeRecord(entry.key, raw :: { [string]: any }?)
				if record and record.Status == "Open" then
					count += 1
				end
			else
				logger:warn("migrateOpenReportCountFromFullWalk: skipped record that failed to fetch", {
					id = entry.key,
				})
			end
		end

		if currentPages.IsFinished then
			break
		end
		local advanceOk = withRetry("BugReport migrateOpenReportCount AdvanceToNextPageAsync", function()
			currentPages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			logger:error("migrateOpenReportCountFromFullWalk: AdvanceToNextPageAsync failed -- partial total", {
				partialCount = count,
			})
			break
		end
	end

	return count
end

-- Pure UpdateAsync merge function for the one-time migration write -- same "extract the pure logic"
-- reason ComputeOpenCountAfterDelta above has. Prefers an already-persisted number over
-- `migratedCount` (another server may have already migrated, or a real Submit/UpdateStatus delta may
-- have already landed, while this walk was still running) so two servers racing the same first-boot
-- migration converge on one value instead of the second one stomping the first's.
function BugReportSystem.ResolveMigratedOpenCount(old: unknown, migratedCount: number): number
	if typeof(old) == "number" then
		return old
	end
	return migratedCount
end

-- Seeds openReportCount from the persisted OPEN_COUNT_KEY counter -- ONE GetAsync, not one per
-- report ever submitted (see this file's header/2026-08 performance audit: the old version paged the
-- full OrderedDataStore and GetAsync'd every report on EVERY server boot, which at scale saturated a
-- booting server's DataStore budget badly enough to get joining players' own profile loads kicked
-- for an unrelated timeout). If no persisted counter exists yet (a fresh DataStore, or the first boot
-- since this counter replaced the old full-walk seed), falls back to
-- migrateOpenReportCountFromFullWalk exactly once and persists the result via UpdateAsync so no
-- future boot -- on this server or any other -- ever pays for that walk again. The UpdateAsync
-- callback prefers an already-persisted value over this walk's own result if one appeared while the
-- walk was running (another server racing the same first-boot migration), keeping the migration
-- idempotent.
local function seedOpenReportCount(): ()
	if not mainStore then
		return
	end

	local getOk, raw, failReason = withRetry("BugReport seedOpenReportCount GetAsync", function()
		return (mainStore :: DataStore):GetAsync(OPEN_COUNT_KEY)
	end)
	if not getOk then
		logger:error("seedOpenReportCount: GetAsync failed -- openReportCount stays 0", { reason = failReason })
		return
	end

	if typeof(raw) == "number" then
		openReportCount = math.max(0, raw)
		logger:info("seedOpenReportCount complete", { openReportCount = openReportCount })
		return
	end

	logger:info("seedOpenReportCount: no persisted counter yet -- running one-time migration walk")
	local migratedCount = migrateOpenReportCountFromFullWalk()
	local persistOk, finalValue = withRetry("BugReport seedOpenReportCount migration UpdateAsync", function()
		return (mainStore :: DataStore):UpdateAsync(OPEN_COUNT_KEY, function(old: unknown)
			return BugReportSystem.ResolveMigratedOpenCount(old, migratedCount)
		end)
	end)
	if not persistOk then
		logger:error("seedOpenReportCount: migration walk succeeded but failed to persist", {
			migratedCount = migratedCount,
		})
		openReportCount = migratedCount
		return
	end

	openReportCount = if typeof(finalValue) == "number" then finalValue else migratedCount
	logger:info("seedOpenReportCount: migration complete", { openReportCount = openReportCount })
end

function BugReportSystem.Init(): ()
	mainStore = DataStoreService:GetDataStore(StorageConfig.BugReportDataStoreName)
	orderedStore = DataStoreService:GetOrderedDataStore(StorageConfig.BugReportOrderedDataStoreName)

	-- Backgrounded, not called inline -- Main.server.lua's boot sequence is a straight-line chain of
	-- System.Init() calls with no task.spawn of its own, so any DataStore round trip here blocks
	-- every System.Init() after this one (AdminActionSystem, DevMenuSystem) for however long it
	-- takes. The common case is now one cheap GetAsync (see seedOpenReportCount/OPEN_COUNT_KEY's own
	-- headers -- this used to be a full OrderedDataStore page-through, GetAsync-ing every report ever
	-- submitted, on EVERY boot; task.spawn mattered a lot more before that fix), but the rare
	-- one-time migration path can still be a real page-through, so this stays backgrounded rather
	-- than assuming the fast path always applies. The accepted trade-off is GetOpenCount can read a
	-- stale/zero count for the brief window between Init() returning and this seed actually
	-- finishing -- openReportCount's own header already documents it as "seeded once... then kept
	-- accurate incrementally," this just makes that initial seed asynchronous rather than blocking.
	-- The only real read site (DevMenuSystem's GetSidebarStats) fires per-request, off a remote an
	-- admin's client calls well after boot, never during or immediately after Init().
	task.spawn(seedOpenReportCount)

	local submitRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.Submit)
	logger:debug("Remote created", { name = Config.RemoteNames.Submit })
	submitRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		"Submit",
		{ Success = false, Reason = "InternalError" } :: Types.BugReportSubmitResult,
		BugReportSystem.Submit
	)
	logger:debug("Handler connected", { remote = Config.RemoteNames.Submit })

	PlayerLifecycle.BindAllPlayers({
		Scope = "BugReportSystem",
		OnPlayerRemoving = function(player: Player)
			lastSubmitAt[player] = nil
			submitRateLimiter:Clear(player)
			adminPagingSessions[player] = nil
		end,
	})

	logger:info("BugReportSystem.Init() complete")
end

-- Deliberately NOT cast to Types.SystemModule (unlike DevMenuSystem.lua's own return) -- DevMenuSystem
-- calls ListReports/UpdateStatus on this module directly, so its full type (not just Init) needs to
-- stay visible to that caller, the same reason CombatSystem.lua returns itself uncast.
return BugReportSystem
