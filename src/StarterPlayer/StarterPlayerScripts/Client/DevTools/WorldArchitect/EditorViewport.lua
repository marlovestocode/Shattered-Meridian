--!strict
--[[
	EditorViewport.lua

	Owns: the World Architect's side of the 3D world while the editor is open, all of it client-local -- the orbit camera
	(the Move Editor's PlacementCamera, shared), picking, selection outlines, the transform gizmo, the placement ghost,
	the terrain brush ghost, the generation preview, the optimiser's outlines, the admin-only Hide, and the editor's
	keyboard shortcuts.

	NOTHING HERE CHANGES THE WORLD. Every action ends as an Intent on the screen's handle (Pick, TransformCommit,
	PlaceAt, Stroke, Duplicate...) for WorldArchitectClient to send; the server decides. Ghosts are local Parts under a
	local folder in the camera, outlines are SelectionBoxes, Hide is LocalTransparencyModifier -- all of it is torn down
	by one Trove when the editor closes, so a cancelled drag, a cancelled preview or a closed editor leaves nothing.

	THE GIZMO. Handles (Move, Scale) or ArcHandles (Rotate) on an invisible proxy box around the selection. A drag shows
	the result as ghosts (the selection's real parts are hidden locally for the drag) and only commits on release;
	Escape or a right click during the drag cancels it and restores the view. Every drag snaps: translation and size to
	the grid, rotation to the turn step, in World or Local axes. A Scale drag on one part resizes that face; on a set or
	a group it scales the set uniformly about its pivot.

	PICKING SELECTS THE TOP-LEVEL ITEM (a placed template selects as one thing); Alt-click picks the part itself;
	Shift-click adds or removes. Clicks that land on the console's panels never reach here (gameProcessed).

	A raw-input file on purpose, like the Move Editor's HitboxWorldPreview: a dev tool's in-world gestures and its
	CAS key sink (scripts/cohesion-report.py lists the exemption).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Trove = require(ReplicatedStorage.Shared.Trove)
local ArchitectBuild = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectBuild)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)

local PlacementCamera = require(script.Parent.Parent.MoveEditor.PlacementCamera)
local WorldArchitectTypes = require(script.Parent.Parent.Parent.UI.Screens.DevTools.WorldArchitect.Types)

type Handle = WorldArchitectTypes.Handle
type NodeRecord = ArchitectRecord.NodeRecord
type Trove = Trove.TroveInstance

local peek = Fusion.peek

local EditorViewport = {}

local KEY_ACTION = "WorldArchitectKeys"
local KEY_PRIORITY = Enum.ContextActionPriority.High.Value + 50

local SELECT_COLOR = Color3.fromRGB(150, 214, 228)
local LOCKED_COLOR = Color3.fromRGB(196, 164, 110)
local FINDING_COLOR = Color3.fromRGB(216, 150, 80)
local GHOST_TRANSPARENCY = 0.55
local PICK_DISTANCE = 4000
local STROKE_INTERVAL = 0.18
local OUTLINE_CAP = 600

local TOOL_KEYS: { [Enum.KeyCode]: WorldArchitectTypes.Tool } = {
	[Enum.KeyCode.One] = "Select",
	[Enum.KeyCode.Two] = "Move",
	[Enum.KeyCode.Three] = "Rotate",
	[Enum.KeyCode.Four] = "Scale",
	[Enum.KeyCode.Five] = "Place",
	[Enum.KeyCode.Six] = "Terrain",
}

local AXIS_OF_NORMAL: { [Enum.NormalId]: { Axis: ArchitectTransform.Axis, Sign: number } } = {
	[Enum.NormalId.Right] = { Axis = "X", Sign = 1 },
	[Enum.NormalId.Left] = { Axis = "X", Sign = -1 },
	[Enum.NormalId.Top] = { Axis = "Y", Sign = 1 },
	[Enum.NormalId.Bottom] = { Axis = "Y", Sign = -1 },
	[Enum.NormalId.Back] = { Axis = "Z", Sign = 1 },
	[Enum.NormalId.Front] = { Axis = "Z", Sign = -1 },
}

local AXIS_OF_ENUM: { [Enum.Axis]: ArchitectTransform.Axis } = {
	[Enum.Axis.X] = "X",
	[Enum.Axis.Y] = "Y",
	[Enum.Axis.Z] = "Z",
}

export type GenerationGhost = {
	Placements: { { TemplateId: string, CFrame: CFrame } },
	Corners: { Vector3 },
}

export type Session = {
	Stop: () -> (),
	-- Cancels an in-flight gizmo drag; true when there was one (so Escape stops there).
	CancelDrag: () -> boolean,
	-- The point the editor camera orbits: where Place and generation default to.
	Focus: () -> Vector3,
	FocusOn: (point: Vector3) -> (),
	ShowGeneration: (ghost: GenerationGhost?) -> (),
	-- Called once the server has answered a gizmo commit: a refusal puts the parts back where they started.
	EndPending: (accepted: boolean) -> (),
}

local function shiftHeld(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function ctrlHeld(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

local function altHeld(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
end

-- Ghost copies of records: built like the real thing, then made see-through, non-colliding and unqueryable.
local function ghost(records: { NodeRecord }, color: Color3?, parent: Instance): Model
	local model = ArchitectBuild.Assemble(records, "Ghost")
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Transparency = math.max(descendant.Transparency, GHOST_TRANSPARENCY)
			if color then
				descendant.Color = color
				descendant.Material = Enum.Material.ForceField
			end
		end
	end
	model.Parent = parent
	return model
end

function EditorViewport.Start(handle: Handle, root: Instance): Session
	local trove = Trove.New()
	local camera = Workspace.CurrentCamera
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local localFolder = trove:Add(Instance.new("Folder"))
	localFolder.Name = "WorldArchitectEditor"
	localFolder.Parent = camera

	-- Id -> Instance, rebuilt lazily from the replicated folder (the server's materializer tags each with its id).
	local instanceById: { [string]: Instance } = {}
	local function rebuildIndex()
		table.clear(instanceById)
		for _, descendant in root:GetDescendants() do
			local id = descendant:GetAttribute(ArchitectConstants.IdAttribute)
			if id then
				instanceById[id :: string] = descendant
			end
		end
	end
	local function instanceOf(id: string): Instance?
		local found = instanceById[id]
		if found == nil or found.Parent == nil then
			rebuildIndex()
			found = instanceById[id]
		end
		return found
	end
	trove:Connect(root.DescendantAdded, function(descendant: Instance)
		local id = descendant:GetAttribute(ArchitectConstants.IdAttribute)
		if id then
			instanceById[id :: string] = descendant
		end
	end)

	local cameraSession = PlacementCamera.Start(function(): Vector3?
		local selection = peek(handle.Selection)
		if #selection > 0 then
			local records = WorldArchitectTypes.WithDescendants(peek(handle.Records), selection)
			local low, high = ArchitectTransform.Bounds(records)
			if low and high then
				return (low + high) / 2
			end
		end
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
	end, { Owner = "WorldArchitect", MaxDistance = ArchitectConstants.Editor.CameraMaxDistance })
	trove:Add(cameraSession.Stop)

	--
	-- Hide (local view only)
	--
	local hiddenParts: { [BasePart]: boolean } = {}
	local function applyHidden()
		for part in hiddenParts do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		table.clear(hiddenParts)
		local hidden = peek(handle.Hidden)
		for id in hidden do
			local instance = instanceOf(id)
			if instance then
				local parts: { Instance } = if instance:IsA("BasePart") then { instance } else instance:GetDescendants()
				for _, part in parts do
					if part:IsA("BasePart") then
						part.LocalTransparencyModifier = 1
						hiddenParts[part] = true
					end
				end
			end
		end
	end
	trove:Add(function()
		for part in hiddenParts do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
	end)

	local function isHidden(instance: Instance): boolean
		return instance:IsA("BasePart") and hiddenParts[instance] == true
	end

	--
	-- Raycasts
	--
	local function mouseRay(): Ray
		local mouse = UserInputService:GetMouseLocation()
		return camera:ViewportPointToRay(mouse.X, mouse.Y)
	end

	-- The first built part under the mouse that is not hidden.
	local function pickBuilt(): BasePart?
		local ray = mouseRay()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { root }
		local origin = ray.Origin
		local remaining = PICK_DISTANCE
		for _ = 1, 8 do
			local hit = Workspace:Raycast(origin, ray.Direction * remaining, params)
			if hit == nil then
				return nil
			end
			if not isHidden(hit.Instance) then
				return hit.Instance :: BasePart
			end
			local travelled = (hit.Position - origin).Magnitude + 0.05
			remaining -= travelled
			origin = hit.Position + ray.Direction * 0.05
			if remaining <= 0 then
				return nil
			end
		end
		return nil
	end

	-- The surface under the mouse, ignoring characters and the editor's own ghosts.
	local function pickSurface(): (Vector3?, Vector3?)
		local ray = mouseRay()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignore: { Instance } = { localFolder }
		for _, other in Players:GetPlayers() do
			if other.Character then
				table.insert(ignore, other.Character)
			end
		end
		for part in hiddenParts do
			table.insert(ignore, part)
		end
		params.FilterDescendantsInstances = ignore
		local hit = Workspace:Raycast(ray.Origin, ray.Direction * PICK_DISTANCE, params)
		if hit then
			return hit.Position, hit.Normal
		end
		return nil, nil
	end

	--
	-- Selection outlines
	--
	local outlines = trove:Extend()
	local function drawOutlines()
		outlines:Clean()
		local records = peek(handle.Records)
		local count = 0
		local function outline(id: string, color: Color3)
			local instance = instanceOf(id)
			if instance == nil or count >= OUTLINE_CAP then
				return
			end
			count += 1
			local box = outlines:Add(Instance.new("SelectionBox"))
			box.Adornee = instance :: any
			box.Color3 = color
			box.LineThickness = 0.06
			box.SurfaceTransparency = 0.92
			box.SurfaceColor3 = color
			box.Parent = localFolder
		end
		for _, id in peek(handle.Selection) do
			local record = records[id]
			outline(id, if record and record.Locked then LOCKED_COLOR else SELECT_COLOR)
		end
		local report = peek(handle.Report)
		local included = peek(handle.PreviewFindings)
		if report then
			for _, finding in report.Findings do
				if included[finding.Id] then
					for _, id in finding.Nodes do
						outline(id, FINDING_COLOR)
					end
				end
			end
		end
	end

	--
	-- Transform gizmo
	--
	local gizmo = trove:Extend()
	-- A drag edits the selection's REAL parts on this client (the server replicates the same values back once it
	-- accepts the commit), eased toward the snapped target every frame so grid steps glide instead of jump. Each part's
	-- starting CFrame and Size are kept so a cancel or a refusal puts it back exactly.
	type Live = { Part: BasePart, StartCFrame: CFrame, StartSize: Vector3, Target: CFrame, TargetSize: Vector3 }
	local drag: {
		Start: { NodeRecord },
		Result: { NodeRecord }?,
		Cancelled: boolean,
		Live: { [string]: Live },
		Proxy: BasePart?,
		Follow: boolean,
	}? =
		nil
	-- Parts left at a committed transform while the server answers; restored if it refuses.
	local settling: { [string]: Live } = {}
	local overHandle = false

	-- The records a drag moves: the selection with everything under it.
	local function dragSet(): { NodeRecord }
		return WorldArchitectTypes.WithDescendants(peek(handle.Records), peek(handle.Selection))
	end

	local function restore(live: { [string]: Live })
		for _, entry in live do
			if entry.Part.Parent then
				entry.Part.CFrame = entry.StartCFrame
				entry.Part.Size = entry.StartSize
			end
		end
	end

	local function showDrag(result: { NodeRecord })
		local current = drag
		if current == nil then
			return
		end
		current.Result = result
		for _, record in result do
			local entry = current.Live[record.Id]
			if entry then
				entry.Target = ArchitectRecord.CFrameOf(record)
				entry.TargetSize = record.Size
			end
		end
		-- The handles ride on the box being dragged, so the face under the cursor stays under it.
		local proxy = current.Proxy
		if current.Follow and proxy then
			local low, high = ArchitectTransform.Bounds(result)
			if #result == 1 and result[1].Kind == "Part" and peek(handle.Space) == "Local" then
				proxy.CFrame = ArchitectRecord.CFrameOf(result[1])
				proxy.Size = result[1].Size
			elseif low and high then
				proxy.CFrame = CFrame.new((low + high) / 2)
				proxy.Size = (high - low):Max(Vector3.new(0.5, 0.5, 0.5))
			end
		end
	end

	local function endDrag(commit: boolean)
		local current = drag
		drag = nil
		if current == nil then
			return
		end
		if commit and not current.Cancelled and current.Result then
			-- Land exactly on the snapped values, and hold them until the server answers (EndPending).
			for id, entry in current.Live do
				if entry.Part.Parent then
					entry.Part.CFrame = entry.Target
					entry.Part.Size = entry.TargetSize
				end
				settling[id] = entry
			end
			handle.Fire({ Kind = "TransformCommit", Records = current.Result, Label = peek(handle.Tool) })
			return
		end
		restore(current.Live)
	end

	local function beginDrag(proxy: BasePart, follow: boolean)
		local start = dragSet()
		local live: { [string]: Live } = {}
		for _, record in start do
			local instance = instanceOf(record.Id)
			if instance and instance:IsA("BasePart") then
				live[record.Id] = {
					Part = instance,
					StartCFrame = instance.CFrame,
					StartSize = instance.Size,
					Target = instance.CFrame,
					TargetSize = instance.Size,
				}
			end
		end
		drag = { Start = start, Result = nil, Cancelled = false, Live = live, Proxy = proxy, Follow = follow }
	end

	-- Eases every dragged part toward its target. Frame-rate independent; ~95% of the way in a tenth of a second.
	local SMOOTHING = 30
	trove:Connect(RunService.RenderStepped, function(deltaTime: number)
		local current = drag
		if current == nil then
			return
		end
		local alpha = 1 - math.exp(-SMOOTHING * deltaTime)
		for _, entry in current.Live do
			local part = entry.Part
			if part.Parent then
				part.CFrame = part.CFrame:Lerp(entry.Target, alpha)
				part.Size = part.Size:Lerp(entry.TargetSize, alpha)
			end
		end
	end)

	local function primaryFrame(start: { NodeRecord }): CFrame?
		local first = peek(handle.Selection)[1]
		for _, record in start do
			if record.Id == first then
				return ArchitectRecord.CFrameOf(record)
			end
		end
		return nil
	end

	local function buildGizmo()
		gizmo:Clean()
		overHandle = false
		local tool = peek(handle.Tool)
		if tool ~= "Move" and tool ~= "Rotate" and tool ~= "Scale" then
			return
		end
		local records = dragSet()
		if #records == 0 then
			return
		end
		for _, record in records do
			if record.Locked then
				return
			end
		end
		local low, high = ArchitectTransform.Bounds(records)
		if low == nil or high == nil then
			return
		end
		local space = peek(handle.Space)
		local proxy = gizmo:Add(Instance.new("Part"))
		proxy.Name = "GizmoProxy"
		proxy.Anchored = true
		proxy.CanCollide = false
		proxy.CanQuery = false
		proxy.CanTouch = false
		proxy.Transparency = 1
		local reference = primaryFrame(records)
		if space == "Local" and reference and #peek(handle.Selection) == 1 and records[1].Kind == "Part" then
			proxy.CFrame = reference
			proxy.Size = records[1].Size
		else
			proxy.CFrame = CFrame.new((low + high) / 2)
			proxy.Size = (high - low):Max(Vector3.new(0.5, 0.5, 0.5))
		end
		proxy.Parent = localFolder
		local axesFrame = proxy.CFrame

		local function hover(object: GuiBase3d)
			gizmo:Connect((object :: any).MouseEnter, function()
				overHandle = true
			end)
			gizmo:Connect((object :: any).MouseLeave, function()
				overHandle = false
			end)
		end

		if tool == "Rotate" then
			local arcs = gizmo:Add(Instance.new("ArcHandles"))
			arcs.Adornee = proxy
			arcs.Color3 = SELECT_COLOR
			hover(arcs)
			gizmo:Connect(arcs.MouseButton1Down, function()
				-- The arcs stay put: their angle is measured about where the drag began.
				beginDrag(proxy, false)
			end)
			gizmo:Connect(arcs.MouseDrag, function(axis: Enum.Axis, relativeAngle: number)
				local current = drag
				if current == nil or current.Cancelled then
					return
				end
				local degrees = ArchitectTransform.Snap(math.deg(relativeAngle), peek(handle.RotationStep))
				local axisVector =
					axesFrame:VectorToWorldSpace(ArchitectTransform.AxisVector(AXIS_OF_ENUM[axis], "World", nil))
				showDrag(ArchitectTransform.RotateAbout(current.Start, axesFrame.Position, axisVector, degrees))
			end)
			gizmo:Connect(arcs.MouseButton1Up, function()
				endDrag(true)
				buildGizmo()
			end)
			arcs.Parent = playerGui
			return
		end

		local handles = gizmo:Add(Instance.new("Handles"))
		handles.Adornee = proxy
		handles.Color3 = SELECT_COLOR
		handles.Style = if tool == "Scale" then Enum.HandlesStyle.Resize else Enum.HandlesStyle.Movement
		hover(handles)
		gizmo:Connect(handles.MouseButton1Down, function()
			beginDrag(proxy, true)
		end)
		gizmo:Connect(handles.MouseDrag, function(face: Enum.NormalId, distance: number)
			local current = drag
			if current == nil or current.Cancelled then
				return
			end
			local grid = peek(handle.Grid)
			local snapped = ArchitectTransform.Snap(distance, grid)
			local info = AXIS_OF_NORMAL[face]
			local direction = axesFrame:VectorToWorldSpace(Vector3.FromNormalId(face))
			if tool == "Move" then
				showDrag(ArchitectTransform.Translate(current.Start, direction * snapped))
				return
			end
			-- Scale: one part resizes the dragged face; a group or several parts stretch along the dragged axis with the
			-- opposite side fixed (a wall run gets longer, not taller); Shift scales the set uniformly instead.
			if #current.Start == 1 and current.Start[1].Kind == "Part" then
				local record = current.Start[1]
				local frame = ArchitectRecord.CFrameOf(record)
				local localAxis = frame:VectorToObjectSpace(direction)
				local axis: ArchitectTransform.Axis = if math.abs(localAxis.X) > 0.7
					then "X"
					elseif math.abs(localAxis.Y) > 0.7 then "Y"
					else "Z"
				local sign = if ArchitectTransform.Component(localAxis, axis) > 0 then 1 else -1
				showDrag({
					ArchitectTransform.ResizeFace(record, axis, sign, snapped, ArchitectConstants.Limits.MinPartSize),
				})
			else
				local extent = ArchitectTransform.Component((high :: Vector3) - (low :: Vector3), info.Axis)
				local factor = math.max(1 + snapped / math.max(extent, 0.5), 0.05)
				if shiftHeld() then
					showDrag(
						ArchitectTransform.ScaleSet(current.Start, ArchitectTransform.PivotOf(current.Start), factor)
					)
				else
					local anchor = ArchitectTransform.Component(
						if info.Sign > 0 then low :: Vector3 else high :: Vector3,
						info.Axis
					)
					showDrag(
						ArchitectTransform.StretchSet(
							current.Start,
							info.Axis,
							anchor,
							factor,
							ArchitectConstants.Limits.MinPartSize
						)
					)
				end
			end
		end)
		gizmo:Connect(handles.MouseButton1Up, function()
			endDrag(true)
			buildGizmo()
		end)
		handles.Parent = playerGui
	end

	--
	-- Place ghost
	--
	local placeGhost = trove:Extend()
	local placeYaw = 0
	local placeModel: Model? = nil
	local placeRecords: { NodeRecord }? = nil
	local lastPlacePivot: CFrame? = nil

	local function rebuildPlaceGhost()
		placeGhost:Clean()
		placeModel = nil
		placeRecords = nil
		if peek(handle.Tool) ~= "Place" then
			return
		end
		local asset = peek(handle.ActiveAsset)
		if asset == nil then
			return
		end
		local records = WorldArchitectTypes.AssetRecords(asset, peek(handle.TemplateCache) :: any)
		if records == nil then
			return
		end
		placeRecords = records
		local model = placeGhost:Add(ghost(records, SELECT_COLOR, localFolder))
		-- Records are in the asset's own space, so its pivot is the origin: PivotTo then places the whole ghost.
		model.WorldPivot = CFrame.identity
		placeModel = model
		lastPlacePivot = nil
	end

	local function placementPivot(): CFrame?
		local position, normal = pickSurface()
		if position == nil then
			return nil
		end
		local grid = peek(handle.Grid)
		local snapped = if grid > 0
			then Vector3.new(
				ArchitectTransform.Snap(position.X, grid),
				position.Y,
				ArchitectTransform.Snap(position.Z, grid)
			)
			else position
		if not peek(handle.SurfaceSnap) and grid > 0 then
			snapped = Vector3.new(snapped.X, ArchitectTransform.Snap(position.Y, grid), snapped.Z)
		end
		local pivot = CFrame.new(snapped) * CFrame.fromOrientation(0, math.rad(placeYaw), 0)
		-- On a wall (surface snap on), a single primitive is set against the face rather than its pivot on it.
		if peek(handle.SurfaceSnap) and normal and math.abs(normal.Y) < 0.7 and placeRecords and #placeRecords == 1 then
			local record = (placeRecords :: { NodeRecord })[1]
			local frame = ArchitectTransform.SurfacePlacement(position, normal, record.Size, placeYaw, grid)
			pivot = frame * CFrame.new(0, -record.Size.Y / 2, 0)
		end
		return pivot
	end

	--
	-- Terrain brush ghost
	--
	local brush = trove:Extend()
	local brushPart: Part? = nil
	local stroking = false
	local lastStrokeAt = 0
	local lastStrokeCenter: Vector3? = nil
	local flattenHeight: number? = nil

	local function rebuildBrush()
		brush:Clean()
		brushPart = nil
		if peek(handle.Tool) ~= "Terrain" then
			return
		end
		local part = brush:Add(Instance.new("Part"))
		part.Name = "Brush"
		part.Shape = Enum.PartType.Ball
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.ForceField
		part.Color = SELECT_COLOR
		part.Transparency = 0.3
		part.Parent = localFolder
		brushPart = part
	end

	local function stroke(center: Vector3)
		local settings = peek(handle.Terrain)
		handle.Fire({
			Kind = "Stroke",
			Center = center,
			Height = if settings.Mode == "Flatten" then flattenHeight or center.Y else nil,
		})
		lastStrokeAt = os.clock()
		lastStrokeCenter = center
	end

	--
	-- Generation preview
	--
	local generation = trove:Extend()
	local function showGeneration(layout: GenerationGhost?)
		generation:Clean()
		if layout == nil then
			return
		end
		local cache = peek(handle.TemplateCache) :: any
		local folder = generation:Add(Instance.new("Folder"))
		folder.Name = "GenerationPreview"
		folder.Parent = localFolder
		for _, placement in layout.Placements do
			local records = WorldArchitectTypes.AssetRecords(placement.TemplateId, cache)
			if records then
				local moved = ArchitectTransform.TransformSet(records, CFrame.identity, placement.CFrame)
				ghost(moved, SELECT_COLOR, folder)
			end
		end
		local corners = layout.Corners
		for index, corner in corners do
			local nextCorner = corners[(index % #corners) + 1]
			local edge = Instance.new("Part")
			edge.Anchored = true
			edge.CanCollide = false
			edge.CanQuery = false
			edge.CanTouch = false
			edge.CastShadow = false
			edge.Material = Enum.Material.Neon
			edge.Color = SELECT_COLOR
			edge.Transparency = 0.4
			local length = (nextCorner - corner).Magnitude
			edge.Size = Vector3.new(0.3, 0.3, length)
			edge.CFrame = CFrame.lookAt((corner + nextCorner) / 2, nextCorner) + Vector3.new(0, 0.5, 0)
			edge.Parent = folder
		end
	end

	--
	-- Mouse
	--
	local DOUBLE_CLICK = 0.35
	local lastClickId: unknown = nil
	local lastClickAt = 0
	trove:Connect(UserInputService.InputBegan, function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and drag then
			-- A right click mid-drag cancels the drag (it would otherwise start an orbit).
			local current = drag :: any
			current.Cancelled = true
			endDrag(false)
			buildGizmo()
			return
		end
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local tool = peek(handle.Tool)
		if tool == "Place" then
			local pivot = placementPivot()
			if pivot then
				handle.Fire({ Kind = "PlaceAt", Pivot = pivot })
			end
			return
		end
		if tool == "Terrain" then
			local position = pickSurface()
			if position then
				stroking = true
				flattenHeight = position.Y
				stroke(position)
			end
			return
		end
		if overHandle or drag then
			return
		end
		local part = pickBuilt()
		if part == nil then
			if not shiftHeld() then
				handle.Fire({ Kind = "Deselect" })
			end
			return
		end
		local id = part:GetAttribute(ArchitectConstants.IdAttribute)
		if id == nil then
			return
		end
		-- Which piece a click means: the whole placed item, or the one part under the cursor. PICK PART (P) flips the
		-- default, Alt flips it for one click, and a second click on the same part within DOUBLE_CLICK steps inside.
		local now = os.clock()
		local doubleClick = id == lastClickId and now - lastClickAt <= DOUBLE_CLICK
		lastClickId, lastClickAt = id, now
		local deep = (altHeld() ~= peek(handle.DeepPick)) or doubleClick
		handle.Fire({ Kind = "Pick", Id = id, Additive = shiftHeld(), Deep = deep })
	end)
	trove:Connect(UserInputService.InputEnded, function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			stroking = false
			flattenHeight = nil
		end
	end)

	-- Per frame: only the cursor-following ghosts move; nothing here scans the world.
	trove:Connect(RunService.RenderStepped, function()
		local tool = peek(handle.Tool)
		if tool == "Place" and placeModel then
			local pivot = placementPivot()
			if pivot and pivot ~= lastPlacePivot then
				lastPlacePivot = pivot;
				(placeModel :: Model):PivotTo(pivot)
			end
		elseif tool == "Terrain" and brushPart then
			local position = pickSurface()
			local radius = peek(handle.Terrain).Radius
			local part = brushPart :: Part
			part.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
			if position then
				part.Position = position
				part.Transparency = 0.3
				if
					stroking
					and os.clock() - lastStrokeAt >= STROKE_INTERVAL
					and (lastStrokeCenter == nil or (position - lastStrokeCenter :: Vector3).Magnitude > radius * 0.5)
				then
					stroke(position)
				end
			else
				part.Transparency = 1
			end
		end
	end)

	--
	-- Keys
	--
	ContextActionService:BindActionAtPriority(
		KEY_ACTION,
		function(_name, state, input)
			if PlacementCamera.PanKeys[input.KeyCode] and not ctrlHeld() then
				cameraSession.SetKey(input.KeyCode, state == Enum.UserInputState.Begin)
				return Enum.ContextActionResult.Sink
			end
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			local key = input.KeyCode
			local tool = TOOL_KEYS[key]
			if tool then
				handle.Fire({ Kind = "SetTool", Tool = tool })
			elseif key == Enum.KeyCode.Z and ctrlHeld() then
				handle.Fire({ Kind = if shiftHeld() then "Redo" else "Undo" })
			elseif key == Enum.KeyCode.Y and ctrlHeld() then
				handle.Fire({ Kind = "Redo" })
			elseif key == Enum.KeyCode.D and ctrlHeld() then
				handle.Fire({ Kind = "Duplicate" })
			elseif key == Enum.KeyCode.A and ctrlHeld() then
				handle.Fire({ Kind = "SelectAll" })
			elseif key == Enum.KeyCode.G and ctrlHeld() then
				handle.Fire({ Kind = if shiftHeld() then "Ungroup" else "Group" })
			elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then
				handle.Fire({ Kind = "Delete" })
			elseif key == Enum.KeyCode.F then
				handle.Fire({ Kind = "Focus" })
			elseif key == Enum.KeyCode.R then
				local step = peek(handle.RotationStep)
				local turn = if step > 0 then step else 90
				if peek(handle.Tool) == "Place" then
					placeYaw = (placeYaw + turn) % 360
					lastPlacePivot = nil
				else
					handle.Fire({ Kind = "Turn", Degrees = turn })
				end
			elseif key == Enum.KeyCode.H then
				handle.Fire({ Kind = "SetHidden", Hidden = not shiftHeld() })
			elseif key == Enum.KeyCode.P then
				handle.Fire({ Kind = "ToggleDeepPick" })
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		KEY_PRIORITY,
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
		Enum.KeyCode.Six,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Q,
		Enum.KeyCode.E,
		Enum.KeyCode.Z,
		Enum.KeyCode.Y,
		Enum.KeyCode.G,
		Enum.KeyCode.F,
		Enum.KeyCode.R,
		Enum.KeyCode.H,
		Enum.KeyCode.P,
		Enum.KeyCode.Delete,
		Enum.KeyCode.Backspace
	)
	trove:Add(function()
		ContextActionService:UnbindAction(KEY_ACTION)
	end)

	--
	-- Reacting to the console
	--
	local observers = Fusion.scoped(Fusion)
	trove:Add(function()
		observers:doCleanup()
	end)
	local function refreshWorldViews()
		drawOutlines()
		if drag == nil then
			buildGizmo()
		end
		applyHidden()
	end
	observers:Observer(handle.Records):onChange(refreshWorldViews)
	observers:Observer(handle.Selection):onChange(refreshWorldViews)
	observers:Observer(handle.Space):onChange(buildGizmo)
	observers:Observer(handle.Hidden):onChange(applyHidden)
	observers:Observer(handle.Report):onChange(drawOutlines)
	observers:Observer(handle.PreviewFindings):onChange(drawOutlines)
	observers:Observer(handle.Tool):onChange(function()
		if drag then
			local current = drag :: any
			current.Cancelled = true
			endDrag(false)
		end
		buildGizmo()
		rebuildPlaceGhost()
		rebuildBrush()
	end)
	observers:Observer(handle.ActiveAsset):onChange(rebuildPlaceGhost)
	observers:Observer(handle.TemplateCache):onChange(rebuildPlaceGhost)

	trove:Add(function()
		local current = drag
		if current then
			current.Cancelled = true
			endDrag(false)
		end
		table.clear(settling)
	end)

	refreshWorldViews()
	rebuildPlaceGhost()
	rebuildBrush()

	return {
		Stop = function()
			trove:Clean()
		end,
		CancelDrag = function(): boolean
			local current = drag
			if current == nil then
				return false
			end
			current.Cancelled = true
			endDrag(false)
			buildGizmo()
			return true
		end,
		Focus = cameraSession.Focus,
		FocusOn = cameraSession.FocusOn,
		ShowGeneration = showGeneration,
		EndPending = function(accepted: boolean)
			if not accepted then
				restore(settling)
			end
			table.clear(settling)
		end,
	}
end

return EditorViewport
