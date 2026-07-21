--!strict
--[[
	FlightPhysics.lua

	Owns: the Collide-mode constraint rig for the dev-menu flight feature -- a `LinearVelocity` +
	`AlignOrientation` pair (plus a gravity-cancelling `VectorForce`, same formula
	Server/Combat/RagdollController.lua's ensureGravityCancel uses) that drives the flying
	character's rootPart through REAL Roblox physics, so it genuinely stops at walls/floors instead
	of bypassing collision the way Noclip mode's raw CFrame writes do. Client-side by design: flight
	is already fully client-trusted (CombatSystem.SetPlayerFlying's own header: "same trust level as
	WalkSpeed itself"), and whichever client has `Flying=true` already owns network authority over
	its own unanchored parts -- there is no adversarial relationship here to guard against the way
	RagdollController's `SetNetworkOwner(nil)` does for combat knockback, so no server module is
	needed for this half of the feature.

	Uses its OWN instance names (FlightAttachment/FlightGravityCancel/FlightVelocityDrive/
	FlightOrientationDrive), distinct from RagdollController's AirComboHold* set, so the two rigs
	never collide if a flying admin is also somehow mid-air-combo on the same rootPart.

	Does not own: the momentum/banking MATH (Shared/FlightMath.lua computes the velocity/orientation
	FlightController.lua passes in here), the Noclip-mode branch (a plain CFrame write, no constraints
	at all), or deciding which mode is active (FlightController.lua reads the "FlyCollide" Humanoid
	Attribute and calls EnterCollideMode/ExitCollideMode on transitions).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

local FlightPhysics = {}

local ATTACHMENT_NAME = "FlightAttachment"
local GRAVITY_CANCEL_NAME = "FlightGravityCancel"
local VELOCITY_DRIVE_NAME = "FlightVelocityDrive"
local ORIENTATION_DRIVE_NAME = "FlightOrientationDrive"

-- Large-but-finite rather than math.huge: too low and the character's own momentum/gravity fights
-- the drive (sluggish, sinks), too high and wall contact reads as a violent stop instead of a
-- controlled halt. Starting point only -- flagged as a Studio-tune item in the design plan. Now
-- Constants.Flight.VelocityDriveMaxForce -- see that field's own header in Constants.lua.
local VELOCITY_DRIVE_MAX_FORCE = Constants.Flight.VelocityDriveMaxForce

local function findAttachment(rootPart: BasePart): Attachment?
	local existing = rootPart:FindFirstChild(ATTACHMENT_NAME)
	if existing and existing:IsA("Attachment") then
		return existing
	end
	return nil
end

-- Idempotent: safe to call every time Collide mode engages, even if a stale rig from an earlier
-- flight session somehow lingered (it shouldn't -- ExitCollideMode tears everything down -- but a
-- fresh rootPart on respawn never has one anyway).
function FlightPhysics.EnterCollideMode(rootPart: BasePart): ()
	local attachment = findAttachment(rootPart)
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = ATTACHMENT_NAME
		attachment.Parent = rootPart
	end

	if not rootPart:FindFirstChild(GRAVITY_CANCEL_NAME) then
		local gravityCancel = Instance.new("VectorForce")
		gravityCancel.Name = GRAVITY_CANCEL_NAME
		gravityCancel.Attachment0 = attachment
		gravityCancel.ApplyAtCenterOfMass = true
		gravityCancel.RelativeTo = Enum.ActuatorRelativeTo.World
		gravityCancel.Force = Vector3.new(0, rootPart.AssemblyMass * Workspace.Gravity, 0)
		gravityCancel.Parent = rootPart
	end

	if not rootPart:FindFirstChild(VELOCITY_DRIVE_NAME) then
		local velocityDrive = Instance.new("LinearVelocity")
		velocityDrive.Name = VELOCITY_DRIVE_NAME
		velocityDrive.Attachment0 = attachment
		velocityDrive.RelativeTo = Enum.ActuatorRelativeTo.World
		velocityDrive.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		velocityDrive.ForceLimitMode = Enum.ForceLimitMode.Magnitude
		velocityDrive.MaxForce = VELOCITY_DRIVE_MAX_FORCE
		velocityDrive.VectorVelocity = Vector3.zero
		velocityDrive.Parent = rootPart
	end

	if not rootPart:FindFirstChild(ORIENTATION_DRIVE_NAME) then
		local orientationDrive = Instance.new("AlignOrientation")
		orientationDrive.Name = ORIENTATION_DRIVE_NAME
		orientationDrive.Attachment0 = attachment
		orientationDrive.Mode = Enum.OrientationAlignmentMode.OneAttachment
		orientationDrive.RelativeTo = Enum.ActuatorRelativeTo.World
		orientationDrive.RigidityEnabled = false
		orientationDrive.MaxTorque = math.huge
		orientationDrive.CFrame = rootPart.CFrame - rootPart.CFrame.Position
		orientationDrive.Parent = rootPart
	end
end

function FlightPhysics.ExitCollideMode(rootPart: BasePart): ()
	local gravityCancel = rootPart:FindFirstChild(GRAVITY_CANCEL_NAME)
	if gravityCancel then
		gravityCancel:Destroy()
	end
	local velocityDrive = rootPart:FindFirstChild(VELOCITY_DRIVE_NAME)
	if velocityDrive then
		velocityDrive:Destroy()
	end
	local orientationDrive = rootPart:FindFirstChild(ORIENTATION_DRIVE_NAME)
	if orientationDrive then
		orientationDrive:Destroy()
	end
	local attachment = rootPart:FindFirstChild(ATTACHMENT_NAME)
	if attachment then
		attachment:Destroy()
	end
end

-- Sets this frame's commanded world-space velocity. No-op (not an error) if Collide mode isn't
-- currently entered -- a caller that races a mode transition just loses one frame of drive, same
-- "a missing preset degrades to nothing" tolerance the rest of this codebase's presentation layer
-- uses.
function FlightPhysics.SetCommandedVelocity(rootPart: BasePart, velocity: Vector3): ()
	local velocityDrive = rootPart:FindFirstChild(VELOCITY_DRIVE_NAME)
	if velocityDrive and velocityDrive:IsA("LinearVelocity") then
		velocityDrive.VectorVelocity = velocity
	end
end

-- Sets this frame's commanded world-space orientation (bank/pitch/facing) -- only the rotation
-- matters here, AlignOrientation never touches position.
function FlightPhysics.SetCommandedOrientation(rootPart: BasePart, cframe: CFrame): ()
	local orientationDrive = rootPart:FindFirstChild(ORIENTATION_DRIVE_NAME)
	if orientationDrive and orientationDrive:IsA("AlignOrientation") then
		orientationDrive.CFrame = cframe - cframe.Position
	end
end

return FlightPhysics
