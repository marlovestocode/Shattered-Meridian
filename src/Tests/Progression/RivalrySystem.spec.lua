--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local RivalrySystem = require(ServerScriptService.Server.Systems.RivalrySystem)

return function()
	describe("RivalrySystem", function()
		it("starts every rivalry at zero standing and exposes a top-player ranking surface", function()
			RivalrySystem.Init()

			local playerA = {} :: any
			local playerB = {} :: any

			expect(RivalrySystem.GetRivalryStanding(playerA, playerB)).to.equal(0)
			expect(RivalrySystem.GetTopPlayers(2)).to.be.ok()
		end)

		it("returns the full tracked ranking when limit is omitted and an empty ranking for zero limit", function()
			RivalrySystem.Init()

			local playerA = {} :: any
			local playerB = {} :: any

			RivalrySystem.GetRivalryStanding(playerA, playerB)

			local allPlayers = RivalrySystem.GetTopPlayers()
			local zeroLimitPlayers = RivalrySystem.GetTopPlayers(0)

			expect(#allPlayers).to.equal(2)
			expect(#zeroLimitPlayers).to.equal(0)
		end)

		it("adds standing for a winner and removes standing for the loser in a PvP kill", function()
			RivalrySystem.Init()

			local winner = {} :: any
			local loser = {} :: any

			RivalrySystem.RegisterPvPKill(winner, loser)

			expect(RivalrySystem.GetRivalryStanding(winner, loser)).to.equal(1)
			expect(RivalrySystem.GetRivalryStanding(loser, winner)).to.equal(-1)
		end)

		it("drops a departing player's own standing AND every other player's standing against them", function()
			RivalrySystem.Init()

			local departing = {} :: any
			local opponentA = {} :: any
			local opponentB = {} :: any

			RivalrySystem.RegisterPvPKill(departing, opponentA)
			RivalrySystem.RegisterPvPKill(opponentB, departing)

			-- Sanity: both directions are populated before the cleanup runs.
			expect(RivalrySystem.GetRivalryStanding(departing, opponentA)).to.equal(1)
			expect(RivalrySystem.GetRivalryStanding(opponentB, departing)).to.equal(1)

			RivalrySystem.ClearPlayerReferences(departing)

			-- Check the leaderboard surface BEFORE any further GetRivalryStanding calls below --
			-- GetRivalryStanding auto-tracks whichever players it's queried with (ensureScoreEntry,
			-- existing behavior, not something this cleanup should fight), so querying standing
			-- against `departing` again would legitimately re-add them. That's correct system
			-- behavior, not something to work around after the fact -- so this test must observe the
			-- "fully cleared" state before it does anything that would re-track them.
			local topPlayers = RivalrySystem.GetTopPlayers()
			local sawDeparting = false
			local sawOpponentA = false
			local sawOpponentB = false
			for _, player in ipairs(topPlayers) do
				if player == departing then
					sawDeparting = true
				elseif player == opponentA then
					sawOpponentA = true
				elseif player == opponentB then
					sawOpponentB = true
				end
			end
			expect(sawDeparting).to.equal(false)
			expect(sawOpponentA).to.equal(true)
			expect(sawOpponentB).to.equal(true)

			-- The departing player's own outgoing standing and the reverse relationship (departing as
			-- someone ELSE's tracked opponent) both read back as a fresh zero, not the old value --
			-- confirming the underlying standing data was actually dropped, not just hidden from the
			-- leaderboard. Checked last since both calls re-track `departing` as a side effect.
			expect(RivalrySystem.GetRivalryStanding(departing, opponentA)).to.equal(0)
			expect(RivalrySystem.GetRivalryStanding(opponentB, departing)).to.equal(0)
		end)
	end)
end
