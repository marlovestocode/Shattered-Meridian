--!strict
--[[
	DevMenuClient.lua

	Owns: the local player's dev-menu UX -- keybind toggle (resolved through
	Client/Input/KeybindManager.lua rather than a hardcoded key, same as CombatClient.lua) and
	translating the DevMenu screen's SpawnDummyRequested/SpawnBotRequested signals into
	NetworkBridge RemoteFunction calls. This module holds NO copy of the admin whitelist: it asks the
	server whether to start at all (see requestServerAuthorization below), because that list lives in
	ServerScriptService/Server/Config/AdminConfig.lua and no longer replicates to clients. Gating here
	remains a UX convenience either way -- skip connecting input for a non-dev so the menu never even
	appears -- and is never trusted as real authorization: DevMenuSystem.lua re-checks the whitelist
	server-side on every request regardless of what this module decides, per
	luau-coding-standards.md's server/client split rule.

	Also binds "OpenDevConsole" (F6), which opens Roblox's own developer console. It lives here rather
	than in its own module for one reason: this is already the module that has asked the server
	whether this client is an admin, so binding it inside startDevMenu gets the console the identical
	whitelist as the menu for free -- no second authorization path, no new remote, nothing to keep in
	sync. Roblox's built-in F9 only binds for accounts with edit access to the place, so a whitelisted
	admin who is neither the owner nor a group member otherwise has no way to read a live server's
	logs at all; StarterGui:SetCore("DevConsoleVisible") has no such gate. Same "client-side
	convenience toggle, fires no remote" shape as the DevMenuToggle bind next to it -- and, like it,
	not real authorization: nothing the console exposes is a privileged ACTION, every one of those
	still goes through DevMenuSystem's own server-side check.

	Also drives the screen's TargetNameDisplay/GodmodeActive/FlightActive (see watchTarget below):
	subscribes directly to the existing Combat_LockOnChanged RemoteEvent (the same one
	CombatClient.lua already listens to for the lock-on reticle) to learn the resolved admin-action
	target exactly the way DevMenuSystem.resolveActionTarget resolves it server-side, then watches
	that target's Humanoid Godmode/Flying Attributes (AdminActionSystem.SetGodmode/SetFlying both
	mirror their boolean onto a replicated Attribute) the same way
	Client/DevMenu/FlightController.lua already watches its own Flying attribute. This is real
	server-replicated state, not a locally-guessed toggle -- no new remote needed.

	Screens/DevMenu/init.lua's Sidebar/ContentArea split (see that module's own header) means every
	field this module used to reach as a flat `handle.X` now lives on `handle.Sidebar.X` (the
	"Players" tab roster) or `handle.Content.Y` (every other tab) -- `handle.StatusText`/`handle.IsOpen`
	stay on the root handle itself. Every helper function below that only needs Content or Sidebar
	still takes the full DevMenuHandle (unchanged signatures) and reaches into the one sub-handle it
	actually needs, rather than every call site being rewritten to pass the narrower type around.

	Does not own: whether a spawn request is actually allowed (DevMenuSystem.lua), or the dev menu
	panel itself (UI/Screens/DevMenu/init.lua) -- this module only drives that screen's handle from
	outside, the same "screen exposes state/signals, client module drives from outside" pattern
	CombatClient.lua already uses for CombatFeedback.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
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
local ParkourDebug = require(script.Parent.Parent.Parkour.ParkourDebug)
local SpectateController = require(script.Parent.SpectateController)

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

local function describeRollEmoteResult(result: Types.DevMenuRollEmoteResult): string
	if result.Success then
		return `Emote rolled: {result.EmoteId or "?"}.`
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

local function describeActionResult(actionLabel: string, result: Types.DevMenuActionResult): string
	if result.Success then
		return actionLabel .. " applied."
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

-- Shutdown's first (arming) press returns DevMenuActionResult with Reason = "ConfirmationRequired" --
-- not a failure in the everyday sense, so this special-cases that one Reason into a real instruction
-- rather than letting describeActionResult's generic "Failed: ConfirmationRequired" render.
local function describeShutdownResult(result: Types.DevMenuActionResult): string
	if result.Success then
		return "Server shutdown confirmed."
	end
	if result.Reason == "ConfirmationRequired" then
		return "Press again to confirm server shutdown."
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

-- Same special-casing as describeShutdownResult above, for Instant Restart Server's own two-press
-- confirm (Constants.Debug.DevMenu.InstantRestartConfirmWindowSeconds).
local function describeInstantRestartResult(result: Types.DevMenuActionResult): string
	if result.Success then
		return "Server restarting now."
	end
	if result.Reason == "ConfirmationRequired" then
		return "Press again to restart the server immediately."
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

-- Generation counter guards the delayed clear below against a stale timer stomping a fresher
-- status message -- e.g. two identical-text results ("Training dummy spawned.") landing within
-- STATUS_CLEAR_DELAY of each other would otherwise let the first result's timer clear the second's
-- still-fresh message early (a plain string-equality check can't tell "my own message, still
-- showing" apart from "a different request that happened to produce the same text").
local statusGeneration = 0

-- Flight-feel tuner state -- fetch once, cache, patch from Adjust/Reset responses (the only
-- remaining DevMenu tuning tool of this shape -- Hitbox Timing/Standalone Attacks moved to the Move
-- Editor's "Default" moves section, see Server/Combat/DefaultMoveRegistry.lua), for Constants.
-- Flight's own curated field set (Types.DevMenuListFlightTuningResult).
local flightTuningFields: { Types.FlightTuningInfo } = {}
local flightTuningSelectedIndex = 1

-- Reports tab state -- unlike the flight-tuner cache above (which keeps exactly one currently-
-- selected item), this keeps every fetched report so a status-change response can patch the one
-- record that changed in place (same "patch from Adjust/Reset response" idea, applied to a list
-- instead of a single selection) without a full re-fetch.
local reportRecords: { Types.BugReportRecord } = {}

-- Set once at the top of startDevMenu -- formatReportDisplay needs it to compute
-- BugReportRowDisplay.IsAssignedToMe (record.AssignedAdminUserId == this admin's own UserId)
-- without every call site threading the local player through.
local reportsLocalUserId = 0

-- Generic 3-decimal number formatter -- originally shared by hitbox timing (seconds) and
-- standalone offset (studs) too (both moved to the Move Editor's "Default" moves section); still
-- used for the flight-tuner's own value display. The unit suffix is added by each renderer, not
-- this function.
local function formatNumber(value: number): string
	return string.format("%.3f", value)
end

-- Pushes the currently selected cached field's values onto the handle's display Value -- called
-- after the initial fetch and after every cycle/adjust/reset. Number->string formatting lives here,
-- not in the screen, per DevMenuHandle.Content.FlightTuningDisplay's own "presentation, not
-- computation" contract.
local function renderFlightTuning(handle: DevMenuHandle): ()
	local field = flightTuningFields[flightTuningSelectedIndex]
	if not field then
		handle.Content.FlightTuningDisplay:set(nil)
		return
	end
	handle.Content.FlightTuningDisplay:set({
		TitleText = field.DisplayName,
		ValueText = `Value: {formatNumber(field.Value)}`,
	})
end

-- Number->string formatting for one report, same "presentation lives in DevMenuClient, the screen
-- only ever renders ready-made strings" boundary as renderFlightTuning above.
local function formatReportContext(record: Types.BugReportRecord): string
	local positionText = if record.Position
		then string.format("(%.0f, %.0f, %.0f)", record.Position.X, record.Position.Y, record.Position.Z)
		else "no position"
	return `PlaceId {record.PlaceId} | Job {record.JobId} | {positionText}`
end

local function formatReportNote(note: Types.BugReportNote): DevMenuModule.BugReportNoteDisplay
	return {
		Id = note.Id,
		AuthorName = note.AuthorName,
		Text = note.Text,
		TimeText = os.date("%Y-%m-%d %H:%M", note.CreatedAt),
	}
end

local function formatReportDisplay(record: Types.BugReportRecord): DevMenuModule.BugReportRowDisplay
	local dateText = os.date("%Y-%m-%d %H:%M", record.CreatedAt)
	local notesDisplay: { DevMenuModule.BugReportNoteDisplay } = {}
	for index, note in ipairs(record.Notes) do
		notesDisplay[index] = formatReportNote(note)
	end
	return {
		Id = record.Id,
		HeaderText = `[{record.Category}] {record.ReporterName} -- {dateText}`,
		DescriptionText = record.Description,
		ContextText = formatReportContext(record),
		Status = record.Status,
		Category = record.Category,
		ReporterName = record.ReporterName,
		Priority = record.Priority,
		PriorityText = `Priority: {record.Priority}`,
		AssignedText = if record.AssignedAdminName then `Claimed by {record.AssignedAdminName}` else "Unassigned",
		IsAssignedToMe = record.AssignedAdminUserId == reportsLocalUserId,
		Notes = notesDisplay,
	}
end

-- Pushes the full cached reportRecords list onto the handle's display Value -- called after every
-- fetch and after a status-change response patches one record in place.
local function renderReports(handle: DevMenuHandle): ()
	local displays: { DevMenuModule.BugReportRowDisplay } = {}
	for index, record in ipairs(reportRecords) do
		displays[index] = formatReportDisplay(record)
	end
	handle.Content.ReportsDisplay:set(displays)
end

-- Shared fetch for both the initial load and the Refresh/Load More buttons -- cursorMode "First"
-- replaces the cached list (a fresh chronological page 1); "Next" appends onto it (see
-- BugReportSystem.ListReports' own per-admin DataStorePages session for why this has to be a
-- stateful cursor rather than an offset/limit the client could compute itself).
local function fetchReports(handle: DevMenuHandle, cursorMode: string): ()
	if peek(handle.Content.ReportsLoading) then
		return
	end
	handle.Content.ReportsLoading:set(true)

	local listRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListBugReports)
	local ok, resultOrError = pcall(function()
		return listRemote:InvokeServer(cursorMode)
	end)

	handle.Content.ReportsLoading:set(false)

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

	handle.Content.ReportsHasMore:set(result.HasMore == true)
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
local frozenAttributeConnection: RBXScriptConnection? = nil
local invisibleAttributeConnection: RBXScriptConnection? = nil
local speedMultiplierAttributeConnection: RBXScriptConnection? = nil
local targetCharacterAddedConnection: RBXScriptConnection? = nil

-- The Player DevMenuSystem.resolveActionTarget would currently resolve to -- kept alongside the
-- Attribute-tracking state above so the Spectate toggle (SpectateLockedTargetRequested below) can
-- reuse the SAME resolution this module already computes for the Admin tab's live display, instead
-- of re-deriving it a second time or adding a new remote just to ask the server who it is.
local currentResolvedTarget: Player? = nil

-- Re-reads every tracked Attribute off `humanoid` and (re)connects their GetAttributeChangedSignal
-- listeners -- called for the resolved target's current character, and again every time that
-- target's character respawns. Disconnects any previous character's connections first so a target
-- who respawns repeatedly while still being watched can't stack duplicate listeners. Every field
-- touched here (Godmode/Flight/Collide/Frozen/Invisible/SpeedMultiplier) lives on the Admin tab, so
-- it's Content-owned -- see DevMenuHandle's own header for the Sidebar/Content split.
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
	if frozenAttributeConnection then
		frozenAttributeConnection:Disconnect()
	end
	if invisibleAttributeConnection then
		invisibleAttributeConnection:Disconnect()
	end
	if speedMultiplierAttributeConnection then
		speedMultiplierAttributeConnection:Disconnect()
	end

	local content = handle.Content

	content.GodmodeActive:set(humanoid:GetAttribute(Constants.Attributes.Godmode) == true)
	content.FlightActive:set(humanoid:GetAttribute(Constants.Attributes.Flying) == true)
	content.CollideActive:set(humanoid:GetAttribute(Constants.Attributes.FlyCollide) == true)
	content.FrozenActive:set(humanoid:GetAttribute(Constants.Attributes.Frozen) == true)
	content.InvisibleActive:set(humanoid:GetAttribute(Constants.Attributes.Invisible) == true)
	content.SpeedMultiplierActive:set((humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier) :: number?) or 1)

	godmodeAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.Godmode):Connect(function()
		content.GodmodeActive:set(humanoid:GetAttribute(Constants.Attributes.Godmode) == true)
	end)
	flyingAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.Flying):Connect(function()
		content.FlightActive:set(humanoid:GetAttribute(Constants.Attributes.Flying) == true)
	end)
	collideAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.FlyCollide):Connect(function()
		content.CollideActive:set(humanoid:GetAttribute(Constants.Attributes.FlyCollide) == true)
	end)
	frozenAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.Frozen):Connect(function()
		content.FrozenActive:set(humanoid:GetAttribute(Constants.Attributes.Frozen) == true)
	end)
	invisibleAttributeConnection = humanoid:GetAttributeChangedSignal(Constants.Attributes.Invisible):Connect(function()
		content.InvisibleActive:set(humanoid:GetAttribute(Constants.Attributes.Invisible) == true)
	end)
	speedMultiplierAttributeConnection = humanoid
		:GetAttributeChangedSignal(Constants.Attributes.SpeedMultiplier)
		:Connect(function()
			content.SpeedMultiplierActive:set(
				(humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier) :: number?) or 1
			)
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
		end
		if flyingAttributeConnection then
			flyingAttributeConnection:Disconnect()
		end
		if collideAttributeConnection then
			collideAttributeConnection:Disconnect()
		end
		if frozenAttributeConnection then
			frozenAttributeConnection:Disconnect()
		end
		if invisibleAttributeConnection then
			invisibleAttributeConnection:Disconnect()
		end
		if speedMultiplierAttributeConnection then
			speedMultiplierAttributeConnection:Disconnect()
		end
		godmodeAttributeConnection = nil
		flyingAttributeConnection = nil
		collideAttributeConnection = nil
		frozenAttributeConnection = nil
		invisibleAttributeConnection = nil
		speedMultiplierAttributeConnection = nil
		handle.Content.GodmodeActive:set(false)
		handle.Content.FlightActive:set(false)
		handle.Content.CollideActive:set(false)
		handle.Content.FrozenActive:set(false)
		handle.Content.InvisibleActive:set(false)
		handle.Content.SpeedMultiplierActive:set(1)
	end

	targetCharacterAddedConnection = targetPlayer.CharacterAdded:Connect(onCharacterAdded)
end

-- StatusText stays on the root handle (not Sidebar/Content) -- see DevMenuHandle's own header.
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

-- Asks the SERVER whether this client may run the dev menu, replacing a former local read of
-- Constants.Debug.DevMenu.AuthorizedUserIds. That list now lives in
-- ServerScriptService/Server/Config/AdminConfig.lua and no longer replicates -- see that file's
-- header for why publishing the admin roster to every client was worth removing.
--
-- Deliberately reuses the existing DevMenu_GetSidebarStats RemoteFunction rather than adding an
-- "am I an admin" remote: every DevMenuSystem handler already runs the same
-- checkDevMenuPreconditions gate and rejects unauthorized callers identically, so a rejection here
-- IS the authorization answer -- and this is a call startDevMenu() already makes for the sidebar
-- header anyway. The extra round-trip is one per join, admin or not.
--
-- Yields (InvokeServer), which is exactly why Start() below runs it inside task.spawn: Start() is
-- called synchronously partway through Main.client.lua's boot sequence, and blocking here would
-- stall every client module after it for every player in the game.
local function requestServerAuthorization(): boolean
	local ok, resultOrError = pcall(function()
		return NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetSidebarStats):InvokeServer()
	end)
	if not ok then
		logger:debug("DevMenu authorization check errored", { errorMessage = tostring(resultOrError) })
		return false
	end
	local result = resultOrError :: Types.DevMenuSidebarStatsResult?
	return result ~= nil and result.Success == true
end

local function startDevMenu(handle: DevMenuHandle): ()
	local localPlayer = Players.LocalPlayer
	local sidebar = handle.Sidebar
	local content = handle.Content

	logger:info("DevMenuClient.Start called", { userId = localPlayer.UserId })

	-- See reportsLocalUserId's own declaration -- must be set before the Reports tab's eager fetch
	-- below runs, so the very first render already knows which reports (if any) this admin holds.
	reportsLocalUserId = localPlayer.UserId

	-- Target tracking for the Admin tab's live display -- resolves exactly the way
	-- DevMenuSystem.resolveActionTarget does server-side (lock-on target, or self if none),
	-- reusing the existing Combat_LockOnChanged broadcast rather than adding a new remote.
	local function setTarget(targetUserId: number?): ()
		local lockedOnPlayer = if targetUserId then Players:GetPlayerByUserId(targetUserId) else nil
		local resolvedTarget = lockedOnPlayer or localPlayer
		currentResolvedTarget = resolvedTarget
		content.TargetNameDisplay:set(if lockedOnPlayer then lockedOnPlayer.Name else "Self")
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
		elseif KeybindManager.Matches("OpenDevConsole", input) then
			-- Roblox's own developer console, opened for an authorized admin. Bound HERE, inside
			-- startDevMenu, specifically because this function only ever runs after
			-- requestServerAuthorization returned true -- so the console binding inherits the exact
			-- same whitelist as the dev menu itself, with no second authorization path to keep in sync
			-- and no new remote.
			--
			-- WHY THIS IS NEEDED AT ALL, since Roblox already ships F9: the engine only binds that
			-- shortcut for accounts with edit access to the place. A whitelisted admin who is not the
			-- place owner or a group member gets nothing from it in a live server, which means the one
			-- place every Shared/Logger.lua line surfaces is unreachable for exactly the people who
			-- need to read it. SetCore("DevConsoleVisible") carries no such permission gate.
			--
			-- pcall'd because SetCore is documented to error if the CoreGui script that registers the
			-- "DevConsoleVisible" handler has not bound yet -- a real possibility on a very early
			-- keypress. Failing to open a debug panel must never take down the input handler that also
			-- owns the dev-menu toggle.
			local ok, errorMessage = pcall(function()
				StarterGui:SetCore("DevConsoleVisible", true)
			end)
			if ok then
				logger:debug("Developer console opened")
			else
				logger:warn("Developer console could not be opened", { errorMessage = tostring(errorMessage) })
			end
		end
	end)

	content.SpawnDummyRequested:Connect(function()
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

	content.SpawnBotRequested:Connect(function(presetName: string)
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

	content.RollRareEmoteRequested:Connect(function()
		logger:debug("RollRareEmoteRequested received")
		invokeAndReport(handle, function()
			local rollEmoteRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.RollEmote)
			return rollEmoteRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuRollEmoteResult
			logger:debug("RollEmote result received", { success = result.Success, emoteId = result.EmoteId })
			return describeRollEmoteResult(result)
		end)
	end)

	content.SetHealthRequested:Connect(function(health: number)
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

	content.SetGodmodeRequested:Connect(function(enabled: boolean)
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

	content.SetFlightRequested:Connect(function(enabled: boolean)
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

	content.SetFlightCollideRequested:Connect(function(enabled: boolean)
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

	content.SetFrozenRequested:Connect(function(enabled: boolean)
		logger:debug("SetFrozenRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setFrozenRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetFrozen)
			return setFrozenRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetTargetFrozen result received", { success = result.Success, reason = result.Reason })
			return describeActionResult(if enabled then "Frozen on" else "Frozen off", result)
		end)
	end)

	content.SetInvisibleRequested:Connect(function(enabled: boolean)
		logger:debug("SetInvisibleRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setInvisibleRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetInvisible)
			return setInvisibleRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetTargetInvisible result received", { success = result.Success, reason = result.Reason })
			return describeActionResult(if enabled then "Invisible on" else "Invisible off", result)
		end)
	end)

	content.SetSpeedMultiplierRequested:Connect(function(multiplier: number)
		logger:debug("SetSpeedMultiplierRequested received", { multiplier = multiplier })
		invokeAndReport(handle, function()
			local setSpeedMultiplierRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetTargetSpeedMultiplier)
			return setSpeedMultiplierRemote:InvokeServer(multiplier)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug(
				"SetTargetSpeedMultiplier result received",
				{ success = result.Success, reason = result.Reason }
			)
			return describeActionResult(`Speed x{multiplier}`, result)
		end)
	end)

	content.TeleportToTargetRequested:Connect(function()
		logger:debug("TeleportToTargetRequested received")
		invokeAndReport(handle, function()
			local teleportToTargetRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.TeleportToTarget)
			return teleportToTargetRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("TeleportToTarget result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Teleport to target", result)
		end)
	end)

	content.BringTargetRequested:Connect(function()
		logger:debug("BringTargetRequested received")
		invokeAndReport(handle, function()
			local bringTargetRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.BringTarget)
			return bringTargetRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("BringTarget result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Bring target", result)
		end)
	end)

	content.TeleportToCoordinatesRequested:Connect(function(x: number, y: number, z: number)
		logger:debug("TeleportToCoordinatesRequested received", { x = x, y = y, z = z })
		invokeAndReport(handle, function()
			local teleportToCoordinatesRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.TeleportToCoordinates)
			return teleportToCoordinatesRemote:InvokeServer(x, y, z)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("TeleportToCoordinates result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Teleport to coordinates", result)
		end)
	end)

	content.ForceRespawnTargetRequested:Connect(function()
		logger:debug("ForceRespawnTargetRequested received")
		invokeAndReport(handle, function()
			local forceRespawnTargetRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ForceRespawnTarget)
			return forceRespawnTargetRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("ForceRespawnTarget result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Force respawn", result)
		end)
	end)

	content.BroadcastAnnouncementRequested:Connect(function(message: string)
		logger:debug("BroadcastAnnouncementRequested received", { length = #message })
		invokeAndReport(handle, function()
			local broadcastAnnouncementRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.BroadcastAnnouncement)
			return broadcastAnnouncementRemote:InvokeServer(message)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("BroadcastAnnouncement result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Announcement", result)
		end)
	end)

	content.ShutdownServerRequested:Connect(function()
		logger:debug("ShutdownServerRequested received")
		invokeAndReport(handle, function()
			local shutdownServerRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ShutdownServer)
			return shutdownServerRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("ShutdownServer result received", { success = result.Success, reason = result.Reason })
			return describeShutdownResult(result)
		end)
	end)

	content.InstantRestartServerRequested:Connect(function()
		logger:debug("InstantRestartServerRequested received")
		invokeAndReport(handle, function()
			local instantRestartServerRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.InstantRestartServer)
			return instantRestartServerRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("InstantRestartServer result received", { success = result.Success, reason = result.Reason })
			return describeInstantRestartResult(result)
		end)
	end)

	-- Server-wide, not per-target -- unlike SetGodmodeRequested/SetFrozenRequested/etc. above, there's
	-- no Humanoid Attribute reflecting truth back, so content.HitboxDebugActive is set directly from
	-- this call's own result (falling back to the pre-toggle value on failure/error, never silently
	-- assuming the request succeeded).
	content.SetHitboxDebugRequested:Connect(function(enabled: boolean)
		logger:debug("SetHitboxDebugRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setHitboxDebugRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetHitboxDebug)
			return setHitboxDebugRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuHitboxDebugResult
			logger:debug("SetHitboxDebug result received", { success = result.Success, reason = result.Reason })
			if result.Success and result.Enabled ~= nil then
				content.HitboxDebugActive:set(result.Enabled)
			end
			return describeActionResult(
				if enabled then "Hitboxes visible" else "Hitboxes hidden",
				{ Success = result.Success, Reason = result.Reason }
			)
		end)
	end)

	-- Spectate (Client/DevMenu/SpectateController.lua) -- toggles against currentResolvedTarget (the
	-- SAME resolution setTarget above already tracks for the Admin tab's live display), never a
	-- second independent resolution. A no-op with a status message if nothing is currently resolved
	-- (should be unreachable in practice -- setTarget(nil) at Start() already seeds it to the local
	-- player -- but guarded rather than assumed).
	content.SpectateLockedTargetRequested:Connect(function()
		logger:debug("SpectateLockedTargetRequested received")
		if SpectateController.IsSpectating() then
			SpectateController.Stop()
			content.SpectatingActive:set(false)
			setStatus(handle, "Spectate stopped.")
			return
		end

		local target = currentResolvedTarget
		if not target or target == localPlayer then
			setStatus(handle, "Failed: no target locked on.")
			return
		end

		SpectateController.Start(target)
		content.SpectatingActive:set(true)
		setStatus(handle, `Spectating {target.Name}.`)
	end)

	-- "Players" tab roster -- eager fetch at Start() (same trade-off the three tuner fetches and the
	-- Reports tab already accept: pay one round trip even if the admin never opens this tab), then
	-- wire Refresh and every per-row action.
	local function formatRosterEntry(entry: Types.PlayerRosterEntry): DevMenuModule.PlayerRosterRowDisplay
		local snapshot = entry.Snapshot
		local healthText = if snapshot
			then `HP {math.floor(snapshot.Health)}/{math.floor(snapshot.MaxHealth)}`
			else "HP --"
		local postureText = if snapshot
			then `Posture {math.floor(snapshot.Posture)}/{math.floor(snapshot.MaxPosture)}`
			else "Posture --"
		return {
			UserId = entry.UserId,
			Name = entry.Name,
			HealthText = healthText,
			PostureText = postureText,
			PingText = `{math.floor(entry.Ping)}ms`,
			Muted = entry.Muted,
			SuspectedCheater = entry.SuspectedCheater,
		}
	end

	-- Sidebar stats header (DevMenu_GetSidebarStats) -- eager fetch at Start() (same trade-off
	-- fetchPlayers/the three tuner fetches/the Reports tab already accept), re-fetched after a
	-- successful Flag/Unflag action below (mirroring how MutePlayerRequested's own handler already
	-- re-triggers fetchPlayers() on success).
	local function fetchSidebarStats(): ()
		local getSidebarStatsRemote =
			NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetSidebarStats)
		local ok, resultOrError = pcall(function()
			return getSidebarStatsRemote:InvokeServer()
		end)

		if not ok then
			logger:error("GetSidebarStats request errored", { errorMessage = tostring(resultOrError) })
			return
		end

		local result = resultOrError :: Types.DevMenuSidebarStatsResult
		if not result.Success then
			logger:warn("GetSidebarStats rejected", { reason = result.Reason })
			return
		end

		sidebar.BugReportOpenCount:set(result.BugReportOpenCount)
		sidebar.SuspectedCheaterCount:set(result.SuspectedCheaterCount)
		logger:debug("GetSidebarStats loaded", {
			bugReportOpenCount = result.BugReportOpenCount,
			suspectedCheaterCount = result.SuspectedCheaterCount,
		})
	end

	task.spawn(fetchSidebarStats)

	-- HitboxDebugState is server-wide (not per-target), so unlike Godmode/Frozen/etc. above there's
	-- no Humanoid Attribute to seed content.HitboxDebugActive from -- fetched once on Start(), same
	-- eager-fetch trade-off fetchSidebarStats just above accepts.
	local function fetchHitboxDebugState(): ()
		local getHitboxDebugRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetHitboxDebug)
		local ok, resultOrError = pcall(function()
			return getHitboxDebugRemote:InvokeServer()
		end)

		if not ok then
			logger:error("GetHitboxDebug request errored", { errorMessage = tostring(resultOrError) })
			return
		end

		local result = resultOrError :: Types.DevMenuHitboxDebugResult
		if not result.Success or result.Enabled == nil then
			logger:warn("GetHitboxDebug rejected", { reason = result.Reason })
			return
		end

		content.HitboxDebugActive:set(result.Enabled)
		logger:debug("GetHitboxDebug loaded", { enabled = result.Enabled })
	end

	task.spawn(fetchHitboxDebugState)

	-- Passive "a newer version has been published" banner (Server/Systems/VersionWatchSystem.lua) --
	-- fetched once on Start(), same eager-fetch trade-off fetchSidebarStats/fetchHitboxDebugState
	-- above accept. Pre-formats the banner text here (this screen's own "already-computed value in,
	-- presentation out" rule) rather than handing ContentArea the raw version numbers --
	-- content.VersionBannerText is left nil (nothing shown) both before this resolves and for the
	-- ordinary case where no newer version exists.
	local function fetchServerVersionInfo(): ()
		local getServerVersionInfoRemote =
			NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetServerVersionInfo)
		local ok, resultOrError = pcall(function()
			return getServerVersionInfoRemote:InvokeServer()
		end)

		if not ok then
			logger:error("GetServerVersionInfo request errored", { errorMessage = tostring(resultOrError) })
			return
		end

		local result = resultOrError :: Types.DevMenuServerVersionInfoResult
		if not result.Success then
			logger:warn("GetServerVersionInfo rejected", { reason = result.Reason })
			return
		end

		if result.NewerVersionAvailable then
			content.VersionBannerText:set(
				`A newer version has been published (this server: v{result.BootPlaceVersion}, latest seen: v{result.LatestKnownPlaceVersion}). Consider restarting.`
			)
		end
		logger:debug("GetServerVersionInfo loaded", {
			bootPlaceVersion = result.BootPlaceVersion,
			latestKnownPlaceVersion = result.LatestKnownPlaceVersion,
			newerVersionAvailable = result.NewerVersionAvailable,
		})
	end

	task.spawn(fetchServerVersionInfo)

	local function fetchPlayers(): ()
		if peek(sidebar.PlayersLoading) then
			return
		end
		sidebar.PlayersLoading:set(true)

		local listPlayersRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListPlayers)
		local ok, resultOrError = pcall(function()
			return listPlayersRemote:InvokeServer()
		end)

		sidebar.PlayersLoading:set(false)

		if not ok then
			logger:error("ListPlayers request errored", { errorMessage = tostring(resultOrError) })
			return
		end

		local result = resultOrError :: Types.DevMenuListPlayersResult
		if not result.Success or not result.Players then
			logger:warn("ListPlayers rejected", { reason = result.Reason })
			return
		end

		local displays: { DevMenuModule.PlayerRosterRowDisplay } = {}
		for index, entry in ipairs(result.Players) do
			displays[index] = formatRosterEntry(entry)
		end
		sidebar.PlayersDisplay:set(displays)
		logger:debug("ListPlayers loaded", { count = #result.Players })
	end

	task.spawn(fetchPlayers)

	sidebar.RefreshPlayersRequested:Connect(function()
		logger:debug("RefreshPlayersRequested received")
		task.spawn(fetchPlayers)
	end)

	sidebar.KickPlayerRequested:Connect(function(targetUserId: number)
		logger:debug("KickPlayerRequested received", { targetUserId = targetUserId })
		local reason = peek(sidebar.ActionReasonText)
		invokeAndReport(handle, function()
			local kickPlayerRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.KickPlayer)
			return kickPlayerRemote:InvokeServer(targetUserId, reason)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("KickPlayer result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Kick", result)
		end)
	end)

	sidebar.BanPlayerRequested:Connect(function(targetUserId: number)
		logger:debug("BanPlayerRequested received", { targetUserId = targetUserId })
		local reasonInput = peek(sidebar.ActionReasonText)
		local reason = if #reasonInput > 0 then reasonInput else "Banned by an administrator."
		invokeAndReport(handle, function()
			local banPlayerRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.BanPlayer)
			-- No ExpiresAt UI in this pass -- every Ban from this panel is permanent (nil expiry). See
			-- DevMenuHandle.Sidebar's own header comment.
			return banPlayerRemote:InvokeServer(targetUserId, reason, nil)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("BanPlayer result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Ban", result)
		end)
	end)

	sidebar.MutePlayerRequested:Connect(function(targetUserId: number, enabled: boolean)
		logger:debug("MutePlayerRequested received", { targetUserId = targetUserId, enabled = enabled })
		invokeAndReport(handle, function()
			local mutePlayerRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.MutePlayer)
			return mutePlayerRemote:InvokeServer(targetUserId, enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("MutePlayer result received", { success = result.Success, reason = result.Reason })
			if result.Success then
				task.spawn(fetchPlayers)
			end
			return describeActionResult(if enabled then "Mute" else "Unmute", result)
		end)
	end)

	-- Irreversible -- see Sidebar.lua's own arm/confirm friction (isDataResetArmed) for the
	-- client-side "are you sure" step; this handler fires only once that's already resolved. No
	-- reason text (unlike Kick/Ban/SetSuspectedCheater below) -- this is a debug/testing tool with
	-- no target-facing message, matching MutePlayerRequested's own simplicity above. No re-fetch on
	-- success either -- none of PlayerRosterRowDisplay's fields (Health/Posture/Ping/Muted/
	-- SuspectedCheater) are sourced from the wiped profile, so there's nothing stale to refresh.
	sidebar.ResetPlayerDataRequested:Connect(function(targetUserId: number)
		logger:debug("ResetPlayerDataRequested received", { targetUserId = targetUserId })
		invokeAndReport(handle, function()
			local resetPlayerDataRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ResetTargetPlayerData)
			return resetPlayerDataRemote:InvokeServer(targetUserId)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("ResetTargetPlayerData result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Reset player data", result)
		end)
	end)

	sidebar.SetSuspectedCheaterRequested:Connect(function(targetUserId: number, enabled: boolean)
		logger:debug("SetSuspectedCheaterRequested received", { targetUserId = targetUserId, enabled = enabled })
		local reason = peek(sidebar.ActionReasonText)
		invokeAndReport(handle, function()
			local setSuspectedCheaterRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetSuspectedCheater)
			return setSuspectedCheaterRemote:InvokeServer(targetUserId, enabled, reason)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SetSuspectedCheater result received", { success = result.Success, reason = result.Reason })
			if result.Success then
				-- Both re-fetched: the roster row's own Flagged look (fetchPlayers) and the sidebar's
				-- Suspected-Cheaters count (fetchSidebarStats) both changed as a result of this one
				-- action -- same "re-fetch on success" pattern MutePlayerRequested's own handler above
				-- already uses for the roster.
				task.spawn(fetchPlayers)
				task.spawn(fetchSidebarStats)
			end
			return describeActionResult(
				if enabled then "Flag suspected cheater" else "Unflag suspected cheater",
				result
			)
		end)
	end)

	sidebar.ResetPlayerCombatStateRequested:Connect(function(targetUserId: number)
		logger:debug("ResetPlayerCombatStateRequested received", { targetUserId = targetUserId })
		invokeAndReport(handle, function()
			local resetCombatStateRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ResetTargetCombatState)
			return resetCombatStateRemote:InvokeServer(targetUserId)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("ResetTargetCombatState result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Reset combat state", result)
		end)
	end)

	sidebar.TeleportToPlayerRequested:Connect(function(targetUserId: number)
		logger:debug("TeleportToPlayerRequested received", { targetUserId = targetUserId })
		invokeAndReport(handle, function()
			local teleportToTargetRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.TeleportToTarget)
			return teleportToTargetRemote:InvokeServer(targetUserId)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("TeleportToTarget (row) result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Teleport to player", result)
		end)
	end)

	-- Flight-feel tuner: fetch every tunable field ONCE and wire the cycle/adjust/reset signals.
	-- task.spawn since InvokeServer yields and Start() shouldn't stall the rest of the client boot
	-- sequence behind it (Main.client.lua's own convention for yielding work, e.g. bindLocalCharacter
	-- in CombatClient.lua). The only DevMenu tuning tool left of this shape -- Hitbox Timing/
	-- Standalone Attacks moved to the Move Editor's "Default" moves section, see
	-- Client/MoveEditor/MoveEditorClient.lua. Adjust fires a FRACTIONAL delta straight through (no
	-- per-field name needed -- there's only ever one number being adjusted for whichever field is
	-- currently selected).
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

	content.CycleFlightTuningPrevRequested:Connect(function()
		if #flightTuningFields == 0 then
			return
		end
		flightTuningSelectedIndex = if flightTuningSelectedIndex <= 1
			then #flightTuningFields
			else flightTuningSelectedIndex - 1
		renderFlightTuning(handle)
	end)

	content.CycleFlightTuningNextRequested:Connect(function()
		if #flightTuningFields == 0 then
			return
		end
		flightTuningSelectedIndex = if flightTuningSelectedIndex >= #flightTuningFields
			then 1
			else flightTuningSelectedIndex + 1
		renderFlightTuning(handle)
	end)

	content.AdjustFlightTuningRequested:Connect(function(deltaFraction: number)
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

	content.ResetFlightTuningRequested:Connect(function()
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

	content.LoadFirstReportsRequested:Connect(function()
		logger:debug("LoadFirstReportsRequested received")
		task.spawn(function()
			fetchReports(handle, "First")
		end)
	end)

	content.LoadMoreReportsRequested:Connect(function()
		logger:debug("LoadMoreReportsRequested received")
		task.spawn(function()
			fetchReports(handle, "Next")
		end)
	end)

	content.UpdateReportStatusRequested:Connect(function(reportId: string, newStatus: string)
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

	-- Triage mutations added alongside UpdateReportStatusRequested above -- same "patch the one
	-- changed record in place, then re-render" shape, just for a different mutation each.
	content.SetReportPriorityRequested:Connect(function(reportId: string, newPriority: string)
		logger:debug("SetReportPriorityRequested received", { id = reportId, priority = newPriority })
		invokeAndReport(handle, function()
			local setPriorityRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetBugReportPriority)
			return setPriorityRemote:InvokeServer(reportId, newPriority)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuBugReportMutationResult
			if result.Success and result.Report then
				for index, record in ipairs(reportRecords) do
					if record.Id == result.Report.Id then
						reportRecords[index] = result.Report
						break
					end
				end
				renderReports(handle)
				return "Report priority updated."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	content.AssignReportRequested:Connect(function(reportId: string, assign: boolean)
		logger:debug("AssignReportRequested received", { id = reportId, assign = assign })
		invokeAndReport(handle, function()
			local assignRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.AssignBugReport)
			return assignRemote:InvokeServer(reportId, assign)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuBugReportMutationResult
			if result.Success and result.Report then
				for index, record in ipairs(reportRecords) do
					if record.Id == result.Report.Id then
						reportRecords[index] = result.Report
						break
					end
				end
				renderReports(handle)
				return if assign then "Report claimed." else "Report released."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	content.AddReportNoteRequested:Connect(function(reportId: string, text: string)
		logger:debug("AddReportNoteRequested received", { id = reportId })
		invokeAndReport(handle, function()
			local addNoteRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.AddBugReportNote)
			return addNoteRemote:InvokeServer(reportId, text)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuBugReportMutationResult
			if result.Success and result.Report then
				for index, record in ipairs(reportRecords) do
					if record.Id == result.Report.Id then
						reportRecords[index] = result.Report
						break
					end
				end
				renderReports(handle)
				return "Note added."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	-- Unlike the three handlers above, JumpToReporter never mutates the report record itself -- it
	-- just moves the requesting admin's own character, so there's nothing to patch into
	-- reportRecords/re-render here.
	content.JumpToReporterRequested:Connect(function(reportId: string)
		logger:debug("JumpToReporterRequested received", { id = reportId })
		invokeAndReport(handle, function()
			local jumpToReporterRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.JumpToReporter)
			return jumpToReporterRemote:InvokeServer(reportId)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("JumpToReporter result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Jump to reporter", result)
		end)
	end)

	logger:debug("DevMenuClient bindings connected")
end

-- Public entry point, called once from Main.client.lua's boot sequence.
--
-- Returns immediately and does the real work on its own thread, because the authorization check is
-- now a server round-trip (see requestServerAuthorization above) and Main.client.lua calls this
-- synchronously with several more client modules queued behind it -- BugReportClient and
-- AnnouncementClient among them, both of which every player needs. Blocking the boot sequence on a
-- dev-tooling handshake would delay real gameplay UI for everyone to gate a menu almost nobody can
-- open.
--
-- Consequence worth knowing: for an authorized admin, the DevMenuToggle keybind binds one round-trip
-- after join rather than instantly, so a keypress in the first few hundred milliseconds of a session
-- does nothing. Acceptable for dev tooling; the alternative was keeping the whitelist replicated.
function DevMenuClient.Start(handle: DevMenuHandle): ()
	task.spawn(function()
		if not requestServerAuthorization() then
			logger:debug("DevMenuClient not started: server did not authorize this client")
			return
		end
		-- The parkour debug overlay (F6) runs on this same answer rather than asking for its own --
		-- one authorization round-trip per session, one whitelist to maintain. Granted here rather
		-- than inside startDevMenu because it is not part of the menu; it just shares the gate. See
		-- ParkourDebug.SetAuthorized for why a client-side grant is safe for a read-only overlay.
		ParkourDebug.SetAuthorized(true)
		startDevMenu(handle)
	end)
end

return DevMenuClient
