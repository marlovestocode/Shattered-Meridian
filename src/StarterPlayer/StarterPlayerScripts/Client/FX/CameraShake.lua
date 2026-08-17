--!strict
--[[
	CameraShake.lua

	Owns: a short, decaying rotational shake composed onto the local camera on every server-validated
	combat impact (hit landed, parry, posture break, finisher slam) -- the "impact emphasis" cue
	docs/ui-ux-philosophy.md's Hit Feedback section asks for and animation-systems.md's "every combat
	state with a visible moment needs a VFX cue" mandate, which the game had no camera-level answer to
	before this module (only SwingEffect's FOV punch and StunEffect's colour dip). Presets live in
	Constants.FX.CameraShake; CombatClient.lua's Combat_FeedbackEvent handler is the only caller, so a
	shake only ever fires on a resolution the server already confirmed -- never optimistically.

	Implementation: a single active shake (newest wins -- upstream HitStop.MinIntervalSeconds already
	throttles the rapid multi-target case) whose amplitude eases to zero over its duration, sampled
	through math.noise per axis so the motion is smooth wander rather than random jitter. Applied by
	POST-MULTIPLYING a small CFrame.Angles onto Workspace.CurrentCamera each frame at
	RenderPriority.Camera + 2 -- deliberately AFTER the default camera scripts (Camera) AND
	ShiftLockCamera's Camera + 1 character-yaw write, so the shake layers on the frame's FINAL camera
	pose instead of being overwritten by, or fighting, either. The default camera rewrites the base
	CFrame fresh every frame, which is exactly what lets a decaying offset here read as a shake that
	settles rather than a permanent nudge. Never touches Humanoid.CameraOffset -- that property is
	ShiftLockCamera's alone (see its header); this only ever composes onto the camera CFrame.

	Does not own: deciding WHEN to shake or how hard (CombatClient picks the preset per resolution),
	the FOV punch (SwingEffect) or colour dip (StunEffect), or any camera framing/lock behavior
	(ShiftLockCamera). Purely additive, purely local -- nothing here crosses the network.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("CameraShake")

local RENDER_STEP_NAME = "CombatCameraShake"

local NOISE_SEEDS = Constants.FX.CameraShake.NoiseSeeds

export type ShakePreset = {
	Amplitude: number,
	Frequency: number,
	DurationSeconds: number,
}

local CameraShake = {}

-- The one active shake, or nil. Newest Shake() replaces it wholesale -- see the header for why a
-- single slot is enough given upstream throttling.
local active: { Amplitude: number, Frequency: number, Duration: number, StartClock: number, Seed: number }? = nil

local started = false

-- Starts (or restarts) a shake from a Constants.FX.CameraShake preset. Cheap and allocation-light;
-- safe to call every confirmed impact. A nil/malformed preset is a no-op (a missing shake degrades
-- to no shake, never an error) -- consistent with Constants.FX's "presentation, not outcome" note.
function CameraShake.Shake(preset: ShakePreset?): ()
	if not preset or typeof(preset.Amplitude) ~= "number" then
		return
	end
	active = {
		Amplitude = preset.Amplitude,
		Frequency = preset.Frequency,
		Duration = preset.DurationSeconds,
		StartClock = os.clock(),
		-- A fresh random phase per shake so two shakes of the same preset don't sample identical
		-- noise and read as a repeat.
		Seed = math.random() * 1000,
	}
end

local function onRenderStep(): ()
	local shake = active
	if not shake then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		active = nil
		return
	end

	local elapsed = os.clock() - shake.StartClock
	if elapsed >= shake.Duration then
		active = nil
		return
	end

	-- Quadratic ease-out (decay^2): the shake hits hardest at the moment of impact and settles
	-- smoothly, the same trauma-squared curve that reads as a real impact rather than a linear ramp.
	local decay = 1 - (elapsed / shake.Duration)
	local amplitude = shake.Amplitude * decay * decay
	local t = elapsed * shake.Frequency

	local pitch = amplitude * math.noise(t, shake.Seed + NOISE_SEEDS.Pitch)
	local yaw = amplitude * math.noise(t, shake.Seed + NOISE_SEEDS.Yaw)
	local roll = amplitude * math.noise(t, shake.Seed + NOISE_SEEDS.Roll)

	camera.CFrame = camera.CFrame * CFrame.Angles(pitch, yaw, roll)
end

-- Binds the render-step compositor. Called once from Main.client.lua's boot sequence, after
-- ShiftLockCamera.Start so the ordering note in the header holds (both bind at their own priority
-- regardless of call order, but keeping the boot order aligned with the priority order avoids
-- surprise). Idempotent.
function CameraShake.Start(): ()
	if started then
		return
	end
	started = true
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 2, onRenderStep)
	logger:info("CameraShake started")
end

return CameraShake
