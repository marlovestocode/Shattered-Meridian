--!strict
--[[
	SettingsStore.lua

	Owns: the local player's live settings, by group (Parkour, Comfort, Gamepad, UI, Autorun), as an observable store.
	`Get(group)` reads one; `Observe(group, fn)` hands `fn` the current value at once and every later one, and returns the
	disconnect; `Set(group, value)` replaces a group and tells its observers.

	WHY (coworking plan F8, W14). SettingsClient used to be a push-hub: it required ParkourController, RunController, CameraShake,
	FOVOffset, BlimpCamera and Analog, and called each one's setter from five apply*Settings functions every time a value was
	restored or changed. A new setting meant editing the screen's client in two places and adding a gameplay require to it. Now each
	consumer subscribes to its own group from its own Start, and SettingsClient only writes here -- it keeps persistence, the
	write coalescer and the screen, and requires no gameplay module (Tests/Settings/SettingsStore.spec.lua checks that).

	THE DEFAULTS ARE THE ONES SettingsClient HELD: a consumer that subscribes before the profile's settings arrive is handed the
	same values the old hub's locals started from, which are the values each consumer already defaulted to itself.

	Values are handed out as copies; mutating one changes nothing. Does not own persistence, validation of a stored record
	(SettingsClient's RestoreSettings), or the screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local logger = Logger.scope("SettingsStore")

export type Group = "Parkour" | "Comfort" | "Gamepad" | "UI" | "Autorun"

local SettingsStore = {}

local function defaults(): { [Group]: any }
	return {
		Parkour = {
			Enabled = ParkourConstants.Enabled,
			CameraEffects = true,
			CoyoteTime = ParkourConstants.Assists.CoyoteTime,
			JumpBuffer = ParkourConstants.Assists.JumpBuffer,
			AutoVault = ParkourConstants.Assists.AutoVault,
			LedgeAssist = ParkourConstants.Assists.LedgeAssist,
			StepAssist = ParkourConstants.Assists.StepAssist,
			SprintMode = "Hold",
		} :: Types.ParkourSettings,
		Comfort = {
			CameraShake = true,
			FieldOfViewEffects = true,
			VehicleCameraMotion = true,
		} :: Types.ComfortSettings,
		Gamepad = {
			LookSensitivity = Constants.Settings.Gamepad.Defaults.LookSensitivity,
			MoveDeadzone = Constants.Settings.Gamepad.Defaults.MoveDeadzone,
			LookDeadzone = Constants.Settings.Gamepad.Defaults.LookDeadzone,
			InvertLookY = Constants.Settings.Gamepad.Defaults.InvertLookY,
			Vibration = Constants.Settings.Gamepad.Defaults.Vibration,
		} :: Types.GamepadSettings,
		UI = {
			Scale = Constants.Settings.UI.Defaults.Scale,
		} :: Types.UISettings,
		Autorun = false,
	}
end

local values = defaults()
local observers: { [Group]: CallbackList.CallbackList<any> } = {}

local function copy(value: any): any
	return if typeof(value) == "table" then table.clone(value) else value
end

local function listOf(group: Group): CallbackList.CallbackList<any>
	local list = observers[group]
	if list == nil then
		list = CallbackList.New(logger, `SettingsStore.Observe({group})`)
		observers[group] = list
	end
	return list
end

function SettingsStore.Get(group: Group): any
	assert(values[group] ~= nil, `SettingsStore.Get: unknown group "{group}"`)
	return copy(values[group])
end

function SettingsStore.Set(group: Group, value: any): ()
	assert(values[group] ~= nil, `SettingsStore.Set: unknown group "{group}"`)
	values[group] = copy(value)
	listOf(group):Fire(copy(value))
end

function SettingsStore.Observe(group: Group, callback: (value: any) -> ()): () -> ()
	assert(values[group] ~= nil, `SettingsStore.Observe: unknown group "{group}"`)
	local disconnect = listOf(group):Connect(callback)
	callback(copy(values[group]))
	return disconnect
end

-- Spec-only: every group back to its default, every observer dropped.
function SettingsStore.ResetForTesting(): ()
	values = defaults()
	for _, list in observers do
		list:Clear()
	end
end

return SettingsStore
