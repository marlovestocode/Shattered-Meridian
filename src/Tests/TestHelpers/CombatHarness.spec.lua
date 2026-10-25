--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local CombatTick = require(ServerScriptService.Server.Combat.CombatTick)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local CombatHarness = require(ServerScriptService.Tests.TestHelpers.CombatHarness)
local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)

return function()
	afterEach(function()
		CombatHarness.Teardown()
	end)

	describe("CombatHarness.Reset", function()
		it("has a reset for every CombatTick phase, so a new phase cannot be missed", function()
			-- Reset asserts per phase; running it over the real PHASES is the check.
			CombatHarness.Reset()
			expect(#CombatTick.PHASES > 0).to.equal(true)
		end)

		it("empties the engine and the defense layer", function()
			local spawn = CombatHarness.Spawner({ ParryAnimation = "rbxassetid://spec-harness-parry" })
			local dummy = spawn("HarnessA", Vector3.new(0, 5, 0))
			expect(HitboxEngine.GetCombatantId(dummy.Model)).to.equal(dummy.Id)
			expect(DefenseSystem.IsRegistered(dummy.Model)).to.equal(true)

			CombatHarness.Reset()
			expect(HitboxEngine.GetCombatantId(dummy.Model)).to.equal(nil)
			expect(DefenseSystem.IsRegistered(dummy.Model)).to.equal(false)
		end)
	end)

	describe("CombatHarness.Combatant", function()
		it("registers with the engine alone when Defense is off", function()
			local body = Rig.Dummy("HarnessEngineOnly", Vector3.new(0, 5, 0))
			local id = CombatHarness.Combatant(body, { Defense = false })
			expect(id).never.to.equal(nil)
			expect(DefenseSystem.IsRegistered(body.Model)).to.equal(false)
		end)

		it("registers with nothing when Engine is off", function()
			local body = Rig.Dummy("HarnessNone")
			expect(CombatHarness.Combatant(body, { Engine = false })).to.equal(nil)
			expect(HitboxEngine.GetCombatantId(body.Model)).to.equal(nil)
		end)
	end)

	describe("CombatHarness.Spawner", function()
		it("passes anchored through to the root", function()
			local spawn = CombatHarness.Spawner({ Defense = false })
			expect(spawn("HarnessFree", Vector3.new(0, 5, 0), nil, false).Root.Anchored).to.equal(false)
			expect(spawn("HarnessHeld", Vector3.new(0, 5, 0)).Root.Anchored).to.equal(true)
		end)
	end)
end
