--!strict
--[[
	FlightMath.lua

	Owns: pure, Instance-free math for the dev-menu flight feature (Client/DevMenu/FlightController.lua/
	FlightPhysics.lua) -- velocity/momentum integration, bank-angle-from-turn-rate, and the hover idle
	bob. Deliberately has no Roblox Instance dependency (no Humanoid, no BasePart, no Workspace), the
	same "pure logic, safe for both sides to read" shape luau-coding-standards.md asks of Shared
	ModuleScripts -- which is exactly what makes it headlessly TestEZ-testable, the same reasoning
	Server/Combat/Movement.lua's ComputeDesiredWalkSpeed and Client/FX/FXPool.lua already get tested
	this way.

	Does not own: any Constants.Flight lookup, any Instance mutation, or the noclip-vs-collide branch
	(FlightController.lua reads Constants.Flight itself and passes plain numbers/Vector3s in here).
]]

local FlightMath = {}

-- Frame-rate-independent step toward `target` at `ratePerSecond` studs/s^2, expressed as "the
-- fraction of the remaining gap to close this frame" -- never overshoots even at a large deltaTime
-- (e.g. a lag spike), unlike a naive `current + rate*deltaTime` displacement step.
local function stepToward(current: number, target: number, ratePerSecond: number, deltaTime: number): number
	local gap = target - current
	local maxStep = ratePerSecond * deltaTime
	if math.abs(gap) <= maxStep then
		return target
	end
	return current + maxStep * (if gap > 0 then 1 else -1)
end

-- Integrates `current` velocity toward a target velocity this frame. If `desiredDirection` is
-- (near-)zero, decelerates straight toward zero at `deceleration` studs/s^2 (no direction to chase).
-- Otherwise accelerates toward `desiredDirection.Unit * maxSpeed` at `acceleration` studs/s^2 --
-- applied per-axis via stepToward so the velocity vector smoothly re-targets even when
-- desiredDirection changes direction frame-to-frame (banking/turning), rather than snapping.
function FlightMath.ComputeNextVelocity(
	current: Vector3,
	desiredDirection: Vector3,
	maxSpeed: number,
	acceleration: number,
	deceleration: number,
	deltaTime: number
): Vector3
	local target: Vector3
	local rate: number
	if desiredDirection.Magnitude < 1e-4 then
		target = Vector3.zero
		rate = deceleration
	else
		target = desiredDirection.Unit * maxSpeed
		rate = acceleration
	end

	return Vector3.new(
		stepToward(current.X, target.X, rate, deltaTime),
		stepToward(current.Y, target.Y, rate, deltaTime),
		stepToward(current.Z, target.Z, rate, deltaTime)
	)
end

-- Maps a turn rate (radians/sec, signed -- positive = turning right) to a bank/roll angle
-- (radians, signed), clamped to +/- maxBankRadians. `sensitivity` is how strongly turn rate maps to
-- bank before the clamp kicks in -- higher sensitivity means a gentler turn already reads as a hard
-- lean.
function FlightMath.ComputeBankAngle(turnRateRadPerSec: number, maxBankRadians: number, sensitivity: number): number
	return math.clamp(turnRateRadPerSec * sensitivity, -maxBankRadians, maxBankRadians)
end

-- A small sinusoidal vertical offset (studs) for the hover idle bob, sampled off a monotonic clock
-- so it's continuous regardless of when a caller starts reading it (no phase reset needed).
function FlightMath.ComputeHoverBobOffset(clockSeconds: number, amplitudeStuds: number, periodSeconds: number): number
	if periodSeconds <= 0 then
		return 0
	end
	return amplitudeStuds * math.sin((2 * math.pi * clockSeconds) / periodSeconds)
end

-- Fraction of the remaining gap to a target to close THIS frame, for a frame-rate-independent
-- exponential ease (alpha = 1 - e^(-rate*dt)) -- before this extraction, the single most-repeated
-- formula across the client camera/flight code, independently reimplemented in Client/Camera/
-- FlightCamera.lua (FOV-delta and chase-offset ease), Client/Camera/ShiftLockCamera.lua (shoulder-
-- offset CameraOffset ease), Client/DevMenu/FlightController.lua (yaw/pitch/bank easeAngle), and
-- Client/FX/FOVOffset.lua (continuous-slot ease). Deliberately returns just the alpha rather than
-- an eased value: the four call sites apply it to three different shapes (a plain number via
-- `current + (target - current) * alpha`, a Vector3 via `current:Lerp(target, alpha)`, and a
-- wrap-around angle via FlightController.lua's own angleDelta instead of a plain subtraction), so
-- this function owns only the rate -> alpha conversion, never how a caller combines it with
-- current/target. Never overshoots or oscillates regardless of deltaTime (a lag spike still only
-- pushes alpha asymptotically toward, never past, 1).
function FlightMath.EaseAlpha(ratePerSecond: number, deltaTime: number): number
	return 1 - math.exp(-ratePerSecond * deltaTime)
end

-- Yaw angle (radians) of a direction vector's flattened (Y-zeroed) XZ projection -- shared by
-- Client/Camera/ShiftLockCamera.lua (deriving character facing from the camera's own look vector)
-- and Client/DevMenu/FlightController.lua (deriving character facing from flight velocity), which
-- had independently arrived at the identical formula: CFrame.Angles(0, yaw, 0) has LookVector
-- (-sin(yaw), 0, -cos(yaw)); solving for the flattened direction gives yaw = atan2(-x, -z). Returns
-- nil when the flattened vector is too close to straight up/down to have a usable yaw (magnitude
-- below 1e-3) rather than an arbitrary 0 -- both call sites already had their own "keep whatever
-- yaw we last had" fallback for this degenerate case, so nil lets each caller keep using that
-- fallback instead of silently snapping to a fixed facing.
function FlightMath.YawFromFlatDirection(direction: Vector3): number?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	local unit = flat.Unit
	-- Same formula Client/Camera/ShiftLockCamera.lua and Client/DevMenu/FlightController.lua's own
	-- (now-removed) local copies used: CFrame.Angles(0, yaw, 0) has LookVector (-sin(yaw), 0,
	-- -cos(yaw)) -- yaw=0 faces -Z (Roblox's default forward), yaw=+pi/2 faces -X (NOT +X -- see
	-- this function's own spec for the direction this sign convention actually produces). Solving
	-- for yaw given a unit (x, 0, z) direction: sin(yaw) = -x, cos(yaw) = -z, so
	-- yaw = atan2(-x, -z).
	return math.atan2(-unit.X, -unit.Z)
end

return FlightMath
