--!strict
--[[
	WeaponModelRegistry.lua

	Owns: turning a hand-built weapon model sitting at ONE FIXED PATH in Studio -- Workspace.Weapons --
	into a cached, equip-ready Tool template, keyed by that child's own Name, and keeping that map live
	as models are added or removed from the folder while the server runs. This is the ONLY source
	WeaponModels.Build has -- there is no procedural fallback (one existed briefly and was cut once this
	pipeline replaced the need for a stand-in; see that module's own header) -- so a weapon whose
	ModelId has no matching child in the folder simply fights empty-handed.

	THE WHOLE AUTHORING CONTRACT, and nothing else:

	  1. In Studio, create a Folder named "Weapons" directly under Workspace, if it doesn't already
	     exist. ONE FIXED PATH -- Workspace.Weapons -- not a tag that can be scattered anywhere in the
	     game; this registry reads nothing outside that folder.
	  2. Drop your sword model in as a DIRECT CHILD of that folder -- a Tool, or a plain Model. Its Name
	     IS its weapon id (Shared/Combat/WeaponRoster.lua reads the same folder and keys off the same
	     Name), so there is no tag and no Attribute to set for it. Two children sharing a Name is a
	     build error, not a variant system: the registry logs it and keeps whichever registered first,
	     the same "extra is a build error, not a feature" rule Shared/Blimp/BlimpTagging.lua's
	     ResolveStations/ResolveFuelStation already apply to a second Helm or Furnace.
	  3. If it's already a Tool, it is cloned exactly as authored -- Handle, Grip, every child -- and
	     this registry does not touch any of it. Full author control; skip the rest of this contract.
	     The one requirement it does still check is Roblox's own: Handle must be a DIRECT child of the
	     Tool. Unlike the Model case below, a nested one is reported rather than lifted, because
	     "exactly as authored" is the whole promise of this case.
	  4. If it's a plain Model, it must contain a BasePart named "Handle" SOMEWHERE inside it -- at ANY
	     depth. Model > MeshPart > Handle is fine and needs no restructuring; the Handle is found and
	     lifted to the top of the built Tool automatically (see wrapModel for why the lift is
	     mandatory and why it cannot move the art). A Model with no part named Handle anywhere is
	     logged and skipped -- that weapon stays empty-handed until it's fixed -- rather than guessed
	     at: there is no reliable way to pick a grip part from geometry alone.
	  5. Optional, Model case only: a CFrame Attribute named WeaponGripOffset on the model sets the
	     resulting Tool.Grip precisely. Absent, it defaults to CFrame.new() (identity) -- retune it in
	     Studio if the sword reads as floating, clipped, or backwards in a real player's hand. Every
	     other BasePart in the model, at any depth, is welded to the Handle so the assembly is one
	     rigid piece, and each is forced CanCollide = false / Massless = true: a held weapon that
	     collides with the world shoves its own wielder around, and a heavy one changes how they move.

	The folder is NEVER Rojo-synced (Workspace's Weapons folder has no $path entry in
	default.project.json), so it survives a `rojo build`/sync untouched -- exactly the same reason
	Blimp models sit directly in Studio rather than in the repo. The models inside it are NEVER moved or
	destroyed by this registry; it only ever CLONES what it finds, so a display copy left standing in
	the world (e.g. mounted on a rack) stays exactly where it is.

	Does not own: which weapon a Name belongs to (WeaponModels.lua's own WEAPON_MODELS map) or what
	happens when no template is registered for one (WeaponModels.Build's own nil fallback). Does not
	hand out the cached master directly -- WeaponModelRegistry.GetTemplate returns it so
	WeaponModels.Build can Clone() a fresh one per equip; handing out the master itself would let one
	character's equip mutate every other character already holding the same weapon.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

local logger = Logger.scope("WeaponModelRegistry")

local WeaponModelRegistry = {}

-- The one fixed location this whole module reads -- see this file's header. Not configurable per-call
-- on purpose: a single, well-known path is the entire point of this design over the tag-anywhere
-- version it replaced.

-- Grip tuning, as TWO Vector3 Attributes rather than one CFrame.
--
-- NOT A CFrame BECAUSE STUDIO CANNOT SET ONE. The Attributes panel supports string/number/boolean/
-- Vector3/Color3/UDim/Rect and a handful more -- CFrame is NOT among them, so a CFrame Attribute can
-- only ever be written from a script. This started life as one and was unusable for the exact job it
-- existed to do: letting whoever is holding the model in Studio nudge it until it sits right. Euler
-- degrees and studs are also simply easier to reason about by hand than a matrix.
local GRIP_ROTATION_ATTRIBUTE = "WeaponGripRotation"
local GRIP_POSITION_ATTRIBUTE = "WeaponGripPosition"

-- Applied when a model sets no WeaponGripRotation of its own: a half turn about Y, which turns the
-- blade to face the other way WITHOUT rolling it over.
--
-- THE AXIS MATTERS AND GETTING IT WRONG IS VISIBLE. This was Z for one revision, which rolls the
-- weapon end-over-end and presents as the sword being held upside down -- the exact complaint that
-- produced this comment. Y turns it around the way "point it the other way" means; Z and X both flip
-- which way is up.
--
-- A DEFAULT, NOT A CONSTRAINT. Any model that wants a different orientation sets its own
-- WeaponGripRotation Attribute and this is ignored entirely -- fix a single misoriented weapon THERE
-- rather than here, because every other weapon is reading this same number.
local DEFAULT_GRIP_ROTATION = Vector3.new(0, 180, 0)

local started = false
local addedConnection: RBXScriptConnection? = nil
local removedConnection: RBXScriptConnection? = nil

-- Keyed by the SOURCE child instance, not the derived master -- a ChildRemoved signal only ever hands
-- back the source, so this is what makes unregisterSource able to find (and undo) exactly the
-- registration that source produced, even if it lost a same-name race and never made it into
-- mastersByName at all.
local sourceEntries: { [Instance]: { Name: string, Master: Tool } } = {}
local mastersByName: { [string]: Tool } = {}

local function weld(part0: BasePart, part1: BasePart): ()
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = part0
	constraint.Part1 = part1
	constraint.Parent = part1
end

-- One Vector3 Attribute, or `fallback`. A wrong-typed value is logged and ignored rather than
-- coerced -- an Attribute is a field somebody types into, and silently reading a mistyped one as zero
-- would present as "my grip setting does nothing" with no explanation.
local function vectorAttribute(source: Instance, attributeName: string, fallback: Vector3): Vector3
	local raw = source:GetAttribute(attributeName)
	if raw == nil then
		return fallback
	end
	if typeof(raw) == "Vector3" then
		return raw :: Vector3
	end
	logger:warn("Ignoring non-Vector3 grip Attribute", {
		source = source:GetFullName(),
		attribute = attributeName,
	})
	return fallback
end

-- How the Handle sits in the hand, composed from the two Studio-settable Attributes above.
--
-- Rotation is applied BEFORE translation (`CFrame.new(pos) * angles`, read right to left) so the
-- position Attribute means "shift it this far along the HAND's axes", which is what somebody nudging
-- numbers in Studio expects. Composing the other way would make every position tweak depend on the
-- current rotation, so fixing the angle would silently move the sword as well.
local function resolveGripOffset(source: Instance): CFrame
	local degrees = vectorAttribute(source, GRIP_ROTATION_ATTRIBUTE, DEFAULT_GRIP_ROTATION)
	local position = vectorAttribute(source, GRIP_POSITION_ATTRIBUTE, Vector3.zero)
	return CFrame.new(position) * CFrame.Angles(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
end

-- The three physics properties a part MUST have to be carried, forced regardless of how the world
-- model was built. All three are properties of BEING HELD rather than authoring choices, and the
-- alternative is every artist remembering all three on every part of every weapon forever.
--
-- ANCHORED IS THE IMPORTANT ONE, AND ITS ABSENCE SHIPPED A TELEPORT. A weapon sitting in the world is
-- anchored (that is what keeps it on its rack), the template is a clone of that model, and
-- Humanoid:EquipTool welds the Handle to the character's hand. Welding an ANCHORED part to a character
-- does not bring the part to the hand -- the anchor wins and the CHARACTER is dragged to the part. So
-- drawing a sword yanked the player across the map to wherever its world model was standing.
--
-- CanCollide: a blade that collides with the world shoves its own wielder around. Massless: a heavy
-- one changes how they move.
local function makeHoldable(part: BasePart): ()
	part.Anchored = false
	part.CanCollide = false
	part.Massless = true
end

-- Every BasePart in `assembly` reachable from `root` by following Motor6D joints, `root` included.
--
-- WHAT THIS PROTECTS, AND WHY IT HAD TO EXIST. wrapModel below welds the assembly rigid so a weapon
-- built as a dozen loose meshes still moves as one piece. That is right for the overwhelmingly common
-- case (a static sword) and CATASTROPHIC for a rigged one: a weapon authored in Blender with a real
-- Motor6D chain -- a blade that swings on its hilt, a segmented whip, a sword that turns in the hand
-- across a swing -- carries joints the character's Animator is supposed to drive, and a WeldConstraint
-- laid over the same part pair pins that joint shut. The clip still loads, still plays, still reports
-- the right length and weight; the articulated parts simply never move. Zero keyframes land, with no
-- error anywhere -- the same shape of silent failure a nested Handle already had to be rescued from,
-- one layer down.
--
-- SO ARTICULATION WINS OVER RIGIDITY, but only where it actually exists: a part joined into the
-- Motor6D graph is left for the Animator, and every part OUTSIDE that graph is still welded exactly as
-- before. A weapon with no Motor6Ds in it reaches the identical result it always did, which is what
-- makes this safe to apply to every weapon rather than gating it behind an Attribute somebody has to
-- remember to set.
--
-- ROOTED AT THE HANDLE, NOT "ANY PART THAT HAS A MOTOR6D ON IT". A joint chain that never connects back
-- to the Handle is not part of the grip assembly, and sparing it would leave those parts with nothing
-- holding them to the weapon at all -- so they fall through to the weld, which is the same answer they
-- got before. Only the chain actually hanging off the grip is spared.
local function motoredParts(assembly: Instance, root: BasePart): { [BasePart]: true }
	local joints: { Motor6D } = {}
	for _, descendant in assembly:GetDescendants() do
		if descendant:IsA("Motor6D") then
			table.insert(joints, descendant :: Motor6D)
		end
	end

	local reached: { [BasePart]: true } = { [root] = true }
	if #joints == 0 then
		return reached
	end

	-- Repeated sweeps to a fixed point rather than a real graph walk with an adjacency table: a
	-- hand-built weapon's joint chain is a handful of links, and the passes stop the moment one adds
	-- nothing, so building the index would cost more than the walk it saves.
	local grew = true
	while grew do
		grew = false
		for _, joint in joints do
			local part0, part1 = joint.Part0, joint.Part1
			if part0 and part1 then
				if reached[part0] and not reached[part1] then
					reached[part1] = true
					grew = true
				elseif reached[part1] and not reached[part0] then
					reached[part0] = true
					grew = true
				end
			end
		end
	end
	return reached
end

-- Wraps a cloned Model into a fresh equip-ready Tool -- Handle becomes the grip anchor, every other
-- BasePart in the assembly gets welded to it so the whole thing moves as one rigid piece. Returns nil
-- (and warns) if the clone has no BasePart named Handle anywhere -- see this file's header on why that
-- is a skip, not a guess. Consumes `modelClone` either way: on success every child has been reparented
-- into the returned Tool, on failure it is destroyed here so a caller never has to clean up after it.
--
-- HANDLE IS FOUND AT ANY DEPTH, THEN LIFTED TO BE A DIRECT CHILD OF THE TOOL. Both halves matter and
-- neither is optional:
--
--   * Found at any depth, because an imported/grouped weapon naturally arrives as Model > MeshPart >
--     Handle rather than with the Handle sitting at the top level. Requiring the flat shape would mean
--     every artist restructuring every model by hand for no reason the engine actually cares about --
--     including the now-common shape of one outer weapon container holding both an authoring-only
--     "Animations" folder (see stripAnimationsFolders below) and the actual grip model a level deeper.
--   * Lifted to the top, because Roblox's own Tool.RequiresHandle grip looks for a direct child named
--     "Handle" and NOTHING ELSE -- it does not search. A Handle left nested is a Tool that silently
--     refuses to grip, which reads in play as "the sword is invisible" with no error anywhere.
--
-- BLADE GETS THE IDENTICAL TREATMENT, OPTIONALLY. Server/Combat/HitboxEngine/HitboxEngine.lua's
-- resolveAttachmentPart looks for a direct child of the equipped Tool named "Blade" (falling back to
-- Handle) so a weapon swing's hitbox can track -- and, with SizeFromAttachmentPart, size itself off --
-- the actual edge of the weapon rather than its grip. That lookup is not a search: a Blade left nested
-- (exactly the failure Handle already had to be rescued from) would silently and permanently fall back
-- to Handle-anchored geometry, with nothing here or there ever reporting it. Optional because not
-- every weapon needs one -- a model with no part named Blade simply has nothing to lift, and
-- HitboxEngine's own fallback chain (Handle, then hand, then root) degrades gracefully from there.
--
-- Reparenting a BasePart never moves it, and a WeldConstraint binds by reference rather than by
-- hierarchy, so lifting Handle/Blade out of the art cannot shift or break the assembly.
local function wrapModel(modelClone: Model, gripOffset: CFrame): Tool?
	local handleChild = modelClone:FindFirstChild("Handle", true)
	if not (handleChild and handleChild:IsA("BasePart")) then
		logger:warn("WeaponModels Model has no BasePart named Handle anywhere inside it; skipping", {
			model = modelClone.Name,
		})
		modelClone:Destroy()
		return nil
	end
	local handle = handleChild :: BasePart

	local bladeChild = modelClone:FindFirstChild("Blade", true)
	local blade = if bladeChild and bladeChild:IsA("BasePart") then bladeChild :: BasePart else nil

	local tool = Instance.new("Tool")
	tool.Name = modelClone.Name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.Grip = gripOffset

	-- Every BasePart in the assembly, at any depth, welded straight to the Handle -- not just the ones
	-- that happen to sit at the top level -- EXCEPT the ones already joined to it by a Motor6D chain.
	-- A weapon built as one grouped mesh and a weapon built as a dozen nested sub-models both end up
	-- equally rigid, and neither depends on the author having flattened anything; a weapon built as a
	-- real rig keeps its articulation instead. See motoredParts above for why that exception is not
	-- optional. Done BEFORE any reparenting, purely so this walks the tree once, while it is still
	-- whole.
	local articulated = motoredParts(modelClone, handle)
	for _, descendant in modelClone:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= handle then
			local part = descendant :: BasePart
			makeHoldable(part)
			if not articulated[part] then
				weld(handle, part)
			end
		end
	end

	makeHoldable(handle)
	-- Lifted out of the art first, so the loop below moves whatever it was nested in without carrying
	-- it back down -- see this function's header on why Handle (and, when present, Blade) has to end
	-- up at the top.
	handle.Parent = tool
	if blade then
		blade.Parent = tool
	end

	-- Snapshot the children before reparenting any of them -- GetChildren() is a live call, and
	-- reparenting into `tool` while iterating modelClone's own children would otherwise mutate the
	-- list this loop is walking.
	local children = modelClone:GetChildren()
	for _, child in children do
		child.Parent = tool
	end
	modelClone:Destroy()

	return tool
end

-- Drops every ProximityPrompt out of a built template.
--
-- The world models double as PICKUP points -- Server/Combat/Weapon/WeaponInventorySystem.lua puts a
-- hold-E prompt on each one -- and a template is a clone of that same model, so without this the
-- sword in a player's HAND would carry its own "pick up" prompt around with it. Stripped here, in the
-- one place templates are built, rather than depending on the registry happening to clone before the
-- inventory system happens to add prompts: that ordering holds today and would break silently.
local function stripPrompts(instance: Instance): ()
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		end
	end
end

-- Drops every Folder named "Animations" out of a built template.
--
-- That folder (Shared/Attack/AttackAnimations.lua's WEAPON_STAGE_FOLDERS / Shared/Combat/
-- WeaponIdleAnimations.lua's own IDLE lookup) is authoring-only content: both modules read it straight
-- off the SOURCE model in Workspace.Weapons, never off what a player is holding, so it has no
-- gameplay reason to exist on an equipped clone. The same "strip authoring-only content out of the
-- template" shape as stripPrompts just above, for the same reason: without this, every equipped copy
-- of every weapon would carry its own full clip library around in a player's hand for nothing.
local function stripAnimationsFolders(instance: Instance): ()
	for _, descendant in instance:GetDescendants() do
		if descendant.Name == "Animations" and descendant:IsA("Folder") then
			descendant:Destroy()
		end
	end
end

-- Builds this source's master Tool (a Tool clones as-is; a Model is wrapped per wrapModel above), or
-- nil if the source can't produce one -- an unsupported class, or a Model with no Handle.
local function buildMaster(source: Instance): Tool?
	if source:IsA("Tool") then
		local clone = source:Clone()
		-- DIRECT child only, and unlike the Model path this one does NOT go hunting for a nested
		-- Handle to lift. A Tool is taken exactly as authored (this file's header calls that out as
		-- full author control), so quietly restructuring one would break the only promise that case
		-- makes. The warning names the requirement instead, since the fix is a one-drag change.
		if not clone:FindFirstChild("Handle") then
			logger:warn("WeaponModels Tool has no Handle as a DIRECT child; ignoring", {
				source = source:GetFullName(),
				hint = "Roblox only grips a Handle parented directly to the Tool -- move it up a level",
			})
			clone:Destroy()
			return nil
		end
		clone.RequiresHandle = true
		clone.CanBeDropped = false
		stripPrompts(clone)
		stripAnimationsFolders(clone)
		-- Same anchor/collide/mass treatment the Model path gets -- a Tool authored in the world is just
		-- as likely to have been left anchored, and the teleport it causes is identical.
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				makeHoldable(descendant :: BasePart)
			end
		end
		return clone
	end

	if source:IsA("Model") then
		local wrapped = wrapModel(source:Clone(), resolveGripOffset(source))
		if wrapped then
			stripPrompts(wrapped)
			stripAnimationsFolders(wrapped)
		end
		return wrapped
	end

	logger:warn("Workspace.Weapons has an unsupported child type; ignoring", {
		source = source:GetFullName(),
		className = source.ClassName,
	})
	return nil
end

local function registerSource(source: Instance): ()
	if sourceEntries[source] then
		return
	end

	local name = source.Name
	local master = buildMaster(source)
	if not master then
		return
	end

	local existing = mastersByName[name]
	if existing then
		logger:warn("Two Workspace.Weapons children share the same Name; keeping the first", {
			name = name,
			ignoring = source:GetFullName(),
		})
		master:Destroy()
		return
	end

	-- Parented to nil rather than left under the source or moved into a holding folder: this Tool is a
	-- pure clone source from here on, never rendered or collided with, and the original the author
	-- placed in Workspace.Weapons is untouched.
	master.Parent = nil
	mastersByName[name] = master
	sourceEntries[source] = { Name = name, Master = master }
	logger:info("Registered weapon model", { name = name, source = source:GetFullName() })
end

local function unregisterSource(source: Instance): ()
	local entry = sourceEntries[source]
	if not entry then
		return
	end
	sourceEntries[source] = nil
	-- Only clears the live slot if THIS source's master is still the one occupying it -- a source that
	-- lost the duplicate-name race above was already destroyed and never held the slot, so removing it
	-- later must not evict whichever template is actually still in service.
	if mastersByName[entry.Name] == entry.Master then
		mastersByName[entry.Name] = nil
	end
	entry.Master:Destroy()
end

-- Workspace.Weapons itself, or nil (and a one-time warning) if nobody has created it yet -- an empty
-- game fights entirely empty-handed rather than erroring at boot.

-- Present-at-boot children and future ones through the same registerSource, which is the whole reason
-- the folder's existing children are read before ChildAdded is connected rather than after -- a child
-- added in the window between the two would otherwise register twice, and registerSource's own
-- sourceEntries guard is what makes the overlap harmless in the other direction. Idempotent.
--
-- A child ADDED elsewhere and reparented in later is picked up the same way (ChildAdded fires on
-- reparent, not just Instance.new) -- there is no separate "was this always here" case.
function WeaponModelRegistry.Start(): ()
	if started then
		return
	end
	started = true

	local container = WeaponAssets.Container(logger)
	if not container then
		logger:warn("Workspace.Weapons folder not found; every weapon will equip empty-handed")
		return
	end

	for _, child in container:GetChildren() do
		registerSource(child)
	end
	addedConnection = container.ChildAdded:Connect(registerSource)
	removedConnection = container.ChildRemoved:Connect(unregisterSource)
end

-- The cached master Tool registered for `modelId` (i.e. Workspace.Weapons's matching child Name), or
-- nil if nothing has been placed there yet. The MASTER itself, not a clone -- see this file's header on
-- why WeaponModels.Build, not this function, is what clones it per equip.
function WeaponModelRegistry.GetTemplate(modelId: string): Tool?
	return mastersByName[modelId]
end

-- Spec-only, mirrors every other System's Reset -- so one test's Workspace.Weapons children, and the
-- masters they produced, cannot leak into the next.
function WeaponModelRegistry.Reset(): ()
	if addedConnection then
		addedConnection:Disconnect()
		addedConnection = nil
	end
	if removedConnection then
		removedConnection:Disconnect()
		removedConnection = nil
	end
	for _, entry in sourceEntries do
		entry.Master:Destroy()
	end
	table.clear(sourceEntries)
	table.clear(mastersByName)
	started = false
end

return WeaponModelRegistry
