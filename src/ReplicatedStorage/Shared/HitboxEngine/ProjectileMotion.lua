--!strict
--[[
	ProjectileMotion.lua

	Owns: the pure math of a projectile's flight -- how a volley spreads out of its aim (Volley, and Cast for
	every wave of one), how one step of flight moves a shot (Integrate), how a heading turns toward a target
	(TurnToward), the reflection of a velocity off a surface (Reflect), and the few derived answers the
	simulator and the editor both need: a mirrored spawn (MirrorOffset), an intercept aim (Intercept), a
	range falloff (Falloff) and the drawn path of one shot (Path).

	SHARED BY THREE CALLERS, AND THAT IS WHY IT IS ITS OWN MODULE. The server's ProjectileSimulator flies
	the real shots with it; the client's ProjectileFX flies the visuals with it between the server's
	events; the Move Editor's plot draws a volley's paths with it. One integrator means the thing a player
	sees and the thing the author plotted are the thing the server hit with -- the arrangement the editor's
	HitboxPlot already has with HitboxGeometry.ContainsPoint.

	AGE-DRIVEN WHERE IT MUST AGREE (2026-10-26). A weave and homing's delay/duration window are functions of
	the shot's age, passed to Integrate as the age at the START of the step. The weave turns the heading by
	the difference of its sine between the step's two ends, so the turns telescope: N small steps and one big
	step over the same span turn a shot by exactly the same total, and a client flying at 144 Hz draws the path
	the server flew at 60. A caller that passes no age gets the motion it always had (no weave, homing
	ungated) -- every Motion field added here is optional for the same reason.

	PURE: numbers, vectors and CFrames in, the same out. No Instances, no clock, no services.

	Does not own: the vocabulary (ProjectileTypes), collision, targets, or any lifecycle
	(Server/Combat/HitboxEngine/ProjectileSimulator.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type ProjectileSpec = ProjectileTypes.ProjectileSpec

local ProjectileMotion = {}

local EPSILON = 1e-4
local TAU = 2 * math.pi

-- One shot of a volley: where it starts and which way it flies (a unit vector).
export type Shot = {
	Origin: Vector3,
	Direction: Vector3,
}

-- One shot of a whole cast (Cast): which wave and which shot of it, and how long after the first it fires.
export type CastShot = {
	Origin: Vector3,
	Direction: Vector3,
	Wave: number,
	Index: number,
	At: number,
}

-- The subset of a spec that moves a shot once it is flying -- what the client is handed at launch, so it
-- can fly a visual without the whole spec. Everything past MaxSpeed is optional (this file's header).
export type Motion = {
	Gravity: number,
	Acceleration: number,
	-- Degrees per second; 0 is no homing.
	HomingStrength: number,
	MaxSpeed: number,
	MinSpeed: number?,
	-- Homing turns only while age is in [HomingDelay, HomingDelay + HomingDuration); a duration of 0 is the
	-- whole flight.
	HomingDelay: number?,
	HomingDuration: number?,
	-- Weave amplitude in radians (0 is none), angular frequency in radians per second, the plane, and its
	-- sign (-1 on a WeaveMirrored volley's every second shot).
	WeaveRadians: number?,
	WeaveOmega: number?,
	WeaveVertical: boolean?,
	WeaveSign: number?,
}

-- `mirrored` inverts the weave -- a WeaveMirrored volley's even shots.
function ProjectileMotion.MotionOf(spec: ProjectileSpec, mirrored: boolean?): Motion
	return {
		Gravity = spec.Gravity,
		Acceleration = spec.Acceleration,
		HomingStrength = if spec.Homing then spec.HomingStrength else 0,
		MaxSpeed = spec.MaxSpeed,
		MinSpeed = spec.MinSpeed,
		HomingDelay = spec.HomingDelaySeconds,
		HomingDuration = spec.HomingDurationSeconds,
		WeaveRadians = math.rad(spec.WeaveDegrees),
		WeaveOmega = TAU * spec.WeaveFrequency,
		WeaveVertical = spec.WeavePlane == "Vertical",
		WeaveSign = if mirrored then -1 else 1,
	}
end

-- The motion a returning shot flies with (ProjectileTypes' header, Return): homing on its thrower at the
-- return rate, from now on, with nothing else about its flight changed. No weave: it is coming home.
function ProjectileMotion.ReturnMotionOf(motion: Motion, spec: ProjectileSpec): Motion
	local returning = table.clone(motion)
	returning.HomingStrength = spec.ReturnTurnRate
	returning.HomingDelay = 0
	returning.HomingDuration = 0
	returning.WeaveRadians = 0
	return returning
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

-- Where shot `index` of a Grid sits, right and up of the aim: rows of `columns`, `spacing` apart both
-- ways, the block centred on the aim and a short last row centred under the others.
function ProjectileMotion.GridCell(index: number, count: number, columns: number, spacing: number): (number, number)
	local width = math.clamp(math.floor(columns), 1, math.max(count, 1))
	local rows = math.ceil(count / width)
	local row = (index - 1) // width
	local column = (index - 1) % width
	local inRow = if row == rows - 1 then count - width * (rows - 1) else width
	return (column - (inRow - 1) / 2) * spacing, ((rows - 1) / 2 - row) * spacing
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
	elseif pattern == "Grid" then
		local right, up = ProjectileMotion.GridCell(index, count, spec.Columns, spec.Spacing)
		return CFrame.new(right, up, 0)
	elseif pattern == "Circle" then
		-- From the aim's right, anticlockwise as the thrower sees it.
		local angle = TAU * (index - 1) / count
		return CFrame.new(math.cos(angle) * spec.FormationRadius, math.sin(angle) * spec.FormationRadius, 0)
	end
	-- Radial: tilted SpreadAngle/2 off the aim axis, then spun around it (a roll about the forward axis).
	local spin = TAU * (index - 1) / count
	return CFrame.Angles(0, 0, spin) * CFrame.Angles(math.rad(spec.SpreadAngle / 2), 0, 0)
end

-- Every shot of one volley, out of `aim` (a world CFrame: position is the spawn point, LookVector the
-- centre of the volley, its roll the pattern's plane). `wave` (default 1) turns the pattern
-- WaveRollDegrees per wave after the first. Deterministic: the same spec, aim and wave always give the same
-- shots in the same order, so shot N is the same shot on every machine.
function ProjectileMotion.Volley(spec: ProjectileSpec, aim: CFrame, wave: number?): { Shot }
	local count = ProjectileTypes.ShotCount(spec)
	local shots: { Shot } = table.create(count)
	local roll = math.rad(spec.WaveRollDegrees * ((wave or 1) - 1))
	local rolled = if roll ~= 0 then aim * CFrame.Angles(0, 0, roll) else aim
	local pattern = spec.SpreadPattern
	-- A Fan or a Ring with a radius starts each shot that far out along its own heading.
	local pushOut = if (pattern == "Fan" or pattern == "Radial") and spec.FormationRadius > 0
		then CFrame.new(0, 0, -spec.FormationRadius)
		else nil
	local focus = if spec.ConvergeDistance > 0 then aim.Position + aim.LookVector * spec.ConvergeDistance else nil
	for index = 1, count do
		local frame = rolled * patternOffset(spec, index, count)
		if pushOut then
			frame *= pushOut
		end
		local direction = frame.LookVector
		if focus then
			local toward = focus - frame.Position
			if toward.Magnitude > EPSILON then
				direction = toward.Unit
			end
		end
		shots[index] = { Origin = frame.Position, Direction = direction }
	end
	return shots
end

-- When shot `index` of wave `wave` fires, in seconds after the cast's first shot.
function ProjectileMotion.FireTime(spec: ProjectileSpec, wave: number, index: number): number
	return (wave - 1) * spec.WaveIntervalSeconds + (index - 1) * spec.ShotIntervalSeconds
end

-- Every shot of every wave of one cast, in firing order, from a FIXED aim -- the editor's picture of a
-- cast (the server re-aims Follow waves as the thrower turns, which a still preview cannot know).
-- `mirroredAim` is the aim every second wave fires from when AlternateSides is on.
function ProjectileMotion.Cast(spec: ProjectileSpec, aim: CFrame, mirroredAim: CFrame?): { CastShot }
	local waves = math.max(1, math.floor(spec.WaveCount))
	local shots: { CastShot } = {}
	for wave = 1, waves do
		local waveAim = if spec.AlternateSides and wave % 2 == 0 and mirroredAim then mirroredAim else aim
		for index, shot in ProjectileMotion.Volley(spec, waveAim, wave) do
			table.insert(shots, {
				Origin = shot.Origin,
				Direction = shot.Direction,
				Wave = wave,
				Index = index,
				At = ProjectileMotion.FireTime(spec, wave, index),
			})
		end
	end
	table.sort(shots, function(a: CastShot, b: CastShot): boolean
		if a.At ~= b.At then
			return a.At < b.At
		end
		if a.Wave ~= b.Wave then
			return a.Wave < b.Wave
		end
		return a.Index < b.Index
	end)
	return shots
end

-- `aim` with its spawn point lifted by the spec's SpawnHeight along world up (ProjectileTypes' header,
-- Height); its rotation is untouched. `groundY` is the height of the ground under the spawn point, when the
-- caller found one -- HeightFrom Ground measures from it, and without it falls back to the spawn point.
function ProjectileMotion.Raise(spec: ProjectileSpec, aim: CFrame, groundY: number?): CFrame
	local position = aim.Position
	local raised: Vector3
	if spec.HeightFrom == "Ground" and groundY ~= nil then
		raised = Vector3.new(position.X, groundY + spec.SpawnHeight, position.Z)
	elseif spec.SpawnHeight ~= 0 then
		raised = position + Vector3.new(0, spec.SpawnHeight, 0)
	else
		return aim
	end
	return aim.Rotation + raised
end

-- `offset` mirrored across its own right/left (the YZ plane): right becomes left, and a yaw or a roll turns
-- the other way, while up, forward and pitch are kept. AlternateSides' every second wave.
function ProjectileMotion.MirrorOffset(offset: CFrame): CFrame
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = offset:GetComponents()
	return CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
end

-- The unit direction a shot at `origin` flying `speed` must take to meet a body at `target` moving at
-- `velocity` (constant), or nil when it cannot catch it. Straight flight; gravity and homing are not
-- solved for -- a lead is an aim, and the shot's own flight does the rest.
function ProjectileMotion.Intercept(origin: Vector3, target: Vector3, velocity: Vector3, speed: number): Vector3?
	local offset = target - origin
	-- |offset + velocity t| = speed t  ->  a t^2 + b t + c = 0
	local a = velocity:Dot(velocity) - speed * speed
	local b = 2 * offset:Dot(velocity)
	local c = offset:Dot(offset)
	local t: number
	if math.abs(a) < EPSILON then
		if math.abs(b) < EPSILON then
			return nil
		end
		t = -c / b
	else
		local discriminant = b * b - 4 * a * c
		if discriminant < 0 then
			return nil
		end
		local root = math.sqrt(discriminant)
		local t1 = (-b - root) / (2 * a)
		local t2 = (-b + root) / (2 * a)
		t = math.huge
		if t1 > EPSILON then
			t = t1
		end
		if t2 > EPSILON and t2 < t then
			t = t2
		end
	end
	if t <= EPSILON or t == math.huge then
		return nil
	end
	local aimPoint = offset + velocity * t
	return if aimPoint.Magnitude > EPSILON then aimPoint.Unit else nil
end

-- The damage scale a contact `travelled` studs into the flight carries: 1 up to FalloffStartStuds, then
-- linearly down to FalloffMinScale at MaxRange.
function ProjectileMotion.Falloff(spec: ProjectileSpec, travelled: number): number
	local floor = spec.FalloffMinScale
	if floor >= 1 or travelled <= spec.FalloffStartStuds then
		return 1
	end
	local span = spec.MaxRange - spec.FalloffStartStuds
	if span <= EPSILON then
		return 1
	end
	local alpha = math.clamp((travelled - spec.FalloffStartStuds) / span, 0, 1)
	return 1 + (floor - 1) * alpha
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

-- Whether homing steers at `age` (nil: always -- the caller is not age-aware).
local function homingOpen(motion: Motion, age: number?): boolean
	if motion.HomingStrength <= 0 then
		return false
	end
	if age == nil then
		return true
	end
	local delay = motion.HomingDelay or 0
	if age < delay then
		return false
	end
	local duration = motion.HomingDuration or 0
	return duration <= 0 or age < delay + duration
end

-- The weave's turn over [age, age + dt], applied to `direction` (unit).
local function weave(direction: Vector3, motion: Motion, age: number, dt: number): Vector3
	local amplitude = motion.WeaveRadians or 0
	local omega = motion.WeaveOmega or 0
	if amplitude <= 0 or omega <= 0 then
		return direction
	end
	local turn = amplitude * (motion.WeaveSign or 1) * (math.sin(omega * (age + dt)) - math.sin(omega * age))
	if math.abs(turn) <= 1e-7 then
		return direction
	end
	local axis: Vector3
	if motion.WeaveVertical then
		-- The pitch axis: across the heading, level with the ground.
		axis = direction:Cross(Vector3.yAxis)
		if axis.Magnitude <= EPSILON then
			axis = Vector3.xAxis
		end
	else
		axis = if math.abs(direction.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	end
	return (CFrame.fromAxisAngle(axis.Unit, turn) * direction).Unit
end

-- One step of flight. Homing turns the heading first (toward `homingPoint`, when there is one and the
-- motion homes at this age), then the weave turns it, then Acceleration changes speed along it, then
-- Gravity pulls, then the shot moves. Speed is clamped to [MinSpeed, MaxSpeed] -- a decelerating shot
-- stops and hangs rather than reversing. `age` is the shot's age at the START of the step (this file's
-- header); nil is the motion without its age-driven parts.
--
-- Semi-implicit (velocity first, then position with the new velocity), which is stable for a constant
-- pull and needs no spring's care: nothing here oscillates but the weave, which is exact by construction.
function ProjectileMotion.Integrate(
	position: Vector3,
	velocity: Vector3,
	motion: Motion,
	dt: number,
	homingPoint: Vector3?,
	age: number?
): (Vector3, Vector3)
	local speed = velocity.Magnitude
	local moved = velocity
	if speed > EPSILON then
		local direction = velocity / speed
		if homingPoint and homingOpen(motion, age) then
			local toward = homingPoint - position
			if toward.Magnitude > EPSILON then
				direction = ProjectileMotion.TurnToward(direction, toward.Unit, math.rad(motion.HomingStrength) * dt)
			end
		end
		if age ~= nil then
			direction = weave(direction, motion, age, dt)
		end
		speed = math.clamp(
			speed + motion.Acceleration * dt,
			math.min(motion.MinSpeed or 0, motion.MaxSpeed),
			motion.MaxSpeed
		)
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

-- How far a shot at `position` has used its range: along its path (`travelled`) or as the straight
-- distance from `origin`, by the spec's RangeMode.
function ProjectileMotion.RangeUsed(spec: ProjectileSpec, travelled: number, origin: Vector3, position: Vector3): number
	if spec.RangeMode == "Displacement" then
		return (position - origin).Magnitude
	end
	return travelled
end

-- Points along one shot's unhomed flight, from its origin, until it has flown `maxLength` studs (or its
-- range) or its lifetime -- `segments` pieces of equal time. For drawing (the Move Editor's plot), so each
-- piece is integrated in a few substeps: a lobbed or weaving shot is drawn as the curve it flies, not as
-- its chord. A returning shot is drawn coming back to its origin, which stands in for the thrower.
-- `mirrored` is a WeaveMirrored volley's even shot.
function ProjectileMotion.Path(
	spec: ProjectileSpec,
	shot: Shot,
	maxLength: number,
	segments: number,
	mirrored: boolean?
): { Vector3 }
	local motion = ProjectileMotion.MotionOf(spec, mirrored)
	local limit = math.min(spec.MaxRange, maxLength)
	local returns = spec.ReturnAfterSeconds > 0 and spec.ReturnAfterSeconds < spec.LifetimeSeconds
	local flight = spec.LifetimeSeconds
	if not returns and spec.Acceleration >= 0 then
		flight = math.min(flight, limit / math.max(spec.Speed, spec.MinSpeed, EPSILON))
	end
	local points = { shot.Origin }
	local position, velocity = shot.Origin, shot.Direction * spec.Speed
	local legOrigin = shot.Origin
	local travelled = 0
	local age = 0
	local returning = false
	local substeps = 4
	local dt = flight / segments / substeps
	for _ = 1, segments do
		for _ = 1, substeps do
			if returns and not returning and age >= spec.ReturnAfterSeconds then
				returning = true
				motion = ProjectileMotion.ReturnMotionOf(motion, spec)
				legOrigin = position
				travelled = 0
			end
			local homingPoint = if returning then shot.Origin else nil
			local nextPosition, nextVelocity =
				ProjectileMotion.Integrate(position, velocity, motion, dt, homingPoint, age)
			travelled += (nextPosition - position).Magnitude
			position, velocity = nextPosition, nextVelocity
			age += dt
		end
		table.insert(points, position)
		if returning and (position - shot.Origin).Magnitude <= 2 then
			break
		end
		if ProjectileMotion.RangeUsed(spec, travelled, legOrigin, position) >= limit then
			break
		end
	end
	return points
end

return ProjectileMotion
