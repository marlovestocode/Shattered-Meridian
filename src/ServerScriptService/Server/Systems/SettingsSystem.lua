--!strict
--[[
	SettingsSystem.lua

	Owns: persistence for Types.PlayerSettings (rebound keybind overrides + Autorun) and every Remote
	this feature exposes (Constants.Settings.RemoteNames). Client/Input/KeybindManager.lua stays the
	live, in-session source of truth for "what key is bound right now" -- this module never decides
	what a key does, only whether a rebind/reset/toggle request is well-formed enough to persist
	through PlayerDataSystem.Transform. Client/Settings/SettingsClient.lua is the one caller: it
	applies a rebind to KeybindManager FIRST (so the local session sees it immediately, no round
	trip), then fires the matching Update*/Reset* remote here purely to make that change durable.

	Persists exclusively through PlayerDataSystem.Transform/GetProfile (Types.PlayerProfile.settings)
	-- never a DataStore call of its own, the same "one serialized entry point per player's data"
	discipline EmoteUnlockService.lua already follows for its own slice of the profile.

	Every mutating handler re-validates its own device/action/keybind shape server-side regardless of
	what KeybindManager already accepted client-side (engineering-standards.md: never trust
	client-provided gameplay information) -- isRebindableAction rejects any HotbarSlot* action (those
	stay fixed per the Settings panel's own design) and anything that isn't a currently-known
	KeybindAction; validateKeybind rejects anything that isn't exactly one real Enum.KeyCode or
	Enum.UserInputType.

	Does not own: what a KeybindAction's default binding is (Constants.Keybinds.Defaults/
	GamepadDefaults), or the Settings panel itself (Client/UI/Screens/Settings/init.lua) -- this
	module only persists what a client already decided to bind.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("SettingsSystem")

local SettingsSystem = {}

local RemoteNames = Constants.Settings.RemoteNames

-- One shared budget across every mutating remote this module owns -- a rebind/reset/toggle burst is
-- all the same "cheap, gameplay-inert settings write" category, the same reasoning
-- Constants.Rivalry.QueryMaxCallsPerSecond gives for its own single shared limiter.
local rateLimiter = RateLimiter.New(Constants.Settings.MaxCallsPerSecondPerPlayer)

local DEFAULT_SETTINGS: Types.PlayerSettings = {
	Keybinds = {},
	GamepadKeybinds = {},
	Autorun = false,
	Parkour = PlayerDataSystem.CreateDefaultParkourSettings(),
	Comfort = PlayerDataSystem.CreateDefaultComfortSettings(),
	Gamepad = PlayerDataSystem.CreateDefaultGamepadSettings(),
}

-- The closed set of Types.ParkourSettings fields a client may write, and the value type each one
-- accepts. A single remote carries a field name (see Constants.Settings.RemoteNames.UpdateParkour's
-- own header for why one remote rather than eight), which makes the field name untrusted input --
-- so it is validated against this table exactly the way isRebindableAction below validates a keybind
-- action. A field absent from here cannot be written no matter what a client sends, which also means
-- retiring a preference is a deletion here rather than a hole in the validation.
local PARKOUR_SETTING_TYPES: { [string]: "boolean" | "SprintMode" } = {
	Enabled = "boolean",
	CameraEffects = "boolean",
	CoyoteTime = "boolean",
	JumpBuffer = "boolean",
	AutoVault = "boolean",
	LedgeAssist = "boolean",
	StepAssist = "boolean",
	SprintMode = "SprintMode",
}

-- The closed set of Types.ComfortSettings fields a client may write. Same role, same reasoning and
-- same untrusted-field-name posture as PARKOUR_SETTING_TYPES above; every entry is a plain boolean, so
-- this one needs no value-type column at all.
local COMFORT_SETTING_FIELDS: { [string]: true } = {
	CameraShake = true,
	FieldOfViewEffects = true,
	VehicleCameraMotion = true,
}

-- The closed set of Types.GamepadSettings fields a client may write. Same role and same
-- untrusted-field-name posture as the two tables above, but this one needs a value-type column that
-- COMFORT_SETTING_FIELDS did not: three of the five fields are numbers, and a number field needs the
-- bounds it is clamped into as well as its type. Constants.Settings.Gamepad.Bounds is the shared
-- source of those numbers -- Server/Systems/PlayerDataSystem.lua's own decoder clamps to the same
-- table on read, so a value can only be out of range if it never went through either path.
local GAMEPAD_SETTING_TYPES: { [string]: "boolean" | "LookSensitivity" | "Deadzone" } = {
	LookSensitivity = "LookSensitivity",
	MoveDeadzone = "Deadzone",
	LookDeadzone = "Deadzone",
	InvertLookY = "boolean",
	Vibration = "boolean",
}

-- See file header -- structurally valid AND not a hotbar slot. Constants.Keybinds.Defaults is a
-- complete map of every currently-known KeybindAction (KeybindManager.lua's own header), so
-- membership there is the correct "is this a real action" check.
local function isRebindableAction(action: string): boolean
	return (Constants.Keybinds.Defaults :: { [string]: any })[action] ~= nil and not string.match(action, "^HotbarSlot")
end

local function isKeybindDevice(value: unknown): boolean
	return value == "Keyboard" or value == "Gamepad"
end

-- Exactly one of KeyCode/UserInputType, both real EnumItems of the right EnumType -- mirrors
-- Types.Keybind's own "exactly one populated" contract. A RemoteEvent argument can carry a real
-- EnumItem natively (unlike a DataStore write -- see PlayerDataSystem.lua's own encode/decode pair
-- for why THAT boundary has to stringify), so no pcall/string-lookup is needed here, just a type
-- check.
local function validateKeybind(raw: unknown): Types.Keybind?
	if typeof(raw) ~= "table" then
		return nil
	end
	local rawTable = raw :: { [string]: any }
	local keyCode = rawTable.KeyCode
	local userInputType = rawTable.UserInputType
	local hasKeyCode = typeof(keyCode) == "EnumItem" and (keyCode :: EnumItem).EnumType == Enum.KeyCode
	local hasUserInputType = typeof(userInputType) == "EnumItem"
		and (userInputType :: EnumItem).EnumType == Enum.UserInputType

	if hasKeyCode and not hasUserInputType then
		return { KeyCode = keyCode :: Enum.KeyCode }
	end
	if hasUserInputType and not hasKeyCode then
		return { UserInputType = userInputType :: Enum.UserInputType }
	end
	return nil
end

local function handleGetSettings(player: Player): Types.PlayerSettings
	if rateLimiter:IsLimited(player) then
		return DEFAULT_SETTINGS
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		logger:warn("GetSettings called before profile loaded -- returning inert defaults", { player = player.Name })
		return DEFAULT_SETTINGS
	end
	return profile.settings
end

local function handleUpdateKeybind(player: Player, rawDevice: unknown, rawAction: unknown, rawKeybind: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if not isKeybindDevice(rawDevice) then
		logger:debug("UpdateKeybind rejected: invalid device", { player = player.Name })
		return
	end
	if typeof(rawAction) ~= "string" or not isRebindableAction(rawAction) then
		logger:debug("UpdateKeybind rejected: invalid action", { player = player.Name, action = tostring(rawAction) })
		return
	end
	local keybind = validateKeybind(rawKeybind)
	if not keybind then
		logger:debug("UpdateKeybind rejected: invalid keybind shape", { player = player.Name })
		return
	end

	local device = rawDevice :: Types.KeybindDevice
	local action = rawAction :: Types.KeybindAction

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		if device == "Keyboard" then
			profile.settings.Keybinds[action] = keybind
		else
			profile.settings.GamepadKeybinds[action] = keybind
		end
	end)
	if not transformed then
		logger:warn("UpdateKeybind: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Keybind persisted", { player = player.Name, device = device, action = action })
end

local function handleResetKeybinds(player: Player, rawDevice: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if not isKeybindDevice(rawDevice) then
		logger:debug("ResetKeybinds rejected: invalid device", { player = player.Name })
		return
	end
	local device = rawDevice :: Types.KeybindDevice

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		if device == "Keyboard" then
			profile.settings.Keybinds = {}
		else
			profile.settings.GamepadKeybinds = {}
		end
	end)
	if not transformed then
		logger:warn("ResetKeybinds: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Keybinds reset to defaults", { player = player.Name, device = device })
end

local function handleUpdateAutorun(player: Player, rawEnabled: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawEnabled) ~= "boolean" then
		logger:debug("UpdateAutorun rejected: non-boolean value", { player = player.Name })
		return
	end

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		profile.settings.Autorun = rawEnabled
	end)
	if not transformed then
		logger:warn("UpdateAutorun: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Autorun persisted", { player = player.Name, enabled = rawEnabled })
end

-- Parkour preference write. Same shape as handleUpdateAutorun above -- validate, persist through
-- PlayerDataSystem.Transform, log -- with the extra step of validating the field NAME against
-- PARKOUR_SETTING_TYPES first, since this remote's payload includes which field to write.
--
-- Note what this handler deliberately does NOT do: it never tells any other System that movement
-- preferences changed. The client has already applied the change locally (SettingsClient pushes it
-- straight into ParkourController) before firing this, exactly as it does for a rebind, so this
-- exists purely to make the change durable. The server has no behavior keyed off these preferences --
-- every one of them is client-side feel -- which is why persisting them is the whole job.
local function handleUpdateParkour(player: Player, rawField: unknown, rawValue: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawField) ~= "string" then
		logger:debug("UpdateParkour rejected: non-string field", { player = player.Name })
		return
	end
	local field = rawField :: string
	local expectedType = PARKOUR_SETTING_TYPES[field]
	if not expectedType then
		logger:debug("UpdateParkour rejected: unknown field", { player = player.Name, field = field })
		return
	end

	local value: any
	if expectedType == "boolean" then
		if typeof(rawValue) ~= "boolean" then
			logger:debug("UpdateParkour rejected: expected boolean", { player = player.Name, field = field })
			return
		end
		value = rawValue
	else
		if rawValue ~= "Hold" and rawValue ~= "Toggle" then
			logger:debug("UpdateParkour rejected: invalid SprintMode", { player = player.Name })
			return
		end
		value = rawValue
	end

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		-- Defensive: a profile loaded from a record that predates the Parkour block and somehow missed
		-- Migrations[4] would have no table to write into. Backfilling here rather than erroring keeps
		-- one stale record from making the whole Settings panel non-functional for that player.
		if typeof(profile.settings.Parkour) ~= "table" then
			profile.settings.Parkour = PlayerDataSystem.CreateDefaultParkourSettings()
		end
		(profile.settings.Parkour :: { [string]: any })[field] = value
	end)
	if not transformed then
		logger:warn("UpdateParkour: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Parkour setting persisted", { player = player.Name, field = field })
end

-- Camera-comfort preferences. Mirrors handleUpdateParkour above exactly -- rate limit, closed-set
-- field validation, typed value check, Transform-with-defensive-backfill -- and is a separate handler
-- rather than a branch inside it because the two write different sub-tables and validate against
-- different closed sets; sharing one handler would mean a field name from either group being accepted
-- for the other.
local function handleUpdateComfort(player: Player, rawField: unknown, rawValue: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawField) ~= "string" then
		logger:debug("UpdateComfort rejected: non-string field", { player = player.Name })
		return
	end
	local field = rawField :: string
	if not COMFORT_SETTING_FIELDS[field] then
		logger:debug("UpdateComfort rejected: unknown field", { player = player.Name, field = field })
		return
	end
	if typeof(rawValue) ~= "boolean" then
		logger:debug("UpdateComfort rejected: expected boolean", { player = player.Name, field = field })
		return
	end
	local value = rawValue :: boolean

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		-- Defensive, for the same reason handleUpdateParkour's own backfill is: a profile that somehow
		-- missed Migrations[5] would have no table to write into, and one stale record must not make
		-- the whole Settings panel non-functional for that player.
		if typeof(profile.settings.Comfort) ~= "table" then
			profile.settings.Comfort = PlayerDataSystem.CreateDefaultComfortSettings()
		end
		(profile.settings.Comfort :: { [string]: any })[field] = value
	end)
	if not transformed then
		logger:warn("UpdateComfort: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Comfort setting persisted", { player = player.Name, field = field })
end

-- Gamepad stick preferences. Mirrors handleUpdateComfort above -- rate limit, closed-set field
-- validation, Transform-with-defensive-backfill -- and differs in exactly one place: a numeric field
-- is CLAMPED rather than rejected when it arrives out of range.
--
-- CLAMP, DON'T DROP, and the reason is the player rather than the protocol. A rejected write leaves
-- the server holding a different value than the client already applied locally, and the two only
-- reconcile on next login -- so a slider dragged one pixel too far would appear to work all session
-- and silently revert. Clamping keeps the two ends agreeing on a value that is always usable. A
-- non-numeric or NaN value IS dropped, because there is nothing sensible to clamp it to.
local function handleUpdateGamepad(player: Player, rawField: unknown, rawValue: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawField) ~= "string" then
		logger:debug("UpdateGamepad rejected: non-string field", { player = player.Name })
		return
	end
	local field = rawField :: string
	local expected = GAMEPAD_SETTING_TYPES[field]
	if not expected then
		logger:debug("UpdateGamepad rejected: unknown field", { player = player.Name, field = field })
		return
	end

	local value: any
	if expected == "boolean" then
		if typeof(rawValue) ~= "boolean" then
			logger:debug("UpdateGamepad rejected: expected boolean", { player = player.Name, field = field })
			return
		end
		value = rawValue
	else
		-- `value ~= value` is the NaN test: NaN is the one number math.clamp cannot rescue, since it
		-- compares false against every bound and would propagate straight through to Analog.ApplyStick.
		if typeof(rawValue) ~= "number" or rawValue ~= rawValue then
			logger:debug("UpdateGamepad rejected: expected a real number", { player = player.Name, field = field })
			return
		end
		local bounds = (Constants.Settings.Gamepad.Bounds :: { [string]: any })[expected]
		value = math.clamp(rawValue :: number, bounds.Min, bounds.Max)
	end

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		-- Defensive backfill, same reasoning as handleUpdateComfort's: this group ships with no
		-- migration of its own (see PlayerDataSystem.DecodeSettings' note on why), so an in-memory
		-- profile loaded from a pre-Gamepad record legitimately has no table here yet.
		if typeof(profile.settings.Gamepad) ~= "table" then
			profile.settings.Gamepad = PlayerDataSystem.CreateDefaultGamepadSettings()
		end
		(profile.settings.Gamepad :: { [string]: any })[field] = value
	end)
	if not transformed then
		logger:warn("UpdateGamepad: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Gamepad setting persisted", { player = player.Name, field = field })
end

local function onPlayerRemoving(player: Player): ()
	rateLimiter:Clear(player)
end

function SettingsSystem.Init(): ()
	local getSettingsRemote = NetworkBridge.CreateRemoteFunction(RemoteNames.GetSettings)
	getSettingsRemote.OnServerInvoke =
		RemoteHandler.WrapInvoke(logger, "GetSettings", DEFAULT_SETTINGS, handleGetSettings)

	local updateKeybindRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateKeybind)
	updateKeybindRemote.OnServerEvent:Connect(handleUpdateKeybind)

	local resetKeybindsRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.ResetKeybinds)
	resetKeybindsRemote.OnServerEvent:Connect(handleResetKeybinds)

	local updateAutorunRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateAutorun)
	updateAutorunRemote.OnServerEvent:Connect(handleUpdateAutorun)

	local updateParkourRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateParkour)
	updateParkourRemote.OnServerEvent:Connect(handleUpdateParkour)

	local updateComfortRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateComfort)
	updateComfortRemote.OnServerEvent:Connect(handleUpdateComfort)

	local updateGamepadRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateGamepad)
	updateGamepadRemote.OnServerEvent:Connect(handleUpdateGamepad)

	PlayerLifecycle.BindAllPlayers({
		Scope = "SettingsSystem",
		OnPlayerRemoving = onPlayerRemoving,
	})

	logger:info("SettingsSystem.Init() complete")
end

return SettingsSystem :: Types.SystemModule
