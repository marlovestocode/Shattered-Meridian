--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local QiDeviationSystem = require(ServerScriptService.Server.Systems.QiDeviationSystem)
local QiDeviationConstants = require(ReplicatedStorage.Shared.QiDeviationConstants)

-- Pure-formula surface (ComputeRiskAfterSpend) never touches PlayerDataSystem, CharacterSheetSystem,
-- or a live Player -- QiDeviationSystem.Init() is never called in this spec file, the same
-- "requiring the module never calls Init()" contract QiSystem.spec.lua/PlayerDataSystem.spec.lua
-- already rely on. IsLocked IS exercised below, but only against the "never processed a spend"
-- fallback path (a plain table standing in for Player, same trick QiSystem.spec.lua uses) -- a
-- genuinely triggered lockout requires GameplayEvents.OnQiSpent to have actually fired for a real
-- Player with a loaded profile, which is Studio/live-server verification only, the same
-- already-accepted gap QiSystem.spec.lua documents for its own Player-keyed state.

return function()
	describe("QiDeviationSystem.ComputeRiskAfterSpend", function()
		it("accrues nothing for a spend that stays at or above SafeQiFraction", function()
			local newRisk, triggered =
				QiDeviationSystem.ComputeRiskAfterSpend(0, QiDeviationConstants.SafeQiFraction, 0)
			expect(newRisk).to.equal(0)
			expect(triggered).to.equal(false)

			local newRisk2, triggered2 = QiDeviationSystem.ComputeRiskAfterSpend(0, 1, 0)
			expect(newRisk2).to.equal(0)
			expect(triggered2).to.equal(false)
		end)

		it("accrues risk proportional to how far below SafeQiFraction the spend landed", function()
			local halfDeficit = QiDeviationConstants.SafeQiFraction / 2
			local newRisk, triggered = QiDeviationSystem.ComputeRiskAfterSpend(0, halfDeficit, 0)

			expect(triggered).to.equal(false)
			expect(math.abs(newRisk - (halfDeficit * QiDeviationConstants.RiskPerDeficitFraction)) < 1e-6).to.equal(
				true
			)
		end)

		it("accrues the maximum for a spend that empties Qi entirely", function()
			local newRisk = QiDeviationSystem.ComputeRiskAfterSpend(0, 0, 0)
			local expected = QiDeviationConstants.SafeQiFraction * QiDeviationConstants.RiskPerDeficitFraction
			expect(math.abs(newRisk - expected) < 1e-6).to.equal(true)
		end)

		it("decays existing risk by elapsed time before accruing anything new", function()
			local decayOnly = QiDeviationConstants.RiskDecayPerSecond * 5
			local newRisk = QiDeviationSystem.ComputeRiskAfterSpend(decayOnly, 1, 5)
			expect(math.abs(newRisk - 0) < 1e-6).to.equal(true)
		end)

		it("never decays risk below zero even with a large elapsed gap", function()
			local newRisk = QiDeviationSystem.ComputeRiskAfterSpend(10, 1, 10000)
			expect(newRisk).to.equal(0)
		end)

		it("treats a negative or non-numeric elapsed time as zero elapsed", function()
			local newRisk = QiDeviationSystem.ComputeRiskAfterSpend(10, 1, -5)
			expect(newRisk).to.equal(10)
		end)

		it("treats a NaN current risk as zero rather than propagating it", function()
			local nan = 0 / 0
			local newRisk = QiDeviationSystem.ComputeRiskAfterSpend(nan, 1, 0)
			expect(newRisk).to.equal(0)
		end)

		it("triggers and resets to exactly zero once accrued risk reaches TriggerThreshold", function()
			local newRisk, triggered =
				QiDeviationSystem.ComputeRiskAfterSpend(QiDeviationConstants.TriggerThreshold - 0.01, 0, 0)
			expect(triggered).to.equal(true)
			expect(newRisk).to.equal(0)
		end)

		it("does not trigger for risk that stays just under TriggerThreshold", function()
			local newRisk, triggered =
				QiDeviationSystem.ComputeRiskAfterSpend(QiDeviationConstants.TriggerThreshold - 50, 0, 0)
			expect(triggered).to.equal(false)
			expect(newRisk > 0).to.equal(true)
		end)
	end)

	describe("QiDeviationSystem.IsLocked (never processed a spend)", function()
		it("is false for a player this System has never seen", function()
			local fakePlayer = {} :: any
			expect(QiDeviationSystem.IsLocked(fakePlayer)).to.equal(false)
		end)
	end)
end
