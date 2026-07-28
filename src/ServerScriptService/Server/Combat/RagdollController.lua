--!strict
--[[
	RagdollController.lua

	Owns: turning a combat character into a physics ragdoll and applying server-authoritative
	knockback (launch up / slam down) for CombatSystem's combo finishers (uppercut / downslam). A
	pure helper under Server/Combat/, the same role HitboxResolver plays for hit detection --
	CombatSystem drives it (LaunchAndRagdoll / SlamToGround to start, Update() from its own single
	Heartbeat to auto-recover expired ragdolls) and it owns no combat state of its own.

	Why server-authoritative: a player's character is network-owned by that player's client, so a bare
	velocity/CFrame write from the server is immediately overridden by the owner's own simulation.
	Before applying any knockback this module takes network ownership of every BasePart to the server
	(SetNetworkOwner(nil)) so the launch and the ragdoll simulate authoritatively and replicate to
	everyone (including the victim), then restores ownership to the player on recovery. Every
	ownership/physics call is pcall-guarded -- a character can die or despawn mid-ragdoll, and a
	failed SetNetworkOwner (e.g. a part that momentarily isn't in workspace) must never break the
	recover path or throw out of CombatSystem's hit resolution.

	Ragdoll shape (R15): every Motor6D except the ones touching the HumanoidRootPart (the Root joint,
	kept rigid so the character keeps one stable primary assembly for collision) is disabled and
	replaced with a BallSocketConstraint, and the Humanoid is put into PlatformStand + Physics state
	with GettingUp disabled so it stays limp for the duration. Recovery destroys the constraints,
	re-enables the Motor6Ds, and stands the Humanoid back up. An R6 rig (no per-limb joints worth
	swapping) falls back to a PlatformStand-only "stiff" knockdown -- still launched and downed, just
	not floppy -- so the finisher never errors on a non-R15 avatar.

	Does not own: the decision to ragdoll (CombatSystem's finisher logic decides that), the combo /
	finisher state (CombatState.ragdollExpiry mirrors this module's own timer so the action-lockout
	and the physical recovery stay in lockstep), or any gameplay validation. This module also never
	touches Humanoid.Health -- a ragdoll is a physical state, damage is CombatSystem's job.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Constants = require(ReplicatedStorage.Shared.Constants)

local RagdollController = {}

-- One live ragdoll. Keyed by the character Model in `active` below. `motors` are the Motor6Ds this
-- module disabled (to re-enable on recover); `created` are the Attachments/BallSocketConstraints it
-- made (to destroy on recover). `ownerPlayer` is who network ownership is restored to (nil = server-
-- owned for its whole life, e.g. a training dummy).
type ActiveRagdoll = {
	character: Model,
	humanoid: Humanoid,
	ownerPlayer: Player?,
	expiry: number,
	motors: { Motor6D },
	created: { Instance },
	savedPlatformStand: boolean,
	savedAutoRotate: boolean,
}

local active: { [Model]: ActiveRagdoll } = {}

-- Air combo hold (RagdollController.HoldAloft below) -- shared by BOTH the target's own hover pin
-- AND the attacker's standoff pin (ChaseTarget/HoldAloft used to be two separate mechanisms; see
-- HoldAloft's own header for why they collapsed into one). One pending auto-release thread per held
-- rootPart, so a second HoldAloft call on the same part (a continuation hit refreshing the hold)
-- can cancel the previous timer instead of letting it fire later and destroy the new hold early.
local activeHolds: { [BasePart]: thread } = {}

-- Live-body holds (the ATTACKER's standoff pin -- a non-ragdolled character that keeps its Humanoid
-- so it can keep swinging). A live Humanoid keeps running its own controller in the air (Freefall
-- state machine, balance, landing detection) even while server-owned, and that controller fights the
-- AlignPosition every frame -- the rise stutters/steps instead of gliding ("going up in stages,
-- tracking the target"). The ragdolled TARGET doesn't have this because its Humanoid is put into
-- PlatformStand + Physics (enterRagdoll) so only physics drives it. This records the attacker's
-- Humanoid state so the SAME controller-quieting (PlatformStand + Physics + GettingUp off, but NO
-- joint swap, so the body stays rigid and upright, not floppy) can be applied for the hold and
-- restored when it ends. Keyed by rootPart, parallel to activeHolds. Swinging still works: attacks
-- are RemoteEvents CombatSystem validates against stun/posture/ragdoll/cooldown, none of which
-- PlatformStand touches, and AnimationTracks play independent of Humanoid movement state.
local rigidHolds: { [BasePart]: { humanoid: Humanoid, savedPlatformStand: boolean, savedAutoRotate: boolean } } = {}

-- Quiets a live held body's Humanoid controller so only the AlignPosition drives it -- see
-- rigidHolds above. Idempotent per rootPart (a continuation hit refreshing the hold won't
-- re-save/re-apply). No-op if the character/Humanoid is gone.
local function enterRigidHold(rootPart: BasePart): ()
	if rigidHolds[rootPart] then
		return
	end
	local character = rootPart.Parent
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	rigidHolds[rootPart] = {
		humanoid = humanoid,
		savedPlatformStand = humanoid.PlatformStand,
		savedAutoRotate = humanoid.AutoRotate,
	}
	-- Same controller-off treatment enterRagdoll applies, minus buildConstraints -- the body stays
	-- rigid (joints intact, upright) but stops fighting the pin. AutoRotate off so the Humanoid
	-- doesn't try to re-orient mid-air; the attacker keeps whatever facing they dashed in with (still
	-- pointed at the target, so arc-gated continuation hits land).
	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)
end

-- Restores a live held body's Humanoid controller when the hold ends -- the attacker then falls and
-- lands normally under their own control. No-op if there was no rigid hold on this rootPart (the
-- ragdolled target never registers one, so ClearHold can call this unconditionally).
local function exitRigidHold(rootPart: BasePart): ()
	local record = rigidHolds[rootPart]
	if not record then
		return
	end
	rigidHolds[rootPart] = nil
	local humanoid = record.humanoid
	if humanoid.Parent then
		humanoid.PlatformStand = record.savedPlatformStand
		humanoid.AutoRotate = record.savedAutoRotate
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
end

-- BallSocket cone/twist limits live in Constants.Combat.Ragdoll -- were module-local constants
-- here, moved per luau-coding-standards.md's "no magic numbers in system logic" now that every
-- other physics/hitbox tunable lives in Constants.lua.

local function forEachBasePart(character: Model, fn: (BasePart) -> ()): ()
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			fn(descendant)
		end
	end
end

-- Server takes ownership of the whole character so its ragdoll + launch physics are authoritative
-- and replicate to every client. Per-part (a BallSocket ragdoll is several assemblies, not one), and
-- pcall-guarded because SetNetworkOwner throws on an anchored/grounded part.
local function takeServerOwnership(character: Model): ()
	forEachBasePart(character, function(part: BasePart)
		if part.Anchored then
			return
		end
		pcall(function()
			part:SetNetworkOwner(nil)
		end)
	end)
end

local function restoreOwnership(character: Model, ownerPlayer: Player?): ()
	forEachBasePart(character, function(part: BasePart)
		if part.Anchored then
			return
		end
		pcall(function()
			-- nil restores automatic ownership (correct for a dummy with no player); a live player
			-- gets ownership of their own character back so their client resumes simulating it.
			part:SetNetworkOwner(ownerPlayer)
		end)
	end)
end

-- Launches the ragdoll by setting the velocity of the HumanoidRootPart's assembly (the HRP +
-- LowerTorso, kept rigid because buildConstraints skips the Root joint). The BallSocket-linked limbs
-- trail from the torso via their constraints, which reads as a natural launched body. (If limbs ever
-- trail too far in testing, widen this to every BasePart -- the torso is what carries the launch.)
local function applyLaunchVelocity(rootPart: BasePart, velocity: Vector3): ()
	if rootPart.Anchored then
		return
	end
	pcall(function()
		rootPart.AssemblyLinearVelocity = velocity
	end)
end

local function applyLaunchAngularVelocity(rootPart: BasePart, angularVelocity: Vector3): ()
	if rootPart.Anchored then
		return
	end
	pcall(function()
		rootPart.AssemblyAngularVelocity = angularVelocity
	end)
end

-- Swap every Motor6D that doesn't touch the HumanoidRootPart into a BallSocketConstraint. Skipping
-- HRP-touching joints keeps the HRP rigidly attached to the LowerTorso (one stable primary assembly
-- for collision) while every other limb goes floppy. Returns the disabled motors + created instances
-- so recover can reverse exactly this.
local function buildConstraints(character: Model): ({ Motor6D }, { Instance })
	local motors: { Motor6D } = {}
	local created: { Instance } = {}

	local rootPartInstance = character:FindFirstChild("HumanoidRootPart")
	if not rootPartInstance or not rootPartInstance:IsA("BasePart") then
		-- Matches CombatSystem.lua's own guard for the identical lookup (e.g. onCharacterAdded) --
		-- a malformed rig missing the standard root part would otherwise never match the "keep the
		-- Root joint rigid" check below for ANY joint, converting every Motor6D (including the one
		-- meant to stay rigid) into a BallSocketConstraint and scattering the character instead of
		-- ragdolling it as one coherent body.
		warn(
			`RagdollController: character {character:GetFullName()} has no HumanoidRootPart -- skipping ragdoll constraints`
		)
		return motors, created
	end
	local rootPart = rootPartInstance

	for _, descendant in ipairs(character:GetDescendants()) do
		if not descendant:IsA("Motor6D") then
			continue
		end
		local part0 = descendant.Part0
		local part1 = descendant.Part1
		if not part0 or not part1 then
			continue
		end
		-- Keep the Root joint (HRP <-> LowerTorso) rigid.
		if part0 == rootPart or part1 == rootPart then
			continue
		end

		local a0 = Instance.new("Attachment")
		a0.CFrame = descendant.C0
		a0.Parent = part0

		local a1 = Instance.new("Attachment")
		a1.CFrame = descendant.C1
		a1.Parent = part1

		local socket = Instance.new("BallSocketConstraint")
		socket.Attachment0 = a0
		socket.Attachment1 = a1
		socket.LimitsEnabled = true
		socket.UpperAngle = Constants.Combat.Ragdoll.BallSocketUpperAngle
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = Constants.Combat.Ragdoll.BallSocketTwistLowerAngle
		socket.TwistUpperAngle = Constants.Combat.Ragdoll.BallSocketTwistUpperAngle
		socket.Parent = part0

		descendant.Enabled = false

		table.insert(motors, descendant)
		table.insert(created, a0)
		table.insert(created, a1)
		table.insert(created, socket)
	end

	return motors, created
end

-- Shared setup for every ragdoll variant: put the Humanoid limp, build the constraints (R15 only),
-- take server ownership, and register the timer. Idempotent -- a second finisher landing on an
-- already-ragdolled target just extends the timer rather than double-swapping joints.
local function enterRagdoll(character: Model, humanoid: Humanoid, ownerPlayer: Player?, seconds: number): ()
	local existing = active[character]
	if existing then
		existing.expiry = math.max(existing.expiry, os.clock() + seconds)
		return
	end

	local savedPlatformStand = humanoid.PlatformStand
	local savedAutoRotate = humanoid.AutoRotate

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)

	local motors: { Motor6D } = {}
	local created: { Instance } = {}
	-- Only R15 has per-limb joints worth swapping; an R6 rig just stays PlatformStand-limp (stiff
	-- knockdown), which still launches and downs the target without erroring on a 6-part rig.
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		motors, created = buildConstraints(character)
	end

	takeServerOwnership(character)

	active[character] = {
		character = character,
		humanoid = humanoid,
		ownerPlayer = ownerPlayer,
		expiry = os.clock() + seconds,
		motors = motors,
		created = created,
		savedPlatformStand = savedPlatformStand,
		savedAutoRotate = savedAutoRotate,
	}
end

-- Reverse enterRagdoll: destroy constraints, re-enable motors, stand the Humanoid back up, restore
-- ownership. Guards every instance for having been destroyed (death/despawn) mid-ragdoll.
local function exitRagdoll(entry: ActiveRagdoll): ()
	for _, instance in ipairs(entry.created) do
		instance:Destroy()
	end
	for _, motor in ipairs(entry.motors) do
		if motor.Parent then
			motor.Enabled = true
		end
	end

	local humanoid = entry.humanoid
	if humanoid.Parent then
		humanoid.PlatformStand = entry.savedPlatformStand
		humanoid.AutoRotate = entry.savedAutoRotate
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end

	if entry.character.Parent then
		restoreOwnership(entry.character, entry.ownerPlayer)
	end

	active[entry.character] = nil
end

-- Uppercut: ragdoll + a launch that's up AND away from the attacker (not a pure straight-up pop),
-- plus a backward angular velocity so the tumble is biased to come down on its back instead of a
-- random/face-down landing -- a bias applied at launch, not a forced landing snap (this module
-- deliberately never CFrame-snaps a ballsocket-jointed ragdoll; see SlamToGround's own comment on
-- why that reads as a teleport jerk). `ownerPlayer` is nil for a training dummy. `attackerRootPart`
-- is nil for a dummy target (no meaningful attacker to fly away from) -- falls back to the target's
-- own reversed facing so there's still a horizontal component instead of a pure vertical pop.
function RagdollController.LaunchAndRagdoll(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerPlayer: Player?,
	attackerRootPart: BasePart?,
	upVelocity: number,
	horizontalVelocity: number,
	backwardSpin: number,
	seconds: number
): ()
	enterRagdoll(character, humanoid, ownerPlayer, seconds)

	local horizontalDirection = Vector3.new(0, 0, 0)
	if attackerRootPart then
		local delta = rootPart.Position - attackerRootPart.Position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude > Constants.Combat.MinDirectionMagnitude then
			horizontalDirection = flat.Unit
		end
	end
	if horizontalDirection.Magnitude < Constants.Combat.MinDirectionMagnitude then
		horizontalDirection = -rootPart.CFrame.LookVector
	end

	applyLaunchVelocity(rootPart, horizontalDirection * horizontalVelocity + Vector3.new(0, upVelocity, 0))

	-- Perpendicular-to-travel horizontal axis (direction x world-up) so the tumble reads as "flipped
	-- backward along the flight path," not a random corkscrew -- see this function's own header for
	-- why the sign is "backward" (rotating around this axis moves the character's "up" away from its
	-- direction of travel, i.e. head tips backward).
	local spinAxis = horizontalDirection:Cross(Vector3.new(0, 1, 0))
	if spinAxis.Magnitude > Constants.Combat.MinDirectionMagnitude then
		applyLaunchAngularVelocity(rootPart, spinAxis.Unit * backwardSpin)
	end
end

-- Extends an already-ragdolled character's recovery timer WITHOUT touching velocity, constraints, or
-- network ownership -- for a continuation hit that needs the ragdoll to keep lasting but has nothing
-- new to launch (Constants.Combat.AirCombo's continuation branch: the target's actual position is
-- already owned by HoldAloft below, so re-calling LaunchAndRagdoll with an all-zero velocity just to
-- touch this timer was ALSO stomping whatever residual velocity the hold's own AlignPosition had
-- already settled into -- forcing a tiny re-accelerate from rest on every landed hit instead of one
-- continuous, settled hold). A no-op if the character isn't currently ragdolled (nothing to extend).
function RagdollController.ExtendRagdoll(character: Model, seconds: number): ()
	local entry = active[character]
	if entry then
		entry.expiry = math.max(entry.expiry, os.clock() + seconds)
	end
end

-- Stops an in-progress HoldAloft on `rootPart` (below), if any -- cancels the pending auto-release
-- thread (so a continuation hit's fresh hold can't get cut short by the PREVIOUS hold's own timer
-- firing later and destroying the new Attachment/AlignPosition out from under it -- see HoldAloft's
-- own "refresh-in-place" note), destroys the Attachment/AlignPosition, and restores network
-- ownership. Called both by HoldAloft itself (to rebuild a stale hold) and directly by callers
-- ending the sequence early (the slam finisher) so a lingering pin doesn't fight the slam's own
-- downward velocity, or (for the attacker's own hold) so movement control returns right away
-- instead of a few hundred ms late. `ownerPlayer` nil restores automatic ownership (a dummy target);
-- a real player (attacker or target) gets their own ownership back. This only restores network
-- ownership -- it does NOT touch CombatState.airComboChaseExpiry (this module owns no combat state,
-- per this file's own header), so a caller clearing the ATTACKER's own hold early MUST also zero
-- that field itself in the same breath, or the player stays pinned at WalkSpeed 0 (Movement.
-- ComputeDesiredWalkSpeed) for whatever's left of the original window even though the pull already
-- stopped.
function RagdollController.ClearHold(rootPart: BasePart, ownerPlayer: Player?): ()
	local pendingThread = activeHolds[rootPart]
	if pendingThread then
		task.cancel(pendingThread)
		activeHolds[rootPart] = nil
	end
	local existingAlign = rootPart:FindFirstChild("AirComboHoldAlign")
	if existingAlign then
		existingAlign:Destroy()
	end
	local existingGravityCancel = rootPart:FindFirstChild("AirComboHoldGravityCancel")
	if existingGravityCancel then
		existingGravityCancel:Destroy()
	end
	local existingOrient = rootPart:FindFirstChild("AirComboHoldOrient")
	if existingOrient then
		existingOrient:Destroy()
	end
	local existingAttachment = rootPart:FindFirstChild("AirComboHoldAttachment")
	if existingAttachment then
		existingAttachment:Destroy()
	end
	-- Restore the Humanoid controller BEFORE handing ownership back (matches exitRagdoll's order) --
	-- no-op for a ragdolled target, which never registered a rigid hold.
	exitRigidHold(rootPart)
	if rootPart.Parent then
		pcall(function()
			rootPart:SetNetworkOwner(ownerPlayer)
		end)
	end
end

-- Adds (or refreshes) a VectorForce on `rootPart` that exactly cancels gravity on its assembly, so
-- an AlignPosition holding a LIVE (non-ragdolled) body doesn't have to fight gravity to stay put.
-- Why this exists: an AlignPosition's Responsiveness behaves like a spring-damper stiffness even
-- with MaxForce = math.huge -- under a constant disturbance (gravity) a SOFT responsiveness settles
-- with a large following error, i.e. the held body hangs well BELOW its target Position ("floating
-- down, never reaching them"). The ragdolled TARGET tolerates this at its stiffer HoverResponsiveness
-- (25); the ATTACKER, held at the deliberately-soft ChaseResponsiveness (10) that reads as flight
-- rather than a teleport, sagged badly. Cancelling gravity removes the disturbance entirely, so the
-- soft pin holds the exact standoff point -- keeping the flight feel AND the reach. Sized to the
-- assembly's own mass * Workspace.Gravity and applied at the center of mass (no torque), recomputed
-- each (re)creation so a mass change between hits stays correct. Only the attacker's non-ragdolled
-- hold uses this; the ragdolled target (a split multi-assembly body whose limbs are meant to hang)
-- deliberately does not.
local function ensureGravityCancel(rootPart: BasePart, attachment: Attachment): ()
	local existing = rootPart:FindFirstChild("AirComboHoldGravityCancel")
	local force: VectorForce
	if existing and existing:IsA("VectorForce") then
		force = existing
	else
		if existing then
			existing:Destroy()
		end
		local created = Instance.new("VectorForce")
		created.Name = "AirComboHoldGravityCancel"
		created.Attachment0 = attachment
		created.ApplyAtCenterOfMass = true
		created.RelativeTo = Enum.ActuatorRelativeTo.World
		created.Parent = rootPart
		force = created
	end
	-- AssemblyMass is the whole (non-ragdolled) character's mass here; * Gravity is its weight, so
	-- an equal-and-opposite world-up force leaves zero net gravity for the AlignPosition to fight.
	force.Force = Vector3.new(0, rootPart.AssemblyMass * Workspace.Gravity, 0)
end

-- Faces a live held body (the attacker) toward `facePoint`, HORIZONTALLY, via a rigid
-- AlignOrientation. Why: without it the attacker's facing is frozen at whatever direction they
-- dashed in with, so once they and the target settle at their standoff positions the target can sit
-- slightly off that frozen line and every continuation swing is rejected "OutsideArc" -- the combo
-- lands its first hit then whiffs the rest. Pointing the attacker at the target keeps the target
-- inside the swing arc for every hit, and reads as the attacker actively tracking their victim
-- rather than staring off frozen. Rigid (a hard lock, no responsiveness/torque tuning) because the
-- target's HORIZONTAL position barely changes during the hold, so there's nothing to ease toward --
-- and the attacker already enters roughly facing the target, so the initial correction is small.
local function ensureFaceOrientation(
	rootPart: BasePart,
	attachment: Attachment,
	holdPosition: Vector3,
	facePoint: Vector3
): ()
	local flatFace = Vector3.new(facePoint.X, holdPosition.Y, facePoint.Z)
	if (flatFace - holdPosition).Magnitude < Constants.Combat.Ragdoll.FaceAlignToleranceStuds then
		-- Target directly overhead (degenerate horizontal direction) -- keep whatever facing exists
		-- rather than aligning to a near-zero look vector.
		return
	end
	local lookCFrame = CFrame.lookAt(holdPosition, flatFace)

	local existing = rootPart:FindFirstChild("AirComboHoldOrient")
	if existing and existing:IsA("AlignOrientation") then
		existing.CFrame = lookCFrame
		return
	end
	if existing then
		existing:Destroy()
	end
	local orient = Instance.new("AlignOrientation")
	orient.Name = "AirComboHoldOrient"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.RigidityEnabled = true
	orient.CFrame = lookCFrame
	orient.Parent = rootPart
end

-- Air combo position control -- pins `rootPart` to a single, fixed `holdPosition` for
-- `durationSeconds` via a server-side AlignPosition, then releases it. Used for BOTH sides of the
-- sequence (CombatSystem.lua's applyAirCombo): the TARGET's hover (Constants.Combat.AirCombo.
-- HoverHeight/HoverRiseSpeed/HoverResponsiveness) and the ATTACKER's standoff position near them
-- (ChaseStandoffDistance/ChaseBelowTargetOffset/ChaseSpeed/ChaseResponsiveness) -- these used to be
-- two separate mechanisms (this one, and a ChaseTarget that re-targeted an AlignPosition to the
-- target's live position every single Heartbeat tick), collapsed into one once the target's own
-- position stopped moving once it settles (nothing to continuously re-track anymore). Re-assigning
-- an already-converged AlignPosition's `Position` to a barely-changed value 60 times a second turned
-- out to visibly disturb its own internal responsiveness ramp -- read as "snap up snap up" instead
-- of one continuous rise -- so this version writes `Position` ONCE per call (creation or an explicit
-- refresh) and otherwise leaves Roblox's own physics solver to keep enforcing it every step with no
-- further script involvement.
--
-- `liveBodyFacePoint` marks this as the ATTACKER's LIVE (non-ragdolled) hold and is the world point
-- to keep them facing (the target's hover position). Non-nil triggers the full live-body treatment:
-- a weight-cancelling VectorForce so the soft pin doesn't sag (ensureGravityCancel), controller-
-- quieting so the live Humanoid doesn't stutter the rise (enterRigidHold), and a face orientation so
-- swings keep landing (ensureFaceOrientation). The ragdolled target passes nil -- it needs none of
-- these (its own ragdoll already hands control to physics, and it has no swings to aim).
--
-- `holdPosition` is computed ONCE by the caller at DashPunch-hit time (the target's hit-time
-- position + HoverHeight for the target's own hold; that same hoverPosition + a standoff offset for
-- the attacker's -- see CombatState.airComboHoverPosition/airComboChaseOffset's own headers) and
-- MUST be reused verbatim by every continuation hit, not recomputed from wherever things currently
-- are -- recomputing is what let a fast combo ratchet the target's height up hit-over-hit before
-- (HoverHeight's own header in Constants.lua has the full story).
--
-- Takes and holds server ownership of `rootPart` for the duration -- a client fighting the server
-- for the same part would be the same tug-of-war either direction. Safe for a ragdolled target
-- (PlatformStand = true, set by the caller's own LaunchAndRagdoll before this runs -- no WASD to
-- fight). For a NOT-ragdolled attacker, network ownership alone does NOT stop their own held WASD
-- from still commanding Humanoid movement server-side -- the server simulates their Humanoid off
-- replicated move input regardless of who owns the part, so an un-silenced WalkSpeed would fight
-- this function's AlignPosition for the whole window. Silencing that is CombatState.
-- airComboChaseExpiry's job (Movement.ComputeDesiredWalkSpeed pins WalkSpeed to 0 while active) --
-- every caller using this for the ATTACKER side is responsible for setting attackerState.
-- airComboChaseExpiry = now + durationSeconds in the same breath.
--
-- Refresh-in-place per rootPart -- a continuation hit calling this again while the SAME Attachment/
-- AlignPosition from a prior call is still alive just updates its `Position` (normally a same-value
-- write, per the "MUST be reused verbatim" note above, but stays correct if a future caller ever
-- wants to move it) and reschedules the auto-release timer, WITHOUT destroying/recreating the
-- constraint or touching `maxSpeed`/`responsiveness` again (a live AlignPosition keeps its already-
-- set tuning; only Position and the release timer change on refresh).
function RagdollController.HoldAloft(
	rootPart: BasePart,
	ownerPlayer: Player?,
	holdPosition: Vector3,
	durationSeconds: number,
	maxSpeed: number,
	responsiveness: number,
	liveBodyFacePoint: Vector3?
): ()
	if rootPart.Anchored then
		return
	end

	local existingAlign = rootPart:FindFirstChild("AirComboHoldAlign")
	if existingAlign and existingAlign:IsA("AlignPosition") then
		existingAlign.Position = holdPosition
		-- Keep the live-body constraints alive/correct across a continuation-hit refresh, same
		-- refresh-in-place philosophy as the AlignPosition itself: the gravity-cancel force's mass
		-- factor is recomputed, the face orientation re-points at the (barely-moved) target, and
		-- enterRigidHold is re-asserted (idempotent) so the controller-quieting persists.
		if liveBodyFacePoint then
			local attachment = rootPart:FindFirstChild("AirComboHoldAttachment")
			if attachment and attachment:IsA("Attachment") then
				ensureGravityCancel(rootPart, attachment)
				ensureFaceOrientation(rootPart, attachment, holdPosition, liveBodyFacePoint)
			end
			enterRigidHold(rootPart)
		end
		local pendingThread = activeHolds[rootPart]
		if pendingThread then
			task.cancel(pendingThread)
		end
		activeHolds[rootPart] = task.delay(durationSeconds, function()
			activeHolds[rootPart] = nil
			RagdollController.ClearHold(rootPart, ownerPlayer)
		end)
		return
	end

	RagdollController.ClearHold(rootPart, ownerPlayer)

	pcall(function()
		rootPart:SetNetworkOwner(nil)
	end)

	local created = pcall(function()
		local attachment = Instance.new("Attachment")
		attachment.Name = "AirComboHoldAttachment"
		attachment.Parent = rootPart

		local alignPosition = Instance.new("AlignPosition")
		alignPosition.Name = "AirComboHoldAlign"
		alignPosition.Attachment0 = attachment
		alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
		alignPosition.MaxForce = math.huge
		alignPosition.MaxVelocity = maxSpeed
		alignPosition.Responsiveness = responsiveness
		alignPosition.Position = holdPosition
		alignPosition.Parent = rootPart

		-- A live (non-ragdolled) held body: cancel its gravity so the soft AlignPosition holds the
		-- exact point instead of sagging below it, and point it at the target so its swings keep
		-- landing. Created inside the same pcall so a mid-setup failure tears down cleanly via the
		-- leftover cleanup below.
		if liveBodyFacePoint then
			ensureGravityCancel(rootPart, attachment)
			ensureFaceOrientation(rootPart, attachment, holdPosition, liveBodyFacePoint)
		end
	end)

	-- Quiet the live attacker's Humanoid controller for the hold so it doesn't fight the pin and
	-- stutter the rise -- outside the pcall above (it changes Humanoid properties, not physics
	-- instances, so it isn't part of the same construction that could fail) and only once the
	-- AlignPosition actually got created.
	if created and liveBodyFacePoint then
		enterRigidHold(rootPart)
	end

	if not created then
		-- Reuse ClearHold instead of re-destroying each named instance by hand -- it also restores
		-- network ownership to ownerPlayer (SetNetworkOwner(nil) was set just above, before the
		-- attempt) and calls exitRigidHold (a no-op here since enterRigidHold never ran on this
		-- failure path), neither of which the old bespoke cleanup did -- a failed hold used to leave
		-- the rootPart's network ownership stuck server-side (nil) with nothing to ever hand it back.
		RagdollController.ClearHold(rootPart, ownerPlayer)
		return
	end

	activeHolds[rootPart] = task.delay(durationSeconds, function()
		activeHolds[rootPart] = nil
		RagdollController.ClearHold(rootPart, ownerPlayer)
	end)
end

-- Downslam: ragdoll (a briefer knockdown than the uppercut's) + a hard straight-down launch that
-- drives a target back into the floor. No ground raycast/snap -- the downward velocity does the
-- grounding, and snapping a CFrame while BallSocket-jointed reads as a teleport jerk.
--
-- Applies the down velocity to EVERY BasePart, not just rootPart -- deliberately unlike
-- LaunchAndRagdoll above, which only launches the root and lets the BallSocket-linked limbs trail
-- behind it (the "flying body" look that's correct for an upward launch). enterRagdoll just
-- converted every non-Root joint into a floppy BallSocketConstraint the instant before this runs, so
-- the limbs are still carrying whatever velocity they had a moment ago (near-zero for a standing/
-- idle target) -- setting a big downward velocity on ONLY the root then yanks the torso down at full
-- speed while the limbs are still nearly stationary, and the ball sockets have to violently
-- reconcile that sudden relative-velocity mismatch on the very first physics step. That reconciling
-- is what reads as the character spinning/flipping instead of just dropping -- giving every part the
-- SAME velocity up front means the whole body falls together with no relative velocity for the
-- constraints to fight, so it drops instead of tumbling.
function RagdollController.SlamToGround(
	character: Model,
	humanoid: Humanoid,
	ownerPlayer: Player?,
	downVelocity: number,
	seconds: number
): ()
	enterRagdoll(character, humanoid, ownerPlayer, seconds)
	local velocity = Vector3.new(0, -downVelocity, 0)
	forEachBasePart(character, function(part: BasePart)
		applyLaunchVelocity(part, velocity)
	end)
end

-- Immediate recover, out of band with the timer -- CombatSystem calls this when a ragdolled
-- character dies or despawns so nothing leaks (disabled motors, server ownership) onto a character
-- that's about to be replaced. Safe to call on a character that isn't ragdolled.
function RagdollController.Recover(character: Model): ()
	local entry = active[character]
	if entry then
		exitRagdoll(entry)
	end
end

-- Reverses ONLY the ballsocket-joint ragdoll swap (destroys the created Attachments/
-- BallSocketConstraints, re-enables the disabled Motor6Ds) -- deliberately does NOT restore network
-- ownership and does NOT stand the Humanoid up via GettingUp, unlike the full Recover/exitRagdoll
-- above. For CombatSystem.lua's handleAirTechRequest: converting an air-combo TARGET from
-- ragdolled-and-helpless into held-but-conscious, where the caller immediately re-calls HoldAloft
-- with a liveBodyFacePoint to apply the same live-body treatment (PlatformStand+Physics rigid hold
-- via enterRigidHold, gravity-cancel, face orientation) the ATTACKER's own hold already uses --
-- ownership must stay server-side and the Humanoid must stay controller-quieted for that hold to
-- keep working, so this stops short of exitRagdoll's full reversal (which would hand ownership back
-- to the player and let their own held WASD immediately fight the still-active AlignPosition, same
-- "float down, never reach them" class of bug HoldAloft's own header describes for a live body that
-- isn't gravity-cancelled/controller-quieted). No-op if the character isn't currently ragdolled.
--
-- It DOES, however, restore the Humanoid's saved PlatformStand/AutoRotate/GettingUp before dropping
-- the entry, and that is load-bearing rather than cosmetic. `active[character]` is the only record
-- of the pre-ragdoll values (enterRagdoll captures them there), so clearing it without restoring
-- destroyed them -- and enterRigidHold, which the caller invokes immediately afterward via HoldAloft,
-- snapshots `humanoid.PlatformStand` fresh. It therefore recorded the RAGDOLLED value (true) as
-- though it were the player's normal state, and exitRigidHold faithfully restored `true` when the
-- hold ended, leaving the player permanently limp -- unable to walk until they died or an admin ran
-- ResetCombatState, since ChangeState(GettingUp) cannot override a true PlatformStand. Restoring
-- here means the ragdoll -> rigid-hold transition carries the ORIGINAL pre-ragdoll state forward
-- instead of laundering the ragdoll's own state into it.
--
-- Safe despite the header's warning above, because this is not exitRagdoll's full reversal: network
-- ownership deliberately stays server-side, and the caller (AirCombo's air-tech path) re-applies
-- enterRigidHold's quieting synchronously in the same frame with no yield in between, so no physics
-- step observes the momentarily-restored controller.
function RagdollController.RecoverJointsOnly(character: Model): ()
	local entry = active[character]
	if not entry then
		return
	end
	for _, instance in ipairs(entry.created) do
		instance:Destroy()
	end
	for _, motor in ipairs(entry.motors) do
		if motor.Parent then
			motor.Enabled = true
		end
	end

	local humanoid = entry.humanoid
	if humanoid.Parent then
		humanoid.PlatformStand = entry.savedPlatformStand
		humanoid.AutoRotate = entry.savedAutoRotate
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		-- No ChangeState(GettingUp) here, unlike exitRagdoll -- standing the body up is exactly what
		-- this function exists NOT to do; the caller is about to re-pin it.
	end

	active[character] = nil
end

-- Driven once per tick from CombatSystem.onHeartbeat (this module opens no Heartbeat connection of
-- its own -- same reasoning as HitboxResolver). Recovers every ragdoll whose window has elapsed.
function RagdollController.Update(now: number): ()
	local expired: { Model }? = nil
	for character, entry in pairs(active) do
		if now >= entry.expiry then
			expired = expired or {}
			table.insert(expired, character)
		end
	end
	if expired then
		for _, character in ipairs(expired) do
			local entry = active[character]
			if entry then
				exitRagdoll(entry)
			end
		end
	end
end

return RagdollController
