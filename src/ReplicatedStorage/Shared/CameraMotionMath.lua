--!strict
--[[
	CameraMotionMath.lua

	Owns: the arithmetic of the movement-responsive camera -- how a body's measured velocity becomes a lean, a pull-back, a
	speed FOV and a landing compression. The pure half of Client/Camera/CameraMotion.lua, split out the way
	CameraFollowMath and Blimp/BlimpCameraMath are: it can be spec'd with plain vectors and a fixed frame time, no camera,
	no character, no frame clock (Client/Camera is mounted in test.project.json, but the controller needs a live Humanoid).
	The tuning is CameraConstants.Motion.

	THE PHYSICAL INPUT OF EACH CHANNEL (nothing here is a canned animation; every output is a function of the velocity
	the body actually had):
	  * LEAN (roll)    -- acceleration across the screen. The velocity is low-passed, differenced into an acceleration,
	                      low-passed again, and projected on the camera's right axis; a spring turns it into a roll. A
	                      steady run has no lateral acceleration and so no lean; a strafe start, a hard turn or a
	                      reversal does, in proportion, clamped to Lean.MaxDegrees.
	  * PULL           -- planar speed. The camera sits further back the faster the body goes.
	  * FOV            -- planar speed above sprint, plus downward speed above a free-fall floor.
	  * LANDING        -- the vertical speed the body LOST in one frame. Read off the raw velocity, so it needs no state
	                      from any movement framework: a parkour landing, a plain jump, a knockback that ends on the
	                      ground and a vault that drops off a ledge all report the same way.

	WHAT IS NOT HERE, ON PURPOSE. The acceleration-aware LAG of the view behind the body is Shared/CameraFollowMath (a
	spring on the camera's focus); this does not repeat it. Pitch and yaw are the player's. Shake is CameraShake's.

	FRAME-RATE INDEPENDENT. Filters use FlightMath.EaseAlpha (1 - e^(-rate*dt)); springs run through FlightMath.SpringAdvance
	(SpringStep in fixed-size sub-steps), so the same body at 30, 60, 144 and 240 fps gets the same curve to within a few percent
	(Tests/Shared/CameraMotionMath.spec.lua proves it on the landing peak and the lean). Long frames are capped
	(Sampling.MaxStepSeconds): a hitch settles the springs, it does not integrate across the stall.

	SUSPENDED means a system other than the player's own legs is moving this body (the BodyRestraint "CameraMotion" row:
	a vessel, flight, a root lock, a grab, a freeze). Every target goes to zero, the springs ease out, the velocity
	filter RE-SEEDS every frame (so the first live frame afterwards sees no phantom acceleration out of whatever the
	body was doing), and no landing is reported -- neither while suspended nor on the first frame after.

	Does not own: where the outputs go (CameraMotion writes them through CameraOffsetComposer, FOVOffset and
	CameraRotationComposer), the camera's own state (type, subject, first person), or any tuning value.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

local CameraMotionMath = {}

export type Tuning = {
	-- Per-channel multipliers: the reduce-motion knobs. 0 silences a channel without touching the others.
	Scale: { Lean: number, Pull: number, Fov: number, Landing: number },
	Sampling: {
		-- Exponential low-pass rates (1/s) for the velocity and for the acceleration differenced from it.
		VelocityFilterRate: number,
		AccelFilterRate: number,
		-- A frame longer than this is treated as this long.
		MaxStepSeconds: number,
	},
	Lean: {
		MaxDegrees: number,
		-- Lateral acceleration (studs/s^2) that earns the full lean.
		FullAccel: number,
		-- Fraction of FullAccel below which nothing leans (filter noise, a slope's wobble).
		Deadzone: number,
		-- Planar speed at which the lean is fully permitted; below it the lean fades out.
		MinSpeed: number,
		Frequency: number,
		Damping: number,
	},
	Pull: { StartSpeed: number, FullSpeed: number, MaxStuds: number, EaseRate: number },
	Fov: {
		StartSpeed: number,
		FullSpeed: number,
		MaxDelta: number,
		-- Downward speed band for the free-fall widening.
		FallStartSpeed: number,
		FallFullSpeed: number,
		FallMaxDelta: number,
	},
	Landing: {
		-- Vertical speed absorbed in one frame below which nothing is felt, and the speed that earns the full response.
		MinImpactSpeed: number,
		FullImpactSpeed: number,
		SoftDipStuds: number,
		HardDipStuds: number,
		Frequency: number,
		Damping: number,
		-- How far the camera may rise above neutral on the rebound, in studs.
		MaxReboundStuds: number,
		-- Two landings closer than this are one.
		CooldownSeconds: number,
	},
}

export type State = {
	-- Low-passed world velocity and the low-passed acceleration differenced from it.
	Velocity: Vector3,
	Accel: Vector3,
	-- The raw vertical speed of the previous live frame, for the landing read.
	RawVerticalSpeed: number,
	-- False until a frame has been seen live: the first one only seeds.
	Armed: boolean,
	Cooldown: number,
	Roll: number,
	RollVelocity: number,
	Pull: number,
	Dip: number,
	DipVelocity: number,
	Fov: number,
}

function CameraMotionMath.NewState(): State
	return {
		Velocity = Vector3.zero,
		Accel = Vector3.zero,
		RawVerticalSpeed = 0,
		Armed = false,
		Cooldown = 0,
		Roll = 0,
		RollVelocity = 0,
		Pull = 0,
		Dip = 0,
		DipVelocity = 0,
		Fov = 0,
	}
end

-- Forgets everything: the next live frame seeds, and every output is back at neutral.
function CameraMotionMath.Reset(state: State): ()
	state.Velocity = Vector3.zero
	state.Accel = Vector3.zero
	state.RawVerticalSpeed = 0
	state.Armed = false
	state.Cooldown = 0
	state.Roll = 0
	state.RollVelocity = 0
	state.Pull = 0
	state.Dip = 0
	state.DipVelocity = 0
	state.Fov = 0
end

local function smoothstep(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- 0..1 position of `value` between `low` and `high`.
local function band(value: number, low: number, high: number): number
	return math.clamp((value - low) / math.max(high - low, 1e-6), 0, 1)
end

-- The FOV the body's speed asks for, in degrees (before the Scale.Fov multiplier): planar speed above sprint widens it,
-- and so does free fall past the floor. `fallSpeed` is the downward speed, positive.
function CameraMotionMath.SpeedFov(planarSpeed: number, fallSpeed: number, tuning: Tuning): number
	local fov = tuning.Fov
	return fov.MaxDelta * smoothstep(band(planarSpeed, fov.StartSpeed, fov.FullSpeed))
		+ fov.FallMaxDelta * smoothstep(band(fallSpeed, fov.FallStartSpeed, fov.FallFullSpeed))
end

-- One frame. Returns (roll radians, pull studs, dip studs, fov degrees, landing severity 0..1 or nil):
--   roll      about the camera's forward axis; negative leans into a turn toward the camera's right
--   pull      studs the camera sits further back than neutral (the caller picks the direction)
--   dip       studs the camera sits below neutral; negative on the rebound
--   fov       the TARGET widening; FOVOffset eases toward it
--   severity  non-nil on the frame a landing is felt, 0 at the threshold, 1 at FullImpactSpeed
-- `cameraRight` is the camera's flat (Y = 0) unit right vector.
function CameraMotionMath.Step(
	state: State,
	velocity: Vector3,
	cameraRight: Vector3,
	suspended: boolean,
	deltaTime: number,
	tuning: Tuning
): (number, number, number, number, number?)
	if deltaTime <= 0 then
		return state.Roll, state.Pull, state.Dip, state.Fov, nil
	end
	local dt = math.min(deltaTime, tuning.Sampling.MaxStepSeconds)
	local scale = tuning.Scale

	local live = state.Armed and not suspended
	state.Armed = not suspended
	local previousVertical = state.RawVerticalSpeed
	state.RawVerticalSpeed = velocity.Y

	local leanTarget = 0
	local pullTarget = 0
	local fovTarget = 0
	local severity: number? = nil

	if live then
		local sampling = tuning.Sampling
		local previousFiltered = state.Velocity
		local filtered = previousFiltered:Lerp(velocity, FlightMath.EaseAlpha(sampling.VelocityFilterRate, dt))
		state.Velocity = filtered
		state.Accel =
			state.Accel:Lerp((filtered - previousFiltered) / dt, FlightMath.EaseAlpha(sampling.AccelFilterRate, dt))

		local planarSpeed = Vector3.new(filtered.X, 0, filtered.Z).Magnitude

		-- Lean: lateral acceleration across the screen, past a deadzone, faded in with speed.
		local lean = tuning.Lean
		local lateral = math.clamp(state.Accel:Dot(cameraRight) / lean.FullAccel, -1, 1)
		local past = math.max(math.abs(lateral) - lean.Deadzone, 0) / (1 - lean.Deadzone)
		leanTarget = -math.sign(lateral) * past * band(planarSpeed, 0, lean.MinSpeed) * math.rad(lean.MaxDegrees)
		leanTarget *= scale.Lean

		local pull = tuning.Pull
		pullTarget = pull.MaxStuds * smoothstep(band(planarSpeed, pull.StartSpeed, pull.FullSpeed)) * scale.Pull

		fovTarget = CameraMotionMath.SpeedFov(planarSpeed, math.max(-filtered.Y, 0), tuning) * scale.Fov

		-- Landing: the vertical speed lost this frame, capped at the speed the body had (a body still falling after
		-- the frame only lost part of it).
		local landing = tuning.Landing
		state.Cooldown = math.max(state.Cooldown - dt, 0)
		local absorbed = math.min(-previousVertical, velocity.Y - previousVertical)
		if absorbed >= landing.MinImpactSpeed and state.Cooldown <= 0 then
			state.Cooldown = landing.CooldownSeconds
			local felt = band(absorbed, landing.MinImpactSpeed, landing.FullImpactSpeed)
			severity = felt
			local peak = (landing.SoftDipStuds + (landing.HardDipStuds - landing.SoftDipStuds) * felt) * scale.Landing
			state.DipVelocity += peak / FlightMath.SpringPeakFactor(landing.Frequency, landing.Damping)
		end
	else
		-- Re-seed so the first live frame measures its acceleration from where the body really is.
		state.Velocity = velocity
		state.Accel = Vector3.zero
		state.Cooldown = 0
	end

	local lean = tuning.Lean
	state.Roll, state.RollVelocity =
		FlightMath.SpringAdvance(state.Roll, state.RollVelocity, leanTarget, lean.Frequency, lean.Damping, dt)
	state.Pull += (pullTarget - state.Pull) * FlightMath.EaseAlpha(tuning.Pull.EaseRate, dt)
	state.Fov = fovTarget

	local landing = tuning.Landing
	local dip, dipVelocity =
		FlightMath.SpringAdvance(state.Dip, state.DipVelocity, 0, landing.Frequency, landing.Damping, dt)
	local ceiling = landing.HardDipStuds * 1.3 * math.max(scale.Landing, 1)
	state.Dip = math.clamp(dip, -landing.MaxReboundStuds, ceiling)
	state.DipVelocity = dipVelocity

	return state.Roll, state.Pull, state.Dip, state.Fov, severity
end

return CameraMotionMath
