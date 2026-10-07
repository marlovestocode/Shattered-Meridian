--!strict
--[[
	HitboxPreviewShapes.lua

	Owns: how each of the engine's fifteen hitbox shapes is drawn with Roblox parts -- as a list of pieces
	(a part type, a size and a CFrame in the hitbox's own local space) that HitboxWorldPreview.lua turns
	into Instances and places every frame.

	PURE DATA, NO INSTANCES, so the part counts and sizes are specced headless. The volumes follow
	Shared/HitboxEngine/HitboxGeometry.ContainsPoint exactly where a primitive can, and approximate only
	where Roblox has no primitive for the shape:

	  Box       one Block, W x H x L, centred.
	  Sphere    one Ball, diameter 2R.
	  Cylinder  one Cylinder along Z (Roblox cylinders lie along X, so it is turned 90 degrees about Y),
	            length L, diameter 2R, centred.
	  Capsule   that cylinder plus a Ball at each end.
	  Beam      the cylinder, pushed forward L/2 -- it grows FROM the origin, not around it.
	  Cone      CONE_SLICES stacked cylinders from the apex forward, each as wide as the cone at its own
	            midpoint (the engine clamps the angle to 1..179, and so does this).
	  Arc       ARC_SEGMENTS blocks fanned across the sector, inner to outer radius, height H; a full
	            circle at 360.
	  Ellipsoid SLICES blocks stacked along Z, each as wide and tall as the ellipsoid is at its middle (Roblox
	            has no part that is round in one plane and stretched in another).
	  Hemisphere SLICES cylinders from the flat face forward, each as wide as the dome is at its middle.
	  Frustum   SLICES cylinders from the origin forward, widening (or narrowing) linearly.
	  Pyramid   SLICES blocks from the apex forward, growing in width AND height.
	  Wedge     SLICES blocks from the apex edge forward, growing in width only.
	  Crescent  ARC_SEGMENTS * 2 bearings round the outer disc; along each, the stretch of the ray that is
	            inside the disc and outside the bite is a block (one or two per bearing).
	  Cross     two blocks through the origin.
	  Pillar    one cylinder standing on its end.

	Local frame is HitboxTypes': forward is -Z, up is +Y.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

type Dimensions = MoveTypes.MoveDimensions

export type Piece = {
	PartType: Enum.PartType,
	Size: Vector3,
	-- Relative to the hitbox's origin.
	Local: CFrame,
}

local HitboxPreviewShapes = {}

HitboxPreviewShapes.ConeSlices = 8
HitboxPreviewShapes.ArcSegments = 16
-- Slices through the shapes that have no part of their own (Ellipsoid, Hemisphere, Frustum, Pyramid, Wedge).
HitboxPreviewShapes.Slices = 8

-- A part may not be thinner than this; a zero-radius slice at a cone's apex would otherwise be invisible
-- and a zero-size part is clamped by the engine anyway.
local MIN_THICKNESS = 0.05

-- Turns a Roblox cylinder (axis X) to lie along Z.
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0)

local function cylinder(length: number, radius: number, centreZ: number): Piece
	local diameter = math.max(radius * 2, MIN_THICKNESS)
	return {
		PartType = Enum.PartType.Cylinder,
		Size = Vector3.new(math.max(length, MIN_THICKNESS), diameter, diameter),
		Local = CFrame.new(0, 0, centreZ) * ALONG_Z,
	}
end

local function ball(radius: number, centreZ: number): Piece
	local diameter = math.max(radius * 2, MIN_THICKNESS)
	return {
		PartType = Enum.PartType.Ball,
		Size = Vector3.new(diameter, diameter, diameter),
		Local = CFrame.new(0, 0, centreZ),
	}
end

local function block(width: number, height: number, length: number, centre: CFrame): Piece
	return {
		PartType = Enum.PartType.Block,
		Size = Vector3.new(
			math.max(width, MIN_THICKNESS),
			math.max(height, MIN_THICKNESS),
			math.max(length, MIN_THICKNESS)
		),
		Local = centre,
	}
end

-- A crescent's blocks: for each bearing round the outer disc, the parts of the ray from the origin that are
-- inside the disc (Radius) and outside the bite (a disc of InnerRadius centred Length behind the origin).
local function crescentPieces(dimensions: Dimensions): { Piece }
	local pieces: { Piece } = {}
	local segments = HitboxPreviewShapes.ArcSegments * 2
	local step = math.rad(360 / segments)
	local radius, bite, behind = dimensions.Radius, dimensions.InnerRadius, dimensions.Length
	for index = 0, segments - 1 do
		local bearing = (index + 0.5) * step
		-- The ray's unit vector is (sin b, 0, -cos b); the bite's centre is (0, 0, behind).
		local along = -math.cos(bearing) * behind
		local discriminant = along * along - (behind * behind - bite * bite)
		local spans: { { number } } = { { 0, radius } }
		if bite > 0 and discriminant >= 0 then
			local root = math.sqrt(discriminant)
			local near, far = along - root, along + root
			spans = {}
			if near > 0 then
				table.insert(spans, { 0, math.min(near, radius) })
			end
			if far < radius then
				table.insert(spans, { math.max(far, 0), radius })
			end
		end
		for _, span in spans do
			local from, to = span[1], span[2]
			if to - from > MIN_THICKNESS then
				local middle = (from + to) / 2
				local width = math.max(2 * math.max(middle, MIN_THICKNESS) * math.tan(step / 2), MIN_THICKNESS)
				local position = Vector3.new(math.sin(bearing) * middle, 0, -math.cos(bearing) * middle)
				table.insert(
					pieces,
					block(width, dimensions.Height, to - from, CFrame.new(position) * CFrame.Angles(0, -bearing, 0))
				)
			end
		end
	end
	return pieces
end

function HitboxPreviewShapes.Build(shape: MoveTypes.MoveShape, dimensions: Dimensions): { Piece }
	if shape == "Ellipsoid" then
		local pieces: { Piece } = {}
		local slices = HitboxPreviewShapes.Slices
		local sliceLength = dimensions.Length / slices
		for index = 0, slices - 1 do
			-- Position along Z as a fraction of the half-length, -1 to 1; the section there is a scaled
			-- ellipse, and the block takes its full extent at the slice's middle.
			local t = ((index + 0.5) / slices) * 2 - 1
			local scale = math.sqrt(math.max(1 - t * t, 0))
			table.insert(
				pieces,
				block(
					dimensions.Width * scale,
					dimensions.Height * scale,
					sliceLength,
					CFrame.new(0, 0, t * dimensions.Length / 2)
				)
			)
		end
		return pieces
	elseif shape == "Hemisphere" then
		local pieces: { Piece } = {}
		local slices = HitboxPreviewShapes.Slices
		local sliceLength = dimensions.Radius / slices
		for index = 0, slices - 1 do
			local forward = (index + 0.5) * sliceLength
			local across = math.sqrt(math.max(dimensions.Radius * dimensions.Radius - forward * forward, 0))
			table.insert(pieces, cylinder(sliceLength, across, -forward))
		end
		return pieces
	elseif shape == "Frustum" then
		local pieces: { Piece } = {}
		local slices = HitboxPreviewShapes.Slices
		local sliceLength = dimensions.Length / slices
		for index = 0, slices - 1 do
			local along = (index + 0.5) / slices
			local radius = dimensions.InnerRadius + (dimensions.Radius - dimensions.InnerRadius) * along
			table.insert(pieces, cylinder(sliceLength, radius, -(index + 0.5) * sliceLength))
		end
		return pieces
	elseif shape == "Pyramid" or shape == "Wedge" then
		local pieces: { Piece } = {}
		local slices = HitboxPreviewShapes.Slices
		local sliceLength = dimensions.Length / slices
		for index = 0, slices - 1 do
			local along = (index + 0.5) / slices
			local height = if shape == "Pyramid" then dimensions.Height * along else dimensions.Height
			table.insert(
				pieces,
				block(dimensions.Width * along, height, sliceLength, CFrame.new(0, 0, -(index + 0.5) * sliceLength))
			)
		end
		return pieces
	elseif shape == "Crescent" then
		return crescentPieces(dimensions)
	elseif shape == "Cross" then
		local bar = dimensions.Radius * 2
		return {
			block(dimensions.Width, dimensions.Height, bar, CFrame.identity),
			block(bar, dimensions.Height, dimensions.Length, CFrame.identity),
		}
	elseif shape == "Pillar" then
		local diameter = math.max(dimensions.Radius * 2, MIN_THICKNESS)
		return {
			{
				PartType = Enum.PartType.Cylinder,
				Size = Vector3.new(math.max(dimensions.Height, MIN_THICKNESS), diameter, diameter),
				-- Standing: a cylinder's axis is X, turned up to Y.
				Local = CFrame.Angles(0, 0, math.rad(90)),
			},
		}
	end
	if shape == "Sphere" then
		return { ball(dimensions.Radius, 0) }
	elseif shape == "Cylinder" then
		return { cylinder(dimensions.Length, dimensions.Radius, 0) }
	elseif shape == "Capsule" then
		local half = dimensions.Length / 2
		return {
			cylinder(dimensions.Length, dimensions.Radius, 0),
			ball(dimensions.Radius, -half),
			ball(dimensions.Radius, half),
		}
	elseif shape == "Beam" then
		return { cylinder(dimensions.Length, dimensions.Radius, -dimensions.Length / 2) }
	elseif shape == "Cone" then
		local pieces: { Piece } = {}
		local slices = HitboxPreviewShapes.ConeSlices
		local sliceLength = dimensions.Length / slices
		local tangent = math.tan(math.rad(math.clamp(dimensions.AngleDegrees, 1, 179) / 2))
		for index = 0, slices - 1 do
			local forward = (index + 0.5) * sliceLength
			table.insert(pieces, cylinder(sliceLength, tangent * forward, -forward))
		end
		return pieces
	elseif shape == "Arc" then
		local pieces: { Piece } = {}
		local segments = HitboxPreviewShapes.ArcSegments
		local sweep = math.clamp(dimensions.AngleDegrees, 1, 360)
		local step = math.rad(sweep / segments)
		local inner = math.clamp(dimensions.InnerRadius, 0, dimensions.Radius)
		local depth = math.max(dimensions.Radius - inner, MIN_THICKNESS)
		local middle = (inner + dimensions.Radius) / 2
		-- The chord each segment spans at the rim, so neighbours meet there without a gap.
		local width = math.max(2 * dimensions.Radius * math.tan(step / 2), MIN_THICKNESS)
		for index = 0, segments - 1 do
			-- Bearing from straight ahead, positive toward +X -- HitboxGeometry's atan2(x, -z).
			local bearing = math.rad(-sweep / 2) + (index + 0.5) * step
			local position = Vector3.new(math.sin(bearing) * middle, 0, -math.cos(bearing) * middle)
			table.insert(pieces, {
				PartType = Enum.PartType.Block,
				Size = Vector3.new(width, math.max(dimensions.Height, MIN_THICKNESS), depth),
				-- Turning by -bearing points the block's -Z along the radial.
				Local = CFrame.new(position) * CFrame.Angles(0, -bearing, 0),
			})
		end
		return pieces
	end
	return {
		{
			PartType = Enum.PartType.Block,
			Size = Vector3.new(
				math.max(dimensions.Width, MIN_THICKNESS),
				math.max(dimensions.Height, MIN_THICKNESS),
				math.max(dimensions.Length, MIN_THICKNESS)
			),
			Local = CFrame.identity,
		},
	}
end

-- A cheap key that changes exactly when Build's output would -- the preview rebuilds its parts only then.
function HitboxPreviewShapes.Signature(shape: MoveTypes.MoveShape, dimensions: Dimensions): string
	return string.format(
		"%s|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f",
		shape,
		dimensions.Width,
		dimensions.Height,
		dimensions.Length,
		dimensions.Radius,
		dimensions.InnerRadius,
		dimensions.AngleDegrees
	)
end

return HitboxPreviewShapes
