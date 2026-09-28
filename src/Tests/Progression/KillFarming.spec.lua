--!strict
-- Covers ProgressionSystem's repeat-victim rule -- the kill-farming guard -- through the real spine:
-- RewardSystem composes, ProgressionSystem weighs and routes, MeridianSystem scales its own amount and
-- writes it through a real (spec-installed) profile. Time is passed to Apply explicitly, so the ten-
-- minute window is walked without sleeping.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ProgressionConstants = require(ReplicatedStorage.Shared.Progression.ProgressionConstants)
local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem) :: any
local ProgressionSystem = require(ServerScriptService.Server.Systems.ProgressionSystem)
local RewardSystem = require(ServerScriptService.Server.Systems.RewardSystem)

local BASE = Constants.Meridian.BaseXPPerKill
local RULE = ProgressionConstants.RepeatVictim

local nextUserId = 9500

local function fakePlayer(name: string): any
	nextUserId += 1
	return { Name = name, UserId = nextUserId }
end

return function()
	local killer: any
	local victim: any
	local deathId: number
	local installed: { any }

	local function load(player: any): ()
		PlayerDataSystem.InstallProfileForSpec(player, PlayerDataSystem.CreateDefaultProfile(player.UserId))
		table.insert(installed, player)
	end

	local function xpOf(player: any): number
		return PlayerDataSystem.GetProfile(player).meridianXp
	end

	-- One kill of `target` by `by` at time `at`, through RewardSystem's composer and ProgressionSystem.
	local function kill(by: any, target: any, at: number): any
		deathId += 1
		local manifest = RewardSystem.ComposeKillManifest(target, by, deathId)
		return ProgressionSystem.Apply(manifest :: any, at)
	end

	beforeEach(function()
		RewardSystem.Reset()
		ProgressionSystem.Reset()
		installed = {}
		deathId = 0
		killer = fakePlayer("Farmer")
		victim = fakePlayer("Alt")
		load(killer)
	end)

	afterEach(function()
		for _, player in installed do
			PlayerDataSystem.EvictProfileForSpec(player)
		end
		RewardSystem.Reset()
		ProgressionSystem.Reset()
	end)

	describe("ProgressionConstants.RepeatVictim", function()
		it("is a non-increasing ladder of weights in (0, 1], starting at a full kill", function()
			expect(RULE.WindowSeconds > 0).to.equal(true)
			expect(RULE.Weights[1]).to.equal(1)
			for index, weight in RULE.Weights do
				expect(weight > 0 and weight <= 1).to.equal(true)
				if index > 1 then
					expect(weight <= RULE.Weights[index - 1]).to.equal(true)
				end
			end
		end)
	end)

	describe("the same victim, over and over", function()
		it("pays each step of the ladder, then nothing", function()
			local expectedTotal = 0
			for index, weight in RULE.Weights do
				local outcome = kill(killer, victim, 100 + index)
				expect(outcome.Accepted).to.equal(true)
				expect(outcome.Weight).to.equal(weight)
				expectedTotal += math.max(1, math.floor(BASE * weight + 0.5))
				expect(xpOf(killer)).to.equal(expectedTotal)
			end

			local farmed = kill(killer, victim, 200)
			expect(farmed.Accepted).to.equal(false)
			expect(farmed.Refusal).to.equal("RepeatVictim")
			expect(farmed.Weight).to.equal(0)
			expect(xpOf(killer)).to.equal(expectedTotal)
		end)

		it("keeps a pair that never stops farming at zero -- every kill restarts the window", function()
			local at = 100
			for _ = 1, #RULE.Weights do
				kill(killer, victim, at)
			end
			-- Each further kill lands just inside the window of the one before it.
			for _ = 1, 5 do
				at += RULE.WindowSeconds - 1
				expect(kill(killer, victim, at).Refusal).to.equal("RepeatVictim")
			end
		end)

		it("pays a full kill again once the window has passed with no kill of that victim", function()
			for index = 1, #RULE.Weights + 1 do
				kill(killer, victim, 100 + index)
			end
			local later = kill(killer, victim, 100 + #RULE.Weights + 1 + RULE.WindowSeconds + 1)
			expect(later.Accepted).to.equal(true)
			expect(later.Weight).to.equal(1)
		end)
	end)

	describe("what the rule must not touch", function()
		it("does not discount a different victim", function()
			for index = 1, #RULE.Weights + 1 do
				kill(killer, victim, 100 + index)
			end
			local stranger = fakePlayer("Stranger")
			local outcome = kill(killer, stranger, 110)
			expect(outcome.Weight).to.equal(1)
		end)

		it("does not discount the victim killing back -- the direction is part of the pair", function()
			load(victim)
			for index = 1, #RULE.Weights + 1 do
				kill(killer, victim, 100 + index)
			end
			local revenge = kill(victim, killer, 110)
			expect(revenge.Accepted).to.equal(true)
			expect(revenge.Weight).to.equal(1)
		end)
	end)

	describe("rejoining", function()
		it("does not reset the count -- a returning victim is the same UserId in a new Player", function()
			for index = 1, #RULE.Weights do
				kill(killer, victim, 100 + index)
			end
			local rejoined = { Name = victim.Name, UserId = victim.UserId } :: any
			expect(kill(killer, rejoined, 110).Refusal).to.equal("RepeatVictim")
		end)
	end)
end
