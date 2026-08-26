--!strict
--[[
	InputDevice.lua

	Owns: which physical device the local player is CURRENTLY using -- keyboard/mouse, gamepad, or
	touch -- as one value every input-aware UI surface can read instead of independently polling
	UserInputService.TouchEnabled/GamepadEnabled the way UI/Tokens.lua:22 and
	UI/Components/Stepper.lua:65 do today. This module does not migrate those two call sites (Phase 6
	scope) -- it exists first so Phase 6 has a single source to point them at.

	Does NOT own bindings (Client/Input/KeybindManager.lua's job) or what a device is currently DOING
	-- pressing a bound action, holding a menu open -- which is Client/Input/InputRouter.lua's job.
	This module answers exactly one question: keyboard/mouse, gamepad, or touch.

	THE HYSTERESIS, AND WHY LastInputTypeChanged ALONE CANNOT CARRY IT. A stray mouse jiggle while a
	gamepad is in a player's hands, or a gamepad's own resting thumbstick drift, must not flap the
	reading back and forth every frame -- so a MOVEMENT-class sample (mouse movement, a thumbstick
	nudge) only counts once its magnitude clears a threshold, where a BUTTON-class sample (a key, a
	mouse click, a gamepad face button, a touch) counts immediately. UserInputService.LastInputType-
	Changed is the right PRIMARY signal for the button-class families -- it fires once per meaningful
	change and needs nothing else -- but it hands back only the Enum.UserInputType, never the
	InputObject, so it cannot supply a magnitude at all. Worse, Roblox reports a thumbstick nudge and
	a gamepad face-button press through the exact same UserInputType (Gamepad1..Gamepad8) -- there is
	no separate "thumbstick" input type -- so LastInputTypeChanged cannot even tell the two apart on
	its own. MouseMovement and every Gamepad type are therefore deliberately excluded from the
	LastInputTypeChanged handler below and resolved instead off UserInputService.InputBegan (gamepad
	buttons -- a discrete press, always immediate) and UserInputService.InputChanged (mouse movement's
	Delta, and a thumbstick's own Position, which is where the actual magnitude lives). This is a
	judged deviation from using LastInputTypeChanged for literally everything, made because the event
	cannot supply what the hysteresis rule needs for exactly these two families.

	ResolveDevice BELOW IS THE ONE DECISION EVERY LIVE CONNECTION FUNNELS THROUGH, and it is exposed
	rather than kept local because InputObject has no public constructor -- a spec cannot synthesize a
	real button press or stick nudge to drive UserInputService directly. Every connection below
	reduces its own InputObject to the same three primitives (UserInputType, KeyCode, a pre-computed
	magnitude) before calling it, so the live path and the spec path cannot drift -- the same "assert
	through the function the real input goes through" reasoning Shell/Chrome.lua's HandleEscape
	documents for itself.

	Observe BELOW GUARDS FOR A NIL Players.LocalPlayer, modeled exactly on Shell/Chrome.lua's
	ObserveModalGate, even though nothing in this module actually reads Player state -- because
	scripts/run-tests.lua require-loads every client module on the server, where LocalPlayer is nil,
	and every Fusion adapter under Client/Input follows the same guarded shape so a future one that
	DOES need Player state does not have to introduce the pattern for the first time under pressure.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

type Scope = Fusion.Scope<typeof(Fusion)>

export type Device = "KeyboardMouse" | "Gamepad" | "Touch"

local InputDevice = {}

-- Button-class UserInputTypes that resolve to a device on their own identity alone -- see file
-- header. MouseMovement and every Gamepad type are deliberately absent: both need more than their
-- own UserInputType to resolve (see ResolveDevice below).
local BUTTON_DEVICE_BY_TYPE: { [Enum.UserInputType]: Device } = {
	[Enum.UserInputType.Keyboard] = "KeyboardMouse",
	[Enum.UserInputType.MouseButton1] = "KeyboardMouse",
	[Enum.UserInputType.MouseButton2] = "KeyboardMouse",
	[Enum.UserInputType.MouseButton3] = "KeyboardMouse",
	[Enum.UserInputType.MouseWheel] = "KeyboardMouse",
	[Enum.UserInputType.Touch] = "Touch",
}

local GAMEPAD_TYPES: { [Enum.UserInputType]: boolean } = {
	[Enum.UserInputType.Gamepad1] = true,
	[Enum.UserInputType.Gamepad2] = true,
	[Enum.UserInputType.Gamepad3] = true,
	[Enum.UserInputType.Gamepad4] = true,
	[Enum.UserInputType.Gamepad5] = true,
	[Enum.UserInputType.Gamepad6] = true,
	[Enum.UserInputType.Gamepad7] = true,
	[Enum.UserInputType.Gamepad8] = true,
}

local THUMBSTICK_KEYCODES: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Thumbstick1] = true,
	[Enum.KeyCode.Thumbstick2] = true,
}

-- Movement-class hysteresis thresholds. Hardcoded module constants for now -- there is no
-- GamepadSettings/comfort equivalent yet for input-device sensitivity, the same carve-out
-- Analog.lua's own header takes for its four knobs; Phase 4 is where either would get wired to a
-- real settings value. THUMBSTICK_MOVEMENT_THRESHOLD matches Analog.lua's own default deadzone
-- deliberately: a nudge too small to register as stick input should also be too small to claim the
-- device reading.
local MOUSE_MOVEMENT_THRESHOLD = 2
local THUMBSTICK_MOVEMENT_THRESHOLD = 0.2

-- The decision every live connection below funnels through -- see file header for why it is public.
-- `magnitude` is the ALREADY-COMPUTED movement magnitude (InputChanged's own Delta.Magnitude for
-- MouseMovement, Position.Magnitude for a thumbstick); it is ignored for every button-class type.
-- Returns nil when the sample does not resolve to a device switch at all -- either because it is a
-- movement-class sample that has not cleared its threshold, or because `userInputType` is not one
-- this module has an opinion about (Enum.UserInputType.Focus, TextInput, etc.).
function InputDevice.ResolveDevice(
	userInputType: Enum.UserInputType,
	keyCode: Enum.KeyCode?,
	magnitude: number?
): Device?
	local immediate = BUTTON_DEVICE_BY_TYPE[userInputType]
	if immediate then
		return immediate
	end

	if userInputType == Enum.UserInputType.MouseMovement then
		if (magnitude or 0) >= MOUSE_MOVEMENT_THRESHOLD then
			return "KeyboardMouse"
		end
		return nil
	end

	if GAMEPAD_TYPES[userInputType] then
		if keyCode and THUMBSTICK_KEYCODES[keyCode] then
			if (magnitude or 0) >= THUMBSTICK_MOVEMENT_THRESHOLD then
				return "Gamepad"
			end
			return nil
		end
		-- Any other Gamepad KeyCode -- face buttons, triggers, D-pad -- is button-class: Roblox has
		-- already applied its own press threshold before InputBegan fires at all, so this counts
		-- immediately with no threshold of this module's own.
		return "Gamepad"
	end

	return nil
end

-- No UserInputService property mirrors LastInputTypeChanged (there is nothing to poll for "the
-- current device" at cold start), so the very first reading is a best-effort guess off the
-- platform's own capability flags rather than an actual observed input -- corrected the moment any
-- real input arrives.
local function initialDevice(): Device
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled then
		return "Touch"
	end
	if
		UserInputService.GamepadEnabled
		and not UserInputService.KeyboardEnabled
		and not UserInputService.MouseEnabled
	then
		return "Gamepad"
	end
	return "KeyboardMouse"
end

local currentDevice: Device = initialDevice()
local changedListeners: { () -> () } = {}

local function notifyChanged(): ()
	for _, listener in ipairs(changedListeners) do
		listener()
	end
end

local function setDevice(next: Device): ()
	if next == currentDevice then
		return
	end
	currentDevice = next
	notifyChanged()
end

UserInputService.LastInputTypeChanged:Connect(function(lastInputType: Enum.UserInputType)
	-- MouseMovement and every Gamepad type are excluded here -- see file header. InputBegan/
	-- InputChanged below are the primary signal for exactly those two families.
	if lastInputType == Enum.UserInputType.MouseMovement or GAMEPAD_TYPES[lastInputType] then
		return
	end
	local device = InputDevice.ResolveDevice(lastInputType, nil, nil)
	if device then
		setDevice(device)
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if not GAMEPAD_TYPES[input.UserInputType] then
		return
	end
	local device = InputDevice.ResolveDevice(input.UserInputType, input.KeyCode, nil)
	if device then
		setDevice(device)
	end
end)

UserInputService.InputChanged:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local device = InputDevice.ResolveDevice(input.UserInputType, nil, input.Delta.Magnitude)
		if device then
			setDevice(device)
		end
		return
	end
	if GAMEPAD_TYPES[input.UserInputType] and input.KeyCode and THUMBSTICK_KEYCODES[input.KeyCode] then
		local device = InputDevice.ResolveDevice(input.UserInputType, input.KeyCode, input.Position.Magnitude)
		if device then
			setDevice(device)
		end
	end
end)

-- The current device, synchronously. For a non-Fusion caller (a plain script, a one-shot check) --
-- Observe below is the Fusion-reactive equivalent.
function InputDevice.Current(): Device
	return currentDevice
end

-- Registers `listener` to run after the device changes. Fires with no arguments, same shape and same
-- reasoning as KeybindManager.OnChanged: every consumer re-reads Current() rather than being handed
-- the new value directly. Returns an unsubscribe function.
function InputDevice.OnChanged(listener: () -> ()): () -> ()
	table.insert(changedListeners, listener)
	return function()
		local index = table.find(changedListeners, listener)
		if index then
			table.remove(changedListeners, index)
		end
	end
end

-- TEST-ONLY: forces Current() to `device` and fires OnChanged exactly as a real switch would,
-- without going through any live UserInputService signal. No production caller uses this -- it
-- exists because InputObject has no public constructor, so nothing outside this module can
-- synthesize the button press or stick nudge that would drive a real switch (see file header), and a
-- consumer like Glyph.lua needs a way to prove it actually recomputes when the device changes.
function InputDevice.SetCurrentForTesting(device: Device): ()
	setDevice(device)
end

-- The Fusion adapter over Current()/OnChanged -- see file header for why it guards a nil LocalPlayer
-- even though nothing here reads Player state. Read once at construction (the Value starts at
-- Current(), not a hardcoded default), then kept live for as long as `scope` lives.
function InputDevice.Observe(scope: Scope): Fusion.Value<Device>
	local current: Fusion.Value<Device> = scope:Value(InputDevice.Current())

	if Players.LocalPlayer == nil then
		return current
	end

	table.insert(
		scope,
		InputDevice.OnChanged(function()
			current:set(InputDevice.Current())
		end)
	)

	return current
end

return InputDevice
