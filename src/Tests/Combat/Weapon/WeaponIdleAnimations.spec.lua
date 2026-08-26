--!strict
-- Covers Shared/Combat/WeaponIdleAnimations.lua -- the per-weapon Animations/IDLE Animation-instance
-- lookup that backs Client/FX/CombatAnimator.lua's armed-idle loop.
--
-- Exercised against a REAL Workspace.Weapons folder (WeaponFixture), the same choice
-- AttackAnimations.spec.lua makes and for the same reason: the whole claim this module makes is that
-- it reads a real Animation instance off the actual model in that folder.
--
-- INSTALLED ONCE, AT FILE SCOPE, NEVER REMOVED -- see AttackAnimations.spec.lua's own header for why:
-- WeaponFixture is shared VM-wide state, and every other consumer in this suite (AttackCatalog.spec,
-- WeaponInventorySystem.spec, ...) assumes it stays installed once set up. Per-test isolation for the
-- clip this file sets is handled by afterEach clearing AnimationId back to "".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WeaponIdleAnimations = require(ReplicatedStorage.Shared.Combat.WeaponIdleAnimations)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local ROSTER = WeaponFixture.Install()
local weaponId = ROSTER[1]
local otherWeaponId = ROSTER[2]

local function idleAnimation(id: string): Animation
	return WeaponFixture.AnimationSlot(id, "IDLE") :: Animation
end

return function()
	afterEach(function()
		idleAnimation(weaponId).AnimationId = ""
		idleAnimation(otherWeaponId).AnimationId = ""
	end)

	describe("WeaponIdleAnimations.Get", function()
		it('returns "" for a weapon with no clip authored in its Animations/IDLE folder', function()
			expect(WeaponIdleAnimations.Get(weaponId)).to.equal("")
		end)

		it('returns "" for a weapon that is not in the roster', function()
			expect(WeaponIdleAnimations.Get("NoSuchWeapon")).to.equal("")
		end)

		it('returns "" for nil/blank input rather than erroring', function()
			expect(WeaponIdleAnimations.Get(nil)).to.equal("")
			expect(WeaponIdleAnimations.Get("")).to.equal("")
		end)

		it("resolves a weapon's own Animations/IDLE clip", function()
			idleAnimation(weaponId).AnimationId = "rbxassetid://888888"
			expect(WeaponIdleAnimations.Get(weaponId)).to.equal("rbxassetid://888888")
		end)

		it("does not leak one weapon's idle clip onto another weapon", function()
			idleAnimation(weaponId).AnimationId = "rbxassetid://888888"
			expect(WeaponIdleAnimations.Get(otherWeaponId)).to.equal("")
		end)

		it("normalizes a bare-digit id the same way AttackAnimations does", function()
			idleAnimation(weaponId).AnimationId = "888888"
			expect(WeaponIdleAnimations.Get(weaponId)).to.equal("rbxassetid://888888")
		end)

		it("leaves a full rbxassetid:// id untouched", function()
			idleAnimation(weaponId).AnimationId = "rbxassetid://888888"
			expect(WeaponIdleAnimations.Get(weaponId)).to.equal("rbxassetid://888888")
		end)
	end)

	describe("WeaponIdleAnimations.GetPreloadIds/GetPreloadLabels", function()
		it("returns an empty list when no weapon has authored an idle clip", function()
			expect(#WeaponIdleAnimations.GetPreloadIds()).to.equal(0)
		end)

		it("includes every authored weapon's idle clip", function()
			idleAnimation(weaponId).AnimationId = "rbxassetid://888888"
			idleAnimation(otherWeaponId).AnimationId = "rbxassetid://999999"
			local ids = {}
			for _, id in WeaponIdleAnimations.GetPreloadIds() do
				ids[id] = true
			end
			expect(ids["rbxassetid://888888"]).to.equal(true)
			expect(ids["rbxassetid://999999"]).to.equal(true)
		end)

		it("deduplicates two weapons sharing one idle clip", function()
			idleAnimation(weaponId).AnimationId = "rbxassetid://888888"
			idleAnimation(otherWeaponId).AnimationId = "rbxassetid://888888"
			local seen: { [string]: boolean } = {}
			for _, id in WeaponIdleAnimations.GetPreloadIds() do
				expect(seen[id]).to.equal(nil)
				seen[id] = true
			end
		end)

		it("labels an idle clip by WeaponId:Idle", function()
			idleAnimation(weaponId).AnimationId = "rbxassetid://888888"
			local labels = WeaponIdleAnimations.GetPreloadLabels()
			expect(labels["rbxassetid://888888"]).to.equal(`{weaponId}:Idle`)
		end)
	end)
end
