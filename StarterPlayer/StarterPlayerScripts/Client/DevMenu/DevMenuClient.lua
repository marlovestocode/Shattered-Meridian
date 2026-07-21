--!strict
--[[
	DevMenuClient.lua

	Owns: the local player's dev-menu UX -- keybind toggle (resolved through
	Client/Input/KeybindManager.lua rather than a hardcoded key, same as CombatClient.lua) and
	translating the DevMenu screen's SpawnDummyRequested/SpawnBotRequested signals into
	NetworkBridge RemoteFunction calls. The whitelist read below is a LOCAL-ONLY convenience (skip
	connecting input for a non-dev so the menu never even appears) -- never trusted as real
	authorization. DevMenuSystem.lua re-checks Constants.Debug.DevMenu.AuthorizedUserIds
	server-side on every request regardless of what this module decides, per
	luau-coding-standards.md's server/client split rule.

	Also drives the screen's TargetNameDisplay/GodmodeActive/FlightActive (see watchTarget below):
	subscribes directly to the existing Combat_LockOnChanged RemoteEvent (the same one
	CombatClient.lua already listens to for the lock-on reticle) to learn the resolved admin-action
	target exactly the way DevMenuSystem.resolveActionTarget resolves it server-side, then watches
	that target's Humanoid Godmode/Flying Attributes (CombatSystem.SetPlayerGodmode/SetPlayerFlying
	both mirror their boolean onto a replicated Attribute) the same way
	Client/DevMenu/FlightController.lua already watches its own Flying attribute. This is real
	server-replicated state, not a locally-guessed toggle -- no new remote needed.

	Does not own: whether a spawn request is actually allowed (DevMenuSystem.lua), or the dev menu
	panel itself (UI/Screens/DevMenu/init.lua) -- this module only drives that screen's handle from
	outside, the same "screen exposes state/signals, client module drives from outside" pattern
	CombatClient.lua already uses for CombatFeedback.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local CombatRemoteNames = Constants.Combat.RemoteNames

local DevMenuModule = require(script.Parent.Parent.UI.Screens.DevMenu)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

type DevMenuHandle = DevMenuModule.DevMenuHandle

local peek = Fusion.peek

local logger = Logger.scope("DevMenuClient")

local STATUS_CLEAR_DELAY = Constants.Debug.DevMenu.StatusClearDelaySeconds

local DevMenuClient = {}

local function describeResult(result: Types.DevMenuSpawnDummyResult): string
	if result.Success then
		return "Training dummy spawned."
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

local function describeBotResult(presetName: string, result: Types.DevMenuSpawnBotResult): string
	if result.Success then
		return `Training bot spawned ({presetName}).`
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

local function describeActionResult(actionLabel: string, result: Types.DevMenuActionResult): string
	if result.Success then
		return actionLabel .. " applied."
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

-- Generation counter guards the delayed clear below against a stale timer stomping a fresher
-- status message -- e.g. two identical-text results ("Training dummy spawned.") landing within
-- STATUS_CLEAR_DELAY of each other would otherwise let the first result's timer clear the second's
-- still-fresh message early (a plain string-equality check can't tell "my own message, still
-- showing" apart from "a different request that happened to produce the same text").
local statusGeneration = 0

-- Hitbox-timing tuner state -- the one ListHitboxStages fetch (below, in Start) populates this
-- once; every cycle/adjust/reset action after that reads/writes this SAME cached array rather than
-- re-fetching, since every Adjust/Reset response already carries back the one stage that changed
-- (Types.DevMenuHitboxStageResult). 1-based index into hitboxStages; both stay empty/1 (and the
-- section shows its "Loading..." placeholder) for a session where the fetch never resolves.
local hitboxStages: { Types.HitboxStageInfo } = {}
local hitboxSelectedIndex = 1

-- Standalone-attack tuner state -- same "fetch once, cache, patch from Adjust/Reset responses"
-- shape as hitboxStages/hitboxSelectedIndex above, for DashPunch/DashHit
-- (Types.DevMenuListStandaloneAttacksResult) instead of a weapon's combo stages.
local standaloneAttacks: { Types.HitboxStandaloneInfo } = {}
local standaloneSelectedIndex = 1

-- Flight-feel tuner state -- same "fetch once, cache, patch from Adjust/Reset responses" shape as
-- hitboxStages/hitboxSelectedIndex above, for Constants.Flight's own curated field set
-- (Types.DevMenuListFlightTuningResult) instead of a weapon's combo stages.
local flightTuningFields: { Types.FlightTuningInfo } = {}
local flightTuningSelectedIndex = 1

-- Reports tab state -- unlike the three tuner caches above (each keeps exactly one currently-
-- selected item), this keeps every fetched report so a status-change response can patch the one
-- record that changed in place (same "patch from Adjust/Reset response" idea, applied to a list
-- instead of a single selection) without a full re-fetch.
local reportRecords: { Types.BugReportRecord } = {}

-- Generic 3-decimal number formatter -- used for both hitbox timing (seconds) and standalone
-- offset (studs); the unit suffix is added by each renderer, not this function.
local function formatNumber(value: number): string
	return string.format("%.3f", value)
end

-- Pushes the currently selected cached stage's values onto the handle's display Value -- called
-- after the initial fetch and after every cycle/adjust/reset. Number->string formatting lives here,
-- not in the screen, per DevMenuHandle.HitboxStageDisplay's own "presentation, not computation"
-- contract.
local function renderHitboxStage(handle: DevMenuHandle): ()
	local stage = hitboxStages[hitboxSelectedIndex]
	if not stage then
		handle.HitboxStageDisplay:set(nil)
		return
	end
	handle.HitboxStageDisplay:set({
		TitleText = `{stage.WeaponId} {stage.DebugName}`,
		WindupText = `Windup: {formatNumber(stage.WindupSeconds)}s`,
		ActiveText = `Active: {formatNumber(stage.ActiveSeconds)}s`,
		RecoveryText = `Recovery: {formatNumber(stage.RecoverySeconds)}s`,
	})
end

-- Same shape as renderHitboxStage above, for the standalone-attack tuner.
local function renderStandaloneAttack(handle: DevMenuHandle): ()
	local attack = standaloneAttacks[standaloneSelectedIndex]
	if not attack then
		handle.HitboxStandaloneDisplay:set(nil)
		return
	end
	handle.HitboxStandaloneDisplay:set({
		TitleText = attack.DebugName,
		WindupText = `Windup: {formatNumber(attack.WindupSeconds)}s`,
		ActiveText = `Active: {formatNumber(attack.ActiveSeconds)}s`,
		RecoveryText = `Recovery: {formatNumber(attack.RecoverySeconds)}s`,
		OffsetText = `Offset: {formatNumber(attack.OffsetForwardStuds)} studs`,
	})
end

-- Same shape as renderHitboxStage above, for the flight-feel tuner.
local function renderFlightTuning(handle: DevMenuHandle): ()
	local field = flightTuningFields[flightTuningSelectedIndex]
	if not field then
		handle.FlightTuningDisplay:set(nil)
		return
	end
	handle.FlightTuningDisplay:set({
		TitleText = field.DisplayName,
		ValueText = `Value: {formatNumber(field.Value)}`,
	})
end

-- Number->string formatting for one report, same "presentation lives in DevMenuClient, the screen
-- only ever renders ready-made strings" boundary as renderHitboxStage/renderStandaloneAttack/
-- renderFlightTuning above.
local function formatReportContext(record: Types.BugReportRecord): string
	local positionText = if record.Position
		then string.format("(%.0f, %.0f, %.0f)", record.Position.X, record.Position.Y, record.Position.Z)
		else "no position"
	return `PlaceId {record.PlaceId} | Job {record.JobId} | {positionText}`
end

local function formatReportDisplay(record: Types.BugReportRecord): DevMenuModule.BugReportRowDisplay
	local dateText = os.date("%Y-%m-%d %H:%M", record.CreatedAt)
	return {
		Id = record.Id,
		HeaderText = `[{record.Category}] {record.ReporterName} -- {dateText}`,
		DescriptionText = record.Description,
		ContextText = formatReportContext(record),
		Status = record.Status,
	}
end

-- Pushes the full cached reportRecords list onto the handle's display Value -- called after every
-- fetch and after a status-change response patches one record in place.
local function renderReports(handle: DevMenuHandle): ()
	local displays: { DevMenuModule.BugReportRowDisplay } = {}
	for index, record in ipairs(reportRecords) do
		displays[index] = formatReportDisplay(record)
	end
	handle.ReportsDisplay:set(displays)
end

-- Shared fetch for both the initial load and the Refresh/Load More buttons -- cursorMode "First"
-- replaces the cached list (a fresh chronological page 1); "Next" appends onto it (see
-- BugReportSystem.ListReports' own per-admin DataStorePages session for why this has to be a
-- stateful cursor rather than an offset/limit the client could compute itself).
local function fetchReports(handle: DevMenuHandle, cursorMode: string): ()
	if peek(handle.ReportsLoading) then
		return
	end
	handle.ReportsLoading:set(true)

	local listRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListBugReports)
	local ok, resultOrError = pcall(function()
		return listRemote:InvokeServer(cursorMode)
	end)

	handle.ReportsLoading:set(false)

	if not ok then
		logger:error("ListBugReports request errored", { errorMessage = tostring(resultOrError) })
		return
	end

	local result = resultOrError :: Types.DevMenuListBugReportsResult
	if not result.Success or not result.Reports then
		logger:warn("ListBugReports rejected", { reason = result.Reason })
		return
	end

	if cursorMode == "Next" then
		for _, record in ipairs(result.Reports) do
			table.insert(reportRecords, record)
		end
	else
		reportRecords = result.Reports
	end

	handle.ReportsHasMore:set(result.HasMore == true)
	renderReports(handle)
	logger:debug("ListBugReports loaded", { fetchedCount = #result.Reports, cursorMode = cursorMode })
end

-- Target-tracking state for the Admin tab's live display (TargetNameDisplay/GodmodeActive/
-- FlightActive) -- module-local like hitboxStages above, since this module has exactly one
-- long-lived Start() call per client session. godmodeAttributeConnection/flyingAttributeConnection
-- watch whichever Humanoid currently belongs to the resolved target; targetCharacterAddedConnection
-- rebinds them across that target's own respawns (mirroring FlightController.lua's own
-- BindCharacter, just for a possibly-other player instead of always the local one).
local godmodeAttributeConnection: RBXScriptConnection? = nil
local flyingAttributeConnection: RBXScriptConnection? = nil
local collideAttributeConnection: RBXScriptConnection? = nil
local targetCharacterAddedConnection: RBXScriptConnection? = nil

-- Re-reads both Attributes off `humanoid` and (re)connects the two GetAttributeChangedSignal
-- listeners -- called for the resolved target's current character, and again every time that
-- target's character respawns. Disconnects any previous character's connections first so a target
-- who respawns repeatedly while still being watched can't stack duplicate listeners.
local function rebindAttributeConnections(handle: DevMenuHandle, humanoid: Humanoid): ()
	if godmodeAttributeConnection then
		godmodeAttributeConnection:Disconnect()
	end
	if flyingAttributeConnection then
		flyingAttributeConnection:Disconnect()
	end
	if collideAttributeConnection then
		collideAttributeConnection:Disconnect()
	end

	handle.GodmodeActive:set(humanoid:GetAttribute(Constants.Attributes.Godmode) == true)
	handle.FlightActive:set(humanoid:GetAttribute(Constants.Attributes.Flying) == true)
	handle.CollideActive:set(humanoid:GetAttribute(Constants.Attributes.FlyCollide) == true)

	godmodeAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.Godmode):Connect(function()
		handle.GodmodeActive:set(humanoid:GetAttribute(Constants.Attributes.Godmode) == true)
	end)
	flyingAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.Flying):Connect(function()
		handle.FlightActive:set(humanoid:GetAttribute(Constants.Attributes.Flying) == true)
	end)
	collideAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.FlyCollide):Connect(function()
		handle.CollideActive:set(humanoid:GetAttribute(Constants.Attributes.FlyCollide) == true)
	end)
end

-- Watches `targetPlayer` (whichever player DevMenuSystem.resolveActionTarget would currently
-- resolve to -- see setTarget below) for its Godmode/Flying Humanoid Attributes. Called once at
-- Start() (watching the local player, before any lock-on exists) and again every time
-- Combat_LockOnChanged fires with a new resolved target.
local function watchTarget(handle: DevMenuHandle, targetPlayer: Player): ()
	if targetCharacterAddedConnection then
		targetCharacterAddedConnection:Disconnect()
		targetCharacterAddedConnection = nil
	end

	local function onCharacterAdded(character: Model): ()
		local humanoidInstance = character:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds)
		if humanoidInstance and humanoidInstance:IsA("Humanoid") then
			rebindAttributeConnections(handle, humanoidInstance :: Humanoid)
		end
	end

	if targetPlayer.Character then
		onCharacterAdded(targetPlayer.Character)
	else
		if godmodeAttributeConnection then
			godmodeAttributeConnection:Disconnect()
			godmodeAttributeConnection = nil
		end
		if flyingAttributeConnection then
			flyingAttributeConnection:Disconnect()
			flyingAttributeConnection = nil
		end
		if collideAttributeConnection then
			collideAttributeConnection:Disconnect()
			collideAttributeConnection = nil
		end
		handle.GodmodeActive:set(false)
		handle.FlightActive:set(false)
		handle.CollideActive:set(false)
	end

	targetCharacterAddedConnection = targetPlayer.CharacterAdded:Connect(onCharacterAdded)
end

local function setStatus(handle: DevMenuHandle, message: string): ()
	statusGeneration += 1
	local generation = statusGeneration
	handle.StatusText:set(message)
	task.delay(STATUS_CLEAR_DELAY, function()
		if statusGeneration == generation then
			handle.StatusText:set("")
		end
	end)
end

-- Shared "InvokeServer -> describe result -> set status -> schedule clear" shape, duplicated
-- almost verbatim between the dummy-spawn and bot-spawn handlers below before this was extracted.
-- `invoke` performs the actual RemoteFunction call (each caller controls its own remote/arguments);
-- `describe` turns whatever it returns (or the pcall error) into the status string to display.
local function invokeAndReport(handle: DevMenuHandle, invoke: () -> unknown, describe: (unknown) -> string): ()
	handle.StatusText:set("Spawning...")

	local ok, resultOrError = pcall(invoke)

	local message: string
	if not ok then
		logger:error("Dev menu request errored", { errorMessage = tostring(resultOrError) })
		message = "Failed: request error"
	else
		message = describe(resultOrError)
	end

	setStatus(handle, message)
end

function DevMenuClient.Start(handle: DevMenuHandle): ()
	local localPlayer = Players.LocalPlayer

	-- Local-only UX gate -- see file header. Never trusted as authorization.
	if Constants.Debug.DevMenu.AuthorizedUserIds[localPlayer.UserId] ~= true then
		logger:debug("DevMenuClient not started: local player not on whitelist", { userId = localPlayer.UserId })
		return
	end

	logger:info("DevMenuClient.Start called", { userId = localPlayer.UserId })

	-- Target tracking for the Admin tab's live display -- resolves exactly the way
	-- DevMenuSystem.resolveActionTarget does server-side (lock-on target, or self if none),
	-- reusing the existing Combat_LockOnChanged broadcast rather than adding a new remote.
	local function setTarget(targetUserId: number?): ()
		local lockedOnPlayer = if targetUserId then Players:GetPlayerByUserId(targetUserId) else nil
		local resolvedTarget = lockedOnPlayer or localPlayer
		handle.TargetNameDisplay:set(if lockedOnPlayer then lockedOnPlayer.Name else "Self")
		watchTarget(handle, resolvedTarget)
	end

	setTarget(nil)

	local lockOnChangedRemote = NetworkBridge.GetRemoteEvent(CombatRemoteNames.LockOnChanged)
	lockOnChangedRemote.OnClientEvent:Connect(function(targetUserId: number?)
		logger:debug("Combat_LockOnChanged received (DevMenu target tracking)", { targetUserId = targetUserId })
		setTarget(targetUserId)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("DevMenuToggle", input) then
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			logger:debug("Dev menu toggled", { open = nowOpen })
		end
	end)

	handle.SpawnDummyRequested:Connect(function()
		logger:debug("SpawnDummyRequested received")
		invokeAndReport(handle, function()
			local spawnDummyRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SpawnDummy)
			return spawnDummyRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuSpawnDummyResult
			logger:debug("SpawnDummy result received", { success = result.Success, reason = result.Reason })
			return describeResult(result)
		end)
	end)

	handle.SpawnBotRequested:Connect(function(presetName: string)
		logger:debug("SpawnBotRequested received", { preset = presetName })
		invokeAndReport(handle, function()
			local spawnBotRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SpawnTrainingBot)
			return spawnBotRemote:InvokeServer(presetName)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuSpawnBotResult
			logger:debug("SpawnTrainingBot result received", { success = result.Success, reason = result.Reason })
			return describeBotResult(presetName, result)
		end)
	end)

	handle.SetHealthRequested:Connect(function(health: number)
		logger:debug("SetHealthRequested received", { health = health })
		invokeAndReport(handle, function()
			local setHealthRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetHealth)
			return setHealthRemote:InvokeServer(health)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetTargetHealth result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Health", result)
		end)
	end)

	handle.SetGodmodeRequested:Connect(function(enabled: boolean)
		logger:debug("SetGodmodeRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setGodmodeRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetGodmode)
			return setGodmodeRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetTargetGodmode result received", { success = result.Success, reason = result.Reason })
			return describeActionResult(if enabled then "Godmode on" else "Godmode off", result)
		end)
	end)

	handle.SetFlightRequested:Connect(function(enabled: boolean)
		logger:debug("SetFlightRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setFlightRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetFlight)
			return setFlightRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetTargetFlight result received", { success = result.Success, reason = result.Reason })
			return describeActionResult(if enabled then "Flight on" else "Flight off", result)
		end)
	end)

	handle.SetFlightCollideRequested:Connect(function(enabled: boolean)
		logger:debug("SetFlightCollideRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setFlightCollideRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetFlightCollide)
			return setFlightCollideRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetTargetFlightCollide result received", { success = result.Success, reason = result.Reason })
			return describeActionResult(if enabled then "Collide on" else "Collide off", result)
		end)
	end)

	-- Hitbox timing tuner: fetch every tunable stage ONCE (see hitboxStages' own header) and wire
	-- the cycle/adjust/reset signals. task.spawn since InvokeServer yields and Start() shouldn't
	-- stall the rest of the client boot sequence behind it (Main.client.lua's own convention for
	-- yielding work, e.g. bindLocalCharacter in CombatClient.lua).
	task.spawn(function()
		local listRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListHitboxStages)
		local ok, resultOrError = pcall(function()
			return listRemote:InvokeServer()
		end)
		if not ok then
			logger:error("ListHitboxStages request errored", { errorMessage = tostring(resultOrError) })
			return
		end
		local result = resultOrError :: Types.DevMenuListHitboxStagesResult
		if not result.Success or not result.Stages then
			logger:warn("ListHitboxStages rejected", { reason = result.Reason })
			return
		end
		hitboxStages = result.Stages
		hitboxSelectedIndex = 1
		renderHitboxStage(handle)
		logger:debug("ListHitboxStages loaded", { stageCount = #hitboxStages })
	end)

	handle.CycleHitboxStagePrevRequested:Connect(function()
		if #hitboxStages == 0 then
			return
		end
		hitboxSelectedIndex = if hitboxSelectedIndex <= 1 then #hitboxStages else hitboxSelectedIndex - 1
		renderHitboxStage(handle)
	end)

	handle.CycleHitboxStageNextRequested:Connect(function()
		if #hitboxStages == 0 then
			return
		end
		hitboxSelectedIndex = if hitboxSelectedIndex >= #hitboxStages then 1 else hitboxSelectedIndex + 1
		renderHitboxStage(handle)
	end)

	handle.AdjustHitboxTimingRequested:Connect(function(field: string, delta: number)
		local stage = hitboxStages[hitboxSelectedIndex]
		if not stage then
			return
		end
		logger:debug("AdjustHitboxTimingRequested received", { field = field, delta = delta })
		invokeAndReport(handle, function()
			local adjustRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.AdjustHitboxTiming)
			return adjustRemote:InvokeServer(stage.WeaponId, stage.Category, stage.StageIndex, field, delta)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuHitboxStageResult
			if result.Success and result.Stage then
				hitboxStages[hitboxSelectedIndex] = result.Stage
				renderHitboxStage(handle)
				return "Timing updated."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	handle.ResetHitboxStageRequested:Connect(function()
		local stage = hitboxStages[hitboxSelectedIndex]
		if not stage then
			return
		end
		logger:debug("ResetHitboxStageRequested received")
		invokeAndReport(handle, function()
			local resetRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ResetHitboxStage)
			return resetRemote:InvokeServer(stage.WeaponId, stage.Category, stage.StageIndex)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuHitboxStageResult
			if result.Success and result.Stage then
				hitboxStages[hitboxSelectedIndex] = result.Stage
				renderHitboxStage(handle)
				return "Stage reset to default."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	-- Standalone-attack tuner: same fetch-once/cycle/adjust/reset wiring as the hitbox-stage tuner
	-- above, for DashPunch/DashHit instead of a weapon's combo stages.
	task.spawn(function()
		local listRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListStandaloneAttacks)
		local ok, resultOrError = pcall(function()
			return listRemote:InvokeServer()
		end)
		if not ok then
			logger:error("ListStandaloneAttacks request errored", { errorMessage = tostring(resultOrError) })
			return
		end
		local result = resultOrError :: Types.DevMenuListStandaloneAttacksResult
		if not result.Success or not result.Attacks then
			logger:warn("ListStandaloneAttacks rejected", { reason = result.Reason })
			return
		end
		standaloneAttacks = result.Attacks
		standaloneSelectedIndex = 1
		renderStandaloneAttack(handle)
		logger:debug("ListStandaloneAttacks loaded", { attackCount = #standaloneAttacks })
	end)

	handle.CycleHitboxStandalonePrevRequested:Connect(function()
		if #standaloneAttacks == 0 then
			return
		end
		standaloneSelectedIndex = if standaloneSelectedIndex <= 1
			then #standaloneAttacks
			else standaloneSelectedIndex - 1
		renderStandaloneAttack(handle)
	end)

	handle.CycleHitboxStandaloneNextRequested:Connect(function()
		if #standaloneAttacks == 0 then
			return
		end
		standaloneSelectedIndex = if standaloneSelectedIndex >= #standaloneAttacks
			then 1
			else standaloneSelectedIndex + 1
		renderStandaloneAttack(handle)
	end)

	handle.AdjustHitboxStandaloneRequested:Connect(function(field: string, delta: number)
		local attack = standaloneAttacks[standaloneSelectedIndex]
		if not attack then
			return
		end
		logger:debug("AdjustHitboxStandaloneRequested received", { field = field, delta = delta })
		invokeAndReport(handle, function()
			local adjustRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.AdjustStandaloneField)
			return adjustRemote:InvokeServer(attack.Name, field, delta)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuStandaloneAttackResult
			if result.Success and result.Attack then
				standaloneAttacks[standaloneSelectedIndex] = result.Attack
				renderStandaloneAttack(handle)
				return "Attack updated."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	handle.ResetHitboxStandaloneRequested:Connect(function()
		local attack = standaloneAttacks[standaloneSelectedIndex]
		if not attack then
			return
		end
		logger:debug("ResetHitboxStandaloneRequested received")
		invokeAndReport(handle, function()
			local resetRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ResetStandaloneAttack)
			return resetRemote:InvokeServer(attack.Name)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuStandaloneAttackResult
			if result.Success and result.Attack then
				standaloneAttacks[standaloneSelectedIndex] = result.Attack
				renderStandaloneAttack(handle)
				return "Attack reset to default."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	-- Flight-feel tuner: same fetch-once/cycle/adjust/reset wiring as the two Hitbox tuners above,
	-- for Constants.Flight's own curated field set instead of a weapon's combo stages. Adjust fires
	-- a FRACTIONAL delta straight through (no per-field name needed -- unlike the hitbox tuners,
	-- there's only ever one number being adjusted for whichever field is currently selected).
	task.spawn(function()
		local listRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListFlightTuning)
		local ok, resultOrError = pcall(function()
			return listRemote:InvokeServer()
		end)
		if not ok then
			logger:error("ListFlightTuning request errored", { errorMessage = tostring(resultOrError) })
			return
		end
		local result = resultOrError :: Types.DevMenuListFlightTuningResult
		if not result.Success or not result.Fields then
			logger:warn("ListFlightTuning rejected", { reason = result.Reason })
			return
		end
		flightTuningFields = result.Fields
		flightTuningSelectedIndex = 1
		renderFlightTuning(handle)
		logger:debug("ListFlightTuning loaded", { fieldCount = #flightTuningFields })
	end)

	handle.CycleFlightTuningPrevRequested:Connect(function()
		if #flightTuningFields == 0 then
			return
		end
		flightTuningSelectedIndex = if flightTuningSelectedIndex <= 1
			then #flightTuningFields
			else flightTuningSelectedIndex - 1
		renderFlightTuning(handle)
	end)

	handle.CycleFlightTuningNextRequested:Connect(function()
		if #flightTuningFields == 0 then
			return
		end
		flightTuningSelectedIndex = if flightTuningSelectedIndex >= #flightTuningFields
			then 1
			else flightTuningSelectedIndex + 1
		renderFlightTuning(handle)
	end)

	handle.AdjustFlightTuningRequested:Connect(function(deltaFraction: number)
		local field = flightTuningFields[flightTuningSelectedIndex]
		if not field then
			return
		end
		logger:debug("AdjustFlightTuningRequested received", { field = field.Field, deltaFraction = deltaFraction })
		invokeAndReport(handle, function()
			local adjustRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.AdjustFlightTuning)
			return adjustRemote:InvokeServer(field.Field, deltaFraction)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuFlightTuningResult
			if result.Success and result.Field then
				flightTuningFields[flightTuningSelectedIndex] = result.Field
				renderFlightTuning(handle)
				return "Field updated."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	handle.ResetFlightTuningRequested:Connect(function()
		local field = flightTuningFields[flightTuningSelectedIndex]
		if not field then
			return
		end
		logger:debug("ResetFlightTuningRequested received")
		invokeAndReport(handle, function()
			local resetRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ResetFlightTuning)
			return resetRemote:InvokeServer(field.Field)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuFlightTuningResult
			if result.Success and result.Field then
				flightTuningFields[flightTuningSelectedIndex] = result.Field
				renderFlightTuning(handle)
				return "Field reset to default."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	-- Reports tab: eager fetch at Start() (same "pay one DataStore read even if the admin never
	-- opens that tab" trade-off the three tuner fetches above already accept), then wire
	-- Refresh/Load More/triage.
	task.spawn(function()
		fetchReports(handle, "First")
	end)

	handle.LoadFirstReportsRequested:Connect(function()
		logger:debug("LoadFirstReportsRequested received")
		task.spawn(function()
			fetchReports(handle, "First")
		end)
	end)

	handle.LoadMoreReportsRequested:Connect(function()
		logger:debug("LoadMoreReportsRequested received")
		task.spawn(function()
			fetchReports(handle, "Next")
		end)
	end)

	handle.UpdateReportStatusRequested:Connect(function(reportId: string, newStatus: string)
		logger:debug("UpdateReportStatusRequested received", { id = reportId, status = newStatus })
		invokeAndReport(handle, function()
			local updateRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.UpdateBugReportStatus)
			return updateRemote:InvokeServer(reportId, newStatus)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuUpdateBugReportStatusResult
			if result.Success and result.Report then
				for index, record in ipairs(reportRecords) do
					if record.Id == result.Report.Id then
						reportRecords[index] = result.Report
						break
					end
				end
				renderReports(handle)
				return "Report status updated."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	logger:debug("DevMenuClient bindings connected")
end

return DevMenuClient
