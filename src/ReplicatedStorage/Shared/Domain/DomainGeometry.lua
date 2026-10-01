--!strict
--[[
	DomainGeometry.lua

	Owns: the realm's boundary as math -- whether a point is inside, whether two realms overlap, where a
	body on the wrong side of a Barred edge is set back to, and whether a segment crosses the edge. Pure:
	no Instances, no clock, so the server's enforcement, the projectile barrier, the owning client's own
	predicted wall (Client/FX/DomainFX.lua) and the specs all run the identical test.

	A BOUNDARY IS A CENTRE, A YAW AND THREE NUMBERS. Radius is the sphere's radius, the cylinder's radius or
	the box's half-width (DomainTypes' header); Height is the cylinder's and box's full height, centred on
	the centre. The yaw only matters for a Box -- a sphere and an upright cylinder are the same from every
	heading.

	Does not own: where the centre is (DomainSystem resolves it from the owner and the Anchor), what the
	boundary DOES to anyone (DomainSystem), or drawing it (DomainFX).
]]

local DomainGeometry = {}

export type Shape = "Sphere" | "Cylinder" | "Box"

export type Boundary = {
	Shape: Shape,
	Center: Vector3,
	-- Radians about +Y. Only a Box reads it.
	Yaw: number,
	Radius: number,
	Height: number,
}

-- The point in the boundary's own frame (yaw removed, centre at the origin). Only a Box needs the rotation.
local function toLocal(boundary: Boundary, point: Vector3): Vector3
	local offset = point - boundary.Center
	if boundary.Shape ~= "Box" or boundary.Yaw == 0 then
		return offset
	end
	local cos, sin = math.cos(-boundary.Yaw), math.sin(-boundary.Yaw)
	return Vector3.new(offset.X * cos + offset.Z * sin, offset.Y, -offset.X * sin + offset.Z * cos)
end

local function toWorld(boundary: Boundary, localPoint: Vector3): Vector3
	if boundary.Shape ~= "Box" or boundary.Yaw == 0 then
		return boundary.Center + localPoint
	end
	local cos, sin = math.cos(boundary.Yaw), math.sin(boundary.Yaw)
	return boundary.Center
		+ Vector3.new(localPoint.X * cos + localPoint.Z * sin, localPoint.Y, -localPoint.X * sin + localPoint.Z * cos)
end

-- How far inside the boundary a point is, in studs: positive inside, negative outside, 0 on the edge.
-- A signed distance rather than a boolean so the enforcement's tolerance and margin are one comparison
-- each, and so a caller ordering bodies by "how deep in" has a number to sort by.
function DomainGeometry.Depth(boundary: Boundary, point: Vector3): number
	local localPoint = toLocal(boundary, point)
	local halfHeight = boundary.Height / 2
	if boundary.Shape == "Sphere" then
		return boundary.Radius - localPoint.Magnitude
	elseif boundary.Shape == "Cylinder" then
		local radial = boundary.Radius - Vector3.new(localPoint.X, 0, localPoint.Z).Magnitude
		local vertical = halfHeight - math.abs(localPoint.Y)
		return math.min(radial, vertical)
	end
	local x = boundary.Radius - math.abs(localPoint.X)
	local z = boundary.Radius - math.abs(localPoint.Z)
	local y = halfHeight - math.abs(localPoint.Y)
	return math.min(x, y, z)
end

function DomainGeometry.Contains(boundary: Boundary, point: Vector3): boolean
	return DomainGeometry.Depth(boundary, point) >= 0
end

-- The radius of the smallest sphere around the centre that holds the whole boundary. Overlap between two
-- realms is judged on these: a clash is a meeting of two wills, and a corner-to-corner test between two
-- rotated boxes would be precision the design does not ask for.
function DomainGeometry.BoundingRadius(boundary: Boundary): number
	local halfHeight = boundary.Height / 2
	if boundary.Shape == "Sphere" then
		return boundary.Radius
	elseif boundary.Shape == "Cylinder" then
		return math.sqrt(boundary.Radius * boundary.Radius + halfHeight * halfHeight)
	end
	return math.sqrt(2 * boundary.Radius * boundary.Radius + halfHeight * halfHeight)
end

-- The half-angle, in radians, the boundary's bounding sphere subtends seen from `point`: how much of a view
-- the realm can fill, whatever its shape or size. math.pi / 2 from inside the bounding sphere. What the
-- client's shell (Client/FX/DomainFX.lua) picks its look by -- a 120-stud realm fills the screen of a
-- camera well outside it, and "is the camera inside" is the wrong question to ask about frame cost.
function DomainGeometry.AngularRadius(boundary: Boundary, point: Vector3): number
	local reach = DomainGeometry.BoundingRadius(boundary)
	local distance = (point - boundary.Center).Magnitude
	if distance <= reach then
		return math.pi / 2
	end
	return math.asin(reach / distance)
end

-- The same boundary at `scale` of its size about its own centre -- a realm part-way through unfurling.
function DomainGeometry.Scaled(boundary: Boundary, scale: number): Boundary
	return {
		Shape = boundary.Shape,
		Center = boundary.Center,
		Yaw = boundary.Yaw,
		Radius = boundary.Radius * scale,
		Height = boundary.Height * scale,
	}
end

-- Whether two realms' bounding spheres meet.
function DomainGeometry.Overlaps(a: Boundary, b: Boundary): boolean
	local reach = DomainGeometry.BoundingRadius(a) + DomainGeometry.BoundingRadius(b)
	return (a.Center - b.Center).Magnitude < reach
end

-- Where a body at `point` is set to so it sits `margin` studs INSIDE the boundary (for a held member who
-- has stepped out). Moves it along the shortest way back: radially for a sphere, horizontally or
-- vertically for a cylinder (whichever edge it crossed), per axis for a box. A point already that deep is
-- returned unchanged.
function DomainGeometry.ClampInside(boundary: Boundary, point: Vector3, margin: number): Vector3
	if DomainGeometry.Depth(boundary, point) >= margin then
		return point
	end
	local localPoint = toLocal(boundary, point)
	local halfHeight = math.max(boundary.Height / 2 - margin, 0)
	local radius = math.max(boundary.Radius - margin, 0)
	local clamped: Vector3
	if boundary.Shape == "Sphere" then
		local length = localPoint.Magnitude
		clamped = if length > 1e-6 then localPoint * (radius / length) else Vector3.zero
	elseif boundary.Shape == "Cylinder" then
		local flat = Vector3.new(localPoint.X, 0, localPoint.Z)
		local flatLength = flat.Magnitude
		if flatLength > radius and flatLength > 1e-6 then
			flat = flat * (radius / flatLength)
		end
		clamped = Vector3.new(flat.X, math.clamp(localPoint.Y, -halfHeight, halfHeight), flat.Z)
	else
		clamped = Vector3.new(
			math.clamp(localPoint.X, -radius, radius),
			math.clamp(localPoint.Y, -halfHeight, halfHeight),
			math.clamp(localPoint.Z, -radius, radius)
		)
	end
	return toWorld(boundary, clamped)
end

-- Where a body at `point` is set to so it sits `margin` studs OUTSIDE the boundary (for a barred newcomer
-- who has stepped in). Pushed out horizontally from the centre -- a body standing on the ground is never
-- lifted over the realm or driven under the floor -- except when it is directly over or under the centre,
-- where the only way out is sideways along the world's +X.
function DomainGeometry.ClampOutside(boundary: Boundary, point: Vector3, margin: number): Vector3
	if DomainGeometry.Depth(boundary, point) <= -margin then
		return point
	end
	local localPoint = toLocal(boundary, point)
	local flat = Vector3.new(localPoint.X, 0, localPoint.Z)
	local direction = if flat.Magnitude > 1e-6 then flat.Unit else Vector3.xAxis
	local reach: number
	if boundary.Shape == "Box" then
		-- Out along whichever axis the direction leans on hardest, so a body pushed out of a box leaves by
		-- the nearest face rather than a corner.
		local scale = math.max(math.abs(direction.X), math.abs(direction.Z))
		reach = (boundary.Radius + margin) / math.max(scale, 1e-3)
	elseif boundary.Shape == "Sphere" then
		-- The sphere's horizontal extent at this body's own height; beyond the poles, the rim.
		local y = math.abs(localPoint.Y)
		local rim = if y < boundary.Radius then math.sqrt(boundary.Radius * boundary.Radius - y * y) else 0
		reach = rim + margin
	else
		reach = boundary.Radius + margin
	end
	local pushed = Vector3.new(direction.X * reach, localPoint.Y, direction.Z * reach)
	return toWorld(boundary, pushed)
end

-- Whether the segment from `from` to `to` crosses the boundary, and which way: "Leaving", "Entering", or
-- nil for a segment wholly inside or wholly outside. A step is short (a projectile's substep), so its two
-- endpoints decide it; a shot that passes clean through a thin corner inside one substep is accepted as
-- having missed it.
function DomainGeometry.Crossing(boundary: Boundary, from: Vector3, to: Vector3): ("Leaving" | "Entering")?
	local wasInside = DomainGeometry.Contains(boundary, from)
	local isInside = DomainGeometry.Contains(boundary, to)
	if wasInside and not isInside then
		return "Leaving"
	elseif isInside and not wasInside then
		return "Entering"
	end
	return nil
end

return DomainGeometry
