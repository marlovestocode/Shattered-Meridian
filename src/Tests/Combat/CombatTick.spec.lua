--!strict
-- Covers Server/Combat/CombatTick.lua -- the one combat Heartbeat. Driven through Step with a synthetic clock;
-- no case relies on a real frame (each Reset drops the connection the first Register makes).

local ServerScriptService = game:GetService("ServerScriptService")

local CombatTick = require(ServerScriptService.Server.Combat.CombatTick)

return function()
	afterEach(function()
		CombatTick.Reset()
	end)

	describe("CombatTick", function()
		it("runs phases in PHASES order, whatever order they registered in", function()
			local ran: { string } = {}
			for index = #CombatTick.PHASES, 1, -1 do
				local name = CombatTick.PHASES[index]
				CombatTick.Register(name, function()
					table.insert(ran, name)
				end)
			end
			CombatTick.Step(1 / 60, 10)
			for index, name in CombatTick.PHASES do
				expect(ran[index]).to.equal(name)
			end
		end)

		it("hands every phase the same clock", function()
			local seen: { number } = {}
			CombatTick.Register("HitboxEngine", function(_dt, now)
				table.insert(seen, now)
			end)
			CombatTick.Register("DamageSystem", function(_dt, now)
				table.insert(seen, now)
			end)
			CombatTick.Step(1 / 60, 42)
			expect(seen[1]).to.equal(42)
			expect(seen[2]).to.equal(42)
		end)

		it("keeps running later phases when one errors", function()
			local reached = false
			CombatTick.Register("HitboxEngine", function()
				error("boom")
			end)
			CombatTick.Register("DefenseSystem", function()
				reached = true
			end)
			CombatTick.Step(1 / 60, 1)
			expect(reached).to.equal(true)
		end)

		it("refuses an unknown phase and a second owner of one", function()
			expect(function()
				CombatTick.Register("NotAPhase", function() end)
			end).to.throw()
			CombatTick.Register("GrabSystem", function() end)
			expect(function()
				CombatTick.Register("GrabSystem", function() end)
			end).to.throw()
		end)

		it("stops running a phase once unregistered", function()
			local count = 0
			local unregister = CombatTick.Register("EngagementSystem", function()
				count += 1
			end)
			CombatTick.Step(1 / 60, 1)
			unregister()
			CombatTick.Step(1 / 60, 2)
			expect(count).to.equal(1)
			expect(CombatTick.IsRegistered("EngagementSystem")).to.equal(false)
		end)
	end)
end
