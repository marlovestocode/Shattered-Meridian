--!strict
--[[
	Rig.lua

	Owns: every body a spec stands on -- the one place a test model with a Humanoid and a root is built, so
	no spec writes `local function makeDummy` / `makeRig` / `makeCharacter` of its own (check-spec-literals
	fails one). Twenty specs did, and the cohesion audit traced 34 of the 43 red tests it examined to
	fixture drift: stand-ins missing an API, a root joint looked for under the wrong part, a combatant
	nobody registered. Those are what private copies of a builder produce.

	THE KINDS (all return a Body, `{ Model, Root, Humanoid }`):
	  Dummy      A combat target: anchored (so no assertion races gravity), non-colliding root, Humanoid with
	             RequiresNeck off. What HitboxEngine/Defense/Damage/Grab/Domain specs stand on.
	  Character  A physics-shaped body: unanchored, collidable, HipHeight 2. What the parkour specs drive.
	  R6         A real R6 rig from a HumanoidDescription (so a real RootJoint, Animator and joints), anchored.
	             What the AnimationManager specs bind to.
	  Limbs      Six anchored R6-named limbs and nothing else (no Humanoid, no root). What the afterimage/FX
	             specs clone from.
	  Bare       A Model with a Humanoid and, optionally, one Part -- never parented. The Attribute-only
	             admin specs (AdminActionSystem) that need no world at all. Returns multiple values, not a Body.

	THE ROOT JOINT IS OPT-IN (`RootJoint = true`): a Torso and a Motor6D named "RootJoint" under
	HumanoidRootPart, as an R6 character has. It is not the default because HitboxEngine's hurtbox gather
	indexes a body's direct-child BaseParts -- a spec that did not ask for a torso must not get a second
	hurtbox. R6 already has a real one.

	WHAT IT DOES NOT OWN: registering a body with a combat layer (CombatHarness.Combatant), arming it with a
	weapon, or resetting a layer. Rig builds Instances; the layers are CombatHarness's. Keeping that line is
	what lets a parkour or FX spec use Rig without loading the combat stack.

	CLEANUP. Everything Rig builds, and anything handed to Rig.Track (a wall, a Tool, a stray model), is
	destroyed by one Rig.DestroyAll() -- the loop every spec's afterEach used to write over its own private
	`spawned` table. Call it AFTER the layer resets (CombatHarness.Teardown does), as those loops did.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Rig = {}

export type Body = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
}

export type DummyOptions = {
	-- false leaves the root unanchored. Default true.
	Anchored: boolean?,
	-- Sets MaxHealth and Health. Default: the Humanoid's own 100.
	Health: number?,
	-- Set on the Humanoid, where the combat Attribute seams live.
	Attributes: { [string]: any }?,
	-- Where the model is parented. Default Workspace.
	Parent: Instance?,
	-- Adds a Torso and a Motor6D "RootJoint" under HumanoidRootPart. Default false (see the header).
	RootJoint: boolean?,
}

local tracked: { Instance } = {}
local nextUserId = 0

-- Adds `instance` to what DestroyAll cleans up.
function Rig.Track(instance: Instance): ()
	table.insert(tracked, instance)
end

-- Destroys everything built or tracked since the last call. Safe on an already-destroyed instance.
function Rig.DestroyAll(): ()
	for _, instance in tracked do
		instance:Destroy()
	end
	table.clear(tracked)
end

local function addRootJoint(model: Model, root: BasePart, anchored: boolean): ()
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Anchored = anchored
	torso.CanCollide = false
	torso.CFrame = root.CFrame
	torso.Parent = model

	local joint = Instance.new("Motor6D")
	joint.Name = "RootJoint"
	joint.Part0 = root
	joint.Part1 = torso
	joint.Parent = root
end

function Rig.Dummy(name: string, position: Vector3?, lookAt: Vector3?, options: DummyOptions?): Body
	local opts: DummyOptions = options or {}
	local anchored = opts.Anchored ~= false

	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = anchored
	root.CanCollide = false
	if position then
		root.CFrame = if lookAt then CFrame.lookAt(position, lookAt) else CFrame.new(position)
	end
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	if opts.Health then
		humanoid.MaxHealth = opts.Health
		humanoid.Health = opts.Health
	end
	for attribute, value in opts.Attributes or {} do
		humanoid:SetAttribute(attribute, value)
	end
	humanoid.Parent = model

	if opts.RootJoint then
		addRootJoint(model, root, anchored)
	end

	model.PrimaryPart = root
	model.Parent = if opts.Parent then opts.Parent else Workspace
	Rig.Track(model)
	return { Model = model, Root = root, Humanoid = humanoid }
end

-- Unanchored and collidable, with the hip height a standing character has, and the Humanoid left at its
-- engine defaults (RequiresNeck included). The shape ParkourMotor and the parkour states need to push.
function Rig.Character(name: string, position: Vector3?, lookAt: Vector3?): Body
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	if position then
		root.CFrame = if lookAt then CFrame.lookAt(position, lookAt) else CFrame.new(position)
	end
	root.Anchored = false
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 2
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace
	Rig.Track(model)
	return { Model = model, Root = root, Humanoid = humanoid }
end

function Rig.R6(name: string): Body
	local model =
		Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R6)
	model.Name = name
	local root = model.PrimaryPart :: BasePart
	root.Anchored = true
	model.Parent = Workspace
	Rig.Track(model)
	return { Model = model, Root = root, Humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid }
end

Rig.LIMB_NAMES = table.freeze({ "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" })

-- Six anchored, R6-named limbs in a row at height 50. No Humanoid and no root: what a FX spec clones.
function Rig.Limbs(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	for index, limb in Rig.LIMB_NAMES do
		local part = Instance.new("Part")
		part.Name = limb
		part.Anchored = true
		part.Size = Vector3.new(1, 2, 1)
		part.CFrame = CFrame.new(index * 2, 50, 0)
		part.Parent = model
	end
	model.Parent = Workspace
	Rig.Track(model)
	return model
end

-- A Model with a Humanoid and, when asked, one Part (Transparency 0) -- never parented, never tracked.
function Rig.Bare(withPart: boolean?): (Model, Humanoid, BasePart?)
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	local part: BasePart? = nil
	if withPart then
		local created = Instance.new("Part")
		created.Transparency = 0
		created.Parent = model
		part = created
	end
	return model, humanoid, part
end

-- The table-cast-to-Player stand-in the harness uses where `Instance.new("Player")` errors. Carries only
-- what a player-keyed System reads off a Player: Name, UserId, Character. `userId` overrides the counter.
function Rig.FakePlayer(name: string, character: Model?, userId: number?): Player
	nextUserId += 1
	return { Name = name, UserId = userId or nextUserId, Character = character } :: any
end

return Rig
