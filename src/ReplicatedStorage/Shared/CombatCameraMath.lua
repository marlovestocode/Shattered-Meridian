--!strict
--[[
	CombatCameraMath.lua

	Owns: the arithmetic and the one rule of the combat camera -- the pure half of Client/Camera/CombatCamera.lua, split out
	so both can be spec'd without a camera or a character:

	  * LockOnLook -- one frame of the lock-on's soft pull: the camera's yaw and pitch sprung toward a target, softened
	    at close range, stood down when the two bodies overlap. Moved intact from Client/Combat/LockOnController's
	    pullCamera (2026-10-27), so the numbers a player feels did not change.
	  * BodyFacingHeld -- whether something other than the shift-lock spring owns the local body's facing this frame
	    (a server hold, flight, a traversal, a swing's tracking). Moved intact from the old ShiftLockCamera's per-frame yaw guards.

	Does not own: the tuning (LockOnConstants.Camera, CameraConstants.ShiftLock), the target (LockOnController), or any
	Instance read or write (CombatCamera).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

local CombatCameraMath = {}

export type LookTuning = {
	YawFrequency: number,
	PitchFrequency: number,
	Damping: number,
	CloseRangeStuds: number,
	CloseRangeScale: number,
	PitchBias: number,
	MinPitch: number,
	MaxPitch: number,
	MinDistanceStuds: number,
}

-- The spring's memory between frames. Only the velocities: the VALUE is re-read off the camera every frame, so the
-- player's own mouse or stick input (applied by the camera scripts between two calls) is where the spring resumes from.
export type LookState = {
	YawVelocity: number,
	PitchVelocity: number,
}

export type FacingFlags = {
	-- Server-held: RootControlLocked (a ragdoll, a grab, an air-combo hold, a throw, a mount, a punish).
	RootControlLocked: boolean,
	-- The DefenseState is a punish (Staggered, GuardBroken) or a guard state a stagger runs underneath.
	PunishLocked: boolean,
	Grabbed: boolean,
	Mounted: boolean,
	Flying: boolean,
	-- Client owners of the facing: a traversal's orientation drive, a swing's target tracking.
	ParkourFacingOwned: boolean,
	CombatFacingOwned: boolean,
}

function CombatCameraMath.NewLookState(): LookState
	return { YawVelocity = 0, PitchVelocity = 0 }
end

-- Stops the pull's swing, so the next frame starts from rest (a new target, a stand-down).
function CombatCameraMath.ResetLook(state: LookState): ()
	state.YawVelocity = 0
	state.PitchVelocity = 0
end

-- One frame of the soft lock. `look` is the camera's current look vector, `focus` the point the camera scripts orbit,
-- `aim` the target point, `body` the local root's position. Returns the new (pitch, yaw) to write as the camera's
-- orientation, or nil when the pull stands down this frame (the bodies overlap, or the look has no usable yaw).
--
-- HOW CLOSE THE FIGHT IS is a fact about the BODY, so the stand-down and the close-range softening read the distance
-- from the root. The focus carries the shoulder offset and CameraFollow's trail, so measured from it the gate moved with
-- the camera and could cut out and restart from rest mid-exchange. The LOOK still aims from the focus: that is the point
-- the camera scripts orbit.
function CombatCameraMath.LockOnLook(
	state: LookState,
	look: Vector3,
	focus: Vector3,
	aim: Vector3,
	body: Vector3,
	deltaTime: number,
	tuning: LookTuning
): (number?, number?)
	local direction = aim - focus
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local bodyOffset = aim - body
	local bodyDistance = Vector3.new(bodyOffset.X, 0, bodyOffset.Z).Magnitude
	if bodyDistance < tuning.MinDistanceStuds then
		CombatCameraMath.ResetLook(state)
		return nil, nil
	end
	local currentYaw = FlightMath.YawFromFlatDirection(look)
	local desiredYaw = FlightMath.YawFromFlatDirection(flat)
	if currentYaw == nil or desiredYaw == nil then
		return nil, nil
	end
	local currentPitch = math.asin(math.clamp(look.Y, -1, 1))
	local desiredPitch =
		math.clamp(math.atan2(direction.Y, flat.Magnitude) + tuning.PitchBias, tuning.MinPitch, tuning.MaxPitch)

	-- Softer at arm's length, where small movements are big angles. 1 at CloseRangeStuds and beyond, down to
	-- CloseRangeScale at MinDistanceStuds.
	local closeness = math.clamp(
		(bodyDistance - tuning.MinDistanceStuds) / math.max(tuning.CloseRangeStuds - tuning.MinDistanceStuds, 1e-3),
		0,
		1
	)
	local scale = tuning.CloseRangeScale + (1 - tuning.CloseRangeScale) * closeness

	-- The yaw target is unwrapped next to the current yaw, so the spring always turns the short way round.
	local yaw, yawVelocity = FlightMath.SpringStep(
		currentYaw,
		state.YawVelocity,
		currentYaw + FlightMath.AngleDelta(currentYaw, desiredYaw),
		tuning.YawFrequency * scale,
		tuning.Damping,
		deltaTime
	)
	local pitch, pitchVelocity = FlightMath.SpringStep(
		currentPitch,
		state.PitchVelocity,
		desiredPitch,
		tuning.PitchFrequency * scale,
		tuning.Damping,
		deltaTime
	)
	state.YawVelocity = yawVelocity
	state.PitchVelocity = pitchVelocity
	return pitch, yaw
end

-- Whether something other than shift lock owns the body's facing this frame, so shift lock must not turn it.
--
-- A server hold owns it -- any write would compete with the server's AlignOrientation or ragdoll for the frame, and
-- the server wins the next replication tick anyway. A PUNISH-only hold is the exception: DefenseSystem takes
-- RootControlLocked for a stagger or a guard break only to park parkour, nothing rotates the body, and a player without
-- shift lock can still turn through it -- unless the body is also grabbed or mounted, which do rotate it. Flight
-- drives its own facing. A traversal (ParkourFacingOwned) and a swing's tracking (CombatFacingOwned) are client owners
-- holding the facing for their own window.
function CombatCameraMath.BodyFacingHeld(flags: FacingFlags): boolean
	local serverHold = flags.RootControlLocked and not (flags.PunishLocked and not flags.Grabbed and not flags.Mounted)
	return serverHold or flags.Flying or flags.ParkourFacingOwned or flags.CombatFacingOwned
end

return CombatCameraMath
