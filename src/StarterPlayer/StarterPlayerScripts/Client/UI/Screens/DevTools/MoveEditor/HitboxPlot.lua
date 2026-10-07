--!strict
--[[
	MoveEditor/HitboxPlot.lua

	Owns: one orthographic view of a move's hitbox beside the attacker's body -- TOP (looking down, the
	attacker facing up the plot) or SIDE (looking from the attacker's right, facing right) -- drawn by
	asking the ENGINE'S OWN containment test, not by drawing a shape.

	WHY A RASTER OF ContainsPoint, NOT A PICTURE OF THE SHAPE. The old editor rendered a 3D gizmo of
	what it believed each shape looked like, in 750 lines, and five of its twelve shapes did not exist in
	the engine at all -- the picture was of a volume that never swung. Here every lit cell is a point for
	which Shared/HitboxEngine/HitboxGeometry.ContainsPoint -- the function the server runs on every
	contact -- answers true. A Cone's taper, an Arc's inner radius and sector, a Capsule's end caps and
	any rotation are therefore drawn exactly as they will hit, by construction, with no per-shape drawing
	code to drift from the math.

	A cell is lit when ANY of a handful of samples through the view's depth is inside, so a thin volume
	that does not cross the plot's own plane still shows. The view auto-fits to the volume (never smaller
	than the body), and says its half-width in studs so two moves' plots are comparable.

	The volume is placed relative to the ROOT. A move anchored to a hand or the weapon rides on that part
	instead, which moves with the animation -- the readout's notes say so; this view cannot know where the
	part will be mid-swing.

	A PROJECTILE MOVE IS DRAWN AS ITS VOLLEY: every shot's path for its first PROJECTILE_REACH studs, laid
	along the points Shared/HitboxEngine/ProjectileMotion flies (Volley for the spread, Path for gravity and
	acceleration). A sphere is a run of Capsules of the shot's radius -- the swept volume the server tests a
	step against. Any other Shape is the BODY itself (Shared/HitboxEngine/ProjectileBody) stood at points
	along the path, close enough to overlap, so a slab reads as a slab and a crescent as a crescent. So a
	5-shot 30-degree fan shows five evenly spaced lanes because the server fires five evenly spaced lanes.
	Drawn as fired "Facing" from the root with no homing: an anchor-aimed or target-aimed volley, and a
	homing shot's turn, depend on a pose and a target this view does not have.

	Cells are built once and only recoloured when their state CHANGES: a few hundred Frames toggling a
	transparency is cheap, a few hundred being rebuilt -- or even re-written with the value they already
	hold -- on every keystroke is not. Each volume visits only the cells its own box covers, so a wide
	volley costs what it covers rather than volumes x cells.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileBody = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileBody)
local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type HitboxPlotProps = {
	View: "Top" | "Side",
	-- The plot's square edge, in pixels.
	Size: number,
	Draft: UsedAs<MoveTypes.MoveDefinition?>,
	LayoutOrder: number?,
}

-- Cells per axis. 26 keeps a cell at ~6px in the readout's plots -- fine enough to show an Arc's hub,
-- coarse enough that a whole redraw is a few thousand arithmetic tests.
local GRID = 26
-- Samples through the view's depth per cell.
local DEPTH_SAMPLES = 7
-- The smallest half-width a view shrinks to, so a tiny hitbox is not magnified into looking huge.
local MIN_HALF_EXTENT = 4
local CAPTION_HEIGHT = 16

-- An R6 body relative to the HumanoidRootPart: two studs wide, one deep; feet three below the root,
-- head top two and a half above.
local BODY_HALF_WIDTH = 1
local BODY_HALF_DEPTH = 0.5
local BODY_BOTTOM = -3
local BODY_TOP = 2.5

-- How much of a projectile's flight the plot draws, in studs -- enough to read a spread, short enough
-- that the body stays visible beside it.
local PROJECTILE_REACH = 24
-- Pieces per shot path when something bends it (gravity, acceleration); a straight shot is one.
local CURVED_PATH_SEGMENTS = 4
-- Past this many volumes a cell takes fewer depth samples, so a wide volley still redraws at drag speed.
local MANY_VOLUMES = 24
local FEW_DEPTH_SAMPLES = 3
-- A shaped body is stood along its path at most this many times, and no closer than the stride that makes
-- neighbours just overlap (its own length, but never under MIN_BODY_STRIDE studs).
local MAX_BODY_STANDS = 12
local MIN_BODY_STRIDE = 2

-- One volume to rasterise: a shape at a root-space pose, plus that pose's inverse and the root-space
-- box around it (a cell outside the box skips the exact test).
type Volume = {
	Shape: MoveTypes.MoveShape,
	Dimensions: MoveTypes.MoveDimensions,
	Inverse: CFrame,
	Min: Vector3,
	Max: Vector3,
}

local function newVolume(shape: MoveTypes.MoveShape, dimensions: MoveTypes.MoveDimensions, pose: CFrame): Volume
	local size, centre = HitboxGeometry.BoundingBox(shape, dimensions)
	local frame = pose * centre
	local half = size / 2
	local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = frame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
				low, high = low:Min(corner), high:Max(corner)
			end
		end
	end
	return { Shape = shape, Dimensions = dimensions, Inverse = pose:Inverse(), Min = low, Max = high }
end

-- A projectile's volley as Capsules along each shot's path (see this file's header).
local function volleyVolumes(move: MoveTypes.MoveDefinition, spec: MoveTypes.MoveProjectileConfig): { Volume }
	local volumes: { Volume } = {}
	local aim = CFrame.new(move.Offset.Position) * move.Offset.Rotation
	local curved = spec.Gravity ~= 0 or spec.Acceleration ~= 0
	local segments = if curved then CURVED_PATH_SEGMENTS else 1
	local body = ProjectileBody.Of(spec)
	if not body.IsSphere then
		-- The body itself, stood along each path. A stand every body-length overlaps its neighbour; the
		-- path's own bend is honoured by sampling it at least as finely as it curves.
		local stride = math.max(body.Extents.Z, MIN_BODY_STRIDE)
		segments = math.clamp(math.ceil(PROJECTILE_REACH / stride), segments, MAX_BODY_STANDS)
		for _, shot in ProjectileMotion.Volley(spec, aim) do
			local points = ProjectileMotion.Path(spec, shot, PROJECTILE_REACH, segments)
			for index, point in points do
				local before, after = points[math.max(index - 1, 1)], points[math.min(index + 1, #points)]
				local heading = after - before
				if heading.Magnitude < 1e-4 then
					heading = shot.Direction
				end
				table.insert(
					volumes,
					newVolume(body.Shape, body.Dimensions, ProjectileBody.PoseAt(body, point, heading))
				)
			end
		end
		return volumes
	end
	for _, shot in ProjectileMotion.Volley(spec, aim) do
		local points = ProjectileMotion.Path(spec, shot, PROJECTILE_REACH, segments)
		for index = 1, #points - 1 do
			local a, b = points[index], points[index + 1]
			local delta = b - a
			local length = delta.Magnitude
			local dimensions = HitboxTypes.DefaultDimensions()
			dimensions.Radius = spec.Size
			dimensions.Length = length
			local pose = if length > 1e-4
				then CFrame.lookAt(
					(a + b) / 2,
					b,
					if math.abs(delta.Unit.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
				)
				else CFrame.new(a)
			table.insert(volumes, newVolume("Capsule", dimensions, pose))
		end
		if #points == 1 then
			local dimensions = HitboxTypes.DefaultDimensions()
			dimensions.Radius = spec.Size
			table.insert(volumes, newVolume("Sphere", dimensions, CFrame.new(points[1])))
		end
	end
	return volumes
end

-- Everything the plot draws for a move, in root space.
local function volumesOf(move: MoveTypes.MoveDefinition): { Volume }
	local spec = move.Projectile
	if spec then
		return volleyVolumes(move, spec)
	end
	return { newVolume(move.Shape, move.Dimensions, move.Offset) }
end

-- The volumes' corners in root space, from the engine's own broadphase boxes.
local function worldCorners(volumes: { Volume }): { Vector3 }
	local corners: { Vector3 } = {}
	for _, volume in volumes do
		table.insert(corners, volume.Min)
		table.insert(corners, volume.Max)
	end
	return corners
end

local function insideBox(volume: Volume, point: Vector3): boolean
	return point.X >= volume.Min.X
		and point.X <= volume.Max.X
		and point.Y >= volume.Min.Y
		and point.Y <= volume.Max.Y
		and point.Z >= volume.Min.Z
		and point.Z <= volume.Max.Z
end

type Fit = {
	HalfExtent: number,
	-- The depth axis's range, sampled per cell.
	DepthMin: number,
	DepthMax: number,
}

local function fitView(view: "Top" | "Side", corners: { Vector3 }): Fit
	local extent = MIN_HALF_EXTENT
	local depthMin, depthMax = math.huge, -math.huge
	for _, corner in corners do
		if view == "Top" then
			extent = math.max(extent, math.abs(corner.X), math.abs(corner.Z))
			depthMin, depthMax = math.min(depthMin, corner.Y), math.max(depthMax, corner.Y)
		else
			extent = math.max(extent, math.abs(corner.Y), math.abs(corner.Z))
			depthMin, depthMax = math.min(depthMin, corner.X), math.max(depthMax, corner.X)
		end
	end
	return { HalfExtent = math.ceil(extent * 1.1), DepthMin = depthMin, DepthMax = depthMax }
end

-- The root-space point at plot cell (column, row), at `depth` along the view's collapsed axis.
local function cellPoint(view: "Top" | "Side", column: number, row: number, halfExtent: number, depth: number): Vector3
	local step = halfExtent * 2 / GRID
	local across = -halfExtent + (column + 0.5) * step
	local down = -halfExtent + (row + 0.5) * step
	if view == "Top" then
		-- Right is +X; up the plot is forward (-Z).
		return Vector3.new(across, depth, down)
	end
	-- Right is forward (-Z); up the plot is +Y.
	return Vector3.new(depth, -down, -across)
end

local function HitboxPlot(scope: Scope, props: HitboxPlotProps): Frame
	local size = props.Size
	local cellPixels = size / GRID
	local extentText = scope:Value("")

	local canvas = scope:New "Frame" {
		Name = "Canvas",
		Position = UDim2.fromOffset(0, CAPTION_HEIGHT),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = scope:New "UIStroke" {
			Color = Tokens.Border.Hairline.Color,
			Transparency = Tokens.Border.Hairline.Transparency,
			Thickness = 1,
		},
	} :: Frame

	-- The cells, built once (see this file's header). Parented to the canvas, which the scope owns, so
	-- they go with it.
	local cells: { Frame } = table.create(GRID * GRID)
	for row = 0, GRID - 1 do
		for column = 0, GRID - 1 do
			local cell = Instance.new("Frame")
			cell.Name = "Cell"
			cell.BorderSizePixel = 0
			cell.BackgroundColor3 = Tokens.Color.Danger
			cell.BackgroundTransparency = 1
			cell.Position = UDim2.fromOffset(column * cellPixels, row * cellPixels)
			cell.Size = UDim2.fromOffset(math.ceil(cellPixels), math.ceil(cellPixels))
			cell.Parent = canvas
			cells[row * GRID + column + 1] = cell
		end
	end

	-- Crosshair through the root, and the body's own outline -- both repositioned when the fit changes.
	local function hairline(name: string, vertical: boolean): Frame
		local line = Instance.new("Frame")
		line.Name = name
		line.BorderSizePixel = 0
		line.BackgroundColor3 = Tokens.Border.Standard.Color
		line.BackgroundTransparency = Tokens.Border.Standard.Transparency
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.fromScale(0.5, 0.5)
		line.Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
		line.ZIndex = 2
		line.Parent = canvas
		return line
	end
	hairline("AxisX", false)
	hairline("AxisY", true)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundColor3 = Tokens.Color.TextSecondary
	body.BackgroundTransparency = 0.8
	body.BorderSizePixel = 0
	body.ZIndex = 3
	body.Parent = canvas
	local bodyStroke = Instance.new("UIStroke")
	bodyStroke.Color = Tokens.Color.TextPrimary
	bodyStroke.Transparency = 0.4
	bodyStroke.Thickness = 1
	bodyStroke.Parent = body

	-- Which way the attacker faces, as a short bar out of the body.
	local facing = Instance.new("Frame")
	facing.Name = "Facing"
	facing.BackgroundColor3 = Tokens.Color.AccentPrimaryBright
	facing.BorderSizePixel = 0
	facing.ZIndex = 3
	facing.Parent = canvas

	local function studsToPixels(studs: number, halfExtent: number): number
		return studs / (halfExtent * 2) * size
	end

	local function placeBody(halfExtent: number): ()
		local centre = size / 2
		if props.View == "Top" then
			local w, d = studsToPixels(BODY_HALF_WIDTH * 2, halfExtent), studsToPixels(BODY_HALF_DEPTH * 2, halfExtent)
			body.Position = UDim2.fromOffset(centre - w / 2, centre - d / 2)
			body.Size = UDim2.fromOffset(w, d)
			facing.Position = UDim2.fromOffset(centre - 1, centre - d / 2 - studsToPixels(1.5, halfExtent))
			facing.Size = UDim2.fromOffset(2, studsToPixels(1.5, halfExtent))
		else
			local d = studsToPixels(BODY_HALF_DEPTH * 2, halfExtent)
			local top = centre - studsToPixels(BODY_TOP, halfExtent)
			local bottom = centre - studsToPixels(BODY_BOTTOM, halfExtent)
			body.Position = UDim2.fromOffset(centre - d / 2, top)
			body.Size = UDim2.fromOffset(d, bottom - top)
			facing.Position = UDim2.fromOffset(centre + d / 2, centre - 1)
			facing.Size = UDim2.fromOffset(studsToPixels(1.5, halfExtent), 2)
		end
	end

	-- What each cell is showing, so a redraw writes only the cells that changed.
	local shown: { boolean } = table.create(GRID * GRID, false)
	local lit: { boolean } = table.create(GRID * GRID, false)

	local function setCell(index: number, on: boolean): ()
		if shown[index] ~= on then
			shown[index] = on
			cells[index].BackgroundTransparency = if on then 0.35 else 1
		end
	end

	-- The columns and rows a volume's root-space box can touch in this view, clamped to the grid.
	local function cellRange(volume: Volume, halfExtent: number): (number, number, number, number)
		local step = halfExtent * 2 / GRID
		local across0, across1, down0, down1
		if props.View == "Top" then
			across0, across1, down0, down1 = volume.Min.X, volume.Max.X, volume.Min.Z, volume.Max.Z
		else
			across0, across1, down0, down1 = -volume.Max.Z, -volume.Min.Z, -volume.Max.Y, -volume.Min.Y
		end
		local function index(value: number): number
			return math.clamp(math.floor((value + halfExtent) / step), 0, GRID - 1)
		end
		return index(across0), index(across1), index(down0), index(down1)
	end

	local function redraw(): ()
		local move = peek(props.Draft)
		if not move then
			for index = 1, GRID * GRID do
				setCell(index, false)
			end
			extentText:set("")
			placeBody(MIN_HALF_EXTENT)
			return
		end

		local volumes = volumesOf(move)
		local fit = fitView(props.View, worldCorners(volumes))
		local depthSamples = if #volumes > MANY_VOLUMES then FEW_DEPTH_SAMPLES else DEPTH_SAMPLES
		table.clear(lit)
		for _, volume in volumes do
			local columnMin, columnMax, rowMin, rowMax = cellRange(volume, fit.HalfExtent)
			-- Sampled through THIS volume's own depth, not the whole plot's: fewer wasted samples, and a
			-- thin volume far from the others is not missed between them.
			local depthMin, depthMax
			if props.View == "Top" then
				depthMin, depthMax = volume.Min.Y, volume.Max.Y
			else
				depthMin, depthMax = volume.Min.X, volume.Max.X
			end
			local depthStep = if depthSamples > 1 then (depthMax - depthMin) / (depthSamples - 1) else 0
			for row = rowMin, rowMax do
				for column = columnMin, columnMax do
					local index = row * GRID + column + 1
					if lit[index] then
						continue
					end
					for sample = 0, depthSamples - 1 do
						local point = cellPoint(props.View, column, row, fit.HalfExtent, depthMin + depthStep * sample)
						if
							insideBox(volume, point)
							and HitboxGeometry.ContainsPoint(volume.Shape, volume.Dimensions, volume.Inverse * point, 0)
						then
							lit[index] = true
							break
						end
					end
				end
			end
		end
		for index = 1, GRID * GRID do
			setCell(index, lit[index] == true)
		end
		extentText:set(`±{fit.HalfExtent} studs`)
		placeBody(fit.HalfExtent)
	end

	scope:Observer(props.Draft):onBind(redraw)

	return scope:New "Frame" {
		Name = `HitboxPlot{props.View}`,
		Size = UDim2.fromOffset(size, size + CAPTION_HEIGHT),
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,

		[Children] = {
			TrackedLabel(scope, {
				Text = string.upper(props.View),
				Scale = "Chip",
				Color = Tokens.Color.TextDisabled,
				Position = UDim2.fromOffset(0, 0),
			}),
			Label(scope, {
				Text = extentText,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextDisabled,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromOffset(size, CAPTION_HEIGHT - 2),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			canvas,
		},
	} :: Frame
end

return HitboxPlot
