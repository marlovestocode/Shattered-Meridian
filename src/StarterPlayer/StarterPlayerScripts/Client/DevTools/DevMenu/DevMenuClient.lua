--!strict
--[[
	DevMenuClient.lua

	Owns: the local player's dev-menu UX -- keybind toggle (resolved through
	Client/Input/KeybindManager.lua rather than a hardcoded key) and translating the DevMenu screen's
	action signals into NetworkBridge RemoteFunction calls. This module holds NO copy of the admin whitelist: it asks the
	server whether to start at all (see requestServerAuthorization below), because that list lives in
	ServerScriptService/Server/Config/AdminConfig.lua and no longer replicates to clients. Gating here
	remains a UX convenience either way -- skip connecting input for a non-dev so the menu never even
	appears -- and is never trusted as real authorization: DevMenuSystem.lua re-checks the whitelist
	server-side on every request regardless of what this module decides, per
	luau-coding-standards.md's server/client split rule.

	No longer binds "OpenDevConsole" (F5) -- that used to open Roblox's own native developer console
	via StarterGui:SetCore("DevConsoleVisible") from right here, since this was already the module
	that had asked the server whether this client is an admin. It moved to its own module,
	Client/DevTools/LiveConsole/LiveConsoleClient.lua, which binds F5 to a bespoke live log console instead:
	the native console only ever showed anything in Studio (Shared/Logger.lua never calls
	print()/warn() outside RunService:IsStudio() by design), so on a live server -- the one place a
	whitelisted admin actually needs it, since Roblox's own F9 shortcut only binds for accounts with
	edit access to the place -- it opened empty. See LiveConsoleClient.lua's own header for the
	replacement.

	Also drives the screen's TargetNameDisplay/GodmodeActive/FlightActive (see watchTarget below):
	always the local player now -- DevMenuSystem.resolveActionTarget's lock-on lookup (and the
	Combat_LockOnChanged RemoteEvent it rode in on) was removed alongside the rest of the combat
	system, so there is no longer a way to resolve an admin action's target to anyone but the calling
	admin. watchTarget still watches that target's Humanoid Godmode/Flying Attributes
	(AdminActionSystem.SetGodmode/SetFlying both mirror their boolean onto a replicated Attribute) the
	same way Client/Flight/FlightController.lua already watches its own Flying attribute -- this is
	real server-replicated state, not a locally-guessed toggle.

	Screens/DevTools/DevMenu/init.lua's Sidebar/ContentArea split (see that module's own header) means every
	field this module used to reach as a flat `handle.X` now lives on `handle.Sidebar.X` (the
	"Players" tab roster) or `handle.Content.Y` (every other tab) -- `handle.StatusText`/`handle.IsOpen`
	stay on the root handle itself. Every helper function below that only needs Content or Sidebar
	still takes the full DevMenuHandle (unchanged signatures) and reaches into the one sub-handle it
	actually needs, rather than every call site being rewritten to pass the narrower type around.

	Does not own: whether a spawn request is actually allowed (DevMenuSystem.lua), or the dev menu
	panel itself (UI/Screens/DevTools/DevMenu/init.lua) -- this module only drives that screen's handle from
	outside, the same "screen exposes state/signals, client module drives from outside" pattern
	CombatClient.lua already uses for CombatFeedback.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local VehicleConstants = require(ReplicatedStorage.Shared.Vehicle.VehicleConstants)
local VehicleTypes = require(ReplicatedStorage.Shared.Vehicle.VehicleTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local RemoteInvoker = require(script.Parent.Parent.Parent.Network.RemoteInvoker)
local DevMenuModule = require(script.Parent.Parent.Parent.UI.Screens.DevTools.DevMenu)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local ParkourDebug = require(script.Parent.Parent.Parent.Parkour.ParkourDebug)
local SpectateController = require(script.Parent.SpectateController)
local Chrome = require(script.Parent.Parent.Parent.UI.Shell.Chrome)

type DevMenuHandle = DevMenuModule.DevMenuHandle

local peek = Fusion.peek

local logger = Logger.scope("DevMenuClient")

local STATUS_CLEAR_DELAY = Constants.Debug.DevMenu.StatusClearDelaySeconds

local DevMenuClient = {}

local function describeRollEmoteResult(result: Types.DevMenuRollEmoteResult): string
	if result.Success then
		return `Emote rolled: {result.EmoteId or "?"}.`
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

local function describeGrantRerollsResult(result: Types.DevMenuGrantRerollsResult): string
	if result.Success then
		return `Rerolls granted -- {result.RerollsRemaining or 0} held.`
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
	local ok, resultOrError = RemoteInvoker.Invoke(listRemote, cursorMode)

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

-- Vehicles tab ------------------------------------------------------------------------------------
--
-- Every function here exists to turn Server/Systems/VehicleManager.lua's one snapshot into the
-- already-formatted rows Screens/DevTools/DevMenu/VehiclesTab.lua renders -- this module owns all number ->
-- string formatting for that tab, per that screen's own "already-computed value in, presentation
-- out" boundary.

-- "2m 14s" / "9s". Coarse on purpose: an age is read to answer "is this the one I just spawned",
-- which never needs sub-second precision, and a ticking millisecond readout in a list that only
-- refreshes on demand would be a lie the moment it stopped updating.
local function formatVehicleAge(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	if whole < 60 then
		return `{whole}s`
	end
	return `{whole // 60}m {whole % 60}s`
end

local function formatVehiclePosition(position: Vector3): string
	return string.format("%d, %d, %d", position.X, position.Y, position.Z)
end

-- The whole tab's state from one snapshot -- see VehicleConstants.RemoteNames.GetState on why this is
-- a single round trip rather than four. `reload` re-scans the registry server-side first, which is
-- what makes a model added in Studio appear without a server restart.
local function fetchVehicleState(handle: DevMenuHandle, reload: boolean): ()
	local vehicles = handle.Content.Vehicles
	if peek(vehicles.Loading) then
		return
	end
	vehicles.Loading:set(true)

	local remoteName = if reload
		then VehicleConstants.RemoteNames.ReloadRegistry
		else VehicleConstants.RemoteNames.GetState
	local ok, resultOrError = RemoteInvoker.Invoke(NetworkBridge.GetRemoteFunction(remoteName))

	vehicles.Loading:set(false)

	if not ok then
		logger:error("Vehicle state request errored", { errorMessage = tostring(resultOrError) })
		vehicles.RegistryText:set("Registry: request failed.")
		return
	end

	local result = resultOrError :: VehicleTypes.VehicleStateResult
	if not result.Success or not result.Catalog or not result.Live or not result.Berths then
		logger:warn("Vehicle state rejected", { reason = result.Reason })
		vehicles.RegistryText:set(`Registry: rejected ({result.Reason or "Unknown"}).`)
		return
	end

	local catalog = result.Catalog
	local liveVehicles = result.Live
	local berths = result.Berths

	vehicles.RegistryText:set(
		`Registry: {result.RegistryPath or "<unknown>"} -- {#catalog} vehicle(s), {#liveVehicles} live.`
	)

	local rejectionLines: { string } = {}
	for _, rejection in result.Rejections or {} do
		table.insert(rejectionLines, `{rejection.Path}: {rejection.Reason}`)
	end
	vehicles.RejectionText:set(
		if #rejectionLines > 0 then "Rejected -- " .. table.concat(rejectionLines, "; ") else nil
	)

	local catalogRows: { DevMenuModule.VehicleCatalogRowDisplay } = {}
	for index, entry in catalog do
		catalogRows[index] = {
			Id = entry.Id,
			NameText = entry.DisplayName,
			DetailText = `{entry.Kind} - {entry.FootprintStuds} studs - {entry.LiveCount}/{entry.MaxLive} live`,
			AtCapacity = entry.LiveCount >= entry.MaxLive,
		}
	end
	vehicles.CatalogDisplay:set(catalogRows)

	local liveRows: { DevMenuModule.VehicleLiveRowDisplay } = {}
	for index, info in liveVehicles do
		local where = if info.BerthName then `berth {info.BerthName}` else formatVehiclePosition(info.Position)
		local occupied = if info.Occupied then " - occupied" else ""
		liveRows[index] = {
			InstanceId = info.InstanceId,
			NameText = info.DisplayName,
			DetailText = `{info.OwnerName} - {formatVehicleAge(info.AgeSeconds)} - {where}{occupied}`,
		}
	end
	vehicles.LiveDisplay:set(liveRows)

	local berthRows: { DevMenuModule.VehicleBerthRowDisplay } = {}
	for index, berth in berths do
		local accepts = if #berth.Accepts > 0 then ` ({table.concat(berth.Accepts, "/")})` else ""
		local occupied = if berth.Occupied then " - occupied" else ""
		berthRows[index] = {
			Name = berth.Name,
			Label = `{berth.Name}{accepts}{occupied}`,
		}
	end
	vehicles.BerthDisplay:set(berthRows)

	logger:debug("Vehicle state loaded", { catalog = #catalog, live = #liveVehicles, berths = #berths })
end

-- Module-local, like every other piece of this module's session state (reportRecords, hitboxStages):
-- there is exactly one Start() per client, so a second "has this been seeded" flag per handle would
-- be tracking a distinction that cannot arise.
local vehicleStateSeeded = false

-- The first-open read. Idempotent and non-yielding at the call site, so the keybind handler can call
-- it unconditionally on every open without either checking the flag itself or blocking the input
-- thread on a round trip.
local function seedVehicleStateOnce(handle: DevMenuHandle): ()
	if vehicleStateSeeded then
		return
	end
	vehicleStateSeeded = true
	task.spawn(function()
		fetchVehicleState(handle, false)
	end)
end

-- Target-tracking state for the Admin tab's live display (TargetNameDisplay/GodmodeActive/
-- FlightActive) -- module-local like hitboxStages above, since this module has exactly one
-- long-lived Start() call per client session. attributeTrove watches whichever Humanoid currently
-- belongs to the resolved target across all six tracked Attributes as one scope -- rebindAttributeConnections
-- and watchTarget's own "target has no character" branch both need to drop every one of them at once,
-- which a Trove makes a single :Clean() instead of six hand-paired disconnect-and-nil sites.
-- targetCharacterAddedConnection rebinds them across that target's own respawns (mirroring
-- FlightController.lua's own BindCharacter, just for a possibly-other player instead of always the
-- local one).
local attributeTrove = Trove.New()
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
	attributeTrove:Clean()

	local content = handle.Content

	content.GodmodeActive:set(humanoid:GetAttribute(Constants.Attributes.Godmode) == true)
	content.FlightActive:set(humanoid:GetAttribute(Constants.Attributes.Flying) == true)
	content.CollideActive:set(humanoid:GetAttribute(Constants.Attributes.FlyCollide) == true)
	content.FrozenActive:set(humanoid:GetAttribute(Constants.Attributes.Frozen) == true)
	content.InvisibleActive:set(humanoid:GetAttribute(Constants.Attributes.Invisible) == true)
	content.SpeedMultiplierActive:set((humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier) :: number?) or 1)

	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.Godmode), function()
		content.GodmodeActive:set(humanoid:GetAttribute(Constants.Attributes.Godmode) == true)
	end)
	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.Flying), function()
		content.FlightActive:set(humanoid:GetAttribute(Constants.Attributes.Flying) == true)
	end)
	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.FlyCollide), function()
		content.CollideActive:set(humanoid:GetAttribute(Constants.Attributes.FlyCollide) == true)
	end)
	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.Frozen), function()
		content.FrozenActive:set(humanoid:GetAttribute(Constants.Attributes.Frozen) == true)
	end)
	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.Invisible), function()
		content.InvisibleActive:set(humanoid:GetAttribute(Constants.Attributes.Invisible) == true)
	end)
	attributeTrove:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.SpeedMultiplier), function()
		content.SpeedMultiplierActive:set((humanoid:GetAttribute(Constants.Attributes.SpeedMultiplier) :: number?) or 1)
	end)
end

-- Watches `targetPlayer` (whichever player DevMenuSystem.resolveActionTarget would currently
-- resolve to -- see setTarget below, always the local player now) for its Godmode/Flying Humanoid
-- Attributes. Called once at Start().
local function watchTarget(handle: DevMenuHandle, targetPlayer: Player): ()
	if targetCharacterAddedConnection then
		targetCharacterAddedConnection:Disconnect()
		targetCharacterAddedConnection = nil
	end

	local function onCharacterAdded(character: Model): ()
		local humanoidInstance = CharacterUtil.AwaitHumanoid(character)
		if humanoidInstance then
			rebindAttributeConnections(handle, humanoidInstance)
		end
	end

	if targetPlayer.Character then
		onCharacterAdded(targetPlayer.Character)
	else
		attributeTrove:Clean()
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
-- The invoke -> describe -> set-status shape, which is Client/Network/RemoteInvoker.CallAndReport's
-- with two things bolted on that are this screen's own: the "Spawning..." pre-status every action
-- here shows while it waits, and setStatus's own auto-clear timer.
--
-- CallAndReport rather than InvokeAndReport because every call site below builds a CLOSURE, and most
-- of them resolve their remote inside it -- NetworkBridge.GetRemoteFunction asserts on a failed
-- lookup, so hoisting that out to pass a RemoteFunction would move the assert outside the protected
-- region. All thirty-nine call sites are unchanged.
local function invokeAndReport(handle: DevMenuHandle, invoke: () -> unknown, describe: (unknown) -> string): ()
	handle.StatusText:set("Spawning...")
	RemoteInvoker.CallAndReport(function(message: string)
		setStatus(handle, message)
	end, "DevMenu", invoke, describe)
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
	-- The remote is resolved INSIDE the pcall on purpose, so this stays a bare pcall rather than
	-- RemoteInvoker.Invoke: NetworkBridge.GetRemoteFunction asserts on a failed lookup, and hoisting
	-- it out to pass a resolved RemoteFunction would move that assert outside the protected region --
	-- turning a logged failure into a thrown one on the very path that decides whether this panel is
	-- allowed to open at all.
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

local function startDevMenu(handle: DevMenuHandle, chrome: Chrome.ChromeHandle): ()
	local localPlayer = Players.LocalPlayer
	local sidebar = handle.Sidebar
	local content = handle.Content

	logger:info("DevMenuClient.Start called", { userId = localPlayer.UserId })

	-- See reportsLocalUserId's own declaration -- must be set before the Reports tab's eager fetch
	-- below runs, so the very first render already knows which reports (if any) this admin holds.
	reportsLocalUserId = localPlayer.UserId

	-- Target tracking for the Admin tab's live display -- resolves exactly the way
	-- DevMenuSystem.resolveActionTarget does server-side: always the local player. The lock-on target
	-- resolution this used to layer on top of (via the Combat_LockOnChanged broadcast) was removed
	-- alongside the rest of the combat system -- see this file's own header.
	local function setTarget(): ()
		currentResolvedTarget = localPlayer
		content.TargetNameDisplay:set("Self")
		watchTarget(handle, localPlayer)
	end

	setTarget()

	-- ADOPTED: this panel had no Escape at all, so the toggle key was the only way out of it. Bound
	-- here rather than in Start below because Start holds a Lazy thunk and this needs the resolved
	-- handle -- which is also why the bind can safely assume the panel exists.
	chrome:BindEscape("DevMenu", handle.IsOpen, function()
		handle.IsOpen:set(false)
		logger:debug("Dev menu closed on Escape")
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("DevMenuToggle", input) then
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			if nowOpen then
				seedVehicleStateOnce(handle)
			end
			logger:debug("Dev menu toggled", { open = nowOpen })
		end
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

	content.GrantBloodlineRerollsRequested:Connect(function()
		logger:debug("GrantBloodlineRerollsRequested received")
		invokeAndReport(handle, function()
			local grantRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GrantBloodlineRerolls)
			return grantRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuGrantRerollsResult
			logger:debug("GrantBloodlineRerolls result received", { success = result.Success })
			return describeGrantRerollsResult(result)
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

	content.SetHitboxDebugRequested:Connect(function(enabled: boolean)
		logger:debug("SetHitboxDebugRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setHitboxDebugRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetHitboxDebug)
			return setHitboxDebugRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuHitboxDebugResult
			logger:debug("SetHitboxDebug result received", { success = result.Success, enabled = result.Enabled })
			-- Refreshed from what the server reports actually took effect, never optimistically from
			-- the press -- see HitboxDebugActive's own header on why (this is a server-wide toggle,
			-- not a personal one, so "did it work" is a real question a refused request can answer no
			-- to).
			if result.Success and result.Enabled ~= nil then
				content.HitboxDebugActive:set(result.Enabled)
			end
			return describeActionResult(if enabled then "Hitboxes visible" else "Hitboxes hidden", result)
		end)
	end)

	-- Debug dummy (Spawn tab, Server/Systems/DebugDummySystem.lua) -- SpawnDebugDummyRequested/
	-- DespawnAllDebugDummiesRequested are fire-and-forget, same "invokeAndReport, status text only"
	-- shape as RollRareEmoteRequested above. SetDummyGuardRequested refreshes DummyGuardActive from
	-- the server's own echoed value, never optimistically from the press -- same contract
	-- SetHitboxDebugRequested's own handler already keeps for its server-wide toggle.
	content.SpawnDebugDummyRequested:Connect(function()
		logger:debug("SpawnDebugDummyRequested received")
		invokeAndReport(handle, function()
			local spawnDebugDummyRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SpawnDummy)
			return spawnDebugDummyRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SpawnDebugDummy result received", { success = result.Success, reason = result.Reason })
			if result.Success then
				content.ActiveDummyCountDisplay:set(peek(content.ActiveDummyCountDisplay) + 1)
			end
			return describeActionResult("Spawn debug dummy", result)
		end)
	end)

	content.DespawnAllDebugDummiesRequested:Connect(function()
		logger:debug("DespawnAllDebugDummiesRequested received")
		invokeAndReport(handle, function()
			local despawnAllRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.DespawnAllDebugDummies)
			return despawnAllRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("DespawnAllDebugDummies result received", { success = result.Success, reason = result.Reason })
			if result.Success then
				content.ActiveDummyCountDisplay:set(0)
			end
			return describeActionResult("Despawn all debug dummies", result)
		end)
	end)

	content.SetDummyGuardRequested:Connect(function(enabled: boolean)
		logger:debug("SetDummyGuardRequested received", { enabled = enabled })
		invokeAndReport(handle, function()
			local setDummyGuardRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SetDummyGuard)
			return setDummyGuardRemote:InvokeServer(enabled)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuDebugDummyStateResult
			logger:debug(
				"SetDummyGuard result received",
				{ success = result.Success, guardEnabled = result.GuardEnabled }
			)
			if result.Success and result.GuardEnabled ~= nil then
				content.DummyGuardActive:set(result.GuardEnabled)
			end
			if result.Success and result.ActiveCount ~= nil then
				content.ActiveDummyCountDisplay:set(result.ActiveCount)
			end
			return describeActionResult(if enabled then "Guard on" else "Guard off", result)
		end)
	end)

	-- Training bot (Spawn tab, Server/Combat/TrainingBot/TrainingBotSystem.lua) -- same fire-and-forget
	-- "invokeAndReport, status text only" shape as SpawnDebugDummyRequested above, with the active count
	-- taken from what the server reports rather than counted up locally (a spawn past MaxActive evicts).
	content.SpawnTrainingBotRequested:Connect(function(style: string, difficulty: string, weapon: string)
		logger:debug("SpawnTrainingBotRequested received", { style = style, difficulty = difficulty, weapon = weapon })
		invokeAndReport(handle, function()
			local spawnTrainingBotRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SpawnTrainingBot)
			return spawnTrainingBotRemote:InvokeServer(style, difficulty, weapon)
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuSpawnBotResult
			logger:debug("SpawnTrainingBot result received", { success = result.Success, reason = result.Reason })
			if result.Success and result.ActiveCount ~= nil then
				content.ActiveTrainingBotCountDisplay:set(result.ActiveCount)
			end
			return describeActionResult(`Spawn {style} bot ({difficulty})`, result)
		end)
	end)

	content.DespawnTrainingBotsRequested:Connect(function()
		logger:debug("DespawnTrainingBotsRequested received")
		invokeAndReport(handle, function()
			local despawnTrainingBotsRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.DespawnTrainingBots)
			return despawnTrainingBotsRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuSpawnBotResult
			logger:debug("DespawnTrainingBots result received", { success = result.Success, reason = result.Reason })
			if result.Success then
				content.ActiveTrainingBotCountDisplay:set(0)
			end
			return describeActionResult("Despawn training bots", result)
		end)
	end)

	-- Blimp Fuel System test nodes (Spawn tab, Server/Systems/ResourceGatheringSystem.SpawnDebugNode)
	-- -- fire-and-forget, same "invokeAndReport, status text only" shape as SpawnDebugDummyRequested
	-- above.
	content.SpawnCoalDepositRequested:Connect(function()
		logger:debug("SpawnCoalDepositRequested received")
		invokeAndReport(handle, function()
			local spawnCoalDepositRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SpawnCoalDeposit)
			return spawnCoalDepositRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SpawnCoalDeposit result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Spawn coal deposit", result)
		end)
	end)

	content.SpawnWaterSourceRequested:Connect(function()
		logger:debug("SpawnWaterSourceRequested received")
		invokeAndReport(handle, function()
			local spawnWaterSourceRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.SpawnWaterSource)
			return spawnWaterSourceRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("SpawnWaterSource result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Spawn water source", result)
		end)
	end)

	content.FillCarriedFuelRequested:Connect(function()
		logger:debug("FillCarriedFuelRequested received")
		invokeAndReport(handle, function()
			local fillCarriedFuelRemote =
				NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.FillCarriedFuel)
			return fillCarriedFuelRemote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: Types.DevMenuActionResult
			logger:debug("FillCarriedFuel result received", { success = result.Success, reason = result.Reason })
			return describeActionResult("Fill carried fuel", result)
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

	-- Spectate (Client/DevTools/DevMenu/SpectateController.lua) -- toggles against currentResolvedTarget (the
	-- SAME resolution setTarget above already tracks for the Admin tab's live display), never a
	-- second independent resolution. currentResolvedTarget is always the local player now (lock-on
	-- was removed alongside the rest of the combat system -- see setTarget's own header), so this
	-- always reports "no target locked on" -- left wired rather than deleted, since the guard/status
	-- shape is still correct for whatever eventually replaces target selection.
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
		local ok, resultOrError = RemoteInvoker.Invoke(getSidebarStatsRemote)

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

	-- Passive "a newer version has been published" banner (Server/Systems/VersionWatchSystem.lua) --
	-- fetched once on Start(), same eager-fetch trade-off fetchSidebarStats above accepts. Pre-formats
	-- the banner text here (this screen's own "already-computed value in,
	-- presentation out" rule) rather than handing ContentArea the raw version numbers --
	-- content.VersionBannerText is left nil (nothing shown) both before this resolves and for the
	-- ordinary case where no newer version exists.
	local function fetchServerVersionInfo(): ()
		local getServerVersionInfoRemote =
			NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetServerVersionInfo)
		local ok, resultOrError = RemoteInvoker.Invoke(getServerVersionInfoRemote)

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

	-- Swing-volume visualiser (Server/Combat/HitboxEngine.lua) -- fetched once on Start(), same
	-- eager-fetch shape as fetchServerVersionInfo above. SERVER-WIDE state, not a per-player
	-- Attribute, so this fetch (not a watched Humanoid Attribute the way Godmode/Flight refresh) is
	-- the only way this admin's own Toggle starts showing the truth rather than the client's
	-- own scope:Value(false) default -- which would otherwise silently lie for an admin joining a
	-- server where a previous admin already turned it on.
	local function fetchHitboxDebug(): ()
		local getHitboxDebugRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetHitboxDebug)
		local ok, resultOrError = RemoteInvoker.Invoke(getHitboxDebugRemote)

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

	task.spawn(fetchHitboxDebug)

	-- Debug dummy guard toggle + active count (Spawn tab) -- same eager fetch-once-on-open shape as
	-- fetchHitboxDebug directly above, for the identical reason: a server-wide toggle a joining admin
	-- must see the truth of, not this client's own scope:Value(false) default.
	local function fetchDebugDummyState(): ()
		local getDebugDummyStateRemote =
			NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.GetDebugDummyState)
		local ok, resultOrError = RemoteInvoker.Invoke(getDebugDummyStateRemote)

		if not ok then
			logger:error("GetDebugDummyState request errored", { errorMessage = tostring(resultOrError) })
			return
		end

		local result = resultOrError :: Types.DevMenuDebugDummyStateResult
		if not result.Success then
			logger:warn("GetDebugDummyState rejected", { reason = result.Reason })
			return
		end

		if result.GuardEnabled ~= nil then
			content.DummyGuardActive:set(result.GuardEnabled)
		end
		if result.ActiveCount ~= nil then
			content.ActiveDummyCountDisplay:set(result.ActiveCount)
		end
		logger:debug(
			"GetDebugDummyState loaded",
			{ guardEnabled = result.GuardEnabled, activeCount = result.ActiveCount }
		)
	end

	task.spawn(fetchDebugDummyState)

	local function fetchPlayers(): ()
		if peek(sidebar.PlayersLoading) then
			return
		end
		sidebar.PlayersLoading:set(true)

		local listPlayersRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListPlayers)
		local ok, resultOrError = RemoteInvoker.Invoke(listPlayersRemote)

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
	-- in CombatClient.lua). The only DevMenu tuning tool left of this shape -- hand-authored attacks
	-- are tuned as the Move Editor's Default moves now. Adjust fires a FRACTIONAL delta straight through (no
	-- per-field name needed -- there's only ever one number being adjusted for whichever field is
	-- currently selected).
	task.spawn(function()
		local listRemote = NetworkBridge.GetRemoteFunction(Constants.Debug.DevMenu.RemoteNames.ListFlightTuning)
		local ok, resultOrError = RemoteInvoker.Invoke(listRemote)
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

	-- Vehicles tab: seeded the first time the panel is opened rather than eagerly at Start(), unlike
	-- Reports above. The snapshot walks every live hull's pivot and every tagged berth on the server,
	-- and an admin who never opens this menu should not pay for that on every join. Driven off
	-- seedVehicleStateOnce, which the keybind handler above calls -- rather than an Observer on
	-- handle.IsOpen, which would need a Fusion scope this module deliberately does not have (it drives
	-- a screen from outside; it never builds one). Every mutation below re-reads afterwards rather
	-- than guessing at what the server did, since a spawn may have evicted something to make room.
	content.Vehicles.RefreshRequested:Connect(function()
		task.spawn(function()
			fetchVehicleState(handle, false)
		end)
	end)

	content.Vehicles.ReloadRegistryRequested:Connect(function()
		task.spawn(function()
			fetchVehicleState(handle, true)
		end)
	end)

	content.Vehicles.SpawnRequested:Connect(function(vehicleId: string, berthName: string?)
		logger:debug("SpawnVehicleRequested received", { vehicleId = vehicleId, berth = berthName })
		invokeAndReport(handle, function()
			local remote = NetworkBridge.GetRemoteFunction(VehicleConstants.RemoteNames.Spawn)
			return remote:InvokeServer(vehicleId, berthName)
		end, function(resultOrError)
			local result = resultOrError :: VehicleTypes.VehicleSpawnResult
			-- Re-read either way. A REJECTED spawn still usually means the tab is stale -- the berth
			-- filled, the vehicle was rescanned away -- which is exactly what the admin needs to see.
			task.spawn(function()
				fetchVehicleState(handle, false)
			end)
			if result.Success then
				return `Spawned {vehicleId}.`
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	content.Vehicles.DespawnRequested:Connect(function(instanceId: string)
		logger:debug("DespawnVehicleRequested received", { instanceId = instanceId })
		invokeAndReport(handle, function()
			local remote = NetworkBridge.GetRemoteFunction(VehicleConstants.RemoteNames.Despawn)
			return remote:InvokeServer(instanceId)
		end, function(resultOrError)
			local result = resultOrError :: VehicleTypes.VehicleActionResult
			task.spawn(function()
				fetchVehicleState(handle, false)
			end)
			if result.Success then
				return "Vehicle despawned."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
	end)

	content.Vehicles.DespawnAllRequested:Connect(function()
		logger:debug("DespawnAllVehiclesRequested received")
		invokeAndReport(handle, function()
			local remote = NetworkBridge.GetRemoteFunction(VehicleConstants.RemoteNames.DespawnAll)
			return remote:InvokeServer()
		end, function(resultOrError)
			local result = resultOrError :: VehicleTypes.VehicleActionResult
			task.spawn(function()
				fetchVehicleState(handle, false)
			end)
			if result.Success then
				return "All vehicles cleared."
			end
			return "Failed: " .. (result.Reason or "Unknown")
		end)
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
--
-- TAKES A Shared/Lazy.lua THUNK, not a mounted handle. The panel this drives is ~105 Instances that
-- UI.Mount() used to build on the boot path for every player regardless of the answer below -- see
-- Client/UI/init.lua's own header. Forcing it here rather than there costs nothing: this function was
-- already doing all its real work on its own thread behind the same round trip, so the mount simply
-- joins work that was already deferred, and a non-admin never pays for it at all.
function DevMenuClient.Start(deferredHandle: Lazy.Lazy<DevMenuHandle>, chrome: Chrome.ChromeHandle): ()
	task.spawn(function()
		if not requestServerAuthorization() then
			logger:debug("DevMenuClient not started: server did not authorize this client")
			return
		end
		-- The parkour debug overlay (F6) runs on this same answer rather than asking for its own --
		-- one authorization round-trip per session, one whitelist to maintain. Granted here rather
		-- than inside startDevMenu because it is not part of the menu; it just shares the gate. See
		-- ParkourDebug.SetAuthorized for why a client-side grant is safe for a read-only overlay.
		-- Deliberately BEFORE the mount below: the overlay is not part of the panel and must not be
		-- gated on the panel's own construction.
		ParkourDebug.SetAuthorized(true)
		startDevMenu(deferredHandle.Get(), chrome)
	end)
end

return DevMenuClient
