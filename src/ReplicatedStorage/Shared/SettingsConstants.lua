--!strict
--[[
	SettingsConstants.lua

	Owns: the player-preferences surface -- the remote names the settings round trip uses for each
	preference group (rebound keybinds, Parkour, Comfort, Gamepad), the per-player call budget that
	guards them, and the UI's own status-clear delay.

	Lifted out of Constants.lua, moved verbatim -- no type annotations, no cross-references, nothing
	rewritten but the table statement itself. Constants.Settings re-exports this module, so all
	forty-eight existing Constants.Settings.X call sites keep working; new code should require this
	module directly.

	A REMOTE SURFACE, NOT A SCHEMA. What a preference group CONTAINS is Types.PlayerSettings /
	ParkourSettings / ComfortSettings / GamepadSettings, and what a preference is worth is owned by
	the system it tunes -- ParkourConstants for the parkour toggles, Analog's own shipped defaults for
	the stick curves, KeybindConstants for the default bindings a rebind overrides. This file only
	names the wires and bounds how often a client may pull them.

	Does not own: persistence (PlayerDataSystem owns the profile and its schema version), validation
	of a submitted value (Server/Systems/SettingsSystem.lua checks each against the owning system's
	bounds), or the defaults any of it overrides.
]]

-- Settings System (Server/Systems/SettingsSystem.lua, Client/Settings/SettingsClient.lua) --
-- persists Types.PlayerSettings (rebound keybind overrides + Autorun) through PlayerDataSystem and
-- restores them into Client/Input/KeybindManager.lua on join. Kept as its own table rather than
-- folded in with the keybinds themselves -- Shared/Input/KeybindConstants.lua is static
-- DEFAULT-binding content, while this is remote-name/networking config for a feature built on top
-- of it, the same "distinct feature, distinct table" split Constants.PlayerData's own header draws
-- against Constants.BugReport. The two used to be adjacent tables in Constants.lua, which is what
-- made "above" a meaningful word here; they are two modules now.
local SettingsConstants = {
	RemoteNames = {
		-- RemoteFunction, no payload -- fetched once by SettingsClient.Start() (same "client needs an
		-- immediate, race-free answer at boot" reasoning as CharacterCreation_GetOnboardingState)
		-- rather than a server push on PlayerDataSystem.OnProfileLoaded: a push fired before this
		-- client has connected its own listener (a real risk here -- IntroClient/LoadingClient both
		-- block Main.client.lua well past the moment a profile can finish loading server-side) would
		-- be silently lost with no corrective resync, unlike Combat_VitalsUpdated's own continuously-
		-- refreshed value. A request/response round trip has no such window: it always reflects
		-- whatever PlayerDataSystem already has loaded by the time this client asks.
		GetSettings = "Settings_GetSettings",
		-- Fire-and-forget persistence writes -- the client has already applied each of these locally
		-- (KeybindManager.Rebind/RebindGamepad/ResetToDefaults/ResetGamepadToDefaults, or its own
		-- Autorun toggle) before firing, so there is nothing for the server to echo back; these exist
		-- purely to make the change durable across sessions.
		UpdateKeybind = "Settings_UpdateKeybind",
		ResetKeybinds = "Settings_ResetKeybinds",
		UpdateAutorun = "Settings_UpdateAutorun",
		-- Parkour System preferences (Types.ParkourSettings) -- one remote carrying a field name plus a
		-- value, rather than eight single-purpose remotes. That is the opposite of the choice made for
		-- Autorun above (its own remote, no payload beyond the boolean), and deliberately so: Autorun
		-- is one settled preference, where the Parkour block is a group expected to grow and shrink as
		-- that feature is tuned, and a remote per assist would mean a NetworkBridge registration, a
		-- handler and a client call site for every one. The cost is that the field name becomes
		-- untrusted input -- handled by SettingsSystem validating it against a closed set, exactly as
		-- isRebindableAction already does for keybind actions.
		UpdateParkour = "Settings_UpdateParkour",
		-- Camera-comfort preferences (Types.ComfortSettings) -- same field-name-plus-value shape as
		-- UpdateParkour above, and chosen for the same reason: this is a group expected to gain
		-- entries as more accessibility options are added, and a remote per toggle would mean a
		-- NetworkBridge registration, a handler and a client call site for each one. The field name is
		-- therefore untrusted input, validated against a closed set server-side exactly as
		-- PARKOUR_SETTING_TYPES already does.
		UpdateComfort = "Settings_UpdateComfort",
		-- Gamepad device preferences (Types.GamepadSettings) -- same field-name-plus-value shape as
		-- UpdateParkour/UpdateComfort above, and chosen for the same reason. Unlike those two, this
		-- group's values are not all booleans (three of the five are numbers), so the closed set
		-- server-side carries a value TYPE per field and the numeric ones are clamped to Gamepad.Bounds
		-- below rather than merely type-checked -- a client is free to send 400 for a sensitivity, and
		-- the answer is to clamp it, not to trust it or to drop the write.
		UpdateGamepad = "Settings_UpdateGamepad",
	},

	-- The shipped gamepad stick defaults, and the range each numeric one may be set to. Lives HERE, in
	-- shared Constants, rather than in Client/Input/Analog.lua where it is consumed, because the
	-- SERVER has to validate writes against the same numbers and cannot require a client module --
	-- Analog.lua reads its own DEFAULT_CONFIG out of this table so there is exactly one source of
	-- truth, the same rule Types.ParkourSettings follows against ParkourConstants.
	Gamepad = {
		Defaults = {
			LookSensitivity = 1,
			-- Roughly the point at which a healthy stick's resting noise stops registering, without
			-- eating enough of the range to make small corrections impossible.
			MoveDeadzone = 0.2,
			LookDeadzone = 0.2,
			InvertLookY = false,
			Vibration = true,
		},
		-- Inclusive. The deadzone ceiling is deliberately well below 1: a deadzone at or near 1 is not
		-- a preference, it is a stick that no longer works, and Analog.ApplyStick would return zero
		-- for every input. The sensitivity floor is likewise above 0 for the same reason -- a
		-- sensitivity of 0 is indistinguishable from a broken controller, and a player who set it by
		-- accident would have no way to reach the menu to undo it on a pad.
		Bounds = {
			LookSensitivity = { Min = 0.25, Max = 4 },
			Deadzone = { Min = 0, Max = 0.6 },
		},
	},
	-- Same call-budget reasoning as Constants.Rivalry.QueryMaxCallsPerSecond -- a rebind/toggle write
	-- costs nothing gameplay-wise but should still never be free spam.
	MaxCallsPerSecondPerPlayer = 4,
	-- Same "named duration, not a magic number at the call site" convention as
	-- Constants.Debug.DevMenu.StatusClearDelaySeconds/Constants.BugReport.ConfirmationClearDelaySeconds
	-- -- Client/Settings/SettingsClient.lua's own status line (e.g. "Keybinds reset to defaults.").
	StatusClearDelaySeconds = 3,
}

return SettingsConstants
