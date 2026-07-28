--!strict
--[[
	ModerationSystem.lua

	Owns: player moderation actions gated by DevMenuSystem.lua's existing whitelist -- Kick
	(stateless, immediate), Ban (DataStore-backed, own store separate from BugReport's -- works on
	ANY UserId, including one that isn't currently online, and survives a rejoin/new server since it's
	a durable record, not session state), Mute (in-memory, this-session-only muted-set wired into
	every TextChatService.TextChannels' ShouldDeliverCallback, so a muted player's messages never
	deliver to anyone for the rest of THIS server's lifetime -- deliberately not persisted: a mute is
	a "settle this down right now" tool, not a standing record the way a ban is; an admin who wants a
	mute to survive a rejoin reaches for Ban or Kick instead), and SuspectedCheater (a REVERSIBLE
	manual flag, own DataStore store, own in-memory mirror -- see suspectedCheaterUserIds' own header
	for why IsSuspectedCheater reads memory, never the DataStore, on every check).

	Follows BugReportSystem.lua's DataStore precedent for Ban: lazy store acquisition in Init() (this
	module stays side-effect-free at require() time, safe for the headless test harness's load-check),
	and a retry/backoff wrapper matching BugReportSystem's own withRetry shape. Both now delegate to
	the shared Shared/DataStoreRetry.lua implementation -- PlayerDataSystem.lua became the third
	caller needing the exact same retry/backoff shape this header used to flag as the extraction
	threshold ("once a third caller needs the same shape"), so the algorithm itself now lives in one
	place; this module's own `withRetry` stays as a thin local wrapper supplying its own logger/Config,
	so every existing call site is unchanged.

	Critical ordering requirement: Init() connects Players.PlayerAdded, and per Roblox's own contract
	that event fires listeners in the order they connected -- so Main.server.lua calls this System's
	Init() before every other System's (PlayerDataSystem included), guaranteeing a banned player is
	kicked before any other System starts writing per-player state for them.

	Does not own: authorization (DevMenuSystem.lua's whitelist + checkDevMenuPreconditions gate --
	same trust boundary every other admin action in this codebase already establishes; this module
	never re-checks who's allowed to call it). Does not own chat UI/rendering (TextChatService's own
	default bubble/channel behavior) -- Mute only ever intercepts message DELIVERY via
	ShouldDeliverCallback, never rewrites, inspects, or filters message content itself (contrast
	BugReportSystem.Submit's own TextService:FilterStringAsync call, a genuinely different concern).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local TextChatService = game:GetService("TextChatService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)

local ModerationSystem = {}

local logger = Logger.scope("ModerationSystem")

local Config = Constants.Moderation

export type BanRecord = {
	BannedAt: number,
	BannedByUserId: number,
	Reason: string,
	ExpiresAt: number?,
}

-- Obtained lazily inside Init(), never at module load time -- see this module's own header.
local banStore: DataStore? = nil

-- This-session-only muted set, keyed by UserId (not Player -- a mute should still make sense to
-- check against a TextSource.UserId read off a TextChatMessage, which never carries a live Player
-- reference). Cleared per-player on PlayerRemoving so it can't accumulate for players who left.
local mutedUserIds: { [number]: boolean } = {}

-- Closes the race BanPlayer's own SetAsync yield otherwise leaves open: SetAsync can take up to
-- several retries/backoffs (Config.StorageRetryMaxAttempts) before the ban record actually exists in
-- the DataStore, and a target who joins during that window sails straight through the PlayerAdded
-- IsBanned GetAsync check below (finds nothing yet) -- only getting kicked afterward, and only if
-- handleBanPlayer's own online-kick still finds them connected. This set is written SYNCHRONOUSLY at
-- the top of BanPlayer, before SetAsync ever starts, so PlayerAdded has an immediate, in-memory
-- signal to check with no yield of its own. Parallel in shape to mutedUserIds above (session-only,
-- keyed by UserId), but far shorter-lived -- entries exist only for the few seconds an individual
-- BanPlayer call is actually in flight.
local pendingBanUserIds: { [number]: boolean } = {}

-- Local, non-exported retry/backoff wrapper -- delegates to Shared/DataStoreRetry.lua now that
-- PlayerDataSystem.lua is a third caller needing the same shape (see this module's header, which
-- used to flag this exact duplication as "a real candidate for extraction... once a third caller
-- needs the same shape"). Kept as a local wrapper (not a call-site-by-call-site swap to
-- DataStoreRetry.Attempt directly) so every withRetry(operationName, attempt) call below stays
-- unchanged.
local function withRetry<T>(operationName: string, attempt: () -> T): (boolean, T?, string?)
	return DataStoreRetry.Attempt(logger, operationName, {
		MaxAttempts = Config.StorageRetryMaxAttempts,
		BaseBackoffSeconds = Config.StorageRetryBaseBackoffSeconds,
	}, attempt)
end

local function encodeBanRecord(record: BanRecord): { [string]: any }
	return {
		BannedAt = record.BannedAt,
		BannedByUserId = record.BannedByUserId,
		Reason = record.Reason,
		ExpiresAt = record.ExpiresAt,
	}
end

local function decodeBanRecord(raw: { [string]: any }?): BanRecord?
	if typeof(raw) ~= "table" then
		return nil
	end
	return {
		BannedAt = raw.BannedAt,
		BannedByUserId = raw.BannedByUserId,
		Reason = raw.Reason,
		ExpiresAt = raw.ExpiresAt,
	}
end

-- Pure/testable: a timed ban (ExpiresAt set) whose expiry is already in the past is treated as
-- not-banned. Exported specifically so TestEZ can exercise the expiry math against a plain BanRecord
-- literal, no DataStore involved -- same "pure validators get their own export" precedent as
-- BugReportSystem.ValidateCategory/ValidateDescription. A permanent ban (ExpiresAt == nil) is always
-- active.
function ModerationSystem.IsRecordActive(record: BanRecord, now: number): boolean
	if record.ExpiresAt == nil then
		return true
	end
	return now < record.ExpiresAt
end

-- Reads the ban record for `userId` (DataStore GetAsync + retry). Returns:
--   (true, record, nil)   -- actively banned right now
--   (false, nil, nil)     -- never banned, OR a past timed ban has since expired (see
--                            IsRecordActive above -- this function, not the caller, decides that)
--   (false, nil, reason)  -- storage error; callers treat this as "cannot confirm, let them in"
--                            rather than failing closed (locking every player out during a DataStore
--                            outage is a far worse failure mode than occasionally missing a ban
--                            check).
function ModerationSystem.IsBanned(userId: number): (boolean, BanRecord?, string?)
	if not banStore then
		return false, nil, "StorageError"
	end

	local ok, raw, failReason = withRetry("Moderation IsBanned GetAsync", function()
		return (banStore :: DataStore):GetAsync(tostring(userId))
	end)
	if not ok then
		return false, nil, failReason
	end

	local record = decodeBanRecord(raw :: { [string]: any }?)
	if not record then
		return false, nil, nil
	end

	if not ModerationSystem.IsRecordActive(record, os.time()) then
		return false, nil, nil
	end

	return true, record, nil
end

-- Writes a ban record for targetUserId -- works whether or not that UserId is currently a live
-- Player (see this module's header), which is why this takes a bare number, not a Player, unlike
-- KickPlayer below. `bannedByUserId` isn't part of the 3-argument signature this feature was
-- originally sketched with, but BanRecord.BannedByUserId has to come from SOMEWHERE for the audit
-- trail that field exists for -- DevMenuSystem.handleBanPlayer is the only caller and always has the
-- requesting admin's own UserId on hand, so it's threaded through here explicitly rather than left
-- unpopulated. Flagged here for visibility rather than silently deviating from the sketch.
function ModerationSystem.BanPlayer(
	targetUserId: number,
	bannedByUserId: number,
	reason: string,
	expiresAt: number?
): boolean
	if not banStore then
		return false
	end

	-- Written BEFORE the SetAsync call starts (not after it returns) -- see pendingBanUserIds' own
	-- header for why this has to be synchronous with respect to the yield it's guarding.
	pendingBanUserIds[targetUserId] = true

	local record: BanRecord = {
		BannedAt = os.time(),
		BannedByUserId = bannedByUserId,
		Reason = reason,
		ExpiresAt = expiresAt,
	}

	local ok = withRetry("Moderation BanPlayer SetAsync", function()
		(banStore :: DataStore):SetAsync(tostring(targetUserId), encodeBanRecord(record))
	end)

	-- Cleared either way, not just on success. On success the persisted DataStore record is now the
	-- source of truth for every future IsBanned check, so the pending flag has no more work to do. On
	-- FAILURE (every retry exhausted), this deliberately matches handleBanPlayer's own existing
	-- philosophy (DevMenuSystem.lua): a BanPlayer call that never persisted is NOT treated as banned at
	-- all -- handleBanPlayer skips its online-kick entirely when `ok` comes back false, rather than
	-- kicking someone for a ban that doesn't durably exist. Leaving the pending flag set past this
	-- point would kick that same target on every join for the rest of the server's session over a ban
	-- record that will never actually appear -- worse than the narrow race this flag exists to close.
	pendingBanUserIds[targetUserId] = nil

	return ok
end

-- Mirrors IsMuted's own accessor shape for the same session-only, UserId-keyed set idea -- see
-- pendingBanUserIds' own header above for what this actually guards against.
function ModerationSystem.IsPendingBan(userId: number): boolean
	return pendingBanUserIds[userId] == true
end

-- Stateless -- Kick has no persistence of its own (contrast Ban above); a fresh join is a fresh
-- start. Takes a live Player (unlike Ban/Mute, which target a bare UserId) since kicking someone
-- who isn't currently connected is meaningless.
function ModerationSystem.KickPlayer(targetPlayer: Player, reason: string): boolean
	targetPlayer:Kick(reason)
	return true
end

function ModerationSystem.MutePlayer(targetUserId: number, enabled: boolean): boolean
	mutedUserIds[targetUserId] = if enabled then true else nil
	return true
end

function ModerationSystem.IsMuted(userId: number): boolean
	return mutedUserIds[userId] == true
end

-- Obtained lazily inside Init(), never at module load time -- see this module's own header.
local suspicionStore: DataStore? = nil

-- In-memory mirror of every currently-flagged UserId -- the PRIMARY read path for IsSuspectedCheater,
-- never the DataStore. buildRosterEntry (DevMenuSystem.lua) calls IsSuspectedCheater once per online
-- player on every "Players" tab fetch/refresh; a DataStore GetAsync per row per fetch would multiply
-- roster fetches into N DataStore reads and burn this place's DataStore call budget for a value that
-- changes far less often than it's read. Seeded once at Init() (seedSuspectedCheaterState, a single
-- ListKeysAsync page-through -- no per-key GetAsync needed just to know a key exists) and kept in
-- sync at exactly the two points that can change it: FlagSuspectedCheater/UnflagSuspectedCheater.
-- The DataStore itself stays the durable source of truth (survives a server restart); this table is
-- a fast cache rebuilt from it every boot, the same relationship pendingBanUserIds has to banStore's
-- eventual persisted record, just permanent instead of a few-seconds-long race window.
local suspectedCheaterUserIds: { [number]: boolean } = {}
local suspectedCheaterCount = 0

local function encodeSuspicionRecord(record: Types.SuspicionRecord): { [string]: any }
	return {
		UserId = record.UserId,
		FlaggedAt = record.FlaggedAt,
		FlaggedByUserId = record.FlaggedByUserId,
		Reason = record.Reason,
		Source = record.Source,
		Confidence = record.Confidence,
		ReasonCode = record.ReasonCode,
	}
end

local function decodeSuspicionRecord(raw: { [string]: any }?): Types.SuspicionRecord?
	if typeof(raw) ~= "table" then
		return nil
	end
	return {
		UserId = raw.UserId,
		FlaggedAt = raw.FlaggedAt,
		FlaggedByUserId = raw.FlaggedByUserId,
		Reason = raw.Reason,
		Source = raw.Source,
		Confidence = raw.Confidence,
		ReasonCode = raw.ReasonCode,
	}
end

-- Pure delta for a flag/unflag mutation's effect on suspectedCheaterCount -- exported specifically so
-- TestEZ can exercise the "+1 only if newly flagged, -1 only if previously flagged, no-op otherwise"
-- logic without any DataStore, same "pure logic gets its own export" precedent as
-- BugReportSystem.ComputeOpenCountDelta and this module's own IsRecordActive above.
function ModerationSystem.ComputeSuspicionCountDelta(wasFlagged: boolean, willBeFlagged: boolean): number
	if wasFlagged == willBeFlagged then
		return 0
	end
	return if willBeFlagged then 1 else -1
end

-- Writes/overwrites a suspicion record for targetUserId -- works whether or not that UserId is
-- currently a live Player, same "bare UserId, not a Player" reasoning as BanPlayer above (this pass's
-- only caller, DevMenuSystem.handleSetSuspectedCheater, always targets an explicit roster row, but
-- the underlying record makes sense for an offline UserId too, same as a ban does).
function ModerationSystem.FlagSuspectedCheater(
	targetUserId: number,
	flaggedByUserId: number?,
	reason: string,
	source: Types.SuspicionSource
): boolean
	if not suspicionStore then
		return false
	end

	local record: Types.SuspicionRecord = {
		UserId = targetUserId,
		FlaggedAt = os.time(),
		FlaggedByUserId = flaggedByUserId,
		Reason = reason,
		Source = source,
		Confidence = nil,
		ReasonCode = nil,
	}

	local ok = withRetry("Moderation FlagSuspectedCheater SetAsync", function()
		(suspicionStore :: DataStore):SetAsync(tostring(targetUserId), encodeSuspicionRecord(record))
	end)
	if not ok then
		return false
	end

	local wasFlagged = suspectedCheaterUserIds[targetUserId] == true
	suspectedCheaterUserIds[targetUserId] = true
	suspectedCheaterCount += ModerationSystem.ComputeSuspicionCountDelta(wasFlagged, true)

	return true
end

-- Removes targetUserId's suspicion record entirely (RemoveAsync, not an "inactive" overwrite) -- a
-- later re-flag creates a fresh record via SetAsync above, matching this feature's "overwritten on
-- re-flag" contract with no accumulated history to reconcile.
function ModerationSystem.UnflagSuspectedCheater(targetUserId: number): boolean
	if not suspicionStore then
		return false
	end

	local ok = withRetry("Moderation UnflagSuspectedCheater RemoveAsync", function()
		(suspicionStore :: DataStore):RemoveAsync(tostring(targetUserId))
	end)
	if not ok then
		return false
	end

	local wasFlagged = suspectedCheaterUserIds[targetUserId] == true
	suspectedCheaterUserIds[targetUserId] = nil
	suspectedCheaterCount += ModerationSystem.ComputeSuspicionCountDelta(wasFlagged, false)

	return true
end

function ModerationSystem.IsSuspectedCheater(userId: number): boolean
	return suspectedCheaterUserIds[userId] == true
end

function ModerationSystem.GetSuspectedCheaterCount(): number
	return suspectedCheaterCount
end

-- Full re-enumeration (ListKeysAsync page-through + one GetAsync per key) -- unlike
-- IsSuspectedCheater/GetSuspectedCheaterCount above, this is NOT served from the in-memory mirror,
-- since it needs each record's full Reason/FlaggedAt/Source, not just presence. Not wired to any UI
-- in this pass (no "SuspectedCheaters" list screen exists yet) -- exposed now the same
-- backend-now-UI-later precedent DevMenu/init.lua's own header documents for Custom bot weights, so a
-- future triage screen has a real API to call rather than needing this module touched again first.
function ModerationSystem.ListSuspectedCheaters(): { Types.SuspicionRecord }
	if not suspicionStore then
		return {}
	end

	local ok, pages, failReason = withRetry("Moderation ListSuspectedCheaters ListKeysAsync", function()
		return (suspicionStore :: DataStore):ListKeysAsync()
	end)
	if not ok or not pages then
		logger:error("ListSuspectedCheaters: ListKeysAsync failed", { reason = failReason })
		return {}
	end

	local currentPages = pages :: DataStoreKeyPages
	local records: { Types.SuspicionRecord } = {}
	while true do
		for _, keyInfo in ipairs(currentPages:GetCurrentPage()) do
			local getOk, raw = withRetry("Moderation ListSuspectedCheaters GetAsync", function()
				return (suspicionStore :: DataStore):GetAsync(keyInfo.KeyName)
			end)
			if getOk then
				local record = decodeSuspicionRecord(raw :: { [string]: any }?)
				if record then
					table.insert(records, record)
				else
					logger:warn("ListSuspectedCheaters: skipped undecodable record", { key = keyInfo.KeyName })
				end
			else
				logger:warn("ListSuspectedCheaters: skipped record that failed to fetch", { key = keyInfo.KeyName })
			end
		end

		if currentPages.IsFinished then
			break
		end
		local advanceOk = withRetry("Moderation ListSuspectedCheaters AdvanceToNextPageAsync", function()
			currentPages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			break
		end
	end

	return records
end

-- Seeds suspectedCheaterUserIds/suspectedCheaterCount by paging ListKeysAsync exactly ONCE
-- (Init()-time only) -- see suspectedCheaterUserIds' own header for why this is a key-only walk (no
-- GetAsync needed just to know a UserId is currently flagged). Same partial-progress-on-failure
-- posture as BugReportSystem.seedOpenReportCount: a failed page fetch/advance stops the walk early
-- and logs loudly rather than blocking Init() or retrying the whole seed.
local function seedSuspectedCheaterState(): ()
	if not suspicionStore then
		return
	end

	local ok, pages, failReason = withRetry("Moderation seedSuspectedCheaterState ListKeysAsync", function()
		return (suspicionStore :: DataStore):ListKeysAsync()
	end)
	if not ok or not pages then
		logger:error("seedSuspectedCheaterState: ListKeysAsync failed -- suspicion state stays empty", {
			reason = failReason,
		})
		return
	end

	local currentPages = pages :: DataStoreKeyPages
	local count = 0
	while true do
		for _, keyInfo in ipairs(currentPages:GetCurrentPage()) do
			local userId = tonumber(keyInfo.KeyName)
			if userId then
				suspectedCheaterUserIds[userId] = true
				count += 1
			else
				logger:warn("seedSuspectedCheaterState: skipped non-numeric key", { key = keyInfo.KeyName })
			end
		end

		if currentPages.IsFinished then
			break
		end
		local advanceOk = withRetry("Moderation seedSuspectedCheaterState AdvanceToNextPageAsync", function()
			currentPages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			logger:error("seedSuspectedCheaterState: AdvanceToNextPageAsync failed -- count may be a partial total", {
				partialCount = count,
			})
			break
		end
	end

	suspectedCheaterCount = count
	logger:info("seedSuspectedCheaterState complete", { count = count })
end

-- TextChannel.ShouldDeliverCallback fires once per POTENTIAL RECEIVER for every sent message --
-- this checks the message's own SENDER (textChatMessage.TextSource) against the muted set, ignoring
-- the receiving TextSource entirely, so a mute is a genuine "nobody hears this player" global mute,
-- not a per-viewer ignore list. A message with no TextSource (a system message) always delivers.
local function shouldDeliverMessage(textChatMessage: TextChatMessage, _receivingTextSource: TextSource): boolean
	local senderSource = textChatMessage.TextSource
	if not senderSource then
		return true
	end
	return not ModerationSystem.IsMuted(senderSource.UserId)
end

local function attachChannel(channel: Instance): ()
	if not channel:IsA("TextChannel") then
		return
	end
	(channel :: TextChannel).ShouldDeliverCallback = shouldDeliverMessage
end

function ModerationSystem.Init(): ()
	banStore = DataStoreService:GetDataStore(StorageConfig.BanDataStoreName)
	suspicionStore = DataStoreService:GetDataStore(StorageConfig.SuspectedCheaterDataStoreName)

	-- Backgrounded, not called inline -- this module boots FIRST in Main.server.lua's whole sequence
	-- (see this module's own header), so a synchronous ListKeysAsync page-through here would delay
	-- every other System's Init() behind it, including whichever one first triggers NetworkBridge's
	-- lazy Remotes-folder creation. task.spawn lets Init() return immediately; the accepted trade-off
	-- is IsSuspectedCheater/GetSuspectedCheaterCount can read stale/empty results for the brief window
	-- between Init() returning and this seed actually finishing -- an extension of the same
	-- eventual-consistency contract suspectedCheaterUserIds' own header already describes ("a fast
	-- cache... rebuilt from it every boot"), now just an async rebuild instead of a synchronous one.
	-- Both real read sites (DevMenuSystem's buildRosterEntry/GetSidebarStats) only fire per-request,
	-- off a remote an admin's client calls well after boot, never during or immediately after Init().
	task.spawn(seedSuspectedCheaterState)

	-- CRITICAL: this connection must land before any other System's own Players.PlayerAdded --
	-- Main.server.lua calls ModerationSystem.Init() first in the whole boot sequence to guarantee it
	-- (see this module's own header).
	Players.PlayerAdded:Connect(function(player: Player)
		-- Checked BEFORE the real (async) IsBanned lookup below -- an in-flight BanPlayer call for
		-- this exact UserId has no DataStore record yet for IsBanned's GetAsync to find, but this
		-- synchronous in-memory flag already knows. See pendingBanUserIds' own header for the race
		-- this closes.
		if ModerationSystem.IsPendingBan(player.UserId) then
			logger:warn("Pending-ban player kicked on join (ban write still in flight)", { userId = player.UserId })
			player:Kick("You are banned.")
			return
		end

		local isBanned, record, failReason = ModerationSystem.IsBanned(player.UserId)
		if failReason then
			logger:error("IsBanned check failed on join -- allowing join", {
				userId = player.UserId,
				reason = failReason,
			})
			return
		end
		if isBanned then
			local reasonText = if record then record.Reason else "Banned"
			logger:warn("Banned player kicked on join", { userId = player.UserId, reason = reasonText })
			player:Kick(`You are banned: {reasonText}`)
		end
	end)

	-- Attach to every TextChannel that already exists, then hook ChildAdded for any created after
	-- this point (channels can be created after Init -- see this System's own task brief). TextChannels
	-- itself is a fixed, always-present child of TextChatService; a missing one here would mean this
	-- place's chat pipeline is configured in a way this pass couldn't verify (see the NOTE below).
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	if textChannels then
		for _, channel in ipairs(textChannels:GetChildren()) do
			attachChannel(channel)
		end
		textChannels.ChildAdded:Connect(attachChannel)
	else
		logger:warn("TextChatService.TextChannels not found at Init -- Mute enforcement inactive")
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		mutedUserIds[player.UserId] = nil
	end)

	logger:info("ModerationSystem.Init() complete")

	-- NOTE (flagged for the Chief Architect, not a TODO left in gameplay logic): Mute's actual
	-- effectiveness depends on this place's TextChatService.ChatVersion being set to
	-- Enum.ChatVersion.TextChatService -- if it's still LegacyChatService, messages never flow through
	-- TextChannels/ShouldDeliverCallback at all and this wiring silently does nothing. This couldn't be
	-- verified from source (no Studio/live-server session available in this pass) -- confirm
	-- game.TextChatService.ChatVersion in Studio before relying on Mute in production.
end

-- Not cast to Types.SystemModule -- same reasoning as BugReportSystem.lua's own return: DevMenuSystem
-- calls IsBanned/BanPlayer/KickPlayer/MutePlayer directly, so this module's full type (not just Init)
-- needs to stay visible to that caller.
return ModerationSystem
