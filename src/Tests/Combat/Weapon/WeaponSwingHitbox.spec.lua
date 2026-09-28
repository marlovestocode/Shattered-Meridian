--!strict
-- Covers the per-weapon swing hitbox: the Attributes a weapon's own build carries
-- (WeaponRoster.HITBOX_ATTRIBUTE_NAMES), how they reach a stage's geometry, and the two that do not
-- reach it through the stage at all -- Mode, which picks the swing's ANCHOR in DefaultMoveRegistry's
-- projection, and SpawnDelay, which AttackCatalog adds to WindupSeconds at the very end of the chain.
--
-- Driven through the REAL roster against REAL fixture models rather than by calling the readers
-- directly, because every failure this guards against is a link in a five-module chain
-- (Workspace model -> WeaponRoster -> DefaultMoveRegistry -> MoveTypes -> AttackCatalog) rather than a
-- wrong number in any one of them. A unit test of the reader would have passed throughout the bug
-- where a marked clip silently ate SpawnDelay.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local ROSTER = WeaponFixture.Install()
local WEAPON = ROSTER[1]
local OTHER = ROSTER[2]
local BASIC_1 = `default:{WEAPON}:Basic:1`

-- Every Attribute this spec ever sets, cleared wholesale between cases. Listed rather than tracked so
-- a case that errors midway still leaves the roster clean for the next spec file -- the fixture is
-- VM-wide shared state, and a leaked Mode="Blade" would retune combat for everything after it.
local ATTRIBUTE_NAMES = { "Mode", "Size", "Offset", "ScaleWithWeaponReach", "SpawnDelay" }

local function configure(weaponId: string, attributes: { [string]: any }): ()
	local values = WeaponFixture.HitboxValues(weaponId)
	assert(values, `fixture weapon {weaponId} is missing`)
	for name, value in attributes do
		values:SetAttribute(name, value)
	end
	WeaponFixture.Rebuild()
end

return function()
	afterEach(function()
		for _, weaponId in ROSTER do
			local values = WeaponFixture.HitboxValues(weaponId)
			if values then
				for _, name in ATTRIBUTE_NAMES do
					values:SetAttribute(name, nil)
				end
			end
		end
		WeaponFixture.Rebuild()
		AttackCatalog.Reset()
	end)

	describe("resolution", function()
		it("falls back to the house config for a weapon that authors nothing", function()
			-- The whole backward-compatibility claim: every weapon that existed before these Attributes
			-- did keeps swinging exactly what it swung.
			local house = CombatConstants.Weapons.SwingHitbox
			local resolved = WeaponRoster.SwingHitbox(WEAPON)
			expect(resolved.Mode).to.equal(house.Mode)
			expect(resolved.Size).to.equal(house.Size)
			expect(resolved.ScaleWithWeaponReach).to.equal(house.ScaleWithWeaponReach)
			expect(resolved.SpawnDelaySeconds).to.equal(house.SpawnDelaySeconds)
		end)

		it("finds a suffix-named value object nested inside the weapon", function()
			-- The real Cutlass ships Weapons/Cutlass/Cutlass/CutlassHitboxValues -- nested, and named for
			-- the weapon rather than generically. A lookup that only handled a direct child named exactly
			-- "HitboxValues" would silently apply nothing, which is the failure mode Handle already had
			-- to be rescued from in WeaponModelRegistry.wrapModel.
			configure(WEAPON, { Size = Vector3.new(3, 4, 5) })
			expect(WeaponRoster.SwingHitbox(WEAPON).Size).to.equal(Vector3.new(3, 4, 5))
		end)

		it("keeps one weapon's config off every other weapon", function()
			configure(WEAPON, { Size = Vector3.new(3, 4, 5), SpawnDelay = 0.5 })
			local other = WeaponRoster.SwingHitbox(OTHER)
			expect(other.Size).to.equal(CombatConstants.Weapons.SwingHitbox.Size)
			expect(other.SpawnDelaySeconds).to.equal(0)
		end)

		it("returns the house config for an id the roster does not know, never nil", function()
			-- A combatant holding a weapon deleted out from under them mid-session. "Swings the house
			-- box" beats "has no hitbox at all", and callers should never have to branch.
			local resolved = WeaponRoster.SwingHitbox("no-such-weapon")
			expect(resolved).to.be.ok()
			expect(resolved.Size).to.equal(CombatConstants.Weapons.SwingHitbox.Size)
		end)

		it("converts the Vector3 Offset Attribute into a CFrame once, at resolution", function()
			-- Roblox Attributes cannot hold a CFrame, so the Attribute is a translation and the config
			-- is not. If this ever regressed to storing the Vector3, every stage's Offset would be the
			-- wrong type and the engine would compose garbage against the root.
			configure(WEAPON, { Offset = Vector3.new(0, 1, -6) })
			local offset = WeaponRoster.SwingHitbox(WEAPON).Offset
			expect(typeof(offset)).to.equal("CFrame")
			expect(offset.Position).to.equal(Vector3.new(0, 1, -6))
		end)

		it("freezes the resolved config, so a consumer cannot retune the weapon for everyone", function()
			-- Handed out by reference through SwingHitbox and shared with DefaultMoveRegistry's cached
			-- descriptors -- the same shared-table hazard the stage tables are deep-copied to avoid.
			local resolved = WeaponRoster.SwingHitbox(WEAPON)
			expect(function()
				(resolved :: any).Size = Vector3.new(1, 1, 1)
			end).to.throw()
		end)
	end)

	describe("validation", function()
		it("ignores an Attribute of the wrong type rather than honouring it", function()
			-- An Attribute is a text field somebody types into. Same contract as WeaponRoster.multiplier.
			configure(WEAPON, { Size = "enormous", SpawnDelay = "soon", ScaleWithWeaponReach = 3 })
			local house = CombatConstants.Weapons.SwingHitbox
			local resolved = WeaponRoster.SwingHitbox(WEAPON)
			expect(resolved.Size).to.equal(house.Size)
			expect(resolved.SpawnDelaySeconds).to.equal(house.SpawnDelaySeconds)
			expect(resolved.ScaleWithWeaponReach).to.equal(house.ScaleWithWeaponReach)
		end)

		it("ignores an unrecognised Mode", function()
			configure(WEAPON, { Mode = "Bodybox" }) -- lower b: a real typo, not a synonym
			expect(WeaponRoster.SwingHitbox(WEAPON).Mode).to.equal(CombatConstants.Weapons.SwingHitbox.Mode)
		end)

		it("clamps an absurd Size per axis, keeping the axes that were fine", function()
			-- Component-wise: (8, 8, 900) is a builder who meant something on two axes and fat-fingered
			-- the third. Rejecting the whole vector would throw away the two good numbers.
			configure(WEAPON, { Size = Vector3.new(8, 8, 9000) })
			local size = WeaponRoster.SwingHitbox(WEAPON).Size
			expect(size.X).to.equal(8)
			expect(size.Y).to.equal(8)
			expect(size.Z).to.equal(512)
		end)

		it("clamps a negative Size rather than inverting the box", function()
			configure(WEAPON, { Size = Vector3.new(-4, 8, 8) })
			expect(WeaponRoster.SwingHitbox(WEAPON).Size.X > 0).to.equal(true)
		end)

		it("clamps SpawnDelay to the maximum rather than stranding the swing", function()
			-- 60 is someone entering milliseconds. A hitbox a minute late is diagnosable; one that
			-- silently ignored the delay is not.
			configure(WEAPON, { SpawnDelay = 60 })
			expect(WeaponRoster.SwingHitbox(WEAPON).SpawnDelaySeconds).to.equal(2)
		end)

		it("refuses a negative SpawnDelay, which would pull the hitbox forward", function()
			configure(WEAPON, { SpawnDelay = -1 })
			expect(WeaponRoster.SwingHitbox(WEAPON).SpawnDelaySeconds).to.equal(0)
		end)
	end)

	describe("reaching the swing geometry", function()
		it("stamps the weapon's box onto every stage", function()
			-- Basic, Heavy and Finisher alike -- a config that only reached the M1 string would read in
			-- play as "my heavy has a different range for no reason."
			configure(WEAPON, { Size = Vector3.new(3, 4, 5), Offset = Vector3.new(0, 0, -2.5) })
			local entry = WeaponRoster.Get(WEAPON)
			expect(entry).to.be.ok()
			local stages = (entry :: any).Stages
			for _, stage in stages.Basic do
				expect(stage.Size).to.equal(Vector3.new(3, 4, 5))
				expect(stage.Offset.Position).to.equal(Vector3.new(0, 0, -2.5))
			end
			for _, stage in stages.Heavy do
				expect(stage.Size).to.equal(Vector3.new(3, 4, 5))
			end
			expect(stages.Finisher.Size).to.equal(Vector3.new(3, 4, 5))
		end)

		it("leaves the box alone when WeaponReach scaling is off", function()
			-- The default. Every weapon swings the one volume a player learns once, and WeaponReach is a
			-- damage/speed flavour rather than a geometric one.
			configure(WEAPON, { Size = Vector3.new(8, 8, 8), ScaleWithWeaponReach = false })
			local stage = (WeaponRoster.Get(WEAPON) :: any).Stages.Basic[1]
			expect(stage.Size).to.equal(Vector3.new(8, 8, 8))
		end)

		it("anchors to the weapon only when that weapon asks for Blade mode", function()
			-- Mode picks the ANCHOR, which is not a stage field at all -- it is resolved in
			-- DefaultMoveRegistry's projection, and it also decides SizeFromAttachmentPart downstream.
			-- Per weapon, so a roster can mix a modelled-blade weapon with body-box ones.
			configure(WEAPON, { Mode = "Blade" })
			expect((AttackCatalog.Get(BASIC_1) :: any).Definition.AttachmentPart).to.equal("Weapon")
			expect((AttackCatalog.Get(`default:{OTHER}:Basic:1`) :: any).Definition.AttachmentPart).to.equal("Root")
		end)

		it("anchors to the root in BodyBox mode, which is what un-sizes the swing from the blade", function()
			expect((AttackCatalog.Get(BASIC_1) :: any).Definition.AttachmentPart).to.equal("Root")
			expect((AttackCatalog.Get(BASIC_1) :: any).Definition.SizeFromAttachmentPart).to.equal(false)
		end)
	end)

	describe("SpawnDelay", function()
		-- Baseline Basic[1]: WindupSeconds 0.31, ActiveSeconds 0.22, RecoverySeconds 0.14, Cooldown 0.44.
		local ANIMATION_ID = "rbxassetid://104588315151150" -- AttackAnimations' baseline Basic:1 clip

		local function serveMarker(time: number): ()
			AttackWindows.SetExtractor(function(): KeyframeSequence?
				local sequence = Instance.new("KeyframeSequence")
				local keyframe = Instance.new("Keyframe")
				keyframe.Time = time
				local marker = Instance.new("KeyframeMarker")
				marker.Name = "AttackM1"
				marker.Parent = keyframe
				keyframe.Parent = sequence
				return sequence
			end)
		end

		afterEach(function()
			AttackWindows.Reset()
			AttackWindows.SetExtractor(function()
				return nil
			end)
		end)

		it("adds to the stage's own WindupSeconds rather than replacing it", function()
			configure(WEAPON, { SpawnDelay = 0.2 })
			expect((AttackCatalog.Get(BASIC_1) :: any).Definition.WindupSeconds).to.be.near(0.51, 1e-6)
		end)

		it("changes nothing at zero, which is what every existing weapon has", function()
			expect((AttackCatalog.Get(BASIC_1) :: any).Definition.WindupSeconds).to.be.near(0.31, 1e-6)
		end)

		it("survives a clip's own marker override instead of being discarded by it", function()
			-- THE BUG THIS WHOLE ORDERING EXISTS FOR. The marker REPLACES WindupSeconds, so a delay
			-- folded in any earlier is kept for weapons whose clips have no marker and silently dropped
			-- for the ones that do -- the same move behaving two ways depending on whether an animator
			-- had touched the asset.
			configure(WEAPON, { SpawnDelay = 0.2 })
			serveMarker(0.10) -- clears the Cooldown bound: 0.10 + 0.22 + 0.14 = 0.46 >= 0.44
			AttackWindows.Prefetch(ANIMATION_ID)
			expect((AttackCatalog.Get(BASIC_1) :: any).Definition.WindupSeconds).to.be.near(0.30, 1e-6)
		end)

		it("is not counted by the marker's own Cooldown bound", function()
			-- The bound guards the marker, and must judge it on the clip's own timing. Letting the delay
			-- pad the sum would wave through a marker that genuinely does leave dead time after the
			-- swing, on exactly the weapons that had a delay set.
			--
			-- The bound only applies while the clip's LENGTH is unknown (with it known, the swing is the
			-- clip's length and the bound has nothing to guard), so clip syncing is switched off here.
			configure(WEAPON, { SpawnDelay = 0.2 })
			serveMarker(0.05) -- 0.05 + 0.22 + 0.14 = 0.41, under the 0.44 Cooldown: rejected
			AttackWindows.Prefetch(ANIMATION_ID)
			LiveTuningContract.withRestore(function()
				AttackConstants.Windows.SyncToClipLength = false
				expect((AttackCatalog.Get(BASIC_1) :: any).Definition.WindupSeconds).to.be.near(0.51, 1e-6)
			end, function()
				AttackConstants.Windows.SyncToClipLength = true
			end)
		end)

		it("applies to Heavy and Finisher too, which no marker ever touches", function()
			configure(WEAPON, { SpawnDelay = 0.2 })
			local heavy = AttackCatalog.Get(`default:{WEAPON}:Heavy:1`) :: any
			expect(heavy.Definition.WindupSeconds).to.be.near(0.8, 1e-6) -- 0.600 + 0.2
			local finisher = AttackCatalog.Get(`default:{WEAPON}:Finisher`) :: any
			expect(finisher.Definition.WindupSeconds).to.be.near(0.48, 1e-6) -- 0.28 + 0.2
		end)

		it("leaves the standalone fist attacks alone -- they have no weapon to carry one", function()
			configure(WEAPON, { SpawnDelay = 0.2 })
			local dash = AttackCatalog.Get("default:DashPunch") :: any
			expect(dash).to.be.ok()
			expect(dash.Definition.WindupSeconds).to.be.near(0.4, 1e-6)
		end)
	end)
end
