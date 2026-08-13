--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local QiSystem = require(ServerScriptService.Server.Systems.QiSystem)
local QiConstants = require(ReplicatedStorage.Shared.QiConstants)

-- Pure-formula surface (ComputeMaxQi/ComputeRegenPerSecond/CheckQiConflict) never touches
-- PlayerDataSystem or a live Player -- QiSystem.Init() is never called in this spec file, the same
-- "requiring the module never calls Init()" contract PlayerDataSystem.spec/BugReportSystem.spec
-- already rely on. GetQiType/GetQi/GetMaxQi ARE exercised below, but only against the
-- "profile never loaded" fallback path (a plain table standing in for Player, same trick
-- RateLimiter.spec.lua/PlayerDataSystem.spec.lua already use) -- a genuinely seeded qiState requires
-- PlayerDataSystem.OnProfileLoaded to have actually fired for a real Player, which is Studio/
-- live-server verification only, the same already-accepted gap those specs document for their own
-- Player-keyed state.

return function()
	describe("QiSystem.ComputeMaxQi", function()
		it("returns exactly the tier's table value at the baseline MeridianFlow", function()
			for tier, expected in pairs(QiConstants.MaxQiByTier) do
				expect(QiSystem.ComputeMaxQi(tier, QiConstants.BaselineMeridianFlow)).to.equal(expected)
			end
		end)

		it("adds MaxQiPerMeridianFlowPoint for every point above baseline", function()
			local baseline = QiSystem.ComputeMaxQi(1, QiConstants.BaselineMeridianFlow)
			local plusFive = QiSystem.ComputeMaxQi(1, QiConstants.BaselineMeridianFlow + 5)

			expect(plusFive - baseline).to.equal(5 * QiConstants.MaxQiPerMeridianFlowPoint)
		end)

		it("subtracts for every point below baseline, never going below 1", function()
			local farBelowBaseline = QiSystem.ComputeMaxQi(1, -1000)
			expect(farBelowBaseline).to.equal(1)
		end)

		it("clamps a tier above the highest defined entry to that entry instead of indexing nil", function()
			local atMax = QiSystem.ComputeMaxQi(QiConstants.MaxTierDefined, QiConstants.BaselineMeridianFlow)
			local beyondMax = QiSystem.ComputeMaxQi(QiConstants.MaxTierDefined + 5, QiConstants.BaselineMeridianFlow)

			expect(beyondMax).to.equal(atMax)
		end)

		it("clamps a tier below 1 up to tier 1 instead of indexing nil", function()
			local tierOne = QiSystem.ComputeMaxQi(1, QiConstants.BaselineMeridianFlow)
			local tierZero = QiSystem.ComputeMaxQi(0, QiConstants.BaselineMeridianFlow)

			expect(tierZero).to.equal(tierOne)
		end)
	end)

	describe("QiSystem.ComputeRegenPerSecond", function()
		it("returns exactly BaseRegenPerSecond at the baseline MeridianFlow", function()
			expect(QiSystem.ComputeRegenPerSecond(QiConstants.BaselineMeridianFlow)).to.equal(
				QiConstants.BaseRegenPerSecond
			)
		end)

		it("scales by RegenPerSecondPerMeridianFlowPoint above baseline", function()
			local baseline = QiSystem.ComputeRegenPerSecond(QiConstants.BaselineMeridianFlow)
			local plusTen = QiSystem.ComputeRegenPerSecond(QiConstants.BaselineMeridianFlow + 10)
			local expectedDelta = 10 * QiConstants.RegenPerSecondPerMeridianFlowPoint

			expect(math.abs((plusTen - baseline) - expectedDelta) < 1e-6).to.equal(true)
		end)

		it("never goes negative even far below baseline", function()
			expect(QiSystem.ComputeRegenPerSecond(-1000)).to.equal(0)
		end)
	end)

	describe("QiSystem.CheckQiConflict", function()
		it("is None for a type against itself", function()
			expect(QiSystem.CheckQiConflict("Celestial", "Celestial")).to.equal("None")
			expect(QiSystem.CheckQiConflict("Demonic", "Demonic")).to.equal("None")
			expect(QiSystem.CheckQiConflict("Unbound", "Unbound")).to.equal("None")
		end)

		it("is Severe for Celestial vs Demonic, order-independent", function()
			expect(QiSystem.CheckQiConflict("Celestial", "Demonic")).to.equal("Severe")
			expect(QiSystem.CheckQiConflict("Demonic", "Celestial")).to.equal("Severe")
		end)

		it("is Risky for Unbound against either sect, order-independent", function()
			expect(QiSystem.CheckQiConflict("Celestial", "Unbound")).to.equal("Risky")
			expect(QiSystem.CheckQiConflict("Unbound", "Celestial")).to.equal("Risky")
			expect(QiSystem.CheckQiConflict("Demonic", "Unbound")).to.equal("Risky")
			expect(QiSystem.CheckQiConflict("Unbound", "Demonic")).to.equal("Risky")
		end)
	end)

	describe("QiSystem.GetQiType / GetQi / GetMaxQi (no profile ever loaded)", function()
		it("GetQiType falls back to QiConstants.DefaultQiType", function()
			local fakePlayer = {} :: any
			expect(QiSystem.GetQiType(fakePlayer)).to.equal(QiConstants.DefaultQiType)
		end)

		it("GetQi/GetMaxQi are zero for a player with no seeded Qi state", function()
			local fakePlayer = {} :: any
			expect(QiSystem.GetQi(fakePlayer)).to.equal(0)
			expect(QiSystem.GetMaxQi(fakePlayer)).to.equal(0)
		end)

		it("Spend/Refund are safe no-ops for a player with no seeded Qi state", function()
			local fakePlayer = {} :: any
			expect(QiSystem.Spend(fakePlayer, 10)).to.equal(false)
			-- Refund on an unseeded player must not error -- it silently does nothing.
			QiSystem.Refund(fakePlayer, 10)
			expect(QiSystem.GetQi(fakePlayer)).to.equal(0)
		end)

		it("Spend rejects a non-positive or non-numeric amount", function()
			local fakePlayer = {} :: any
			expect(QiSystem.Spend(fakePlayer, 0)).to.equal(false)
			expect(QiSystem.Spend(fakePlayer, -5)).to.equal(false)
		end)

		-- RefreshFromProfile is the recompute entry point that replaced the old per-Heartbeat-tick
		-- GetProfile calls (see QiSystem.lua's own header on that function for the ~32,000
		-- allocations/sec at 30 players it removed). Same "safe no-op for an unseeded player" contract
		-- Spend/Refund above already have -- it must never error just because onHeartbeatTick or a
		-- future tier-up hook calls it for a player whose profile hasn't loaded yet.
		it("RefreshFromProfile is a safe no-op for a player with no seeded Qi state", function()
			local fakePlayer = {} :: any
			QiSystem.RefreshFromProfile(fakePlayer)
			expect(QiSystem.GetQi(fakePlayer)).to.equal(0)
			expect(QiSystem.GetMaxQi(fakePlayer)).to.equal(0)
		end)
	end)
end
