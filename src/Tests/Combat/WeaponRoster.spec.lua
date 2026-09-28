--!strict
-- Covers the synthesized bare-hands weapon (Shared/Combat/WeaponRoster.lua's Fists entry) all the way
-- to the number a landed punch is priced at: CombatConstants.Weapons.Fists -> WeaponRoster's derived
-- multiplier -> DefaultMoveRegistry -> AttackCatalog's damage profile, which is exactly what
-- DamageSystem reads on a hit. Asserted there, not at the multiplier, because the bug this exists for
-- (a "2" that meant 13 damage) was invisible at every step except the last.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

-- Installing the fixture builds the roster, which always appends the fists.
WeaponFixture.Install()

local FISTS = WeaponRoster.FISTS_ID
local PUNCH = CombatConstants.Weapons.Fists.BasicHitDamage

return function()
	afterEach(function()
		AttackCatalog.Reset()
		MoveRegistryManager.Init()
	end)

	it("is always in the roster, last in the swap order", function()
		expect(WeaponRoster.Has(FISTS)).to.equal(true)
		local order = WeaponRoster.Order()
		expect(order[#order]).to.equal(FISTS)
	end)

	it("prices every Basic punch at exactly the authored hit", function()
		local stage = 1
		while true do
			local entry = AttackCatalog.Get(`default:{FISTS}:Basic:{stage}`)
			if entry == nil then
				break
			end
			expect((entry :: any).Profile.Damage).to.be.near(PUNCH, 1e-6)
			stage += 1
		end
		-- The loop above must have checked something, or it proved nothing.
		expect(stage > 1).to.equal(true)
	end)

	it("keeps its Heavy in proportion to a sword's, rather than at a sword's full weight", function()
		local fistHeavy = AttackCatalog.Get(`default:{FISTS}:Heavy:1`) :: any
		expect(fistHeavy).to.be.ok()
		local baseline = CombatConstants.Weapons.Baseline.Stages
		local expected = baseline.Heavy[1].Damage * PUNCH / baseline.Basic[1].Damage
		expect(fistHeavy.Profile.Damage).to.be.near(expected, 1e-6)
		expect(fistHeavy.Profile.Damage < baseline.Heavy[1].Damage).to.equal(true)
	end)
end
