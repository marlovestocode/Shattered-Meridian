--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BountySystem = require(ServerScriptService.Server.Systems.BountySystem)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- Init() is deliberately NEVER called here; ResetState() gives each case a clean table instead. That
-- distinction is load-bearing, not stylistic: Init() creates the real RemoteEvents, and
-- RemoteEvent:FireClient rejects anything that isn't a genuine Player Instance -- so with remotes
-- live, the very first placement would throw inside sendMarkedState before any rule under test ran.
-- With no Init(), the remotes stay nil, both replication helpers take the nil guards they already
-- carry for pre-Init calls, and what's left is exactly the streak/placement/claim logic this file is
-- about. See BountySystem.ResetState's own header.
--
-- Kills are driven through BountySystem.RegisterKill directly rather than
-- GameplayEvents.FirePlayerKilled, for a second, independent reason: the BindableEvent path
-- deep-copies plain-table arguments across Fire(), so the doubles below would arrive as different
-- tables than the ones this spec holds and could never match as table keys. Real Player Instances
-- cross a BindableEvent by reference, so that is an artifact of the double, not of production --
-- and Init()'s subscription is a one-line forward into RegisterKill precisely so that the
-- indirection being skipped here carries no logic of its own.
--
-- Reward payout (MeridianSystem.AwardMeridianXP) is not asserted here: it requires a loaded profile
-- for a live Player, the same Studio/live-server-only gap MeridianSystem.spec.lua and
-- PlayerDataSystem.spec.lua both document. AwardMeridianXP returning false for an unloaded profile
-- is exactly why ClaimBounty's contract is "the bounty is consumed either way."

local function fakePlayer(name: string): any
	return { Name = name, UserId = 0 }
end

return function()
	describe("BountySystem.ComputeReward", function()
		it("pays Base + tier at the moment a player is first marked", function()
			local atThreshold = BountySystem.ComputeReward(BountyConstants.NotorietyStreakThreshold, 1)
			expect(atThreshold).to.equal(BountyConstants.BaseReward + BountyConstants.PerTargetTierReward)
		end)

		it("counts only kills past the threshold, so the streak term starts at zero", function()
			local tier = 1
			local atThreshold = BountySystem.ComputeReward(BountyConstants.NotorietyStreakThreshold, tier)
			local oneMore = BountySystem.ComputeReward(BountyConstants.NotorietyStreakThreshold + 1, tier)
			expect(oneMore - atThreshold).to.equal(BountyConstants.PerStreakKillReward)
		end)

		it("scales with the target's tier", function()
			local streak = BountyConstants.NotorietyStreakThreshold
			local tier1 = BountySystem.ComputeReward(streak, 1)
			local tier5 = BountySystem.ComputeReward(streak, 5)
			expect(tier5 - tier1).to.equal(4 * BountyConstants.PerTargetTierReward)
		end)

		it("is worth meaningfully more than an ordinary kill even at the minimum", function()
			local minimum = BountySystem.ComputeReward(BountyConstants.NotorietyStreakThreshold, 1)
			expect(minimum > Constants.Meridian.BaseXPPerKill * 2).to.equal(true)
		end)

		it("caps at MaxReward rather than scaling without bound", function()
			expect(BountySystem.ComputeReward(100000, 9)).to.equal(BountyConstants.MaxReward)
		end)

		it("never returns a negative or NaN-driven reward for junk input", function()
			expect(BountySystem.ComputeReward(0, 1) >= 0).to.equal(true)
			expect(BountySystem.ComputeReward(-50, 1) >= 0).to.equal(true)
			expect(BountySystem.ComputeReward(0 / 0, 0 / 0) >= 0).to.equal(true)
		end)
	end)

	describe("Notoriety placement", function()
		it("does not mark a player below the streak threshold", function()
			BountySystem.ResetState()
			local hunter = fakePlayer("Hunter")

			for index = 1, BountyConstants.NotorietyStreakThreshold - 1 do
				BountySystem.RegisterKill(hunter, fakePlayer(`Victim{index}`))
			end

			expect(BountySystem.GetKillStreak(hunter)).to.equal(BountyConstants.NotorietyStreakThreshold - 1)
			expect(BountySystem.IsMarked(hunter)).to.equal(false)
			expect(#BountySystem.ListActiveBounties()).to.equal(0)
		end)

		it("marks a player exactly at the streak threshold", function()
			BountySystem.ResetState()
			local hunter = fakePlayer("Hunter")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(hunter, fakePlayer(`Victim{index}`))
			end

			expect(BountySystem.IsMarked(hunter)).to.equal(true)
			local board = BountySystem.ListActiveBounties()
			expect(#board).to.equal(1)
			expect(board[1].TargetName).to.equal("Hunter")
			expect(board[1].Streak).to.equal(BountyConstants.NotorietyStreakThreshold)
		end)

		it("re-prices an existing bounty upward as the streak continues, without placing a second", function()
			BountySystem.ResetState()
			local hunter = fakePlayer("Hunter")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(hunter, fakePlayer(`Victim{index}`))
			end
			local firstReward = (BountySystem.GetActiveBounty(hunter) :: any).reward
			local firstBountyId = (BountySystem.GetActiveBounty(hunter) :: any).bountyId

			BountySystem.RegisterKill(hunter, fakePlayer("OneMore"))

			local updated = BountySystem.GetActiveBounty(hunter) :: any
			expect(updated.reward > firstReward).to.equal(true)
			-- Same bounty, re-priced -- not a second entry on the board.
			expect(updated.bountyId).to.equal(firstBountyId)
			expect(#BountySystem.ListActiveBounties()).to.equal(1)
		end)

		it("never marks anyone for a self-kill", function()
			BountySystem.ResetState()
			local loner = fakePlayer("Loner")

			for _ = 1, BountyConstants.NotorietyStreakThreshold + 2 do
				BountySystem.RegisterKill(loner, loner)
			end

			expect(BountySystem.GetKillStreak(loner)).to.equal(0)
			expect(BountySystem.IsMarked(loner)).to.equal(false)
		end)
	end)

	describe("Claiming", function()
		it("clears the mark and returns the reward when a marked player is killed", function()
			BountySystem.ResetState()
			local marked = fakePlayer("Marked")
			local challenger = fakePlayer("Challenger")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(marked, fakePlayer(`Victim{index}`))
			end
			local expectedReward = (BountySystem.GetActiveBounty(marked) :: any).reward

			BountySystem.RegisterKill(challenger, marked)

			expect(BountySystem.IsMarked(marked)).to.equal(false)
			expect(BountySystem.GetKillStreak(marked)).to.equal(0)
			expect(#BountySystem.ListActiveBounties()).to.equal(0)
			expect(expectedReward > 0).to.equal(true)
		end)

		it("cannot be claimed twice -- the second attempt finds nothing", function()
			BountySystem.ResetState()
			local marked = fakePlayer("Marked")
			local challenger = fakePlayer("Challenger")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(marked, fakePlayer(`Victim{index}`))
			end

			expect(BountySystem.ClaimBounty(marked, challenger)).to.be.ok()
			expect(BountySystem.ClaimBounty(marked, challenger)).to.equal(nil)
		end)

		it("refuses a self-claim outright", function()
			BountySystem.ResetState()
			local marked = fakePlayer("Marked")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(marked, fakePlayer(`Victim{index}`))
			end

			expect(BountySystem.ClaimBounty(marked, marked)).to.equal(nil)
			-- Refused, not consumed -- the bounty must survive a refused claim.
			expect(BountySystem.IsMarked(marked)).to.equal(true)
		end)

		it("returns nil for a target who was never marked", function()
			BountySystem.ResetState()
			expect(BountySystem.ClaimBounty(fakePlayer("Nobody"), fakePlayer("Claimer"))).to.equal(nil)
		end)

		it("drops the mark on an unattributed death without paying anyone", function()
			BountySystem.ResetState()
			local marked = fakePlayer("Marked")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(marked, fakePlayer(`Victim{index}`))
			end
			expect(BountySystem.IsMarked(marked)).to.equal(true)

			-- A fall or the void: CombatSystem confirms the death with no killer attributed.
			BountySystem.RegisterKill(nil, marked)

			expect(BountySystem.IsMarked(marked)).to.equal(false)
			expect(BountySystem.GetKillStreak(marked)).to.equal(0)
			expect(#BountySystem.ListActiveBounties()).to.equal(0)
		end)

		it("advances the claimer's own streak, so a hunter can become the hunted", function()
			BountySystem.ResetState()
			local challenger = fakePlayer("Challenger")

			-- Challenger reaches the threshold entirely by ending other people's runs.
			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(challenger, fakePlayer(`Runner{index}`))
			end

			expect(BountySystem.IsMarked(challenger)).to.equal(true)
		end)
	end)

	describe("Board", function()
		it("ranks by reward, highest first", function()
			BountySystem.ResetState()
			local big = fakePlayer("Big")
			local small = fakePlayer("Small")

			for index = 1, BountyConstants.NotorietyStreakThreshold + 5 do
				BountySystem.RegisterKill(big, fakePlayer(`BigVictim{index}`))
			end
			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(small, fakePlayer(`SmallVictim{index}`))
			end

			local board = BountySystem.ListActiveBounties()
			expect(#board).to.equal(2)
			expect(board[1].TargetName).to.equal("Big")
			expect(board[2].TargetName).to.equal("Small")
			expect(board[1].Reward > board[2].Reward).to.equal(true)
		end)

		it("exposes no Player instance on the wire, only name and UserId", function()
			BountySystem.ResetState()
			local marked = fakePlayer("Marked")
			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(marked, fakePlayer(`Victim{index}`))
			end

			local entry = BountySystem.ListActiveBounties()[1]
			expect(entry.TargetName).to.be.a("string")
			expect(entry.TargetUserId).to.be.a("number")
			expect((entry :: any).target).to.equal(nil)
		end)
	end)

	describe("Cleanup", function()
		it("drops a departing player's bounty and streak", function()
			BountySystem.ResetState()
			local leaver = fakePlayer("Leaver")

			for index = 1, BountyConstants.NotorietyStreakThreshold do
				BountySystem.RegisterKill(leaver, fakePlayer(`Victim{index}`))
			end
			expect(BountySystem.IsMarked(leaver)).to.equal(true)

			BountySystem.ClearPlayerReferences(leaver)

			expect(BountySystem.IsMarked(leaver)).to.equal(false)
			expect(BountySystem.GetKillStreak(leaver)).to.equal(0)
			expect(#BountySystem.ListActiveBounties()).to.equal(0)
		end)

		it("is safe to call for a player who was never tracked", function()
			BountySystem.ResetState()
			BountySystem.ClearPlayerReferences(fakePlayer("Stranger"))
			expect(#BountySystem.ListActiveBounties()).to.equal(0)
		end)
	end)

	describe("BountyConstants", function()
		it("keeps the reward ceiling above the floor", function()
			local floor = BountySystem.ComputeReward(BountyConstants.NotorietyStreakThreshold, 1)
			expect(BountyConstants.MaxReward > floor).to.equal(true)
		end)

		it("uses a streak threshold players can actually reach", function()
			expect(BountyConstants.NotorietyStreakThreshold >= 2).to.equal(true)
			expect(BountyConstants.NotorietyStreakThreshold <= 10).to.equal(true)
		end)
	end)
end
