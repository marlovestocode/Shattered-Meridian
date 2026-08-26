--!strict
--[[
	BlimpAssembly.lua

	Owns: turning a tagged Model full of loose MeshParts into ONE driveable physics body, and the two
	constraints that fly it. This is the file that answers "make it also affect all the other mesh parts
	in the model" -- everything else in this layer assumes a blimp is a single rigid thing, and this is
	where that becomes true.

	WHAT A BUILDER HANDS US, and why none of it can be assumed: a Model with anywhere between two and two
	hundred BaseParts, most of them anchored (because that is how anything stays put in Studio), welded to
	each other in some places and not others, with no PrimaryPart set, and with a mass nobody has thought
	about. Every one of those is fatal to a drive constraint on its own -- an anchored part ignores force
	entirely, an unwelded part gets left behind the instant the hull moves, and an unknown mass means no
	force constant can be right. Build() normalises all of it.

	THE ROOT IS THE LARGEST PART, unless the builder set a PrimaryPart, in which case it is that. Largest
	rather than first-found because the root is what the whole hull's motion is expressed relative to, and
	picking a bolt on the gondola would put the centre of rotation somewhere the pilot can see it swing.

	MASSLESS IS NOT AN OPTIMISATION, it is what makes one set of force constants correct for every blimp.
	With every non-root part massless, the assembly's mass is the root part's mass and nothing else, so
	BlimpConstants.Physics.ForceGravityMultiple means the same thing on a two-part prototype and on a
	finished two-hundred-mesh airship. Without it, an artist adding detail meshes silently makes the blimp
	heavier and slower until one day it cannot climb, with nothing in any log to explain why.

	RECOVERABLE, NOT DESTRUCTIVE. Every property this file changes (Anchored, Massless, RootPriority) is
	recorded and restored by Destroy, and every Instance it creates is tracked in the assembly's Trove. An
	untagged blimp goes back to being exactly the Model the builder made, which is what makes the Tag
	Editor a usable way to iterate on one at runtime rather than a one-way door.

	Does not own: the flight arithmetic (BlimpDrive.lua -- this file only owns the constraints it is fed
	into), the mount (BlimpSystem.lua), or which parts are stations (Shared/Blimp/BlimpTagging.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local logger = Logger.scope("BlimpAssembly")

local BlimpAssembly = {}

export type Assembly = {
	Model: Model,
	Root: BasePart,
	Attachment: Attachment,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
	-- Every BasePart that makes up this hull (including Root). Exposed so BlimpSystem.registerBlimp
	-- can wire Touched/TouchEnded on the whole hull without re-walking the model and re-deriving the
	-- same "exclude anything that belongs to a character" filter Build already applied once here --
	-- see BlimpSafety.lua's own header for what that wiring is for.
	HullParts: { BasePart },
	Trove: Trove.TroveInstance,
}

-- Nominal lever arm, in studs, for turning the torque multiple into a torque. Fixed rather than derived
-- from the hull's own extents on purpose: deriving it would mean a longer blimp automatically got more
-- torque, which sounds right and is not -- it would make every hull turn at the same rate regardless of
-- size, deleting the one place a builder's model proportions should be felt in the handling.
local NOMINAL_LEVER_STUDS = 16

-- Whether this part belongs to somebody's character rather than to the blimp. A player standing on the
-- deck when a blimp is (re)built must not be welded into the hull permanently -- BlimpSystem owns mounting
-- a body, with a weld it can undo, and this file must never quietly do the same thing with no way out.
local function belongsToACharacter(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

local function chooseRoot(model: Model, parts: { BasePart }): BasePart?
	local primary = model.PrimaryPart
	if primary and table.find(parts, primary) then
		return primary
	end

	local best: BasePart? = nil
	local bestVolume = -1
	for _, part in parts do
		local size = part.Size
		local volume = size.X * size.Y * size.Z
		if volume > bestVolume then
			bestVolume = volume
			best = part
		end
	end
	return best
end

-- Sizes both constraints off the assembly's CURRENT mass. Called again by BlimpSystem on every mount and
-- dismount, because a welded passenger is real mass joining the assembly: sizing once at registration
-- would give a blimp that flies correctly empty and sags with a full crew.
function BlimpAssembly.RefreshForceLimits(assembly: Assembly): ()
	local weight = assembly.Root.AssemblyMass * Workspace.Gravity
	assembly.AlignPosition.MaxForce = weight * BlimpConstants.Physics.ForceGravityMultiple
	assembly.AlignOrientation.MaxTorque = weight * NOMINAL_LEVER_STUDS * BlimpConstants.Physics.TorqueGravityMultiple
end

-- Hands the whole assembly to the SERVER. Called on build and again after every weld change, because
-- welding a client-owned character into a server-owned assembly is exactly the case where Roblox has to
-- pick one owner and the answer is not guaranteed to be the one we set last.
--
-- pcall-guarded the same way GrabSystem's and AdminActionSystem.SetFlying's own calls are: SetNetworkOwner
-- throws outright on an anchored or otherwise ungrounded part, which is reachable here if a builder
-- re-anchors a hull part from the Explorer mid-flight.
function BlimpAssembly.ClaimOwnership(assembly: Assembly): ()
	local ok, err = pcall(function()
		assembly.Root:SetNetworkOwner(nil)
	end)
	if not ok then
		logger:warn("Could not claim network ownership of the hull", {
			model = assembly.Model:GetFullName(),
			err = tostring(err),
		})
	end
end

-- Normalises `model` into one driven body. Returns nil (having changed nothing) if there is nothing here
-- to fly -- a tagged Folder-shaped Model with no parts in it is a build mistake, and reporting it is more
-- use than half-building an assembly around it.
function BlimpAssembly.Build(model: Model): Assembly?
	local parts: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not belongsToACharacter(descendant :: BasePart) then
			table.insert(parts, descendant :: BasePart)
		end
	end

	local root = chooseRoot(model, parts)
	if not root then
		logger:warn("Tagged model has no BaseParts to fly", { model = model:GetFullName() })
		return nil
	end

	local trove = Trove.New()

	-- Recorded before anything is touched, and restored by the Trove in reverse -- see this file's header
	-- on why untagging has to give the builder their Model back unchanged.
	local originalAnchored: { [BasePart]: boolean } = {}
	local originalMassless: { [BasePart]: boolean } = {}
	local originalRootPriority = root.RootPriority
	trove:Add(function()
		for part, anchored in originalAnchored do
			if part.Parent then
				part.Anchored = anchored
			end
		end
		for part, massless in originalMassless do
			if part.Parent then
				part.Massless = massless
			end
		end
		if root.Parent then
			root.RootPriority = originalRootPriority
		end
	end)

	for _, part in parts do
		originalAnchored[part] = part.Anchored
		part.Anchored = false
	end

	-- Welded AFTER the unanchor pass, not during it: a WeldConstraint created while either part is still
	-- anchored is legal but leaves the pair in a state Roblox only re-solves on the next anchor change,
	-- and the failure mode is a hull that flies with three meshes left hanging in the air behind it.
	for _, part in parts do
		if part == root then
			continue
		end
		if BlimpConstants.Physics.MasslessNonRootParts then
			originalMassless[part] = part.Massless
			part.Massless = true
		end

		local weld = Instance.new("WeldConstraint")
		weld.Name = "BlimpHullWeld"
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = root
		trove:Add(weld)
	end

	-- Keeps the hull the assembly's root part once bodies start being welded on -- a character's
	-- HumanoidRootPart arrives with a high RootPriority of its own, and an assembly rooted on a passenger
	-- is one whose centre of rotation walks around the deck with them.
	root.RootPriority = 127

	local attachment = Instance.new("Attachment")
	attachment.Name = "BlimpDriveAnchor"
	attachment.Parent = root
	trove:Add(attachment)

	-- OneAttachment mode on both: there is no second body to align against, only a target pose the server
	-- computes. Responsiveness is deliberately low -- see BlimpConstants.Physics.
	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "BlimpDrivePosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	alignPosition.ReactionForceEnabled = false
	alignPosition.RigidityEnabled = false
	alignPosition.Responsiveness = BlimpConstants.Physics.PositionResponsiveness
	-- Hard ceiling on how fast THIS CONSTRAINT may ever move the hull while closing a position error, no
	-- matter how large that error is or how it got there -- see BlimpConstants.Physics.MaxDriveVelocity's
	-- own comment. Only takes effect while RigidityEnabled is false, which this constraint already is.
	alignPosition.MaxVelocity = BlimpConstants.Physics.MaxDriveVelocity
	alignPosition.Position = root.Position
	alignPosition.Parent = root
	trove:Add(alignPosition)

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "BlimpDriveOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.RigidityEnabled = false
	alignOrientation.Responsiveness = BlimpConstants.Physics.OrientationResponsiveness
	alignOrientation.CFrame = root.CFrame.Rotation
	alignOrientation.Parent = root
	trove:Add(alignOrientation)

	local assembly: Assembly = {
		Model = model,
		Root = root,
		Attachment = attachment,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
		HullParts = parts,
		Trove = trove,
	}

	BlimpAssembly.RefreshForceLimits(assembly)
	BlimpAssembly.ClaimOwnership(assembly)

	logger:info("Assembly built", {
		model = model:GetFullName(),
		root = root.Name,
		parts = #parts,
		mass = root.AssemblyMass,
	})

	return assembly
end

-- Undoes Build entirely: constraints and welds destroyed, recorded properties restored. Safe on a model
-- that is already being destroyed -- every restore checks the part still has a Parent first.
function BlimpAssembly.Destroy(assembly: Assembly): ()
	assembly.Trove:Clean()
end

return BlimpAssembly
