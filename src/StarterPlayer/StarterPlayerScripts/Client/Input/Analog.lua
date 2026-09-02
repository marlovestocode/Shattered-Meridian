--!strict
--[[
	Analog.lua

	Owns: reading a gamepad's two thumbsticks and two analog triggers as processed values --
	Move()/Look() return a Vector2 already past a radial deadzone and a response curve, Trigger()
	returns a 0..1 float. Nothing else in this codebase reads GetGamepadState/thumbstick Position
	directly; a future consumer (camera look, vehicle steering, a charge-attack trigger) calls these
	instead of re-deriving deadzone/curve math of its own.

	POLLING, NOT EVENT-DRIVEN, deliberately -- the same shape KeybindManager.IsJumpKeyDown already
	uses for a raw device read. UserInputService:GetGamepadState(gamepadType) hands back the CURRENT
	InputObject for every input on that pad, including both thumbsticks and both triggers, so there is
	nothing an InputChanged connection would buy here that a call-on-demand read does not -- and no
	connection to leak if a caller never gets around to disconnecting it.

	RADIAL DEADZONE, NOT PER-AXIS. A per-axis deadzone (dropping X and Y independently below some
	threshold) makes diagonals unreachable near the deadzone edge -- a stick pushed to (0.15, 0.15) can
	clear a RADIAL deadzone of 0.2 (magnitude ~0.212) while failing a per-axis one of 0.2 on both axes
	at once. This module tests the STICK'S MAGNITUDE once, the same shape
	Shared/FlightMath.lua reasons about "the overshoot is the information" for a spring -- here the
	information is "how far off centre," not "how far on each axis."

	FOUR KNOBS, NOW FED BY REAL SETTINGS. Deadzone/curve exponent/sensitivity/per-axis invert are what
	Types.GamepadSettings carries, and Client/Settings/SettingsClient.lua pushes the player's own
	values in through SetSettings below. ApplyStick still takes an explicit AnalogConfig so the pure
	math stays drivable from a spec with no settings state at all.

	MOVE AND LOOK DERIVE DIFFERENT CONFIGS FROM THE SAME SETTINGS TABLE, which is the whole reason
	SetSettings takes Types.GamepadSettings rather than an AnalogConfig:
	  * Move uses MoveDeadzone, and takes NO sensitivity and NO invert. Its output feeds
	    Humanoid.MoveDirection, where the magnitude IS the walk-versus-run request -- scaling it would
	    silently retune movement speed, and inverting it would mean pushing forward walks backward.
	  * Look uses LookDeadzone, LookSensitivity and InvertLookY. All three are aim-feel preferences
	    that mean nothing to the left stick.
	Handing both sticks one shared AnalogConfig is the bug this split exists to make unrepresentable;
	a single Deadzone/Sensitivity pair applied to both is how a sensitivity slider ends up changing how
	fast the character walks.

	THE SHIPPED DEFAULTS LIVE IN Constants.Settings.Gamepad.Defaults, not here. The server validates
	writes against the same table and cannot require this module, so restating the numbers locally
	would be two sources of truth that agree only by coincidence.

	Does NOT own: which gamepad is "the" gamepad (the first entry off
	UserInputService:GetConnectedGamepads() -- this codebase has never supported split-screen/local
	multiplayer, so "the first connected pad" is the only meaningful answer), or a response curve
	that is anything other than a single exponent -- a per-axis or piecewise curve is a real
	possibility for a future weapon-aim-assist feature, and is out of scope for this pass.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

export type AnalogConfig = {
	Deadzone: number,
	CurveExponent: number,
	Sensitivity: number,
	InvertX: boolean,
	InvertY: boolean,
}

local Analog = {}

-- The response curve's exponent is NOT a Types.GamepadSettings field and deliberately not player-
-- facing: it is a feel decision the game makes, the way ParkourConstants owns its own curves, and a
-- slider for it would ask players to tune something they have no vocabulary for. Deadzone/sensitivity
-- /invert are the three that genuinely differ per person and per controller.
local CURVE_EXPONENT = 2

local DEFAULT_CONFIG: AnalogConfig = {
	Deadzone = Constants.Settings.Gamepad.Defaults.MoveDeadzone,
	CurveExponent = CURVE_EXPONENT,
	Sensitivity = 1,
	InvertX = false,
	InvertY = false,
}

-- The player's own preferences, or the shipped defaults until SettingsClient pushes theirs in. Held
-- as the SETTINGS table rather than as two pre-derived AnalogConfigs so that a later field (a second
-- curve, a per-stick sensitivity) is one more read below rather than a change to what is stored.
local currentSettings: Types.GamepadSettings = {
	LookSensitivity = Constants.Settings.Gamepad.Defaults.LookSensitivity,
	MoveDeadzone = Constants.Settings.Gamepad.Defaults.MoveDeadzone,
	LookDeadzone = Constants.Settings.Gamepad.Defaults.LookDeadzone,
	InvertLookY = Constants.Settings.Gamepad.Defaults.InvertLookY,
	Vibration = Constants.Settings.Gamepad.Defaults.Vibration,
}

-- Called by Client/Settings/SettingsClient.lua once at boot with the player's persisted block, and
-- again on every Controller-tab change. Stores a COPY: the caller's table is its own live state and
-- must not become shared mutable state here.
function Analog.SetSettings(settings: Types.GamepadSettings): ()
	currentSettings = {
		LookSensitivity = settings.LookSensitivity,
		MoveDeadzone = settings.MoveDeadzone,
		LookDeadzone = settings.LookDeadzone,
		InvertLookY = settings.InvertLookY,
		Vibration = settings.Vibration,
	}
end

-- What Analog is currently reading sticks through. Returned as a copy for the same reason
-- Chord.Chords is -- a caller listing these must not be able to edit them.
function Analog.Settings(): Types.GamepadSettings
	return table.clone(currentSettings)
end

-- See the header: the two sticks get different halves of the same settings table.
local function moveConfig(): AnalogConfig
	return {
		Deadzone = currentSettings.MoveDeadzone,
		CurveExponent = CURVE_EXPONENT,
		Sensitivity = 1,
		InvertX = false,
		InvertY = false,
	}
end

local function lookConfig(): AnalogConfig
	return {
		Deadzone = currentSettings.LookDeadzone,
		CurveExponent = CURVE_EXPONENT,
		Sensitivity = currentSettings.LookSensitivity,
		InvertX = false,
		InvertY = currentSettings.InvertLookY,
	}
end

-- t must already be in 0..1 (post-deadzone-rescale). exponent > 0 guarantees Curve(0) == 0 and
-- Curve(1) == 1 exactly, and monotonic in between -- asserted in the spec rather than merely assumed.
function Analog.Curve(t: number, exponent: number?): number
	return t ^ (exponent or DEFAULT_CONFIG.CurveExponent)
end

-- The pure pipeline every stick read below funnels through: invert, radial deadzone (rescaled so the
-- deadzone edge maps to 0 rather than leaving a dead jump at the edge), response curve, sensitivity.
-- Exposed (rather than kept local) so a spec can drive it with a plain Vector2 -- unlike InputObject,
-- Vector2 has a public constructor, so this needs no InputObject-shaped test seam at all.
function Analog.ApplyStick(raw: Vector2, config: AnalogConfig?): Vector2
	local resolved = config or DEFAULT_CONFIG
	local adjusted = Vector2.new(if resolved.InvertX then -raw.X else raw.X, if resolved.InvertY then -raw.Y else raw.Y)

	local magnitude = adjusted.Magnitude
	if magnitude <= resolved.Deadzone or resolved.Deadzone >= 1 then
		return Vector2.zero
	end

	local normalized = math.min((magnitude - resolved.Deadzone) / (1 - resolved.Deadzone), 1)
	local curved = Analog.Curve(normalized, resolved.CurveExponent) * resolved.Sensitivity
	return adjusted.Unit * curved
end

-- The InputObject for `keyCode` on the first connected gamepad, or nil if none is connected or the
-- pad is not currently reporting that input at all.
local function firstGamepadInput(keyCode: Enum.KeyCode): InputObject?
	for _, gamepadType in UserInputService:GetConnectedGamepads() do
		for _, inputObject in UserInputService:GetGamepadState(gamepadType) do
			if inputObject.KeyCode == keyCode then
				return inputObject
			end
		end
	end
	return nil
end

-- Left stick, processed. Vector2.zero with no gamepad connected -- the same "no input" answer a
-- centred, undeadzoned stick would give, so a caller never has to special-case "no gamepad" itself.
function Analog.Move(config: AnalogConfig?): Vector2
	local stick = firstGamepadInput(Enum.KeyCode.Thumbstick1)
	if not stick then
		return Vector2.zero
	end
	return Analog.ApplyStick(Vector2.new(stick.Position.X, stick.Position.Y), config or moveConfig())
end

-- Right stick, processed. Same shape as Move above.
function Analog.Look(config: AnalogConfig?): Vector2
	local stick = firstGamepadInput(Enum.KeyCode.Thumbstick2)
	if not stick then
		return Vector2.zero
	end
	return Analog.ApplyStick(Vector2.new(stick.Position.X, stick.Position.Y), config or lookConfig())
end

-- ButtonL2/ButtonR2 analog position, 0..1. Roblox reports a trigger's pull through the InputObject's
-- Position.Z component (X/Y stay 0 for a trigger, unlike a thumbstick) -- clamped defensively since
-- nothing guarantees a future engine build keeps reporting exactly [0, 1].
function Analog.Trigger(which: "Left" | "Right"): number
	local keyCode = if which == "Left" then Enum.KeyCode.ButtonL2 else Enum.KeyCode.ButtonR2
	local trigger = firstGamepadInput(keyCode)
	if not trigger then
		return 0
	end
	return math.clamp(trigger.Position.Z, 0, 1)
end

-- Whether a DIGITAL gamepad button is physically held right now, on any connected pad.
--
-- Deliberately NOT built on firstGamepadInput above, and deliberately not on
-- UserInputService:IsKeyDown. IsKeyDown resolves a KEYBOARD key and nothing else -- handed a gamepad
-- KeyCode it does not error, it simply returns false forever, which is the worst possible failure
-- shape: every call site reads as "the button is not held" and no log, lint or type check ever
-- objects. KeybindManager.IsJumpKeyDown was written that way and meant that jump, polled rather than
-- routed, was invisible to the parkour framework on a controller -- see that function's own note.
--
-- IsGamepadButtonDown is the purpose-built read for a digital button and needs none of
-- firstGamepadInput's InputObject plumbing (there is no Position to deadzone or curve here, only a
-- boolean), so this walks the connected pads directly. Safe with nothing connected: the loop simply
-- does not run and the answer is false, the same "no input" contract Move/Look/Trigger already keep.
function Analog.IsButtonDown(keyCode: Enum.KeyCode): boolean
	for _, gamepadType in UserInputService:GetConnectedGamepads() do
		if UserInputService:IsGamepadButtonDown(gamepadType, keyCode) then
			return true
		end
	end
	return false
end

return Analog
