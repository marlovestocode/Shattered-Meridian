--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerStateSystem = require(ServerScriptService.Server.Systems.PlayerStateSystem)
local Rig = require(script.Parent.Parent.TestHelpers.Rig)

-- The registry is module state shared with every System that registered at boot in this VM; each case snapshots the live
-- registrations by name and only asserts on its own.
return function()
	describe("PlayerStateSystem", function()
		it("runs every registered snapshot for the asking player, in registration order", function()
			local heard: { string } = {}
			local asker = Rig.FakePlayer("Asker")
			PlayerStateSystem.Register("SpecSliceA", function(player)
				if player == asker then
					table.insert(heard, "A")
				end
			end)
			PlayerStateSystem.Register("SpecSliceB", function(player)
				if player == asker then
					table.insert(heard, "B")
				end
			end)
			PlayerStateSystem.Replay(asker)
			expect(table.concat(heard, "")).to.equal("AB")
		end)

		it("replaces a slice registered again rather than answering it twice", function()
			local calls = 0
			local asker = Rig.FakePlayer("Twice")
			PlayerStateSystem.Register("SpecSliceTwice", function(player)
				if player == asker then
					calls += 1
				end
			end)
			PlayerStateSystem.Register("SpecSliceTwice", function(player)
				if player == asker then
					calls += 10
				end
			end)
			PlayerStateSystem.Replay(asker)
			expect(calls).to.equal(10)
			local count = 0
			for _, name in PlayerStateSystem.SliceNames() do
				if name == "SpecSliceTwice" then
					count += 1
				end
			end
			expect(count).to.equal(1)
		end)

		it("keeps answering when one slice's snapshot throws", function()
			local reached = false
			local asker = Rig.FakePlayer("Throws")
			PlayerStateSystem.Register("SpecSliceThrows", function(player)
				if player == asker then
					error("spec failure")
				end
			end)
			PlayerStateSystem.Register("SpecSliceAfter", function(player)
				if player == asker then
					reached = true
				end
			end)
			PlayerStateSystem.Replay(asker)
			expect(reached).to.equal(true)
		end)
	end)
end
