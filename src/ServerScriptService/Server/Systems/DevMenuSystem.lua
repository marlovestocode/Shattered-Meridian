--!strict
--[[
	DevMenuSystem.lua

	Owns: server-side authorization and request handling for whitelist-gated developer tooling
	(Constants.Debug.DevMenu for tunables; Server/Config/AdminConfig.lua for the whitelist itself).
	Every request re-checks AdminConfig.AuthorizedUserIds[player.UserId] itself, regardless of what
	the client believes. That list deliberately lives in a server-only module rather than in
	Constants.lua, which replicates -- see AdminConfig.lua's own header. DevMenuClient.lua therefore
	no longer holds a local copy to gate itself with; it asks this System instead, over the
	GetSidebarStats RemoteFunction it already calls at startup, and a rejection from any handler here
	is the authorization answer. Unlike Logger.lua, this System
	is NOT Studio-gated -- Constants.Debug.DevMenu's own header is explicit that dev tooling is
	meant to work in live servers too; safety comes entirely from the whitelist plus this System's
	own re-check on every request, never from RunService:IsStudio() or from being hidden.

	Does not own: what a dev action actually does -- CombatSystem.SpawnTrainingDummy/SpawnTrainingBot
	own training dummy/bot creation, TrainingBotSystem.ValidatePresetRequest owns validating a
	bot spawn request's preset/weights (never trusted here directly), AdminActionSystem owns the
	Godmode/Flying/FlightCollide/Frozen/Invisible/SpeedMultiplier/Teleport override actions,
	CombatSystem.SetPlayerHealth/ResetCombatState own direct health mutation and the "clear cooldowns/
	combo/vitals-timers without a respawn" action, and ModerationSystem owns Kick/Ban/Mute -- this
	System only decides *whether* a given request is allowed to reach those, then translates the
	request/response shape. Uses RemoteFunctions, not RemoteEvents, since the client needs to know
	immediately whether its request was accepted (see Types.DevMenuSpawnDummyResult/
	DevMenuSpawnBotResult) -- Announcement is the one deliberate exception (a genuine broadcast to
	every client, not just the requesting admin), so it's a RemoteEvent instead.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

local CombatSystem = require(script.Parent.CombatSystem)
local TrainingBotSystem = require(script.Parent.TrainingBotSystem)
local AdminActionSystem = require(script.Parent.AdminActionSystem)
local HitboxTuning = require(script.Parent.Parent.Combat.HitboxTuning)
local FlightTuning = require(script.Parent.Parent.DevMenu.FlightTuning)
local BugReportSystem = require(script.Parent.BugReportSystem)
local ModerationSystem = require(script.Parent.ModerationSystem)
local AdminConfig = require(script.Parent.Parent.Config.AdminConfig)

local DevMenuSystem = {}

local logger = Logger.scope("DevMenuSystem")

local DevMenuConfig = Constants.Debug.DevMenu

-- Own bucket, separate from CombatSystem's -- dev tooling requests shouldn't compete with (or be
-- starved by) a player's combat remote budget, and vice versa. Shared by EVERY handler in this
-- file, including SetSuspectedCheater/GetSidebarStats: an earlier pass gave those two their own
-- dedicated instances with no documented technical reason (both are low-frequency, one-shot,
-- admin-only requests -- GetSidebarStats fires once per DevMenuClient.Start(), SetSuspectedCheater
-- fires on a UI button click -- the same call profile every other handler below already shares this
-- bucket for), so a Chief Architect review consolidated them back here per this file's own
-- checkDevMenuPreconditions header ("unifying what every one of the handlers below used to
-- hand-duplicate"); a future handler with a genuinely different call-frequency profile (e.g. a
-- per-Heartbeat polling remote) would be the kind of case that legitimately earns its own bucket.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

-- Reads Server/Config/AdminConfig.lua, not Constants -- the whitelist deliberately lives in a
-- server-only module so it never replicates to clients. See AdminConfig.lua's own header.
local function isAuthorized(player: Player): boolean
	return AdminConfig.AuthorizedUserIds[player.UserId] == true
end

-- Shared auth + rate-limit precondition, unifying what every one of the 15 (now 17) handlers below
-- used to hand-duplicate: CombatSystem.lua already solved this exact problem for itself with its
-- ACTION_GATES table -- this is the DevMenuSystem equivalent, extracted after that same
-- hand-duplicated-gate failure mode (per CombatSystem.lua's own ACTION_GATES header: "the same
-- failure mode any hand-duplicated gate is one edit away from repeating") showed up here too.
-- actionName feeds both the "X rejected: ..." log message and the caller's own "X received" debug
-- line, so callers only need to name their action once. `limiter` defaults to the shared `rateLimiter`
-- above -- every handler in this file now uses the shared bucket (see that variable's own comment).
-- Returns (true, nil) when the request may proceed, or (false, Reason) with the Reason string every
-- handler's own Result shape already uses.
local function checkDevMenuPreconditions(
	player: Player,
	actionName: string,
	limiter: RateLimiter.RateLimiterInstance?
): (boolean, string?)
	if not isAuthorized(player) then
		logger:warn(actionName .. " rejected: not authorized", { player = player.Name, userId = player.UserId })
		return false, "NotAuthorized"
	end
	if (limiter or rateLimiter):IsLimited(player) then
		logger:debug(actionName .. " rejected: rate limited", { player = player.Name, userId = player.UserId })
		return false, "RateLimited"
	end
	return true, nil
end

-- Shared "does this player have a live character with a HumanoidRootPart" lookup -- byte-for-byte
-- identical between handleSpawnDummy/handleSpawnBot before this was extracted, differing only in
-- the log-message prefix. Both callers treat a missing root part the same way a missing character
-- is treated ("NoCharacter") since neither dev action has anything meaningful to do with a
-- rootPart-less character.
local function getRootPart(player: Player, logPrefix: string): (BasePart?, string?)
	local character = player.Character
	if not character then
		logger:debug(logPrefix .. " rejected: no character", { player = player.Name })
		return nil, "NoCharacter"
	end

	local rootPartInstance = character:FindFirstChild("HumanoidRootPart")
	if not rootPartInstance or not rootPartInstance:IsA("BasePart") then
		logger:debug(logPrefix .. " rejected: no root part", { player = player.Name })
		return nil, "NoCharacter"
	end
	return rootPartInstance :: BasePart, nil
end

-- Closed-whitelist string-to-enum lookup, unifying the 8 call sites below that used to each hand-
-- write `if typeof(rawX) == "string" then MAP[rawX] else nil`. Rejects both a non-string and a
-- string outside the given map's known keys in one step -- see HITBOX_CATEGORIES' own comment
-- below for why the closed-whitelist behavior (not just a typeof check) matters here.
local function resolveEnum<T>(raw: unknown, map: { [string]: T }): T?
	if typeof(raw) ~= "string" then
		return nil
	end
	return map[raw]
end

local function handleSpawnDummy(player: Player): Types.DevMenuSpawnDummyResult
	logger:debug("SpawnDummy received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SpawnDummy")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local rootPart, rootPartFailureReason = getRootPart(player, "SpawnDummy")
	if not rootPart then
		return { Success = false, Reason = rootPartFailureReason }
	end

	local spawnCFrame = rootPart.CFrame * CFrame.new(0, 0, -Constants.Debug.TrainingDummy.SpawnDistance)

	local model, failureReason = CombatSystem.SpawnTrainingDummy(spawnCFrame)
	if not model then
		logger:warn("SpawnDummy failed", { player = player.Name, reason = failureReason })
		return { Success = false, Reason = failureReason or "SpawnFailed" }
	end

	logger:info("SpawnDummy accepted", { player = player.Name, dummy = model.Name })
	return { Success = true }
end

-- Same shape as handleSpawnDummy above, plus a preset-validation step TrainingBotSystem.lua owns
-- (never trust rawPresetName/rawCustomWeights directly -- see that System's ValidatePresetRequest
-- header for the full trust-boundary reasoning) between the rate-limit check and the character
-- check.
local function handleSpawnBot(
	player: Player,
	rawPresetName: unknown,
	rawCustomWeights: unknown
): Types.DevMenuSpawnBotResult
	logger:debug("SpawnTrainingBot received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SpawnTrainingBot")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local weights, presetName, validationReason =
		TrainingBotSystem.ValidatePresetRequest(rawPresetName, rawCustomWeights)
	if not weights or not presetName then
		logger:debug(
			"SpawnTrainingBot rejected: invalid preset request",
			{ player = player.Name, reason = validationReason }
		)
		return { Success = false, Reason = validationReason or "InvalidRequest" }
	end

	local rootPart, rootPartFailureReason = getRootPart(player, "SpawnTrainingBot")
	if not rootPart then
		return { Success = false, Reason = rootPartFailureReason }
	end

	local spawnCFrame = rootPart.CFrame * CFrame.new(0, 0, -Constants.Debug.TrainingBot.SpawnDistance)

	local model, failureReason = CombatSystem.SpawnTrainingBot(player, spawnCFrame)
	if not model then
		logger:warn("SpawnTrainingBot failed", { player = player.Name, reason = failureReason })
		return { Success = false, Reason = failureReason or "SpawnFailed" }
	end

	TrainingBotSystem.RegisterBot(model, player, presetName, weights, spawnCFrame)

	logger:info("SpawnTrainingBot accepted", { player = player.Name, bot = model.Name, preset = presetName })
	return { Success = true }
end

-- Shared "who is this admin action for" resolution: whichever player the requesting admin
-- currently has locked on (CombatSystem.GetLockOnTarget), falling back to themselves if nothing's
-- locked -- reuses the existing lock-on system as the target picker instead of a new player-select
-- UI (Constants.Debug.DevMenu.RemoteNames' own header explains the reasoning). Never trusts a
-- client-supplied target UserId -- there isn't one; the admin locks a target the same way any
-- player locks one (CapsLock), then the action applies to whoever that resolves to server-side.
local function resolveActionTarget(player: Player): Player
	return CombatSystem.GetLockOnTarget(player) or player
end

-- Closed whitelist for handleSetTargetSpeedMultiplier below -- rejects any number outside the exact
-- preset set BEFORE it ever reaches AdminActionSystem.SetSpeedMultiplier (which re-validates the
-- same set itself; see that function's own header for why both layers check). Same
-- table-from-array idiom HITBOX_CATEGORIES/HITBOX_TIMING_FIELDS below use, just declared up here
-- since this file's earlier handlers need it too.
local SPEED_MULTIPLIER_PRESETS: { [number]: boolean } = {}
for _, preset in ipairs(Constants.Debug.DevMenu.SpeedMultiplierPresets) do
	SPEED_MULTIPLIER_PRESETS[preset] = true
end

-- Resolves an EXPLICIT target Player by UserId, for the "Players" tab's per-row buttons (Teleport-To/
-- Reset-Combat-State) that need to act on a specific roster row rather than whichever player the
-- admin currently has locked on. `rawTargetUserId` is nil for every existing Admin-tab caller (none
-- of which pass one) -- in that case this returns (nil, nil) so the caller falls back to
-- resolveActionTarget's own lock-on-or-self resolution, exactly preserving those callers' existing
-- behavior. A non-nil id that doesn't currently resolve to a live Player (already left, or a bogus
-- number) returns (nil, "NoTarget") instead of silently falling back -- a row button naming a
-- specific player should never silently retarget onto someone else.
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

local function handleSetTargetHealth(player: Player, rawHealth: unknown): Types.DevMenuActionResult
	logger:debug("SetTargetHealth received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "SetTargetHealth")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawHealth) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local target = resolveActionTarget(player)
	local ok = CombatSystem.SetPlayerHealth(target, rawHealth)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetHealth accepted", { player = player.Name, target = target.Name, health = rawHealth })
	return { Success = true }
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

-- Module-local (not per-player) armed state -- see this function's own Constants.lua comment
-- (ShutdownConfirmWindowSeconds/ShutdownDelaySeconds) for the two-press confirmation shape. 0 (not
-- armed) rather than a boolean, so the window itself expires without a separate timer to cancel.
local shutdownArmedUntil: number = 0

local function handleShutdownServer(player: Player): Types.DevMenuActionResult
	logger:debug("ShutdownServer received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ShutdownServer")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local now = os.clock()
	if now >= shutdownArmedUntil then
		shutdownArmedUntil = now + DevMenuConfig.ShutdownConfirmWindowSeconds
		-- Unconditional Warn-level log for the initiating admin's UserId -- this is the one action
		-- where under-logging would be a real problem (see this System's own process reminders).
		logger:warn("ShutdownServer armed", { player = player.Name, userId = player.UserId })
		return { Success = false, Reason = "ConfirmationRequired" }
	end

	shutdownArmedUntil = 0
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

-- Player roster ("Players" tab) -- one entry per Players:GetPlayers() at fetch time. Ping comes
-- straight off Player:GetNetworkPing() (Roblox's own round-trip estimate); Snapshot is whatever
-- CombatSystem.GetCombatState currently returns for that player (nil only for a brand-new join whose
-- own CombatSystem PlayerAdded handler hasn't run yet).
local function buildRosterEntry(target: Player): Types.PlayerRosterEntry
	return {
		UserId = target.UserId,
		Name = target.Name,
		Snapshot = CombatSystem.GetCombatState(target),
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

local function handleResetTargetCombatState(player: Player, rawTargetUserId: unknown): Types.DevMenuActionResult
	logger:debug("ResetTargetCombatState received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ResetTargetCombatState")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	local explicitTarget, explicitFailureReason = resolveOptionalExplicitTarget(rawTargetUserId)
	if explicitFailureReason then
		return { Success = false, Reason = explicitFailureReason }
	end
	local target = explicitTarget or resolveActionTarget(player)

	local ok = CombatSystem.ResetCombatState(target)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("ResetTargetCombatState accepted", { player = player.Name, target = target.Name })
	return { Success = true }
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
	if typeof(rawTargetUserId) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawReason) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if rawExpiresAt ~= nil and typeof(rawExpiresAt) ~= "number" then
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
	if typeof(rawTargetUserId) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawEnabled) ~= "boolean" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	ModerationSystem.MutePlayer(rawTargetUserId, rawEnabled)

	logger:info("MutePlayer accepted", { player = player.Name, targetUserId = rawTargetUserId, enabled = rawEnabled })
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

-- Closed whitelists for the two string-typed hitbox-tuning params below -- unlike a plain
-- typeof(x) ~= "string" check, this ALSO rejects any string outside the exact known set, which
-- matters here specifically because `field` ultimately selects which table KEY gets written on a
-- live Constants.Combat.Weapons stage (HitboxTuning.AdjustField's `if field == "WindupSeconds" ...`
-- branch) -- an unvalidated arbitrary string could otherwise target the wrong branch or, if that
-- module's own guard were ever loosened, an unrelated field entirely. Same reasoning
-- TrainingBotSystem.ValidatePresetRequest already applies to preset names.
local HITBOX_CATEGORIES: { [string]: Types.HitboxStageCategory } =
	{ Basic = "Basic", Heavy = "Heavy", Finisher = "Finisher" }
local HITBOX_TIMING_FIELDS: { [string]: Types.HitboxTimingField } =
	{ WindupSeconds = "WindupSeconds", ActiveSeconds = "ActiveSeconds", RecoverySeconds = "RecoverySeconds" }

-- Same closed-whitelist reasoning as the two above, for the standalone-attack tuning params
-- (handleAdjustStandaloneField/handleResetStandaloneAttack below).
local STANDALONE_ATTACK_NAMES: { [string]: Types.StandaloneAttackName } =
	{ DashPunch = "DashPunch", DashHit = "DashHit" }
local HITBOX_STANDALONE_FIELDS: { [string]: Types.HitboxStandaloneField } = {
	WindupSeconds = "WindupSeconds",
	ActiveSeconds = "ActiveSeconds",
	RecoverySeconds = "RecoverySeconds",
	OffsetForwardStuds = "OffsetForwardStuds",
}

-- Same closed-whitelist reasoning as HITBOX_CATEGORIES/HITBOX_TIMING_FIELDS above, for the flight
-- feel tuner (handleAdjustFlightTuning/handleResetFlightTuning below) -- rejects any string outside
-- FlightTuning.lua's own curated field set before it can be used to pick which Constants.Flight key
-- gets written.
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

local function handleListHitboxStages(player: Player): Types.DevMenuListHitboxStagesResult
	logger:debug("ListHitboxStages received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ListHitboxStages")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	return { Success = true, Stages = HitboxTuning.ListStages() }
end

local function handleAdjustHitboxTiming(
	player: Player,
	rawWeaponId: unknown,
	rawCategory: unknown,
	rawStageIndex: unknown,
	rawField: unknown,
	rawDelta: unknown
): Types.DevMenuHitboxStageResult
	logger:debug("AdjustHitboxTiming received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "AdjustHitboxTiming")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if rawWeaponId ~= "Primary" and rawWeaponId ~= "Secondary" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	local category = resolveEnum(rawCategory, HITBOX_CATEGORIES)
	if not category then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawStageIndex) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	local field = resolveEnum(rawField, HITBOX_TIMING_FIELDS)
	if not field then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawDelta) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local weaponId = rawWeaponId :: Types.WeaponId
	local stage = HitboxTuning.AdjustField(weaponId, category, rawStageIndex, field, rawDelta)
	if not stage then
		return { Success = false, Reason = "InvalidRequest" }
	end

	logger:info("AdjustHitboxTiming accepted", {
		player = player.Name,
		weaponId = weaponId,
		category = category,
		stageIndex = rawStageIndex,
		field = field,
		delta = rawDelta,
	})
	return { Success = true, Stage = stage }
end

local function handleResetHitboxStage(
	player: Player,
	rawWeaponId: unknown,
	rawCategory: unknown,
	rawStageIndex: unknown
): Types.DevMenuHitboxStageResult
	logger:debug("ResetHitboxStage received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ResetHitboxStage")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if rawWeaponId ~= "Primary" and rawWeaponId ~= "Secondary" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	local category = resolveEnum(rawCategory, HITBOX_CATEGORIES)
	if not category then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawStageIndex) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local weaponId = rawWeaponId :: Types.WeaponId
	local stage = HitboxTuning.ResetStage(weaponId, category, rawStageIndex)
	if not stage then
		return { Success = false, Reason = "InvalidRequest" }
	end

	logger:info(
		"ResetHitboxStage accepted",
		{ player = player.Name, weaponId = weaponId, category = category, stageIndex = rawStageIndex }
	)
	return { Success = true, Stage = stage }
end

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
	if typeof(rawDeltaFraction) ~= "number" then
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

local function handleListStandaloneAttacks(player: Player): Types.DevMenuListStandaloneAttacksResult
	logger:debug("ListStandaloneAttacks received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ListStandaloneAttacks")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end

	return { Success = true, Attacks = HitboxTuning.ListStandaloneAttacks() }
end

local function handleAdjustStandaloneField(
	player: Player,
	rawName: unknown,
	rawField: unknown,
	rawDelta: unknown
): Types.DevMenuStandaloneAttackResult
	logger:debug("AdjustStandaloneField received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "AdjustStandaloneField")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	local name = resolveEnum(rawName, STANDALONE_ATTACK_NAMES)
	if not name then
		return { Success = false, Reason = "InvalidRequest" }
	end
	local field = resolveEnum(rawField, HITBOX_STANDALONE_FIELDS)
	if not field then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if typeof(rawDelta) ~= "number" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local attack = HitboxTuning.AdjustStandaloneField(name, field, rawDelta)
	if not attack then
		return { Success = false, Reason = "InvalidRequest" }
	end

	logger:info(
		"AdjustStandaloneField accepted",
		{ player = player.Name, name = name, field = field, delta = rawDelta }
	)
	return { Success = true, Attack = attack }
end

local function handleResetStandaloneAttack(player: Player, rawName: unknown): Types.DevMenuStandaloneAttackResult
	logger:debug("ResetStandaloneAttack received", { player = player.Name, userId = player.UserId })

	local allowed, reason = checkDevMenuPreconditions(player, "ResetStandaloneAttack")
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	local name = resolveEnum(rawName, STANDALONE_ATTACK_NAMES)
	if not name then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local attack = HitboxTuning.ResetStandaloneAttack(name)
	if not attack then
		return { Success = false, Reason = "InvalidRequest" }
	end

	logger:info("ResetStandaloneAttack accepted", { player = player.Name, name = name })
	return { Success = true, Attack = attack }
end

-- Bug report triage ("Reports" tab, DevMenu/init.lua) -- both handlers gate here exactly like
-- every action above, then delegate to BugReportSystem's public API. BugReportSystem itself has no
-- admin-authorization notion of its own; it trusts these two callers the same way CombatSystem
-- trusts DevMenuSystem for SpawnTrainingDummy/SpawnTrainingBot.
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

-- Shared pcall-wrap-and-log-error boilerplate for OnServerInvoke registration, unifying what all 15
-- remotes below used to hand-duplicate in Init(). `name` feeds the error log message; the handler's
-- own first parameter is always the requesting Player (every handler above takes one), reused here
-- purely for the error-log's `player.Name` field, not passed through specially otherwise -- pcall
-- forwards every argument (Player included) straight to `handler` unchanged. On a caught error,
-- returns a same-shaped `{ Success = false, Reason = "InternalError" }` cast to whatever Result type
-- the specific handler declares -- every one of this System's Result types shares that Success/Reason
-- pair (Types.DevMenu*Result), so the same literal fits all of them; the `:: any` bridge is required
-- because `Result` is a generic here and Luau can't otherwise verify a literal table matches an
-- unresolved generic type parameter.
local function wrapHandler<Result, Args...>(name: string, handler: (Player, Args...) -> Result): (Player, Args...) -> Result
	return function(player: Player, ...: Args...): Result
		local ok, resultOrError = pcall(handler, player, ...)
		if not ok then
			logger:error(name .. " handler errored", { player = player.Name, errorMessage = tostring(resultOrError) })
			return ({ Success = false, Reason = "InternalError" } :: any) :: Result
		end
		return resultOrError :: Result
	end
end

function DevMenuSystem.Init(): ()
	local remote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SpawnDummy)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SpawnDummy })
	remote.OnServerInvoke = wrapHandler("SpawnDummy", handleSpawnDummy)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SpawnDummy })

	local spawnBotRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SpawnTrainingBot)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SpawnTrainingBot })
	spawnBotRemote.OnServerInvoke = wrapHandler("SpawnTrainingBot", handleSpawnBot)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SpawnTrainingBot })

	local setHealthRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetHealth)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetHealth })
	setHealthRemote.OnServerInvoke = wrapHandler("SetTargetHealth", handleSetTargetHealth)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetHealth })

	local setGodmodeRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetGodmode)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetGodmode })
	setGodmodeRemote.OnServerInvoke = wrapHandler("SetTargetGodmode", handleSetTargetGodmode)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetGodmode })

	local setFlightRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetFlight)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetFlight })
	setFlightRemote.OnServerInvoke = wrapHandler("SetTargetFlight", handleSetTargetFlight)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetFlight })

	local setFlightCollideRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetFlightCollide)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetFlightCollide })
	setFlightCollideRemote.OnServerInvoke = wrapHandler("SetTargetFlightCollide", handleSetTargetFlightCollide)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetFlightCollide })

	local listHitboxStagesRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ListHitboxStages)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ListHitboxStages })
	listHitboxStagesRemote.OnServerInvoke = wrapHandler("ListHitboxStages", handleListHitboxStages)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ListHitboxStages })

	local adjustHitboxTimingRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.AdjustHitboxTiming)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.AdjustHitboxTiming })
	adjustHitboxTimingRemote.OnServerInvoke = wrapHandler("AdjustHitboxTiming", handleAdjustHitboxTiming)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.AdjustHitboxTiming })

	local resetHitboxStageRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ResetHitboxStage)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ResetHitboxStage })
	resetHitboxStageRemote.OnServerInvoke = wrapHandler("ResetHitboxStage", handleResetHitboxStage)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ResetHitboxStage })

	local listFlightTuningRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ListFlightTuning)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ListFlightTuning })
	listFlightTuningRemote.OnServerInvoke = wrapHandler("ListFlightTuning", handleListFlightTuning)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ListFlightTuning })

	local adjustFlightTuningRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.AdjustFlightTuning)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.AdjustFlightTuning })
	adjustFlightTuningRemote.OnServerInvoke = wrapHandler("AdjustFlightTuning", handleAdjustFlightTuning)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.AdjustFlightTuning })

	local resetFlightTuningRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ResetFlightTuning)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ResetFlightTuning })
	resetFlightTuningRemote.OnServerInvoke = wrapHandler("ResetFlightTuning", handleResetFlightTuning)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ResetFlightTuning })

	local listStandaloneAttacksRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ListStandaloneAttacks)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ListStandaloneAttacks })
	listStandaloneAttacksRemote.OnServerInvoke = wrapHandler("ListStandaloneAttacks", handleListStandaloneAttacks)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ListStandaloneAttacks })

	local adjustStandaloneFieldRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.AdjustStandaloneField)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.AdjustStandaloneField })
	adjustStandaloneFieldRemote.OnServerInvoke = wrapHandler("AdjustStandaloneField", handleAdjustStandaloneField)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.AdjustStandaloneField })

	local resetStandaloneAttackRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ResetStandaloneAttack)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ResetStandaloneAttack })
	resetStandaloneAttackRemote.OnServerInvoke = wrapHandler("ResetStandaloneAttack", handleResetStandaloneAttack)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ResetStandaloneAttack })

	local listBugReportsRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ListBugReports)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ListBugReports })
	listBugReportsRemote.OnServerInvoke = wrapHandler("ListBugReports", handleListBugReports)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ListBugReports })

	local updateBugReportStatusRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.UpdateBugReportStatus)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.UpdateBugReportStatus })
	updateBugReportStatusRemote.OnServerInvoke = wrapHandler("UpdateBugReportStatus", handleUpdateBugReportStatus)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.UpdateBugReportStatus })

	local setFrozenRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetFrozen)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetFrozen })
	setFrozenRemote.OnServerInvoke = wrapHandler("SetTargetFrozen", handleSetTargetFrozen)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetFrozen })

	local setInvisibleRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetInvisible)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetInvisible })
	setInvisibleRemote.OnServerInvoke = wrapHandler("SetTargetInvisible", handleSetTargetInvisible)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetInvisible })

	local setSpeedMultiplierRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetTargetSpeedMultiplier)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetTargetSpeedMultiplier })
	setSpeedMultiplierRemote.OnServerInvoke = wrapHandler("SetTargetSpeedMultiplier", handleSetTargetSpeedMultiplier)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetTargetSpeedMultiplier })

	local teleportToTargetRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.TeleportToTarget)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.TeleportToTarget })
	teleportToTargetRemote.OnServerInvoke = wrapHandler("TeleportToTarget", handleTeleportToTarget)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.TeleportToTarget })

	local bringTargetRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.BringTarget)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.BringTarget })
	bringTargetRemote.OnServerInvoke = wrapHandler("BringTarget", handleBringTarget)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.BringTarget })

	local teleportToCoordinatesRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.TeleportToCoordinates)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.TeleportToCoordinates })
	teleportToCoordinatesRemote.OnServerInvoke = wrapHandler("TeleportToCoordinates", handleTeleportToCoordinates)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.TeleportToCoordinates })

	local forceRespawnTargetRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ForceRespawnTarget)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ForceRespawnTarget })
	forceRespawnTargetRemote.OnServerInvoke = wrapHandler("ForceRespawnTarget", handleForceRespawnTarget)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ForceRespawnTarget })

	local broadcastAnnouncementRemote =
		NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.BroadcastAnnouncement)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.BroadcastAnnouncement })
	broadcastAnnouncementRemote.OnServerInvoke = wrapHandler("BroadcastAnnouncement", handleBroadcastAnnouncement)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.BroadcastAnnouncement })

	local shutdownServerRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ShutdownServer)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ShutdownServer })
	shutdownServerRemote.OnServerInvoke = wrapHandler("ShutdownServer", handleShutdownServer)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ShutdownServer })

	-- RemoteEvent, not RemoteFunction -- broadcast to every client (Client/Announcement/
	-- AnnouncementClient.lua, unconditional for every player, not just admins). Created here (not
	-- inside broadcastAnnouncement) so it exists before any handler could possibly fire it.
	announcementRemote = NetworkBridge.CreateRemoteEvent(DevMenuConfig.RemoteNames.Announcement)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.Announcement })

	local listPlayersRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ListPlayers)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ListPlayers })
	listPlayersRemote.OnServerInvoke = wrapHandler("ListPlayers", handleListPlayers)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ListPlayers })

	local resetCombatStateRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.ResetTargetCombatState)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.ResetTargetCombatState })
	resetCombatStateRemote.OnServerInvoke = wrapHandler("ResetTargetCombatState", handleResetTargetCombatState)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.ResetTargetCombatState })

	local kickPlayerRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.KickPlayer)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.KickPlayer })
	kickPlayerRemote.OnServerInvoke = wrapHandler("KickPlayer", handleKickPlayer)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.KickPlayer })

	local banPlayerRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.BanPlayer)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.BanPlayer })
	banPlayerRemote.OnServerInvoke = wrapHandler("BanPlayer", handleBanPlayer)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.BanPlayer })

	local mutePlayerRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.MutePlayer)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.MutePlayer })
	mutePlayerRemote.OnServerInvoke = wrapHandler("MutePlayer", handleMutePlayer)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.MutePlayer })

	local setSuspectedCheaterRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.SetSuspectedCheater)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.SetSuspectedCheater })
	setSuspectedCheaterRemote.OnServerInvoke = wrapHandler("SetSuspectedCheater", handleSetSuspectedCheater)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.SetSuspectedCheater })

	local getSidebarStatsRemote = NetworkBridge.CreateRemoteFunction(DevMenuConfig.RemoteNames.GetSidebarStats)
	logger:debug("Remote created", { name = DevMenuConfig.RemoteNames.GetSidebarStats })
	getSidebarStatsRemote.OnServerInvoke = wrapHandler("GetSidebarStats", handleGetSidebarStats)
	logger:debug("Handler connected", { remote = DevMenuConfig.RemoteNames.GetSidebarStats })

	Players.PlayerRemoving:Connect(function(player: Player)
		rateLimiter:Clear(player)
	end)

	logger:info("DevMenuSystem.Init() complete")
end

return DevMenuSystem :: Types.SystemModule
