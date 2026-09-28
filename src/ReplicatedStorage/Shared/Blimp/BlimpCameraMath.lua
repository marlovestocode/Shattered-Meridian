--!strict
--[[
	BlimpCameraMath.lua

	Owns: the arithmetic of the aboard-a-blimp camera -- turning one frame's raw hull physics into the
	roll, sway, pitch, positional offset and FOV delta the view should be wearing this frame. A spring
	network and the filter in front of it, and nothing else.

	TOUCHES NO INSTANCE, exactly like Server/Blimp/BlimpDrive.lua and for exactly the same payoff: the
	entire FEEL of this camera -- does a turn overshoot and settle, does opening the throttle shove the
	view backward, does the bob fade out once the ship is making way, does letting go of everything
	return to level -- is answerable in the TestEZ suite by feeding numbers to a table, rather than only
	by flying a blimp in Studio and squinting. Client/Camera/BlimpCamera.lua owns every Instance touch
	(reading the hull, writing the camera) and calls this for all of the maths.

	THERE ARE THREE KINDS OF CUE HERE AND THEY DO DIFFERENT JOBS. Getting this wrong is what made the
	first version of this camera read as flat despite every channel working exactly as specified:

	  * The SPRINGS answer to CHANGE -- a turn, a climb, a throttle move. They are the weight.
	  * The KICK is a one-shot impulse on the rung actually moving. It is the RECEIPT for a control
	    whose real effect takes two and a half seconds to arrive, and without it the telegraph feels
	    like a key that does nothing.
	  * The RUMBLE never settles, because an engine never does. It is the only cue that survives a
	    steady cruise -- and a steady cruise is where a pilot spends nearly all of their time.

	The first version had only the first of those, which meant that the moment a ship settled onto a
	heading the view went as still as standing on solid ground. Every individual channel was correct
	and the whole thing was inert, because the situation being presented is mostly a STEADY one.

	SPRINGS, NOT EASES, AND THAT IS THE WHOLE POINT. This codebase already has an exponential ease --
	Shared/FlightMath.EaseAlpha -- and it is the right tool nearly everywhere it is used: a value
	chasing a target, arriving from one side, never overshooting. It is the wrong tool here. A camera
	riding a heavy thing that is being pushed around should lean a little too far into the turn and come
	back; the horizon should dip when the engines bite and rise past level when they cut. That
	overshoot is not decoration, it is the only cue in the frame that says the ship has mass. An ease
	physically cannot produce it. So every channel below is a damped harmonic oscillator with its own
	frequency and its own damping ratio, tuned under 1 so it rings once and settles.

	THE INTEGRATOR IS IMPLICIT EULER, not the semi-implicit form, and that is a stability decision
	rather than an accuracy one. Semi-implicit Euler on a spring is only stable while dt < 2/frequency;
	at the stiffest rate this system ships that is about 180ms, which a Studio breakpoint, a streaming
	hitch or a client that alt-tabbed clears easily -- and the failure is not a wobble, it is the
	spring diverging and the camera being flung. The implicit form below is unconditionally stable at
	ANY dt (it degrades toward "snap to target", never toward "explode"), which is the correct failure
	mode for something a player is looking through, and it costs one extra divide per channel.

	IT ALLOCATES NOTHING IN THE STEADY STATE. One State and one Pose table per mount, both reused and
	mutated in place for the whole ride; every spring is a pair of plain number fields rather than a
	{Value, Velocity} table, and springStep returns its two numbers as multiple returns, which Luau
	does not box. This runs on every rendered frame for every player aboard a blimp, and a per-frame
	table for each of seven channels is exactly the kind of steady GC pressure the client performance
	audit already found in two other per-frame paths.

	NOTHING HERE READS A NUMBER THE SERVER SENT. The input is the hull assembly's own
	AssemblyLinearVelocity/AssemblyAngularVelocity, which Roblox already replicates for free because
	the hull is a physically simulated body -- see Client/Camera/BlimpCamera.lua's header for why that
	is both cheaper and MORE honest than pushing the server's own integrator state down the wire: the
	server's Target is the pose the hull is being asked to reach, and the camera should answer to where
	the hull actually IS.

	Does not own: the tuning numbers (Shared/Blimp/BlimpConstants.Camera), reading the hull or writing
	the camera (Client/Camera/BlimpCamera.lua), or the character's own lean, which is a different pose
	on a different channel with its own opposite-sign reasoning (Shared/Blimp/BlimpPilotPose.lua).
]]

local BlimpConstants = require(script.Parent.BlimpConstants)
local FlightMath = require(script.Parent.Parent.FlightMath)
local VesselMotion = require(script.Parent.Parent.Vessel.VesselMotion)

local BlimpCameraMath = {}

-- Seconds. A frame longer than this is a hitch, not motion, and running the acceleration difference
-- across it would report a spike the hull never experienced. Same reasoning, and deliberately the same
-- order of magnitude, as BlimpDrive's own MAX_STEP_SECONDS.
local MAX_STEP_SECONDS = 0.2

-- One frame's measured hull motion, already filtered. Every field is in the HULL's own frame, not the
-- world's -- which is what lets one set of coefficients work regardless of which way the ship is
-- pointed.
export type Motion = {
	-- Studs/second along the hull's own look vector. Signed: negative is making way astern.
	ForwardSpeed: number,
	-- Studs/second across it. Nonzero mid-turn (the hull crabs slightly) and after a collision.
	LateralSpeed: number,
	-- Radians/second of yaw. The turn signal, and the input to both rotational channels.
	YawRate: number,
	-- Studs/second of world Y.
	ClimbRate: number,
	-- Studs/second^2 along the hull's look vector, differentiated from ForwardSpeed and filtered
	-- harder than it (see BlimpConstants.Camera.Smoothing). The accelerate/decelerate signal.
	ForwardAccel: number,
	-- ForwardSpeed as a fraction of this hull's own cruise speed, clamped 0..1. Astern reports 0
	-- rather than a negative fraction: the pull-back and the FOV widen are "how fast is this going",
	-- and reversing out of a mooring is not fast.
	SpeedFraction: number,
}

-- What the camera should wear this frame. Rotations are radians in the CAMERA's own local space, to
-- be composed onto whatever the stock follow-cam already produced; Offset is in Humanoid.CameraOffset's
-- local space (X right, Y up, Z back).
export type Pose = {
	RollRadians: number,
	YawRadians: number,
	PitchRadians: number,
	Offset: Vector3,
	FovDelta: number,
}

-- Every spring is two plain fields rather than a table -- see this file's header on allocation.
export type State = {
	Motion: Motion,
	Pose: Pose,

	RollValue: number,
	RollVelocity: number,
	SwayValue: number,
	SwayVelocity: number,
	PitchValue: number,
	PitchVelocity: number,

	OffsetXValue: number,
	OffsetXVelocity: number,
	OffsetYValue: number,
	OffsetYVelocity: number,
	OffsetZValue: number,
	OffsetZVelocity: number,

	FovValue: number,
	-- How much of the idle bob is currently being applied, 0..1. Its own eased value rather than a
	-- straight function of this frame's speed, because the bob has to be able to wind DOWN on release --
	-- see Step, and BlimpConstants.Camera.Bob.GainEaseSpeed.
	BobGain: number,

	-- The filtered raw signals, kept across frames because each is an exponential filter over its own
	-- history rather than a function of this frame alone.
	SmoothForward: number,
	SmoothLateral: number,
	SmoothYaw: number,
	SmoothClimb: number,
	SmoothAccel: number,

	-- Last frame's filtered forward speed, differentiated against to get acceleration.
	PreviousForward: number,
	-- False until the first Observe has run. The first frame has no previous speed to difference
	-- against, and treating a cold 0 as one reports the hull's entire current speed as a single
	-- frame's worth of acceleration -- which, boarding a blimp already at flank, is a violent shove
	-- backward on the exact frame the player's view is handed to this module.
	Primed: boolean,

	-- Seconds since this mount began -- the clock behind both driven oscillators (the bob and the
	-- rumble). Per-mount rather than os.clock() so each starts at a known phase instead of wherever the
	-- session happened to be.
	Elapsed: number,
}

-- The spring itself lives in Shared/FlightMath.lua alongside EaseAlpha, not here -- see that
-- function's own header for the implicit-Euler stability argument this file's header summarises, and
-- for when to reach for a spring over an ease. It is shared because Shared/Blimp/BlimpPilotPose.lua
-- needs the identical integrator for the mounted body's lean, and two hand-rolled copies of a damped
-- oscillator is exactly how one of them ends up subtly wrong.
local springStep = FlightMath.SpringStep

-- THE MEASUREMENT HALF OF THIS MODULE LIVES IN Shared/Vessel/VesselMotion.lua NOW, and Observe/
-- ZeroMotion below are delegations to it. The line the split was taken along: this file does two
-- separable things -- it MEASURES a hull, and it decides what a camera wears as a result -- and only
-- the first is wanted by the mounted body's lean or by a vehicle with no bespoke camera of its own.
--
-- State BELOW IS UNCHANGED and still carries every field it always had, which is what made the
-- delegation free: VesselMotion.State is a strict subset of it, so a State from here satisfies that
-- one structurally with no wrapper, no nesting, and no change at any call site.
local motionSampler = VesselMotion.New(BlimpConstants.Camera.Smoothing)

-- Framerate-independent exponential filter, deliberately routed through the SAME FlightMath.EaseAlpha
-- every other eased value in this codebase uses rather than growing a second one here. The springs
-- above are what this module adds; the filter in front of them is not novel and should not pretend
-- to be.
local function filter(current: number, target: number, ratePerSecond: number, dt: number): number
	return current + (target - current) * FlightMath.EaseAlpha(ratePerSecond, dt)
end

local function clampMagnitude(value: number, limit: number): number
	return math.clamp(value, -limit, limit)
end

-- A one-shot impulse, for the moment the engine telegraph actually moves. `rungDelta` is signed --
-- positive is a rung toward flank -- and the impulse scales with it, so ringing down from Flank to
-- Full shoves the view forward exactly as braking does.
--
-- IMPLEMENTED AS A VELOCITY INJECTION INTO THE SPRINGS THAT ALREADY OWN THOSE AXES, not as a fourth
-- animated channel. That is both less code and more physically honest: a step change in commanded
-- thrust IS an impulse, and handing it to the fore-aft spring means it composes with whatever that
-- spring was already doing rather than being summed on top by a separate system with its own decay.
-- It also means the kick inherits the spring's own settle, so a pilot walking the ladder with a held
-- key gets one continuous swell rather than five discrete thumps.
--
-- Deliberately does NOT touch the FOV, even though the kick has an FOV component: that one is a
-- Client/FX/FOVOffset.lua Punch fired by Client/Camera/BlimpCamera.lua, so it rides the same
-- FieldOfViewEffects comfort opt-out as every other impact punch in the game rather than this
-- module's own vehicle-motion one.
function BlimpCameraMath.Kick(state: State, rungDelta: number): ()
	local cfg = BlimpConstants.Camera.Kick
	state.OffsetZVelocity += rungDelta * cfg.OffsetVelocityPerRung
	state.PitchVelocity += rungDelta * cfg.PitchVelocityPerRung
end

function BlimpCameraMath.NewState(): State
	return {
		Motion = {
			ForwardSpeed = 0,
			LateralSpeed = 0,
			YawRate = 0,
			ClimbRate = 0,
			ForwardAccel = 0,
			SpeedFraction = 0,
		},
		Pose = {
			RollRadians = 0,
			YawRadians = 0,
			PitchRadians = 0,
			Offset = Vector3.zero,
			FovDelta = 0,
		},

		RollValue = 0,
		RollVelocity = 0,
		SwayValue = 0,
		SwayVelocity = 0,
		PitchValue = 0,
		PitchVelocity = 0,

		OffsetXValue = 0,
		OffsetXVelocity = 0,
		OffsetYValue = 0,
		OffsetYVelocity = 0,
		OffsetZValue = 0,
		OffsetZVelocity = 0,

		FovValue = 0,
		BobGain = 0,

		SmoothForward = 0,
		SmoothLateral = 0,
		SmoothYaw = 0,
		SmoothClimb = 0,
		SmoothAccel = 0,

		PreviousForward = 0,
		Primed = false,

		Elapsed = 0,
	}
end

-- Reads one frame of hull physics into `state.Motion`, in place. `hullCFrame`/`linearVelocity`/
-- `angularVelocity` come straight off the assembly root; `cruiseSpeed` is THIS hull's own resolved
-- cruise speed (BlimpTagging.ResolveTuning), not the shipped default -- a hull tuned to half speed
-- should reach full pull-back at ITS full speed, not at two thirds of somebody else's.
--
-- Mutates rather than returning a table, and returns nothing at all, so a caller cannot accidentally
-- start allocating a Motion per frame by using the return value.
--
-- The arithmetic is Shared/Vessel/VesselMotion.lua's -- read that file for the flattened forward axis,
-- the two filters and the un-primed first frame, all of which were written here and moved there intact.
function BlimpCameraMath.Observe(
	state: State,
	hullCFrame: CFrame,
	linearVelocity: Vector3,
	angularVelocity: Vector3,
	cruiseSpeed: number,
	deltaTime: number
): ()
	motionSampler.Observe(state, hullCFrame, linearVelocity, angularVelocity, cruiseSpeed, deltaTime)
end

-- Zeroes the measured motion without touching the springs -- the release path. Every channel then
-- settles toward level under its own spring on subsequent Step calls, which is what makes stepping
-- off a blimp a glide back to a neutral view rather than a snap.
--
-- Also un-primes the accelerometer, so a player who dismounts at flank and boards another ship a
-- second later does not get the first hull's last known speed differenced against the second's first.
-- Both behaviours are Shared/Vessel/VesselMotion.Zero's now; the springs this file owns are, correctly,
-- none of that module's business.
function BlimpCameraMath.ZeroMotion(state: State): ()
	VesselMotion.Zero(state)
end

-- Advances every spring one frame and writes `state.Pose`, in place.
--
-- `rotationEnabled` false is the camera-comfort opt-out (Types.ComfortSettings.VehicleCameraMotion):
-- the three ROTATIONAL channels are driven to zero, and the positional ones are left running. That
-- split is deliberate rather than a half-measure. Rotating the horizon under someone is what actually
-- provokes simulator sickness -- it disagrees with their inner ear about which way is down. Sliding
-- the camera a couple of studs does not; it reads as the ship having weight, and taking it away costs
-- a player who needed the toggle every cue that they are moving at all.
function BlimpCameraMath.Step(state: State, deltaTime: number, rotationEnabled: boolean): ()
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
	if dt <= 0 then
		return
	end
	state.Elapsed += dt

	local cfg = BlimpConstants.Camera
	local motion = state.Motion
	local pose = state.Pose

	-- Rotational channels. Negated so a starboard turn (positive yaw rate under this codebase's own
	-- convention -- see BlimpDrive.Step) drops the starboard side of the view, matching the hull's own
	-- bank rather than fighting it.
	local rollTarget = if rotationEnabled
		then clampMagnitude(-motion.YawRate * cfg.Roll.RadiansPerYawRate, cfg.Roll.MaxRadians)
		else 0
	state.RollValue, state.RollVelocity =
		springStep(state.RollValue, state.RollVelocity, rollTarget, cfg.Roll.Stiffness, cfg.Roll.Damping, dt)

	local swayTarget = if rotationEnabled
		then clampMagnitude(motion.YawRate * cfg.Sway.RadiansPerYawRate, cfg.Sway.MaxRadians)
		else 0
	state.SwayValue, state.SwayVelocity =
		springStep(state.SwayValue, state.SwayVelocity, swayTarget, cfg.Sway.Stiffness, cfg.Sway.Damping, dt)

	local pitchTarget = if rotationEnabled
		then clampMagnitude(motion.ClimbRate * cfg.Pitch.RadiansPerClimbRate, cfg.Pitch.MaxRadians)
		else 0
	state.PitchValue, state.PitchVelocity =
		springStep(state.PitchValue, state.PitchVelocity, pitchTarget, cfg.Pitch.Stiffness, cfg.Pitch.Damping, dt)

	-- Positional channels. All three share one stiffness/damping pair on purpose: they are three axes
	-- of one displacement, and letting them settle at different rates makes the camera trace a curve
	-- back to centre instead of a line.
	local offsetCfg = cfg.Offset
	local slideTarget = clampMagnitude(motion.YawRate * offsetCfg.SlideStudsPerYawRate, offsetCfg.MaxSlideStuds)
	state.OffsetXValue, state.OffsetXVelocity =
		springStep(state.OffsetXValue, state.OffsetXVelocity, slideTarget, offsetCfg.Stiffness, offsetCfg.Damping, dt)

	local heaveTarget = clampMagnitude(motion.ClimbRate * offsetCfg.HeaveStudsPerClimbRate, offsetCfg.MaxHeaveStuds)
	state.OffsetYValue, state.OffsetYVelocity =
		springStep(state.OffsetYValue, state.OffsetYVelocity, heaveTarget, offsetCfg.Stiffness, offsetCfg.Damping, dt)

	-- Steady pull-back with speed PLUS the surge with acceleration -- one spring, two summed targets,
	-- rather than two springs on the same axis. Two springs would each settle independently and their
	-- sum would ring twice off one throttle change.
	local surgeTarget = clampMagnitude(motion.ForwardAccel * offsetCfg.SurgeStudsPerAccel, offsetCfg.MaxSurgeStuds)
	local pullBackTarget = motion.SpeedFraction * offsetCfg.PullBackStudsAtCruise + surgeTarget
	state.OffsetZValue, state.OffsetZVelocity = springStep(
		state.OffsetZValue,
		state.OffsetZVelocity,
		pullBackTarget,
		offsetCfg.Stiffness,
		offsetCfg.Damping,
		dt
	)

	-- The idle bob rides ON TOP of the settled Y spring rather than being a target fed into it: it is
	-- a driven oscillation with a fixed period, and a spring asked to chase a sine wave attenuates and
	-- phase-shifts it by an amount that depends on the spring's own rate.
	--
	-- Which also means it has no natural way to WIND DOWN -- every other channel here settles because its
	-- spring pulls it to zero, and a driven oscillator just keeps oscillating. So its amplitude is gated
	-- by an eased gain rather than applied outright, on two conditions: how fast the ship is going (a
	-- hull under way has its own motion and does not need a second, slower one under it), and whether
	-- anything is being measured at all. The second is the load-bearing one: ZeroMotion un-primes the
	-- state, so a released camera's bob fades to nothing instead of running forever -- which is what lets
	-- Client/Camera/BlimpCamera.lua's release ever finish and unbind its render step.
	local bob = cfg.Bob
	local bobTarget = if state.Primed
		then 1 - math.clamp(math.abs(motion.ForwardSpeed) / math.max(bob.FadeOutSpeed, 1), 0, 1)
		else 0
	state.BobGain = filter(state.BobGain, bobTarget, bob.GainEaseSpeed, dt)
	local bobOffset = if state.BobGain > 1e-4
		then FlightMath.ComputeHoverBobOffset(state.Elapsed, bob.AmplitudeStuds, bob.PeriodSeconds) * state.BobGain
		else 0

	-- ENGINE RUMBLE. The one channel with no target and no settle -- see this file's header on why a
	-- steady cruise has nothing else left to say. Summed ON TOP of the settled spring values rather
	-- than fed in as a target, for the same reason the bob is: a spring asked to chase an 11Hz
	-- oscillation would attenuate and phase-shift it by an amount that depends on the spring's own rate,
	-- which is a filter nobody asked for.
	--
	-- Scaled by how hard the ship is WORKING, with a floor: a hull at dead slow is still burning coal,
	-- and a purely linear scale from zero would make the engine unfelt at exactly the speeds a pilot
	-- spends most of their time at. Rotational, so the comfort opt-out silences it with the rest.
	local rumbleRadians = 0
	if rotationEnabled then
		local rumble = cfg.Rumble
		local drive = math.abs(motion.SpeedFraction)
		local intensity = if drive > 1e-3 then rumble.IdleFraction + (1 - rumble.IdleFraction) * drive else 0
		rumbleRadians = intensity * rumble.MaxRadians
	end
	local rumblePhase = state.Elapsed * cfg.Rumble.BaseFrequency
	-- Two incommensurate oscillators per axis, and the two axes read the pair in opposite order, so
	-- roll and pitch never peak together and the result reads as vibration rather than as a circle.
	local rumbleA = math.sin(rumblePhase)
	local rumbleB = math.sin(rumblePhase * cfg.Rumble.BeatRatio)

	pose.RollRadians = state.RollValue + rumbleRadians * (rumbleA * 0.6 + rumbleB * 0.4)
	pose.YawRadians = state.SwayValue
	pose.PitchRadians = state.PitchValue + rumbleRadians * (rumbleB * 0.6 - rumbleA * 0.4)
	pose.Offset = Vector3.new(state.OffsetXValue, state.OffsetYValue + bobOffset, state.OffsetZValue)

	-- FOV stays a plain ease rather than a spring, and it is the one channel that should. An
	-- overshooting field of view does not read as weight, it reads as a lens breathing -- the effect
	-- every other FOV consumer in this codebase (Constants.Camera.Sprint/Flight) also deliberately
	-- eases rather than springs.
	state.FovValue = filter(state.FovValue, motion.SpeedFraction * cfg.Fov.MaxDeltaAtCruise, cfg.Fov.EaseSpeed, dt)
	pose.FovDelta = state.FovValue
end

return BlimpCameraMath
