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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("SettingsSystem")

local SettingsSystem = {}

local RemoteNames = Constants.Settings.RemoteNames

-- One shared budget across every mutating remote this module owns -- a rebind/reset/toggle burst is
-- all the same "cheap, gameplay-inert settings write" category, the same reasoning
-- Constants.Rivalry.QueryMaxCallsPerSecond gives for its own single shared limiter.
local rateLimiter = RateLimiter.New(Constants.Settings.MaxCallsPerSecondPerPlayer)

local DEFAULT_SETTINGS: Types.PlayerSettings = { Keybinds = {}, GamepadKeybinds = {}, Autorun = false }

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

local function onPlayerRemoving(player: Player): ()
	rateLimiter:Clear(player)
end

function SettingsSystem.Init(): ()
	local getSettingsRemote = NetworkBridge.CreateRemoteFunction(RemoteNames.GetSettings)
	getSettingsRemote.OnServerInvoke = handleGetSettings

	local updateKeybindRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateKeybind)
	updateKeybindRemote.OnServerEvent:Connect(handleUpdateKeybind)

	local resetKeybindsRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.ResetKeybinds)
	resetKeybindsRemote.OnServerEvent:Connect(handleResetKeybinds)

	local updateAutorunRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.UpdateAutorun)
	updateAutorunRemote.OnServerEvent:Connect(handleUpdateAutorun)

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	logger:info("SettingsSystem.Init() complete")
end

return SettingsSystem :: Types.SystemModule
