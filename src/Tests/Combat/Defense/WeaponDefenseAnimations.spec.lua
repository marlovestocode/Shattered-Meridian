--!strict
--[[
	WeaponDefenseAnimations.spec.lua

	Covers Shared/Defense/WeaponDefenseAnimations.lua -- the PARRY/BLOCK slot resolver.

	THE CASES THAT EARN THEIR KEEP HERE ARE THE FALLBACK ONES. This module differs from its two
	siblings (AttackAnimations, WeaponIdleAnimations) in exactly one respect -- it falls back to a
	shared baseline where WeaponIdleAnimations returns "" -- and that difference is the whole reason
	a weapon with no PARRY folder still parries. A regression that "fixed" this into returning ""
	would break defense for every unauthored weapon and pass every other spec in the suite.

	GetParryIds is tested hardest of the four exports because it is the one whose failure is SILENT:
	it feeds DefenseSystem.Init's ParryWindows.ValidateAll warm pass, and an id missing from it is a
	weapon whose parry never arms, with no error anywhere. See that function's own header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local PARRY = WeaponDefenseAnimations.Slots.Parry
local BLOCK = WeaponDefenseAnimations.Slots.Block

-- Installed at COLLECTION time, not per-test -- see WeaponFixture's own contract: it is shared VM-wide
-- state, and an Install/Remove cycle per case tears the roster out from under other spec files'
-- collection-time fixtures. Each case sets the AnimationIds it needs and afterEach clears them back.
local ROSTER = WeaponFixture.Install()
local armed = ROSTER[1]
local other = ROSTER[2]

local function setSlot(weaponId: string, slot: string, assetId: string): ()
	local animation = WeaponFixture.AnimationSlot(weaponId, slot)
	if animation then
		animation.AnimationId = assetId
	end
end

return function()
	afterEach(function()
		for _, id in ROSTER do
			setSlot(id, PARRY, "")
			setSlot(id, BLOCK, "")
		end
	end)

	describe("GetParry / GetBlock", function()
		it("falls back to the shared baseline for a weapon that authors neither slot", function()
			expect(WeaponDefenseAnimations.GetParry(armed)).to.equal(DefenseConstants.ParryAnimationId)
			expect(WeaponDefenseAnimations.GetBlock(armed)).to.equal(DefenseConstants.BlockHoldAnimationId)
		end)

		it("falls back to the baseline for a nil weapon -- an unarmed player still blocks", function()
			expect(WeaponDefenseAnimations.GetParry(nil)).to.equal(DefenseConstants.ParryAnimationId)
			expect(WeaponDefenseAnimations.GetBlock(nil)).to.equal(DefenseConstants.BlockHoldAnimationId)
		end)

		it("falls back to the baseline for a weapon that is not in Workspace.Weapons at all", function()
			expect(WeaponDefenseAnimations.GetParry("NoSuchWeapon")).to.equal(DefenseConstants.ParryAnimationId)
		end)

		it("prefers the weapon's own clip over the baseline", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			setSlot(armed, BLOCK, "rbxassetid://222")
			expect(WeaponDefenseAnimations.GetParry(armed)).to.equal("rbxassetid://111")
			expect(WeaponDefenseAnimations.GetBlock(armed)).to.equal("rbxassetid://222")
		end)

		it("resolves the two slots independently -- overriding PARRY alone leaves BLOCK on the baseline", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			expect(WeaponDefenseAnimations.GetParry(armed)).to.equal("rbxassetid://111")
			expect(WeaponDefenseAnimations.GetBlock(armed)).to.equal(DefenseConstants.BlockHoldAnimationId)
		end)

		it("does not leak one weapon's clip onto another", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			expect(WeaponDefenseAnimations.GetParry(other)).to.equal(DefenseConstants.ParryAnimationId)
		end)

		-- The bare-number case is the one an author actually hits: Roblox's asset page, the Toolbox and
		-- the Creator Dashboard all show an id without the prefix, so that is what gets pasted.
		it("normalizes a bare digits-only id into a content id", function()
			setSlot(armed, PARRY, "111")
			expect(WeaponDefenseAnimations.GetParry(armed)).to.equal("rbxassetid://111")
		end)

		it("treats a blank AnimationId as unauthored rather than as a clip", function()
			setSlot(armed, PARRY, "")
			expect(WeaponDefenseAnimations.GetParry(armed)).to.equal(DefenseConstants.ParryAnimationId)
		end)
	end)

	describe("GetParryIds", function()
		it("includes the shared baseline even when no weapon overrides it", function()
			expect(table.find(WeaponDefenseAnimations.GetParryIds(), DefenseConstants.ParryAnimationId)).to.be.ok()
		end)

		it("includes every weapon's own parry clip", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			setSlot(other, PARRY, "rbxassetid://333")
			local parryIds = WeaponDefenseAnimations.GetParryIds()
			expect(table.find(parryIds, "rbxassetid://111")).to.be.ok()
			expect(table.find(parryIds, "rbxassetid://333")).to.be.ok()
		end)

		-- The whole point of the list: it is fed to ParryWindows.ValidateAll, whose extraction is a
		-- rate-limited web call. A duplicate is a wasted request against a budget the ids that DO gate a
		-- mechanic need.
		it("deduplicates a clip two weapons share", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			setSlot(other, PARRY, "rbxassetid://111")
			local seen = 0
			for _, id in WeaponDefenseAnimations.GetParryIds() do
				if id == "rbxassetid://111" then
					seen += 1
				end
			end
			expect(seen).to.equal(1)
		end)

		-- Nothing reads a marker off a block loop, so an id in here would spend the extraction budget
		-- on a clip whose timing means nothing.
		it("never includes a BLOCK clip", function()
			setSlot(armed, BLOCK, "rbxassetid://222")
			expect(table.find(WeaponDefenseAnimations.GetParryIds(), "rbxassetid://222")).to.never.be.ok()
		end)
	end)

	describe("GetPreloadIds / GetPreloadLabels", function()
		it("returns both slots' clips -- the client plays both", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			setSlot(armed, BLOCK, "rbxassetid://222")
			local preloadIds = WeaponDefenseAnimations.GetPreloadIds()
			expect(table.find(preloadIds, "rbxassetid://111")).to.be.ok()
			expect(table.find(preloadIds, "rbxassetid://222")).to.be.ok()
		end)

		-- The baseline pair reaches the preloader through DefenseClient.GetPreloadInstances instead --
		-- returning it here too would double-count it in the loading screen's own progress total.
		it("omits the shared baseline, which DefenseClient contributes separately", function()
			expect(table.find(WeaponDefenseAnimations.GetPreloadIds(), DefenseConstants.ParryAnimationId)).to.never.be.ok()
		end)

		it("contributes nothing at all when no weapon authors either slot", function()
			expect(#WeaponDefenseAnimations.GetPreloadIds()).to.equal(0)
		end)

		it("labels each id by weapon and slot, so a preload failure names something", function()
			setSlot(armed, PARRY, "rbxassetid://111")
			setSlot(armed, BLOCK, "rbxassetid://222")
			local labels = WeaponDefenseAnimations.GetPreloadLabels()
			expect(labels["rbxassetid://111"]).to.equal(`{armed}:Parry`)
			expect(labels["rbxassetid://222"]).to.equal(`{armed}:Block`)
		end)
	end)
end
