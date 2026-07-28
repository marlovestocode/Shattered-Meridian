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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)

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
-- stat (DevMenu_GetSidebarStats). Seeded ONCE in Init() by paging the full OrderedDataStore a single
-- time (see seedOpenReportCount below), then kept accurate incrementally at exactly the two points
-- that can change it: Submit (a new report always starts Open, unconditional +1) and UpdateStatus
-- (adjust by ComputeOpenCountDelta's transition delta). Never recomputed by re-paging on every read
-- -- GetOpenCount is called from the Sidebar's eager fetch-at-mount path, which would otherwise pay a
-- full DataStore page-through per Sidebar mount for a number this counter already tracks for free.
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

-- Local, non-exported retry/backoff wrapper -- delegates to Shared/DataStoreRetry.lua, which this
-- module's own header used to flag as "a candidate for extraction... later, not before."
-- PlayerDataSystem.lua is now that later/third caller (alongside ModerationSystem.lua's own
-- withRetry), so the actual retry loop lives in one shared place; this local wrapper just supplies
-- this module's own logger/Config, keeping every call site below (withRetry(operationName,
-- attempt)) unchanged.
local function withRetry<T>(operationName: string, attempt: () -> T): (boolean, T?, string?)
	return DataStoreRetry.Attempt(logger, operationName, {
		MaxAttempts = Config.StorageRetryMaxAttempts,
		BaseBackoffSeconds = Config.StorageRetryBaseBackoffSeconds,
	}, attempt)
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

function BugReportSystem.ValidateDescription(raw: unknown): (string?, string?)
	if typeof(raw) ~= "string" then
		return nil, "InvalidType"
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
-- report. Deliberate, documented choice, not an oversight.
local STATUS_SET: { [string]: Types.BugReportStatus } =
	{ Open = "Open", Resolved = "Resolved", Dismissed = "Dismissed" }

function BugReportSystem.IsValidStatus(raw: unknown): boolean
	return typeof(raw) == "string" and STATUS_SET[raw] ~= nil
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
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			position = rootPart.Position
		end
	end

	local filterOk, filteredOrError = pcall(function(): string
		local filterResult =
			TextService:FilterStringAsync(description, player.UserId, Enum.TextFilterContext.PublicChat)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not filterOk then
		logger:warn(
			"Submit rejected: filtering failed",
			{ player = player.Name, errorMessage = tostring(filteredOrError) }
		)
		return { Success = false, Reason = "FilterFailed" }
	end

	local id = HttpService:GenerateGUID(false)
	local record: Types.BugReportRecord = {
		Id = id,
		ReporterUserId = player.UserId,
		ReporterName = player.Name,
		Category = category,
		Description = filteredOrError :: string,
		CreatedAt = os.time(),
		PlaceId = game.PlaceId,
		JobId = game.JobId,
		Position = position,
		Status = "Open",
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

	openReportCount = math.max(0, openReportCount + BugReportSystem.ComputeOpenCountDelta(oldStatus, newStatus))

	logger:info("UpdateStatus accepted", { admin = admin.Name, id = reportId, status = newStatus })
	return record, nil
end

-- Seeds openReportCount by paging the full OrderedDataStore exactly ONCE (Init()-time only, never
-- re-run on a later read) -- decodes every record across every page and counts Status == "Open".
-- A failure partway through (a failed GetSortedAsync, or a failed AdvanceToNextPageAsync) stops the
-- page walk early and leaves openReportCount at whatever partial count was accumulated so far, logged
-- loudly rather than silently -- an under-count here is a stale sidebar stat, not a gameplay-affecting
-- failure, so this deliberately doesn't retry the whole seed or block Init() on eventual consistency.
local function seedOpenReportCount(): ()
	if not orderedStore then
		return
	end

	local ok, pages, failReason = withRetry("BugReport seedOpenReportCount GetSortedAsync", function()
		return (orderedStore :: OrderedDataStore):GetSortedAsync(false, Config.ListPageSize)
	end)
	if not ok or not pages then
		logger:error("seedOpenReportCount: initial GetSortedAsync failed -- openReportCount stays 0", {
			reason = failReason,
		})
		return
	end

	local currentPages = pages :: DataStorePages
	local count = 0
	while true do
		for _, entry in ipairs(currentPages:GetCurrentPage()) do
			local getOk, raw = withRetry("BugReport seedOpenReportCount GetAsync", function()
				return (mainStore :: DataStore):GetAsync(entry.key)
			end)
			if getOk then
				local record = decodeRecord(entry.key, raw :: { [string]: any }?)
				if record and record.Status == "Open" then
					count += 1
				end
			else
				logger:warn("seedOpenReportCount: skipped record that failed to fetch", { id = entry.key })
			end
		end

		if currentPages.IsFinished then
			break
		end
		local advanceOk = withRetry("BugReport seedOpenReportCount AdvanceToNextPageAsync", function()
			currentPages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			logger:error("seedOpenReportCount: AdvanceToNextPageAsync failed -- count may be a partial total", {
				partialCount = count,
			})
			break
		end
	end

	openReportCount = count
	logger:info("seedOpenReportCount complete", { openReportCount = count })
end

function BugReportSystem.Init(): ()
	mainStore = DataStoreService:GetDataStore(Config.DataStoreName)
	orderedStore = DataStoreService:GetOrderedDataStore(Config.OrderedDataStoreName)

	-- Backgrounded, not called inline -- Main.server.lua's boot sequence is a straight-line chain of
	-- System.Init() calls with no task.spawn of its own, so a synchronous full-OrderedDataStore
	-- page-through here (seedOpenReportCount pages+decodes every report) blocks every System.Init()
	-- after this one (AdminActionSystem, DevMenuSystem) for however long that page-through takes.
	-- task.spawn lets Init() return immediately; the accepted trade-off is GetOpenCount can read a
	-- stale/zero count for the brief window between Init() returning and this seed actually
	-- finishing -- openReportCount's own header already documents it as "seeded once... then kept
	-- accurate incrementally," this just makes that initial seed asynchronous rather than blocking.
	-- The only real read site (DevMenuSystem's GetSidebarStats) fires per-request, off a remote an
	-- admin's client calls well after boot, never during or immediately after Init().
	task.spawn(seedOpenReportCount)

	local submitRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.Submit)
	logger:debug("Remote created", { name = Config.RemoteNames.Submit })
	submitRemote.OnServerInvoke = function(player: Player, rawCategory: unknown, rawDescription: unknown)
		local ok, resultOrError = pcall(BugReportSystem.Submit, player, rawCategory, rawDescription)
		if not ok then
			logger:error("Submit handler errored", { player = player.Name, errorMessage = tostring(resultOrError) })
			return { Success = false, Reason = "InternalError" }
		end
		return resultOrError
	end
	logger:debug("Handler connected", { remote = Config.RemoteNames.Submit })

	Players.PlayerRemoving:Connect(function(player: Player)
		lastSubmitAt[player] = nil
		submitRateLimiter:Clear(player)
		adminPagingSessions[player] = nil
	end)

	logger:info("BugReportSystem.Init() complete")
end

-- Deliberately NOT cast to Types.SystemModule (unlike DevMenuSystem.lua's own return) -- DevMenuSystem
-- calls ListReports/UpdateStatus on this module directly, so its full type (not just Init) needs to
-- stay visible to that caller, the same reason CombatSystem.lua returns itself uncast.
return BugReportSystem
