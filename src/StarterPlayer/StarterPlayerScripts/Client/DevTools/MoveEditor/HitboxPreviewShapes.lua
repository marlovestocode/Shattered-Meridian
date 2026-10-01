--!strict
--[[
	HitboxPreviewShapes.lua

	Owns: how each of the engine's seven hitbox shapes is drawn with Roblox parts -- as a list of pieces
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

function HitboxPreviewShapes.Build(shape: MoveTypes.MoveShape, dimensions: Dimensions): { Piece }
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
