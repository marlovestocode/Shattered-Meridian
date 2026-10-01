--!strict
--[[
	ProjectileMotion.lua

	Owns: the pure math of a projectile's flight -- how a volley spreads out of its aim (Volley), how one
	step of flight moves a shot (Integrate), how a heading turns toward a target (TurnToward), and the
	reflection of a velocity off a surface (Reflect).

	SHARED BY THREE CALLERS, AND THAT IS WHY IT IS ITS OWN MODULE. The server's ProjectileSimulator flies
	the real shots with it; the client's ProjectileFX flies the visuals with it between the server's
	events; the Move Editor's plot draws a volley's paths with it. One integrator means the thing a player
	sees and the thing the author plotted are the thing the server hit with -- the arrangement the editor's
	HitboxPlot already has with HitboxGeometry.ContainsPoint.

	PURE: numbers, vectors and CFrames in, the same out. No Instances, no clock, no services.

	Does not own: the vocabulary (ProjectileTypes), collision, targets, or any lifecycle
	(Server/Combat/HitboxEngine/ProjectileSimulator.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type ProjectileSpec = ProjectileTypes.ProjectileSpec

local ProjectileMotion = {}

local EPSILON = 1e-4

-- One shot of a volley: where it starts and which way it flies (a unit vector).
export type Shot = {
	Origin: Vector3,
	Direction: Vector3,
}

-- The subset of a spec that moves a shot once it is flying -- what the client is handed at launch, so it
-- can fly a visual without the whole spec.
export type Motion = {
	Gravity: number,
	Acceleration: number,
	-- Degrees per second; 0 is no homing.
	HomingStrength: number,
	MaxSpeed: number,
}

function ProjectileMotion.MotionOf(spec: ProjectileSpec): Motion
	return {
		Gravity = spec.Gravity,
		Acceleration = spec.Acceleration,
		HomingStrength = if spec.Homing then spec.HomingStrength else 0,
		MaxSpeed = ProjectileTypes.Limits.Speed.Max,
	}
end

-- The Fan's angle for shot `index` of `count`, in degrees, positive to the right. Evenly across the arc,
-- both ends included -- except a full circle, whose two ends are the same heading, so a 360 fan steps
-- 360/count and never fires two shots down one line.
function ProjectileMotion.FanAngle(index: number, count: number, spreadAngle: number): number
	if count <= 1 then
		return 0
	end
	if spreadAngle >= 360 then
		return -180 + 360 * (index - 1) / count
	end
	return -spreadAngle / 2 + spreadAngle * (index - 1) / (count - 1)
end

-- Shot `index`'s frame relative to the aim: a rotation for the diverging patterns, a translation for
-- the parallel ones. See ProjectileTypes' header for what each pattern means.
local function patternOffset(spec: ProjectileSpec, index: number, count: number): CFrame
	local pattern = spec.SpreadPattern
	if count <= 1 or pattern == "Single" then
		return CFrame.identity
	elseif pattern == "Fan" then
		-- A positive Y rotation turns -Z toward -X (left), so "positive is right" is a negative one.
		return CFrame.Angles(0, -math.rad(ProjectileMotion.FanAngle(index, count, spec.SpreadAngle)), 0)
	elseif pattern == "Horizontal" then
		return CFrame.new((index - (count + 1) / 2) * spec.Spacing, 0, 0)
	elseif pattern == "Vertical" then
		return CFrame.new(0, ((count + 1) / 2 - index) * spec.Spacing, 0)
	end
	-- Radial: tilted SpreadAngle/2 off the aim axis, then spun around it (a roll about the forward axis).
	local spin = 2 * math.pi * (index - 1) / count
	return CFrame.Angles(0, 0, spin) * CFrame.Angles(math.rad(spec.SpreadAngle / 2), 0, 0)
end

-- Every shot of one volley, out of `aim` (a world CFrame: position is the spawn point, LookVector the
-- centre of the volley, its roll the pattern's plane). Deterministic: the same spec and aim always give
-- the same shots in the same order, so shot N is the same shot on every machine.
function ProjectileMotion.Volley(spec: ProjectileSpec, aim: CFrame): { Shot }
	local count = ProjectileTypes.ShotCount(spec)
	local shots: { Shot } = table.create(count)
	for index = 1, count do
		local frame = aim * patternOffset(spec, index, count)
		shots[index] = { Origin = frame.Position, Direction = frame.LookVector }
	end
	return shots
end

-- The angle between two unit vectors, in radians.
function ProjectileMotion.AngleBetween(a: Vector3, b: Vector3): number
	return math.acos(math.clamp(a:Dot(b), -1, 1))
end

-- `direction` turned toward `desired` by at most `maxRadians` (both unit). Exactly `desired` when it is
-- already within reach. Straight behind has no unique turning axis, so it turns about world up (or,
-- flying vertically, about world X) -- any axis is correct there, and this one is stable.
function ProjectileMotion.TurnToward(direction: Vector3, desired: Vector3, maxRadians: number): Vector3
	local angle = ProjectileMotion.AngleBetween(direction, desired)
	if angle <= maxRadians or angle <= EPSILON then
		return desired
	end
	local axis = direction:Cross(desired)
	if axis.Magnitude <= EPSILON then
		axis = direction:Cross(Vector3.yAxis)
		if axis.Magnitude <= EPSILON then
			axis = Vector3.xAxis
		end
	end
	return (CFrame.fromAxisAngle(axis.Unit, maxRadians) * direction).Unit
end

-- One step of flight. Homing turns the heading first (toward `homingPoint`, when there is one and the
-- motion homes), then Acceleration changes speed along it, then Gravity pulls, then the shot moves.
-- Speed is clamped to [0, MaxSpeed] -- a decelerating shot stops and hangs rather than reversing.
--
-- Semi-implicit (velocity first, then position with the new velocity), which is stable for a constant
-- pull and needs no spring's care: nothing here oscillates.
function ProjectileMotion.Integrate(
	position: Vector3,
	velocity: Vector3,
	motion: Motion,
	dt: number,
	homingPoint: Vector3?
): (Vector3, Vector3)
	local speed = velocity.Magnitude
	local moved = velocity
	if speed > EPSILON then
		local direction = velocity / speed
		if homingPoint and motion.HomingStrength > 0 then
			local toward = homingPoint - position
			if toward.Magnitude > EPSILON then
				direction = ProjectileMotion.TurnToward(direction, toward.Unit, math.rad(motion.HomingStrength) * dt)
			end
		end
		speed = math.clamp(speed + motion.Acceleration * dt, 0, motion.MaxSpeed)
		moved = direction * speed
	end
	if motion.Gravity ~= 0 then
		moved += Vector3.new(0, -motion.Gravity * dt, 0)
		local magnitude = moved.Magnitude
		if magnitude > motion.MaxSpeed then
			moved = moved * (motion.MaxSpeed / magnitude)
		end
	end
	return position + moved * dt, moved
end

-- `velocity` reflected off a surface with unit `normal`, with no loss.
function ProjectileMotion.Reflect(velocity: Vector3, normal: Vector3): Vector3
	return velocity - 2 * velocity:Dot(normal) * normal
end

-- Points along one shot's unhomed flight, from its origin, until it has flown `maxLength` studs or its
-- lifetime -- `segments` pieces of equal time. For drawing (the Move Editor's plot), so each piece is
-- integrated in a few substeps: a lobbed shot is drawn as the curve it flies, not as its chord.
function ProjectileMotion.Path(spec: ProjectileSpec, shot: Shot, maxLength: number, segments: number): { Vector3 }
	local motion = ProjectileMotion.MotionOf(spec)
	local flight = math.min(spec.LifetimeSeconds, math.min(spec.MaxRange, maxLength) / math.max(spec.Speed, EPSILON))
	local points = { shot.Origin }
	local position, velocity = shot.Origin, shot.Direction * spec.Speed
	local travelled = 0
	local limit = math.min(spec.MaxRange, maxLength)
	local substeps = 4
	local dt = flight / segments / substeps
	for _ = 1, segments do
		for _ = 1, substeps do
			local nextPosition, nextVelocity = ProjectileMotion.Integrate(position, velocity, motion, dt, nil)
			travelled += (nextPosition - position).Magnitude
			position, velocity = nextPosition, nextVelocity
		end
		table.insert(points, position)
		if travelled >= limit then
			break
		end
	end
	return points
end

return ProjectileMotion
