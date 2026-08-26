--!strict
--[[
	WeaponFixture.lua

	Stands up a real weapon roster for a spec: models in Workspace.Weapons, WeaponRoster.Start() run
	over them, and every downstream cache invalidated so the catalogue actually resolves their moves.

	EXISTS BECAUSE THE ROSTER IS A DATAMODEL FACT, NOT A CONSTANT. Combat specs used to lean on
	CombatConstants' hardcoded Primary/Secondary pair simply being there at require time. Weapons are
	models in Workspace.Weapons now (see Shared/Combat/WeaponRoster.lua), so a headless test place has
	NO weapons unless a spec makes some -- and a spec that forgets gets an empty roster, a catalogue
	with no weapon moves in it, and every Resolve returning nil, which reads as a broken module rather
	than a missing fixture.

	THE CACHE ORDER MATTERS and is the whole reason this is shared rather than copied per spec:
	DefaultMoveRegistry memoises its descriptor list off the roster on first use, and AttackCatalog
	reads through that. So Install must (1) place the models, (2) build the roster, (3) invalidate the
	registry's cache -- in that order. Getting it wrong yields a roster that exists but resolves
	nothing, with no error anywhere.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local WeaponModelRegistry = require(ReplicatedStorage.Shared.Combat.WeaponModelRegistry)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)

local WeaponFixture = {}

-- The two weapons every combat spec gets unless it asks for something else. Named plainly rather than
-- after real content ("Cutlass"/"Flambert") so a spec failure never reads as a statement about a
-- particular sword's tuning -- and so renaming real content can never break the suite.
WeaponFixture.DefaultIds = { "TestBlade", "TestDagger" }

-- Every slot Shared/Attack/AttackAnimations.lua's WEAPON_STAGE_FOLDERS, Shared/Combat/
-- WeaponIdleAnimations.lua's own IDLE lookup and Shared/Defense/WeaponDefenseAnimations.lua's
-- PARRY/BLOCK pair read off a weapon's Animations folder -- see this file's own AnimationSlot below,
-- which is what a spec actually calls to reach one.
local ANIMATION_SLOTS = { "IDLE", "M1", "M2", "M3", "HEAVY", "FINISHER", "PARRY", "BLOCK" }

-- Every slot Shared/Combat/WeaponSounds.lua reads off a weapon's SFX folder -- the audio counterpart to
-- ANIMATION_SLOTS above, and installed the same way and for the same reason: a fixture weapon that has
-- clips but no SFX folder would exercise only the "no folder at all" path, which no real weapon in
-- Workspace.Weapons is actually in.
local SOUND_SLOTS = { "Swing", "Block", "Parry", "Equip", "Sheathe" }

local installed: { Instance } = {}

-- Places `ids` in Workspace.Weapons, builds the roster from them, and clears the caches built off any
-- previous one. Returns the ids in roster order (which WeaponRoster sorts by name, so it may differ
-- from the order passed in -- callers that care should read the return, not their own argument).
function WeaponFixture.Install(ids: { string }?): { string }
	WeaponFixture.Remove()

	local folder = Workspace:FindFirstChild("Weapons")
	if not (folder and folder:IsA("Folder")) then
		local created = Instance.new("Folder")
		created.Name = "Weapons"
		created.Parent = Workspace
		folder = created
		table.insert(installed, created)
	end

	for _, id in ids or WeaponFixture.DefaultIds do
		local model = Instance.new("Model")
		model.Name = id
		-- A Handle so WeaponModelRegistry can wrap this same model into an equippable Tool -- the
		-- roster itself never reads geometry, but a fixture that only satisfies one of the two readers
		-- of Workspace.Weapons is a trap for the next spec.
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Parent = model
		-- A Blade too: HitboxEngine.resolveAttachmentPart's "Weapon" case anchors a real swing here, not
		-- on Handle (see that function's own header) -- a fixture weapon with no Blade would silently
		-- exercise only the fallback path, which is exactly the "satisfies one reader, not the other"
		-- trap the comment above already warns about, one door down.
		local blade = Instance.new("Part")
		blade.Name = "Blade"
		blade.Parent = model
		-- One Animation instance per slot, AnimationId left blank -- a spec that wants a clip sets
		-- AnimationSlot(id, slot).AnimationId itself and clears it back in its own afterEach, the same
		-- "set it, clear it" shape the old Attribute-based tests used, aimed at a real Instance property
		-- now instead of a model Attribute. Present (not absent) even when a case wants none of them,
		-- so a fixture weapon exercises the SAME "folder and slot exist, clip is blank" path a real
		-- unposed weapon in Workspace.Weapons takes, rather than the "no Animations folder at all" path
		-- nothing in production actually has.
		local animationsFolder = Instance.new("Folder")
		animationsFolder.Name = "Animations"
		animationsFolder.Parent = model
		for _, slot in ANIMATION_SLOTS do
			local slotFolder = Instance.new("Folder")
			slotFolder.Name = slot
			slotFolder.Parent = animationsFolder
			local animation = Instance.new("Animation")
			animation.Name = id .. slot
			animation.Parent = slotFolder
		end
		-- One Sound instance per SFX slot, SoundId left blank -- the exact mirror of the Animations
		-- folder above, including the "present but blank" default: a spec that wants a weapon to have a
		-- real swing sound sets SoundSlot(id, slot).SoundId itself and clears it back in its own
		-- afterEach.
		local sfxFolder = Instance.new("Folder")
		sfxFolder.Name = "SFX"
		sfxFolder.Parent = model
		for _, slot in SOUND_SLOTS do
			local slotFolder = Instance.new("Folder")
			slotFolder.Name = slot
			slotFolder.Parent = sfxFolder
			local sound = Instance.new("Sound")
			sound.Name = id .. slot
			sound.Parent = slotFolder
		end
		model.Parent = folder
		table.insert(installed, model)
	end

	WeaponRoster.Reset()
	WeaponRoster.Start()
	-- The model registry too, off the same folder: a fixture weapon that has numbers but no equippable
	-- Tool would let an end-to-end "draw it and see a sword" case pass its state assertions and prove
	-- nothing about the visual, which is precisely the seam that has broken before.
	WeaponModelRegistry.Reset()
	WeaponModelRegistry.Start()
	-- AFTER the roster exists -- see this file's header on why this order is not negotiable.
	DefaultMoveRegistry.ResetCache()

	return WeaponRoster.Order()
end

-- Find-or-create `weaponId`'s hitbox value object, so a spec can set the Attributes
-- WeaponRoster.HITBOX_ATTRIBUTE_NAMES reads (Mode/Size/Offset/ScaleWithWeaponReach/SpawnDelay).
--
-- NOT created by Install, deliberately: a weapon with no value object at all is what every OTHER spec
-- (and every un-retuned weapon in Workspace.Weapons) actually is, and a fixture that shipped one would
-- mean nothing ever exercises the house-default path.
--
-- Placed NESTED, under an inner Model, and named "<weaponId>HitboxValues" rather than the bare
-- "HitboxValues" -- both on purpose. That is the exact shape the real Cutlass ships
-- (Weapons/Cutlass/Cutlass/CutlassHitboxValues), so the fixture exercises findHitboxValues' recursive
-- search AND its suffix match rather than the easy direct-child exact-name case that a real weapon is
-- least likely to be in.
--
-- Same "set it, clear it" contract as AnimationSlot/SoundSlot below: a spec sets Attributes on the
-- returned instance and clears them in its own afterEach. Call Rebuild() after either, or the roster
-- is still holding the config it resolved at Install time.
function WeaponFixture.HitboxValues(weaponId: string): Instance?
	local weapons = Workspace:FindFirstChild("Weapons")
	if not weapons then
		return nil
	end
	local model = weapons:FindFirstChild(weaponId)
	if not model then
		return nil
	end
	local existing = model:FindFirstChild(weaponId .. "HitboxValues", true)
	if existing then
		return existing
	end
	local inner = model:FindFirstChild("Inner")
	if not inner then
		local created = Instance.new("Model")
		created.Name = "Inner"
		created.Parent = model
		inner = created
	end
	local values = Instance.new("StringValue")
	values.Name = weaponId .. "HitboxValues"
	values.Parent = inner
	return values
end

-- Re-resolves the roster (and the caches built off it) against whatever the fixture models now say.
--
-- The same three calls Install makes, in the same order and for the same reason -- see this file's
-- header. Split out because a spec changing a weapon's Attributes needs the rebuild WITHOUT the
-- teardown-and-replace Install does: Remove() destroys the models, which would take the very value
-- object the spec just configured with it.
function WeaponFixture.Rebuild(): ()
	WeaponRoster.Reset()
	WeaponRoster.Start()
	WeaponModelRegistry.Reset()
	WeaponModelRegistry.Start()
	DefaultMoveRegistry.ResetCache()
end

-- The Animation instance Install already placed for `weaponId`'s own `slot` ("IDLE"/"M1"/"M2"/"M3"/
-- "HEAVY"/"FINISHER"/"PARRY"/"BLOCK"), or nil if `weaponId` was never installed or `slot` isn't one of
-- the eight above.
-- A spec sets .AnimationId on the returned instance to give that slot a clip, and clears it back to ""
-- in its own afterEach -- never removes the Instance itself, which Remove()/the next Install() already
-- owns tearing down.
function WeaponFixture.AnimationSlot(weaponId: string, slot: string): Animation?
	local weapons = Workspace:FindFirstChild("Weapons")
	if not weapons then
		return nil
	end
	local model = weapons:FindFirstChild(weaponId)
	if not model then
		return nil
	end
	local animationsFolder = model:FindFirstChild("Animations")
	if not animationsFolder then
		return nil
	end
	local slotFolder = animationsFolder:FindFirstChild(slot)
	if not slotFolder then
		return nil
	end
	return slotFolder:FindFirstChildOfClass("Animation") :: Animation?
end

-- The Sound instance Install already placed for `weaponId`'s own `slot` ("Swing"/"Block"/"Parry"/
-- "Equip"/"Sheathe"), or nil if `weaponId` was never installed or `slot` isn't one of the five above.
-- Same contract as AnimationSlot directly above: a spec sets .SoundId on the returned instance and
-- clears it back to "" in its own afterEach, never removing the Instance itself.
function WeaponFixture.SoundSlot(weaponId: string, slot: string): Sound?
	local weapons = Workspace:FindFirstChild("Weapons")
	if not weapons then
		return nil
	end
	local model = weapons:FindFirstChild(weaponId)
	if not model then
		return nil
	end
	local sfxFolder = model:FindFirstChild("SFX")
	if not sfxFolder then
		return nil
	end
	local slotFolder = sfxFolder:FindFirstChild(slot)
	if not slotFolder then
		return nil
	end
	return slotFolder:FindFirstChildOfClass("Sound")
end

-- Tears the fixture down and clears the same caches Install does, so a spec that installed a roster
-- cannot leave it standing for one that expects none.
function WeaponFixture.Remove(): ()
	for index = #installed, 1, -1 do
		installed[index]:Destroy()
		installed[index] = nil
	end
	WeaponRoster.Reset()
	WeaponModelRegistry.Reset()
	DefaultMoveRegistry.ResetCache()
end

return WeaponFixture
