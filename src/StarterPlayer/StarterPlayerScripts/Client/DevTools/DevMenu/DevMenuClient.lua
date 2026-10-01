--!strict
--[[
	DevMenuClient.lua

	Owns: driving the admin panel (UI/Screens/DevTools/DevMenu) from outside -- asking the server whether
	this client may have it at all, the toggle key, polling the server while the panel is open, and
	turning each Intent the screen fires into a remote call and its answer into the screen's Values and
	footer line. Rebuilt with the panel on 2026-09-29.

	AUTHORIZATION IS ONE ROUND TRIP: the first GetOverview. A rejection is the answer (DevMenuSystem
	re-checks the whitelist on every request regardless), and a non-admin's client binds no key and
	never builds the panel -- the Lazy thunk is only forced once the server says yes. The parkour
	debug overlay (F6) rides the same answer.

	POLLING ONLY WHILE OPEN. Opening starts two loops -- the overview every OverviewPollSeconds (roster
	and server status) and the selected player's inspection every InspectPollSeconds -- and closing,
	by any route (the key, the frame's close control, Escape), ends them: an Observer on IsOpen, so no
	close path can leave a loop running. Both remotes sit on their own server-side rate-limit bucket.
	A tab's own data (reports, vehicles, flight fields) is read the first time that tab is shown, not
	at join -- the old panel fetched all of it at boot and tripped its own rate limit doing so.

	AFTER EVERY ACTION ON A PLAYER, RE-READ THEM AT ONCE. The screen shows the server's state, never the
	press (the Player tab's switches read the inspection), so the next inspection is requested
	immediately rather than up to a second later.

	Does not own: authorization (DevMenuSystem), what any action does (the server Systems behind it),
	or the panel's layout (the screen).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AdminTypes = require(ReplicatedStorage.Shared.Admin.AdminTypes)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Types = require(ReplicatedStorage.Shared.Types)
local VehicleConstants = require(ReplicatedStorage.Shared.Vehicle.VehicleConstants)
local VehicleTypes = require(ReplicatedStorage.Shared.Vehicle.VehicleTypes)

local Chrome = require(script.Parent.Parent.Parent.UI.Shell.Chrome)
local DevMenuModule = require(script.Parent.Parent.Parent.UI.Screens.DevTools.DevMenu)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local ParkourDebug = require(script.Parent.Parent.Parent.Parkour.ParkourDebug)
local RemoteInvoker = require(script.Parent.Parent.Parent.Network.RemoteInvoker)
local SpectateController = require(script.Parent.SpectateController)

type DevMenuHandle = DevMenuModule.DevMenuHandle
type Intent = DevMenuModule.Intent

local peek = Fusion.peek

local logger = Logger.scope("DevMenuClient")

local DevMenuConfig = Constants.Debug.DevMenu
local REMOTES = DevMenuConfig.RemoteNames

-- How long a flight slider's drag is gathered before the latest value is sent. A drag commits ~20
-- times a second (NumericField's own throttle) and the server's action bucket allows 4.
local FLIGHT_SEND_DELAY = 0.3

local DevMenuClient = {}

-- Reasons -----------------------------------------------------------------------------------------

-- The server's refusal codes, in words an admin can act on.
local REASON_TEXT: { [string]: string } = {
	NotAuthorized = "Not authorized.",
	RateLimited = "Too many requests -- give it a second.",
	InvalidRequest = "The server refused that request as malformed.",
	NoTarget = "That player is no longer in the server.",
	NoCharacter = "No body to act on right now (dead or respawning).",
	SelfTarget = "That does not apply to yourself.",
	NotLoaded = "Their profile has not loaded yet.",
	StorageError = "The data store did not answer -- try again.",
	MaxTier = "Already at the top tier.",
	ReporterNotHere = "The reporter is not in this server.",
	InvalidPreset = "Unknown bot style or difficulty.",
	InvalidWeapon = "That weapon is not in the roster.",
	SpawnFailed = "The spawn failed -- see the live console (F5).",
	InternalError = "The server hit an error -- see the live console (F5).",
	RequestFailed = "The request did not reach the server.",
}

local function describeFailure(reason: string?): string
	return REASON_TEXT[reason or "InternalError"] or `Refused: {reason}.`
end

-- Remotes -----------------------------------------------------------------------------------------

type Answer = { Success: boolean, Reason: string? }

-- One call, never throwing: resolves the remote INSIDE the protected region (NetworkBridge asserts on
-- a missing name) and folds a thrown error into a failed answer, so every caller reads one shape.
local function call(remoteName: string, ...: any): any
	local args = table.pack(...)
	local ok, remote = pcall(NetworkBridge.GetRemoteFunction, remoteName)
	if not ok then
		logger:error("Remote missing", { remote = remoteName, errorMessage = tostring(remote) })
		return { Success = false, Reason = "RequestFailed" }
	end
	local invoked, result = RemoteInvoker.Invoke(remote :: RemoteFunction, table.unpack(args, 1, args.n))
	if not invoked or typeof(result) ~= "table" then
		logger:warn("Remote call failed", { remote = remoteName, errorMessage = tostring(result) })
		return { Success = false, Reason = "RequestFailed" }
	end
	return result
end

-- Session state -----------------------------------------------------------------------------------

local statusGeneration = 0
local pollGeneration = 0
local reportsSeeded = false
local vehiclesSeeded = false
local flightSeeded = false
-- Server-armed confirms (Shutdown, Restart): the button says "confirm" for exactly the server's own
-- window. A stale timer from an earlier arm never clears a later one.
local armGenerations: { [string]: number } = {}

local function showArmed(armed: Fusion.Value<boolean>, key: string, windowSeconds: number): ()
	local generation = (armGenerations[key] or 0) + 1
	armGenerations[key] = generation
	armed:set(true)
	task.delay(windowSeconds, function()
		if armGenerations[key] == generation then
			armed:set(false)
		end
	end)
end
-- Flight fields with a drag in flight: the latest value per field, and whether a send is scheduled.
local pendingFlight: { [string]: number } = {}
local flightSendScheduled: { [string]: boolean } = {}

local function setStatus(handle: DevMenuHandle, message: string): ()
	statusGeneration += 1
	local generation = statusGeneration
	handle.StatusText:set(message)
	task.delay(DevMenuConfig.StatusClearDelaySeconds, function()
		if statusGeneration == generation then
			handle.StatusText:set("")
		end
	end)
end

local function report(handle: DevMenuHandle, answer: Answer, success: string): boolean
	setStatus(handle, if answer.Success then success else describeFailure(answer.Reason))
	return answer.Success
end

local function targetOf(handle: DevMenuHandle): number?
	return peek(handle.SelectedUserId)
end

local function targetName(handle: DevMenuHandle): string
	local selected = targetOf(handle)
	for _, entry in peek(handle.Roster) do
		if entry.UserId == selected then
			return entry.DisplayName
		end
	end
	return "them"
end

-- Reads ------------------------------------------------------------------------------------------

local function applyOverview(handle: DevMenuHandle, result: AdminTypes.OverviewResult): ()
	if not result.Success or not result.Roster or not result.Server then
		return
	end
	handle.Roster:set(result.Roster)
	handle.Server:set(result.Server)

	-- The selected player left: fall back to the admin rather than leaving the tab aimed at nobody.
	local selected = peek(handle.SelectedUserId)
	if selected then
		local present = false
		for _, entry in result.Roster do
			if entry.UserId == selected then
				present = true
				break
			end
		end
		if not present then
			handle.SelectedUserId:set(peek(handle.LocalUserId))
			handle.Inspection:set(nil)
		end
	end

	-- SpectateController stops itself when its target leaves; mirror that.
	if peek(handle.SpectatingUserId) and not SpectateController.IsSpectating() then
		handle.SpectatingUserId:set(nil)
	end
end

local function refreshOverview(handle: DevMenuHandle): ()
	applyOverview(handle, call(REMOTES.GetOverview))
end

local function refreshInspection(handle: DevMenuHandle): ()
	local selected = targetOf(handle)
	if not selected then
		return
	end
	local result = call(REMOTES.InspectPlayer, selected) :: AdminTypes.InspectResult
	-- Only if the selection has not moved on while this was in flight.
	if result.Success and result.Inspection and peek(handle.SelectedUserId) == selected then
		handle.Inspection:set(result.Inspection)
	end
end

-- After an action on a player: re-read them and the roster now rather than at the next tick.
local function refreshTarget(handle: DevMenuHandle): ()
	task.spawn(refreshInspection, handle)
	task.spawn(refreshOverview, handle)
end

local function startPolling(handle: DevMenuHandle): ()
	pollGeneration += 1
	local generation = pollGeneration
	local function live(): boolean
		return generation == pollGeneration and peek(handle.IsOpen)
	end
	task.spawn(function()
		while live() do
			refreshOverview(handle)
			task.wait(DevMenuConfig.OverviewPollSeconds)
		end
	end)
	task.spawn(function()
		while live() do
			refreshInspection(handle)
			task.wait(DevMenuConfig.InspectPollSeconds)
		end
	end)
end

local function loadReports(handle: DevMenuHandle, mode: "First" | "Next"): ()
	if peek(handle.ReportsLoading) then
		return
	end
	handle.ReportsLoading:set(true)
	local result = call(REMOTES.ListBugReports, mode) :: Types.DevMenuListBugReportsResult
	handle.ReportsLoading:set(false)
	if not result.Success or not result.Reports then
		setStatus(handle, describeFailure(result.Reason))
		return
	end
	if mode == "Next" then
		local merged = table.clone(peek(handle.Reports))
		for _, record in result.Reports do
			table.insert(merged, record)
		end
		handle.Reports:set(merged)
	else
		handle.Reports:set(result.Reports)
	end
	handle.ReportsHasMore:set(result.HasMore == true)
end

-- Replaces one record with the server's updated copy -- in a NEW list, so the screen sees the change.
local function patchReport(handle: DevMenuHandle, updated: Types.BugReportRecord): ()
	local list = table.clone(peek(handle.Reports))
	for index, record in list do
		if record.Id == updated.Id then
			list[index] = updated
			break
		end
	end
	handle.Reports:set(list)
end

local function loadVehicles(handle: DevMenuHandle, rescan: boolean): ()
	local remoteName = if rescan
		then VehicleConstants.RemoteNames.ReloadRegistry
		else VehicleConstants.RemoteNames.GetState
	local result = call(remoteName) :: VehicleTypes.VehicleStateResult
	if not result.Success or not result.Catalog or not result.Live or not result.Berths then
		handle.VehicleRegistryText:set(`Registry unavailable: {describeFailure(result.Reason)}`)
		return
	end
	handle.VehicleCatalog:set(result.Catalog)
	handle.VehicleLive:set(result.Live)
	handle.VehicleBerths:set(result.Berths)
	handle.VehicleRegistryText:set(
		`Registry: {result.RegistryPath or "<unknown>"} -- {#result.Catalog} vehicle(s), {#result.Live} live.`
	)
	local rejections: { string } = {}
	for _, rejection in result.Rejections or {} do
		table.insert(rejections, `{rejection.Path}: {rejection.Reason}`)
	end
	handle.VehicleRejectionText:set(if #rejections > 0 then "Rejected -- " .. table.concat(rejections, "; ") else nil)
end

local function loadFlight(handle: DevMenuHandle): ()
	local result = call(REMOTES.ListFlightTuning) :: Types.DevMenuListFlightTuningResult
	if result.Success and result.Fields then
		handle.Flight:set(result.Fields)
	else
		setStatus(handle, describeFailure(result.Reason))
	end
end

local function patchFlight(handle: DevMenuHandle, updated: Types.FlightTuningInfo): ()
	local list = table.clone(peek(handle.Flight))
	for index, info in list do
		if info.Field == updated.Field then
			list[index] = updated
			break
		end
	end
	handle.Flight:set(list)
end

-- The first time a tab is shown, read what it shows.
local function seedTab(handle: DevMenuHandle, tab: string): ()
	if tab == "Reports" and not reportsSeeded then
		reportsSeeded = true
		task.spawn(loadReports, handle, "First")
	elseif tab == "World" and not vehiclesSeeded then
		vehiclesSeeded = true
		task.spawn(loadVehicles, handle, false)
	elseif tab == "Tuning" and not flightSeeded then
		flightSeeded = true
		task.spawn(loadFlight, handle)
	end
end

-- Intents -----------------------------------------------------------------------------------------

local OVERRIDE_REMOTES: { [string]: string } = {
	Godmode = REMOTES.SetTargetGodmode,
	Flight = REMOTES.SetTargetFlight,
	FlightCollide = REMOTES.SetTargetFlightCollide,
	Frozen = REMOTES.SetTargetFrozen,
	Invisible = REMOTES.SetTargetInvisible,
}

local OVERRIDE_WORDS: { [string]: string } = {
	Godmode = "Godmode",
	Flight = "Flight",
	FlightCollide = "Flight collision",
	Frozen = "Freeze",
	Invisible = "Invisibility",
}

type Handler = (handle: DevMenuHandle, intent: any) -> ()

-- One handler per Intent.Kind (Screens/DevTools/DevMenu/Types.lua). Each runs on its own thread.
local HANDLERS: { [string]: Handler } = {
	Select = function(handle)
		refreshInspection(handle)
	end,

	Override = function(handle, intent)
		local answer = call(OVERRIDE_REMOTES[intent.Override], intent.Enabled, targetOf(handle))
		report(
			handle,
			answer,
			`{OVERRIDE_WORDS[intent.Override]} {if intent.Enabled then "on" else "off"} for {targetName(handle)}.`
		)
		refreshTarget(handle)
	end,
	Speed = function(handle, intent)
		local answer = call(REMOTES.SetTargetSpeedMultiplier, intent.Multiplier, targetOf(handle))
		report(handle, answer, `Walk speed x{intent.Multiplier} for {targetName(handle)}.`)
		refreshTarget(handle)
	end,
	GoTo = function(handle)
		report(handle, call(REMOTES.TeleportToTarget, targetOf(handle)), `Moved you to {targetName(handle)}.`)
	end,
	Bring = function(handle)
		report(handle, call(REMOTES.BringTarget, targetOf(handle)), `Brought {targetName(handle)} to you.`)
		refreshTarget(handle)
	end,
	Respawn = function(handle)
		report(handle, call(REMOTES.ForceRespawnTarget, targetOf(handle)), `Respawned {targetName(handle)}.`)
		task.delay(0.5, refreshTarget, handle)
	end,
	Spectate = function(handle)
		local selected = targetOf(handle)
		if peek(handle.SpectatingUserId) == selected then
			SpectateController.Stop()
			handle.SpectatingUserId:set(nil)
			setStatus(handle, "Back to your own camera.")
			return
		end
		local target = if selected then Players:GetPlayerByUserId(selected) else nil
		if not target or target == Players.LocalPlayer then
			setStatus(handle, "Pick another player to spectate.")
			return
		end
		SpectateController.Start(target)
		handle.SpectatingUserId:set(target.UserId)
		setStatus(handle, `Watching {target.DisplayName}. Stop watching returns your camera.`)
	end,
	Restore = function(handle)
		report(handle, call(REMOTES.RestoreTarget, targetOf(handle)), `Restored {targetName(handle)} to full.`)
		refreshTarget(handle)
	end,
	Kill = function(handle)
		report(handle, call(REMOTES.KillTarget, targetOf(handle)), `Killed {targetName(handle)}.`)
		refreshTarget(handle)
	end,
	GrantXP = function(handle, intent)
		local answer = call(REMOTES.GrantMeridianXP, intent.Key, targetOf(handle)) :: AdminTypes.GrantXPResult
		if answer.Success then
			setStatus(
				handle,
				`+{answer.Granted or 0} Meridian XP -- {targetName(handle)} is at {answer.Total or 0}, tier {answer.Tier or "?"}.`
			)
		else
			setStatus(handle, describeFailure(answer.Reason))
		end
		refreshTarget(handle)
	end,
	GrantRerolls = function(handle)
		local answer = call(REMOTES.GrantBloodlineRerolls, targetOf(handle)) :: Types.DevMenuGrantRerollsResult
		report(handle, answer, `Rerolls granted -- {targetName(handle)} holds {answer.RerollsRemaining or 0}.`)
		refreshTarget(handle)
	end,
	RollEmote = function(handle)
		local answer = call(REMOTES.RollEmote, targetOf(handle)) :: Types.DevMenuRollEmoteResult
		report(handle, answer, `Rolled {answer.EmoteId or "an emote"} for {targetName(handle)}.`)
	end,
	Kick = function(handle, intent)
		local name = targetName(handle)
		report(handle, call(REMOTES.KickPlayer, targetOf(handle), intent.Reason), `Kicked {name}.`)
		task.delay(0.5, refreshOverview, handle)
	end,
	Mute = function(handle, intent)
		report(
			handle,
			call(REMOTES.MutePlayer, targetOf(handle), intent.Enabled),
			`{if intent.Enabled then "Muted" else "Unmuted"} {targetName(handle)}.`
		)
		refreshTarget(handle)
	end,
	Flag = function(handle, intent)
		report(
			handle,
			call(REMOTES.SetSuspectedCheater, targetOf(handle), intent.Enabled, intent.Reason),
			`{if intent.Enabled then "Flagged" else "Cleared the flag on"} {targetName(handle)}.`
		)
		refreshTarget(handle)
	end,
	Ban = function(handle, intent)
		local name = targetName(handle)
		report(handle, call(REMOTES.BanPlayer, targetOf(handle), intent.Reason, intent.DurationKey), `Banned {name}.`)
		task.delay(0.5, refreshOverview, handle)
	end,
	ResetData = function(handle)
		report(
			handle,
			call(REMOTES.ResetTargetPlayerData, targetOf(handle)),
			`Wiped {targetName(handle)}'s saved data.`
		)
		refreshTarget(handle)
	end,

	SpawnBot = function(handle, intent)
		local answer = call(REMOTES.SpawnTrainingBot, intent.Style, intent.Difficulty, intent.Weapon)
		report(handle, answer, `Spawned a {intent.Difficulty} {intent.Style} bot.`)
		refreshOverview(handle)
	end,
	DespawnBots = function(handle)
		report(handle, call(REMOTES.DespawnTrainingBots), "Bots despawned.")
		refreshOverview(handle)
	end,
	SpawnDummy = function(handle)
		report(handle, call(REMOTES.SpawnDummy), "Dummy spawned in front of you.")
		refreshOverview(handle)
	end,
	DespawnDummies = function(handle)
		report(handle, call(REMOTES.DespawnAllDebugDummies), "Dummies despawned.")
		refreshOverview(handle)
	end,
	DummyGuard = function(handle, intent)
		report(
			handle,
			call(REMOTES.SetDummyGuard, intent.Enabled),
			if intent.Enabled then "Dummies guard." else "Dummies drop their guard."
		)
		refreshOverview(handle)
	end,
	HitboxVolumes = function(handle, intent)
		report(
			handle,
			call(REMOTES.SetHitboxDebug, intent.Enabled),
			if intent.Enabled then "Hitbox volumes visible to everyone." else "Hitbox volumes hidden."
		)
		refreshOverview(handle)
	end,
	TeleportCoords = function(handle, intent)
		report(
			handle,
			call(REMOTES.TeleportToCoordinates, intent.X, intent.Y, intent.Z),
			`Teleported to {intent.X}, {intent.Y}, {intent.Z}.`
		)
	end,
	SpawnCoal = function(handle)
		report(handle, call(REMOTES.SpawnCoalDeposit), "Coal deposit spawned.")
	end,
	SpawnWater = function(handle)
		report(handle, call(REMOTES.SpawnWaterSource), "Water source spawned.")
	end,
	FillFuel = function(handle)
		report(handle, call(REMOTES.FillCarriedFuel), "Carried coal and water filled.")
	end,
	VehiclesRefresh = function(handle)
		loadVehicles(handle, false)
	end,
	VehiclesRescan = function(handle)
		loadVehicles(handle, true)
		setStatus(handle, "Vehicle registry rescanned.")
	end,
	VehicleSpawn = function(handle, intent)
		local answer = call(VehicleConstants.RemoteNames.Spawn, intent.VehicleId, intent.Berth)
		report(handle, answer, `Spawned {intent.VehicleId}.`)
		-- Re-read either way: a refused spawn usually means the tab is stale (a berth filled).
		loadVehicles(handle, false)
	end,
	VehicleDespawn = function(handle, intent)
		report(handle, call(VehicleConstants.RemoteNames.Despawn, intent.InstanceId), "Vehicle despawned.")
		loadVehicles(handle, false)
	end,
	VehiclesDespawnAll = function(handle)
		report(handle, call(VehicleConstants.RemoteNames.DespawnAll), "Every vehicle cleared.")
		loadVehicles(handle, false)
	end,

	Announce = function(handle, intent)
		report(handle, call(REMOTES.BroadcastAnnouncement, intent.Message), "Announcement sent.")
	end,
	Shutdown = function(handle)
		local answer = call(REMOTES.ShutdownServer)
		if answer.Reason == "ConfirmationRequired" then
			showArmed(handle.ShutdownArmed, "Shutdown", DevMenuConfig.ShutdownConfirmWindowSeconds)
			setStatus(handle, "Press Confirm shutdown to shut this server down.")
			return
		end
		handle.ShutdownArmed:set(false)
		report(handle, answer, `Shutting down in {DevMenuConfig.ShutdownDelaySeconds} seconds.`)
	end,
	Restart = function(handle)
		local answer = call(REMOTES.InstantRestartServer)
		if answer.Reason == "ConfirmationRequired" then
			showArmed(handle.RestartArmed, "Restart", DevMenuConfig.InstantRestartConfirmWindowSeconds)
			setStatus(handle, "Press Confirm restart to restart this server now.")
			return
		end
		handle.RestartArmed:set(false)
		report(handle, answer, "Restarting.")
	end,
	LookupBan = function(handle, intent)
		local answer = call(REMOTES.LookupBan, intent.UserId) :: AdminTypes.BanLookupResult
		if answer.Success and answer.Lookup then
			handle.BanLookup:set(answer.Lookup)
		else
			setStatus(handle, describeFailure(answer.Reason))
		end
	end,
	Unban = function(handle, intent)
		if report(handle, call(REMOTES.UnbanPlayer, intent.UserId), `Lifted the ban on {intent.UserId}.`) then
			local answer = call(REMOTES.LookupBan, intent.UserId) :: AdminTypes.BanLookupResult
			if answer.Success and answer.Lookup then
				handle.BanLookup:set(answer.Lookup)
			end
		end
	end,
	OfflineBan = function(handle, intent)
		if
			report(
				handle,
				call(REMOTES.BanPlayer, intent.UserId, intent.Reason, intent.DurationKey),
				`Banned {intent.UserId}.`
			)
		then
			local answer = call(REMOTES.LookupBan, intent.UserId) :: AdminTypes.BanLookupResult
			if answer.Success and answer.Lookup then
				handle.BanLookup:set(answer.Lookup)
			end
		end
	end,

	ReportsLoad = function(handle, intent)
		loadReports(handle, intent.Mode)
	end,
	ReportStatus = function(handle, intent)
		local answer =
			call(REMOTES.UpdateBugReportStatus, intent.Id, intent.Status) :: Types.DevMenuUpdateBugReportStatusResult
		if report(handle, answer, "Report status updated.") and answer.Report then
			patchReport(handle, answer.Report)
		end
	end,
	ReportPriority = function(handle, intent)
		local answer =
			call(REMOTES.SetBugReportPriority, intent.Id, intent.Priority) :: Types.DevMenuBugReportMutationResult
		if report(handle, answer, "Report priority updated.") and answer.Report then
			patchReport(handle, answer.Report)
		end
	end,
	ReportAssign = function(handle, intent)
		local answer = call(REMOTES.AssignBugReport, intent.Id, intent.Assign) :: Types.DevMenuBugReportMutationResult
		if report(handle, answer, if intent.Assign then "Report claimed." else "Claim released.") and answer.Report then
			patchReport(handle, answer.Report)
		end
	end,
	ReportNote = function(handle, intent)
		local answer = call(REMOTES.AddBugReportNote, intent.Id, intent.Text) :: Types.DevMenuBugReportMutationResult
		if report(handle, answer, "Note added.") and answer.Report then
			patchReport(handle, answer.Report)
		end
	end,
	ReportJump = function(handle, intent)
		report(handle, call(REMOTES.JumpToReporter, intent.Id), "Moved you to the reporter.")
	end,

	-- Gathered per field and sent after FLIGHT_SEND_DELAY -- see that constant.
	FlightSet = function(handle, intent)
		local field = intent.Field
		pendingFlight[field] = intent.Value
		if flightSendScheduled[field] then
			return
		end
		flightSendScheduled[field] = true
		task.wait(FLIGHT_SEND_DELAY)
		flightSendScheduled[field] = nil
		local value = pendingFlight[field]
		pendingFlight[field] = nil
		if value == nil then
			return
		end
		local answer = call(REMOTES.SetFlightTuning, field, value) :: Types.DevMenuFlightTuningResult
		-- A newer drag value is already queued: do not snap the slider back to this older answer.
		if answer.Success and answer.Field and pendingFlight[field] == nil then
			patchFlight(handle, answer.Field)
		elseif not answer.Success then
			setStatus(handle, describeFailure(answer.Reason))
		end
	end,
	FlightReset = function(handle, intent)
		pendingFlight[intent.Field] = nil
		local answer = call(REMOTES.ResetFlightTuning, intent.Field) :: Types.DevMenuFlightTuningResult
		if report(handle, answer, "Field reset to its file default.") and answer.Field then
			patchFlight(handle, answer.Field)
		end
	end,
	FlightResetAll = function(handle)
		table.clear(pendingFlight)
		-- One at a time, and slower than the action bucket refills.
		for _, info in peek(handle.Flight) do
			if info.Value ~= info.Default then
				local answer = call(REMOTES.ResetFlightTuning, info.Field) :: Types.DevMenuFlightTuningResult
				if answer.Success and answer.Field then
					patchFlight(handle, answer.Field)
				end
				task.wait(0.3)
			end
		end
		setStatus(handle, "Every flight field back to its file default.")
	end,
}

-- Start -------------------------------------------------------------------------------------------

-- Yields (one InvokeServer); Start runs it on its own thread.
local function requestAuthorization(): AdminTypes.OverviewResult?
	local answer = call(REMOTES.GetOverview) :: AdminTypes.OverviewResult
	return if answer.Success then answer else nil
end

local function startDevMenu(
	handle: DevMenuHandle,
	chrome: Chrome.ChromeHandle,
	firstOverview: AdminTypes.OverviewResult
): ()
	local localPlayer = Players.LocalPlayer
	handle.LocalUserId:set(localPlayer.UserId)
	applyOverview(handle, firstOverview)

	-- The driver's own scope, for the two Observers below. It lives as long as the client does.
	local scope = Fusion.scoped(Fusion)

	scope:Observer(handle.IsOpen):onChange(function()
		if peek(handle.IsOpen) then
			if peek(handle.SelectedUserId) == nil then
				handle.SelectedUserId:set(localPlayer.UserId)
			end
			seedTab(handle, peek(handle.CurrentTab))
			startPolling(handle)
		else
			-- Loops check IsOpen and exit; bumping the generation ends them even mid-wait.
			pollGeneration += 1
		end
	end)
	scope:Observer(handle.CurrentTab):onChange(function()
		if peek(handle.IsOpen) then
			seedTab(handle, peek(handle.CurrentTab))
		end
	end)

	chrome:BindEscape("DevMenu", handle.IsOpen, function()
		handle.IsOpen:set(false)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("DevMenuToggle", input) then
			handle.IsOpen:set(not peek(handle.IsOpen))
		end
	end)

	handle.Intent:Connect(function(intent: Intent)
		local handler = HANDLERS[intent.Kind]
		if not handler then
			logger:warn("Unhandled admin panel intent", { kind = intent.Kind })
			return
		end
		task.spawn(handler, handle, intent)
	end)

	logger:info("Admin panel ready", { userId = localPlayer.UserId })
end

-- Called once from Client/DevTools/init.lua. Returns at once and does the real work on its own
-- thread: the authorization answer is a round trip, and Main.client.lua boots gameplay modules after
-- this one that every player needs. For an admin, the toggle key binds one round trip after join.
--
-- TAKES A Shared/Lazy.lua THUNK: the panel is only built once the server says yes, so a non-admin never
-- pays for it.
function DevMenuClient.Start(deferredHandle: Lazy.Lazy<DevMenuHandle>, chrome: Chrome.ChromeHandle): ()
	task.spawn(function()
		local firstOverview = requestAuthorization()
		if not firstOverview then
			logger:debug("Admin panel not started: server did not authorize this client")
			return
		end
		-- Not part of the panel, it only shares the gate -- so it is granted before the mount.
		ParkourDebug.SetAuthorized(true)
		startDevMenu(deferredHandle.Get(), chrome, firstOverview)
	end)
end

return DevMenuClient
