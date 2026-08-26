--!strict
-- Covers Shared/Combat/WeaponSounds.lua -- the per-weapon SFX/<Slot> Sound-instance lookup that backs
-- Client/FX/CombatAudio.lua's weapon layer (the sword's own whoosh, clang, parry ring, draw and sheathe).
--
-- Exercised against a REAL Workspace.Weapons folder (WeaponFixture), the same choice
-- WeaponIdleAnimations.spec.lua and AttackAnimations.spec.lua both make and for the same reason: the
-- whole claim this module makes is that it reads a real Sound instance off the actual model in that
-- folder.
--
-- INSTALLED ONCE, AT FILE SCOPE, NEVER REMOVED -- see AttackAnimations.spec.lua's own header for why:
-- WeaponFixture is shared VM-wide state, and every other consumer in this suite assumes it stays
-- installed once set up. Per-test isolation for the ids this file sets is handled by afterEach clearing
-- SoundId back to "".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local WeaponSounds = require(ReplicatedStorage.Shared.Combat.WeaponSounds)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local ROSTER = WeaponFixture.Install()
local weaponId = ROSTER[1]
local otherWeaponId = ROSTER[2]

local SLOTS = { "Swing", "Block", "Parry", "Equip", "Sheathe" }

local function soundSlot(id: string, slot: string): Sound
	return WeaponFixture.SoundSlot(id, slot) :: Sound
end

return function()
	afterEach(function()
		for _, id in { weaponId, otherWeaponId } do
			for _, slot in SLOTS do
				local sound = WeaponFixture.SoundSlot(id, slot)
				if sound then
					sound.SoundId = ""
					sound.Volume = 0.5
				end
			end
		end
	end)

	describe("WeaponSounds.Slots", function()
		it("names every slot CombatAudio reaches for", function()
			expect(WeaponSounds.Slots.Swing).to.equal("Swing")
			expect(WeaponSounds.Slots.Block).to.equal("Block")
			expect(WeaponSounds.Slots.Parry).to.equal("Parry")
			expect(WeaponSounds.Slots.Equip).to.equal("Equip")
			expect(WeaponSounds.Slots.Sheathe).to.equal("Sheathe")
		end)
	end)

	describe("WeaponSounds.Get", function()
		it("returns nil for a weapon whose slot has no SoundId authored", function()
			expect(WeaponSounds.Get(weaponId, "Swing")).to.equal(nil)
		end)

		it("returns nil for a weapon that is not in the roster", function()
			expect(WeaponSounds.Get("NoSuchWeapon", "Swing")).to.equal(nil)
		end)

		it("returns nil for nil/blank input rather than erroring", function()
			expect(WeaponSounds.Get(nil, "Swing")).to.equal(nil)
			expect(WeaponSounds.Get("", "Swing")).to.equal(nil)
		end)

		it("returns nil for a slot that does not exist rather than erroring", function()
			expect(WeaponSounds.Get(weaponId, "NotASlot")).to.equal(nil)
		end)

		it("resolves a weapon's own authored sound, carrying its authored volume", function()
			local sound = soundSlot(weaponId, "Swing")
			sound.SoundId = "rbxassetid://777777"
			-- An exactly-representable float32: Sound.Volume is single-precision, so a value like 0.42
			-- comes back as 0.41999998688697815 and an equality assertion on it would be testing
			-- Roblox's number storage rather than this module's passthrough.
			sound.Volume = 0.25

			local definition = WeaponSounds.Get(weaponId, "Swing")
			expect(definition).to.be.ok()
			expect((definition :: WeaponSounds.SoundDefinition).SoundId).to.equal("rbxassetid://777777")
			expect((definition :: WeaponSounds.SoundDefinition).Volume).to.equal(0.25)
		end)

		it("keeps each slot independent -- a swing sound is not a block sound", function()
			soundSlot(weaponId, "Swing").SoundId = "rbxassetid://777777"
			expect(WeaponSounds.Get(weaponId, "Block")).to.equal(nil)
		end)

		it("does not leak one weapon's sound onto another weapon", function()
			soundSlot(weaponId, "Parry").SoundId = "rbxassetid://777777"
			expect(WeaponSounds.Get(otherWeaponId, "Parry")).to.equal(nil)
		end)

		-- The three id forms this module exists to reconcile -- see its own header. A bare id and a
		-- legacy asset URL are both perfectly good strings that Roblox silently fails to resolve, and
		-- nothing else in the stack would object to either.
		it("normalizes a bare-digit id into a content URL", function()
			soundSlot(weaponId, "Swing").SoundId = "777777"
			local definition = WeaponSounds.Get(weaponId, "Swing")
			expect((definition :: WeaponSounds.SoundDefinition).SoundId).to.equal("rbxassetid://777777")
		end)

		it("normalizes a legacy asset URL into a content URL", function()
			soundSlot(weaponId, "Swing").SoundId = "http://www.roblox.com/asset/?id=777777"
			local definition = WeaponSounds.Get(weaponId, "Swing")
			expect((definition :: WeaponSounds.SoundDefinition).SoundId).to.equal("rbxassetid://777777")
		end)

		it("passes an already-correct content URL through untouched", function()
			soundSlot(weaponId, "Swing").SoundId = "rbxassetid://777777"
			local definition = WeaponSounds.Get(weaponId, "Swing")
			expect((definition :: WeaponSounds.SoundDefinition).SoundId).to.equal("rbxassetid://777777")
		end)

		it("accepts a slot folder named in a different case", function()
			local sound = soundSlot(weaponId, "Swing")
			sound.SoundId = "rbxassetid://777777"
			local slotFolder = sound.Parent :: Folder
			slotFolder.Name = "SWING"

			local definition = WeaponSounds.Get(weaponId, "Swing")
			expect(definition).to.be.ok()
			expect((definition :: WeaponSounds.SoundDefinition).SoundId).to.equal("rbxassetid://777777")

			slotFolder.Name = "Swing"
		end)

		it('accepts "Sheath" as a spelling of the Sheathe slot', function()
			local sound = soundSlot(weaponId, "Sheathe")
			sound.SoundId = "rbxassetid://777777"
			local slotFolder = sound.Parent :: Folder
			slotFolder.Name = "Sheath"

			local definition = WeaponSounds.Get(weaponId, "Sheathe")
			expect(definition).to.be.ok()

			slotFolder.Name = "Sheathe"
		end)

		it("returns nil for a weapon model with no SFX folder at all", function()
			local weapons = Workspace:FindFirstChild("Weapons") :: Folder
			local bare = Instance.new("Model")
			bare.Name = "BareModelWithNoSfx"
			bare.Parent = weapons

			expect(WeaponSounds.Get("BareModelWithNoSfx", "Swing")).to.equal(nil)

			bare:Destroy()
		end)
	end)

	describe("WeaponSounds.GetPreloadIds", function()
		it("is empty when no weapon has authored a sound", function()
			expect(#WeaponSounds.GetPreloadIds()).to.equal(0)
		end)

		it("collects every authored id across weapons and slots, normalized and deduplicated", function()
			soundSlot(weaponId, "Swing").SoundId = "777777"
			soundSlot(weaponId, "Block").SoundId = "rbxassetid://888888"
			-- The same asset on a second weapon: one entry, not two -- the preloader's own dedupe pass
			-- would also catch this, but a source handing back duplicates inflates its progress total.
			soundSlot(otherWeaponId, "Swing").SoundId = "rbxassetid://777777"

			local ids = WeaponSounds.GetPreloadIds()
			table.sort(ids)
			expect(#ids).to.equal(2)
			expect(ids[1]).to.equal("rbxassetid://777777")
			expect(ids[2]).to.equal("rbxassetid://888888")
		end)
	end)

	describe("WeaponSounds.GetPreloadLabels", function()
		it("labels an id by the weapon and slot it came from", function()
			soundSlot(weaponId, "Parry").SoundId = "rbxassetid://999999"
			local labels = WeaponSounds.GetPreloadLabels()
			expect(labels["rbxassetid://999999"]).to.equal(`{weaponId}:Parry`)
		end)

		it("is empty when nothing is authored", function()
			expect(next(WeaponSounds.GetPreloadLabels())).to.equal(nil)
		end)
	end)
end
