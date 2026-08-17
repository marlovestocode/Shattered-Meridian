--!strict
--[[
	ParkourMotor.lua

	Owns: the ONLY place the parkour framework writes to the character's body. Every state describes
	what it wants through a ParkourTypes.MotorCommand and this module commits it -- the constraint
	rig, the authored path, the facing, the crouch, and the teardown that puts everything back.

	This is the structural answer to the design's "allow movement abilities and combat abilities to
	coexist without the two systems constantly fighting over character velocity." Fifteen state
	modules writing AssemblyLinearVelocity directly is how that fight starts; fifteen state modules
	filling in one struct that one applier commits is how it is prevented. It is the same
	architectural role Client/FX/FOVOffset.lua plays for FieldOfView and CameraOffsetComposer.lua
	plays for CameraOffset, applied to the character instead of the camera.

	THREE DRIVE MODES, and what each one is actually for:
	  * "Humanoid"  -- hands the body back to Roblox's own character controller. The motor's entire
	                   job here is TEARDOWN: no rig, AutoRotate and HipHeight restored. Ordinary
	                   walking/sprinting/jumping/falling all run this way, which is what keeps
	                   stairs, slope walking, ladders, seats, and the engine's own jump feeling
	                   exactly like stock Roblox rather than like a reimplementation of it.
	  * "Velocity"  -- a LinearVelocity constraint drives the assembly at a commanded world velocity,
	                   with gravity optionally cancelled. Real collision still applies, so a slide
	                   into a wall stops at the wall. Used for slide, wall-run, roll, wall-jump.
	  * "Kinematic" -- a RIGID AlignPosition (RigidityEnabled = true) drives the root to a commanded
	                   world position every physics step, exactly, along an authored path. Used only
	                   for vault/mantle/ledge-climb/ledge-hang, where the traversal must be guaranteed
	                   to end exactly on top of the thing it claimed it would.
	                   NOT anchored, deliberately -- this mode used to anchor the root and write its
	                   CFrame directly, which drove the local client's own view correctly but is
	                   invisible to everyone else: Roblox does not replicate CFrame writes on an
	                   anchored part at all, because anchored parts have no network owner and never
	                   enter the physics replicator. Every other client watched the traversal freeze
	                   in place for its whole duration and then jump to the exit position the instant
	                   the state ended and the root unanchored -- exactly the "went through the wall /
	                   looks laggy" symptom this rewrite exists to fix. RigidityEnabled bypasses
	                   MaxForce/MaxVelocity/Responsiveness and solves position exactly every step (the
	                   same "kinematic-through-a-constraint" guarantee an anchored write gave), but the
	                   root stays a real, unanchored, network-owned assembly the whole time, so it rides
	                   the exact replication path ordinary walking and Velocity mode already use for
	                   free -- see Client/FX/CombatAnimator.lua's own note on animation replicating off
	                   the OWNING player's Animator for the same "network ownership is what carries it"
	                   principle, applied here to position instead of a track.

	TAKING THE BODY IS A PAIRED OPERATION. Owning a character means more than driving it: it means
	holding four things that belong to somebody else -- HipHeight, AutoRotate, two Humanoid states, and
	(through the ParkourFacingOwned Attribute) Client/Camera/ShiftLockCamera.lua's own per-frame yaw
	write. captureRestorables takes all four and restoreRestorables puts all four back, and the ONLY
	thing that says which side of that pair we are on is the `ownsBody` flag -- deliberately not the
	drive mode, which is a different question with a different answer on the frames where it matters.
	See that flag's own header for the failure that taught the difference.

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
local POSITION_DRIVE_NAME = "ParkourPositionDrive"
local ORIENTATION_DRIVE_NAME = "ParkourOrientationDrive"
local GRAVITY_CANCEL_NAME = "ParkourGravityCancel"

-- Large-but-finite, same reasoning as Constants.Flight.VelocityDriveMaxForce's own header: too low
-- and the character's own weight fights the drive (a wall-run sags), too high and wall contact
-- reads as a violent stop rather than a controlled halt.
local VELOCITY_DRIVE_MAX_FORCE = 90000
-- Raised from 60000, and the reason is animation rather than tuning taste.
--
-- An AlignOrientation commands the whole rotation, upright included, so on paper a Velocity-driven
-- state can never tip. In practice it can, because the torque it has to win against is not constant: an
-- animated rig moves real mass away from the root's own axis (a slide clip lays the character out
-- almost horizontally), and the further that mass swings the longer the lever every collision impulse
-- gets to push on. 60000 held a neutral pose fine and lost to an animated one -- which is exactly the
-- shape of the reported bug, a slide that tumbles the character onto their head ONLY once a clip is
-- attached to it, and never without one.
--
-- Still deliberately finite and still non-rigid (see RigidityEnabled below): the goal is to win against
-- an animation's own mass, not to make the character an immovable object. Wall contact and collision
-- response stay soft.
local ORIENTATION_MAX_TORQUE = 280000
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

-- WHETHER THIS MODULE CURRENTLY HOLDS THE BODY'S RESTORABLES, tracked explicitly rather than inferred
-- from `activeMode`.
--
-- These two used to be assumed equivalent: captureRestorables runs for every non-Humanoid frame, and
-- the restore was gated on `activeMode ~= "Humanoid"`. They are not equivalent, because capture happens
-- BEFORE the mode branch that assigns activeMode, and that branch can refuse. When it did, the frame
-- left AutoRotate/HipHeight captured, the guarded Humanoid states disabled and -- worst of all --
-- ParkourFacingOwned raised, while activeMode still read "Humanoid". The next ordinary walking frame
-- then found `activeMode == "Humanoid"`, skipped the restore entirely, and nothing ever put any of it
-- back: Client/Camera/ShiftLockCamera.lua kept its yaw write suspended against an Attribute that would
-- now never fall, with AutoRotate still false underneath it, so the character could not turn at all for
-- the rest of the life. That is the reported "locked after a parkour move," and it self-healed only
-- when some LATER traversal happened to end through the restore path.
--
-- One flag, set by the capture and cleared by the restore, makes the pair symmetric by construction: it
-- is true exactly when there is something to put back, regardless of which mode -- or no mode -- the
-- frame went on to commit.
local ownsBody = false

-- THE HUMANOID STATES THIS MODULE STANDS DOWN WHILE IT OWNS THE BODY, and why owning velocity is not
-- enough on its own.
--
-- Roblox's Humanoid runs its own state machine underneath everything this framework does, and two of
-- its states are not descriptions of what the character is doing -- they are the engine TAKING the
-- character. FallingDown and Ragdoll drop the body to physics, spin it, and hand it to GettingUp, which
-- then plays its own animation and rotates the character upright over the better part of a second. From
-- inside this framework that is indistinguishable from the character spontaneously flipping onto their
-- head mid-slide, because that is precisely what it looks like.
--
-- The trigger is tipping past the Humanoid's own tolerance, and an animated slide reaches it easily:
-- the clip lays the rig out, the mass swings off the root's axis, one collision impulse tips it, and
-- the engine calls that a fall. The slide then ends as collateral damage -- a tipped root reads longer
-- on the ground probe's straight-down cast, contact is "lost", and Sliding hands off to Falling. That
-- is the whole reported failure, in order: flips onto their head, and the slide will not run down a
-- slope, and both only ever with a clip attached.
--
-- DELIBERATELY JUST THOSE TWO. PlatformStanding is conspicuously absent even though it also suspends
-- the Humanoid's own movement handling, because this codebase's ragdoll and flight paths both work by
-- setting Humanoid.PlatformStand (see Server/Combat/RagdollController.beginRagdoll and
-- Server/Systems/AdminActionSystem.SetFlying) -- disabling the state those depend on entering would be
-- this module quietly breaking two systems that already have a clean handover with it through the
-- RootControlLocked/Flying Attributes. GettingUp is absent for a simpler reason: with FallingDown
-- disabled there is no route into it.
--
-- Captured rather than assumed, and restored on release, for the same reason AutoRotate is: these are
-- legitimately owned by other systems, and writing back a hardcoded `true` would hand them a character
-- whose states they never set that way.
local GUARDED_HUMANOID_STATES = {
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
}
local capturedStateEnabled: { [Enum.HumanoidStateType]: boolean }? = nil

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

-- Shared between Velocity and Kinematic mode -- both need facing control, and both want the same
-- soft, non-rigid convergence (see RigidityEnabled below). A rigid orientation lock fights every
-- collision impulse and reads as the character vibrating against a wall; that is exactly as true
-- mid-vault as it is mid-wall-run, and the Bezier/Lerp paths in the Kinematic states already hold
-- one fixed facing for their whole duration (see States/Vaulting.lua/Mantling.lua/LedgeClimbing.lua/
-- LedgeHanging.lua Update -- travelDirection/facing is computed once at Enter, never per frame), so
-- there is nothing for a soft drive to visibly lag behind once it converges in the first couple of
-- frames.
local function ensureOrientationDrive(part: BasePart, attachment: Attachment): ()
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

local function ensureVelocityRig(part: BasePart): ()
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

	ensureOrientationDrive(part, attachment)
end

-- Built only for Kinematic mode -- see this file's own header for why a RIGID AlignPosition replaces
-- the anchored CFrame write that used to drive vault/mantle/ledge-climb/ledge-hang.
local function ensureKinematicRig(part: BasePart): ()
	local attachment = findAttachment(part)

	if not part:FindFirstChild(POSITION_DRIVE_NAME) then
		local drive = Instance.new("AlignPosition")
		drive.Name = POSITION_DRIVE_NAME
		drive.Attachment0 = attachment
		drive.Mode = Enum.PositionAlignmentMode.OneAttachment
		-- Rigid, unlike the velocity drive above: a vault/mantle/climb/hang has to end exactly where
		-- it claimed it would (see States/Vaulting.lua's own header on clipping the lip / landing on
		-- top instead of past / catching a corner). RigidityEnabled bypasses MaxForce, MaxVelocity and
		-- Responsiveness entirely and solves position exactly every physics step -- Roblox's own
		-- documented mechanism for kinematic-exact motion on a part that still has to stay unanchored
		-- to replicate. MaxForce/Responsiveness are therefore not set below: the engine ignores both
		-- while RigidityEnabled is true, and setting numbers that do nothing would just be a second,
		-- misleading place to look for the tuning that actually lives in the authored path itself
		-- (ParkourMath.TraversalEase/TraversalPoint and each state's own duration constant).
		drive.RigidityEnabled = true
		drive.Position = part.Position
		drive.Parent = part
	end

	ensureOrientationDrive(part, attachment)
end

local function destroyRig(part: BasePart): ()
	for _, name in
		{ VELOCITY_DRIVE_NAME, POSITION_DRIVE_NAME, ORIENTATION_DRIVE_NAME, GRAVITY_CANCEL_NAME, ATTACHMENT_NAME }
	do
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

-- Announces whether this module currently owns the character's ROTATION, via the Attribute
-- Client/Camera/ShiftLockCamera.lua watches (see Constants.Attributes.ParkourFacingOwned for why this
-- is an Attribute rather than a direct call). That module writes root.CFrame to camera yaw EVERY
-- render step while shift lock is engaged and has no idea parkour exists -- its only other guards are
-- the combat/flight Attributes -- so for the full duration of a traversal it contested this module's
-- own facing mechanism: the same AlignOrientation drive that now backs both Velocity and Kinematic
-- mode (see ensureOrientationDrive). It was being overwritten toward camera yaw every frame
-- underneath them.
--
-- Mirrored in a local so the Attribute is written only on the transitions. The capture path below runs
-- on EVERY owned frame, and an unguarded SetAttribute there would be a needless property write (and a
-- needless changed-signal round trip) sixty times a second for the whole traversal.
local facingOwned = false

local function setFacingOwned(currentHumanoid: Humanoid?, owned: boolean): ()
	if owned == facingOwned then
		return
	end
	facingOwned = owned
	if currentHumanoid then
		currentHumanoid:SetAttribute(Constants.Attributes.ParkourFacingOwned, owned)
	end
end

local function captureRestorables(currentHumanoid: Humanoid): ()
	ownsBody = true
	setFacingOwned(currentHumanoid, true)
	if capturedHipHeight == nil then
		capturedHipHeight = currentHumanoid.HipHeight
	end
	if capturedAutoRotate == nil then
		capturedAutoRotate = currentHumanoid.AutoRotate
	end
	-- Guarded once per period of ownership, not per frame: SetStateEnabled is a property write with a
	-- signal behind it, and the whole point of the `capturedStateEnabled == nil` test is that this runs
	-- on the transition into ownership rather than sixty times a second for its duration.
	if capturedStateEnabled == nil then
		local captured: { [Enum.HumanoidStateType]: boolean } = {}
		for _, stateType in GUARDED_HUMANOID_STATES do
			captured[stateType] = currentHumanoid:GetStateEnabled(stateType)
			currentHumanoid:SetStateEnabled(stateType, false)
		end
		capturedStateEnabled = captured
	end
end

-- ORDER IS LOAD-BEARING HERE, and it is the reverse of what it used to be.
--
-- setFacingOwned(false) is now the LAST thing this function does, because that write is not private:
-- Client/Camera/ShiftLockCamera.lua watches ParkourFacingOwned and, on the falling edge, reasserts
-- `AutoRotate = not engaged` -- deliberately, to repair the case where the player toggled shift lock
-- DURING a traversal and this module's capture therefore holds a value that is no longer correct (see
-- that handler's own comment).
--
-- With the release first, that repair was still correct and still ran -- and was then immediately
-- overwritten by the stale `capturedAutoRotate` write below it. Whether the clobber actually lands
-- depends on the place's SignalBehavior: under Deferred the handler resumes after this function
-- returns and wins, under Immediate it runs synchronously inside the SetAttribute call and loses. A
-- correctness property that flips on a place-level engine setting nobody in this repo sets explicitly
-- is not a property at all, so the order is now the one that is right under both: put every captured
-- value back FIRST, then hand rotation over, so the compensating handler always runs last and always
-- has the final say.
local function restoreRestorables(currentHumanoid: Humanoid): ()
	if capturedHipHeight ~= nil then
		currentHumanoid.HipHeight = capturedHipHeight
		capturedHipHeight = nil
	end
	if capturedAutoRotate ~= nil then
		currentHumanoid.AutoRotate = capturedAutoRotate
		capturedAutoRotate = nil
	end
	local captured = capturedStateEnabled
	if captured ~= nil then
		for stateType, wasEnabled in captured do
			currentHumanoid:SetStateEnabled(stateType, wasEnabled)
		end
		capturedStateEnabled = nil
	end
	appliedHipHeightDelta = 0
	ownsBody = false
	setFacingOwned(currentHumanoid, false)
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
	-- Dropped rather than restored: these belonged to the PREVIOUS character's Humanoid, which is either
	-- gone or about to be. Leaving the table populated would make the next capture believe the new
	-- character is already guarded and skip it, so the whole life would run unprotected -- the same
	-- stale-mirror failure `facingOwned` below is reset for.
	capturedStateEnabled = nil
	appliedHipHeightDelta = 0
	-- Dropped for the same reason capturedStateEnabled above is: it describes the PREVIOUS character, and
	-- a stale `true` here would make the first Humanoid frame of this life run a restore against values
	-- that were never captured on this Humanoid.
	ownsBody = false
	-- A fresh character owns its own rotation until this module takes it again. Written straight to the
	-- mirror rather than through setFacingOwned because the new Humanoid's Attribute is already unset --
	-- there is nothing to clear on it, only this module's memory of the PREVIOUS character to reset, and
	-- a stale `true` here would suppress the next real capture's write.
	facingOwned = false
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
	-- Repeated outside the humanoid guard on purpose (restoreRestorables clears it too, and the setter
	-- early-outs when it is already false). Release is reached on teardown paths where `humanoid` is
	-- already nil -- a respawn mid-traversal, most obviously -- and leaving the mirror stuck true there
	-- would mean the next character's first capture sees "already owned" and never writes the Attribute
	-- at all, so shift lock would stand its yaw down for that entire life. The
	-- unrecoverable-without-a-respawn class of failure this function exists to prevent, applied to
	-- facing. The Attribute itself needs no clearing on this path: it died with the old Humanoid.
	setFacingOwned(currentHumanoid, false)
	-- Same reasoning as the setFacingOwned repeat above, for the state guard: on a teardown path where
	-- `humanoid` is already nil there is nothing to restore the states ON, but the memory of having
	-- guarded them must not survive into the next character or its first capture is skipped.
	capturedStateEnabled = nil
	-- Same again for the ownership flag: on a teardown path where `humanoid` is already nil there is
	-- nothing to restore, but a flag left true would have the next character's first ordinary frame try
	-- to restore values belonging to a Humanoid that no longer exists.
	ownsBody = false
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
		-- `ownsBody` for the same reason the Humanoid branch below asks it: a body that was captured but
		-- never committed to a mode still has to be handed back when the server takes root control, and
		-- an activeMode-only test would walk straight past exactly that case.
		if activeMode ~= "Humanoid" or ownsBody then
			ParkourMotor.Release()
		end
		return false
	end

	local mode = command.Mode

	-- REFUSED BEFORE ANYTHING IS TAKEN, not partway through taking it. A kinematic frame with no target
	-- is a state bug (see the Kinematic branch below for what it would otherwise drive toward), and the
	-- refusal used to sit after captureRestorables had already raised ParkourFacingOwned and disabled the
	-- guarded Humanoid states -- so the bug's cost was not "one ignored frame" but a body left
	-- permanently half-owned. Validating first means the refusal is genuinely inert: nothing has been
	-- captured, nothing has been announced, and the body simply keeps doing what it was doing.
	if mode == "Kinematic" and command.TargetCFrame == nil then
		logger:warn("Kinematic motor frame with no TargetCFrame -- ignoring")
		return false
	end

	if mode == "Humanoid" then
		-- `ownsBody` rather than `activeMode` alone: the two can disagree (see that flag's own header),
		-- and when they do it is precisely the case where a restore is most needed and used to be
		-- skipped. Cheap to ask on every walking frame -- both are plain locals, and the body below runs
		-- only on a real hand-back.
		if activeMode ~= "Humanoid" or ownsBody then
			-- Leaving an owned mode: hand the traversal's exit velocity to the physics engine directly,
			-- then tear the rig down, in that order, within this same synchronous frame -- no physics
			-- step runs between the two, so there is no window for a still-parented drive to reassert
			-- itself over the velocity this line just wrote. `part.Anchored` is defensive rather than
			-- load-bearing now: nothing in this module anchors the root any more (see Kinematic below),
			-- but unconditionally clearing it costs nothing and keeps this a safe catch-all if some
			-- other system ever left the root anchored underneath this one.
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
		-- Defensive: a stale rigid AlignPosition left over from a Kinematic frame would fight the
		-- LinearVelocity drive below for control of position. Every real transition already tears this
		-- down via the Humanoid branch above (StateSupport.HandOff always hands off through a Humanoid
		-- frame first -- see that function's own header), so this should always be a no-op in practice;
		-- kept as a guard rather than an assumption for the same reason the Anchored check above is.
		local stalePositionDrive = part:FindFirstChild(POSITION_DRIVE_NAME)
		if stalePositionDrive then
			stalePositionDrive:Destroy()
		end
		ensureVelocityRig(part)
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

	-- Kinematic. The target was validated at the top of this function, before ownership was taken --
	-- see that check for why it cannot live here any more.
	local target = command.TargetCFrame :: CFrame
	if part.Anchored then
		part.Anchored = false
	end
	-- Kinematic never drives through the velocity rig -- a LinearVelocity or gravity-cancel force left
	-- over from a Velocity-driven frame would be one more thing fighting the rigid position lock below
	-- for control of the assembly. Same "should always be a no-op, kept as a guard" reasoning as the
	-- stale-position-drive check in the Velocity branch above.
	local staleVelocityDrive = part:FindFirstChild(VELOCITY_DRIVE_NAME)
	if staleVelocityDrive then
		staleVelocityDrive:Destroy()
	end
	setGravityCancel(part, false)
	ensureKinematicRig(part)
	currentHumanoid.AutoRotate = false
	local positionDrive = part:FindFirstChild(POSITION_DRIVE_NAME)
	if positionDrive and positionDrive:IsA("AlignPosition") then
		positionDrive.Position = target.Position
	end
	applyFacing(part, target.LookVector)
	applyHipHeight(currentHumanoid, command.HipHeightDelta)
	activeMode = "Kinematic"
	return true
end

-- One-shot velocity write, for the impulses that are genuinely instantaneous rather than a mode: a
-- coyote-time jump (the character is already airborne, so Humanoid:ChangeState cannot produce the
-- jump), a buffered jump fired on the landing frame, and the launch of a slide-jump. Refused while a
-- kinematic traversal owns the body and while the server holds root control, for the same reasons
-- Apply refuses.
--
-- Checked against `activeMode` rather than `part.Anchored` -- Kinematic mode no longer anchors the
-- root (see this file's own header), so Anchored can no longer stand in for "a kinematic traversal
-- owns this body" the way it used to. A RigidityEnabled AlignPosition would likely just overwrite
-- whatever this wrote on the very next physics step anyway, but refusing outright keeps this
-- function's contract the same as before: a kinematic traversal's ownership of the body cannot be
-- fought by a stray impulse, full stop, rather than "usually cannot."
--
-- Deliberately NOT routed through the per-frame command struct: an impulse is a discrete event that
-- happens between frames, and expressing it as a frame's worth of commanded velocity would make it
-- last exactly one frame of whatever length the client happens to be running at.
function ParkourMotor.ApplyImpulse(velocity: Vector3): boolean
	local part = rootPart
	local currentHumanoid = humanoid
	if not part or not currentHumanoid or not part.Parent or activeMode == "Kinematic" then
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
