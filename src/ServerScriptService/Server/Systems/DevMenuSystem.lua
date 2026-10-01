--!strict
--[[
	DevMenuSystem.lua

	Owns: server-side authorization and request handling for the admin panel (Client/UI/Screens/
	DevTools/DevMenu) -- Constants.Debug.DevMenu for tunables and remote names, Server/Config/
	AdminConfig.lua for the whitelist itself. Every request re-checks the whitelist (checkPreconditions
	-> Server/Network/AdminGate.Check), regardless of what the client believes; a rejection from any
	handler here is the authorization answer, which is why the panel's first GetOverview doubles as its
	"am I an admin" probe. NOT Studio-gated: admin tooling is meant to work in live servers, and safety
	comes from the whitelist plus this re-check, never from being hidden.

	TARGETING (rebuilt 2026-09-29). Every action that acts ON a player takes that player's UserId as
	its LAST argument, nil meaning the calling admin (resolveTarget). The panel's roster selection is
	that UserId. Before the rebuild this System resolved every Admin-tab action through a lock-on lookup
	that went with the old combat system and had been hard-wired to "the caller" since -- so Godmode,
	Freeze, Bring and the rest could only ever be applied to the admin themselves, and "Teleport to
	target" teleported you to yourself.

	THE READ SURFACE is two remotes the open panel polls: GetOverview (every player's roster row plus
	the server's own status, one round trip) and InspectPlayer (everything about one player). Both are
	built only from in-memory state and replicated Attributes -- no DataStore call -- and both run on
	their own rate-limit bucket (pollLimiter), so a panel left open never eats the budget an admin's
	button presses draw from. See Shared/Admin/AdminTypes.lua for both shapes.

	Does not own: what an action DOES. AdminActionSystem owns the override flags (Godmode/Flying/
	FlightCollide/Frozen/Invisible/SpeedMultiplier) and teleport; ModerationSystem owns Kick/Ban/Mute/
	Flag/Unban; PlayerDataSystem owns the profile wipe; MeridianSystem the XP grant; BloodlineSystem the
	rerolls; EmoteUnlockService the emote roll; QiSystem the Qi restore; DebugDummySystem,
	TrainingBotSystem and ResourceGatheringSystem the world spawns; BugReportSystem the triage;
	FlightTuning the live flight numbers; VersionWatchSystem the version check. This System decides
	whether a request may reach them and translates the request/response shape. The two kick-everyone
	actions (Shutdown, Instant Restart) are the exception and are done here, since nothing but an
	admin's press ever triggers either. RemoteFunctions throughout, since the client needs an immediate
	answer -- Announcement is the one RemoteEvent, a genuine broadcast to every client.

	Retired with the old combat system and never recreated: SetTargetHealth (a free-typed health
	setter) and ResetTargetCombatState. RestoreTarget is deliberately not the first of those back: it
	tops a target off, it does not set an arbitrary value.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local AdminActionSystem = require(script.Parent.AdminActionSystem)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)
local BloodlineManager = require(script.Parent.Parent.Managers.BloodlineManager)
local BloodlineSystem = require(script.Parent.BloodlineSystem)
local BountySystem = require(script.Parent.BountySystem)
local BugReportSystem = require(script.Parent.BugReportSystem)
local DebugDummySystem = require(script.Parent.DebugDummySystem)
local DefenseSystem = require(script.Parent.Parent.Combat.Defense.DefenseSystem)
local EmoteUnlockService = require(script.Parent.EmoteUnlockService)
local EngagementSystem = require(script.Parent.Parent.Combat.Engagement.EngagementSystem)
local FlightTuning = require(script.Parent.Parent.DevMenu.FlightTuning)
local HitboxEngine = require(script.Parent.Parent.Combat.HitboxEngine.HitboxEngine)
local MeridianSystem = require(script.Parent.MeridianSystem)
local ModerationSystem = require(script.Parent.ModerationSystem)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local QiSystem = require(script.Parent.QiSystem)
local ResourceGatheringSystem = require(script.Parent.ResourceGatheringSystem)
local ServerFrameStats = require(script.Parent.Parent.Diagnostics.ServerFrameStats)
local TierSystem = require(script.Parent.TierSystem)
local TrainingBotSystem = require(script.Parent.Parent.Combat.TrainingBot.TrainingBotSystem)
local VersionWatchSystem = require(script.Parent.VersionWatchSystem)

local DevMenuSystem = {}

local logger = Logger.scope("DevMenuSystem")

local DevMenuConfig = Constants.Debug.DevMenu
local Attributes = Constants.Attributes

type ActionResult = Types.DevMenuActionResult

-- One bucket for every action, and a second for the two polling reads -- see
-- Constants.Debug.DevMenu.PollRemoteCallsPerSecond on why the polls earn their own.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)
local pollLimiter = RateLimiter.New(DevMenuConfig.PollRemoteCallsPerSecond)

local function checkPreconditions(player: Player, actionName: string): (boolean, string?)
	return AdminGate.Check(player, actionName, rateLimiter)
end

local function refuse(reason: string?): any
	return { Success = false, Reason = reason or "InternalError" }
end

-- Studs in front of the requesting admin that a spawned node lands -- its own number rather than the
-- dummy's SpawnDistance, which is named for (and tuned with) the dummy.
local RESOURCE_NODE_SPAWN_DISTANCE = 6

-- Targets -----------------------------------------------------------------------------------------

-- The player an action is FOR: nil means the calling admin, a number means that live player in this
-- server. A number that resolves to nobody is refused rather than falling back to the caller -- a
-- press aimed at a player who has just left must never land on the admin instead.
local function resolveTarget(player: Player, rawTargetUserId: unknown): (Player?, string?)
	if rawTargetUserId == nil then
		return player, nil
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

-- For the actions that must name someone explicitly (Kick, Reset): no nil-means-me fallback at all.
local function resolveExplicitTarget(rawTargetUserId: unknown): (Player?, string?)
	if typeof(rawTargetUserId) ~= "number" then
		return nil, "InvalidRequest"
	end
	local target = Players:GetPlayerByUserId(rawTargetUserId)
	if not target then
		return nil, "NoTarget"
	end
	return target, nil
end

-- Ban/Mute/Unban/LookupBan work on OFFLINE UserIds, so they validate the id itself: a real Roblox
-- UserId is a positive integer under 2^53. NaN fails `> 0`.
local function isPlausibleUserId(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	return value > 0 and value < 2 ^ 53 and value == math.floor(value)
end

local function getRootPart(player: Player): (BasePart?, string?)
	local character = player.Character
	if not character then
		return nil, "NoCharacter"
	end
	local rootPart = CharacterUtil.RootOf(character)
	if not rootPart then
		return nil, "NoCharacter"
	end
	return rootPart, nil
end

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

-- Closed-whitelist string-to-value lookup: rejects a non-string and a string outside the map's keys.
local function resolveEnum<T>(raw: unknown, map: { [string]: T }): T?
	if typeof(raw) ~= "string" then
		return nil
	end
	return map[raw]
end

-- Read surface ------------------------------------------------------------------------------------

local function attributeOn(humanoid: Humanoid?, name: string): boolean
	return humanoid ~= nil and humanoid:GetAttribute(name) == true
end

local function speedMultiplierOf(humanoid: Humanoid?): number
	local value = if humanoid then humanoid:GetAttribute(Attributes.SpeedMultiplier) else nil
	return if typeof(value) == "number" then value else 1
end

local function buildRosterEntry(requester: Player, target: Player): AdminTypes.RosterEntry
	local profile = PlayerDataSystem.GetProfile(target)
	local character = target.Character
	local humanoid = if character then CharacterUtil.HumanoidOf(character) else nil
	local alive = humanoid ~= nil and humanoid.Health > 0
	return {
		UserId = target.UserId,
		Name = target.Name,
		DisplayName = target.DisplayName,
		CharacterName = if profile then profile.displayName else nil,
		IsRequester = target == requester,
		Tier = if profile then profile.tier else 1,
		PingMs = target:GetNetworkPing() * 1000,
		Alive = alive,
		HealthFraction = if humanoid
				and alive
				and humanoid.MaxHealth > 0
			then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
			else 0,
		InCombat = EngagementSystem.IsInCombat(target),
		Godmode = attributeOn(humanoid, Attributes.Godmode),
		Flying = attributeOn(humanoid, Attributes.Flying),
		Frozen = attributeOn(humanoid, Attributes.Frozen),
		Invisible = attributeOn(humanoid, Attributes.Invisible),
		SpeedMultiplier = speedMultiplierOf(humanoid),
		Muted = ModerationSystem.IsMuted(target.UserId),
		Flagged = ModerationSystem.IsSuspectedCheater(target.UserId),
		Marked = BountySystem.IsMarked(target),
	}
end

local function numberAttribute(name: string): number?
	local value = ReplicatedStorage:GetAttribute(name)
	return if typeof(value) == "number" then value else nil
end

local function buildServerOverview(): AdminTypes.ServerOverview
	local bootVersion, latestVersion = VersionWatchSystem.GetVersionInfo()
	return {
		UptimeSeconds = Workspace.DistributedGameTime,
		PlayerCount = #Players:GetPlayers(),
		MaxPlayers = Players.MaxPlayers,
		ServerFps = numberAttribute(ServerFrameStats.Attributes.Fps),
		WorstFrameMs = numberAttribute(ServerFrameStats.Attributes.WorstFrameMs),
		MemoryMb = Stats:GetTotalMemoryUsageMb(),
		PlaceVersion = bootVersion,
		LatestPlaceVersion = latestVersion,
		JobId = game.JobId,
		IsStudio = RunService:IsStudio(),
		OpenReports = BugReportSystem.GetOpenCount(),
		FlaggedCount = ModerationSystem.GetSuspectedCheaterCount(),
		EngagedCount = EngagementSystem.TaggedCount(),
		HitboxVolumes = HitboxEngine.IsDebugVolumesEnabled(),
		DummyGuard = DebugDummySystem.IsGuardEnabled(),
		DummyCount = DebugDummySystem.ActiveCount(),
		BotCount = TrainingBotSystem.ActiveCount(),
	}
end

-- Polled. Also the panel's authorization probe -- see this file's header.
local function handleGetOverview(player: Player): AdminTypes.OverviewResult
	local allowed, reason = AdminGate.Check(player, "GetOverview", pollLimiter)
	if not allowed then
		return refuse(reason)
	end

	local roster: { AdminTypes.RosterEntry } = {}
	for _, target in Players:GetPlayers() do
		table.insert(roster, buildRosterEntry(player, target))
	end
	return { Success = true, Server = buildServerOverview(), Roster = roster }
end

local function buildInspection(requester: Player, target: Player): AdminTypes.Inspection
	local profile = PlayerDataSystem.GetProfile(target)
	local character = target.Character
	local humanoid = if character then CharacterUtil.HumanoidOf(character) else nil
	local rootPart = if character then CharacterUtil.RootOf(character) else nil
	local alive = humanoid ~= nil and humanoid.Health > 0

	local tier = if profile then profile.tier else 1
	local floorXp, nextXp = TierSystem.GetTierWindow(tier)

	local bloodlines: { AdminTypes.BloodlineLine } = {}
	if profile then
		for _, bloodlineId in profile.bloodlineIds do
			local definition = BloodlineManager.Get(bloodlineId)
			table.insert(bloodlines, {
				Id = bloodlineId,
				Name = if definition then definition.DisplayName else bloodlineId,
				Stage = profile.bloodlineStageProgress[bloodlineId] or 0,
			})
		end
	end

	local equippedArtCount = 0
	if profile then
		for _ in profile.equippedArts do
			equippedArtCount += 1
		end
	end

	local guard, maxGuard = nil, nil
	local defenseState: string? = nil
	if character then
		guard, maxGuard = DefenseSystem.GetGuard(character)
		defenseState = DefenseSystem.GetState(character)
	end

	return {
		UserId = target.UserId,
		Name = target.Name,
		DisplayName = target.DisplayName,
		AccountAgeDays = target.AccountAge,
		IsRequester = target == requester,
		PingMs = target:GetNetworkPing() * 1000,

		ProfileLoaded = profile ~= nil,
		CharacterName = if profile then profile.displayName else nil,
		RaceId = if profile then profile.raceId else nil,
		Faction = if profile then profile.faction else nil,
		Tier = tier,
		TierName = TierSystem.GetTierName(tier),
		MeridianXP = if profile then profile.meridianXp else 0,
		TierFloorXP = floorXp,
		TierNextXP = nextXp,
		Bloodlines = bloodlines,
		BloodlineRerolls = if profile then profile.bloodlineRerolls else 0,
		Corruption = if profile then profile.corruption else 0,
		QiDeviationRisk = if profile then profile.qiDeviationRisk else 0,
		EquippedArtCount = equippedArtCount,

		Alive = alive,
		Health = if humanoid and alive then humanoid.Health else 0,
		MaxHealth = if humanoid then humanoid.MaxHealth else 0,
		Qi = QiSystem.GetQi(target),
		MaxQi = QiSystem.GetMaxQi(target),
		Guard = guard,
		MaxGuard = maxGuard,
		DefenseState = defenseState,
		Engagement = EngagementSystem.GetEngagement(target),
		KillStreak = BountySystem.GetKillStreak(target),
		Marked = BountySystem.IsMarked(target),

		Position = if rootPart then rootPart.Position else nil,
		Godmode = attributeOn(humanoid, Attributes.Godmode),
		Flying = attributeOn(humanoid, Attributes.Flying),
		FlyCollide = attributeOn(humanoid, Attributes.FlyCollide),
		Frozen = attributeOn(humanoid, Attributes.Frozen),
		Invisible = attributeOn(humanoid, Attributes.Invisible),
		SpeedMultiplier = speedMultiplierOf(humanoid),
		Muted = ModerationSystem.IsMuted(target.UserId),
		Flagged = ModerationSystem.IsSuspectedCheater(target.UserId),
	}
end

-- Polled while a player is selected.
local function handleInspectPlayer(player: Player, rawTargetUserId: unknown): AdminTypes.InspectResult
	local allowed, reason = AdminGate.Check(player, "InspectPlayer", pollLimiter)
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	return { Success = true, Inspection = buildInspection(player, target) }
end

-- Overrides on the selected player ----------------------------------------------------------------

-- The five on/off overrides share one shape: gate, validate the boolean, resolve the target, apply.
-- `apply` is the AdminActionSystem setter; `failure` is what its false means for that override
-- (Flying and Collide need a live body, the persistent ones only need the player).
local function overrideHandler(
	actionName: string,
	apply: (Player, boolean) -> boolean,
	failure: string
): (Player, unknown, unknown) -> ActionResult
	return function(player: Player, rawEnabled: unknown, rawTargetUserId: unknown): ActionResult
		local allowed, reason = checkPreconditions(player, actionName)
		if not allowed then
			return refuse(reason)
		end
		if typeof(rawEnabled) ~= "boolean" then
			return refuse("InvalidRequest")
		end
		local target, targetReason = resolveTarget(player, rawTargetUserId)
		if not target then
			return refuse(targetReason)
		end
		if not apply(target, rawEnabled) then
			return refuse(failure)
		end
		logger:info(`{actionName} accepted`, { player = player.Name, target = target.Name, enabled = rawEnabled })
		return { Success = true }
	end
end

local handleSetTargetGodmode = overrideHandler("SetTargetGodmode", AdminActionSystem.SetGodmode, "NoTarget")
local handleSetTargetFlight = overrideHandler("SetTargetFlight", AdminActionSystem.SetFlying, "NoCharacter")
local handleSetTargetFlightCollide =
	overrideHandler("SetTargetFlightCollide", AdminActionSystem.SetFlightCollide, "NoCharacter")
local handleSetTargetFrozen = overrideHandler("SetTargetFrozen", AdminActionSystem.SetFrozen, "NoTarget")
local handleSetTargetInvisible = overrideHandler("SetTargetInvisible", AdminActionSystem.SetInvisible, "NoTarget")

-- Closed whitelist, re-validated by AdminActionSystem.SetSpeedMultiplier itself.
local SPEED_MULTIPLIER_PRESETS: { [number]: boolean } = {}
for _, preset in DevMenuConfig.SpeedMultiplierPresets do
	SPEED_MULTIPLIER_PRESETS[preset] = true
end

local function handleSetTargetSpeedMultiplier(
	player: Player,
	rawMultiplier: unknown,
	rawTargetUserId: unknown
): ActionResult
	local allowed, reason = checkPreconditions(player, "SetTargetSpeedMultiplier")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawMultiplier) ~= "number" or not SPEED_MULTIPLIER_PRESETS[rawMultiplier] then
		return refuse("InvalidRequest")
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	if not AdminActionSystem.SetSpeedMultiplier(target, rawMultiplier) then
		return refuse("NoTarget")
	end
	logger:info("SetTargetSpeedMultiplier accepted", {
		player = player.Name,
		target = target.Name,
		multiplier = rawMultiplier,
	})
	return { Success = true }
end

-- Movement ----------------------------------------------------------------------------------------

-- The admin goes to the target.
local function handleTeleportToTarget(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "TeleportToTarget")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	if target == player then
		return refuse("SelfTarget")
	end
	local targetRoot, rootReason = getRootPart(target)
	if not targetRoot then
		return refuse(rootReason)
	end
	if not AdminActionSystem.TeleportToPosition(player, targetRoot.Position) then
		return refuse("NoCharacter")
	end
	logger:info("TeleportToTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

-- The target comes to the admin.
local function handleBringTarget(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "BringTarget")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	if target == player then
		return refuse("SelfTarget")
	end
	local adminRoot, rootReason = getRootPart(player)
	if not adminRoot then
		return refuse(rootReason)
	end
	-- A few studs in front of the admin, not inside them.
	local destination = (adminRoot.CFrame * CFrame.new(0, 0, -4)).Position
	if not AdminActionSystem.TeleportToPosition(target, destination) then
		return refuse("NoTarget")
	end
	logger:info("BringTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

-- Moves the calling admin. No target: typed coordinates are already the most explicit request there is.
local function handleTeleportToCoordinates(player: Player, rawX: unknown, rawY: unknown, rawZ: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "TeleportToCoordinates")
	if not allowed then
		return refuse(reason)
	end
	-- Finite only: a NaN or infinite coordinate is a character dropped out of the world. Checked one by
	-- one rather than by iterating { rawX, rawY, rawZ }, which would silently skip a nil component.
	local function finite(component: unknown): boolean
		return typeof(component) == "number" and component == component and math.abs(component) ~= math.huge
	end
	if not (finite(rawX) and finite(rawY) and finite(rawZ)) then
		return refuse("InvalidRequest")
	end
	local position = Vector3.new(rawX :: number, rawY :: number, rawZ :: number)
	if not AdminActionSystem.TeleportToPosition(player, position) then
		return refuse("NoCharacter")
	end
	logger:info("TeleportToCoordinates accepted", { player = player.Name, position = tostring(position) })
	return { Success = true }
end

local function handleForceRespawnTarget(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "ForceRespawnTarget")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	target:LoadCharacter()
	logger:info("ForceRespawnTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

-- Vitals ------------------------------------------------------------------------------------------

-- Full Health and full Qi. Needs a living body: restoring a corpse is a respawn, which has its own button.
local function handleRestoreTarget(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "RestoreTarget")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	local _, humanoid = CharacterUtil.LiveRig(target)
	if not humanoid or humanoid.Health <= 0 then
		return refuse("NoCharacter")
	end
	humanoid.Health = humanoid.MaxHealth
	local maxQi = QiSystem.GetMaxQi(target)
	if maxQi > 0 then
		QiSystem.Restore(target, maxQi)
	end
	logger:info("RestoreTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

-- Health to zero through the ordinary death path -- see the remote's own comment in DebugConstants.
local function handleKillTarget(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "KillTarget")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	local _, humanoid = CharacterUtil.LiveRig(target)
	if not humanoid or humanoid.Health <= 0 then
		return refuse("NoCharacter")
	end
	humanoid.Health = 0
	logger:warn("KillTarget accepted", { player = player.Name, target = target.Name })
	return { Success = true }
end

-- Grants ------------------------------------------------------------------------------------------

type XpGrant = { Key: string, Amount: number?, Label: string }
local XP_GRANTS: { [string]: XpGrant } = {}
for _, grant in DevMenuConfig.XpGrants :: { XpGrant } do
	XP_GRANTS[grant.Key] = grant
end

local function handleGrantMeridianXP(
	player: Player,
	rawKey: unknown,
	rawTargetUserId: unknown
): AdminTypes.GrantXPResult
	local allowed, reason = checkPreconditions(player, "GrantMeridianXP")
	if not allowed then
		return refuse(reason)
	end
	local grant = resolveEnum(rawKey, XP_GRANTS)
	if not grant then
		return refuse("InvalidRequest")
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end

	local amount = grant.Amount
	if amount == nil then
		-- "NextTier": exactly the gap to the next threshold.
		local _, nextXp = TierSystem.GetTierWindow(TierSystem.GetTier(target))
		if nextXp == nil then
			return refuse("MaxTier")
		end
		amount = math.max(1, nextXp - MeridianSystem.GetMeridianXP(target))
	end

	if not MeridianSystem.AwardMeridianXP(target, amount :: number, "AdminGrant") then
		return refuse("NotLoaded")
	end
	logger:info("GrantMeridianXP accepted", { player = player.Name, target = target.Name, amount = amount })
	return {
		Success = true,
		Granted = amount,
		Total = MeridianSystem.GetMeridianXP(target),
		Tier = TierSystem.GetTier(target),
	}
end

-- The amount is fixed by BloodlineConstants rather than sent by the client: there is no case where an
-- admin wants a specific odd number of rerolls rather than "some more".
local function handleGrantBloodlineRerolls(player: Player, rawTargetUserId: unknown): Types.DevMenuGrantRerollsResult
	local allowed, reason = checkPreconditions(player, "GrantBloodlineRerolls")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	local total, refusal = BloodlineSystem.GrantRerolls(target, BloodlineConstants.DevGrantRerollAmount)
	if not total then
		return refuse(refusal)
	end
	logger:info("GrantBloodlineRerolls accepted", { player = player.Name, target = target.Name, total = total })
	return { Success = true, RerollsRemaining = total }
end

-- Always the "RareEmotes" pool: this is a test trigger for the roll path, not a general "roll any
-- pool" remote.
local function handleRollEmote(player: Player, rawTargetUserId: unknown): Types.DevMenuRollEmoteResult
	local allowed, reason = checkPreconditions(player, "RollEmote")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveTarget(player, rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	local granted, emoteId, rollReason = EmoteUnlockService.RollEmote(target, "RareEmotes", {
		Type = "Roll",
		Pool = "RareEmotes",
	})
	if not granted then
		return refuse(rollReason or "RollFailed")
	end
	logger:info("RollEmote accepted", { player = player.Name, target = target.Name, emoteId = emoteId })
	return { Success = true, EmoteId = emoteId }
end

-- Moderation --------------------------------------------------------------------------------------

type BanDuration = { Key: string, Seconds: number?, Label: string }
local BAN_DURATIONS: { [string]: BanDuration } = {}
for _, duration in DevMenuConfig.BanDurations :: { BanDuration } do
	BAN_DURATIONS[duration.Key] = duration
end

local function handleKickPlayer(player: Player, rawTargetUserId: unknown, rawReason: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "KickPlayer")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawReason) ~= "string" then
		return refuse("InvalidRequest")
	end
	local target, targetReason = resolveExplicitTarget(rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	if target == player then
		return refuse("SelfTarget")
	end
	local kickReason = trim(rawReason)
	if kickReason == "" then
		kickReason = "Kicked by an administrator."
	end
	ModerationSystem.KickPlayer(target, kickReason)
	logger:warn("KickPlayer accepted", {
		player = player.Name,
		targetUserId = target.UserId,
		target = target.Name,
		reason = kickReason,
	})
	return { Success = true }
end

-- (userId, reason, durationKey). Works on an offline UserId; kicks the target at once if online.
local function handleBanPlayer(
	player: Player,
	rawTargetUserId: unknown,
	rawReason: unknown,
	rawDurationKey: unknown
): ActionResult
	local allowed, reason = checkPreconditions(player, "BanPlayer")
	if not allowed then
		return refuse(reason)
	end
	if not isPlausibleUserId(rawTargetUserId) or typeof(rawReason) ~= "string" then
		return refuse("InvalidRequest")
	end
	local duration = resolveEnum(rawDurationKey, BAN_DURATIONS)
	if not duration then
		return refuse("InvalidRequest")
	end
	local targetUserId = rawTargetUserId :: number
	if targetUserId == player.UserId then
		return refuse("SelfTarget")
	end

	local banReason = trim(rawReason)
	if banReason == "" then
		banReason = "Banned by an administrator."
	end
	-- On the SERVER's clock -- see BanDurations' own comment.
	local expiresAt = if duration.Seconds then os.time() + duration.Seconds else nil

	if not ModerationSystem.BanPlayer(targetUserId, player.UserId, banReason, expiresAt) then
		return refuse("StorageError")
	end
	-- BanPlayer only writes the record; kick now if they are here, rather than at their next join.
	local onlineTarget = Players:GetPlayerByUserId(targetUserId)
	if onlineTarget then
		onlineTarget:Kick(`You are banned: {banReason}`)
	end

	logger:warn("BanPlayer accepted", {
		player = player.Name,
		targetUserId = targetUserId,
		reason = banReason,
		duration = duration.Key,
		expiresAt = expiresAt,
	})
	return { Success = true }
end

local function handleUnbanPlayer(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "UnbanPlayer")
	if not allowed then
		return refuse(reason)
	end
	if not isPlausibleUserId(rawTargetUserId) then
		return refuse("InvalidRequest")
	end
	if not ModerationSystem.UnbanPlayer(rawTargetUserId :: number) then
		return refuse("StorageError")
	end
	logger:warn("UnbanPlayer accepted", { player = player.Name, targetUserId = rawTargetUserId })
	return { Success = true }
end

local function handleLookupBan(player: Player, rawTargetUserId: unknown): AdminTypes.BanLookupResult
	local allowed, reason = checkPreconditions(player, "LookupBan")
	if not allowed then
		return refuse(reason)
	end
	if not isPlausibleUserId(rawTargetUserId) then
		return refuse("InvalidRequest")
	end
	local targetUserId = rawTargetUserId :: number
	local banned, record, failReason = ModerationSystem.IsBanned(targetUserId)
	if failReason then
		return refuse(failReason)
	end
	return {
		Success = true,
		Lookup = {
			UserId = targetUserId,
			Banned = banned,
			BanReason = if record then record.Reason else nil,
			BannedAt = if record then record.BannedAt else nil,
			BannedByUserId = if record then record.BannedByUserId else nil,
			ExpiresAt = if record then record.ExpiresAt else nil,
			Online = Players:GetPlayerByUserId(targetUserId) ~= nil,
		},
	}
end

local function handleMutePlayer(player: Player, rawTargetUserId: unknown, rawEnabled: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "MutePlayer")
	if not allowed then
		return refuse(reason)
	end
	if not isPlausibleUserId(rawTargetUserId) or typeof(rawEnabled) ~= "boolean" then
		return refuse("InvalidRequest")
	end
	ModerationSystem.MutePlayer(rawTargetUserId :: number, rawEnabled)
	logger:info("MutePlayer accepted", { player = player.Name, targetUserId = rawTargetUserId, enabled = rawEnabled })
	return { Success = true }
end

-- Reversible manual cheater flag. An empty reason falls back to a default rather than rejecting --
-- flagging is the low-severity, reversible action.
local function handleSetSuspectedCheater(
	player: Player,
	rawTargetUserId: unknown,
	rawEnabled: unknown,
	rawReason: unknown
): ActionResult
	local allowed, reason = checkPreconditions(player, "SetSuspectedCheater")
	if not allowed then
		return refuse(reason)
	end
	if not isPlausibleUserId(rawTargetUserId) or typeof(rawEnabled) ~= "boolean" or typeof(rawReason) ~= "string" then
		return refuse("InvalidRequest")
	end
	local targetUserId = rawTargetUserId :: number
	local ok: boolean
	if rawEnabled then
		local flagReason = trim(rawReason :: string)
		if flagReason == "" then
			flagReason = "Flagged by an administrator."
		end
		ok = ModerationSystem.FlagSuspectedCheater(targetUserId, player.UserId, flagReason, "Manual")
	else
		ok = ModerationSystem.UnflagSuspectedCheater(targetUserId)
	end
	if not ok then
		return refuse("StorageError")
	end
	logger:info(
		"SetSuspectedCheater accepted",
		{ player = player.Name, targetUserId = targetUserId, enabled = rawEnabled }
	)
	return { Success = true }
end

-- Wipes a target's SAVED progression data back to a fresh profile. Irreversible, so explicit-UserId
-- only (never the nil-means-me fallback) and online only -- see ResetTargetPlayerData's own comment.
-- An admin MAY wipe themselves: resetting your own test profile is the commonest use.
local function handleResetTargetPlayerData(player: Player, rawTargetUserId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "ResetTargetPlayerData")
	if not allowed then
		return refuse(reason)
	end
	local target, targetReason = resolveExplicitTarget(rawTargetUserId)
	if not target then
		return refuse(targetReason)
	end
	if not PlayerDataSystem.ResetProfile(target) then
		return refuse("NotLoaded")
	end
	logger:warn("ResetTargetPlayerData accepted", {
		player = player.Name,
		targetUserId = target.UserId,
		target = target.Name,
	})
	return { Success = true }
end

-- World: sparring ----------------------------------------------------------------------------------

local function handleSpawnDebugDummy(player: Player): ActionResult
	local allowed, reason = checkPreconditions(player, "SpawnDebugDummy")
	if not allowed then
		return refuse(reason)
	end
	local rootPart, rootReason = getRootPart(player)
	if not rootPart then
		return refuse(rootReason)
	end
	local spawnCFrame = rootPart.CFrame * CFrame.new(0, 0, -Constants.Debug.TrainingDummy.SpawnDistance)
	local model, spawnFailureReason = DebugDummySystem.Spawn(spawnCFrame)
	if not model then
		return refuse(spawnFailureReason or "SpawnFailed")
	end
	logger:info("SpawnDebugDummy accepted", { player = player.Name })
	return { Success = true }
end

local function handleDespawnAllDebugDummies(player: Player): ActionResult
	local allowed, reason = checkPreconditions(player, "DespawnAllDebugDummies")
	if not allowed then
		return refuse(reason)
	end
	local count = DebugDummySystem.DespawnAll()
	logger:info("DespawnAllDebugDummies accepted", { player = player.Name, count = count })
	return { Success = true }
end

-- Server-wide: every active (and future) dummy. Returns what actually took effect.
local function handleSetDummyGuard(player: Player, rawEnabled: unknown): Types.DevMenuDebugDummyStateResult
	local allowed, reason = checkPreconditions(player, "SetDummyGuard")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawEnabled) ~= "boolean" then
		return refuse("InvalidRequest")
	end
	local guardEnabled = DebugDummySystem.SetGuard(rawEnabled)
	logger:info("SetDummyGuard accepted", { player = player.Name, enabled = guardEnabled })
	return { Success = true, GuardEnabled = guardEnabled, ActiveCount = DebugDummySystem.ActiveCount() }
end

-- Read by the Move Editor's test bench on open; the panel reads the same facts off the overview.
local function handleGetDebugDummyState(player: Player): Types.DevMenuDebugDummyStateResult
	local allowed, reason = checkPreconditions(player, "GetDebugDummyState")
	if not allowed then
		return refuse(reason)
	end
	return {
		Success = true,
		GuardEnabled = DebugDummySystem.IsGuardEnabled(),
		ActiveCount = DebugDummySystem.ActiveCount(),
	}
end

-- Style, difficulty and weapon are CLIENT-SENT, so each is checked against its closed list and refused
-- outright if unknown rather than quietly defaulted. Weapon nil or DefaultWeaponChoice means the
-- roster's default.
local function handleSpawnTrainingBot(
	player: Player,
	rawStyle: unknown,
	rawDifficulty: unknown,
	rawWeapon: unknown
): Types.DevMenuSpawnBotResult
	local allowed, reason = checkPreconditions(player, "SpawnTrainingBot")
	if not allowed then
		return refuse(reason)
	end
	if not TrainingBotConstants.IsStyle(rawStyle) or not TrainingBotConstants.IsDifficulty(rawDifficulty) then
		return refuse("InvalidPreset")
	end
	local weaponId: string? = nil
	if rawWeapon ~= nil and rawWeapon ~= TrainingBotConstants.DefaultWeaponChoice then
		if typeof(rawWeapon) ~= "string" or not WeaponRoster.Has(rawWeapon) then
			return refuse("InvalidWeapon")
		end
		weaponId = rawWeapon
	end

	local rootPart, rootReason = getRootPart(player)
	if not rootPart then
		return refuse(rootReason)
	end
	local spawnPosition = (rootPart.CFrame * CFrame.new(0, 0, -TrainingBotConstants.Config.SpawnDistance)).Position
	local facing = Vector3.new(rootPart.Position.X, spawnPosition.Y, rootPart.Position.Z)
	local model, spawnFailureReason = TrainingBotSystem.Spawn(
		CFrame.lookAt(spawnPosition, facing),
		rawStyle :: string,
		rawDifficulty :: string,
		player,
		weaponId
	)
	if not model then
		return refuse(spawnFailureReason or "SpawnFailed")
	end
	logger:info("SpawnTrainingBot accepted", {
		player = player.Name,
		style = rawStyle,
		difficulty = rawDifficulty,
		weapon = weaponId,
	})
	return { Success = true, ActiveCount = TrainingBotSystem.ActiveCount() }
end

local function handleDespawnTrainingBots(player: Player): Types.DevMenuSpawnBotResult
	local allowed, reason = checkPreconditions(player, "DespawnTrainingBots")
	if not allowed then
		return refuse(reason)
	end
	local count = TrainingBotSystem.DespawnAll()
	logger:info("DespawnTrainingBots accepted", { player = player.Name, count = count })
	return { Success = true, ActiveCount = 0 }
end

-- SERVER-WIDE AND VISIBLE TO EVERYONE: the engine draws its volumes as real replicated Parts.
local function handleGetHitboxDebug(player: Player): Types.DevMenuHitboxDebugResult
	local allowed, reason = checkPreconditions(player, "GetHitboxDebug")
	if not allowed then
		return refuse(reason)
	end
	return { Success = true, Enabled = HitboxEngine.IsDebugVolumesEnabled() }
end

local function handleSetHitboxDebug(player: Player, rawEnabled: unknown): Types.DevMenuHitboxDebugResult
	local allowed, reason = checkPreconditions(player, "SetHitboxDebug")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawEnabled) ~= "boolean" then
		return refuse("InvalidRequest")
	end
	HitboxEngine.SetDebugVolumesEnabled(rawEnabled)
	logger:info("SetHitboxDebug accepted", { player = player.Name, enabled = rawEnabled })
	return { Success = true, Enabled = HitboxEngine.IsDebugVolumesEnabled() }
end

-- World: fuel -------------------------------------------------------------------------------------

local function spawnNodeHandler(actionName: string, kind: "Coal" | "Water"): (Player) -> ActionResult
	return function(player: Player): ActionResult
		local allowed, reason = checkPreconditions(player, actionName)
		if not allowed then
			return refuse(reason)
		end
		local rootPart, rootReason = getRootPart(player)
		if not rootPart then
			return refuse(rootReason)
		end
		ResourceGatheringSystem.SpawnDebugNode(kind, rootPart.CFrame * CFrame.new(0, 0, -RESOURCE_NODE_SPAWN_DISTANCE))
		logger:info(`{actionName} accepted`, { player = player.Name })
		return { Success = true }
	end
end

local handleSpawnCoalDeposit = spawnNodeHandler("SpawnCoalDeposit", "Coal")
local handleSpawnWaterSource = spawnNodeHandler("SpawnWaterSource", "Water")

-- The admin's OWN carried coal and water to the cap. Touches a profile, not the world, so it needs no
-- body -- it works before the admin has spawned.
local function handleFillCarriedFuel(player: Player): ActionResult
	local allowed, reason = checkPreconditions(player, "FillCarriedFuel")
	if not allowed then
		return refuse(reason)
	end
	if not ResourceGatheringSystem.FillCarriedFuel(player) then
		return refuse("NotLoaded")
	end
	logger:info("FillCarriedFuel accepted", { player = player.Name })
	return { Success = true }
end

-- Server ------------------------------------------------------------------------------------------

-- Set in Init(): a RemoteEvent, since an announcement goes to every client.
local announcementRemote: RemoteEvent? = nil

local function broadcastAnnouncement(kind: Types.DevMenuAnnouncementKind, message: string): ()
	if not announcementRemote then
		return
	end
	local payload: Types.DevMenuAnnouncementPayload = { Kind = kind, Message = message }
	announcementRemote:FireAllClients(payload)
end

local function handleBroadcastAnnouncement(player: Player, rawMessage: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "BroadcastAnnouncement")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawMessage) ~= "string" then
		return refuse("InvalidRequest")
	end
	local message = trim(rawMessage)
	if message == "" or #message > DevMenuConfig.AnnouncementMaxLength then
		return refuse("InvalidRequest")
	end
	broadcastAnnouncement("Info", message)
	logger:info("BroadcastAnnouncement accepted", { player = player.Name, length = #message })
	return { Success = true }
end

-- Per-admin arm windows (UserId -> os.clock deadline), so one admin's confirm never executes another
-- admin's arm. Cleared on PlayerRemoving.
local shutdownArmedUntil: { [number]: number } = {}
local instantRestartArmedUntil: { [number]: number } = {}

-- True the first time (arming), false once confirmed inside the window.
local function needsConfirmation(armedUntil: { [number]: number }, player: Player, windowSeconds: number): boolean
	local now = os.clock()
	if now >= (armedUntil[player.UserId] or 0) then
		armedUntil[player.UserId] = now + windowSeconds
		return true
	end
	armedUntil[player.UserId] = nil
	return false
end

local function handleShutdownServer(player: Player): ActionResult
	local allowed, reason = checkPreconditions(player, "ShutdownServer")
	if not allowed then
		return refuse(reason)
	end
	if needsConfirmation(shutdownArmedUntil, player, DevMenuConfig.ShutdownConfirmWindowSeconds) then
		logger:warn("ShutdownServer armed", { player = player.Name, userId = player.UserId })
		return refuse("ConfirmationRequired")
	end
	logger:warn("ShutdownServer confirmed -- server shutting down", {
		player = player.Name,
		userId = player.UserId,
		delaySeconds = DevMenuConfig.ShutdownDelaySeconds,
	})
	broadcastAnnouncement("Warning", `Server shutting down in {DevMenuConfig.ShutdownDelaySeconds} seconds.`)
	task.delay(DevMenuConfig.ShutdownDelaySeconds, function()
		for _, otherPlayer in Players:GetPlayers() do
			otherPlayer:Kick("Server shutting down")
		end
	end)
	return { Success = true }
end

-- Same server-armed two-press shape as Shutdown, no countdown once confirmed -- for cycling THIS
-- server onto a version just published.
local function handleInstantRestartServer(player: Player): ActionResult
	local allowed, reason = checkPreconditions(player, "InstantRestartServer")
	if not allowed then
		return refuse(reason)
	end
	if needsConfirmation(instantRestartArmedUntil, player, DevMenuConfig.InstantRestartConfirmWindowSeconds) then
		logger:warn("InstantRestartServer armed", { player = player.Name, userId = player.UserId })
		return refuse("ConfirmationRequired")
	end
	logger:warn("InstantRestartServer confirmed -- server restarting immediately", {
		player = player.Name,
		userId = player.UserId,
	})
	broadcastAnnouncement("Warning", "Server restarting now for an update.")
	for _, otherPlayer in Players:GetPlayers() do
		otherPlayer:Kick("Server restarting for an update. Please rejoin.")
	end
	return { Success = true }
end

-- Tuning ------------------------------------------------------------------------------------------

-- Closed whitelist: `field` selects which table KEY gets written on the live, shared FlightConstants.
local FLIGHT_TUNING_FIELDS: { [string]: Types.FlightTuningFieldName } = {}
for _, info in FlightTuning.ListFields() do
	FLIGHT_TUNING_FIELDS[info.Field] = info.Field
end

local function handleListFlightTuning(player: Player): Types.DevMenuListFlightTuningResult
	local allowed, reason = checkPreconditions(player, "ListFlightTuning")
	if not allowed then
		return refuse(reason)
	end
	return { Success = true, Fields = FlightTuning.ListFields() }
end

local function handleSetFlightTuning(
	player: Player,
	rawField: unknown,
	rawValue: unknown
): Types.DevMenuFlightTuningResult
	local allowed, reason = checkPreconditions(player, "SetFlightTuning")
	if not allowed then
		return refuse(reason)
	end
	local field = resolveEnum(rawField, FLIGHT_TUNING_FIELDS)
	-- `rawValue ~= rawValue` is the NaN test: see FlightTuning.SetField on why NaN must never land.
	if not field or typeof(rawValue) ~= "number" or rawValue ~= rawValue then
		return refuse("InvalidRequest")
	end
	local updated = FlightTuning.SetField(field, rawValue)
	if not updated then
		return refuse("InvalidRequest")
	end
	logger:info("SetFlightTuning accepted", { player = player.Name, field = field, value = updated.Value })
	return { Success = true, Field = updated }
end

local function handleResetFlightTuning(player: Player, rawField: unknown): Types.DevMenuFlightTuningResult
	local allowed, reason = checkPreconditions(player, "ResetFlightTuning")
	if not allowed then
		return refuse(reason)
	end
	local field = resolveEnum(rawField, FLIGHT_TUNING_FIELDS)
	if not field then
		return refuse("InvalidRequest")
	end
	local updated = FlightTuning.ResetField(field)
	if not updated then
		return refuse("InvalidRequest")
	end
	logger:info("ResetFlightTuning accepted", { player = player.Name, field = field })
	return { Success = true, Field = updated }
end

-- Reports -----------------------------------------------------------------------------------------
--
-- Gate here, compute in BugReportSystem, which has no authorization notion of its own.

local function handleListBugReports(player: Player, rawCursorMode: unknown): Types.DevMenuListBugReportsResult
	local allowed, reason = checkPreconditions(player, "ListBugReports")
	if not allowed then
		return refuse(reason)
	end
	local cursorMode: Types.BugReportListCursorMode = if rawCursorMode == "Next" then "Next" else "First"
	local reports, hasMore, failReason = BugReportSystem.ListReports(player, cursorMode)
	if not reports then
		return refuse(failReason)
	end
	return { Success = true, Reports = reports, HasMore = hasMore }
end

local function handleUpdateBugReportStatus(
	player: Player,
	rawReportId: unknown,
	rawStatus: unknown
): Types.DevMenuUpdateBugReportStatusResult
	local allowed, reason = checkPreconditions(player, "UpdateBugReportStatus")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawReportId) ~= "string" or not BugReportSystem.IsValidStatus(rawStatus) then
		return refuse("InvalidRequest")
	end
	local updated, failReason = BugReportSystem.UpdateStatus(player, rawReportId, rawStatus :: Types.BugReportStatus)
	if not updated then
		return refuse(failReason or "NotFound")
	end
	logger:info("UpdateBugReportStatus accepted", { player = player.Name, id = rawReportId, status = rawStatus })
	return { Success = true, Report = updated }
end

local function handleAddBugReportNote(
	player: Player,
	rawReportId: unknown,
	rawText: unknown
): Types.DevMenuBugReportMutationResult
	local allowed, reason = checkPreconditions(player, "AddBugReportNote")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawReportId) ~= "string" then
		return refuse("InvalidRequest")
	end
	local updated, failReason = BugReportSystem.AddNote(player, rawReportId, rawText)
	if not updated then
		return refuse(failReason or "NotFound")
	end
	logger:info("AddBugReportNote accepted", { player = player.Name, id = rawReportId })
	return { Success = true, Report = updated }
end

local function handleSetBugReportPriority(
	player: Player,
	rawReportId: unknown,
	rawPriority: unknown
): Types.DevMenuBugReportMutationResult
	local allowed, reason = checkPreconditions(player, "SetBugReportPriority")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawReportId) ~= "string" or not BugReportSystem.IsValidPriority(rawPriority) then
		return refuse("InvalidRequest")
	end
	local updated, failReason = BugReportSystem.SetPriority(player, rawReportId, rawPriority :: Types.BugReportPriority)
	if not updated then
		return refuse(failReason or "NotFound")
	end
	logger:info("SetBugReportPriority accepted", { player = player.Name, id = rawReportId, priority = rawPriority })
	return { Success = true, Report = updated }
end

local function handleAssignBugReport(
	player: Player,
	rawReportId: unknown,
	rawAssign: unknown
): Types.DevMenuBugReportMutationResult
	local allowed, reason = checkPreconditions(player, "AssignBugReport")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawReportId) ~= "string" or typeof(rawAssign) ~= "boolean" then
		return refuse("InvalidRequest")
	end
	local updated, failReason = BugReportSystem.AssignReport(player, rawReportId, rawAssign)
	if not updated then
		return refuse(failReason or "NotFound")
	end
	logger:info("AssignBugReport accepted", { player = player.Name, id = rawReportId, assign = rawAssign })
	return { Success = true, Report = updated }
end

-- The reporter must be in THIS server: GetPlayerByUserId never returns a player elsewhere.
local function handleJumpToReporter(player: Player, rawReportId: unknown): ActionResult
	local allowed, reason = checkPreconditions(player, "JumpToReporter")
	if not allowed then
		return refuse(reason)
	end
	if typeof(rawReportId) ~= "string" then
		return refuse("InvalidRequest")
	end
	local record, getFailReason = BugReportSystem.GetRecord(rawReportId)
	if not record then
		return refuse(getFailReason or "NotFound")
	end
	local reporter = Players:GetPlayerByUserId(record.ReporterUserId)
	if not reporter then
		return refuse("ReporterNotHere")
	end
	local reporterRoot, rootReason = getRootPart(reporter)
	if not reporterRoot then
		return refuse(rootReason)
	end
	if not AdminActionSystem.TeleportToPosition(player, reporterRoot.Position) then
		return refuse("NoCharacter")
	end
	logger:info("JumpToReporter accepted", { player = player.Name, reporter = reporter.Name })
	return { Success = true }
end

-- Registration ------------------------------------------------------------------------------------

-- Every result shape here shares the Success/Reason pair, so one internal-error result serves all.
local DEV_MENU_INTERNAL_ERROR_RESULT = { Success = false, Reason = "InternalError" }

-- Every RemoteFunction this System registers. RemoteKey indexes DevMenuConfig.RemoteNames; Name is
-- what RemoteHandler.WrapInvoke logs a caught error under (SpawnDummy's handler is SpawnDebugDummy --
-- the config key predates the rebuilt dummy and is kept because the Move Editor calls it too).
-- Handler is `any` because the table holds handlers of different argument/result types side by side.
type RemoteHandlerSpec = {
	RemoteKey: string,
	Name: string,
	Handler: (Player, ...any) -> any,
}
local REMOTE_HANDLERS: { RemoteHandlerSpec } = {
	{ RemoteKey = "GetOverview", Name = "GetOverview", Handler = handleGetOverview :: any },
	{ RemoteKey = "InspectPlayer", Name = "InspectPlayer", Handler = handleInspectPlayer :: any },

	{ RemoteKey = "SetTargetGodmode", Name = "SetTargetGodmode", Handler = handleSetTargetGodmode :: any },
	{ RemoteKey = "SetTargetFlight", Name = "SetTargetFlight", Handler = handleSetTargetFlight :: any },
	{
		RemoteKey = "SetTargetFlightCollide",
		Name = "SetTargetFlightCollide",
		Handler = handleSetTargetFlightCollide :: any,
	},
	{ RemoteKey = "SetTargetFrozen", Name = "SetTargetFrozen", Handler = handleSetTargetFrozen :: any },
	{ RemoteKey = "SetTargetInvisible", Name = "SetTargetInvisible", Handler = handleSetTargetInvisible :: any },
	{
		RemoteKey = "SetTargetSpeedMultiplier",
		Name = "SetTargetSpeedMultiplier",
		Handler = handleSetTargetSpeedMultiplier :: any,
	},
	{ RemoteKey = "TeleportToTarget", Name = "TeleportToTarget", Handler = handleTeleportToTarget :: any },
	{ RemoteKey = "BringTarget", Name = "BringTarget", Handler = handleBringTarget :: any },
	{ RemoteKey = "ForceRespawnTarget", Name = "ForceRespawnTarget", Handler = handleForceRespawnTarget :: any },
	{ RemoteKey = "RestoreTarget", Name = "RestoreTarget", Handler = handleRestoreTarget :: any },
	{ RemoteKey = "KillTarget", Name = "KillTarget", Handler = handleKillTarget :: any },
	{ RemoteKey = "GrantMeridianXP", Name = "GrantMeridianXP", Handler = handleGrantMeridianXP :: any },
	{
		RemoteKey = "GrantBloodlineRerolls",
		Name = "GrantBloodlineRerolls",
		Handler = handleGrantBloodlineRerolls :: any,
	},
	{ RemoteKey = "RollEmote", Name = "RollEmote", Handler = handleRollEmote :: any },

	{ RemoteKey = "KickPlayer", Name = "KickPlayer", Handler = handleKickPlayer :: any },
	{ RemoteKey = "BanPlayer", Name = "BanPlayer", Handler = handleBanPlayer :: any },
	{ RemoteKey = "MutePlayer", Name = "MutePlayer", Handler = handleMutePlayer :: any },
	{ RemoteKey = "SetSuspectedCheater", Name = "SetSuspectedCheater", Handler = handleSetSuspectedCheater :: any },
	{
		RemoteKey = "ResetTargetPlayerData",
		Name = "ResetTargetPlayerData",
		Handler = handleResetTargetPlayerData :: any,
	},
	{ RemoteKey = "LookupBan", Name = "LookupBan", Handler = handleLookupBan :: any },
	{ RemoteKey = "UnbanPlayer", Name = "UnbanPlayer", Handler = handleUnbanPlayer :: any },

	{ RemoteKey = "SpawnDummy", Name = "SpawnDebugDummy", Handler = handleSpawnDebugDummy :: any },
	{
		RemoteKey = "DespawnAllDebugDummies",
		Name = "DespawnAllDebugDummies",
		Handler = handleDespawnAllDebugDummies :: any,
	},
	{ RemoteKey = "SetDummyGuard", Name = "SetDummyGuard", Handler = handleSetDummyGuard :: any },
	{ RemoteKey = "GetDebugDummyState", Name = "GetDebugDummyState", Handler = handleGetDebugDummyState :: any },
	{ RemoteKey = "SpawnTrainingBot", Name = "SpawnTrainingBot", Handler = handleSpawnTrainingBot :: any },
	{ RemoteKey = "DespawnTrainingBots", Name = "DespawnTrainingBots", Handler = handleDespawnTrainingBots :: any },
	{ RemoteKey = "GetHitboxDebug", Name = "GetHitboxDebug", Handler = handleGetHitboxDebug :: any },
	{ RemoteKey = "SetHitboxDebug", Name = "SetHitboxDebug", Handler = handleSetHitboxDebug :: any },
	{
		RemoteKey = "TeleportToCoordinates",
		Name = "TeleportToCoordinates",
		Handler = handleTeleportToCoordinates :: any,
	},
	{ RemoteKey = "SpawnCoalDeposit", Name = "SpawnCoalDeposit", Handler = handleSpawnCoalDeposit :: any },
	{ RemoteKey = "SpawnWaterSource", Name = "SpawnWaterSource", Handler = handleSpawnWaterSource :: any },
	{ RemoteKey = "FillCarriedFuel", Name = "FillCarriedFuel", Handler = handleFillCarriedFuel :: any },

	{
		RemoteKey = "BroadcastAnnouncement",
		Name = "BroadcastAnnouncement",
		Handler = handleBroadcastAnnouncement :: any,
	},
	{ RemoteKey = "ShutdownServer", Name = "ShutdownServer", Handler = handleShutdownServer :: any },
	{ RemoteKey = "InstantRestartServer", Name = "InstantRestartServer", Handler = handleInstantRestartServer :: any },

	{ RemoteKey = "ListFlightTuning", Name = "ListFlightTuning", Handler = handleListFlightTuning :: any },
	{ RemoteKey = "SetFlightTuning", Name = "SetFlightTuning", Handler = handleSetFlightTuning :: any },
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
}

function DevMenuSystem.Init(): ()
	for _, spec in REMOTE_HANDLERS do
		local remoteName = DevMenuConfig.RemoteNames[spec.RemoteKey]
		assert(remoteName, `DevMenuSystem: no remote name for {spec.RemoteKey}`)
		local remote = NetworkBridge.CreateRemoteFunction(remoteName)
		remote.OnServerInvoke =
			RemoteHandler.WrapInvoke(logger, spec.Name, DEV_MENU_INTERNAL_ERROR_RESULT, spec.Handler)
	end

	-- The one RemoteEvent: broadcast to every client (Client/Announcement/AnnouncementClient.lua).
	announcementRemote = NetworkBridge.CreateRemoteEvent(DevMenuConfig.RemoteNames.Announcement)

	PlayerLifecycle.BindAllPlayers({
		Scope = "DevMenuSystem",
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
			pollLimiter:Clear(player)
			shutdownArmedUntil[player.UserId] = nil
			instantRestartArmedUntil[player.UserId] = nil
		end,
	})

	logger:info("DevMenuSystem.Init() complete", { remotes = #REMOTE_HANDLERS + 1 })
end

return DevMenuSystem :: Types.SystemModule
