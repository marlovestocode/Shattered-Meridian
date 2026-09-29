--!strict
-- Covers Shared/Attack/AttackAnimations.lua -- the shared-baseline swing clip table plus the
-- per-weapon override clips layered on top of it.
--
-- Exercised against a REAL Workspace.Weapons folder (WeaponFixture), not a stub, because the whole
-- claim this module makes is that it reads a real Animation instance off each weapon's own Animations
-- folder in that container -- a stubbed container would verify nothing about the real lookup path.
--
-- INSTALLED ONCE, AT FILE SCOPE, NEVER REMOVED -- the same convention every other WeaponFixture
-- consumer in this suite already keeps (AttackCatalog.spec, WeaponInventorySystem.spec,
-- SwingSequencer.spec, ...). WeaponFixture's own state is shared VM-wide, not per-file, so a
-- per-test Install()/Remove() cycle here would tear the fixture down out from under any OTHER spec
-- file whose own tests run afterward and assume it stays installed for the rest of the run -- that
-- exact interaction broke WeaponInventorySystem.spec.lua the first time this file tried it. Per-test
-- isolation for the clips THIS file sets is handled by afterEach clearing them back to "", which is a
-- much narrower (and non-destructive) reset than reinstalling the whole roster.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackAnimations = require(ReplicatedStorage.Shared.Attack.AttackAnimations)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local ROSTER = WeaponFixture.Install()
local weaponId = ROSTER[1]
local otherWeaponId = ROSTER[2]

local OVERRIDE_SLOTS = { "M1", "M2", "M3", "HEAVY", "FINISHER" }

local function stageAnimation(id: string, slot: string): Animation
	return WeaponFixture.AnimationSlot(id, slot) :: Animation
end

return function()
	afterEach(function()
		for _, id in { weaponId, otherWeaponId } do
			for _, slot in OVERRIDE_SLOTS do
				stageAnimation(id, slot).AnimationId = ""
			end
		end
	end)

	describe("AttackAnimations.Get -- shared baseline (unauthored weapon)", function()
		it("resolves a weapon-stage MoveId to the shared baseline clip", function()
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://104588315151150")
			expect(AttackAnimations.Get(`default:{weaponId}:Heavy:1`)).to.equal("rbxassetid://83363364108102")
			expect(AttackAnimations.Get(`default:{weaponId}:Finisher`)).to.equal("rbxassetid://138196103225171")
		end)

		it("resolves the same baseline for any weapon that hasn't overridden it", function()
			-- Two unauthored weapons must animate identically -- this is the whole point of the shared
			-- table's existence (see this file's header).
			expect(AttackAnimations.Get(`default:{otherWeaponId}:Basic:1`)).to.equal(
				AttackAnimations.Get(`default:{weaponId}:Basic:1`)
			)
		end)

		it("still resolves a standalone (non-weapon) MoveId", function()
			expect(AttackAnimations.Get("default:DashPunch")).to.equal("")
		end)

		-- The air combo's moves borrow a ground clip until their own is authored, and SAY they borrowed it:
		-- AttackCatalog retimes a borrowed clip to the air move's own windup instead of trusting its marker.
		it("lends an unauthored air move the ground clip it stands in on, and names the lender", function()
			local id, lender = AttackAnimations.Resolve("default:NoSuchWeapon:Air:1")
			expect(id).to.equal(AttackAnimations.Get("default:NoSuchWeapon:Basic:1"))
			expect(lender).to.equal("default:NoSuchWeapon:Basic:1")
			local _, groundLender = AttackAnimations.Resolve("default:NoSuchWeapon:Basic:1")
			expect(groundLender).to.equal(nil)
		end)

		it('returns "" for an unknown or malformed id, never nil or an error', function()
			expect(AttackAnimations.Get("no-such-move")).to.equal("")
			expect(AttackAnimations.Get("")).to.equal("")
			expect(AttackAnimations.Get(nil :: any)).to.equal("")
		end)
	end)

	describe("AttackAnimations.Get -- per-weapon override", function()
		it("prefers a weapon's own Animations/M1, M2, M3 clip over the shared baseline", function()
			stageAnimation(weaponId, "M1").AnimationId = "rbxassetid://111111"
			stageAnimation(weaponId, "M2").AnimationId = "rbxassetid://222222"
			stageAnimation(weaponId, "M3").AnimationId = "rbxassetid://333333"

			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://111111")
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:2`)).to.equal("rbxassetid://222222")
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:3`)).to.equal("rbxassetid://333333")
		end)

		it("prefers Animations/HEAVY and Animations/FINISHER the same way", function()
			stageAnimation(weaponId, "HEAVY").AnimationId = "rbxassetid://444444"
			stageAnimation(weaponId, "FINISHER").AnimationId = "rbxassetid://555555"

			expect(AttackAnimations.Get(`default:{weaponId}:Heavy:1`)).to.equal("rbxassetid://444444")
			expect(AttackAnimations.Get(`default:{weaponId}:Finisher`)).to.equal("rbxassetid://555555")
		end)

		it("overriding one stage leaves every other stage on the shared baseline", function()
			stageAnimation(weaponId, "M1").AnimationId = "rbxassetid://111111"

			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://111111")
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:2`)).to.equal("rbxassetid://78226937952673")
			expect(AttackAnimations.Get(`default:{weaponId}:Heavy:1`)).to.equal("rbxassetid://83363364108102")
		end)

		it("does not leak one weapon's override onto another weapon's stages", function()
			stageAnimation(weaponId, "M1").AnimationId = "rbxassetid://111111"

			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://111111")
			expect(AttackAnimations.Get(`default:{otherWeaponId}:Basic:1`)).to.equal("rbxassetid://104588315151150")
		end)

		it("ignores a blank override clip, falling back to the shared baseline", function()
			stageAnimation(weaponId, "M1").AnimationId = ""
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://104588315151150")
		end)

		it("normalizes a bare-digit override the same way the shared baseline is normalized", function()
			stageAnimation(weaponId, "M1").AnimationId = "999999"
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://999999")
		end)

		it("leaves a full rbxassetid:// override untouched", function()
			stageAnimation(weaponId, "M1").AnimationId = "rbxassetid://999999"
			expect(AttackAnimations.Get(`default:{weaponId}:Basic:1`)).to.equal("rbxassetid://999999")
		end)

		it("resolves nothing for a weapon that isn't in the roster", function()
			expect(AttackAnimations.Get("default:NoSuchWeapon:Basic:1")).to.equal("rbxassetid://104588315151150")
		end)
	end)

	describe("AttackAnimations.GetPreloadIds/GetPreloadLabels", function()
		it("includes a weapon's override alongside the shared baseline ids", function()
			stageAnimation(weaponId, "M1").AnimationId = "rbxassetid://111111"
			local ids = {}
			for _, id in AttackAnimations.GetPreloadIds() do
				ids[id] = true
			end
			expect(ids["rbxassetid://111111"]).to.equal(true)
			-- The shared baseline's own ids are still present -- this is additive, not a replacement.
			expect(ids["rbxassetid://104588315151150"]).to.equal(true)
		end)

		it("deduplicates a weapon override that happens to match the shared baseline", function()
			stageAnimation(weaponId, "M1").AnimationId = "rbxassetid://104588315151150"
			local seen: { [string]: boolean } = {}
			for _, id in AttackAnimations.GetPreloadIds() do
				expect(seen[id]).to.equal(nil)
				seen[id] = true
			end
		end)

		it("labels a weapon override by WeaponId:Stage, not the raw id", function()
			stageAnimation(weaponId, "FINISHER").AnimationId = "rbxassetid://777777"
			local labels = AttackAnimations.GetPreloadLabels()
			expect(labels["rbxassetid://777777"]).to.equal(`{weaponId}:Finisher`)
		end)

		it("never includes a blank or bare-prefix id", function()
			stageAnimation(weaponId, "M1").AnimationId = ""
			for _, id in AttackAnimations.GetPreloadIds() do
				expect(id).never.to.equal("")
				expect(id).never.to.equal("rbxassetid://")
			end
		end)
	end)
end
