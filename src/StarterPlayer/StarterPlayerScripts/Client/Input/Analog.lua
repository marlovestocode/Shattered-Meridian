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

	FOUR KNOBS, NO SETTINGS TYPE YET. Deadzone/curve exponent/sensitivity/per-axis invert are exactly
	what a future Types.GamepadSettings would carry (Phase 4), so ApplyStick takes them as an optional
	AnalogConfig table rather than reading module-level constants baked into the math -- a caller with
	real settings passes them through today with no signature change needed later. DEFAULT_CONFIG below
	is what every caller gets until then.

	Does NOT own: which gamepad is "the" gamepad (the first entry off
	UserInputService:GetConnectedGamepads() -- this codebase has never supported split-screen/local
	multiplayer, so "the first connected pad" is the only meaningful answer), or a response curve
	that is anything other than a single exponent -- a per-axis or piecewise curve is a real
	possibility for a future weapon-aim-assist feature, and is out of scope for this pass.
]]

local UserInputService = game:GetService("UserInputService")

export type AnalogConfig = {
	Deadzone: number,
	CurveExponent: number,
	Sensitivity: number,
	InvertX: boolean,
	InvertY: boolean,
}

local Analog = {}

local DEFAULT_CONFIG: AnalogConfig = {
	Deadzone = 0.2,
	CurveExponent = 2,
	Sensitivity = 1,
	InvertX = false,
	InvertY = false,
}

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
	return Analog.ApplyStick(Vector2.new(stick.Position.X, stick.Position.Y), config)
end

-- Right stick, processed. Same shape as Move above.
function Analog.Look(config: AnalogConfig?): Vector2
	local stick = firstGamepadInput(Enum.KeyCode.Thumbstick2)
	if not stick then
		return Vector2.zero
	end
	return Analog.ApplyStick(Vector2.new(stick.Position.X, stick.Position.Y), config)
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

return Analog
