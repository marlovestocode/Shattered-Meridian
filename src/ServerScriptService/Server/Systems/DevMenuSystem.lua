--!strict
--[[
	DevMenuSystem.lua

	Owns: server-side authorization and request handling for whitelist-gated developer tooling
	(Constants.Debug.DevMenu for tunables; Server/Config/AdminConfig.lua for the whitelist itself).
	Every request re-checks the whitelist itself (via checkDevMenuPreconditions ->
	Server/Network/AdminGate.Check), regardless of what the client believes. That list deliberately
	lives in a server-only module rather than in Constants.lua, which replicates -- see
	AdminConfig.lua's own header. DevMenuClient.lua therefore no longer holds a local copy to gate
	itself with; it asks this System instead, over the GetSidebarStats RemoteFunction it already
	calls at startup, and a rejection from any handler here is the authorization answer. Unlike
	Logger.lua, this System is NOT Studio-gated -- Constants.Debug.DevMenu's own header is explicit
	that dev tooling is meant to work in live servers too; safety comes entirely from the whitelist
	plus this System's own re-check on every request, never from RunService:IsStudio() or from being
	hidden.

	Does not own: what a dev action actually does -- AdminActionSystem owns the
	Godmode/Flying/FlightCollide/Frozen/Invisible/SpeedMultiplier/Teleport override actions,
	ModerationSystem owns Kick/Ban/Mute, and
	EmoteUnlockService owns granting/rolling emote unlocks (handleRollEmote below is a whitelist-gated
	test trigger for RollEmote's existing "RareEmotes" pool, not a new unlock mechanism -- see that
	handler's own header). VersionWatchSystem owns detecting whether a newer place version has been
	published (handleGetServerVersionInfo below only forwards what it already knows); this System
	still owns the actual kick-everyone actions themselves (handleShutdownServer's countdown-warned
	kick, handleInstantRestartServer's immediate one) since only an admin's own button press ever
	triggers either -- this System only decides *whether* a given request is allowed to reach
	those, then translates the request/response shape. Uses RemoteFunctions, not RemoteEvents, since
	the client needs to know immediately whether its request was accepted -- Announcement is the one
	deliberate exception (a genuine broadcast to every client, not just the requesting admin), so it's
	a RemoteEvent instead.

	No longer owns (combat system removed): SetTargetHealth/ResetTargetCombatState (direct health
	mutation and combat-state reset -- these stay gone). resolveActionTarget's lock-on lookup was also
	CombatSystem's -- every admin action now simply targets whichever player the "Players" tab row
	names, or the calling admin themselves.

	SPAWNDUMMY IS BACK, pointed at the rebuilt stack. handleSpawnDebugDummy/handleDespawnAllDebugDummies/
	handleSetDummyGuard/handleGetDebugDummyState below delegate to Server/Systems/DebugDummySystem.lua,
	a from-scratch module (not a CombatSystem revival -- see that module's own header) that spawns a
	real HitboxEngine/DefenseSystem-registered combatant. SpawnTrainingBot stays orphaned -- an
	AI-controlled sparring partner is a materially bigger feature nothing has rebuilt yet.

	GetHitboxDebug/SetHitboxDebug are BACK, pointed at the rebuilt engine. They used to toggle the
	deleted HitboxResolver.lua's visualisation through a small HitboxDebugState.lua holder; the state
	now lives on HitboxEngine itself (SetDebugVolumesEnabled/IsDebugVolumesEnabled), since that module
	both owns the Parts and is the only thing that can clear them. What has not changed is why these
	are whitelist-gated like every other action here: the volumes are real server-side Parts, so
	flipping them on is visible to every player in the server, not just the admin who asked.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)

local AdminActionSystem = require(script.Parent.AdminActionSystem)
local DebugDummySystem = require(script.Parent.DebugDummySystem)
local ResourceGatheringSystem = require(script.Parent.ResourceGatheringSystem)
local VersionWatchSystem = require(script.Parent.VersionWatchSystem)
local FlightTuning = require(script.Parent.Parent.DevMenu.FlightTuning)
local BugReportSystem = require(script.Parent.BugReportSystem)
local ModerationSystem = require(script.Parent.ModerationSystem)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)
local EmoteUnlockService = require(script.Parent.EmoteUnlockService)
local BloodlineSystem = require(script.Parent.BloodlineSystem)
local HitboxEngine = require(script.Parent.Parent.Combat.HitboxEngine.HitboxEngine)

local DevMenuSystem = {}

local logger = Logger.scope("DevMenuSystem")

local DevMenuConfig = Constants.Debug.DevMenu

-- Own bucket, shared by EVERY handler in this
-- file, including SetSuspectedCheater/GetSidebarStats: an earlier pass gave those two their own
-- dedicated instances with no documented technical reason (both are low-frequency, one-shot,
-- admin-only requests -- GetSidebarStats fires once per DevMenuClient.Start(), SetSuspectedCheater
-- fires on a UI button click -- the same call profile every other handler below already shares this
-- bucket for), so a Chief Architect review consolidated them back here per this file's own
-- checkDevMenuPreconditions header ("unifying what every one of the handlers below used to
-- hand-duplicate"); a future handler with a genuinely different call-frequency profile (e.g. a
-- per-Heartbeat polling remote) would be the kind of case that legitimately earns its own bucket.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

-- Shared auth + rate-limit precondition, unifying what every one of the handlers below used to
-- hand-duplicate -- Server/Network/AdminGate.lua's own Check now owns the auth-check + rate-limit +
-- rejection-logging shape itself (this file's own comment above is the origin that module's header
-- cites); this wrapper stays local only to pin every call site here to the shared `rateLimiter`
-- bucket above without repeating it at each of the 37 call sites. `actionName` feeds both the
-- "X rejected: ..." log message and the caller's own "X received" debug line, so callers only need
-- to name their action once. Returns (true, nil) when the request may proceed, or (false, Reason)
-- with the Reason string every handler's own Result shape already uses.
local function checkDevMenuPreconditions(player: Player, actionName: string): (boolean, string?)
	return AdminGate.Check(player, actionName, rateLimiter)
end

-- Shared "does this player have a live character with a HumanoidRootPart" lookup, used by every
-- teleport-flavored action below (TeleportToTarget/BringTarget/JumpToReporter). A missing root part
-- is treated the same way a missing character is ("NoCharacter") since none of these actions have
-- anything meaningful to do with a rootPart-less character.
-- Thin logging wrapper around Shared/CharacterUtil.lua's RootOf -- kept local rather than folded into
-- that shared module because the debug-log reason ("no character" vs "no root part") and the
-- `logPrefix`-per-caller shape are specific to this System's own handlers, not something every other
-- CharacterUtil caller would want.
local function getRootPart(player: Player, logPrefix: string): (BasePart?, string?)
	local character = player.Character
	if not character then
		logger:debug(logPrefix .. " rejected: no character", { player = player.Name })
		return nil, "NoCharacter"
	end

	local rootPartInstance = CharacterUtil.RootOf(character)
	if not rootPartInstance then
		logger:debug(logPrefix .. " rejected: no root part", { player = player.Name })
		return nil, "NoCharacter"
	end
	return rootPartInstance, nil
end

-- Closed-whitelist string-to-enum lookup, unifying the several call sites below that used to each
-- hand-write `if typeof(rawX) == "string" then MAP[rawX] else nil`. Rejects both a non-string and a
-- string outside the given map's known keys in one step -- see FLIGHT_TUNING_FIELDS' own comment
-- below for why the closed-whitelist behavior (not just a typeof check) matters here.
local function resolveEnum<T>(raw: unknown, map: { [string]: T }): T?
	if typeof(raw) ~= "string" then
		return nil
	end
	return map[raw]
end

-- Whitelist-gated one-shot test trigger for the Emote System's roll path (Server/Systems/
-- EmoteUnlockService.lua's RollEmote) -- exercises GrantEmote/RollEmote end to end from a human
-- tester's own button press, since there is still no AchievementSystem/quest/live-ops caller to
-- trigger it for real (see EmoteUnlockService.RollEmote's own header). Deliberately hardcodes the
-- "RareEmotes" pool and rolls for the CALLING admin themselves (never a resolved lock-on target --
-- unlike the Admin tab's actions, this has no meaningful "target," the same "self, no player-select"
-- shape SpawnDummy/SpawnTrainingBot already use). RollEmote's own signature stays fully generic --
-- this is just a new caller, not a new unlock mechanism.
local function handleRollEmote(player: Player): Types.DevMenuRollEmoteResult
	logger:debug("RollEmote received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "RollEmote")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local granted, emoteId, rollReason = EmoteUnlockService.RollEmote(player, "RareEmotes", {
		Type = "Roll",
		Pool = "RareEmotes",
	})
	if not granted then
		logger:debug("RollEmote rejected", { player = player.Name, reason = rollReason })
		return { Success = false, Reason = rollReason or "RollFailed" }
	end

	logger:info("RollEmote accepted", { player = player.Name, emoteId = emoteId })
	return { Success = true, EmoteId = emoteId }
end

-- Shared "who is this admin action for" resolution when no explicit target row was named -- always
-- the calling admin themselves. Used to resolve lock-on to a combat target
-- (CombatSystem.GetLockOnTarget) before the combat system was removed; every caller now simply falls
-- back to `player`, exactly as if nothing were ever locked on.
local function resolveActionTarget(player: Player): Player
	return player
end

-- Closed whitelist for handleSetTargetSpeedMultiplier below -- rejects any number outside the exact
-- preset set BEFORE it ever reaches AdminActionSystem.SetSpeedMultiplier (which re-validates the
-- same set itself; see that function's own header for why both layers check). Same
-- table-from-array idiom FLIGHT_TUNING_FIELDS below uses, just declared up here since this file's
-- earlier handlers need it too.
local SPEED_MULTIPLIER_PRESETS: { [number]: boolean } = {}
for _, preset in ipairs(Constants.Debug.DevMenu.SpeedMultiplierPresets) do
	SPEED_MULTIPLIER_PRESETS[preset] = true
end

-- Resolves an EXPLICIT target Player by UserId, for the "Players" tab's per-row buttons that need to
-- act on a specific roster row rather than falling back to the calling admin. `rawTargetUserId` is
-- nil for every existing Admin-tab caller (none of which pass one) -- in that case this returns
-- (nil, nil) so the caller falls back to resolveActionTarget's own self-resolution, exactly
-- preserving those callers' existing behavior. A non-nil id that doesn't currently resolve to a live
-- Player (already left, or a bogus number) returns (nil, "NoTarget") instead of silently falling
-- back -- a row button naming a specific player should never silently retarget onto someone else.
local function resolveOptionalExplicitTarget(rawTargetUserId: unknown): (Player?, string?)
	if rawTargetUserId == nil then
		return nil, nil
	end
	if typeof(rawTargetUserId) ~= "number" then
		return nil, "InvalidRequest"
	end
	local target = Players:GetPlayerByUserId(rawTargetUserId)
	if not target then
		return nil, "NoTarget"
	end
	return target, nil
end

-- Same UserId->live-Player resolution as resolveOptionalExplicitTarget above, for the moderation
-- actions (Kick/Mute) that always target an explicit roster row and never fall back to lock-on --
-- kicking or muting "whoever I'm locked onto" is exactly the kind of ambiguity those actions can't
-- afford, so unlike Teleport-To/Reset-Combat-State above, there is no nil-id fallback path here at
-- all: a missing/invalid UserId is always a rejected request.
local function resolveTargetUserId(rawTargetUserId: unknown): (Player?, string?)
	if typeof(rawTargetUserId) ~= "number" then
		return nil, "InvalidRequest"
	end
	local target = Players:GetPlayerByUserId(rawTargetUserId)
	if not target then
		return nil, "NoTarget"
	end
	return target, nil
end

-- BanPlayer/MutePlayer target OFFLINE UserIds by design (ModerationSystem.BanPlayer/MutePlayer take
-- a raw UserId, never a Player) -- resolveTargetUserId above can't be reused for them since it
-- requires Players:GetPlayerByUserId to succeed. This is the same rigor applied to the ID itself:
-- a real Roblox UserId is always a positive integer, well under 2^53 (Lua's exact-integer float
-- ceiling). Rejects NaN implicitly -- NaN > 0 is false, same self-inequality property every other
-- NaN guard in this codebase relies on.
local function isPlausibleUserId(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	return value > 0 and value < 2 ^ 53 and value == math.floor(value)
end

-- Grants bloodline rerolls to the resolved target -- the same lock-on-or-self picker every other
-- admin action on this screen uses, so an admin can top up a player they are watching without a
-- player-select UI. The amount is fixed by BloodlineConstants rather than sent by the client: a
-- client-supplied number would be one more untrusted field to validate for no benefit, since there
-- is no case where an admin wants a specific odd number of rerolls rather than "some more".
local function handleGrantBloodlineRerolls(player: Player): Types.DevMenuGrantRerollsResult
	logger:debug("GrantBloodlineRerolls received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "GrantBloodlineRerolls")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local target = resolveActionTarget(player)
	local total, refusal = BloodlineSystem.GrantRerolls(target, BloodlineConstants.DevGrantRerollAmount)
	if not total then
		return { Success = false, Reason = refusal }
	end

	logger:info("GrantBloodlineRerolls accepted", { player = player.Name, target = target.Name, total = total })
	return { Success = true, RerollsRemaining = total }
end

local function handleSetTargetGodmode(player: Player, rawEnabled: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetGodmode received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetGodmode")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = AdminActionSystem.SetGodmode(target, rawEnabled)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetGodmode accepted", { player = player.Name, target = target.Name, enabled = rawEnabled })
	return { Success = true }
end

local function handleSetTargetFlight(player: Player, rawEnabled: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetFlight received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetFlight")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = AdminActionSystem.SetFlying(target, rawEnabled)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetFlight accepted", { player = player.Name, target = target.Name, enabled = rawEnabled })
	return { Success = true }
end

local function handleSetTargetFlightCollide(player: Player, rawEnabled: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetFlightCollide received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetFlightCollide")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = AdminActionSystem.SetFlightCollide(target, rawEnabled)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetFlightCollide accepted", { player = player.Name, target = target.Name, enabled = rawEnabled })
	return { Success = true }
end

local function handleSetTargetFrozen(player: Player, rawEnabled: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetFrozen received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetFrozen")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = AdminActionSystem.SetFrozen(target, rawEnabled)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetFrozen accepted", { player = player.Name, target = target.Name, enabled = rawEnabled })
	return { Success = true }
end

local function handleSetTargetInvisible(player: Player, rawEnabled: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetInvisible received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetInvisible")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = AdminActionSystem.SetInvisible(target, rawEnabled)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetInvisible accepted", { player = player.Name, target = target.Name, enabled = rawEnabled })
	return { Success = true }
end

local function handleSetTargetSpeedMultiplier(player: Player, rawMultiplier: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetSpeedMultiplier received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetSpeedMultiplier")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawMultiplier) ~= "number" or not SPEED_MULTIPLIER_PRESETS[rawMultiplier] then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = AdminActionSystem.SetSpeedMultiplier(target, rawMultiplier)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info(
		"SetTargetSpeedMultiplier accepted",
		{ player = player.Name, target = target.Name, multiplier = rawMultiplier }
	)
	return { Success = true }
end

local function handleTeleportToTarget(player: Player, rawTargetUserId: unknown): Types.DevMenuActionResult
	logger:debug("TeleportToTarget received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "TeleportToTarget")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local explicitTarget, explicitFailureReason = resolveOptionalExplicitTarget(rawTargetUserId)
	if explicitFailureReason then
		return { Success = false, Reason = explicitFailureReason }
	end
	local target = explicitTarget or resolveActionTarget(player)

	local targetRootPart, targetRootPartFailureReason = getRootPart(target, "TeleportToTarget")
	if not targetRootPart then
		return { Success = false, Reason = targetRootPartFailureReason }
	end

	local ok = AdminActionSystem.TeleportToPosition(player, targetRootPart.Position)
	if not ok then
		return { Success = false, Reason = "NoCharacter" }
	end

	logger:info("TeleportToTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

local function handleBringTarget(player: Player, rawTargetUserId: unknown): Types.DevMenuActionResult
	logger:debug("BringTarget received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "BringTarget")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local adminRootPart, adminRootPartFailureReason = getRootPart(player, "BringTarget")
	if not adminRootPart then
		return { Success = false, Reason = adminRootPartFailureReason }
	end

	local explicitTarget, explicitFailureReason = resolveOptionalExplicitTarget(rawTargetUserId)
	if explicitFailureReason then
		return { Success = false, Reason = explicitFailureReason }
	end
	local target = explicitTarget or resolveActionTarget(player)

	local ok = AdminActionSystem.TeleportToPosition(target, adminRootPart.Position)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("BringTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

local function handleTeleportToCoordinates(
	player: Player,
	rawX: unknown,
	rawY: unknown,
	rawZ: unknown
): Types.DevMenuActionResult
	logger:debug("TeleportToCoordinates received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "TeleportToCoordinates")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawX) ~= "number" or typeof(rawY) ~= "number" or typeof(rawZ) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	-- Defaults to self (resolveActionTarget's own lock-on-or-self resolution) -- there is no
	-- row-scoped variant of this one, since typing in raw coordinates is already an explicit,
	-- deliberate action with nothing left to disambiguate via a target picker.
	local target = resolveActionTarget(player)
	local position = Vector3.new(rawX, rawY, rawZ)
	local ok = AdminActionSystem.TeleportToPosition(target, position)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info(
		"TeleportToCoordinates accepted",
		{ player = player.Name, target = target.Name, position = tostring(position) }
	)
	return { Success = true }
end

local function handleForceRespawnTarget(player: Player): Types.DevMenuActionResult
	logger:debug("ForceRespawnTarget received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ForceRespawnTarget")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local target = resolveActionTarget(player)
	target:LoadCharacter()

	logger:info("ForceRespawnTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

-- Set once Init() creates the Announcement RemoteEvent -- see that function's own comment for why
-- this is a RemoteEvent (broadcast to every client) rather than the RemoteFunction shape every
-- other action in this file uses.
local announcementRemote: RemoteEvent? = nil

-- Shared by handleBroadcastAnnouncement (an admin-authored message) and handleShutdownServer's own
-- countdown warning below -- both are "tell every client something" broadcasts, just with a
-- different Kind/Message.
local function broadcastAnnouncement(kind: Types.DevMenuAnnouncementKind, message: string): ()
	if not announcementRemote then
		return
	end
	local payload: Types.DevMenuAnnouncementPayload = { Kind = kind, Message = message }
	announcementRemote:FireAllClients(payload)
end

local function handleBroadcastAnnouncement(player: Player, rawMessage: unknown): Types.DevMenuActionResult
	logger:debug("BroadcastAnnouncement received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "BroadcastAnnouncement")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawMessage) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local trimmed = (rawMessage:gsub("^%s+", ""):gsub("%s+$", ""))
	if #trimmed == 0 or #trimmed > DevMenuConfig.AnnouncementMaxLength then
		return { Success = false, Reason = "InvalidRequest" }
	end

	broadcastAnnouncement("Info", trimmed)

	logger:info("BroadcastAnnouncement accepted", { player = player.Name, length = #trimmed })
	return { Success = true }
end

-- Per-admin (keyed by UserId), not module-local -- docs/architecture/2026-08-audit.md section 3.6.10
-- flagged the prior module-local shape: any authorized admin's confirm press executed whichever
-- admin's arm was still open, not necessarily their own. 0 (not armed) rather than a missing key, so
-- the window itself expires without a separate timer to cancel. Cleared on PlayerRemoving below so a
-- departed admin's stale arm can never be confirmed by someone else re-using the slot.
local shutdownArmedUntil: { [number]: number } = {}

local function handleShutdownServer(player: Player): Types.DevMenuActionResult
	logger:debug("ShutdownServer received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ShutdownServer")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local now = os.clock()
	if now >= (shutdownArmedUntil[player.UserId] or 0) then
		shutdownArmedUntil[player.UserId] = now + DevMenuConfig.ShutdownConfirmWindowSeconds
		-- Unconditional Warn-level log for the initiating admin's UserId -- this is the one action
		-- where under-logging would be a real problem (see this System's own process reminders).
		logger:warn("ShutdownServer armed", { player = player.Name, userId = player.UserId })
		return { Success = false, Reason = "ConfirmationRequired" }
	end

	shutdownArmedUntil[player.UserId] = nil
	logger:warn("ShutdownServer confirmed -- server shutting down", {
		player = player.Name,
		userId = player.UserId,
		delaySeconds = DevMenuConfig.ShutdownDelaySeconds,
	})

	broadcastAnnouncement("Warning", `Server shutting down in {DevMenuConfig.ShutdownDelaySeconds} seconds.`)

	task.delay(DevMenuConfig.ShutdownDelaySeconds, function()
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			otherPlayer:Kick("Server shutting down")
		end
	end)

	return { Success = true }
end

-- Instant Restart Server admin action -- same two-press server-armed confirmation shape as
-- handleShutdownServer above (own per-admin armed-until table, so arming one of these two actions
-- never arms or disarms the other, and arming it never arms it for a different admin either -- see
-- shutdownArmedUntil's own comment), but the second press kicks IMMEDIATELY, no
-- ShutdownDelaySeconds countdown wait -- see Constants.Debug.DevMenu.InstantRestartConfirmWindowSeconds's
-- own header for why this exists as a distinct, faster action alongside Shutdown Server rather than
-- replacing it: an admin who has just published a place update and wants this server cycled onto it
-- right away has no reason to sit through a countdown warning meant for a planned maintenance
-- window.
local instantRestartArmedUntil: { [number]: number } = {}

local function handleInstantRestartServer(player: Player): Types.DevMenuActionResult
	logger:debug("InstantRestartServer received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "InstantRestartServer")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local now = os.clock()
	if now >= (instantRestartArmedUntil[player.UserId] or 0) then
		instantRestartArmedUntil[player.UserId] = now + DevMenuConfig.InstantRestartConfirmWindowSeconds
		-- Unconditional Warn-level log, same "under-logging would be a real problem" standard
		-- ShutdownServer's own arming log applies to itself.
		logger:warn("InstantRestartServer armed", { player = player.Name, userId = player.UserId })
		return { Success = false, Reason = "ConfirmationRequired" }
	end

	instantRestartArmedUntil[player.UserId] = nil
	logger:warn("InstantRestartServer confirmed -- server restarting immediately", {
		player = player.Name,
		userId = player.UserId,
	})

	broadcastAnnouncement("Warning", "Server restarting now for an update.")

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		otherPlayer:Kick("Server restarting for an update. Please rejoin.")
	end

	return { Success = true }
end

-- Passive "a newer version has been published" fetch (Server/Systems/VersionWatchSystem.lua) --
-- fetch-once-on-open, same shape as handleGetSidebarStats above. Purely
-- advisory: never kicks anyone, never announces anything, just reports what VersionWatchSystem
-- already knows so the Admin tab can show a banner nudging the admin toward Instant Restart/
-- Shutdown Server above.
local function handleGetServerVersionInfo(player: Player): Types.DevMenuServerVersionInfoResult
	logger:debug("GetServerVersionInfo received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "GetServerVersionInfo")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local bootPlaceVersion, latestKnownPlaceVersion = VersionWatchSystem.GetVersionInfo()
	return {
		Success = true,
		BootPlaceVersion = bootPlaceVersion,
		LatestKnownPlaceVersion = latestKnownPlaceVersion,
		NewerVersionAvailable = latestKnownPlaceVersion ~= nil and latestKnownPlaceVersion > bootPlaceVersion,
	}
end

-- Player roster ("Players" tab) -- one entry per Players:GetPlayers() at fetch time. Ping comes
-- straight off Player:GetNetworkPing() (Roblox's own round-trip estimate); Snapshot is always nil
-- now that the combat system (its one source) is gone -- see buildRosterEntry's own comment.
local function buildRosterEntry(target: Player): Types.PlayerRosterEntry
	return {
		UserId = target.UserId,
		Name = target.Name,
		-- Always nil now (Combat system removed) -- DevMenuClient.lua's formatRosterEntry already
		-- renders "HP --"/"Posture --" for a nil Snapshot, the same as it always did for a brand-new
		-- join, so this degrades safely with no client-side change needed.
		Snapshot = nil,
		Ping = target:GetNetworkPing(),
		Muted = ModerationSystem.IsMuted(target.UserId),
		SuspectedCheater = ModerationSystem.IsSuspectedCheater(target.UserId),
	}
end

local function handleListPlayers(player: Player): Types.DevMenuListPlayersResult
	logger:debug("ListPlayers received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ListPlayers")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local roster: { Types.PlayerRosterEntry } = {}
	for _, target in ipairs(Players:GetPlayers()) do
		table.insert(roster, buildRosterEntry(target))
	end

	return { Success = true, Players = roster }
end

local function handleKickPlayer(player: Player, rawTargetUserId: unknown, rawReason: unknown): Types.DevMenuActionResult
	logger:debug("KickPlayer received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "KickPlayer")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawReason) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target, targetFailureReason = resolveTargetUserId(rawTargetUserId)
	if not target then
		return { Success = false, Reason = targetFailureReason }
	end

	local trimmedReason = rawReason:gsub("^%s+", ""):gsub("%s+$", "")
	if #trimmedReason == 0 then
		trimmedReason = "Kicked by an administrator."
	end

	ModerationSystem.KickPlayer(target, trimmedReason)

	-- Unconditional log with the reason text -- same "under-logging would be a real problem" standard
	-- as ShutdownServer above.
	logger:warn(
		"KickPlayer accepted",
		{ player = player.Name, targetUserId = target.UserId, target = target.Name, reason = trimmedReason }
	)
	return { Success = true }
end

local function handleBanPlayer(
	player: Player,
	rawTargetUserId: unknown,
	rawReason: unknown,
	rawExpiresAt: unknown
): Types.DevMenuActionResult
	logger:debug("BanPlayer received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "BanPlayer")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if not isPlausibleUserId(rawTargetUserId) then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawReason) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	-- Finite, future-dated ExpiresAt only -- nil already means "permanent" (ModerationSystem.
	-- BanPlayer's own contract). Without this, a NaN/inf/past-dated ExpiresAt silently creates a
	-- ban record ModerationSystem.IsBanned would treat as already-expired or as a no-op, giving the
	-- admin no indication the ban they just placed does nothing.
	if
		rawExpiresAt ~= nil
		and (
			typeof(rawExpiresAt) ~= "number"
			or rawExpiresAt ~= rawExpiresAt
			or rawExpiresAt <= os.time()
			or rawExpiresAt == math.huge
		)
	then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local trimmedReason = (rawReason:gsub("^%s+", ""):gsub("%s+$", ""))
	if #trimmedReason == 0 then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local ok = ModerationSystem.BanPlayer(rawTargetUserId, player.UserId, trimmedReason, rawExpiresAt :: number?)
	if not ok then
		return { Success = false, Reason = "StorageError" }
	end

	-- BanPlayer only writes the DataStore record -- it has no idea whether the target is currently
	-- online. Kick them immediately if they are, so a ban takes effect right away instead of waiting
	-- for their next join.
	local onlineTarget = Players:GetPlayerByUserId(rawTargetUserId)
	if onlineTarget then
		onlineTarget:Kick(`You are banned: {trimmedReason}`)
	end

	logger:warn("BanPlayer accepted", {
		player = player.Name,
		targetUserId = rawTargetUserId,
		reason = trimmedReason,
		expiresAt = rawExpiresAt,
	})
	return { Success = true }
end

local function handleMutePlayer(
	player: Player,
	rawTargetUserId: unknown,
	rawEnabled: unknown
): Types.DevMenuActionResult
	logger:debug("MutePlayer received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "MutePlayer")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if not isPlausibleUserId(rawTargetUserId) then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	ModerationSystem.MutePlayer(rawTargetUserId, rawEnabled)

	logger:info("MutePlayer accepted", { player = player.Name, targetUserId = rawTargetUserId, enabled = rawEnabled })
	return { Success = true }
end

-- Wipes a target's SAVED progression data back to a fresh profile (PlayerDataSystem.ResetProfile)
-- -- "Players" tab roster row, explicit-UserId-only targeting (resolveTargetUserId, never
-- resolveActionTarget's lock-on-or-self picker), same reasoning as KickPlayer/BanPlayer/MutePlayer
-- above even though this isn't a ModerationSystem action: a data wipe is IRREVERSIBLE, a strictly
-- higher-stakes action than Kick (undone by rejoining) and arguably higher than Ban (still
-- reversible/expirable, and the target's progression sits untouched in the DataStore the whole
-- time it's in effect) -- accidentally applying this to whoever resolveActionTarget's self-fallback
-- happens to resolve to is unacceptable in a way that fallback is fine for elsewhere in this file
-- (every OTHER action it feeds is transient/reversible). Unlike
-- resolveTargetUserId's other callers, this ALSO requires the target to have a currently-loaded
-- profile (PlayerDataSystem.ResetProfile's own precondition) -- an offline wipe is out of scope on
-- purpose, since that would mean a raw DataStore write bypassing the "only Transform/ResetProfile
-- touch a loaded profile" model this whole System is built around.
local function handleResetTargetPlayerData(player: Player, rawTargetUserId: unknown): Types.DevMenuActionResult
	logger:debug("ResetTargetPlayerData received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ResetTargetPlayerData")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local target, targetFailureReason = resolveTargetUserId(rawTargetUserId)
	if not target then
		return { Success = false, Reason = targetFailureReason }
	end

	local ok = PlayerDataSystem.ResetProfile(target)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	-- Unconditional warn, same "under-logging would be a real problem" standard KickPlayer/
	-- BanPlayer above already apply to every other destructive/DataStore-backed admin action.
	logger:warn(
		"ResetTargetPlayerData accepted",
		{ player = player.Name, targetUserId = target.UserId, target = target.Name }
	)
	return { Success = true }
end

-- Reversible manual cheater-flag toggle ("Players" tab roster row) -- same explicit-UserId targeting
-- as KickPlayer/BanPlayer/MutePlayer above (resolveTargetUserId, never resolveActionTarget's
-- lock-on-or-self picker: a moderation action should never silently apply to whoever happens to be
-- locked on). Reuses the roster's shared ActionReasonText field the same way Kick/Ban already do --
-- see DevMenuHandle.ActionReasonText's own header. An empty/whitespace-only reason falls back to a
-- default rather than rejecting the request, matching Kick's fallback (not Ban's hard reject) since
-- flagging is the lower-severity, fully-reversible action of the two.
local function handleSetSuspectedCheater(
	player: Player,
	rawTargetUserId: unknown,
	rawEnabled: unknown,
	rawReason: unknown
): Types.DevMenuActionResult
	logger:debug("SetSuspectedCheater received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetSuspectedCheater")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawReason) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target, targetFailureReason = resolveTargetUserId(rawTargetUserId)
	if not target then
		return { Success = false, Reason = targetFailureReason }
	end

	local ok: boolean
	if rawEnabled then
		local trimmedReason = (rawReason:gsub("^%s+", ""):gsub("%s+$", ""))
		if #trimmedReason == 0 then
			trimmedReason = "Flagged by an administrator."
		end
		ok = ModerationSystem.FlagSuspectedCheater(target.UserId, player.UserId, trimmedReason, "Manual")
	else
		ok = ModerationSystem.UnflagSuspectedCheater(target.UserId)
	end
	if not ok then
		return { Success = false, Reason = "StorageError" }
	end

	logger:info(
		"SetSuspectedCheater accepted",
		{ player = player.Name, targetUserId = target.UserId, enabled = rawEnabled }
	)
	return { Success = true }
end

-- Sidebar header stats (persistent Sidebar, Screens/DevMenu/Sidebar.lua) -- combines two independent
-- in-memory counters (BugReportSystem.GetOpenCount/ModerationSystem.GetSuspectedCheaterCount) into
-- one response so the Sidebar pays a single round trip. Neither counter is computed here -- this
-- handler only gates the request and forwards each System's own already-maintained number.
-- Hitbox visualisation -------------------------------------------------------------------------------

-- Reads the server-wide swing-volume visualiser's current state. Fetched once when the DevMenu opens,
-- the same fetch-once-on-open shape GetSidebarStats uses, so the Tuning tab's toggle renders the truth
-- rather than a guess an admin then has to press twice to correct.
local function handleGetHitboxDebug(player: Player): Types.DevMenuHitboxDebugResult
	logger:debug("GetHitboxDebug received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "GetHitboxDebug")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	return { Success = true, Enabled = HitboxEngine.IsDebugVolumesEnabled() }
end

-- Flips it. SERVER-WIDE AND VISIBLE TO EVERYONE, which is the whole reason it sits behind the same
-- admin whitelist every other action in this file does: the engine draws its volumes as real
-- server-side Parts, so they replicate to every client in the place. This is not a personal overlay
-- and must never be reachable by an ordinary player.
--
-- Returns the value that actually took effect rather than echoing the request, so the client's toggle
-- can refresh from the answer with no second round trip -- and so a future gate that refuses the flip
-- reports honestly instead of leaving the UI showing something the server never did.
local function handleSetHitboxDebug(player: Player, rawEnabled: unknown): Types.DevMenuHitboxDebugResult
	logger:debug("SetHitboxDebug received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetHitboxDebug")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	HitboxEngine.SetDebugVolumesEnabled(rawEnabled)
	logger:info("SetHitboxDebug accepted", { player = player.Name, enabled = rawEnabled })
	return { Success = true, Enabled = HitboxEngine.IsDebugVolumesEnabled() }
end

-- Debug dummy ("Spawn" tab) -------------------------------------------------------------------------

-- Spawns one debug dummy SpawnDistance studs in front of the requesting admin's own character, facing
-- them -- same geometry as every other "spawn near me" admin convenience (see getRootPart above),
-- never a player-select UI. Delegates entirely to Server/Systems/DebugDummySystem.lua; this handler
-- owns only authorization/validation and the position math.
local function handleSpawnDebugDummy(player: Player): Types.DevMenuActionResult
	logger:debug("SpawnDebugDummy received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SpawnDebugDummy")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local rootPart, rootPartFailureReason = getRootPart(player, "SpawnDebugDummy")
	if not rootPart then
		return { Success = false, Reason = rootPartFailureReason }
	end

	local spawnCFrame = rootPart.CFrame * CFrame.new(0, 0, -Constants.Debug.TrainingDummy.SpawnDistance)
	local model, spawnFailureReason = DebugDummySystem.Spawn(spawnCFrame)
	if not model then
		return { Success = false, Reason = spawnFailureReason or "SpawnFailed" }
	end

	logger:info("SpawnDebugDummy accepted", { player = player.Name })
	return { Success = true }
end

-- Blimp Fuel System dev/test nodes ("Spawn" tab) -----------------------------------------------

-- Studs in front of the requesting admin's own character to spawn a debug resource node -- its own
-- number rather than reusing Constants.Debug.TrainingDummy.SpawnDistance, since that constant is
-- named for (and tunable independently of) the dummy, not this unrelated dev tool.
local RESOURCE_NODE_SPAWN_DISTANCE = 6

-- Spawns one tagged CoalDeposit Part RESOURCE_NODE_SPAWN_DISTANCE studs in front of the requesting
-- admin, same "spawn near me" geometry as SpawnDebugDummy above. Delegates entirely to
-- Server/Systems/ResourceGatheringSystem.SpawnDebugNode; this handler owns only authorization and the
-- position math.
local function handleSpawnCoalDeposit(player: Player): Types.DevMenuActionResult
	logger:debug("SpawnCoalDeposit received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SpawnCoalDeposit")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local rootPart, rootPartFailureReason = getRootPart(player, "SpawnCoalDeposit")
	if not rootPart then
		return { Success = false, Reason = rootPartFailureReason }
	end

	local spawnCFrame = rootPart.CFrame * CFrame.new(0, 0, -RESOURCE_NODE_SPAWN_DISTANCE)
	ResourceGatheringSystem.SpawnDebugNode("Coal", spawnCFrame)

	logger:info("SpawnCoalDeposit accepted", { player = player.Name })
	return { Success = true }
end

-- Same shape as handleSpawnCoalDeposit above, for the WaterSource tag.
local function handleSpawnWaterSource(player: Player): Types.DevMenuActionResult
	logger:debug("SpawnWaterSource received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SpawnWaterSource")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local rootPart, rootPartFailureReason = getRootPart(player, "SpawnWaterSource")
	if not rootPart then
		return { Success = false, Reason = rootPartFailureReason }
	end

	local spawnCFrame = rootPart.CFrame * CFrame.new(0, 0, -RESOURCE_NODE_SPAWN_DISTANCE)
	ResourceGatheringSystem.SpawnDebugNode("Water", spawnCFrame)

	logger:info("SpawnWaterSource accepted", { player = player.Name })
	return { Success = true }
end

-- Fills the requesting admin's OWN carried coal and water to the cap (Shared/Blimp/BlimpConstants.
-- Carry, read by ResourceGatheringSystem.FillCarriedFuel, which owns the field -- see that function's
-- own header for why the write is not done here).
--
-- NO getRootPart, unlike the two node spawns above: this touches a profile, not the world, so it works
-- for an admin who has not spawned yet and needs no position at all.
local function handleFillCarriedFuel(player: Player): Types.DevMenuActionResult
	logger:debug("FillCarriedFuel received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "FillCarriedFuel")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	if not ResourceGatheringSystem.FillCarriedFuel(player) then
		-- The one way this fails: the profile has not finished loading (or failed to). Reported rather
		-- than swallowed, because a tester who presses this and sees nothing move needs to know it was
		-- the server and not their own aim -- the same reasoning behind the furnace prompt's own
		-- outcome push (Shared/Blimp/BlimpConstants.Network.RemoteNames.FuelTransfer).
		return { Success = false, Reason = "StorageError" }
	end

	logger:info("FillCarriedFuel accepted", { player = player.Name })
	return { Success = true }
end

-- Clears every active debug dummy at once -- the Spawn tab's deliberate full-reset companion to
-- SpawnDebugDummy above (MaxActive eviction already handles the "too many at once" case one at a
-- time; this is for a tester who wants a clean training area right now).
local function handleDespawnAllDebugDummies(player: Player): Types.DevMenuActionResult
	logger:debug("DespawnAllDebugDummies received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "DespawnAllDebugDummies")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local count = DebugDummySystem.DespawnAll()
	logger:info("DespawnAllDebugDummies accepted", { player = player.Name, count = count })
	return { Success = true }
end

-- Server-wide guard toggle -- see DebugDummySystem.SetGuard's own header for why this applies to
-- every active dummy at once rather than needing a per-dummy picker. Returns the value that actually
-- took effect (always the request here, but echoed the same "never let the client guess a server-wide
-- toggle" way SetHitboxDebug's own handler above does).
local function handleSetDummyGuard(player: Player, rawEnabled: unknown): Types.DevMenuDebugDummyStateResult
	logger:debug("SetDummyGuard received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetDummyGuard")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local guardEnabled = DebugDummySystem.SetGuard(rawEnabled)
	logger:info("SetDummyGuard accepted", { player = player.Name, enabled = guardEnabled })
	return { Success = true, GuardEnabled = guardEnabled, ActiveCount = DebugDummySystem.ActiveCount() }
end

-- Fetch-once-on-open for the Spawn tab -- same "never let a joining admin's client guess a
-- server-wide toggle's truth" reasoning handleGetHitboxDebug above already establishes.
local function handleGetDebugDummyState(player: Player): Types.DevMenuDebugDummyStateResult
	logger:debug("GetDebugDummyState received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "GetDebugDummyState")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	return {
		Success = true,
		GuardEnabled = DebugDummySystem.IsGuardEnabled(),
		ActiveCount = DebugDummySystem.ActiveCount(),
	}
end

local function handleGetSidebarStats(player: Player): Types.DevMenuSidebarStatsResult
	logger:debug("GetSidebarStats received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "GetSidebarStats")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	return {
		Success = true,
		BugReportOpenCount = BugReportSystem.GetOpenCount(),
		SuspectedCheaterCount = ModerationSystem.GetSuspectedCheaterCount(),
	}
end

-- Closed whitelist for the flight-tuning param below -- unlike a plain typeof(x) ~= "string" check,
-- this ALSO rejects any string outside the exact known set, which matters here specifically because
-- `field` ultimately selects which table KEY gets written on a live Constants.Flight table, scoped to
-- the flight feel tuner (handleAdjustFlightTuning/handleResetFlightTuning below) -- rejects any string
-- outside FlightTuning.lua's own curated field set before it can be used to pick which Constants.
-- Flight key gets written.
local FLIGHT_TUNING_FIELDS: { [string]: Types.FlightTuningFieldName } = {
	CruiseSpeed = "CruiseSpeed",
	BoostSpeedMultiplier = "BoostSpeedMultiplier",
	Acceleration = "Acceleration",
	BoostAcceleration = "BoostAcceleration",
	Deceleration = "Deceleration",
	VerticalSpeedFraction = "VerticalSpeedFraction",
	MaxBankAngleDegrees = "MaxBankAngleDegrees",
	MaxPitchAngleDegrees = "MaxPitchAngleDegrees",
	BankTurnRateSensitivity = "BankTurnRateSensitivity",
	TakeoffBurstUpSpeed = "TakeoffBurstUpSpeed",
	TakeoffBurstForwardSpeed = "TakeoffBurstForwardSpeed",
	HoverBobAmplitudeStuds = "HoverBobAmplitudeStuds",
	SoftLandingSpeedThreshold = "SoftLandingSpeedThreshold",
	HardLandingSpeedThreshold = "HardLandingSpeedThreshold",
	SonicBoomSpeedThreshold = "SonicBoomSpeedThreshold",
}

local function handleListFlightTuning(player: Player): Types.DevMenuListFlightTuningResult
	logger:debug("ListFlightTuning received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ListFlightTuning")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	return { Success = true, Fields = FlightTuning.ListFields() }
end

local function handleAdjustFlightTuning(
	player: Player,
	rawField: unknown,
	rawDeltaFraction: unknown
): Types.DevMenuFlightTuningResult
	logger:debug("AdjustFlightTuning received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "AdjustFlightTuning")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	local field = resolveEnum(rawField, FLIGHT_TUNING_FIELDS)
	if not field then
		return { Success = false, Reason = "InvalidRequest" }
	end
	-- rawDeltaFraction ~= rawDeltaFraction rejects NaN (the standard self-inequality test) -- without
	-- it, NaN passes this typeof check, then FlightTuning.AdjustField's own math.clamp leaves a NaN
	-- unchanged (NaN fails both the < and > comparisons a clamp is built from), permanently poisoning
	-- the SHARED Constants.Flight[field] value every flying client reads by reference, not just this
	-- admin's own session.
	if typeof(rawDeltaFraction) ~= "number" or rawDeltaFraction ~= rawDeltaFraction then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local updated = FlightTuning.AdjustField(field, rawDeltaFraction)
	if not updated then
		return { Success = false, Reason = "InvalidRequest" }
	end

	logger:info(
		"AdjustFlightTuning accepted",
		{ player = player.Name, field = field, deltaFraction = rawDeltaFraction }
	)
	return { Success = true, Field = updated }
end

local function handleResetFlightTuning(player: Player, rawField: unknown): Types.DevMenuFlightTuningResult
	logger:debug("ResetFlightTuning received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ResetFlightTuning")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	local field = resolveEnum(rawField, FLIGHT_TUNING_FIELDS)
	if not field then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local updated = FlightTuning.ResetField(field)
	if not updated then
		return { Success = false, Reason = "InvalidRequest" }
	end

	logger:info("ResetFlightTuning accepted", { player = player.Name, field = field })
	return { Success = true, Field = updated }
end

-- Bug report triage ("Reports" tab, DevMenu/init.lua) -- both handlers gate here exactly like
-- every action above, then delegate to BugReportSystem's public API. BugReportSystem itself has no
-- admin-authorization notion of its own; it trusts these two callers the same way every other
-- delegated-to System in this file does.
local function handleListBugReports(player: Player, rawCursorMode: unknown): Types.DevMenuListBugReportsResult
	logger:debug("ListBugReports received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ListBugReports")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local cursorMode: Types.BugReportListCursorMode = if rawCursorMode == "Next" then "Next" else "First"
	local reports, hasMore, failReason = BugReportSystem.ListReports(player, cursorMode)
	if not reports then
		return { Success = false, Reason = failReason or "InternalError" }
	end

	return { Success = true, Reports = reports, HasMore = hasMore }
end

local function handleUpdateBugReportStatus(
	player: Player,
	rawReportId: unknown,
	rawStatus: unknown
): Types.DevMenuUpdateBugReportStatusResult
	logger:debug("UpdateBugReportStatus received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "UpdateBugReportStatus")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawReportId) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if not BugReportSystem.IsValidStatus(rawStatus) then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local updated, failReason = BugReportSystem.UpdateStatus(player, rawReportId, rawStatus :: Types.BugReportStatus)
	if not updated then
		return { Success = false, Reason = failReason or "NotFound" }
	end

	logger:info("UpdateBugReportStatus accepted", { player = player.Name, id = rawReportId, status = rawStatus })
	return { Success = true, Report = updated }
end

local function handleAddBugReportNote(
	player: Player,
	rawReportId: unknown,
	rawText: unknown
): Types.DevMenuBugReportMutationResult
	logger:debug("AddBugReportNote received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "AddBugReportNote")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawReportId) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local updated, failReason = BugReportSystem.AddNote(player, rawReportId, rawText)
	if not updated then
		return { Success = false, Reason = failReason or "NotFound" }
	end

	logger:info("AddBugReportNote accepted", { player = player.Name, id = rawReportId })
	return { Success = true, Report = updated }
end

local function handleSetBugReportPriority(
	player: Player,
	rawReportId: unknown,
	rawPriority: unknown
): Types.DevMenuBugReportMutationResult
	logger:debug("SetBugReportPriority received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetBugReportPriority")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawReportId) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if not BugReportSystem.IsValidPriority(rawPriority) then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local updated, failReason = BugReportSystem.SetPriority(player, rawReportId, rawPriority :: Types.BugReportPriority)
	if not updated then
		return { Success = false, Reason = failReason or "NotFound" }
	end

	logger:info("SetBugReportPriority accepted", { player = player.Name, id = rawReportId, priority = rawPriority })
	return { Success = true, Report = updated }
end

local function handleAssignBugReport(
	player: Player,
	rawReportId: unknown,
	rawAssign: unknown
): Types.DevMenuBugReportMutationResult
	logger:debug("AssignBugReport received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "AssignBugReport")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawReportId) ~= "string" or typeof(rawAssign) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local updated, failReason = BugReportSystem.AssignReport(player, rawReportId, rawAssign)
	if not updated then
		return { Success = false, Reason = failReason or "NotFound" }
	end

	logger:info("AssignBugReport accepted", { player = player.Name, id = rawReportId, assign = rawAssign })
	return { Success = true, Report = updated }
end

-- Teleports the requesting admin straight to wherever a report's reporter currently is IN THIS
-- SERVER -- deliberately does NOT reuse resolveActionTarget/TeleportToTarget's lock-on resolution
-- (that resolves whoever the admin has locked onto in combat, unrelated to a specific report's
-- reporter). Players:GetPlayerByUserId only ever returns a live Player on THIS server instance, so
-- a reporter who submitted from a different server (or has since left) correctly falls through to
-- "ReporterNotHere" rather than silently no-oping.
local function handleJumpToReporter(player: Player, rawReportId: unknown): Types.DevMenuActionResult
	logger:debug("JumpToReporter received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "JumpToReporter")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawReportId) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local record, getFailReason = BugReportSystem.GetRecord(rawReportId)
	if not record then
		return { Success = false, Reason = getFailReason or "NotFound" }
	end

	local reporter = Players:GetPlayerByUserId(record.ReporterUserId)
	if not reporter then
		return { Success = false, Reason = "ReporterNotHere" }
	end

	local reporterRootPart, reporterRootPartFailureReason = getRootPart(reporter, "JumpToReporter")
	if not reporterRootPart then
		return { Success = false, Reason = reporterRootPartFailureReason }
	end

	local ok = AdminActionSystem.TeleportToPosition(player, reporterRootPart.Position)
	if not ok then
		return { Success = false, Reason = "NoCharacter" }
	end

	logger:info("JumpToReporter accepted", { player = player.Name, reporter = reporter.Name })
	return { Success = true }
end

-- The pcall-wrap-and-log-error boilerplate every RemoteFunction below used to hand-duplicate in
-- Init() now lives in Shared/RemoteHandler.WrapInvoke -- see that module's own header. The literal
-- error result below is shared across every handler in REMOTE_HANDLERS, since every one of this
-- System's Result types shares the same Success/Reason pair (Types.DevMenu*Result).
local DEV_MENU_INTERNAL_ERROR_RESULT = { Success = false, Reason = "InternalError" }

-- Every RemoteFunction this System registers, as data rather than 37 hand-duplicated 5-line blocks.
-- RemoteKey indexes DevMenuConfig.RemoteNames; Name is what RemoteHandler.WrapInvoke logs a caught
-- error under -- usually identical to RemoteKey, EXCEPT SpawnDummy below, which keeps the config's
-- un-renamed "SpawnDummy" key (see that field's own comment) paired with the handler's real name.
-- Handler is cast to `any` because this table deliberately holds handlers of different Result/Args
-- types side by side -- the same heterogeneity RemoteHandler.WrapInvoke's own generic accepts;
-- Init() still gets a fully-typed `(Player, Args...) -> Result` back out of it for each one.
type RemoteHandlerSpec = {
	RemoteKey: string,
	Name: string,
	Handler: (Player, ...any) -> any,
}
local REMOTE_HANDLERS: { RemoteHandlerSpec } = {
	{ RemoteKey = "RollEmote", Name = "RollEmote", Handler = handleRollEmote :: any },
	{
		RemoteKey = "GrantBloodlineRerolls",
		Name = "GrantBloodlineRerolls",
		Handler = handleGrantBloodlineRerolls :: any,
	},
	{ RemoteKey = "SetTargetGodmode", Name = "SetTargetGodmode", Handler = handleSetTargetGodmode :: any },
	{ RemoteKey = "SetTargetFlight", Name = "SetTargetFlight", Handler = handleSetTargetFlight :: any },
	{
		RemoteKey = "SetTargetFlightCollide",
		Name = "SetTargetFlightCollide",
		Handler = handleSetTargetFlightCollide :: any,
	},
	{ RemoteKey = "ListFlightTuning", Name = "ListFlightTuning", Handler = handleListFlightTuning :: any },
	{ RemoteKey = "AdjustFlightTuning", Name = "AdjustFlightTuning", Handler = handleAdjustFlightTuning :: any },
	{ RemoteKey = "ResetFlightTuning", Name = "ResetFlightTuning", Handler = handleResetFlightTuning :: any },
	{ RemoteKey = "ListBugReports", Name = "ListBugReports", Handler = handleListBugReports :: any },
	{
		RemoteKey = "UpdateBugReportStatus",
		Name = "UpdateBugReportStatus",
		Handler = handleUpdateBugReportStatus :: any,
	},
	{ RemoteKey = "AddBugReportNote", Name = "AddBugReportNote", Handler = handleAddBugReportNote :: any },
	{ RemoteKey = "SetBugReportPriority", Name = "SetBugReportPriority", Handler = handleSetBugReportPriority :: any },
	{ RemoteKey = "AssignBugReport", Name = "AssignBugReport", Handler = handleAssignBugReport :: any },
	{ RemoteKey = "JumpToReporter", Name = "JumpToReporter", Handler = handleJumpToReporter :: any },
	{ RemoteKey = "SetTargetFrozen", Name = "SetTargetFrozen", Handler = handleSetTargetFrozen :: any },
	{ RemoteKey = "SetTargetInvisible", Name = "SetTargetInvisible", Handler = handleSetTargetInvisible :: any },
	{
		RemoteKey = "SetTargetSpeedMultiplier",
		Name = "SetTargetSpeedMultiplier",
		Handler = handleSetTargetSpeedMultiplier :: any,
	},
	{ RemoteKey = "TeleportToTarget", Name = "TeleportToTarget", Handler = handleTeleportToTarget :: any },
	{ RemoteKey = "BringTarget", Name = "BringTarget", Handler = handleBringTarget :: any },
	{
		RemoteKey = "TeleportToCoordinates",
		Name = "TeleportToCoordinates",
		Handler = handleTeleportToCoordinates :: any,
	},
	{ RemoteKey = "ForceRespawnTarget", Name = "ForceRespawnTarget", Handler = handleForceRespawnTarget :: any },
	{
		RemoteKey = "BroadcastAnnouncement",
		Name = "BroadcastAnnouncement",
		Handler = handleBroadcastAnnouncement :: any,
	},
	{ RemoteKey = "ShutdownServer", Name = "ShutdownServer", Handler = handleShutdownServer :: any },
	{ RemoteKey = "InstantRestartServer", Name = "InstantRestartServer", Handler = handleInstantRestartServer :: any },
	{ RemoteKey = "ListPlayers", Name = "ListPlayers", Handler = handleListPlayers :: any },
	{ RemoteKey = "KickPlayer", Name = "KickPlayer", Handler = handleKickPlayer :: any },
	{ RemoteKey = "BanPlayer", Name = "BanPlayer", Handler = handleBanPlayer :: any },
	{ RemoteKey = "MutePlayer", Name = "MutePlayer", Handler = handleMutePlayer :: any },
	{
		RemoteKey = "ResetTargetPlayerData",
		Name = "ResetTargetPlayerData",
		Handler = handleResetTargetPlayerData :: any,
	},
	{ RemoteKey = "SetSuspectedCheater", Name = "SetSuspectedCheater", Handler = handleSetSuspectedCheater :: any },
	{ RemoteKey = "GetSidebarStats", Name = "GetSidebarStats", Handler = handleGetSidebarStats :: any },
	{ RemoteKey = "GetHitboxDebug", Name = "GetHitboxDebug", Handler = handleGetHitboxDebug :: any },
	{ RemoteKey = "SetHitboxDebug", Name = "SetHitboxDebug", Handler = handleSetHitboxDebug :: any },
	-- Config key stays "SpawnDummy" (DevMenuConfig.lua never renamed it -- see that field's own
	-- comment, "the direct successor to that action, not a new feature sharing an old label"), but
	-- the handler and its error-log name are the real "SpawnDebugDummy" identity.
	{ RemoteKey = "SpawnDummy", Name = "SpawnDebugDummy", Handler = handleSpawnDebugDummy :: any },
	{
		RemoteKey = "DespawnAllDebugDummies",
		Name = "DespawnAllDebugDummies",
		Handler = handleDespawnAllDebugDummies :: any,
	},
	{ RemoteKey = "SetDummyGuard", Name = "SetDummyGuard", Handler = handleSetDummyGuard :: any },
	{ RemoteKey = "GetDebugDummyState", Name = "GetDebugDummyState", Handler = handleGetDebugDummyState :: any },
	{ RemoteKey = "GetServerVersionInfo", Name = "GetServerVersionInfo", Handler = handleGetServerVersionInfo :: any },
	{ RemoteKey = "SpawnCoalDeposit", Name = "SpawnCoalDeposit", Handler = handleSpawnCoalDeposit :: any },
	{ RemoteKey = "SpawnWaterSource", Name = "SpawnWaterSource", Handler = handleSpawnWaterSource :: any },
	{ RemoteKey = "FillCarriedFuel", Name = "FillCarriedFuel", Handler = handleFillCarriedFuel :: any },
}

function DevMenuSystem.Init(): ()
	for _, spec in REMOTE_HANDLERS do
		local remoteName = DevMenuConfig.RemoteNames[spec.RemoteKey]
		local remote = NetworkBridge.CreateRemoteFunction(remoteName)
		logger:debug("Remote created", { name = remoteName })
		remote.OnServerInvoke =
			RemoteHandler.WrapInvoke(logger, spec.Name, DEV_MENU_INTERNAL_ERROR_RESULT, spec.Handler)
		logger:debug("Handler connected", { remote = remoteName })
	end

	-- RemoteEvent, not RemoteFunction -- broadcast to every client (Client/Announcement/
	-- AnnouncementClient.lua, unconditional for every player, not just admins). Created here (not
	-- inside broadcastAnnouncement) so it exists before any handler could possibly fire it. Not in
	-- REMOTE_HANDLERS above: that table is RemoteFunctions only, this is the one deliberate
	-- RemoteEvent exception (see this module's own header).
	announcementRemote = NetworkBridge.CreateRemoteEvent(DevMenuConfig.RemoteNames.Announcement)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.Announcement })

	PlayerLifecycle.BindAllPlayers({
		Scope = "DevMenuSystem",
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
			shutdownArmedUntil[player.UserId] = nil
			instantRestartArmedUntil[player.UserId] = nil
		end,
	})

	logger:info("DevMenuSystem.Init() complete")
end

return DevMenuSystem :: Types.SystemModule
