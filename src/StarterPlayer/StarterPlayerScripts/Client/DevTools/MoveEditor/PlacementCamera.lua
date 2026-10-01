--!strict
--[[
	PlacementCamera.lua

	Owns: the camera while the Move Editor is in Place mode -- an orbit camera around the hitbox, so the
	admin can look at the volume from any side while their character stays frozen.

	WHY PLACE MODE OWNS THE CAMERA OUTRIGHT (playtest, 2026-09-29): Place mode first only freed the mouse
	(forcing MouseBehavior.Default every frame so the cursor could grab a handle). That froze the view: the
	stock camera orbits only while IT holds the mouse locked during a right-drag, the forced Default undid
	that every frame, and a frozen character cannot walk the camera anywhere. So Place mode now switches the
	camera to Scriptable and drives it itself, with the controls every 3D editor uses:

	    right-drag        orbit around the focus
	    middle-drag       pan the focus across the screen
	    W A S D / Q E     pan the focus (horizontal / down-up)
	    wheel             zoom
	    F                 re-centre on the hitbox

	THE FOCUS IS A POINT, NOT THE HITBOX. It starts on the volume and re-centres on F, but it does not
	follow the volume every frame: a Handles drag measures the mouse against the axis as seen from the
	camera, so a camera that moved during the drag would feed its own motion back into the drag and send
	the volume running away.

	COORDINATION, NOT A FIGHT. ShiftLockCamera is the canonical writer of MouseBehavior and the body's yaw;
	this suspends it through its own keyed SetInputSuspended rather than overwriting it, so it neither
	re-locks the cursor nor turns the character toward the orbiting camera (which would swing a
	root-anchored hitbox around with it). The camera itself is written at RenderPriority.Last + 2, after
	every other camera step, so shakes and offsets computed for gameplay cannot leak into the editor view.

	Keyboard-and-mouse only. Nothing here is reachable from a gamepad yet; Place mode itself is a mouse tool
	(the gizmo is Handles).

	The orbit arithmetic is pure and exported (AnglesFrom / Frame) for Tests/MoveEditor/PlacementPreview.spec.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Shared.Trove)

local ShiftLockCamera = require(script.Parent.Parent.Parent.Camera.ShiftLockCamera)

local PlacementCamera = {}

local STEP_NAME = "MoveEditorPlacementCamera"
local SUSPEND_OWNER = "MoveEditorPlacement"

-- Radians of orbit per pixel of right-drag.
local ORBIT_SENSITIVITY = 0.008
-- Pitch stops short of straight up/down, where yaw stops meaning anything.
local MAX_PITCH = math.rad(85)
PlacementCamera.DistanceLimits = { Min = 2, Max = 80 }
-- Each wheel notch changes the distance by this fraction.
local ZOOM_STEP = 0.12
-- Studs per second of keyboard pan at distance 10; scaled by distance so a far view pans usefully.
local KEY_PAN_SPEED = 8
-- Studs of middle-drag pan per pixel, at distance 10; scaled the same way.
local DRAG_PAN_PER_PIXEL = 0.02

-- The orbit that reproduces `cameraFrame` looking at `focus`: yaw and pitch of the view direction, and
-- the distance. Pure.
function PlacementCamera.AnglesFrom(cameraFrame: CFrame, focus: Vector3): (number, number, number)
	local offset = cameraFrame.Position - focus
	local distance =
		math.clamp(offset.Magnitude, PlacementCamera.DistanceLimits.Min, PlacementCamera.DistanceLimits.Max)
	if offset.Magnitude < 1e-3 then
		offset = -cameraFrame.LookVector
	end
	local direction = -offset.Unit
	local yaw = math.atan2(-direction.X, -direction.Z)
	local pitch = math.clamp(math.asin(math.clamp(direction.Y, -1, 1)), -MAX_PITCH, MAX_PITCH)
	return yaw, pitch, distance
end

-- The camera frame for an orbit: `distance` studs back from `focus` along the view that yaw/pitch give,
-- looking at it. Pure.
function PlacementCamera.Frame(focus: Vector3, yaw: number, pitch: number, distance: number): CFrame
	return CFrame.new(focus) * CFrame.fromEulerAnglesYXZ(pitch, yaw, 0) * CFrame.new(0, 0, distance)
end

export type Session = {
	-- Stops orbiting and hands the camera back.
	Stop: () -> (),
	-- W/A/S/D/Q/E held state, fed by the caller's own sunk key binding.
	SetKey: (keyCode: Enum.KeyCode, down: boolean) -> (),
	-- Re-centres on whatever the focus provider says now.
	Refocus: () -> (),
}

local PAN_KEYS: { [Enum.KeyCode]: Vector3 } = {
	[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
	[Enum.KeyCode.E] = Vector3.new(0, 1, 0),
	[Enum.KeyCode.Q] = Vector3.new(0, -1, 0),
}
PlacementCamera.PanKeys = PAN_KEYS

-- Takes the camera, orbiting whatever `focusOf()` returns at the start (and on each Refocus).
function PlacementCamera.Start(focusOf: () -> Vector3?): Session
	local camera = Workspace.CurrentCamera
	local trove = Trove.New()
	local previousType = camera.CameraType

	local focus = focusOf() or camera.Focus.Position
	local yaw, pitch, distance = PlacementCamera.AnglesFrom(camera.CFrame, focus)
	local held: { [Enum.KeyCode]: boolean } = {}

	ShiftLockCamera.SetInputSuspended(SUSPEND_OWNER, true)
	trove:Add(function()
		ShiftLockCamera.SetInputSuspended(SUSPEND_OWNER, false)
	end)
	camera.CameraType = Enum.CameraType.Scriptable
	trove:Add(function()
		-- Back to whatever it was (Custom, in every normal case); the stock camera re-finds the character.
		camera.CameraType = if previousType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else previousType
	end)

	trove:Connect(UserInputService.InputChanged, function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		distance = math.clamp(
			distance * (1 - ZOOM_STEP * input.Position.Z),
			PlacementCamera.DistanceLimits.Min,
			PlacementCamera.DistanceLimits.Max
		)
	end)

	RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Last.Value + 2, function(deltaTime: number)
		local orbiting = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
		local panning = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3)
		-- Locked only while dragging the view: the rest of the time the cursor is for the handles.
		UserInputService.MouseBehavior = if orbiting or panning
			then Enum.MouseBehavior.LockCurrentPosition
			else Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true

		local scale = distance / 10
		local view = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
		local delta = UserInputService:GetMouseDelta()
		if orbiting then
			yaw -= delta.X * ORBIT_SENSITIVITY
			pitch = math.clamp(pitch - delta.Y * ORBIT_SENSITIVITY, -MAX_PITCH, MAX_PITCH)
		elseif panning then
			focus += (view.RightVector * -delta.X + view.UpVector * delta.Y) * DRAG_PAN_PER_PIXEL * scale
		end

		local move = Vector3.zero
		for keyCode, down in held do
			if down then
				move += PAN_KEYS[keyCode]
			end
		end
		if move.Magnitude > 0 then
			-- Horizontal pan follows the view's yaw only, so W moves along the ground, not into it.
			local flat = CFrame.fromEulerAnglesYXZ(0, yaw, 0)
			local worldMove = flat:VectorToWorldSpace(Vector3.new(move.X, 0, move.Z)) + Vector3.new(0, move.Y, 0)
			focus += worldMove.Unit * KEY_PAN_SPEED * scale * deltaTime
		end

		local frame = PlacementCamera.Frame(focus, yaw, pitch, distance)
		camera.CFrame = frame
		camera.Focus = CFrame.new(focus)
	end)
	trove:Add(function()
		RunService:UnbindFromRenderStep(STEP_NAME)
	end)

	return {
		Stop = function()
			trove:Clean()
		end,
		SetKey = function(keyCode: Enum.KeyCode, down: boolean)
			if PAN_KEYS[keyCode] then
				held[keyCode] = down
			end
		end,
		Refocus = function()
			local target = focusOf()
			if target then
				focus = target
			end
		end,
	}
end

return PlacementCamera
