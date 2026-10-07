--!strict
--[[
	ProjectileBody.lua

	Owns: what a projectile's VOLUME is, as geometry -- the shape and measurements a ProjectileSpec asks
	for, the pose that volume takes as it flies along a heading, and the three radii the simulator and
	the client need from it (how far it reaches ahead, a sphere that stands in for it against the world,
	a sphere that holds all of it).

	THE SIMULATOR SWEEPS THIS, THE CLIENT DRAWS THIS, THE EDITOR PLOTS THIS. One module turns a spec
	into a body, so what an author sees in the editor, what flies on a client and what hits on the server
	are one volume -- the arrangement ProjectileMotion already has for the flight and HitboxGeometry has
	for the swing. The containment math is HitboxGeometry's, untouched: a projectile body is a hitbox
	shape that moves, which is the whole reason the shape vocabulary could be shared.

	POSE, AND WHICH WAY IT POINTS. A body's local -Z is its heading. A shape that is centred on its origin
	(Capsule, Box, Ellipsoid, Cylinder, Crescent, Cross, Pillar) is centred on the shot's position. A shape
	that GROWS FROM its origin (Cone, Pyramid, Wedge, Frustum) is turned round and shifted so it flies POINT
	FIRST with its middle on the shot's position -- an arrowhead, a dagger, a drill, the way a thrown
	weapon travels. A Crescent's thick edge leads: a cut flung forward. Sphere is the default and reads
	only Size, so a record from before shapes existed flies exactly as it did.

	PURE: specs, numbers, vectors and CFrames in, the same out. No Instances, no clock, no services.

	Does not own: the shape math (HitboxGeometry), the vocabulary (ProjectileTypes), flight
	(ProjectileMotion), collision or lifecycle (Server/Combat/HitboxEngine/ProjectileSimulator.lua), or
	how a client dresses the body (Client/FX/ProjectileFX.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type Dimensions = HitboxTypes.Dimensions
type ProjectileSpec = ProjectileTypes.ProjectileSpec

local ProjectileBody = {}

-- A body thinner than this is not swept as one: a sphere cast of zero radius against the world would
-- miss everything it grazes.
local MIN_CAST_RADIUS = 0.1
local EPSILON = 1e-4

export type Body = {
	Shape: HitboxTypes.ShapeKind,
	-- The measurements HitboxGeometry reads for Shape. Shared by every shot of the spec: read-only.
	Dimensions: Dimensions,
	-- True for a shape that grows from its origin and so flies apex first (see this file's header).
	Pointed: boolean,
	-- The body's bounding box (x across, y up, z along the heading), centred on the shot's position.
	Extents: Vector3,
	-- How far the body reaches ahead of / behind the shot's position, along the heading.
	LeadStuds: number,
	-- A sphere that stands in for the body against the WORLD, and how far ahead of the position its
	-- centre sits so its leading surface is the body's.
	CastRadius: number,
	CastLead: number,
	-- A sphere around the position that holds the whole body -- the broadphase's radius.
	BoundRadius: number,
	-- True for the plain sphere, which keeps its original Capsule-sweep fast path.
	IsSphere: boolean,
}

local POINTED: { [string]: boolean } = { Cone = true, Pyramid = true, Wedge = true, Frustum = true }

-- Which of the spec's measurements a body shape reads is HitboxTypes.FieldsFor's say; this only fills the
-- whole bag, so a shape that ignores a field is handed a harmless value for it.
function ProjectileBody.DimensionsOf(spec: ProjectileSpec): Dimensions
	local dimensions = HitboxTypes.DefaultDimensions()
	dimensions.Radius = spec.Size
	dimensions.Width = spec.Width
	dimensions.Height = spec.Height
	dimensions.Length = spec.Length
	dimensions.InnerRadius = math.min(spec.InnerRadius, spec.Size)
	dimensions.AngleDegrees = spec.AngleDegrees
	return dimensions
end

-- Builds the body a spec describes. Allocates -- call it once per volley (the simulator keeps the result on
-- each shot), never per step.
function ProjectileBody.Of(spec: ProjectileSpec): Body
	local shape = spec.Shape :: HitboxTypes.ShapeKind
	local dimensions = ProjectileBody.DimensionsOf(spec)
	local isSphere = shape == "Sphere"
	local pointed = POINTED[shape] == true

	local size, _ = HitboxGeometry.BoundingBox(shape, dimensions)
	local extents = size
	local lead = if pointed then size.Z / 2 else HitboxGeometry.Reach(shape, dimensions)
	local castRadius = if isSphere
		then spec.Size
		else math.max(HitboxGeometry.MinExtent(shape, dimensions) / 2, MIN_CAST_RADIUS)

	return {
		Shape = shape,
		Dimensions = dimensions,
		Pointed = pointed,
		Extents = extents,
		LeadStuds = lead,
		CastRadius = castRadius,
		CastLead = math.max(lead - castRadius, 0),
		BoundRadius = (extents / 2).Magnitude,
		IsSphere = isSphere,
	}
end

-- A frame at `position` looking along `direction` (unit). Straight up or down has no unique up vector, so
-- those take world X.
local function lookAlong(position: Vector3, direction: Vector3): CFrame
	local up = if math.abs(direction.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, position + direction, up)
end

-- The body's pose with its middle on `position`, travelling along `direction` (unit; a zero vector is
-- treated as straight ahead of the world's -Z, which only ever happens for a shot that has not moved).
function ProjectileBody.PoseAt(body: Body, position: Vector3, direction: Vector3): CFrame
	local heading = if direction.Magnitude > EPSILON then direction.Unit else -Vector3.zAxis
	if body.Pointed then
		-- Apex leads: the shape extends from its origin toward its local -Z, so face it AGAINST the
		-- travel and put the origin half a length ahead of the position.
		return lookAlong(position + heading * body.LeadStuds, -heading)
	end
	return lookAlong(position, heading)
end

-- The simplest part type that draws a body, and the Size and the extra turn (about the body's own
-- frame) to give it: the client approximates what Roblox has no primitive for with its bounding box.
-- Returns ("Ball" | "Cylinder" | "Block", size, turn). A Cylinder's axis is X in Roblox, so a body whose
-- axis is the heading carries the quarter turn that lays it along -Z.
function ProjectileBody.Look(body: Body): (string, Vector3, CFrame)
	local shape = body.Shape
	local extents = body.Extents
	if shape == "Sphere" then
		local diameter = body.Dimensions.Radius * 2
		return "Ball", Vector3.new(diameter, diameter, diameter), CFrame.identity
	elseif shape == "Capsule" or shape == "Cylinder" then
		local diameter = body.Dimensions.Radius * 2
		local length = if shape == "Capsule" then body.Dimensions.Length + diameter else body.Dimensions.Length
		return "Cylinder", Vector3.new(length, diameter, diameter), CFrame.Angles(0, math.rad(90), 0)
	elseif shape == "Pillar" then
		local diameter = body.Dimensions.Radius * 2
		-- Standing: the cylinder's X axis turned to Y.
		return "Cylinder", Vector3.new(body.Dimensions.Height, diameter, diameter), CFrame.Angles(0, 0, math.rad(90))
	end
	return "Block", extents, CFrame.identity
end

return ProjectileBody
