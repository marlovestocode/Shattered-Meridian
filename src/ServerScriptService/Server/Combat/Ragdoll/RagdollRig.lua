--!strict
--[[
	RagdollRig.lua

	Owns: the Instances that turn one character into a ragdoll and back -- a BallSocketConstraint per limb
	joint (built from that joint's own Motor6D, so it fits any R6 rig, and any rig whose joints are Motor6Ds),
	an invisible collider per limb that does not collide on its own, the NoCollisionConstraints that stop
	adjacent parts fighting at their sockets, a per-part gravity counterforce, and the two drives that right the
	body during the get-up. Plus the property flips around them (motors, PlatformStand, RequiresNeck, the root's
	collision, physical properties, anchoring, network ownership) and their exact restoration.

	BUILT ONCE PER LIFE, TOGGLED AFTER. Build creates every Instance disabled the first time a body ragdolls;
	every later ragdoll of that body only flips Enabled and writes numbers. A character is a new Model each life,
	so the kit dies with it -- nothing to clean.

	WHY THE SOCKETS ARE AIMED, not dropped at C0/C1 as they are. A BallSocketConstraint limits the angle between
	its two attachments' PRIMARY axes. Built straight from a Motor6D's C0/C1, that axis points wherever the rig's
	authoring left it (sideways, for an R6 shoulder), and the cone is centred on nothing a limb does. Each joint
	class names the limb's rest direction (RagdollConstants.Rig.Joints: down for a leg or an arm, up for the
	head); the limb's attachment is aimed along it, and the torso's is derived from it through the motor
	(C0 * C1^-1), so the two coincide exactly in the rest pose and the cone is a cone around a hanging arm.

	Server-only, and only RagdollSystem calls it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RagdollConstants = require(ReplicatedStorage.Shared.Ragdoll.RagdollConstants)
local RagdollRules = require(ReplicatedStorage.Shared.Ragdoll.RagdollRules)
local RagdollTypes = require(ReplicatedStorage.Shared.Ragdoll.RagdollTypes)

type RagdollSpec = RagdollTypes.RagdollSpec

local RagdollRig = {}

export type Joint = {
	Motor: Motor6D,
	Socket: BallSocketConstraint,
	Class: RagdollRules.JointClass,
	-- This ragdoll's limits at full slack (the spec's stiffness), which the get-up tightens from.
	Upper: number,
	TwistLower: number,
	TwistUpper: number,
}

-- What a ragdoll changed on one body part, to put back exactly.
type PartState = {
	Part: BasePart,
	Anchored: boolean,
	CanCollide: boolean,
	Physical: PhysicalProperties?,
	Gravity: VectorForce,
}

export type Kit = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Joints: { Joint },
	Colliders: { BasePart },
	NoCollisions: { NoCollisionConstraint },
	Parts: { PartState },
	-- The get-up's two drives, on the root.
	Stand: AlignPosition,
	Upright: AlignOrientation,
	-- Root centre above the floor when standing: the root's half height, the longest leg, the HipHeight.
	StandHeight: number,
	-- Humanoid and ownership state to restore. PlatformStand is not saved: a body always comes back up with it off
	-- (RagdollRig.Restore), because the state it had going down may be a grab's flight, which has handed it over.
	Saved: {
		RequiresNeck: boolean,
		BreakJointsOnDeath: boolean,
		OwnershipAuto: boolean,
	}?,
}

local FOLDER_NAME = "Ragdoll"

-- The joints that ragdoll: every Motor6D joining two of the model's own body parts, except the one that holds
-- the root (it stays rigid, so the root rides the torso and everything that follows the root -- the camera,
-- the hurtbox, the wall-splat watch -- follows the body). A weapon grip is a Weld and never matches.
local function ragdollMotors(model: Model, root: BasePart): { Motor6D }
	local motors: { Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("Motor6D") then
			continue
		end
		local part0, part1 = descendant.Part0, descendant.Part1
		if part0 == nil or part1 == nil or part0 == root or part1 == root then
			continue
		end
		if part0.Parent ~= model or part1.Parent ~= model then
			continue
		end
		table.insert(motors, descendant)
	end
	return motors
end

-- A unit vector perpendicular to `axis`, for an attachment's secondary axis.
local function perpendicular(axis: Vector3): Vector3
	local reference = if math.abs(axis:Dot(Vector3.zAxis)) < 0.9 then Vector3.zAxis else Vector3.xAxis
	return (reference - axis * reference:Dot(axis)).Unit
end

local function newAttachment(name: string, parent: BasePart, cframe: CFrame): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = cframe
	attachment.Parent = parent
	return attachment
end

local function noCollision(folder: Folder, a: BasePart, b: BasePart, into: { NoCollisionConstraint }): ()
	local constraint = Instance.new("NoCollisionConstraint")
	constraint.Part0 = a
	constraint.Part1 = b
	constraint.Enabled = false
	constraint.Parent = folder
	table.insert(into, constraint)
end

-- Builds the kit for `model`, every Instance disabled. nil when the body has nothing to ragdoll.
function RagdollRig.Build(model: Model, humanoid: Humanoid, root: BasePart): Kit?
	local motors = ragdollMotors(model, root)
	if #motors == 0 then
		return nil
	end
	local existing = model:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local joints: { Joint } = {}
	local colliders: { BasePart } = {}
	local noCollisions: { NoCollisionConstraint } = {}
	local colliderOf: { [BasePart]: BasePart } = {}
	local longestLeg = 0
	local rig = RagdollConstants.Rig

	for _, motor in motors do
		local part0 = motor.Part0 :: BasePart
		local part1 = motor.Part1 :: BasePart
		local class = RagdollRules.JointClassOf(motor.Name)
		local axis = class.Axis.Unit
		local attachment1CFrame = CFrame.fromMatrix(motor.C1.Position, axis, perpendicular(axis))
		local attachment1 = newAttachment("RagdollSocket", part1, attachment1CFrame)
		local attachment0 =
			newAttachment("RagdollSocket_" .. motor.Name, part0, motor.C0 * motor.C1:Inverse() * attachment1CFrame)

		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "Ragdoll_" .. motor.Name
		socket.Attachment0 = attachment0
		socket.Attachment1 = attachment1
		socket.LimitsEnabled = true
		socket.TwistLimitsEnabled = true
		socket.Restitution = 0
		socket.Enabled = false
		socket.Parent = folder
		table.insert(joints, {
			Motor = motor,
			Socket = socket,
			Class = class,
			Upper = class.UpperAngle,
			TwistLower = class.TwistLower,
			TwistUpper = class.TwistUpper,
		})

		if string.find(motor.Name, "Hip", 1, true) then
			longestLeg = math.max(longestLeg, part1.Size.Y)
		end

		-- A limb the Humanoid does not let collide gets a collider of its own (see this file's header).
		if not part1.CanCollide and colliderOf[part1] == nil then
			local collider = Instance.new("Part")
			collider.Name = "RagdollCollider"
			collider.Size = part1.Size * rig.ColliderScale
			collider.Transparency = 1
			collider.Massless = true
			collider.CanCollide = false
			collider.CanQuery = false
			collider.CanTouch = false
			collider.CastShadow = false
			collider.CFrame = part1.CFrame
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = collider
			weld.Part1 = part1
			weld.Parent = collider
			collider.Parent = part1
			colliderOf[part1] = collider
			table.insert(colliders, collider)
		end
		-- A limb and the part it hangs from never collide: they meet at the socket, and would fight there.
		noCollision(folder, colliderOf[part1] or part1, part0, noCollisions)
	end

	-- Legs side by side touch at rest; arms do not, and are left to collide with the legs (a body falling on its
	-- own arm should land on it).
	local legs: { BasePart } = {}
	for _, joint in joints do
		if string.find(joint.Motor.Name, "Hip", 1, true) then
			local leg = joint.Motor.Part1 :: BasePart
			table.insert(legs, colliderOf[leg] or leg)
		end
	end
	for index = 1, #legs - 1 do
		noCollision(folder, legs[index], legs[index + 1], noCollisions)
	end

	local parts: { PartState } = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") then
			local centre = newAttachment("RagdollCentre", child, CFrame.identity)
			local gravity = Instance.new("VectorForce")
			gravity.Name = "RagdollGravity"
			gravity.Attachment0 = centre
			gravity.RelativeTo = Enum.ActuatorRelativeTo.World
			gravity.ApplyAtCenterOfMass = true
			gravity.Force = Vector3.zero
			gravity.Enabled = false
			gravity.Parent = folder
			table.insert(parts, {
				Part = child,
				Anchored = child.Anchored,
				CanCollide = child.CanCollide,
				Physical = child.CustomPhysicalProperties,
				Gravity = gravity,
			})
		end
	end

	local rootAttachment = newAttachment("RagdollRootDrive", root, CFrame.identity)
	local stand = Instance.new("AlignPosition")
	stand.Name = "RagdollStand"
	stand.Mode = Enum.PositionAlignmentMode.OneAttachment
	stand.Attachment0 = rootAttachment
	stand.MaxForce = math.huge
	stand.Enabled = false
	stand.Parent = folder
	local upright = Instance.new("AlignOrientation")
	upright.Name = "RagdollUpright"
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.Attachment0 = rootAttachment
	upright.MaxTorque = math.huge
	upright.Enabled = false
	upright.Parent = folder

	folder.Parent = model

	return {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Joints = joints,
		Colliders = colliders,
		NoCollisions = noCollisions,
		Parts = parts,
		Stand = stand,
		Upright = upright,
		StandHeight = root.Size.Y / 2 + (if longestLeg > 0 then longestLeg else 2) + math.max(humanoid.HipHeight, 0),
		Saved = nil,
	}
end

local function setOwner(part: BasePart, owner: Player?): ()
	if part.Anchored or not part:IsDescendantOf(Workspace) then
		return
	end
	pcall(function()
		if part:CanSetNetworkOwnership() then
			part:SetNetworkOwner(owner)
		end
	end)
end

-- Writes `spec`'s joint numbers, physical properties and gravity onto a kit that is already limp (or about to be).
local function applySpec(kit: Kit, spec: RagdollSpec): ()
	local friction = RagdollRules.FrictionTorque(spec.Stiffness)
	for _, joint in kit.Joints do
		joint.Upper, joint.TwistLower, joint.TwistUpper = RagdollRules.JointLimits(joint.Class, spec.Stiffness)
		local socket = joint.Socket
		socket.UpperAngle = joint.Upper
		socket.TwistLowerAngle = joint.TwistLower
		socket.TwistUpperAngle = joint.TwistUpper
		socket.MaxFrictionTorque = friction
	end
	local rig = RagdollConstants.Rig
	local gravity = Workspace.Gravity
	for _, state in kit.Parts do
		local part = state.Part
		-- The root does not collide while limp, so only its weight is the spec's business.
		if part ~= kit.Root then
			local current = part.CurrentPhysicalProperties
			part.CustomPhysicalProperties = PhysicalProperties.new(
				current.Density,
				spec.Friction,
				spec.Bounce,
				rig.FrictionWeight,
				rig.ElasticityWeight
			)
		end
		-- (1 - scale) of the part's weight, upward: below 1 the body floats, above 1 it is pressed down.
		state.Gravity.Force = Vector3.yAxis * (1 - spec.GravityScale) * part:GetMass() * gravity
		state.Gravity.Enabled = spec.GravityScale ~= 1
	end
	for _, collider in kit.Colliders do
		collider.CustomPhysicalProperties =
			PhysicalProperties.new(0.01, spec.Friction, spec.Bounce, rig.FrictionWeight, rig.ElasticityWeight)
	end
end

-- Takes the body limp under `spec`: the server takes ownership, the motors let go, the sockets and colliders
-- take over. Safe to call on a body that is already limp (a refresh): it only re-writes the spec and stands the
-- get-up drives down.
function RagdollRig.GoLimp(kit: Kit, spec: RagdollSpec): ()
	local humanoid = kit.Humanoid
	if kit.Saved == nil then
		kit.Saved = {
			RequiresNeck = humanoid.RequiresNeck,
			BreakJointsOnDeath = humanoid.BreakJointsOnDeath,
			OwnershipAuto = (function(): boolean
				local ok, auto = pcall(function()
					return kit.Root:GetNetworkOwnershipAuto()
				end)
				return ok and auto == true
			end)(),
		}
		for _, state in kit.Parts do
			state.Anchored = state.Part.Anchored
			state.CanCollide = state.Part.CanCollide
			state.Physical = state.Part.CustomPhysicalProperties
		end
		-- A body losing its neck joint dies (RequiresNeck); a body dying mid-fall breaks apart (BreakJointsOnDeath).
		-- Neither may happen to a ragdoll.
		humanoid.RequiresNeck = false
		humanoid.BreakJointsOnDeath = false
		humanoid.PlatformStand = true
		for _, joint in kit.Joints do
			joint.Socket.Enabled = true
			joint.Motor.Enabled = false
		end
		for _, constraint in kit.NoCollisions do
			constraint.Enabled = true
		end
		for _, collider in kit.Colliders do
			collider.CanCollide = true
		end
		for _, state in kit.Parts do
			local part = state.Part
			if part == kit.Root then
				-- The root rides the torso inside it; colliding, it would shove the torso out of itself.
				part.CanCollide = false
			end
			part.Anchored = false
		end
		-- Every limb is its own assembly now, so each is handed to the server separately.
		for _, state in kit.Parts do
			setOwner(state.Part, nil)
		end
	end
	kit.Stand.Enabled = false
	kit.Upright.Enabled = false
	applySpec(kit, spec)
end

-- Throws the limp body: `linear` for every part, plus the tangential velocity `angular` gives it about the
-- root -- the whole body set spinning as one, not each limb spun about its own centre.
function RagdollRig.Throw(kit: Kit, linear: Vector3, angular: Vector3): ()
	local centre = kit.Root.Position
	for _, state in kit.Parts do
		local part = state.Part
		part.AssemblyLinearVelocity = linear + angular:Cross(part.Position - centre)
		part.AssemblyAngularVelocity = angular
	end
end

-- Starts the get-up toward `target` (where the root stands), over `seconds`.
function RagdollRig.BeginGetUp(kit: Kit, target: CFrame, seconds: number): ()
	local responsiveness =
		math.clamp(RagdollConstants.Recovery.ResponsivenessPerSecond / math.max(seconds, 0.05), 5, 200)
	kit.Stand.Position = target.Position
	kit.Stand.Responsiveness = responsiveness
	kit.Upright.CFrame = target.Rotation
	kit.Upright.Responsiveness = responsiveness
	kit.Stand.Enabled = true
	kit.Upright.Enabled = true
	for _, state in kit.Parts do
		state.Gravity.Enabled = false
	end
end

-- Draws every joint `alpha` (0..1) of the way from its limp limits to the get-up's final angle.
function RagdollRig.Tighten(kit: Kit, alpha: number): ()
	for _, joint in kit.Joints do
		local socket = joint.Socket
		socket.UpperAngle = RagdollRules.TightenedAngle(joint.Upper, alpha)
		socket.TwistLowerAngle = RagdollRules.TightenedAngle(joint.TwistLower, alpha)
		socket.TwistUpperAngle = RagdollRules.TightenedAngle(joint.TwistUpper, alpha)
	end
end

-- Puts the body back together standing at `standAt` (nil: where it is) and hands it back to `owner` (a Player,
-- or nil for a server-owned body). Idempotent on a kit that is not limp.
function RagdollRig.Restore(kit: Kit, standAt: CFrame?, owner: Player?): ()
	local saved = kit.Saved
	if saved == nil then
		return
	end
	kit.Saved = nil
	kit.Stand.Enabled = false
	kit.Upright.Enabled = false
	for _, joint in kit.Joints do
		joint.Socket.Enabled = false
		joint.Motor.Enabled = true
	end
	for _, constraint in kit.NoCollisions do
		constraint.Enabled = false
	end
	for _, collider in kit.Colliders do
		collider.CanCollide = false
	end
	for _, state in kit.Parts do
		state.Gravity.Enabled = false
		state.Part.CustomPhysicalProperties = state.Physical
		state.Part.CanCollide = state.CanCollide
		state.Part.AssemblyLinearVelocity = Vector3.zero
		state.Part.AssemblyAngularVelocity = Vector3.zero
	end
	-- The motors are back, so the body is one assembly again: placing the root places all of it.
	if standAt then
		kit.Model:PivotTo(standAt * kit.Root.CFrame:ToObjectSpace(kit.Model:GetPivot()))
	end
	for _, state in kit.Parts do
		state.Part.Anchored = state.Anchored
	end
	local humanoid = kit.Humanoid
	humanoid.PlatformStand = false
	humanoid.RequiresNeck = saved.RequiresNeck
	humanoid.BreakJointsOnDeath = saved.BreakJointsOnDeath
	if owner then
		setOwner(kit.Root, owner)
	elseif saved.OwnershipAuto then
		pcall(function()
			kit.Root:SetNetworkOwnershipAuto()
		end)
	end
end

-- Whether the kit currently holds the body limp.
function RagdollRig.IsLimp(kit: Kit): boolean
	return kit.Saved ~= nil
end

return RagdollRig
