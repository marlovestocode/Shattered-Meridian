--!strict
-- SettingsSystem's remote decoders, old against new. The OLD functions below are a frozen copy of the hand-written
-- validators this module used before Schema (2026-10-25, W4): a spec of the answer, not of the code. Both are run over
-- one corpus and must agree on every entry -- valid values, each wrong type, nil, NaN, +-inf, out-of-range numbers and
-- oversize strings. The conversion commit deletes the old code from src; this copy is what keeps it honest.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local SettingsSystem = require(ServerScriptService.Server.Systems.SettingsSystem)

local NAN = 0 / 0
local INF = math.huge

-- Frozen copies --------------------------------------------------------------------------------------------

local OLD_PARKOUR: { [string]: string } = {
	Enabled = "boolean",
	CameraEffects = "boolean",
	CoyoteTime = "boolean",
	JumpBuffer = "boolean",
	AutoVault = "boolean",
	LedgeAssist = "boolean",
	StepAssist = "boolean",
	SprintMode = "SprintMode",
}
local OLD_COMFORT: { [string]: true } = { CameraShake = true, FieldOfViewEffects = true, VehicleCameraMotion = true }
local OLD_GAMEPAD: { [string]: string } = {
	LookSensitivity = "LookSensitivity",
	MoveDeadzone = "Deadzone",
	LookDeadzone = "Deadzone",
	InvertLookY = "boolean",
	Vibration = "boolean",
}
local OLD_UI: { [string]: true } = { Scale = true }

-- (field, value) or nil -- what each old handler persisted, ignoring logging and the Transform.
local function oldGroup(group: string, rawField: unknown, rawValue: unknown): (string?, any?)
	if typeof(rawField) ~= "string" then
		return nil
	end
	local field = rawField :: string
	if group == "Parkour" then
		local expectedType = OLD_PARKOUR[field]
		if not expectedType then
			return nil
		end
		if expectedType == "boolean" then
			if typeof(rawValue) ~= "boolean" then
				return nil
			end
			return field, rawValue
		end
		if rawValue ~= "Hold" and rawValue ~= "Toggle" then
			return nil
		end
		return field, rawValue
	elseif group == "Comfort" then
		if not OLD_COMFORT[field] then
			return nil
		end
		if typeof(rawValue) ~= "boolean" then
			return nil
		end
		return field, rawValue
	elseif group == "Gamepad" then
		local expected = OLD_GAMEPAD[field]
		if not expected then
			return nil
		end
		if expected == "boolean" then
			if typeof(rawValue) ~= "boolean" then
				return nil
			end
			return field, rawValue
		end
		if typeof(rawValue) ~= "number" or rawValue ~= rawValue then
			return nil
		end
		local bounds = (Constants.Settings.Gamepad.Bounds :: { [string]: any })[expected]
		return field, math.clamp(rawValue :: number, bounds.Min, bounds.Max)
	else
		if not OLD_UI[field] then
			return nil
		end
		if typeof(rawValue) ~= "number" or rawValue ~= rawValue then
			return nil
		end
		local bounds = (Constants.Settings.UI.Bounds :: { [string]: any })[field]
		return field, math.clamp(rawValue :: number, bounds.Min, bounds.Max)
	end
end

local function oldIsRebindableAction(action: string): boolean
	return (Constants.Keybinds.Defaults :: { [string]: any })[action] ~= nil and not string.match(action, "^HotbarSlot")
end

local function oldValidateKeybind(raw: unknown): { [string]: any }?
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
		return { KeyCode = keyCode }
	end
	if hasUserInputType and not hasKeyCode then
		return { UserInputType = userInputType }
	end
	return nil
end

local function oldKeybindUpdate(rawDevice: unknown, rawAction: unknown, rawKeybind: unknown): (any, any, any)
	if not (rawDevice == "Keyboard" or rawDevice == "Gamepad") then
		return nil
	end
	if typeof(rawAction) ~= "string" or not oldIsRebindableAction(rawAction :: string) then
		return nil
	end
	local keybind = oldValidateKeybind(rawKeybind)
	if not keybind then
		return nil
	end
	return rawDevice, rawAction, keybind
end

-- Corpus ---------------------------------------------------------------------------------------------------

-- Every value a client could put in a value slot.
local VALUES: { any } = {
	true,
	false,
	0,
	1,
	-1,
	0.5,
	10,
	100,
	-100,
	1e308,
	-1e308,
	NAN,
	INF,
	-INF,
	"",
	"Hold",
	"Toggle",
	"hold",
	string.rep("x", 5000),
	{},
	{ true },
	Vector3.zero,
	Enum.KeyCode.E,
}

-- Every value a client could put in a field-name slot, plus each real field name.
local function fieldNames(realFields: { string }): { any }
	local names: { any } = { 5, true, {}, "", "Nope", "__index", "enabled", string.rep("y", 5000), NAN, Enum.KeyCode.E }
	for _, field in realFields do
		table.insert(names, field)
	end
	return names
end

local function sameNumber(a: any, b: any): boolean
	if typeof(a) == "number" and typeof(b) == "number" then
		return a == b or (a ~= a and b ~= b)
	end
	return a == b
end

local GROUP_FIELDS: { [string]: { string } } = {
	Parkour = {
		"Enabled",
		"CameraEffects",
		"CoyoteTime",
		"JumpBuffer",
		"AutoVault",
		"LedgeAssist",
		"StepAssist",
		"SprintMode",
	},
	Comfort = { "CameraShake", "FieldOfViewEffects", "VehicleCameraMotion" },
	Gamepad = { "LookSensitivity", "MoveDeadzone", "LookDeadzone", "InvertLookY", "Vibration" },
	UI = { "Scale" },
}

return function()
	for _, group in { "Parkour", "Comfort", "Gamepad", "UI" } do
		describe(`SettingsSystem.DecodeGroupWrite -- {group}, old against new`, function()
			it("agrees on every (field, value) in the corpus", function()
				local checked = 0
				for _, field in fieldNames(GROUP_FIELDS[group]) do
					for _, value in VALUES do
						local oldField, oldValue = oldGroup(group, field, value)
						local newField, newValue, reason = SettingsSystem.DecodeGroupWrite(group, field, value)
						expect(newField).to.equal(oldField)
						expect(sameNumber(newValue, oldValue)).to.equal(true)
						-- A refusal always says why; an acceptance never does.
						expect(reason == nil).to.equal(oldField ~= nil)
						checked += 1
					end
				end
				expect(checked > 100).to.equal(true)
			end)

			it("agrees when the value is nil", function()
				for _, field in GROUP_FIELDS[group] do
					local oldField = oldGroup(group, field, nil)
					local newField = SettingsSystem.DecodeGroupWrite(group, field, nil)
					expect(newField).to.equal(oldField)
				end
			end)
		end)
	end

	describe("SettingsSystem.DecodeGroupWrite -- the numbers themselves", function()
		it("clamps a gamepad sensitivity to its bounds and refuses NaN", function()
			local bounds = Constants.Settings.Gamepad.Bounds.LookSensitivity
			local _, high = SettingsSystem.DecodeGroupWrite("Gamepad", "LookSensitivity", 1e9)
			local _, low = SettingsSystem.DecodeGroupWrite("Gamepad", "LookSensitivity", -1e9)
			expect(high).to.equal(bounds.Max)
			expect(low).to.equal(bounds.Min)
			expect(SettingsSystem.DecodeGroupWrite("Gamepad", "LookSensitivity", NAN)).to.equal(nil)
		end)
	end)

	describe("SettingsSystem.DecodeKeybindUpdate, old against new", function()
		local DEVICES: { any } = { "Keyboard", "Gamepad", "keyboard", "", 1, true, {}, NAN }
		local ACTIONS: { any } = {
			"Parry",
			"HotbarSlot1",
			"HotbarSlot",
			"NotAnAction",
			"",
			7,
			{},
			string.rep("a", 5000),
		}
		-- Any real action, so the corpus exercises a rebindable one whatever this build defines.
		for action in pairs(Constants.Keybinds.Defaults :: { [string]: any }) do
			table.insert(ACTIONS, action)
		end
		local KEYBINDS: { any } = {
			{ KeyCode = Enum.KeyCode.E },
			{ UserInputType = Enum.UserInputType.MouseButton1 },
			{ KeyCode = Enum.KeyCode.E, UserInputType = Enum.UserInputType.MouseButton1 },
			{ KeyCode = Enum.UserInputType.MouseButton1 },
			{ UserInputType = Enum.KeyCode.E },
			{ KeyCode = Enum.UserInputType.MouseButton1, UserInputType = Enum.UserInputType.MouseButton2 },
			{ KeyCode = "E" },
			{ KeyCode = NAN },
			{},
			"E",
			5,
			true,
			NAN,
		}

		it("agrees on every (device, action, keybind) in the corpus", function()
			local accepted = 0
			for _, device in DEVICES do
				for _, action in ACTIONS do
					for _, keybind in KEYBINDS do
						local oldDevice, oldAction, oldKeybind = oldKeybindUpdate(device, action, keybind)
						local newDevice, newAction, newKeybind =
							SettingsSystem.DecodeKeybindUpdate(device, action, keybind)
						expect(newDevice).to.equal(oldDevice)
						expect(newAction).to.equal(oldAction)
						if oldKeybind == nil then
							expect(newKeybind).to.equal(nil)
						else
							expect((newKeybind :: any).KeyCode).to.equal(oldKeybind.KeyCode)
							expect((newKeybind :: any).UserInputType).to.equal(oldKeybind.UserInputType)
							accepted += 1
						end
					end
				end
			end
			-- The corpus must actually reach the accepting branch, or the agreement above proves nothing.
			expect(accepted > 0).to.equal(true)
		end)

		it("agrees on the nil arguments", function()
			expect(select(1, SettingsSystem.DecodeKeybindUpdate(nil, "Parry", { KeyCode = Enum.KeyCode.E }))).to.equal(
				nil
			)
			expect(select(1, SettingsSystem.DecodeKeybindUpdate("Keyboard", nil, { KeyCode = Enum.KeyCode.E }))).to.equal(
				nil
			)
			expect(select(1, SettingsSystem.DecodeKeybindUpdate("Keyboard", "Parry", nil))).to.equal(nil)
		end)
	end)

	describe("SettingsSystem.DecodeDevice, old against new", function()
		it("accepts exactly the two device names", function()
			for _, raw in { "Keyboard", "Gamepad", "keyboard", "", 1, true, {}, NAN, string.rep("k", 5000) } do
				local expected = if raw == "Keyboard" or raw == "Gamepad" then raw else nil
				expect(SettingsSystem.DecodeDevice(raw)).to.equal(expected)
			end
			expect(SettingsSystem.DecodeDevice(nil)).to.equal(nil)
		end)
	end)
end
