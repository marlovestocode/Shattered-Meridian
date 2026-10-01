--!strict
--[[
	PlacementMath.lua

	Owns: the arithmetic of placing a hitbox by hand in the Move Editor's Place mode -- what a Handles
	drag on a face does to a move's offset or dimensions, what an ArcHandles drag does to its rotation,
	snapping, and unwrapping ArcHandles' angle.

	PURE, so every rule here is specced without a Studio playtest: no Instances, no Fusion, no clock. The
	gizmo code in HitboxWorldPreview.lua only reads events and writes the answers into the draft.

	EVERY DRAG IS RELATIVE TO ITS START. Handles and ArcHandles report the distance / angle since the
	mouse went down, so each event recomputes from the offset and dimensions captured then -- never from
	the previous event -- which is what keeps a long drag free of accumulated rounding.

	WHY THE ANGLE NEEDS UNWRAPPING (Phase 0b, 2026-09-29): ArcHandles.MouseDrag's relativeAngle wraps by
	2*pi mid-drag, and reported the same pose on both sides of the wrap on alternating frames. Used raw,
	the volume snaps through a full turn. Unwrap accumulates the smallest step between successive raw
	angles instead, which is continuous whatever the source does.

	Frames: the hitbox's own local space is HitboxTypes' (forward is -Z); `face` and `axis` are in it,
	because the gizmo adorns a part aligned with the hitbox. The move's Offset lives in the ANCHOR's
	space, so a local direction is carried into it by the offset's own rotation.

	Does not own: the limits (Constants.MoveEditor.Limits), composing an Offset from position and degrees
	(MoveTypes.ComposeOffset), or any gizmo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

type Dimensions = MoveTypes.MoveDimensions
type Shape = MoveTypes.MoveShape

local PlacementMath = {}

local TAU = math.pi * 2
local LIMITS = Constants.MoveEditor.Limits

-- The rotation step whenever snapping is on at all. Rotation has its own step because a stud value is
-- meaningless as an angle.
PlacementMath.RotationSnapDegrees = 15

-- The smallest signed step from `previousRaw` to `raw`, in (-pi, pi]. Accumulate these for a
-- continuous drag angle.
function PlacementMath.UnwrapDelta(previousRaw: number, raw: number): number
	local delta = (raw - previousRaw + math.pi) % TAU - math.pi
	return if delta == -math.pi then math.pi else delta
end

function PlacementMath.Snap(value: number, step: number): number
	if step <= 0 then
		return value
	end
	return math.floor(value / step + 0.5) * step
end

local function clampOffset(position: Vector3): Vector3
	local range = LIMITS.OffsetStuds
	return Vector3.new(
		math.clamp(position.X, range.Min, range.Max),
		math.clamp(position.Y, range.Min, range.Max),
		math.clamp(position.Z, range.Min, range.Max)
	)
end

-- A Move-tool drag: the offset's translation moved `distance` studs (snapped) along `face`'s normal, in
-- the hitbox's own frame. `startOffset` is the Offset captured when the drag began.
function PlacementMath.Move(startOffset: CFrame, face: Enum.NormalId, distance: number, snap: number): Vector3
	local direction = startOffset.Rotation:VectorToWorldSpace(Vector3.FromNormalId(face))
	return clampOffset(startOffset.Position + direction * PlacementMath.Snap(distance, snap))
end

-- Which dimension a face's axis sizes for `shape`, and whether a face drag of d changes it by only d/2
-- -- true for the radius of a one-sided resize (Cylinder/Capsule/Beam across), where the drag moves one
-- side of a diameter and the centre follows. A Sphere's or Arc's radius grows around a fixed origin, so
-- the dragged face tracks the radius one-for-one. nil when the axis sizes nothing on this shape (a
-- Cone's width is its angle, not a length).
function PlacementMath.DimensionFor(shape: Shape, face: Enum.NormalId): (string?, boolean)
	local axis = if face == Enum.NormalId.Right or face == Enum.NormalId.Left
		then "X"
		elseif face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then "Y"
		else "Z"
	if shape == "Box" then
		return if axis == "X" then "Width" elseif axis == "Y" then "Height" else "Length", false
	elseif shape == "Sphere" then
		-- Centred on its origin (see Resize): the dragged face tracks the radius itself.
		return "Radius", false
	elseif shape == "Arc" then
		if axis == "Y" then
			return "Height", false
		end
		return "Radius", false
	elseif shape == "Cone" then
		return if axis == "Z" then "Length" else nil, false
	end
	-- Cylinder, Capsule, Beam: round across, long along Z.
	if axis == "Z" then
		return "Length", false
	end
	return "Radius", true
end

-- Whether `shape` grows forward FROM its origin along Z rather than around it (HitboxGeometry's reach
-- shapes). Its Front face moves the tip; its Back face moves the origin.
local function isReach(shape: Shape): boolean
	return shape == "Cone" or shape == "Beam"
end

-- A Resize-tool drag, one-sided like Studio's: the dragged face moves `distance` studs (snapped) along
-- its outward normal and the opposite face stays put -- so the dimension grows and the centre shifts
-- half of it toward the dragged face (or, for a reach shape's Back face, the origin moves the whole
-- way). Returns the new dimensions and the new offset translation; unchanged dimensions for a face that
-- sizes nothing. The actual change after clamping decides the shift, so a clamped drag does not slide.
function PlacementMath.Resize(
	shape: Shape,
	startDimensions: Dimensions,
	startOffset: CFrame,
	face: Enum.NormalId,
	distance: number,
	snap: number
): (Dimensions, Vector3)
	local dimensions = table.clone(startDimensions)
	local field, isRadius = PlacementMath.DimensionFor(shape, face)
	if field == nil then
		return dimensions, startOffset.Position
	end
	local range = (LIMITS.Dimensions :: any)[field] :: { Min: number, Max: number }
	local before = (startDimensions :: any)[field] :: number
	local grow = PlacementMath.Snap(distance, snap)
	local after = math.clamp(before + (if isRadius then grow / 2 else grow), range.Min, range.Max);
	(dimensions :: any)[field] = after

	-- The extent actually gained along the drag axis, after the clamp.
	local gained = if isRadius then (after - before) * 2 else after - before
	local normal = Vector3.FromNormalId(face)
	local shift: number
	if shape == "Arc" and field == "Radius" or shape == "Sphere" then
		-- Centred on the origin by definition: a ring or ball grows around it.
		shift = 0
	elseif isReach(shape) and field == "Length" then
		shift = if face == Enum.NormalId.Back then gained else 0
	else
		shift = gained / 2
	end
	local position = startOffset.Position + startOffset.Rotation:VectorToWorldSpace(normal) * shift
	return dimensions, clampOffset(position)
end

-- A Rotate-tool drag: the start rotation turned by `angle` radians about the hitbox-local `axis`, read
-- back as (pitch, yaw, roll) degrees in MoveTypes.ComposeOffset's YXZ order. Snaps to
-- RotationSnapDegrees when `snapOn`.
function PlacementMath.Rotate(startRotationDegrees: Vector3, axis: Enum.Axis, angle: number, snapOn: boolean): Vector3
	local step = if snapOn then math.rad(PlacementMath.RotationSnapDegrees) else 0
	local turned = MoveTypes.ComposeOffset(Vector3.zero, startRotationDegrees)
		* CFrame.fromAxisAngle(Vector3.FromAxis(axis), PlacementMath.Snap(angle, step))
	local pitch, yaw, roll = turned:ToEulerAnglesYXZ()
	local range = LIMITS.RotationDegrees
	local function degrees(radians: number): number
		-- Rounded to a thousandth so a snapped 45 reads back as 45, not 44.99999999.
		return math.clamp(math.floor(math.deg(radians) * 1000 + 0.5) / 1000, range.Min, range.Max)
	end
	return Vector3.new(degrees(pitch), degrees(yaw), degrees(roll))
end

return PlacementMath
