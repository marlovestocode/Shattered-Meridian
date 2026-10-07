--!strict
--[[
	HitboxWorldPreview.lua

	Owns: the Move Editor's hitbox drawn ON THE ADMIN'S OWN CHARACTER in the world, every frame, and
	Place mode's gizmo -- dragging the volume's position, size and rotation with Roblox's own
	Handles/ArcHandles.

	WHERE THE ENGINE WOULD PUT IT. The anchor is Shared/HitboxEngine/HitboxAnchor.Resolve -- the chain the
	server's HitboxEngine itself runs -- and the volume sits at anchor.CFrame * draft.Offset, so a
	hand- or weapon-anchored move rides the arm through whatever animation is playing, exactly as the
	hitbox will. A weapon-anchored Box takes the resolved blade's own size (x SizeMultiplier), mirroring
	the engine's SizeFromAttachmentPart, and is tinted to say the blade decides it.

	A PROJECTILE MOVE draws its SPAWN BODY instead -- the shot's own shape and size (a sphere of its radius
	by default; any ProjectileBody otherwise, in the pose it flies in), at the spawn point, which is where
	the volley starts (the readout's plots draw where it goes). Move and Rotate place and aim it exactly as
	they do a volume; Resize sets the shot's own measurements and never moves the spawn point.

	A DOMAIN MOVE draws its REALM'S BOUNDARY (Shared/Domain) -- a ball, a standing cylinder or a box, centred
	CenterForward studs ahead of the root, turned with the body's yaw only -- because a domain move has no
	volume of its own to place. It is a picture, not a gizmo: there is nothing to drag, and Place mode is
	not offered for it.

	CLIENT-ONLY BY CONSTRUCTION. Every part lives under workspace.CurrentCamera, which never replicates;
	each is anchored, non-colliding, non-queryable and non-touching, so the preview cannot be hit, cast
	against or stood on -- nothing a parkour probe, a hitbox or a camera occluder will ever see.

	PLACE MODE (PlacementMode on the handle). The editor's modal closes -- the session stays open and the
	character stays frozen -- and this module:
	  * takes the camera (PlacementCamera): an orbit around the volume -- right-drag orbits, middle-drag
	    and W/A/S/D/Q/E pan, the wheel zooms, F re-centres -- with the cursor free for the handles the
	    rest of the time. (First built as "free the mouse every frame", which froze the view: the stock
	    camera only orbits while it holds the mouse locked, and the character cannot walk. Playtest,
	    2026-09-29.);
	  * adorns Handles (Move / Resize) to a transparent part the size of the volume's bounding box, or
	    ArcHandles (Rotate) to a small part at the volume's origin, which is the pivot the rotation is
	    composed about;
	  * turns every drag into a draft edit (Handle.EditDraft), computed from the drag's START by
	    PlacementMath -- so the Preview debounce makes it live and the undo history coalesces the whole
	    drag into one step;
	  * sinks 1/2/3 (tool), Enter (done), F and the pan keys through ContextActionService while placing, so
	    the same keys do not also fire hotbar slots, interact or walk. Escape leaves placement through the
	    Chrome Escape stack (MoveEditorClient binds it), before it would close the editor.

	Does not own: the draft (the screen's), what a drag does numerically (PlacementMath), how shapes are
	built from parts (HitboxPreviewShapes), or the Place mode bar (Screens/DevTools/MoveEditor/
	PlacementBar.lua).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local HitboxAnchor = require(ReplicatedStorage.Shared.HitboxEngine.HitboxAnchor)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local ProjectileBody = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileBody)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local Tokens = require(script.Parent.Parent.Parent.UI.Tokens)
local MoveEditorScreenTypes = require(script.Parent.Parent.Parent.UI.Screens.DevTools.MoveEditor.Types)
local HitboxPreviewShapes = require(script.Parent.HitboxPreviewShapes)
local PlacementCamera = require(script.Parent.PlacementCamera)
local PlacementMath = require(script.Parent.PlacementMath)

local peek = Fusion.peek

type Move = MoveTypes.MoveDefinition
type MoveEditorHandle = MoveEditorScreenTypes.MoveEditorHandle
-- What a drag is computed from: the draft as it was when the mouse went down.
type DragStart = { Offset: CFrame, Rotation: Vector3, Dimensions: MoveTypes.MoveDimensions }

local HitboxWorldPreview = {}

local FOLDER_NAME = "MoveEditorHitboxPreview"
local VOLUME_TRANSPARENCY = 0.55
local KEY_ACTION_NAME = "MoveEditorPlacementKeys"
-- Above every gameplay binding, so the keys are sunk before a hotbar or an attack sees them.
local KEY_PRIORITY = Enum.ContextActionPriority.High.Value + 100
local PIVOT_SIZE = 0.4

local TOOL_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.One] = "Move",
	[Enum.KeyCode.Two] = "Rotate",
	[Enum.KeyCode.Three] = "Resize",
}

local function newPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- The Box a weapon-anchored move actually swings: the anchor part's own size, the engine's
-- SizeFromAttachmentPart branch. Never a projectile's: its shot is its own size.
local function bladeSized(move: Move): boolean
	return move.Projectile == nil and move.Domain == nil and move.AttachmentPart == "Weapon" and move.Shape == "Box"
end

-- What is drawn at the origin (this file's header): the move's volume, a projectile's spawn body, or a
-- realm's boundary. The third value turns the drawn pieces about the origin -- a shot that flies point
-- first is drawn the way it flies.
local function previewVolume(move: Move): (MoveTypes.MoveShape, MoveTypes.MoveDimensions, CFrame)
	local domain = move.Domain
	if domain then
		local dimensions = HitboxTypes.DefaultDimensions()
		if domain.Shape == "Sphere" then
			dimensions.Radius = domain.Radius
			return "Sphere", dimensions, CFrame.identity
		elseif domain.Shape == "Cylinder" then
			dimensions.Radius = domain.Radius
			dimensions.Height = domain.Height
			return "Pillar", dimensions, CFrame.identity
		end
		-- A Box's Radius is its HALF-width (DomainTypes' header).
		dimensions.Width = domain.Radius * 2
		dimensions.Length = domain.Radius * 2
		dimensions.Height = domain.Height
		return "Box", dimensions, CFrame.identity
	end
	local spec = move.Projectile
	if spec then
		local body = ProjectileBody.Of(spec)
		local turn = if body.Pointed
			then CFrame.new(0, 0, -body.LeadStuds) * CFrame.Angles(0, math.pi, 0)
			else CFrame.identity
		return body.Shape, body.Dimensions, turn
	end
	return move.Shape, move.Dimensions, CFrame.identity
end

function HitboxWorldPreview.Start(handle: MoveEditorHandle): ()
	local localPlayer = Players.LocalPlayer
	local session = Trove.New()

	local folder = session:Add(Instance.new("Folder"))
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace.CurrentCamera

	local character: Model? = nil
	local rootPart: BasePart? = nil
	PlayerLifecycle.BindLocalCharacter({
		Scope = "HitboxWorldPreview",
		OnCharacter = function(model: Model, _humanoid: Humanoid, life)
			character = model
			rootPart = CharacterUtil.AwaitRoot(model)
			life:Add(function()
				character = nil
				rootPart = nil
			end)
		end,
	})

	-- Volume parts ----------------------------------------------------------------------------------

	local pieces: { HitboxPreviewShapes.Piece } = {}
	local parts: { Part } = {}
	local builtSignature = ""

	local function rebuild(move: Move): ()
		local shape, dimensions = previewVolume(move)
		local signature = HitboxPreviewShapes.Signature(shape, dimensions)
			.. (if bladeSized(move) then "|blade" else "")
			.. (if move.Domain then "|realm" elseif move.Projectile then "|shot" else "")
		if signature == builtSignature then
			return
		end
		builtSignature = signature
		for _, part in parts do
			part:Destroy()
		end
		table.clear(parts)
		pieces = HitboxPreviewShapes.Build(shape, dimensions)
		local color = if bladeSized(move)
			then Tokens.Color.AccentSecondary
			elseif move.Domain then Tokens.Color.AccentPrimary
			else Tokens.Color.Danger
		for index, piece in pieces do
			local part = newPart(`Volume{index}`)
			part.Shape = piece.PartType
			part.Size = piece.Size
			part.Color = color
			part.Transparency = VOLUME_TRANSPARENCY
			part.Parent = folder
			table.insert(parts, part)
		end
	end

	-- Gizmo adornees: the volume's bounding box (Move/Resize handles sit on its faces) and its origin
	-- (ArcHandles pivot there, which is where ComposeOffset rotates about).
	local frame = session:Add(newPart("GizmoFrame"))
	frame.Transparency = 1
	frame.Parent = folder
	local pivot = session:Add(newPart("GizmoPivot"))
	pivot.Transparency = 1
	pivot.Size = Vector3.one * PIVOT_SIZE
	pivot.Parent = folder

	-- Where the volume's origin was last drawn -- what the placement camera focuses on.
	local lastOrigin: CFrame? = nil

	local function hide(): ()
		for _, part in parts do
			part.Transparency = 1
		end
	end

	local function anchorOf(move: Move): BasePart?
		local model, root = character, rootPart
		if not model or not root or not root.Parent then
			return nil
		end
		-- A realm is centred on the body, whatever anchor the swing that opens it was authored with.
		return HitboxAnchor.Resolve(model, root, if move.Domain then "Root" else move.AttachmentPart)
	end

	local function isVisible(): boolean
		return (peek(handle.IsOpen) or peek(handle.PlacementMode))
			and peek(handle.ShowOnCharacter)
			and peek(handle.Draft) ~= nil
	end

	session:Connect(RunService.RenderStepped, function()
		local move = peek(handle.Draft)
		if not move or not isVisible() then
			hide()
			return
		end
		local anchor = anchorOf(move)
		if not anchor then
			hide()
			return
		end
		rebuild(move)
		local domain = move.Domain
		local origin: CFrame
		if domain then
			-- Position and yaw only: a realm does not tilt with a body that is leaning into a run.
			local look = anchor.CFrame.LookVector
			local yaw = math.atan2(-look.X, -look.Z)
			origin = CFrame.new(anchor.Position) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, -domain.CenterForward)
		else
			origin = anchor.CFrame * move.Offset
		end
		local _, _, turn = previewVolume(move)

		if bladeSized(move) then
			local size = anchor.Size * (move.SizeMultiplier or 1)
			local part = parts[1]
			if part and part.Size ~= size then
				part.Size = size
			end
			if part then
				part.CFrame = origin
				part.Transparency = VOLUME_TRANSPARENCY
			end
			frame.Size = size
			frame.CFrame = origin
		else
			for index, part in parts do
				part.CFrame = origin * turn * pieces[index].Local
				part.Transparency = VOLUME_TRANSPARENCY
			end
			local shape, dimensions = previewVolume(move)
			local size, centre = HitboxGeometry.BoundingBox(shape, dimensions)
			frame.Size = size
			-- A shot drawn point first is a turned body whose bounding box is centred on the spawn point.
			frame.CFrame = if turn == CFrame.identity then origin * centre else origin
		end
		pivot.CFrame = origin
		lastOrigin = origin
	end)

	-- Place mode --------------------------------------------------------------------------------------

	local placement = session:Extend()
	local dragStart: DragStart? = nil

	local function captureStart(): ()
		local move = peek(handle.Draft)
		if not move then
			dragStart = nil
			return
		end
		local _, dimensions = previewVolume(move)
		dragStart = { Offset = move.Offset, Rotation = move.OffsetRotation, Dimensions = table.clone(dimensions) }
	end

	-- The gizmo for `tool`, everything it creates tracked by `owner` so a tool switch or leaving
	-- placement removes it whole.
	local function buildGizmo(tool: string, owner: Trove.TroveInstance): ()
		local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end
		if tool == "Rotate" then
			local arcs = owner:Add(Instance.new("ArcHandles"))
			arcs.Name = "MoveEditorRotate"
			arcs.Adornee = pivot
			local previousRaw = 0
			local accumulated = 0
			owner:Connect(arcs.MouseButton1Down, function()
				captureStart()
				previousRaw = 0
				accumulated = 0
			end)
			owner:Connect(arcs.MouseDrag, function(axis: Enum.Axis, relativeAngle: number)
				local start = dragStart
				if not start then
					return
				end
				accumulated += PlacementMath.UnwrapDelta(previousRaw, relativeAngle)
				previousRaw = relativeAngle
				local rotation = PlacementMath.Rotate(start.Rotation, axis, accumulated, peek(handle.PlacementSnap) > 0)
				handle.EditDraft(function(move)
					move.OffsetRotation = rotation
					move.Offset = MoveTypes.ComposeOffset(move.Offset.Position, rotation)
				end)
			end)
			arcs.Parent = playerGui
			return
		end

		local handles = owner:Add(Instance.new("Handles"))
		handles.Name = `MoveEditor{tool}`
		handles.Style = if tool == "Resize" then Enum.HandlesStyle.Resize else Enum.HandlesStyle.Movement
		handles.Color3 = Tokens.Color.AccentPrimaryBright
		handles.Adornee = frame
		owner:Connect(handles.MouseButton1Down, captureStart)
		owner:Connect(handles.MouseDrag, function(face: Enum.NormalId, distance: number)
			local start = dragStart
			if not start then
				return
			end
			local snap = peek(handle.PlacementSnap)
			if tool == "Resize" then
				handle.EditDraft(function(move)
					if bladeSized(move) then
						-- The blade decides a weapon-anchored Box's size; there is nothing to resize.
						return
					end
					if move.Domain then
						return
					end
					local spec = move.Projectile
					local shape = if spec then spec.Shape else move.Shape
					local dimensions, position = PlacementMath.Resize(
						shape :: MoveTypes.MoveShape,
						start.Dimensions,
						start.Offset,
						face,
						distance,
						snap
					)
					if spec then
						-- A shot's own measurements, each inside its own limits. Its spawn point stays where it
						-- is: the body is centred on it, so a one-sided drag has no origin to carry.
						local limits = ProjectileTypes.Limits
						spec.Size = math.clamp(dimensions.Radius, limits.Size.Min, limits.Size.Max)
						spec.Width = math.clamp(dimensions.Width, limits.Width.Min, limits.Width.Max)
						spec.Height = math.clamp(dimensions.Height, limits.Height.Min, limits.Height.Max)
						spec.Length = math.clamp(dimensions.Length, limits.Length.Min, limits.Length.Max)
						spec.InnerRadius =
							math.clamp(dimensions.InnerRadius, limits.InnerRadius.Min, limits.InnerRadius.Max)
						return
					end
					move.Dimensions = dimensions
					move.Offset = MoveTypes.ComposeOffset(position, move.OffsetRotation)
				end)
			else
				local position = PlacementMath.Move(start.Offset, face, distance, snap)
				handle.EditDraft(function(move)
					move.Offset = MoveTypes.ComposeOffset(position, move.OffsetRotation)
				end)
			end
		end)
		handles.Parent = playerGui
	end

	local function exitPlacement(): ()
		handle.PlacementMode:set(false)
	end

	local function enterPlacement(): ()
		placement:Clean()
		local camera = PlacementCamera.Start(function(): Vector3?
			return if lastOrigin then lastOrigin.Position elseif rootPart then rootPart.Position else nil
		end)
		placement:Add(camera.Stop)

		ContextActionService:BindActionAtPriority(
			KEY_ACTION_NAME,
			function(_name, state, input)
				if PlacementCamera.PanKeys[input.KeyCode] then
					camera.SetKey(input.KeyCode, state == Enum.UserInputState.Begin)
					return Enum.ContextActionResult.Sink
				end
				if state ~= Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Sink
				end
				local tool = TOOL_KEYS[input.KeyCode]
				if tool then
					handle.PlacementTool:set(tool)
				elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
					exitPlacement()
				elseif input.KeyCode == Enum.KeyCode.F then
					camera.Refocus()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			KEY_PRIORITY,
			Enum.KeyCode.One,
			Enum.KeyCode.Two,
			Enum.KeyCode.Three,
			Enum.KeyCode.Return,
			Enum.KeyCode.KeypadEnter,
			Enum.KeyCode.F,
			Enum.KeyCode.W,
			Enum.KeyCode.A,
			Enum.KeyCode.S,
			Enum.KeyCode.D,
			Enum.KeyCode.Q,
			Enum.KeyCode.E
		)
		placement:Add(function()
			ContextActionService:UnbindAction(KEY_ACTION_NAME)
		end)

		local gizmo = placement:Extend()
		local function showTool(tool: string): ()
			gizmo:Clean()
			buildGizmo(tool, gizmo)
		end
		showTool(peek(handle.PlacementTool))
		local toolObserver = Fusion.scoped(Fusion)
		placement:Add(function()
			toolObserver:doCleanup()
		end)
		toolObserver:Observer(handle.PlacementTool):onChange(function()
			showTool(peek(handle.PlacementTool))
		end)
	end

	local modeScope = Fusion.scoped(Fusion)
	session:Add(function()
		modeScope:doCleanup()
	end)
	modeScope:Observer(handle.PlacementMode):onChange(function()
		if peek(handle.PlacementMode) then
			enterPlacement()
		else
			placement:Clean()
			dragStart = nil
		end
	end)
	session:Add(function()
		placement:Clean()
	end)
end

return HitboxWorldPreview
