--!strict
--[[
	SettingsClient.lua

	Owns: the local player's Settings UX -- restoring persisted Types.PlayerSettings into
	Client/Input/KeybindManager.lua at boot, the panel's own open/close keybind (KeybindManager.
	Matches("SettingsToggle", ...), same pattern DevMenuClient.lua/BugReportClient.lua already use),
	translating the Settings screen's RebindClicked/ResetKeybindsClicked/AutorunToggled signals into
	real KeybindManager calls + the matching Settings_* persistence remote, and forwarding the Autorun
	setting to Client/Combat/CombatClient.lua.

	TWO-PHASE BOOT, not one Start() like most driver modules -- see RestoreSettings' own header for
	why. RestoreSettings() must run BEFORE Client/Combat/CombatClient.lua starts reading keybinds (a
	rebound key must already be live the instant combat input handling begins), where Start(handle)
	only wires the PANEL's own interactivity and can boot alongside every other driver module late in
	Main.client.lua's sequence -- there is nothing time-sensitive about when the Settings SCREEN
	itself becomes clickable. Both phases share KeybindManager as their hand-off: RestoreSettings
	applies every persisted override to it; Start(handle) reads the resulting (already-merged)
	KeybindManager.GetAll()/GetAllGamepad() to seed the screen's own display Values, rather than
	caching or re-fetching the raw settings payload a second time.

	Does not own: whether a rebind/reset/toggle is actually legal to persist (Server/Systems/
	SettingsSystem.lua re-validates everything server-side regardless of what this module sends), the
	panel itself (UI/Screens/Settings/init.lua) -- this module only drives that screen's handle from
	outside, the same "screen exposes state/signals, client module drives from outside" pattern
	DevMenuClient.lua already uses -- or what Autorun actually DOES: auto-sprint lives in
	CombatClient.lua next to the rest of sprint, and this module only pushes the boolean over.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local SettingsModule = require(script.Parent.Parent.UI.Screens.Settings)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local CombatClient = require(script.Parent.Parent.Combat.CombatClient)
local ParkourController = require(script.Parent.Parent.Parkour.ParkourController)

type SettingsHandle = SettingsModule.SettingsHandle
type ListeningState = { Device: Types.KeybindDevice, Action: Types.KeybindAction }

local peek = Fusion.peek

local logger = Logger.scope("SettingsClient")

local RemoteNames = Constants.Settings.RemoteNames
local STATUS_CLEAR_DELAY = Constants.Settings.StatusClearDelaySeconds

local SettingsClient = {}

-- Set by RestoreSettings and by the panel's own toggle, read back by Start to seed the screen. The
-- EFFECT of the setting isn't implemented here: Autorun is auto-SPRINT (moving at all engages sprint,
-- exactly as if the Sprint key were held), and sprint is entirely Client/Combat/CombatClient.lua's
-- concern -- it owns the sprint remotes, the running animation, the dust trickle, the FOV zoom, the
-- Slide gate and the server-reject teardown. Driving a second, parallel sprint path from this module
-- would desync every one of those, so this only ever hands CombatClient the boolean and lets it
-- engage sprint through its own single code path (see CombatClient.SetAutoSprint).
local autorunEnabled = false

-- The live Parkour preference block. Same role as autorunEnabled above -- set by RestoreSettings and
-- by the panel's own controls, read back by Start to seed the screen -- and, like Autorun, the EFFECT
-- of each preference is owned elsewhere: Client/Parkour/ParkourController.lua for the movement ones,
-- Client/Combat/CombatClient.lua for SprintMode (sprint has always been CombatClient's, and driving a
-- second sprint path from here would desync every one of the things it already owns). This module
-- only routes.
local parkourSettings: Types.ParkourSettings = {
	Enabled = false,
	CameraEffects = true,
	CoyoteTime = true,
	JumpBuffer = true,
	AutoVault = true,
	LedgeAssist = true,
	StepAssist = true,
	SprintMode = "Hold",
}

-- Pushes the whole current block to the modules that act on it. Called after any change rather than
-- having each control call its own consumer, so there is one place the mapping from preference to
-- consumer lives, and no way for a new preference to be persisted but never applied.
local function applyParkourSettings(): ()
	ParkourController.SetEnabled(parkourSettings.Enabled)
	ParkourController.SetCameraEffectsEnabled(parkourSettings.CameraEffects)
	ParkourController.SetAssists({
		CoyoteTime = parkourSettings.CoyoteTime,
		JumpBuffer = parkourSettings.JumpBuffer,
		AutoVault = parkourSettings.AutoVault,
		LedgeAssist = parkourSettings.LedgeAssist,
		StepAssist = parkourSettings.StepAssist,
	})
	CombatClient.SetSprintMode(parkourSettings.SprintMode)
end

-- Applies every persisted keybind override onto KeybindManager and primes the Autorun loop -- see
-- file header for why this is a separate, EARLIER phase than Start(handle). A RemoteFunction round
-- trip (not a server push fired once on PlayerDataSystem.OnProfileLoaded, the way EmoteSystem's own
-- Emote_UnlockedUpdated/LoadoutUpdated work) specifically so there is no join-time race to lose: by
-- the time this client can even reach this call (IntroClient/LoadingClient have both already
-- blocked Main.client.lua well past the point CharacterCreationSystem's own onboarding flow already
-- required a loaded profile), the server unconditionally has an answer ready -- see
-- Constants.Settings.RemoteNames.GetSettings's own header for the full reasoning.
function SettingsClient.RestoreSettings(): ()
	local getSettingsRemote = NetworkBridge.GetRemoteFunction(RemoteNames.GetSettings)
	local ok, result = pcall(function()
		return getSettingsRemote:InvokeServer()
	end)

	local settings: Types.PlayerSettings
	if ok and typeof(result) == "table" then
		settings = result :: Types.PlayerSettings
	else
		logger:warn("RestoreSettings: GetSettings failed -- using inert defaults", {
			errorMessage = if not ok then tostring(result) else nil,
		})
		-- Parkour is left at this module's own defaults on a failed fetch rather than switched off:
		-- a settings round trip failing is a transient network problem, and degrading a player's
		-- movement to the fallback controller because of it would be a far more visible and confusing
		-- failure than simply running the shipped defaults for the session.
		settings = { Keybinds = {}, GamepadKeybinds = {}, Autorun = false, Parkour = parkourSettings }
	end

	if typeof(settings.Keybinds) == "table" then
		for action, keybind in settings.Keybinds do
			KeybindManager.Rebind(action, keybind)
		end
	end
	if typeof(settings.GamepadKeybinds) == "table" then
		for action, keybind in settings.GamepadKeybinds do
			KeybindManager.RebindGamepad(action, keybind)
		end
	end

	autorunEnabled = settings.Autorun == true
	CombatClient.SetAutoSprint(autorunEnabled)

	-- Field-by-field rather than assigning the payload wholesale: the server's own decode already
	-- guarantees a complete block, but this module also has to survive an older server (a rolling
	-- deploy, a place that hasn't republished) that predates the Parkour block entirely -- in which
	-- case every field is nil and each one falls back to this module's own default rather than to
	-- false, which would read as "the player disabled everything."
	local restoredParkour = settings.Parkour
	if typeof(restoredParkour) == "table" then
		local raw = restoredParkour :: { [string]: any }
		local function boolean(key: string, fallback: boolean): boolean
			return if typeof(raw[key]) == "boolean" then raw[key] else fallback
		end
		parkourSettings = {
			Enabled = boolean("Enabled", parkourSettings.Enabled),
			CameraEffects = boolean("CameraEffects", parkourSettings.CameraEffects),
			CoyoteTime = boolean("CoyoteTime", parkourSettings.CoyoteTime),
			JumpBuffer = boolean("JumpBuffer", parkourSettings.JumpBuffer),
			AutoVault = boolean("AutoVault", parkourSettings.AutoVault),
			LedgeAssist = boolean("LedgeAssist", parkourSettings.LedgeAssist),
			StepAssist = boolean("StepAssist", parkourSettings.StepAssist),
			SprintMode = if raw.SprintMode == "Toggle" then "Toggle" else "Hold",
		}
	end
	applyParkourSettings()

	logger:info("Settings restored", { autorun = autorunEnabled, parkour = parkourSettings.Enabled })
end

local statusGeneration = 0

local function setStatus(handle: SettingsHandle, message: string): ()
	statusGeneration += 1
	local generation = statusGeneration
	handle.StatusText:set(message)
	task.delay(STATUS_CLEAR_DELAY, function()
		if statusGeneration == generation then
			handle.StatusText:set("")
		end
	end)
end

-- Which raw INPUT is acceptable for a rebind capture, per device -- keyboard accepts any real
-- KeyCode plus the three mouse buttons (Roblox reports those via UserInputType, never a KeyCode);
-- gamepad accepts only a genuine button press (UserInputType.GamepadN with a real KeyCode -- a
-- thumbstick TILT fires InputChanged, never InputBegan, so this never needs to special-case
-- excluding stick motion). Returns nil for anything that shouldn't bind (mouse movement/wheel,
-- touch, an unrecognized input) -- the capture connection below simply keeps listening.
local function resolveCandidateKeybind(device: Types.KeybindDevice, input: InputObject): Types.Keybind?
	if device == "Gamepad" then
		if string.match(input.UserInputType.Name, "^Gamepad") and input.KeyCode ~= Enum.KeyCode.None then
			return { KeyCode = input.KeyCode }
		end
		return nil
	end

	if input.KeyCode ~= Enum.KeyCode.None then
		return { KeyCode = input.KeyCode }
	end
	if
		input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.MouseButton2
		or input.UserInputType == Enum.UserInputType.MouseButton3
	then
		return { UserInputType = input.UserInputType }
	end
	return nil
end

function SettingsClient.Start(handle: SettingsHandle): ()
	logger:info("SettingsClient.Start called")

	-- Seeds from KeybindManager's already-merged (defaults + RestoreSettings' overrides) live state
	-- rather than the raw settings payload -- see file header.
	handle.KeyboardBindings:set(KeybindManager.GetAll())
	handle.GamepadBindings:set(KeybindManager.GetAllGamepad())
	handle.Autorun:set(autorunEnabled)
	handle.Parkour:set(table.clone(parkourSettings))

	local captureConnection: RBXScriptConnection? = nil

	local function cancelCapture(): ()
		if captureConnection then
			captureConnection:Disconnect()
			captureConnection = nil
		end
		handle.ListeningFor:set(nil)
	end

	local function beginCapture(device: Types.KeybindDevice, action: Types.KeybindAction): ()
		local current = peek(handle.ListeningFor) :: ListeningState?
		cancelCapture()
		if current and current.Device == device and current.Action == action then
			-- Clicking the SAME row's button again while it was already listening cancels instead of
			-- restarting the capture -- see Screens/Settings/KeybindsTab.lua's own Button text swap
			-- ("Cancel" while listening).
			return
		end

		handle.ListeningFor:set({ Device = device, Action = action })

		captureConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then
				return
			end
			if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonStart then
				cancelCapture()
				return
			end

			local keybind = resolveCandidateKeybind(device, input)
			if not keybind then
				return
			end

			local applied = if device == "Keyboard"
				then KeybindManager.Rebind(action, keybind)
				else KeybindManager.RebindGamepad(action, keybind)

			cancelCapture()

			if not applied then
				setStatus(handle, "That input is already bound to another action.")
				return
			end

			if device == "Keyboard" then
				handle.KeyboardBindings:set(KeybindManager.GetAll())
			else
				handle.GamepadBindings:set(KeybindManager.GetAllGamepad())
			end
			setStatus(handle, "Keybind updated.")

			local updateKeybindRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateKeybind)
			updateKeybindRemote:FireServer(device, action, keybind)
		end)
	end

	local toggleBinding = KeybindManager.Get("SettingsToggle")
	logger:info("Settings toggle binding resolved", {
		keyCode = tostring(toggleBinding and toggleBinding.KeyCode),
		userInputType = tostring(toggleBinding and toggleBinding.UserInputType),
	})

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			logger:debug("Key pressed", {
				keyCode = tostring(input.KeyCode),
				gameProcessed = gameProcessed,
				matches = KeybindManager.Matches("SettingsToggle", input),
			})
		end
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("SettingsToggle", input) then
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			if not nowOpen then
				cancelCapture()
			end
			logger:debug("Settings panel toggled", { open = nowOpen })
		end
	end)

	handle.RebindClicked:Connect(beginCapture)

	handle.ResetKeybindsClicked:Connect(function(device: Types.KeybindDevice)
		cancelCapture()
		if device == "Keyboard" then
			KeybindManager.ResetToDefaults()
			handle.KeyboardBindings:set(KeybindManager.GetAll())
		else
			KeybindManager.ResetGamepadToDefaults()
			handle.GamepadBindings:set(KeybindManager.GetAllGamepad())
		end
		setStatus(handle, "Keybinds reset to defaults.")

		local resetKeybindsRemote = NetworkBridge.GetRemoteEvent(RemoteNames.ResetKeybinds)
		resetKeybindsRemote:FireServer(device)
	end)

	handle.AutorunToggled:Connect(function(enabled: boolean)
		autorunEnabled = enabled
		handle.Autorun:set(enabled)
		CombatClient.SetAutoSprint(enabled)

		local updateAutorunRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateAutorun)
		updateAutorunRemote:FireServer(enabled)
	end)

	-- Apply-then-persist, the same order every control in this module uses (see the file header): the
	-- local session sees the change immediately with no round trip, and the remote exists purely to
	-- make it durable. The server re-validates the field name and value regardless of what is sent --
	-- see SettingsSystem's PARKOUR_SETTING_TYPES.
	handle.ParkourToggled:Connect(function(field: string, enabled: boolean)
		(parkourSettings :: { [string]: any })[field] = enabled
		handle.Parkour:set(table.clone(parkourSettings))
		applyParkourSettings()

		local updateParkourRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateParkour)
		updateParkourRemote:FireServer(field, enabled)
	end)

	handle.SprintModeChanged:Connect(function(mode: Types.SprintMode)
		parkourSettings.SprintMode = mode
		handle.Parkour:set(table.clone(parkourSettings))
		applyParkourSettings()

		local updateParkourRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateParkour)
		updateParkourRemote:FireServer("SprintMode", mode)
	end)

	logger:debug("SettingsClient bindings connected")
end

return SettingsClient
