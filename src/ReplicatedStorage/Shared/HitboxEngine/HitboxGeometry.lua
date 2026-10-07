--!strict
--[[
	HitboxGeometry.lua

	Owns: every geometric answer the hitbox engine needs about a (ShapeKind, Dimensions) pair --
	the broadphase volume, the exact containment test, forward reach, and the SWEPT containment test
	that is this engine's actual reason for existing.

	Pure math. No Workspace, no services, no state, no Instances -- which is what lets the server
	resolver, a future debug visualiser and a plain unit spec all consume the identical math instead
	of each carrying their own drifting copy. It is in Shared for that reason, not because a client
	currently requires it.

	Local space convention is HitboxTypes.lua's -- forward is -Z, up is +Y, right is +X, with "reach"
	shapes growing forward from the origin and "centred" shapes straddling it. Read that file's header
	before changing anything here.

	WHY SweptContainsPoint EXISTS, since it is the one function here the pre-rebuild shape module (the
	deleted Shared/HitboxShapes.lua) had no equivalent of:

	ContainsPoint answers "is this point inside the volume AT THIS INSTANT." Sampled discretely, that
	question has a blind spot exactly as wide as the distance the volume travelled since the last
	sample. A hitbox on a fist moving 60 studs/second jumps a full stud between 60Hz samples, and much
	further across a server hitch; a target thinner than that jump can be in front of the volume at
	sample N and behind it at sample N+1, never once inside it when asked. The swing passes visibly
	through them and reports nothing. Substepping (HitboxEngineConstants.MinSubstepSeconds) shrinks
	that gap; this function closes what remains of it by testing the point against the CONTINUOUS
	volume swept between the two poses, not just against the volume at the later one.

	It is affordable because of WHERE it sits: it runs only on the handful of candidates the
	broadphase already gathered this sample, never against the world. The step count adapts to how far
	the volume actually moved relative to its own thinnest dimension, so a stationary hitbox costs one
	extra containment test and a wild spinning one costs a bounded few -- all of it arithmetic, with
	no engine calls at all.

	Rotation is included in that travel estimate, not just translation. A swing anchored at the root
	that whips a hand through 120 degrees has barely moved its origin while its far edge has crossed
	several studs, and a translation-only estimate would size the sweep for the former and tunnel
	through the latter.

	Does not own: what any shape is FOR, when it is live, or anything about an attacker or a target.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

type ShapeKind = HitboxTypes.ShapeKind
type Dimensions = HitboxTypes.Dimensions

local HitboxGeometry = {}

-- Below this a length is treated as degenerate. Used as a divisor floor so a zero-thickness shape
-- produces "sample as finely as allowed" rather than a division by zero.
local EPSILON = 1e-4

-- Scratch Dimensions reused by SweptContainsPoint's interpolation loop. Single-threaded by
-- construction (the engine's Heartbeat is the only caller, and the value never escapes the loop it
-- is filled in), so one shared table is safe and keeps the swept test allocation-free -- it runs on
-- every candidate of every sample, which is the one place in this engine where per-call garbage
-- would actually show up in a profile.
local SCRATCH_DIMENSIONS: Dimensions = HitboxTypes.DefaultDimensions()

-- Shared by ContainsPoint and BoundingBox so the two can never disagree about how wide a cone is.
-- AngleDegrees is the FULL apex angle (what an author means by "a 45 degree cone"), so the half-angle
-- is what drives the taper. Clamped to 1..179 because
-- tan is undefined at 90 degrees of half-angle and meaningless past it.
local function coneBaseRadius(dimensions: Dimensions): number
	local halfAngle = math.rad(math.clamp(dimensions.AngleDegrees, 1, 179) / 2)
	return dimensions.Length * math.tan(halfAngle)
end

-- The oriented box a broadphase query should run, as (size, centre-in-local-space). Reach shapes
-- return a non-identity centre because they grow forward from the origin rather than around it.
function HitboxGeometry.BoundingBox(shape: ShapeKind, dimensions: Dimensions): (Vector3, CFrame)
	if shape == "Sphere" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, diameter), CFrame.identity
	elseif shape == "Capsule" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Length + diameter), CFrame.identity
	elseif shape == "Cylinder" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Length), CFrame.identity
	elseif shape == "Cone" then
		local baseDiameter = coneBaseRadius(dimensions) * 2
		return Vector3.new(baseDiameter, baseDiameter, dimensions.Length), CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Beam" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Length), CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Arc" then
		-- Conservatively the FULL ring, not the swept sector: an oriented box cannot express a sector,
		-- and the narrow-phase bearing test is what actually trims it. Over-gathering here is correct
		-- -- a broadphase that missed part of the sector would lose hits the narrow phase never sees.
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, dimensions.Height, diameter), CFrame.identity
	elseif shape == "Pillar" or shape == "Crescent" then
		-- Both are a flat disc of Height, one standing and one with a bite out of it: the full disc is the
		-- broadphase (an oriented box cannot express the bite, and the narrow phase trims it).
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, dimensions.Height, diameter), CFrame.identity
	elseif shape == "Ellipsoid" then
		return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Length), CFrame.identity
	elseif shape == "Hemisphere" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Radius), CFrame.new(0, 0, -dimensions.Radius / 2)
	elseif shape == "Frustum" then
		local diameter = math.max(dimensions.Radius, dimensions.InnerRadius) * 2
		return Vector3.new(diameter, diameter, dimensions.Length), CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Pyramid" or shape == "Wedge" then
		return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Length),
			CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Cross" then
		-- A bar thicker than the other arm's span would poke out of Width x Length, so the box takes the
		-- larger of the two on each axis.
		local thickness = dimensions.Radius * 2
		return Vector3.new(
			math.max(dimensions.Width, thickness),
			dimensions.Height,
			math.max(dimensions.Length, thickness)
		),
			CFrame.identity
	end
	-- Box, and the defensive fallback for a shape the sanitiser somehow let through.
	return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Length), CFrame.identity
end

-- One sphere fully containing the shape, centred on the shape's own origin. Used where a caller wants
-- a single cheap distance figure rather than an oriented box -- the rotational travel estimate in
-- sweptSteps, and Sphere's broadphase query.
function HitboxGeometry.BoundingRadius(shape: ShapeKind, dimensions: Dimensions): number
	local size, centre = HitboxGeometry.BoundingBox(shape, dimensions)
	return (size / 2).Magnitude + centre.Position.Magnitude
end

-- How far in front of the origin the volume reaches, in studs.
function HitboxGeometry.Reach(shape: ShapeKind, dimensions: Dimensions): number
	if shape == "Sphere" then
		return dimensions.Radius
	elseif shape == "Capsule" then
		return dimensions.Length / 2 + dimensions.Radius
	elseif shape == "Cylinder" then
		return dimensions.Length / 2
	elseif shape == "Cone" or shape == "Beam" then
		return dimensions.Length
	elseif shape == "Arc" or shape == "Pillar" or shape == "Crescent" or shape == "Hemisphere" then
		return dimensions.Radius
	elseif shape == "Frustum" or shape == "Pyramid" or shape == "Wedge" then
		return dimensions.Length
	elseif shape == "Cross" then
		return math.max(dimensions.Length, dimensions.Radius * 2) / 2
	end
	return dimensions.Length / 2
end

-- The shape's THINNEST dimension -- the width of the gap a target could tunnel through if the volume
-- moved further than this between two samples. It is what sizes the swept test's step count, which is
-- the only reason this function exists: a flat Arc needs finer interpolation than a fat Sphere moving
-- at the same speed, because the same jump hides a bigger fraction of it.
function HitboxGeometry.MinExtent(shape: ShapeKind, dimensions: Dimensions): number
	local extent: number
	if shape == "Sphere" or shape == "Capsule" then
		extent = dimensions.Radius * 2
	elseif shape == "Cylinder" or shape == "Beam" then
		extent = math.min(dimensions.Radius * 2, dimensions.Length)
	elseif shape == "Cone" then
		extent = math.min(coneBaseRadius(dimensions) * 2, dimensions.Length)
	elseif shape == "Arc" then
		extent = math.min(dimensions.Height, dimensions.Radius - dimensions.InnerRadius)
	elseif shape == "Pillar" or shape == "Cross" then
		extent = math.min(dimensions.Radius * 2, dimensions.Height)
	elseif shape == "Hemisphere" then
		extent = dimensions.Radius
	elseif shape == "Frustum" then
		extent = math.min(dimensions.Radius * 2, dimensions.Length)
	elseif shape == "Ellipsoid" or shape == "Pyramid" or shape == "Wedge" then
		extent = math.min(dimensions.Width, math.min(dimensions.Height, dimensions.Length))
	elseif shape == "Crescent" then
		-- The sickle's thickest point, dead ahead: from the outer rim at -Radius to where the bite begins.
		-- A bite of 0 is a whole disc.
		local thickness = if dimensions.InnerRadius > 0
			then dimensions.Radius + dimensions.Length - dimensions.InnerRadius
			else dimensions.Radius * 2
		extent = math.min(dimensions.Height, thickness)
	else
		extent = math.min(dimensions.Width, math.min(dimensions.Height, dimensions.Length))
	end
	return math.max(extent, EPSILON)
end

-- Exact narrow-phase containment, analytic per shape. `localPoint` is already in the hitbox's own
-- space; `margin` is slack in studs, never negative.
function HitboxGeometry.ContainsPoint(
	shape: ShapeKind,
	dimensions: Dimensions,
	localPoint: Vector3,
	margin: number
): boolean
	local m = math.max(margin, 0)
	local x, y, z = localPoint.X, localPoint.Y, localPoint.Z
	-- Distance FORWARD of the origin -- positive is in front, matching the -Z convention.
	local forward = -z

	if shape == "Sphere" then
		return localPoint.Magnitude <= dimensions.Radius + m
	elseif shape == "Capsule" then
		local halfLength = dimensions.Length / 2
		local nearestOnAxis = math.clamp(z, -halfLength, halfLength)
		local deltaZ = z - nearestOnAxis
		return math.sqrt(x * x + y * y + deltaZ * deltaZ) <= dimensions.Radius + m
	elseif shape == "Cylinder" then
		if math.abs(z) > dimensions.Length / 2 + m then
			return false
		end
		return math.sqrt(x * x + y * y) <= dimensions.Radius + m
	elseif shape == "Cone" then
		if forward < -m or forward > dimensions.Length + m then
			return false
		end
		local allowed = math.max(forward, 0) * math.tan(math.rad(math.clamp(dimensions.AngleDegrees, 1, 179) / 2))
		return math.sqrt(x * x + y * y) <= allowed + m
	elseif shape == "Beam" then
		if forward < -m or forward > dimensions.Length + m then
			return false
		end
		return math.sqrt(x * x + y * y) <= dimensions.Radius + m
	elseif shape == "Ellipsoid" then
		local nx = x / math.max(dimensions.Width / 2 + m, EPSILON)
		local ny = y / math.max(dimensions.Height / 2 + m, EPSILON)
		local nz = z / math.max(dimensions.Length / 2 + m, EPSILON)
		return nx * nx + ny * ny + nz * nz <= 1
	elseif shape == "Hemisphere" then
		return forward >= -m and localPoint.Magnitude <= dimensions.Radius + m
	elseif shape == "Frustum" then
		if forward < -m or forward > dimensions.Length + m then
			return false
		end
		-- Clamped, so the slack past either end still reads the end's own radius rather than extrapolating.
		local along = if dimensions.Length > EPSILON then math.clamp(forward / dimensions.Length, 0, 1) else 1
		local allowed = dimensions.InnerRadius + (dimensions.Radius - dimensions.InnerRadius) * along
		return math.sqrt(x * x + y * y) <= allowed + m
	elseif shape == "Pyramid" or shape == "Wedge" then
		if forward < -m or forward > dimensions.Length + m then
			return false
		end
		local along = if dimensions.Length > EPSILON then math.clamp(forward / dimensions.Length, 0, 1) else 1
		if math.abs(x) > dimensions.Width / 2 * along + m then
			return false
		end
		-- A Wedge keeps its full height all the way; a Pyramid closes in on both axes.
		local halfHeight = if shape == "Pyramid" then dimensions.Height / 2 * along else dimensions.Height / 2
		return math.abs(y) <= halfHeight + m
	elseif shape == "Pillar" then
		return math.abs(y) <= dimensions.Height / 2 + m and math.sqrt(x * x + z * z) <= dimensions.Radius + m
	elseif shape == "Crescent" then
		if math.abs(y) > dimensions.Height / 2 + m or math.sqrt(x * x + z * z) > dimensions.Radius + m then
			return false
		end
		-- The bite is a disc centred Length BEHIND the origin (+Z), so what is left bulges forward with its
		-- horns trailing back. The margin shrinks the bite, as it grows every other volume.
		local bite = math.max(dimensions.InnerRadius - m, 0)
		if bite <= 0 then
			return true
		end
		local behind = z - dimensions.Length
		return math.sqrt(x * x + behind * behind) >= bite
	elseif shape == "Cross" then
		if math.abs(y) > dimensions.Height / 2 + m then
			return false
		end
		local halfBar = dimensions.Radius + m
		if math.abs(z) <= halfBar and math.abs(x) <= dimensions.Width / 2 + m then
			return true
		end
		return math.abs(x) <= halfBar and math.abs(z) <= dimensions.Length / 2 + m
	elseif shape == "Arc" then
		if math.abs(y) > dimensions.Height / 2 + m then
			return false
		end
		local radial = math.sqrt(x * x + z * z)
		if radial > dimensions.Radius + m or radial < math.max(dimensions.InnerRadius - m, 0) then
			return false
		end
		if dimensions.AngleDegrees >= 360 then
			return true
		end
		-- Signed bearing from straight ahead (-Z), in degrees: 0 is dead centre, +-180 directly behind.
		-- The stud margin is converted into an angular slack AT THIS RADIUS, so a part clipping the
		-- sector's edge out at the rim isn't held to the same angular tolerance as one near the hub --
		-- a fixed degree margin would be several studs of slack at the rim and none at all at the centre.
		local bearing = math.deg(math.atan2(x, -z))
		local angularMargin = if radial > EPSILON then math.deg(math.atan(m / radial)) else 180
		return math.abs(bearing) <= dimensions.AngleDegrees / 2 + angularMargin
	end

	return math.abs(x) <= dimensions.Width / 2 + m
		and math.abs(y) <= dimensions.Height / 2 + m
		and math.abs(z) <= dimensions.Length / 2 + m
end

-- Dimension arithmetic -----------------------------------------------------------------------------

-- Scales every LINEAR measurement, leaving AngleDegrees alone. Angles are deliberately exempt: an
-- angle is not a length, and a cone at combo stage 4 should reach further with the same silhouette
-- rather than widening toward a hemisphere and eventually clamping at 360 -- at which point the
-- "scaling" would stop having any effect at all and the attack would quietly stop growing.
--
-- Writes into `out` rather than returning a new table, so the engine's per-sample scaling costs no
-- allocation. `out` may safely be the same table as `source`.
function HitboxGeometry.ScaleDimensions(source: Dimensions, multiplier: number, out: Dimensions): Dimensions
	out.Width = source.Width * multiplier
	out.Height = source.Height * multiplier
	out.Length = source.Length * multiplier
	out.Radius = source.Radius * multiplier
	out.InnerRadius = source.InnerRadius * multiplier
	out.AngleDegrees = source.AngleDegrees
	return out
end

function HitboxGeometry.CopyDimensions(source: Dimensions, out: Dimensions): Dimensions
	out.Width = source.Width
	out.Height = source.Height
	out.Length = source.Length
	out.Radius = source.Radius
	out.InnerRadius = source.InnerRadius
	out.AngleDegrees = source.AngleDegrees
	return out
end

function HitboxGeometry.LerpDimensions(a: Dimensions, b: Dimensions, alpha: number, out: Dimensions): Dimensions
	out.Width = a.Width + (b.Width - a.Width) * alpha
	out.Height = a.Height + (b.Height - a.Height) * alpha
	out.Length = a.Length + (b.Length - a.Length) * alpha
	out.Radius = a.Radius + (b.Radius - a.Radius) * alpha
	out.InnerRadius = a.InnerRadius + (b.InnerRadius - a.InnerRadius) * alpha
	out.AngleDegrees = a.AngleDegrees + (b.AngleDegrees - a.AngleDegrees) * alpha
	return out
end

-- Swept containment --------------------------------------------------------------------------------

-- How finely the interval between two poses has to be subdivided so nothing thinner than the shape
-- itself can hide between the steps. Exported because the spec pins its behaviour directly -- the
-- step count IS the anti-tunnelling guarantee, and a silent regression to 1 would leave every other
-- test still passing.
function HitboxGeometry.SweptSteps(
	shape: ShapeKind,
	dimensionsAtStart: Dimensions,
	poseAtStart: CFrame,
	dimensionsAtEnd: Dimensions,
	poseAtEnd: CFrame,
	margin: number
): number
	local linearTravel = (poseAtEnd.Position - poseAtStart.Position).Magnitude

	-- Rotational contribution: the shape's outermost point traces an arc of (angle * radius) even
	-- when the origin has not moved at all. Without this term a swing that pivots on a stationary root
	-- -- which is most melee -- would be sampled as though nothing had moved.
	local relative = poseAtStart.Rotation:ToObjectSpace(poseAtEnd.Rotation)
	local _, angle = relative:ToAxisAngle()
	if angle ~= angle then
		angle = 0
	end
	-- The LARGER of the two bounding radii: the arc its outermost point traces is longest at whichever
	-- end the volume is biggest, and a step count sized from the smaller end would under-sample a
	-- rotating hitbox for exactly the half of the interval where it sweeps furthest.
	local radius = math.max(
		HitboxGeometry.BoundingRadius(shape, dimensionsAtStart),
		HitboxGeometry.BoundingRadius(shape, dimensionsAtEnd)
	)
	local arcTravel = math.abs(angle) * radius

	-- Conversely the SMALLER of the two thicknesses, because that is the widest gap a target could
	-- slip through at any point in the interval. Taking the end value alone would step a GROWING
	-- volume as coarsely as its final thick size while it was still thin -- reintroducing tunnelling
	-- precisely during a charge attack's early frames.
	--
	-- The margin genuinely thickens the volume, so it genuinely widens the gap a step may span.
	-- Folding it in here rather than ignoring it avoids oversampling a generously-margined hitbox.
	local thinnest =
		math.min(HitboxGeometry.MinExtent(shape, dimensionsAtStart), HitboxGeometry.MinExtent(shape, dimensionsAtEnd))
	local gap = thinnest + math.max(margin, 0) * 2
	local steps = math.ceil((linearTravel + arcTravel) / math.max(gap, EPSILON))
	return math.clamp(steps, 1, HitboxEngineConstants.MaxSweptSteps)
end

-- Tests a WORLD-space point against the volume swept between two consecutive samples, rather than
-- against the volume at the later one alone. See this file's header for why.
--
-- The end pose is tested first and returns immediately: a target that is simply inside the hitbox --
-- the overwhelmingly common case -- costs exactly one containment test and never touches the
-- interpolation path at all.
function HitboxGeometry.SweptContainsPoint(
	shape: ShapeKind,
	dimensionsAtStart: Dimensions,
	poseAtStart: CFrame,
	dimensionsAtEnd: Dimensions,
	poseAtEnd: CFrame,
	worldPoint: Vector3,
	margin: number
): boolean
	if HitboxGeometry.ContainsPoint(shape, dimensionsAtEnd, poseAtEnd:PointToObjectSpace(worldPoint), margin) then
		return true
	end

	local steps = HitboxGeometry.SweptSteps(shape, dimensionsAtStart, poseAtStart, dimensionsAtEnd, poseAtEnd, margin)

	-- Walks alpha from 0 up to (steps-1)/steps. alpha = 1 is the end pose, already tested above, so
	-- excluding it here is what keeps the common case at exactly one test rather than two.
	for index = 0, steps - 1 do
		local alpha = index / steps
		local pose = poseAtStart:Lerp(poseAtEnd, alpha)
		local dimensions = HitboxGeometry.LerpDimensions(dimensionsAtStart, dimensionsAtEnd, alpha, SCRATCH_DIMENSIONS)
		if HitboxGeometry.ContainsPoint(shape, dimensions, pose:PointToObjectSpace(worldPoint), margin) then
			return true
		end
	end

	return false
end

return HitboxGeometry
