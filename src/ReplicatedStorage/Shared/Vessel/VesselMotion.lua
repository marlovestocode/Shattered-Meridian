--!strict
--[[
	VesselMotion.lua

	Owns: MEASURING a moving hull -- reading one frame of an assembly's replicated velocities into a
	filtered, hull-relative set of signals (forward speed, lateral speed, yaw rate, vertical rate,
	forward acceleration, and a speed fraction), and zeroing them on release.

	LIFTED OUT OF Shared/Blimp/BlimpCameraMath.lua when the Boat layer arrived, and the LINE the lift
	was taken along is the interesting part. That module does two separable things: it MEASURES a hull,
	and it decides WHAT A CAMERA WEARS as a result. Only the first is wanted by the pose path -- the
	mounted body's lean needs three numbers off a hull and nothing about a view -- and only the first is
	wanted by a vehicle that does not have a bespoke camera of its own. So the measurement moved and the
	camera model did not.

	BlimpCameraMath.Observe/ZeroMotion NOW DELEGATE HERE and are two lines each. Its State keeps every
	field it always had, which is what made the delegation free: this module's State is a strict SUBSET
	of that one, so a BlimpCameraMath.State satisfies it structurally with no wrapper, no nesting and no
	call-site change anywhere. The arithmetic below is that module's, moved rather than rewritten -- if
	the blimp camera ever behaves differently after this, the bug is in the move.

	READS THE HULL'S OWN REPLICATED PHYSICS, NEVER A NUMBER THE SERVER SENT. Every client aboard can see
	the same body moving, so a hull's speed and turn rate are free on every machine -- which is why no
	vehicle in this codebase puts a continuous quantity on its helm packet. Both the audio and the pose
	read this same sample rather than taking their own, so they can never disagree about how fast a ship
	is going.

	EVERY SIGNAL IS IN THE HULL'S OWN FRAME, not the world's, which is what lets one set of coefficients
	work regardless of which way the ship is pointed.

	MUTATES IN PLACE AND RETURNS NOTHING. This runs per rendered frame for every mounted body on screen;
	a Motion table per body per frame is exactly the steady GC pressure to avoid, and returning nothing
	at all is what stops a caller starting to allocate one by accident.

	Does not own: what a camera does with the answer (Shared/Blimp/BlimpCameraMath.lua's own springs and
	Pose), the smoothing numbers (each vehicle's Constants.Camera.Smoothing), or reading a hull's
	AssemblyRootPart -- the caller passes the values in, so this module never touches an Instance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

local VesselMotion = {}

-- Seconds. A frame longer than this is a hitch, not motion, and running the acceleration difference
-- across it would report a spike the hull never experienced.
local MAX_STEP_SECONDS = 0.2

-- Below this the hull has no usable facing to decompose its velocity along. Only reachable for a
-- degenerate CFrame, which is why the fallback is "report no motion this frame" rather than an error.
local EPSILON = 1e-4

-- How hard the raw physics sample is filtered. Roblox's replicated velocities on a constraint-driven
-- assembly are noisy at the frame scale; without this, every channel downstream buzzes even in a dead
-- calm.
export type Config = {
	VelocityEaseSpeed: number,
	-- Slower than the velocity filter, in every sane authoring of this: acceleration is a difference of
	-- an already-noisy signal, so it is the noisiest thing here and the one a player is least able to
	-- see directly.
	AccelEaseSpeed: number,
}

-- One frame's measured hull motion, already filtered.
export type Motion = {
	-- Studs/second along the hull's own look vector. Signed: negative is making way astern.
	ForwardSpeed: number,
	-- Studs/second across it. Nonzero mid-turn (the hull crabs slightly), after a collision, and -- on a
	-- boat -- for as long as she is making leeway.
	LateralSpeed: number,
	-- Radians/second of yaw. The turn signal, and the input to every rotational channel downstream.
	YawRate: number,
	-- Studs/second of world Y. A blimp's climb; a boat's heave off a swell. One channel, because a body
	-- standing on the deck does not care which of the two lifted it -- see
	-- Shared/Vessel/VesselPilotPose.Step, whose third argument this feeds.
	ClimbRate: number,
	-- Studs/second^2 along the hull's look vector, differentiated from ForwardSpeed and filtered harder
	-- than it. The accelerate/decelerate signal.
	ForwardAccel: number,
	-- ForwardSpeed as a fraction of the reference speed the caller passed, clamped 0..1. Astern reports
	-- 0 rather than a negative fraction: every consumer of this asks "how fast is this going", and
	-- backing out of a berth is not fast.
	SpeedFraction: number,
}

-- The fields this module owns. A caller may hold a LARGER state that also carries a camera's springs
-- (Shared/Blimp/BlimpCameraMath.State does) -- that is a subtype of this and passes straight in.
export type State = {
	Motion: Motion,
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
	-- against, and treating a cold 0 as one reports the hull's ENTIRE current speed as a single frame's
	-- worth of acceleration -- which, boarding a ship already under way, is a violent shove on the exact
	-- frame the player's view is handed to this module.
	Primed: boolean,
}

export type Sampler = {
	NewState: () -> State,
	Observe: (
		state: State,
		hullCFrame: CFrame,
		linearVelocity: Vector3,
		angularVelocity: Vector3,
		referenceSpeed: number,
		deltaTime: number
	) -> (),
	Zero: (state: State) -> (),
}

-- Framerate-independent exponential filter, deliberately routed through the SAME FlightMath.EaseAlpha
-- every other eased value in this codebase uses rather than growing a second one here.
local function filter(current: number, target: number, ratePerSecond: number, dt: number): number
	return current + (target - current) * FlightMath.EaseAlpha(ratePerSecond, dt)
end

-- Zeroes the measured motion. Exposed at module level as well as on every binding because it reads
-- nothing off the config, and because Shared/Blimp/BlimpCameraMath.ZeroMotion is a direct delegation to
-- it.
--
-- Also un-primes the accelerometer, so a player who steps off one hull at speed and boards another a
-- second later does not get the first one's last known speed differenced against the second's first.
function VesselMotion.Zero(state: State): ()
	local motion = state.Motion
	motion.ForwardSpeed = 0
	motion.LateralSpeed = 0
	motion.YawRate = 0
	motion.ClimbRate = 0
	motion.ForwardAccel = 0
	motion.SpeedFraction = 0

	state.SmoothForward = 0
	state.SmoothLateral = 0
	state.SmoothYaw = 0
	state.SmoothClimb = 0
	state.SmoothAccel = 0
	state.PreviousForward = 0
	state.Primed = false
end

-- One vehicle layer's bound sampler.
function VesselMotion.New(config: Config): Sampler
	local sampler = {}

	function sampler.NewState(): State
		return {
			Motion = {
				ForwardSpeed = 0,
				LateralSpeed = 0,
				YawRate = 0,
				ClimbRate = 0,
				ForwardAccel = 0,
				SpeedFraction = 0,
			},
			SmoothForward = 0,
			SmoothLateral = 0,
			SmoothYaw = 0,
			SmoothClimb = 0,
			SmoothAccel = 0,
			PreviousForward = 0,
			Primed = false,
		}
	end

	-- Reads one frame of hull physics into `state.Motion`, in place. `hullCFrame`/`linearVelocity`/
	-- `angularVelocity` come straight off the assembly root; `referenceSpeed` is THIS hull's own
	-- resolved top speed, not the shipped default -- a hull tuned to half speed should read as flat out
	-- at ITS full speed, not at two thirds of somebody else's.
	function sampler.Observe(
		state: State,
		hullCFrame: CFrame,
		linearVelocity: Vector3,
		angularVelocity: Vector3,
		referenceSpeed: number,
		deltaTime: number
	): ()
		local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
		if dt <= 0 then
			return
		end

		local motion = state.Motion

		-- Flattened to the horizontal plane before being used as the "forward" axis. A hull here is a
		-- physically simulated body, so it is nose-up or nose-down for a moment after any collision, any
		-- passenger's mass joining the assembly, any wave, and any tick where the orientation constraint
		-- is still settling. Decomposing velocity against that raw LookVector would report a pure rise as
		-- forward speed, which then differentiates into a phantom acceleration and shoves the view
		-- backward for no reason a player could see.
		local look = hullCFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude <= EPSILON then
			return
		end
		local forwardAxis = flat.Unit
		-- forward x up, written out rather than built with :Cross() -- the flattened forward makes two of
		-- the three components identically zero, and this axis is recomputed every frame for every player
		-- aboard. Sanity check against the engine's own convention: an identity CFrame looks down -Z and
		-- has RightVector +X, and (-(-1), 0, 0) is +X.
		local rightAxis = Vector3.new(-forwardAxis.Z, 0, forwardAxis.X)

		local rawForward = linearVelocity:Dot(forwardAxis)
		state.SmoothForward = filter(state.SmoothForward, rawForward, config.VelocityEaseSpeed, dt)
		state.SmoothLateral = filter(state.SmoothLateral, linearVelocity:Dot(rightAxis), config.VelocityEaseSpeed, dt)
		state.SmoothYaw = filter(state.SmoothYaw, angularVelocity.Y, config.VelocityEaseSpeed, dt)
		state.SmoothClimb = filter(state.SmoothClimb, linearVelocity.Y, config.VelocityEaseSpeed, dt)

		-- The first frame reports no acceleration at all rather than differencing against a cold zero --
		-- see State.Primed's own comment for what that costs when a player boards a ship already at speed.
		local rawAccel = if state.Primed then (state.SmoothForward - state.PreviousForward) / dt else 0
		state.SmoothAccel = filter(state.SmoothAccel, rawAccel, config.AccelEaseSpeed, dt)
		state.PreviousForward = state.SmoothForward
		state.Primed = true

		motion.ForwardSpeed = state.SmoothForward
		motion.LateralSpeed = state.SmoothLateral
		motion.YawRate = state.SmoothYaw
		motion.ClimbRate = state.SmoothClimb
		motion.ForwardAccel = state.SmoothAccel
		motion.SpeedFraction = math.clamp(state.SmoothForward / math.max(referenceSpeed, 1), 0, 1)
	end

	sampler.Zero = VesselMotion.Zero

	return sampler
end

return VesselMotion
