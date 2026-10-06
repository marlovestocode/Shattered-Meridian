--!strict
-- Covers the two progression paths that moved onto the fight-to-grow spine on 2026-10-06 (the progression
-- spine audit's O-1 and O-3): a Bounty payout ("BountyClaim", BountySystem.PayClaim) and Bloodline stage
-- progress ("BloodlineStage", BloodlineSystem.CountKill). What matters about both is that they now obey
-- ProgressionSystem's gate -- above all the repeat-victim weight -- exactly as Meridian XP does.
--
-- Same harness as ProgressionSpine.spec.lua: stand-in Players with genuinely loaded profiles
-- (PlayerDataSystem.InstallProfileForSpec), the chain driven through RewardSystem.HandlePlayerKilled, no
-- Init() anywhere so every remote stays nil.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local ProgressionConstants = require(ReplicatedStorage.Shared.Progression.ProgressionConstants)
local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager) :: any
local BloodlineSystem = require(ServerScriptService.Server.Systems.BloodlineSystem) :: any
local BountySystem = require(ServerScriptService.Server.Systems.BountySystem) :: any
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem) :: any
local ProgressionSystem = require(ServerScriptService.Server.Systems.ProgressionSystem)
local RewardSystem = require(ServerScriptService.Server.Systems.RewardSystem)

local nextUserId = 9400

local function fakePlayer(name: string): any
	nextUserId += 1
	return { Name = name, UserId = nextUserId }
end

-- MeridianXPAwarded facts for one recipient (matched by Name: the signal deep-copies the stand-in).
local function awardsFor(recipientName: string, body: () -> ()): { { amount: number, reason: string? } }
	local seen: { { amount: number, reason: string? } } = {}
	local connection = GameplayEvents.OnMeridianXPAwarded(
		function(player: any, amount: number, _newTotal: number, reason: string?)
			if player.Name == recipientName then
				table.insert(seen, { amount = amount, reason = reason })
			end
		end
	)
	body()
	task.wait()
	connection:Disconnect()
	return seen
end

local function bountyAwards(awards: { { amount: number, reason: string? } }): { number }
	local amounts = {}
	for _, award in awards do
		if award.reason == "BountyClaim" then
			table.insert(amounts, award.amount)
		end
	end
	return amounts
end

return function()
	local killer: any
	local victim: any
	local nextDeathId: number

	local function freshId(): number
		nextDeathId += 1
		return nextDeathId
	end

	local function load(player: any, mutate: ((profile: any) -> ())?): ()
		local profile = PlayerDataSystem.CreateDefaultProfile(player.UserId)
		if mutate then
			mutate(profile)
		end
		PlayerDataSystem.InstallProfileForSpec(player, profile)
	end

	-- Puts a mark on `player` by giving them a streak at the threshold.
	local function mark(player: any): number
		for index = 1, BountyConstants.NotorietyStreakThreshold do
			BountySystem.RegisterKill(player, fakePlayer(`Runner{index}`))
		end
		local bounty = BountySystem.GetActiveBounty(player)
		assert(bounty ~= nil, "the streak did not place a mark")
		return bounty.reward
	end

	beforeEach(function()
		RewardSystem.Reset()
		ProgressionSystem.Reset()
		BountySystem.ResetState()
		killer = fakePlayer("Killer")
		victim = fakePlayer("Victim")
		nextDeathId = 0
	end)

	afterEach(function()
		PlayerDataSystem.EvictProfileForSpec(killer)
		PlayerDataSystem.EvictProfileForSpec(victim)
		RewardSystem.Reset()
		ProgressionSystem.Reset()
		BountySystem.ResetState()
	end)

	describe("a Bounty payout rides the spine", function()
		it("pays the mark when the bounty's own subscription hears the death first", function()
			load(killer)
			local reward = mark(victim)
			local id = freshId()

			local outcome
			local awards = awardsFor("Killer", function()
				BountySystem.RegisterKill(killer, victim, id)
				expect(BountySystem.IsMarked(victim)).to.equal(false)
				expect(BountySystem.GetOwedReward(id)).to.equal(reward)
				outcome = RewardSystem.HandlePlayerKilled(victim, killer, id)
			end)

			expect((outcome :: any).Granted.BountyClaim).to.equal(true)
			expect(BountySystem.GetOwedReward(id)).to.equal(nil)
			local paid = bountyAwards(awards)
			expect(#paid).to.equal(1)
			expect(paid[1]).to.equal(reward)
		end)

		it("pays the mark exactly once when the spine hears the death first", function()
			load(killer)
			local reward = mark(victim)
			local id = freshId()

			local awards = awardsFor("Killer", function()
				RewardSystem.HandlePlayerKilled(victim, killer, id)
				expect(BountySystem.IsMarked(victim)).to.equal(false)
				-- The bounty's own subscription arrives second and finds nothing left to resolve.
				BountySystem.RegisterKill(killer, victim, id)
			end)

			local paid = bountyAwards(awards)
			expect(#paid).to.equal(1)
			expect(paid[1]).to.equal(reward)
			expect(BountySystem.GetOwedReward(id)).to.equal(nil)
		end)

		it("pays nothing for a victim who carried no mark", function()
			load(killer)
			local outcome = RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			expect((outcome :: any).Accepted).to.equal(true)
			expect((outcome :: any).Granted.BountyClaim).to.equal(false)
		end)

		it("is scaled by the repeat-victim weight, like Meridian XP", function()
			load(killer)
			-- An earlier kill of the same victim, before they were marked, opens the pair's run.
			RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			local reward = mark(victim)
			local id = freshId()

			local awards = awardsFor("Killer", function()
				BountySystem.RegisterKill(killer, victim, id)
				RewardSystem.HandlePlayerKilled(victim, killer, id)
			end)

			local weight = ProgressionConstants.RepeatVictim.Weights[2]
			local paid = bountyAwards(awards)
			expect(#paid).to.equal(1)
			expect(paid[1]).to.equal(math.floor(reward * weight + 0.5))
		end)

		it("pays nothing for a kill the gate weighted to zero, and the mark is still gone", function()
			load(killer)
			for _ = 1, #ProgressionConstants.RepeatVictim.Weights do
				RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			end
			mark(victim)
			local id = freshId()

			local outcome
			local awards = awardsFor("Killer", function()
				BountySystem.RegisterKill(killer, victim, id)
				outcome = RewardSystem.HandlePlayerKilled(victim, killer, id)
			end)

			expect((outcome :: any).Refusal).to.equal("RepeatVictim")
			expect(#bountyAwards(awards)).to.equal(0)
			expect(BountySystem.IsMarked(victim)).to.equal(false)
		end)

		it("forgets a claim owed to a player who leaves", function()
			mark(victim)
			local id = freshId()
			BountySystem.RegisterKill(killer, victim, id)
			expect(BountySystem.GetOwedReward(id)).to.be.ok()
			BountySystem.ClearPlayerReferences(killer)
			expect(BountySystem.GetOwedReward(id)).to.equal(nil)
		end)
	end)

	describe("Bloodline stage progress rides the spine", function()
		local BLOODLINE = "spine-route-line"

		local function registerTwoStageBloodline(): ()
			BloodlineManager.Init()
			local stage = function(index: number): any
				return {
					StageIndex = index,
					DisplayName = `Stage {index}`,
					PassiveEffects = {
						{ Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Fortitude", Delta = 1 },
					},
				}
			end
			local validated, reason = BloodlineManager.Validate({
				BloodlineId = BLOODLINE,
				DisplayName = "Spine Route Line",
				RarityTier = "Common",
				FlavorText = "",
				AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = 2 } },
				Stages = { stage(1), stage(2) },
			})
			assert(validated, `Validate rejected: {tostring(reason)}`)
			BloodlineManager.Upsert(validated)
		end

		local function carrying(profile: any): ()
			profile.bloodlineIds = { BLOODLINE }
			profile.bloodlineStageProgress = { [BLOODLINE] = 1 }
		end

		it("counts an honest kill as a whole kill toward the next stage", function()
			registerTwoStageBloodline()
			load(killer, carrying)
			local outcome = RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			expect((outcome :: any).Granted.BloodlineStage).to.equal(true)
			expect(BloodlineSystem.GetKillsTowardNextStage(killer, BLOODLINE)).to.equal(1)
		end)

		it("counts a repeat kill of the same victim at its weight", function()
			registerTwoStageBloodline()
			load(killer, carrying)
			-- Stops one short of RequiredKills so no stage-up (and its effect rebind) runs here.
			expect(BloodlineSystem.CountKill(killer, 0.5)).to.equal(true)
			expect(BloodlineSystem.GetKillsTowardNextStage(killer, BLOODLINE)).to.be.near(0.5, 1e-9)
		end)

		it("counts nothing for a kill the gate weighted to zero", function()
			registerTwoStageBloodline()
			load(killer, carrying)
			expect(BloodlineSystem.CountKill(killer, 0)).to.equal(false)
			expect(BloodlineSystem.GetKillsTowardNextStage(killer, BLOODLINE)).to.equal(0)
		end)

		it("reports nothing to count for a player with no bloodline", function()
			load(killer)
			local outcome = RewardSystem.HandlePlayerKilled(victim, killer, freshId())
			expect((outcome :: any).Granted.BloodlineStage).to.equal(false)
		end)
	end)
end
