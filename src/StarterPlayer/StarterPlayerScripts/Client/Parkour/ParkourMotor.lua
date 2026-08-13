--!strict
--[[
	ParkourMotor.lua

	Owns: the ONLY place the parkour framework writes to the character's body. Every state describes
	what it wants through a ParkourTypes.MotorCommand and this module commits it -- the constraint
	rig, the anchored CFrame path, the facing, the crouch, and the teardown that puts everything back.

	This is the structural answer to the design's "allow movement abilities and combat abilities to
	coexist without the two systems constantly fighting over character velocity." Fifteen state
	modules writing AssemblyLinearVelocity directly is how that fight starts; fifteen state modules
	filling in one struct that one applier commits is how it is prevented. It is the same
	architectural role Client/FX/FOVOffset.lua plays for FieldOfView and CameraOffsetComposer.lua
	plays for CameraOffset, applied to the character instead of the camera.

	THREE DRIVE MODES, and what each one is actually for:
	  * "Humanoid"  -- hands the body back to Roblox's own character controller. The motor's entire
	                   job here is TEARDOWN: no rig, no anchor, AutoRotate and HipHeight restored.
	                   Ordinary walking/sprinting/jumping/falling all run this way, which is what
	                   keeps stairs, slope walking, ladders, seats, and the engine's own jump feeling
	                   exactly like stock Roblox rather than like a reimplementation of it.
	  * "Velocity"  -- a LinearVelocity constraint drives the assembly at a commanded world velocity,
	                   with gravity optionally cancelled. Real collision still applies, so a slide
	                   into a wall stops at the wall. Used for slide, wall-run, roll, wall-jump.
	  * "Kinematic" -- the root is ANCHORED and CFrame-driven along an authored path. Used only for
	                   vault/mantle/ledge-climb, where the traversal must be guaranteed to end exactly
	                   on top of the thing it claimed it would. Anchoring the local character's root
	                   for a few hundred milliseconds is the same technique Client/DevMenu/
	                   FlightController.lua's noclip mode already ships (see syncCollideMode's own
	                   header for why an unanchored part still accrues a physics step of gravity
	                   between writes and therefore sags); the exit always unanchors and injects the
	                   traversal's exit velocity, so the body never lands anchored.

	SERVER RELATIONSHIP: this module never writes Humanoid.WalkSpeed. That property belongs to
	Server/Combat/Movement.ComputeDesiredWalkSpeed, which runs every server Heartbeat and would
	overwrite anything written here within a frame. Instead, the server stands its own resolver down
	for the duration of an owned action (the ParkourVelocityOwned Attribute -> the resolver returns 0)
	and honors a decaying post-action momentum floor (ParkourSpeedFloor) -- both stamped by
	Server/Systems/ParkourSystem.lua off the client's action reports. Owning velocity and owning
	WalkSpeed are therefore never simultaneous, in either direction, by construction.

	Does not own: deciding which mode to use or what velocity to command (the State modules), any
	camera or animation concern, or any network traffic.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

type MotorCommand = ParkourTypes.MotorCommand
type DriveMode = ParkourTypes.DriveMode

local logger = Logger.scope("ParkourMotor")

local ParkourMotor = {}

-- Own instance names, distinct from Client/DevMenu/FlightPhysics.lua's Flight* set and
-- Server/Combat/RagdollController.lua's AirComboHold* set, so all three rigs can coexist on one
-- rootPart without colliding -- the same naming discipline FlightPhysics.lua's own header describes,
-- extended to a third rig.
local ATTACHMENT_NAME = "ParkourAttachment"
local VELOCITY_DRIVE_NAME = "ParkourVelocityDrive"
local ORIENTATION_DRIVE_NAME = "ParkourOrientationDrive"
local GRAVITY_CANCEL_NAME = "ParkourGravityCancel"

-- Large-but-finite, same reasoning as Constants.Flight.VelocityDriveMaxForce's own header: too low
-- and the character's own weight fights the drive (a wall-run sags), too high and wall contact
-- reads as a violent stop rather than a controlled halt.
local VELOCITY_DRIVE_MAX_FORCE = 90000
local ORIENTATION_MAX_TORQUE = 60000
-- How fast commanded facing converges, in the AlignOrientation's own responsiveness units. High
-- enough that a wall-run's facing snaps along the wall within a couple of frames without the
-- rigid-mode jitter RigidityEnabled would introduce.
local ORIENTATION_RESPONSIVENESS = 60

-- No `character` local: everything this module does reaches the body through the Humanoid or the root
-- part, and holding a Model reference it never reads would be one more thing to remember to clear on
-- teardown for no benefit.
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

-- The mode committed on the previous frame -- transitions between modes are where all the setup and
-- teardown happens, so the applier only pays for a mode change when one actually occurs.
local activeMode: DriveMode = "Humanoid"

-- Captured at the moment this module first takes the body, restored when it gives it back. Captured
-- rather than assumed because both are legitimately owned by other systems: HipHeight is a rig
-- property that varies per avatar, and AutoRotate belongs to Client/Camera/ShiftLockCamera.lua while
-- shift lock is engaged (that module writes it false on engage and true on release). Capturing means
-- a parkour action taken while shift-locked restores `false`, not a hardcoded `true` that would
-- silently break shift lock for the rest of the life.
local capturedHipHeight: number? = nil
local capturedAutoRotate: boolean? = nil
local appliedHipHeightDelta = 0

-- Reused command struct handed to the states each frame. Reset by BeginFrame, filled by whichever
-- state is active, committed by Apply. One table for the session -- see EnvironmentProbe.lua's own
-- RESULT TABLES note for the same reasoning.
local command: MotorCommand = {
	Mode = "Humanoid",
	Velocity = Vector3.zero,
	CancelGravity = false,
	DesiredSpeed = 0,
	TargetCFrame = nil,
	FaceDirection = nil,
	HipHeightDelta = 0,
}

local function findAttachment(part: BasePart): Attachment
	local existing = part:FindFirstChild(ATTACHMENT_NAME)
	if existing and existing:IsA("Attachment") then
		return existing
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = ATTACHMENT_NAME
	attachment.Parent = part
	return attachment
end

local function ensureRig(part: BasePart): ()
	local attachment = findAttachment(part)

	if not part:FindFirstChild(VELOCITY_DRIVE_NAME) then
		local drive = Instance.new("LinearVelocity")
		drive.Name = VELOCITY_DRIVE_NAME
		drive.Attachment0 = attachment
		drive.RelativeTo = Enum.ActuatorRelativeTo.World
		drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		drive.ForceLimitMode = Enum.ForceLimitMode.Magnitude
		drive.MaxForce = VELOCITY_DRIVE_MAX_FORCE
		drive.VectorVelocity = Vector3.zero
		drive.Parent = part
	end

	if not part:FindFirstChild(ORIENTATION_DRIVE_NAME) then
		local drive = Instance.new("AlignOrientation")
		drive.Name = ORIENTATION_DRIVE_NAME
		drive.Attachment0 = attachment
		-- OneAttachment mode already interprets `CFrame` in world space, which is exactly what the
		-- callers want. There is deliberately NO `RelativeTo` write here: that property exists on
		-- LinearVelocity and VectorForce (both set below/above) but NOT on AlignOrientation, and
		-- assigning it throws "RelativeTo is not a valid member of AlignOrientation" -- inside rig
		-- creation, so the whole movement frame aborts and slide/wall-run silently never run. Found in
		-- a live playtest; the identical line in Client/DevMenu/FlightPhysics.lua (which this rig was
		-- modelled on) has the same latent bug and is fixed alongside it.
		drive.Mode = Enum.OrientationAlignmentMode.OneAttachment
		-- Non-rigid: a rigid alignment fights every collision impulse and reads as the character
		-- vibrating against a wall. Same setting and same reason as FlightPhysics.lua's own rig.
		drive.RigidityEnabled = false
		drive.MaxTorque = ORIENTATION_MAX_TORQUE
		drive.Responsiveness = ORIENTATION_RESPONSIVENESS
		drive.CFrame = part.CFrame - part.CFrame.Position
		drive.Parent = part
	end
end

local function destroyRig(part: BasePart): ()
	for _, name in { VELOCITY_DRIVE_NAME, ORIENTATION_DRIVE_NAME, GRAVITY_CANCEL_NAME, ATTACHMENT_NAME } do
		local instance = part:FindFirstChild(name)
		if instance then
			instance:Destroy()
		end
	end
end

-- Gravity cancellation is created and destroyed per-frame-need rather than created once and toggled,
-- because a lingering zero-force VectorForce is one more thing that can be left behind by a state
-- that exits abnormally (a respawn mid-wall-run). Creation is cheap; a character floating because a
-- force outlived its owner is not.
local function setGravityCancel(part: BasePart, enabled: boolean): ()
	local existing = part:FindFirstChild(GRAVITY_CANCEL_NAME)
	if not enabled then
		if existing then
			existing:Destroy()
		end
		return
	end
	if existing and existing:IsA("VectorForce") then
		-- AssemblyMass can change mid-life (an accessory added, a tool equipped), so the force is
		-- recomputed rather than trusted from creation time.
		existing.Force = Vector3.new(0, part.AssemblyMass * Workspace.Gravity, 0)
		return
	end
	local force = Instance.new("VectorForce")
	force.Name = GRAVITY_CANCEL_NAME
	force.Attachment0 = findAttachment(part)
	force.ApplyAtCenterOfMass = true
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.Force = Vector3.new(0, part.AssemblyMass * Workspace.Gravity, 0)
	force.Parent = part
end

local function captureRestorables(currentHumanoid: Humanoid): ()
	if capturedHipHeight == nil then
		capturedHipHeight = currentHumanoid.HipHeight
	end
	if capturedAutoRotate == nil then
		capturedAutoRotate = currentHumanoid.AutoRotate
	end
end

local function restoreRestorables(currentHumanoid: Humanoid): ()
	if capturedHipHeight ~= nil then
		currentHumanoid.HipHeight = capturedHipHeight
		capturedHipHeight = nil
	end
	if capturedAutoRotate ~= nil then
		currentHumanoid.AutoRotate = capturedAutoRotate
		capturedAutoRotate = nil
	end
	appliedHipHeightDelta = 0
end

-- Binds a freshly-spawned character. Any rig left on a previous character dies with it, so this only
-- has to reset this module's own bookkeeping.
-- `nextCharacter` is accepted but not stored -- see the `humanoid` local's own note. It stays in the
-- signature so every Bind* entry point in this framework (EnvironmentProbe, ParkourMotor,
-- ParkourAnimator) takes the same arguments and the controller's bind block reads as one operation
-- rather than three subtly different ones.
function ParkourMotor.BindCharacter(_nextCharacter: Model, nextHumanoid: Humanoid, nextRootPart: BasePart): ()
	humanoid = nextHumanoid
	rootPart = nextRootPart
	activeMode = "Humanoid"
	capturedHipHeight = nil
	capturedAutoRotate = nil
	appliedHipHeightDelta = 0
end

-- Hands the body back unconditionally: rig destroyed, anchor cleared, HipHeight/AutoRotate restored.
-- Called when the framework is disabled, when combat takes the body, and on character teardown --
-- every path that stops the per-frame Apply from running must go through here, or the character can
-- be left anchored in mid-air with a stale velocity constraint, which is unrecoverable without a
-- respawn.
function ParkourMotor.Release(): ()
	local part = rootPart
	if part then
		if part.Anchored then
			part.Anchored = false
		end
		destroyRig(part)
	end
	local currentHumanoid = humanoid
	if currentHumanoid then
		restoreRestorables(currentHumanoid)
	end
	activeMode = "Humanoid"
end

function ParkourMotor.Unbind(): ()
	ParkourMotor.Release()
	humanoid = nil
	rootPart = nil
end

-- Resets the shared command to a neutral Humanoid-driven frame and returns it for the active state
-- to fill in. A state that writes nothing therefore hands the body back to the engine, which is the
-- correct default for a state that has nothing to say (Idle, Walking, Falling) and a safe failure
-- mode for one that errors partway through filling it in.
function ParkourMotor.BeginFrame(): MotorCommand
	command.Mode = "Humanoid"
	command.Velocity = Vector3.zero
	command.CancelGravity = false
	command.DesiredSpeed = 0
	command.TargetCFrame = nil
	command.FaceDirection = nil
	command.HipHeightDelta = 0
	return command
end

local function applyFacing(part: BasePart, faceDirection: Vector3?): ()
	if not faceDirection then
		return
	end
	local flat = ParkourMath.Flatten(faceDirection)
	if flat.Magnitude < 1e-3 then
		return
	end
	local drive = part:FindFirstChild(ORIENTATION_DRIVE_NAME)
	if drive and drive:IsA("AlignOrientation") then
		drive.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
	end
end

local function applyHipHeight(currentHumanoid: Humanoid, delta: number): ()
	if delta == appliedHipHeightDelta then
		return
	end
	local baseHipHeight = capturedHipHeight
	if baseHipHeight == nil then
		return
	end
	-- Floored so a large authored delta on a short rig can never invert hip height, which drops the
	-- character through the floor rather than crouching them.
	currentHumanoid.HipHeight = math.max(baseHipHeight - delta, 0.1)
	appliedHipHeightDelta = delta
end

-- Commits this frame's command. Returns false without touching anything when the server currently
-- owns the body -- the RootControlLocked Attribute is set by CombatSystem.syncRootControlLocked
-- while a finisher/DashPunch ragdoll is tumbling the character or RagdollController.HoldAloft has an
-- AlignPosition pin on it, and writing velocity underneath either of those is the exact "two systems
-- fighting over character velocity" failure this framework exists to avoid. Same Attribute, same
-- check, same reasoning as Client/DevMenu/FlightController.lua's own rootControlLocked gate.
function ParkourMotor.Apply(): boolean
	local part = rootPart
	local currentHumanoid = humanoid
	if not part or not currentHumanoid or not part.Parent then
		return false
	end
	if currentHumanoid:GetAttribute(Constants.Attributes.RootControlLocked) == true then
		if activeMode ~= "Humanoid" then
			ParkourMotor.Release()
		end
		return false
	end

	local mode = command.Mode

	if mode == "Humanoid" then
		if activeMode ~= "Humanoid" then
			-- Leaving an owned mode: unanchor first, then hand the traversal's exit velocity to the
			-- physics engine directly. Order matters -- writing AssemblyLinearVelocity on an anchored
			-- part is silently discarded, which is what turns a vault into a dead stop.
			if part.Anchored then
				part.Anchored = false
			end
			if command.Velocity.Magnitude > 1e-3 then
				part.AssemblyLinearVelocity = command.Velocity
			end
			destroyRig(part)
			restoreRestorables(currentHumanoid)
			activeMode = "Humanoid"
		end
		return true
	end

	captureRestorables(currentHumanoid)

	if mode == "Velocity" then
		if part.Anchored then
			part.Anchored = false
		end
		ensureRig(part)
		setGravityCancel(part, command.CancelGravity)
		local drive = part:FindFirstChild(VELOCITY_DRIVE_NAME)
		if drive and drive:IsA("LinearVelocity") then
			drive.VectorVelocity = command.Velocity
		end
		-- AutoRotate off while the orientation drive owns facing: the two write the same rotation
		-- from different sources every frame and visibly fight when both are live.
		currentHumanoid.AutoRotate = false
		applyFacing(part, command.FaceDirection)
		applyHipHeight(currentHumanoid, command.HipHeightDelta)
		activeMode = "Velocity"
		return true
	end

	-- Kinematic.
	local target = command.TargetCFrame
	if not target then
		-- A kinematic frame with no target is a state bug. Refusing (rather than anchoring the
		-- character in place with no path) keeps the failure recoverable: the body simply keeps
		-- whatever it was doing for a frame.
		logger:warn("Kinematic motor frame with no TargetCFrame -- ignoring")
		return false
	end
	-- The rig is torn down for kinematic mode: an anchored part ignores constraints anyway, and a
	-- LinearVelocity left parented to an anchored part re-engages the instant the anchor clears, one
	-- frame before the exit velocity is written.
	destroyRig(part)
	if not part.Anchored then
		part.Anchored = true
	end
	currentHumanoid.AutoRotate = false
	part.CFrame = target
	applyHipHeight(currentHumanoid, command.HipHeightDelta)
	activeMode = "Kinematic"
	return true
end

-- One-shot velocity write, for the impulses that are genuinely instantaneous rather than a mode: a
-- coyote-time jump (the character is already airborne, so Humanoid:ChangeState cannot produce the
-- jump), a buffered jump fired on the landing frame, and the launch of a slide-jump. Refused while
-- the root is anchored (a kinematic traversal owns the body) and while the server holds root
-- control, for the same reasons Apply refuses.
--
-- Deliberately NOT routed through the per-frame command struct: an impulse is a discrete event that
-- happens between frames, and expressing it as a frame's worth of commanded velocity would make it
-- last exactly one frame of whatever length the client happens to be running at.
function ParkourMotor.ApplyImpulse(velocity: Vector3): boolean
	local part = rootPart
	local currentHumanoid = humanoid
	if not part or not currentHumanoid or not part.Parent or part.Anchored then
		return false
	end
	if currentHumanoid:GetAttribute(Constants.Attributes.RootControlLocked) == true then
		return false
	end
	part.AssemblyLinearVelocity = velocity
	return true
end

-- Requests a jump through Roblox's own character controller -- the correct path whenever the
-- character is genuinely grounded, because it produces the engine's own Jumping state transition
-- (which Server/Combat/Movement.ComputeGenuineJumpAirborne reads to credit a genuine jump, and which
-- CombatClient.lua's finisher jump-suppression gates on). Returns false when jumping is currently
-- disabled -- CombatClient disables the Jumping state through an M1 combo so the 4th press throws an
-- Uppercut instead, and the parkour system must honor that rather than jumping anyway through a
-- different code path.
function ParkourMotor.RequestHumanoidJump(): boolean
	local currentHumanoid = humanoid
	if not currentHumanoid then
		return false
	end
	if not currentHumanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
		return false
	end
	currentHumanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	return true
end

-- Whether a jump is currently permitted at all, without performing one. Lets a state's CanEnter stay
-- a pure predicate while still respecting the combat layer's jump suppression.
function ParkourMotor.IsJumpEnabled(): boolean
	local currentHumanoid = humanoid
	return currentHumanoid ~= nil and currentHumanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
end

-- Which mode was last committed -- read by the debug overlay and by ParkourController when deciding
-- whether a state change needs a server ownership report.
function ParkourMotor.GetActiveMode(): DriveMode
	return activeMode
end

return ParkourMotor
