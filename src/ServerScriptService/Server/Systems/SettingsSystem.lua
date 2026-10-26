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
local Schema = require(ReplicatedStorage.Shared.Schema)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local SettingsSlice = require(script.Parent.Parent.Data.Slices.SettingsSlice)

local logger = Logger.scope("SettingsSystem")

local SettingsSystem = {}

local RemoteNames = Constants.Settings.RemoteNames

-- One shared budget across every mutating remote this module owns -- a rebind/reset/toggle burst is
-- all the same "cheap, gameplay-inert settings write" category, the same reasoning
-- Constants.Rivalry.QueryMaxCallsPerSecond gives for its own single shared limiter.
local rateLimiter = RateLimiter.New(Constants.Settings.MaxCallsPerSecondPerPlayer)
-- GetSettings' own bucket (see SettingsConstants.GetMaxCallsPerSecondPerPlayer).
local getRateLimiter = RateLimiter.New(Constants.Settings.GetMaxCallsPerSecondPerPlayer)

local DEFAULT_SETTINGS: Types.PlayerSettings = {
	Keybinds = {},
	GamepadKeybinds = {},
	Autorun = false,
	Parkour = SettingsSlice.CreateDefaultParkourSettings(),
	Comfort = SettingsSlice.CreateDefaultComfortSettings(),
	Gamepad = SettingsSlice.CreateDefaultGamepadSettings(),
	UI = SettingsSlice.CreateDefaultUISettings(),
}

-- The closed set of fields a client may write in each settings group, and the shape each value is judged by. A
-- single remote carries a field NAME (see Constants.Settings.RemoteNames.UpdateParkour's own header for why one
-- remote rather than eight), which makes the name untrusted input, so it is looked up here: a field absent from a
-- group's table cannot be written no matter what a client sends, and retiring a preference is a deletion here
-- rather than a hole in the validation.
--
-- A boolean field is REJECTED when it is not a boolean. A NUMBER is CLAMPED into its bound and rejected only when
-- it is not a real number (NaN included): a rejected write leaves the server holding a different value than the
-- client already applied locally, and the two only reconcile on next login, so a slider dragged one pixel too far
-- would appear to work all session and silently revert. Constants.Settings.Gamepad.Bounds / UI.Bounds are the
-- shared source of the numbers -- PlayerDataSystem's own decoder clamps to the same tables on read.
local GamepadBounds = Constants.Settings.Gamepad.Bounds :: { [string]: any }
local UIBounds = Constants.Settings.UI.Bounds :: { [string]: any }

type Group = {
	-- The key under Types.PlayerSettings.
	Key: string,
	Write: (rawField: unknown, rawValue: unknown) -> (string?, any?, string?),
	Default: () -> { [string]: any },
}

local GROUPS: { [string]: Group } = {
	Parkour = {
		Key = "Parkour",
		Write = Schema.FieldValue({
			Enabled = Schema.Boolean,
			CameraEffects = Schema.Boolean,
			CoyoteTime = Schema.Boolean,
			JumpBuffer = Schema.Boolean,
			AutoVault = Schema.Boolean,
			LedgeAssist = Schema.Boolean,
			StepAssist = Schema.Boolean,
			SprintMode = Schema.Enum({ "Hold", "Toggle" }),
		}),
		Default = SettingsSlice.CreateDefaultParkourSettings,
	},
	Comfort = {
		Key = "Comfort",
		Write = Schema.FieldValue({
			CameraShake = Schema.Boolean,
			FieldOfViewEffects = Schema.Boolean,
			VehicleCameraMotion = Schema.Boolean,
		}),
		Default = SettingsSlice.CreateDefaultComfortSettings,
	},
	Gamepad = {
		Key = "Gamepad",
		Write = Schema.FieldValue({
			LookSensitivity = Schema.Number(GamepadBounds.LookSensitivity.Min, GamepadBounds.LookSensitivity.Max),
			MoveDeadzone = Schema.Number(GamepadBounds.Deadzone.Min, GamepadBounds.Deadzone.Max),
			LookDeadzone = Schema.Number(GamepadBounds.Deadzone.Min, GamepadBounds.Deadzone.Max),
			InvertLookY = Schema.Boolean,
			Vibration = Schema.Boolean,
		}),
		Default = SettingsSlice.CreateDefaultGamepadSettings,
	},
	UI = {
		Key = "UI",
		Write = Schema.FieldValue({
			Scale = Schema.Number(UIBounds.Scale.Min, UIBounds.Scale.Max),
		}),
		Default = SettingsSlice.CreateDefaultUISettings,
	},
}

local KEYBIND_DEVICE = Schema.Enum({ "Keyboard", "Gamepad" })
local KEY_CODE = Schema.EnumItem(Enum.KeyCode)
local USER_INPUT_TYPE = Schema.EnumItem(Enum.UserInputType)

-- See file header -- structurally valid AND not a hotbar slot. Constants.Keybinds.Defaults is a
-- complete map of every currently-known KeybindAction (KeybindManager.lua's own header), so
-- membership there is the correct "is this a real action" check.
local function isRebindableAction(action: string): boolean
	return (Constants.Keybinds.Defaults :: { [string]: any })[action] ~= nil and not string.match(action, "^HotbarSlot")
end

-- Exactly one of KeyCode/UserInputType, both real EnumItems of the right EnumType -- mirrors
-- Types.Keybind's own "exactly one populated" contract. A RemoteEvent argument can carry a real
-- EnumItem natively (unlike a DataStore write -- see PlayerDataSystem.lua's own encode/decode pair
-- for why THAT boundary has to stringify), so no pcall/string-lookup is needed here, just a type
-- check. A field of the wrong kind counts as absent (it does not veto the other), as it always did.
local function validateKeybind(raw: unknown): Types.Keybind?
	if not Schema.IsTable(raw) then
		return nil
	end
	local rawTable = raw :: { [string]: any }
	local keyCode = Schema.Decode(KEY_CODE, rawTable.KeyCode)
	local userInputType = Schema.Decode(USER_INPUT_TYPE, rawTable.UserInputType)

	if keyCode and not userInputType then
		return { KeyCode = keyCode :: Enum.KeyCode }
	end
	if userInputType and not keyCode then
		return { UserInputType = userInputType :: Enum.UserInputType }
	end
	return nil
end

-- The pure halves of the handlers below, public so the old-vs-new corpus spec (and anything that wants to ask
-- "would this write be accepted") can call them without a Player or a profile.

-- (device, action, keybind) for an UpdateKeybind payload, or nil when any part is refused.
function SettingsSystem.DecodeKeybindUpdate(
	rawDevice: unknown,
	rawAction: unknown,
	rawKeybind: unknown
): (Types.KeybindDevice?, Types.KeybindAction?, Types.Keybind?)
	local device = Schema.Decode(KEYBIND_DEVICE, rawDevice)
	if device == nil then
		return nil
	end
	if not Schema.IsString(rawAction) or not isRebindableAction(rawAction :: string) then
		return nil
	end
	local keybind = validateKeybind(rawKeybind)
	if not keybind then
		return nil
	end
	return device :: Types.KeybindDevice, rawAction :: Types.KeybindAction, keybind
end

function SettingsSystem.DecodeDevice(rawDevice: unknown): Types.KeybindDevice?
	return Schema.Decode(KEYBIND_DEVICE, rawDevice) :: Types.KeybindDevice?
end

-- (field, value) for a write into `groupName` ("Parkour"/"Comfort"/"Gamepad"/"UI"), or (nil, nil, reason).
function SettingsSystem.DecodeGroupWrite(
	groupName: string,
	rawField: unknown,
	rawValue: unknown
): (string?, any?, string?)
	return GROUPS[groupName].Write(rawField, rawValue)
end

local function handleGetSettings(player: Player): Types.PlayerSettings
	if getRateLimiter:IsLimited(player) then
		-- NOT the defaults: the client applies whatever table it is handed as the player's real settings, and
		-- cannot tell defaults from a saved profile. nil is its existing "the fetch failed" path, which keeps
		-- the session's own defaults and says so in the log. A legitimate boot read never gets here.
		logger:warn("GetSettings rejected: rate limited", { player = player.Name })
		return nil :: any
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
	local device, action, keybind = SettingsSystem.DecodeKeybindUpdate(rawDevice, rawAction, rawKeybind)
	if device == nil or action == nil or keybind == nil then
		logger:debug("UpdateKeybind rejected: invalid device, action or keybind", { player = player.Name })
		return
	end

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
	local device = SettingsSystem.DecodeDevice(rawDevice)
	if device == nil then
		logger:debug("ResetKeybinds rejected: invalid device", { player = player.Name })
		return
	end

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
	local enabled = Schema.Decode(Schema.Boolean, rawEnabled)
	if enabled == nil then
		logger:debug("UpdateAutorun rejected: non-boolean value", { player = player.Name })
		return
	end

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		profile.settings.Autorun = enabled
	end)
	if not transformed then
		logger:warn("UpdateAutorun: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	logger:debug("Autorun persisted", { player = player.Name, enabled = enabled })
end

-- One handler per settings group (Parkour, Comfort, Gamepad, UI): rate limit, closed-set field + typed value
-- validation through the group's own table, then persist through PlayerDataSystem.Transform with a defensive
-- backfill. The four used to be four copies of this body; they differed only in the table they wrote, the closed
-- set they validated against and the log label. They stay SEPARATE REMOTES (each group's field names are only
-- valid for its own group -- one shared handler would accept a Comfort field name for Parkour).
--
-- The backfill is defensive: a profile loaded from a record that missed the group's migration (Parkour [4],
-- Comfort [5], UI [9]) or that predates a group which ships with none (Gamepad) has no table to write into, and
-- one stale record must not make the whole Settings panel non-functional for that player.
--
-- Note what this deliberately does NOT do: it never tells any other System that a preference changed. The client
-- has already applied the change locally (SettingsClient pushes it straight into the consumer) before firing
-- this, exactly as it does for a rebind, so this exists purely to make the change durable. The server has no
-- behaviour keyed off these preferences -- every one is client-side feel.
local function makeGroupHandler(groupName: string): (Player, unknown, unknown) -> ()
	local group = GROUPS[groupName]
	return function(player: Player, rawField: unknown, rawValue: unknown): ()
		if rateLimiter:IsLimited(player) then
			return
		end
		local field, value, reason = group.Write(rawField, rawValue)
		if field == nil then
			logger:debug(`Update{groupName} rejected: {reason}`, { player = player.Name })
			return
		end

		local transformed = PlayerDataSystem.Transform(player, function(profile)
			local settings = profile.settings :: { [string]: any }
			if not Schema.IsTable(settings[group.Key]) then
				settings[group.Key] = group.Default()
			end
			settings[group.Key][field] = value
		end)
		if not transformed then
			logger:warn(`Update{groupName}: Transform failed (profile not loaded)`, { player = player.Name })
			return
		end

		logger:debug(`{groupName} setting persisted`, { player = player.Name, field = field })
	end
end

local function onPlayerRemoving(player: Player): ()
	rateLimiter:Clear(player)
	getRateLimiter:Clear(player)
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
	updateParkourRemote.OnServerEvent:Connect(makeGroupHandler("Parkour"))

	local updateComfortRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateComfort)
	updateComfortRemote.OnServerEvent:Connect(makeGroupHandler("Comfort"))

	local updateGamepadRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateGamepad)
	updateGamepadRemote.OnServerEvent:Connect(makeGroupHandler("Gamepad"))

	local updateUIRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateUI)
	updateUIRemote.OnServerEvent:Connect(makeGroupHandler("UI"))

	PlayerLifecycle.BindAllPlayers({
		Scope = "SettingsSystem",
		OnPlayerRemoving = onPlayerRemoving,
	})

	logger:info("SettingsSystem.Init() complete")
end

return SettingsSystem :: Types.SystemModule
