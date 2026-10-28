--!strict
--[[
	CameraRotationComposer.lua

	Owns: the single writer of CONTINUOUS camera rotation -- every pitch, yaw or roll the view wears for as long as its
	cause holds (a lean into a turn, a wall-run tilt, a blimp's roll and sway, flight's bank), as named slots summed
	onto one rotation. The rotational sibling of FOVOffset and CameraOffsetComposer, which compose FieldOfView and
	CameraOffset the same way. CameraShake stays the owner of TRANSIENT rotation (a decaying noise on an impact): one is
	a decay that ends, the other a state that holds.

	WHY IT EXISTS. Four modules each multiplied their own rotation onto Camera.CFrame at their own priority, and only
	CameraShake took its rotation back off. The default camera reads its look direction back off Camera.CFrame, so
	whatever pitch or yaw is left on it becomes the next frame's starting point: BlimpCamera's turn sway and climb pitch
	were re-applied on top of themselves every frame, which spun the view through a whole turn and drifted it up a
	climb -- the blimp camera "not working". A pure roll does not move the look direction, so the wall-run tilt and
	flight's bank got away with it, except that a roll left under last frame's shake made CameraShake's undo a rotation
	about the wrong axes and baked a residue into the aim. Every continuous rotation now goes through here.

	APPLIED LAST, TAKEN BACK OFF FIRST, EXACTLY. The sum is post-multiplied onto the camera at the CameraRotation slot,
	after CameraShake's, so it is the last rotation on the frame's pose. At CameraRotationUndo, the first camera slot of
	the next frame and before CameraShakeUndo, the exact inverse of that CFrame is multiplied back on, which hands CameraShake a CFrame ending in
	its own rotation, as its undo expects, and hands the camera scripts the player's real look. Nothing between the two
	moves the look: the body copies the camera's yaw at CombatCameraBody, BEFORE this applies, so a blimp's
	sway or a lean never turns the body.

	Slots are Vector3s of radians: X pitch (positive looks up), Y yaw (positive looks left), Z roll (positive
	counter-clockwise from the player's seat) -- CFrame.Angles' own axes, composed once per frame as CFrame.Angles(X, Y, Z).

	Does not own: deciding WHEN to rotate or how far (each caller), the shake (CameraShake), the camera's position or FOV
	(CameraOffsetComposer, FOVOffset), the lock-on's steering of the player's look (CombatCamera, which moves the look on
	purpose and so is NOT undone), or the comfort settings that silence a caller's rotation (each caller zeroes its slot).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FrameOrder = require(script.Parent.Parent.Config.FrameOrder)

local logger = Logger.scope("CameraRotationComposer")

local RENDER_STEP_NAME = "CameraRotationCompose"
local UNDO_STEP_NAME = "CameraRotationUndo"

-- Below this on every axis the rotation is not worth a CFrame multiply (a fiftieth of a degree).
local REST_RADIANS = 3e-4

type Slot = {
	Current: Vector3,
	Target: Vector3,
	EaseSpeed: number?,
}

local CameraRotationComposer = {}

local slots: { [string]: Slot } = {}
local started = false

-- The rotation this module multiplied onto the camera last frame, and which camera it went on.
local applied: CFrame? = nil
local appliedCamera: Camera? = nil

-- Persistent named rotation (pitch, yaw, roll in radians). A positive easeSpeed has THIS module ease the slot toward the
-- target every frame (FlightMath.EaseAlpha); nil snaps to it, for a caller that already smoothed the value (a spring).
function CameraRotationComposer.SetContinuous(name: string, target: Vector3, easeSpeed: number?): ()
	local existing = slots[name]
	if existing then
		existing.Target = target
		existing.EaseSpeed = easeSpeed
		if not easeSpeed then
			existing.Current = target
		end
		return
	end
	slots[name] = {
		Current = if easeSpeed then Vector3.zero else target,
		Target = target,
		EaseSpeed = easeSpeed,
	}
end

-- Hard removal, no fade -- for teardown. A caller that wants a smooth release sets the slot to zero with an ease instead.
function CameraRotationComposer.ClearContinuous(name: string): ()
	slots[name] = nil
end

-- Advances every slot by `deltaTime` and returns the summed rotation. Separate from the render step so the composition
-- can be spec'd without a camera.
function CameraRotationComposer.Step(deltaTime: number): Vector3
	local total = Vector3.zero
	for _, slot in slots do
		local easeSpeed = slot.EaseSpeed
		if easeSpeed then
			slot.Current = slot.Current:Lerp(slot.Target, FlightMath.EaseAlpha(easeSpeed, deltaTime))
		else
			slot.Current = slot.Target
		end
		total += slot.Current
	end
	return total
end

-- The CFrame a summed rotation is applied as. Exposed so the spec can prove the undo is the exact inverse.
function CameraRotationComposer.RotationOf(total: Vector3): CFrame
	return CFrame.Angles(total.X, total.Y, total.Z)
end

-- Spec-only: every slot dropped.
function CameraRotationComposer.ResetForTesting(): ()
	table.clear(slots)
	applied = nil
	appliedCamera = nil
end

local function undoLastRotation(): ()
	local rotation = applied
	if rotation == nil then
		return
	end
	applied = nil
	local camera = appliedCamera
	appliedCamera = nil
	if camera ~= nil and camera == Workspace.CurrentCamera then
		camera.CFrame = camera.CFrame * rotation:Inverse()
	end
end

local function onRenderStep(deltaTime: number): ()
	local total = CameraRotationComposer.Step(deltaTime)
	if math.abs(total.X) < REST_RADIANS and math.abs(total.Y) < REST_RADIANS and math.abs(total.Z) < REST_RADIANS then
		return
	end
	-- Only the follow camera is rotated: every slot here is a nudge on the default camera's pose, and a Scriptable camera
	-- (the intro, a spectate, the placement tool) writes its own CFrame and must not wear a blimp's sway or a lean.
	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	local rotation = CameraRotationComposer.RotationOf(total)
	camera.CFrame = camera.CFrame * rotation
	applied = rotation
	appliedCamera = camera
end

-- Called once from Main.client.lua's boot sequence. Idempotent.
function CameraRotationComposer.Start(): ()
	if started then
		return
	end
	started = true
	RunService:BindToRenderStep(UNDO_STEP_NAME, FrameOrder.Priority("CameraRotationUndo"), undoLastRotation)
	RunService:BindToRenderStep(RENDER_STEP_NAME, FrameOrder.Priority("CameraRotation"), onRenderStep)
	logger:info("CameraRotationComposer started")
end

return CameraRotationComposer
