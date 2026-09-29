--!strict
--[[
	CameraFollowMath.lua

	Owns: the arithmetic of the camera's smoothed follow -- one frame of a point that chases the
	character's root on a critically damped spring, and how far behind it may trail. The pure half of
	Client/Camera/CameraFollow.lua, split out for the same reason Blimp/BlimpCameraMath is: it can be
	spec'd without a camera, a character or a frame clock (Client/Camera is not mounted in
	test.project.json; ReplicatedStorage/Shared is).

	WHY A SPRING AND NOT AN EASE. The complaint this answers is the camera moving "snappy" when a punch
	moves the body -- SwingLunge's step pushes the root forward at 10-15 studs/s from a standstill, and
	the stock camera is welded to the root, so the view takes that velocity step in a single frame. An
	exponential ease (FlightMath.EaseAlpha) would not fix it: it responds to a step in its target at FULL
	speed on the very first frame, which is the jerk. A second-order spring (FlightMath.SpringStep) starts
	from the velocity it already had, so the camera accelerates into the lunge and settles out of it.
	Critically damped by default, so it never swings past the body when the step ends.

	BOUNDED, ALWAYS. The trail is clamped per axis group (MaxHorizontalLagStuds, MaxVerticalLagStuds), so
	the camera can never fall far enough behind to lose the fight or clip into what the body just ran
	past. And a jump bigger than TeleportStuds in one frame (a respawn, a teleport, a streaming snap)
	re-seats the point instead of animating across the map.

	Returns the OFFSET (smoothed point minus target) in world space; the caller converts it into whatever
	space its writer needs. Zero means "no smoothing this frame".

	Does not own: when the follow runs, or where the offset is written (CameraFollow), and no tuning
	(CameraConstants.Follow).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

local CameraFollowMath = {}

export type Tuning = {
	-- Spring natural frequencies, radians/second. Higher settles faster (and trails less).
	HorizontalFrequency: number,
	VerticalFrequency: number,
	-- Damping ratio. 1 is critical: the fastest settle that never overshoots.
	Damping: number,
	-- The furthest the camera's focus may trail the body, flat and vertically.
	MaxHorizontalLagStuds: number,
	MaxVerticalLagStuds: number,
	-- A single-frame jump larger than this is a teleport, not motion: re-seat, don't animate.
	TeleportStuds: number,
}

export type State = {
	Position: Vector3?,
	Velocity: Vector3,
}

function CameraFollowMath.NewState(): State
	return { Position = nil, Velocity = Vector3.zero }
end

-- Forgets the trail: the next Step seats the point on its target with no lag.
function CameraFollowMath.Reset(state: State): ()
	state.Position = nil
	state.Velocity = Vector3.zero
end

-- Clamps a lag vector to the two bounds, horizontal (X/Z together) and vertical (Y) separately.
local function clampLag(lag: Vector3, tuning: Tuning): Vector3
	local flat = Vector3.new(lag.X, 0, lag.Z)
	local flatMagnitude = flat.Magnitude
	if flatMagnitude > tuning.MaxHorizontalLagStuds and flatMagnitude > 0 then
		flat = flat * (tuning.MaxHorizontalLagStuds / flatMagnitude)
	end
	local vertical = math.clamp(lag.Y, -tuning.MaxVerticalLagStuds, tuning.MaxVerticalLagStuds)
	return Vector3.new(flat.X, vertical, flat.Z)
end

-- One frame. Advances the smoothed point toward `target` and returns its offset from `target`.
function CameraFollowMath.Step(state: State, target: Vector3, deltaTime: number, tuning: Tuning): Vector3
	local position = state.Position
	if position == nil or (target - position).Magnitude > tuning.TeleportStuds then
		state.Position = target
		state.Velocity = Vector3.zero
		return Vector3.zero
	end
	-- A frame with no time in it (a paused step) holds the trail where it is rather than dividing by it.
	if deltaTime <= 0 then
		return clampLag(position - target, tuning)
	end

	local velocity = state.Velocity
	local x, vx =
		FlightMath.SpringStep(position.X, velocity.X, target.X, tuning.HorizontalFrequency, tuning.Damping, deltaTime)
	local y, vy =
		FlightMath.SpringStep(position.Y, velocity.Y, target.Y, tuning.VerticalFrequency, tuning.Damping, deltaTime)
	local z, vz =
		FlightMath.SpringStep(position.Z, velocity.Z, target.Z, tuning.HorizontalFrequency, tuning.Damping, deltaTime)

	-- The clamp moves the point, not just the returned offset, so the spring resumes from where the camera
	-- really is. Velocity is left alone: at the clamp it is already close to the body's own, and the
	-- critically damped release from there overshoots by hundredths of a stud at worst.
	local lag = clampLag(Vector3.new(x, y, z) - target, tuning)
	state.Position = target + lag
	state.Velocity = Vector3.new(vx, vy, vz)
	return lag
end

return CameraFollowMath
