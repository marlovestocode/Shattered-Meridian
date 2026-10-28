--!strict
--[[
	ArchitectTransform.lua

	Owns: the World Architect's transform maths, pure -- snapping, the bounds and pivot of a set of records, moving /
	rotating / scaling a set about a pivot, resizing one part along a face, align, distribute, mirror, array, and where a
	part lands on a surface it was dropped on.

	EVERY OPERATION ON A SET TAKES THE WHOLE SET, descendants included. A group's own record is its pivot; moving the
	group means moving every part under it by the same rigid transform, and the caller (the editor) is the one who knows
	which records are under which group. Results are new records (or patches), never mutations of the inputs.

	A RIGID TRANSFORM PRESERVES PIVOTS. TransformSet maps every record's CFrame through `to * from:Inverse()`, so a
	group's pivot moves with its parts and the relative layout of the set is exact, not re-snapped per part.

	Mirror reflects position and conjugates the rotation (M R M, a proper rotation again). For the symmetric primitives
	(Block, Cylinder, Ball) that is exactly the reflected geometry; a wedge keeps its own handedness (there is no mirrored
	wedge part), which the architecture doc states.

	No Instances, no clock: Tests/WorldArchitect/ArchitectTransform.spec.lua drives all of it.
]]

local ArchitectRecord = require(script.Parent.ArchitectRecord)

type NodeRecord = ArchitectRecord.NodeRecord

local ArchitectTransform = {}

export type Axis = "X" | "Y" | "Z"
export type Space = "World" | "Local"

local AXIS_VECTOR: { [Axis]: Vector3 } = {
	X = Vector3.xAxis,
	Y = Vector3.yAxis,
	Z = Vector3.zAxis,
}

function ArchitectTransform.Snap(value: number, step: number): number
	if step <= 0 then
		return value
	end
	return math.round(value / step) * step
end

function ArchitectTransform.SnapVector(v: Vector3, step: number): Vector3
	local snap = ArchitectTransform.Snap
	return Vector3.new(snap(v.X, step), snap(v.Y, step), snap(v.Z, step))
end

function ArchitectTransform.Component(v: Vector3, axis: Axis): number
	return if axis == "X" then v.X elseif axis == "Y" then v.Y else v.Z
end

local function withComponent(v: Vector3, axis: Axis, value: number): Vector3
	if axis == "X" then
		return Vector3.new(value, v.Y, v.Z)
	elseif axis == "Y" then
		return Vector3.new(v.X, value, v.Z)
	end
	return Vector3.new(v.X, v.Y, value)
end

-- Half the extent of an oriented box along a world direction.
function ArchitectTransform.HalfExtentAlong(cframe: CFrame, size: Vector3, direction: Vector3): number
	local d = direction.Unit
	return (
		math.abs(cframe.RightVector:Dot(d)) * size.X
		+ math.abs(cframe.UpVector:Dot(d)) * size.Y
		+ math.abs(cframe.LookVector:Dot(d)) * size.Z
	) / 2
end

-- World-axis bounding box of one oriented box.
function ArchitectTransform.BoxBounds(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local half = Vector3.new(
		ArchitectTransform.HalfExtentAlong(cframe, size, Vector3.xAxis),
		ArchitectTransform.HalfExtentAlong(cframe, size, Vector3.yAxis),
		ArchitectTransform.HalfExtentAlong(cframe, size, Vector3.zAxis)
	)
	return cframe.Position - half, cframe.Position + half
end

-- World-axis bounding box of the Part records in `records` (Groups have no extent of their own). Nil for no parts.
function ArchitectTransform.Bounds(records: { NodeRecord }): (Vector3?, Vector3?)
	local low: Vector3? = nil
	local high: Vector3? = nil
	for _, record in records do
		if record.Kind == "Part" then
			local a, b = ArchitectTransform.BoxBounds(ArchitectRecord.CFrameOf(record), record.Size)
			low = if low then low:Min(a) else a
			high = if high then high:Max(b) else b
		end
	end
	if low == nil then
		-- A set of empty groups: bound their pivots.
		for _, record in records do
			low = if low then low:Min(record.Position) else record.Position
			high = if high then high:Max(record.Position) else record.Position
		end
	end
	return low, high
end

-- The pivot a set is moved, rotated and placed about: the centre of its bounds' floor.
function ArchitectTransform.PivotOf(records: { NodeRecord }): Vector3
	local low, high = ArchitectTransform.Bounds(records)
	if low == nil or high == nil then
		return Vector3.zero
	end
	local center = (low + high) / 2
	return Vector3.new(center.X, low.Y, center.Z)
end

-- Every record mapped through the rigid transform that takes `from` to `to`.
function ArchitectTransform.TransformSet(records: { NodeRecord }, from: CFrame, to: CFrame): { NodeRecord }
	local delta = to * from:Inverse()
	local out: { NodeRecord } = {}
	for _, record in records do
		table.insert(out, ArchitectRecord.WithCFrame(record, delta * ArchitectRecord.CFrameOf(record)))
	end
	return out
end

function ArchitectTransform.Translate(records: { NodeRecord }, offset: Vector3): { NodeRecord }
	return ArchitectTransform.TransformSet(records, CFrame.identity, CFrame.new(offset))
end

-- The world direction of `axis` in `space`: the world axis, or that axis of `reference`'s own frame.
function ArchitectTransform.AxisVector(axis: Axis, space: Space, reference: CFrame?): Vector3
	local world = AXIS_VECTOR[axis]
	if space == "Local" and reference then
		return reference:VectorToWorldSpace(world)
	end
	return world
end

-- Rotates the set `degrees` about `axisVector` through `pivot`.
function ArchitectTransform.RotateAbout(
	records: { NodeRecord },
	pivot: Vector3,
	axisVector: Vector3,
	degrees: number
): { NodeRecord }
	local from = CFrame.new(pivot)
	local to = CFrame.new(pivot) * CFrame.fromAxisAngle(axisVector.Unit, math.rad(degrees))
	return ArchitectTransform.TransformSet(records, from, to)
end

-- Uniform scale of a set about a pivot: offsets and part sizes both scale, so the composition keeps its shape.
function ArchitectTransform.ScaleSet(records: { NodeRecord }, pivot: Vector3, factor: number): { NodeRecord }
	local out: { NodeRecord } = {}
	for _, record in records do
		local copy = ArchitectRecord.Clone(record)
		copy.Position = pivot + (record.Position - pivot) * factor
		if record.Kind == "Part" then
			copy.Size = record.Size * factor
		end
		table.insert(out, copy)
	end
	return out
end

-- A set stretched along one WORLD axis by `factor`, the plane at `anchor` (that axis's coordinate) staying put -- what
-- dragging one face of a group's box means: a wall run gets longer, not taller. Positions spread from the anchor along
-- the axis only. Each part grows along its own local axes in proportion to how well each lines up with the stretch
-- (squared alignment), so an axis-aligned part stretches exactly and a diagonal piece (a lattice bar, a roof rib)
-- follows proportionally; orientations never change.
function ArchitectTransform.StretchSet(
	records: { NodeRecord },
	axis: Axis,
	anchor: number,
	factor: number,
	minSize: number
): { NodeRecord }
	local direction = AXIS_VECTOR[axis]
	local out: { NodeRecord } = {}
	for _, record in records do
		local copy = ArchitectRecord.Clone(record)
		local p = record.Position
		copy.Position = withComponent(p, axis, anchor + (ArchitectTransform.Component(p, axis) - anchor) * factor)
		if record.Kind == "Part" then
			local frame = ArchitectRecord.CFrameOf(record)
			local function grow(size: number, localAxis: Vector3): number
				local alignment = localAxis:Dot(direction)
				return math.max(size * (1 + (factor - 1) * alignment * alignment), minSize)
			end
			local s = record.Size
			copy.Size =
				Vector3.new(grow(s.X, frame.RightVector), grow(s.Y, frame.UpVector), grow(s.Z, frame.LookVector))
		end
		table.insert(out, copy)
	end
	return out
end

-- One part grown (or shrunk) by `delta` studs along one face, the opposite face staying put -- what a Resize handle
-- drag means. `face` is the local axis and its sign.
function ArchitectTransform.ResizeFace(
	record: NodeRecord,
	axis: Axis,
	sign: number,
	delta: number,
	minSize: number
): NodeRecord
	local current = ArchitectTransform.Component(record.Size, axis)
	local target = math.max(current + delta, minSize)
	local applied = target - current
	local copy = ArchitectRecord.Clone(record)
	copy.Size = withComponent(record.Size, axis, target)
	local cframe = ArchitectRecord.CFrameOf(record)
	local shift = cframe:VectorToWorldSpace(AXIS_VECTOR[axis] * (sign * applied / 2))
	copy.Position = record.Position + shift
	return copy
end

-- Aligns each TOP-LEVEL item (a record id, with every record that moves with it) so its own bounds' min / centre / max
-- on `axis` matches the whole selection's. `items` maps an item id to the records that move with it.
function ArchitectTransform.Align(items: { { NodeRecord } }, axis: Axis, mode: "Min" | "Center" | "Max"): { NodeRecord }
	local all: { NodeRecord } = {}
	for _, item in items do
		for _, record in item do
			table.insert(all, record)
		end
	end
	local low, high = ArchitectTransform.Bounds(all)
	if low == nil or high == nil then
		return {}
	end
	local function anchor(a: Vector3, b: Vector3): number
		if mode == "Min" then
			return ArchitectTransform.Component(a, axis)
		elseif mode == "Max" then
			return ArchitectTransform.Component(b, axis)
		end
		return (ArchitectTransform.Component(a, axis) + ArchitectTransform.Component(b, axis)) / 2
	end
	local target = anchor(low, high)
	local out: { NodeRecord } = {}
	for _, item in items do
		local a, b = ArchitectTransform.Bounds(item)
		if a and b then
			local shift = withComponent(Vector3.zero, axis, target - anchor(a, b))
			for _, record in ArchitectTransform.Translate(item, shift) do
				table.insert(out, record)
			end
		end
	end
	return out
end

-- Spreads the items' centres evenly between the first and the last along `axis`. Needs three or more items.
function ArchitectTransform.Distribute(items: { { NodeRecord } }, axis: Axis): { NodeRecord }
	if #items < 3 then
		return {}
	end
	local entries: { { Center: number, Item: { NodeRecord } } } = {}
	for _, item in items do
		local a, b = ArchitectTransform.Bounds(item)
		if a and b then
			table.insert(entries, { Center = ArchitectTransform.Component((a + b) / 2, axis), Item = item })
		end
	end
	table.sort(entries, function(p, q)
		return p.Center < q.Center
	end)
	local first = entries[1].Center
	local last = entries[#entries].Center
	local stepSize = (last - first) / (#entries - 1)
	local out: { NodeRecord } = {}
	for index, entry in entries do
		local target = first + stepSize * (index - 1)
		local shift = withComponent(Vector3.zero, axis, target - entry.Center)
		for _, record in ArchitectTransform.Translate(entry.Item, shift) do
			table.insert(out, record)
		end
	end
	return out
end

-- `record` reflected through the plane through `planePoint` whose normal is `axis`.
function ArchitectTransform.Mirror(record: NodeRecord, planePoint: Vector3, axis: Axis): NodeRecord
	local sx = if axis == "X" then -1 else 1
	local sy = if axis == "Y" then -1 else 1
	local sz = if axis == "Z" then -1 else 1
	local p = record.Position - planePoint
	local position = planePoint + Vector3.new(p.X * sx, p.Y * sy, p.Z * sz)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = ArchitectRecord.CFrameOf(record):GetComponents()
	-- M R M with M = diag(sx, sy, sz): entry (i, j) is multiplied by s_i * s_j.
	local mirrored = CFrame.new(
		position.X,
		position.Y,
		position.Z,
		r00,
		r01 * sx * sy,
		r02 * sx * sz,
		r10 * sy * sx,
		r11,
		r12 * sy * sz,
		r20 * sz * sx,
		r21 * sz * sy,
		r22
	)
	return ArchitectRecord.WithCFrame(record, mirrored)
end

-- The offsets of an array of `count` copies (the original excluded), each `offset` further than the last.
function ArchitectTransform.ArrayOffsets(count: number, offset: Vector3): { Vector3 }
	local out: { Vector3 } = {}
	for index = 1, math.max(math.floor(count), 0) do
		table.insert(out, offset * index)
	end
	return out
end

-- Where a part of `size` lands when dropped on a surface at `hit` facing `normal`: upright (turned `yawDegrees`) on a
-- floor, back against a wall otherwise, resting on the surface rather than half inside it. `grid` snaps the two
-- tangential coordinates only -- the coordinate along the normal stays exactly on the surface.
function ArchitectTransform.SurfacePlacement(
	hit: Vector3,
	normal: Vector3,
	size: Vector3,
	yawDegrees: number,
	grid: number
): CFrame
	local n = if normal.Magnitude > 1e-6 then normal.Unit else Vector3.yAxis
	local rotation: CFrame
	if math.abs(n.Y) > 0.7 then
		rotation = CFrame.fromOrientation(0, math.rad(yawDegrees), 0)
		if n.Y < 0 then
			rotation = CFrame.fromOrientation(math.rad(180), math.rad(yawDegrees), 0)
		end
	else
		-- Face away from the wall: the part's front (-Z) points along the normal, upright.
		local flat = Vector3.new(n.X, 0, n.Z).Unit
		rotation = CFrame.lookAt(Vector3.zero, flat) * CFrame.fromOrientation(0, 0, math.rad(yawDegrees))
	end
	local lift = ArchitectTransform.HalfExtentAlong(rotation, size, n)
	local position = hit + n * lift
	if grid > 0 then
		local snapped = ArchitectTransform.SnapVector(position, grid)
		-- Keep the normal component exact.
		position = snapped - n * (snapped - position):Dot(n)
	end
	return CFrame.new(position) * rotation
end

return ArchitectTransform
