--!strict
--[[
	SettingsClient.lua

	Owns: the local player's Settings UX -- restoring persisted Types.PlayerSettings into
	Client/Input/KeybindManager.lua at boot, the panel's own open/close keybind (KeybindManager.
	Matches("SettingsToggle", ...), same pattern DevMenuClient.lua/BugReportClient.lua already use),
	and translating the Settings screen's RebindClicked/ResetKeybindsClicked/AutorunToggled signals
	into real KeybindManager calls + the matching Settings_* persistence remote.

	TWO-PHASE BOOT, not one Start() like most driver modules -- see RestoreSettings' own header for
	why. RestoreSettings() must run BEFORE any input-driven client module starts reading keybinds (a
	rebound key must already be live the instant real input could land), where Start(handle) only
	wires the PANEL's own interactivity and can boot alongside every other driver module late in
	Main.client.lua's sequence -- there is nothing time-sensitive about when the Settings SCREEN
	itself becomes clickable. Both phases share KeybindManager as their hand-off: RestoreSettings
	applies every persisted override to it; Start(handle) reads the resulting (already-merged)
	KeybindManager.GetAll()/GetAllGamepad() to seed the screen's own display Values, rather than
	caching or re-fetching the raw settings payload a second time.

	Does not own: whether a rebind/reset/toggle is actually legal to persist (Server/Systems/
	SettingsSystem.lua re-validates everything server-side regardless of what this module sends), or
	the panel itself (UI/Screens/Settings/init.lua) -- this module only drives that screen's handle
	from outside, the same "screen exposes state/signals, client module drives from outside" pattern
	DevMenuClient.lua already uses.

	Autorun/SprintMode push into Client/Movement/RunController.lua, which owns the run end to end on the
	client (the key, hold-versus-toggle, Autorun, the intent remote, and every piece of run
	presentation). Both settings spent a while inert -- their previous consumer, Client/Combat/
	CombatClient.lua, was deleted with the rest of the combat system and nothing inherited sprint --
	which is why this file's own header used to say they did nothing. They are live again, and the
	forwarding is identical in shape to the Parkour block's: this module routes, the consumer owns.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

local SettingsModule = require(script.Parent.Parent.UI.Screens.Settings)
local InputRouter = require(script.Parent.Parent.Input.InputRouter)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local Analog = require(script.Parent.Parent.Input.Analog)
local ParkourController = require(script.Parent.Parent.Parkour.ParkourController)
local RunController = require(script.Parent.Parent.Movement.RunController)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local BlimpCamera = require(script.Parent.Parent.Camera.BlimpCamera)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)
local RemoteInvoker = require(script.Parent.Parent.Network.RemoteInvoker)

type SettingsHandle = SettingsModule.SettingsHandle
type ListeningState = { Device: Types.KeybindDevice, Action: Types.KeybindAction }

local peek = Fusion.peek

local logger = Logger.scope("SettingsClient")

local RemoteNames = Constants.Settings.RemoteNames
local STATUS_CLEAR_DELAY = Constants.Settings.StatusClearDelaySeconds

local SettingsClient = {}

-- Set by RestoreSettings and by the panel's own toggle, read back by Start to seed the screen, and
-- pushed to Client/Movement/RunController.lua, which is what Autorun actually drives.
local autorunEnabled = false

-- The live Parkour preference block. Same role as autorunEnabled above -- set by RestoreSettings and
-- by the panel's own controls, read back by Start to seed the screen. Each movement preference's
-- EFFECT is owned by Client/Parkour/ParkourController.lua, with the one exception of SprintMode, whose
-- consumer is Client/Movement/RunController.lua -- hold-versus-toggle is a run concern, and the run
-- owns its own key. This module only routes.
-- Seeded from ParkourConstants rather than from literals, for the reason the gamepad block below
-- states for itself: this module must not become a second opinion about what the game ships. Enabled
-- was the one field that WAS a literal, and it was `false` -- which is the exact outcome
-- RestoreSettings' own fallback comment says must not happen. A failed GetSettings round trip, or a
-- server old enough to predate this block, fell back to this table and switched the whole parkour
-- framework off (ParkourController.SetEnabled(false) returns from onHeartbeat before any state runs),
-- so there was no wall-run, no ledge hang, and therefore no wall-jump or climb-up -- while ordinary
-- jumping kept working, because that is the stock Humanoid and never goes through this framework at
-- all. A movement system that silently degrades to the fallback controller on a transient network
-- error is exactly the "far more visible and confusing failure" that comment exists to rule out.
local parkourSettings: Types.ParkourSettings = {
	Enabled = ParkourConstants.Enabled,
	CameraEffects = true,
	CoyoteTime = ParkourConstants.Assists.CoyoteTime,
	JumpBuffer = ParkourConstants.Assists.JumpBuffer,
	AutoVault = ParkourConstants.Assists.AutoVault,
	LedgeAssist = ParkourConstants.Assists.LedgeAssist,
	StepAssist = ParkourConstants.Assists.StepAssist,
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
	-- The one field in this block whose consumer is not ParkourController: hold-versus-toggle is a run
	-- concern, and Client/Movement/RunController.lua owns the run's key. Pushed from here anyway rather
	-- than from the SprintModeChanged handler alone, so this function keeps its documented property of
	-- being the single place a preference is mapped to a consumer -- a preference that is persisted but
	-- never applied is the failure this function exists to make impossible.
	RunController.SetSprintMode(parkourSettings.SprintMode)
end

-- The live camera-comfort block. Same role as parkourSettings above -- set by RestoreSettings and by
-- the panel's own controls, read back by Start to seed the screen. Seeded to the shipped defaults
-- (both effects on) so a failed settings fetch runs the game everyone else sees rather than silently
-- stripping effects; see RestoreSettings' own fallback for the identical reasoning applied to parkour.
local comfortSettings: Types.ComfortSettings = {
	CameraShake = true,
	FieldOfViewEffects = true,
	VehicleCameraMotion = true,
}

-- Sibling to applyParkourSettings above, with the same contract: the single place a comfort preference
-- is mapped to its consumer, so a preference cannot be persisted but never applied.
local function applyComfortSettings(): ()
	CameraShake.SetEnabled(comfortSettings.CameraShake)
	FOVOffset.SetPunchesEnabled(comfortSettings.FieldOfViewEffects)
	BlimpCamera.SetMotionEnabled(comfortSettings.VehicleCameraMotion)
end

-- The live gamepad stick block. Same role as parkourSettings/comfortSettings above. Seeded from
-- Constants.Settings.Gamepad.Defaults rather than from literals so this module does not become a
-- fourth opinion about what the shipped values are -- Analog.lua and Server/Systems/PlayerDataSystem.lua
-- both read that same table.
local gamepadSettings: Types.GamepadSettings = {
	LookSensitivity = Constants.Settings.Gamepad.Defaults.LookSensitivity,
	MoveDeadzone = Constants.Settings.Gamepad.Defaults.MoveDeadzone,
	LookDeadzone = Constants.Settings.Gamepad.Defaults.LookDeadzone,
	InvertLookY = Constants.Settings.Gamepad.Defaults.InvertLookY,
	Vibration = Constants.Settings.Gamepad.Defaults.Vibration,
}

-- Sibling to applyComfortSettings above, with the same contract. One consumer today, and the whole
-- block goes to it in one call rather than field by field -- Analog.lua derives the left stick's and
-- right stick's configs from it differently (see its header), so handing it the table is what lets
-- that split live in one place instead of being re-decided here.
local function applyGamepadSettings(): ()
	Analog.SetSettings(gamepadSettings)
end

-- Autorun's own applier. A sibling to applyParkourSettings above rather than a line inside it, because
-- Autorun lives on Types.PlayerSettings directly rather than in the nested Parkour block -- see that
-- type's own note on why it is flat.
local function applyAutorun(): ()
	RunController.SetAutorun(autorunEnabled)
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
	local ok, result = RemoteInvoker.Invoke(getSettingsRemote)

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
		settings = {
			Keybinds = {},
			GamepadKeybinds = {},
			Autorun = false,
			Parkour = parkourSettings,
			Comfort = comfortSettings,
			Gamepad = gamepadSettings,
		}
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
	applyAutorun()

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

	-- Same field-by-field decode and same reasoning as the Parkour block directly above: an older
	-- server that predates this block sends nothing, and every field must fall back to this module's
	-- own default (effects ON) rather than to false, which would read as "the player disabled
	-- everything" and would be indistinguishable from a working accessibility setting.
	local restoredComfort = settings.Comfort
	if typeof(restoredComfort) == "table" then
		local raw = restoredComfort :: { [string]: any }
		local function boolean(key: string, fallback: boolean): boolean
			return if typeof(raw[key]) == "boolean" then raw[key] else fallback
		end
		comfortSettings = {
			CameraShake = boolean("CameraShake", comfortSettings.CameraShake),
			FieldOfViewEffects = boolean("FieldOfViewEffects", comfortSettings.FieldOfViewEffects),
			-- This line was MISSING, and its absence was a live bug rather than an omission: the
			-- assignment replaces the whole table, so a restore left VehicleCameraMotion nil, threw
			-- away whatever the player had persisted, and passed that nil to
			-- BlimpCamera.SetMotionEnabled. It failed in the direction this block's own header warns
			-- about -- a broken accessibility setting that looks exactly like a working one.
			VehicleCameraMotion = boolean("VehicleCameraMotion", comfortSettings.VehicleCameraMotion),
		}
	end
	applyComfortSettings()

	-- Same field-by-field decode as the two blocks above, with one addition they do not need: the
	-- numeric fields are clamped to Constants.Settings.Gamepad.Bounds. The server already clamps on
	-- both write and read, so this is the third and last gate rather than the only one -- it exists
	-- because a value that somehow arrived out of range would otherwise reach Analog.ApplyStick, where
	-- a deadzone of 1 is a stick that does nothing and a player on a pad has no way to open the menu
	-- and fix it.
	local restoredGamepad = settings.Gamepad
	if typeof(restoredGamepad) == "table" then
		local raw = restoredGamepad :: { [string]: any }
		local bounds = Constants.Settings.Gamepad.Bounds
		local function boolean(key: string, fallback: boolean): boolean
			return if typeof(raw[key]) == "boolean" then raw[key] else fallback
		end
		local function number(key: string, fallback: number, min: number, max: number): number
			local value = raw[key]
			-- `value ~= value` is the NaN test -- see SettingsSystem.handleUpdateGamepad.
			if typeof(value) ~= "number" or value ~= value then
				return fallback
			end
			return math.clamp(value, min, max)
		end
		gamepadSettings = {
			LookSensitivity = number(
				"LookSensitivity",
				gamepadSettings.LookSensitivity,
				bounds.LookSensitivity.Min,
				bounds.LookSensitivity.Max
			),
			MoveDeadzone = number(
				"MoveDeadzone",
				gamepadSettings.MoveDeadzone,
				bounds.Deadzone.Min,
				bounds.Deadzone.Max
			),
			LookDeadzone = number(
				"LookDeadzone",
				gamepadSettings.LookDeadzone,
				bounds.Deadzone.Min,
				bounds.Deadzone.Max
			),
			InvertLookY = boolean("InvertLookY", gamepadSettings.InvertLookY),
			Vibration = boolean("Vibration", gamepadSettings.Vibration),
		}
	end
	applyGamepadSettings()

	logger:info("Settings restored", {
		autorun = autorunEnabled,
		parkour = parkourSettings.Enabled,
		cameraShake = comfortSettings.CameraShake,
	})
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

function SettingsClient.Start(handle: SettingsHandle, chrome: Chrome.ChromeHandle): ()
	logger:info("SettingsClient.Start called")

	-- Seeds from KeybindManager's already-merged (defaults + RestoreSettings' overrides) live state
	-- rather than the raw settings payload -- see file header.
	handle.KeyboardBindings:set(KeybindManager.GetAll())
	handle.GamepadBindings:set(KeybindManager.GetAllGamepad())
	handle.Autorun:set(autorunEnabled)
	handle.Parkour:set(table.clone(parkourSettings))
	-- Comfort WAS MISSING from this seed, which was a live bug of the same family as the dropped
	-- VehicleCameraMotion in RestoreSettings above: the screen seeds its own Comfort Value to all-false
	-- and nothing ever wrote the restored block into it, so every camera-comfort row rendered as OFF
	-- until the player toggled it -- at which point the row jumped to the real value. The settings were
	-- being applied correctly the whole time (applyComfortSettings reads the module's own table, not
	-- the handle's), so this was purely a lying panel, which is the hardest version to notice.
	handle.Comfort:set(table.clone(comfortSettings))
	handle.Gamepad:set(table.clone(gamepadSettings))

	local captureConnection: RBXScriptConnection? = nil
	-- The capture's own entry on Shell/Chrome.lua's Escape stack, pushed ABOVE the panel's. Escape
	-- while a row is listening therefore cancels the listen and leaves the panel up, which is the one
	-- behaviour this migration had to preserve exactly -- a player who reaches for Escape to abandon
	-- a mis-click on "Rebind" is not asking to lose the settings screen as well.
	--
	-- The raw PushEscape primitive rather than BindEscape, and this is the one caller in the client
	-- that wants it. BindEscape derives its edges from a Fusion boolean; what says "a capture is
	-- running" here is handle.ListeningFor being non-nil, and turning that into a boolean would need
	-- a Computed on a scope this module does not have. beginCapture/cancelCapture are already an
	-- exactly-matched pair -- every exit from a capture goes through cancelCapture, including the
	-- panel's own close -- so the push and the pop have somewhere honest to sit.
	local captureEscape: Chrome.EscapeHandle? = nil

	local function cancelCapture(): ()
		if captureConnection then
			captureConnection:Disconnect()
			captureConnection = nil
		end
		if captureEscape ~= nil then
			captureEscape:Pop()
			captureEscape = nil
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
		captureEscape = chrome:PushEscape("SettingsKeybindCapture", cancelCapture)

		captureConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then
				return
			end
			-- ButtonStart still cancels here -- it is the gamepad's own menu button and there is no
			-- gamepad Escape stack (plan section 14.3 defers that deliberately). Escape only RETURNS:
			-- the cancel itself is Chrome's, off the entry pushed above, and this branch exists solely
			-- so resolveCandidateKeybind below never gets a chance to bind Escape to an action.
			if input.KeyCode == Enum.KeyCode.Escape then
				return
			end
			if input.KeyCode == Enum.KeyCode.ButtonStart then
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

	-- SETTINGS COULD NOT BE CLOSED WITH ESCAPE BEFORE THIS, and the plan that asked for this phase
	-- said it could. docs/architecture/2026-08-25-hud-shell-plan.md section 2.6 lists Settings among
	-- the four screens that "handle Escape", citing the line inside beginCapture above -- but that
	-- line cancels a keybind CAPTURE, not the panel. K toggled this screen and nothing else closed
	-- it. So Settings is an ADOPTER here rather than a migration, and the entry below is new
	-- behaviour, not relocated behaviour.
	--
	-- cancelCapture as well as the close, because a capture left listening behind a closed panel
	-- would keep an InputBegan connection eating the next key the player pressed. The keybind toggle
	-- below has always done this; Escape has to do it too or it is a second, quieter close path with
	-- different consequences.
	chrome:BindEscape("Settings", handle.IsOpen, function()
		handle.IsOpen:set(false)
		cancelCapture()
	end)

	local toggleBinding = KeybindManager.Get("SettingsToggle")
	logger:info("Settings toggle binding resolved", {
		keyCode = tostring(toggleBinding and toggleBinding.KeyCode),
		userInputType = tostring(toggleBinding and toggleBinding.UserInputType),
	})

	-- "System" rather than "Gameplay"/"Menu" -- see InputRouter.lua's own header for the general
	-- reasoning behind that layer. Concretely for THIS toggle: "Menu" only fires Began while a modal is
	-- already open, which would make K unable to ever OPEN the panel (nothing is open yet when this
	-- fires); "Gameplay" only fires Began while nothing is open, which would make K unable to ever
	-- CLOSE it once Settings itself raises Constants.Attributes.UiModalOpen. "System" is the one layer
	-- InputRouter does not modal-gate in either direction, which is exactly what a two-way toggle needs
	-- -- the same reasoning DevMenuToggle/CharacterMenuToggle's own un-migrated toggles already lean on
	-- by having no modal check at all today.
	--
	-- gameProcessed IS STILL CHECKED HERE, BY HAND, because "System" is also the one layer InputRouter
	-- does not auto-drop it for (see InputRouter.lua's header) -- and this toggle needs it: without it,
	-- typing the letter K into a focused chat/TextBox would toggle Settings open on every keystroke,
	-- since a focused TextBox consumes the keystroke as gameProcessed = true. This is the one migrated
	-- caller in this pass that keeps its own copy of that check, and it is a copy of exactly the one
	-- line every other layer gets for free, not a parallel re-implementation of the gate.
	InputRouter.Bind("SettingsToggle", {
		Layer = "System",
		Began = function(gameProcessed: boolean, input: InputObject)
			if gameProcessed then
				return
			end
			-- Logged only on an actual match, not on every keyboard press this connection used to see --
			-- InputRouter has already done that filtering by the time Began runs. A log meant to help
			-- diagnose "why doesn't my rebound toggle key open Settings" is more useful, not less, once
			-- the one line that fires is the one that actually answers that question.
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			if not nowOpen then
				cancelCapture()
			end
			logger:debug("Settings panel toggled", { open = nowOpen, keyCode = tostring(input.KeyCode) })
		end,
	})

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
		-- Apply-then-persist, the same order every other control in this module uses.
		applyAutorun()

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

	-- Apply-then-persist, same order and same reasoning as ParkourToggled directly above. The server
	-- re-validates the field name and value regardless of what is sent -- see SettingsSystem's
	-- COMFORT_SETTING_FIELDS.
	handle.ComfortToggled:Connect(function(field: string, enabled: boolean)
		(comfortSettings :: { [string]: any })[field] = enabled
		handle.Comfort:set(table.clone(comfortSettings))
		applyComfortSettings()

		local updateComfortRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateComfort)
		updateComfortRemote:FireServer(field, enabled)
	end)

	-- Apply-then-persist, same order and same reasoning as ComfortToggled directly above. Split into
	-- two handlers rather than one taking `any` so each stays type-checked; the server re-validates
	-- both the field name and the value regardless of what is sent, and CLAMPS the numeric ones --
	-- see SettingsSystem's GAMEPAD_SETTING_TYPES and its handler's own note on why clamping beats
	-- rejecting for a value the client has already applied locally.
	handle.GamepadNumberChanged:Connect(function(field: string, value: number)
		(gamepadSettings :: { [string]: any })[field] = value
		handle.Gamepad:set(table.clone(gamepadSettings))
		applyGamepadSettings()

		local updateGamepadRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateGamepad)
		updateGamepadRemote:FireServer(field, value)
	end)

	handle.GamepadToggled:Connect(function(field: string, enabled: boolean)
		(gamepadSettings :: { [string]: any })[field] = enabled
		handle.Gamepad:set(table.clone(gamepadSettings))
		applyGamepadSettings()

		local updateGamepadRemote = NetworkBridge.GetRemoteEvent(RemoteNames.UpdateGamepad)
		updateGamepadRemote:FireServer(field, enabled)
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
