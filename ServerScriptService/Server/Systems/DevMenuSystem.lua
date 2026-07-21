--!strict
--[[
	DevMenuSystem.lua

	Owns: server-side authorization and request handling for whitelist-gated developer tooling
	(Constants.Debug.DevMenu). Every request re-checks
	Constants.Debug.DevMenu.AuthorizedUserIds[player.UserId] itself, regardless of what the client
	believes -- DevMenuClient.lua's own whitelist read is a local-only UX convenience (skip
	connecting input for a non-dev), never trusted as authorization. Unlike Logger.lua, this System
	is NOT Studio-gated -- Constants.Debug.DevMenu's own header is explicit that dev tooling is
	meant to work in live servers too; safety comes entirely from the whitelist plus this System's
	own re-check on every request, never from RunService:IsStudio() or from being hidden.

	Does not own: what a dev action actually does -- CombatSystem.SpawnTrainingDummy/SpawnTrainingBot
	own training dummy/bot creation, and TrainingBotSystem.ValidatePresetRequest owns validating a
	bot spawn request's preset/weights (never trusted here directly); this System only decides
	*whether* a given request is allowed to reach those, then translates the request/response
	shape. Uses RemoteFunctions, not RemoteEvents, since the client needs to know immediately
	whether its request was accepted (see Types.DevMenuSpawnDummyResult/DevMenuSpawnBotResult).
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
local HitboxTuning = require(script.Parent.Parent.Combat.HitboxTuning)
local FlightTuning = require(script.Parent.Parent.DevMenu.FlightTuning)
local BugReportSystem = require(script.Parent.BugReportSystem)

local DevMenuSystem = {}

local logger = Logger.scope("DevMenuSystem")

local DevMenuConfig = Constants.Debug.DevMenu

-- Own bucket, separate from CombatSystem's -- dev tooling requests shouldn't compete with (or be
-- starved by) a player's combat remote budget, and vice versa.
local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

local function isAuthorized(player: Player): boolean
	return DevMenuConfig.AuthorizedUserIds[player.UserId] == true
end

-- Shared auth + rate-limit precondition, unifying what every one of the 15 handlers below used to
-- hand-duplicate: CombatSystem.lua already solved this exact problem for itself with its
-- ACTION_GATES table -- this is the DevMenuSystem equivalent, extracted after that same
-- hand-duplicated-gate failure mode (per CombatSystem.lua's own ACTION_GATES header: "the same
-- failure mode any hand-duplicated gate is one edit away from repeating") showed up here too.
-- actionName feeds both the "X rejected: ..." log message and the caller's own "X received" debug
-- line, so callers only need to name their action once. Returns (true, nil) when the request may
-- proceed, or (false, Reason) with the Reason string every handler's own Result shape already uses.
local function checkDevMenuPreconditions(player: Player, actionName: string): (boolean, string?)
	if not isAuthorized(player) then
		logger:warn(actionName .. " rejected: not authorized", { player = player.Name, userId = player.UserId })
		return false, "NotAuthorized"
	end
	if rateLimiter:IsLimited(player) then
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
	local ok = CombatSystem.SetPlayerGodmode(target, rawEnabled)
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
	local ok = CombatSystem.SetPlayerFlying(target, rawEnabled)
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
	local ok = CombatSystem.SetPlayerFlightCollide(target, rawEnabled)
	if not ok then
		return { Success = false, Reason = "NoTarget" }
	end

	logger:info("SetTargetFlightCollide accepted", { player = player.Name, target = target.Name, enabled = rawEnabled })
	return { Success = true }
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

	Players.PlayerRemoving:Connect(function(player: Player)
		rateLimiter:Clear(player)
	end)

	logger:info("DevMenuSystem.Init() complete")
end

return DevMenuSystem :: Types.SystemModule
