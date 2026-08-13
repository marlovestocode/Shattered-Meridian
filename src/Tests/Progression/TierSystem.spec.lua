--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TierSystem = require(ServerScriptService.Server.Systems.TierSystem)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- TierSystem.Init() is never called here -- it creates a live RemoteEvent and subscribes to
-- GameplayEvents, neither of which this file needs. What IS exercised is the whole promotion curve:
-- ComputeTierForXP/GetThresholdForTier/GetTierWindow/GetTierName are pure (plain numbers in, plain
-- numbers out) by design precisely so the real ladder is testable headlessly rather than a
-- reimplementation of it. TierSystem.Evaluate is covered only on its no-profile path, the same
-- already-accepted gap MeridianSystem.spec.lua and PlayerDataSystem.spec.lua both document for
-- themselves: a genuinely loaded profile needs PlayerDataSystem's DataStore-backed load flow for a
-- live Player, which is Studio/live-server verification only.

return function()
	describe("TierConstants ladder", function()
		it("passes its own structural validation", function()
			local ok, problem = TierConstants.Validate()
			if not ok then
				error(`TierConstants.Validate failed: {problem}`)
			end
			expect(ok).to.equal(true)
		end)

		it("defines nine tiers, matching progression-systems.md's nine-tier backbone", function()
			expect(TierConstants.MaxTier).to.equal(9)
			expect(#TierConstants.Tiers).to.equal(9)
		end)

		it("MaxTier is derived from the table rather than a stale hand-written count", function()
			expect(TierConstants.MaxTier).to.equal(#TierConstants.Tiers)
		end)

		it("starts at 0 so a brand-new profile already holds tier 1", function()
			expect(TierConstants.Tiers[1].MeridianXP).to.equal(0)
			expect(Constants.PlayerData.DefaultTier).to.equal(1)
		end)

		it("gives every tier a non-empty name", function()
			for index, entry in ipairs(TierConstants.Tiers) do
				expect(typeof(entry.Name)).to.equal("string")
				if entry.Name == "" then
					error(`Tier {index} has an empty name`)
				end
			end
		end)
	end)

	describe("TierSystem.ComputeTierForXP", function()
		it("returns tier 1 at zero XP", function()
			expect(TierSystem.ComputeTierForXP(0)).to.equal(1)
		end)

		it("returns tier 1 just below the tier 2 threshold, and tier 2 exactly at it", function()
			local tier2 = TierConstants.Tiers[2].MeridianXP
			expect(TierSystem.ComputeTierForXP(tier2 - 1)).to.equal(1)
			expect(TierSystem.ComputeTierForXP(tier2)).to.equal(2)
		end)

		it("resolves every threshold in the ladder exactly", function()
			for tier, entry in ipairs(TierConstants.Tiers) do
				expect(TierSystem.ComputeTierForXP(entry.MeridianXP)).to.equal(tier)
			end
		end)

		it("resolves one XP below each threshold to the tier beneath it", function()
			for tier = 2, TierConstants.MaxTier do
				expect(TierSystem.ComputeTierForXP(TierConstants.Tiers[tier].MeridianXP - 1)).to.equal(tier - 1)
			end
		end)

		it("clamps at the top of the ladder rather than running past it", function()
			local top = TierConstants.Tiers[TierConstants.MaxTier].MeridianXP
			expect(TierSystem.ComputeTierForXP(top)).to.equal(TierConstants.MaxTier)
			expect(TierSystem.ComputeTierForXP(top * 100)).to.equal(TierConstants.MaxTier)
		end)

		it("floors to tier 1 for negative and NaN XP instead of erroring or returning 0", function()
			expect(TierSystem.ComputeTierForXP(-1)).to.equal(1)
			expect(TierSystem.ComputeTierForXP(-100000)).to.equal(1)
			expect(TierSystem.ComputeTierForXP(0 / 0)).to.equal(1)
		end)

		it("crosses two thresholds in one step when a single total clears both", function()
			-- The multi-tier jump TierSystem.Evaluate relies on: a grant landing past tier 3's
			-- threshold from tier 1 must resolve straight to 3, not to 2.
			expect(TierSystem.ComputeTierForXP(TierConstants.Tiers[3].MeridianXP)).to.equal(3)
		end)
	end)

	describe("TierSystem.GetThresholdForTier", function()
		it("returns each tier's own cumulative threshold", function()
			for tier, entry in ipairs(TierConstants.Tiers) do
				expect(TierSystem.GetThresholdForTier(tier)).to.equal(entry.MeridianXP)
			end
		end)

		it("clamps out-of-ladder tiers to the nearest end instead of indexing nil", function()
			expect(TierSystem.GetThresholdForTier(0)).to.equal(TierConstants.Tiers[1].MeridianXP)
			expect(TierSystem.GetThresholdForTier(-5)).to.equal(TierConstants.Tiers[1].MeridianXP)
			expect(TierSystem.GetThresholdForTier(999)).to.equal(TierConstants.Tiers[TierConstants.MaxTier].MeridianXP)
		end)
	end)

	describe("TierSystem.GetTierWindow", function()
		it("returns this tier's floor and the next tier's threshold", function()
			local floor, ceiling = TierSystem.GetTierWindow(1)
			expect(floor).to.equal(TierConstants.Tiers[1].MeridianXP)
			expect(ceiling).to.equal(TierConstants.Tiers[2].MeridianXP)
		end)

		it("returns a nil ceiling at max tier so a bar never divides by a fabricated span", function()
			local floor, ceiling = TierSystem.GetTierWindow(TierConstants.MaxTier)
			expect(floor).to.equal(TierConstants.Tiers[TierConstants.MaxTier].MeridianXP)
			expect(ceiling).to.equal(nil)
		end)

		it("produces a strictly positive span for every non-max tier", function()
			-- What TierBadge's meter divides by -- a zero or negative span would render a broken bar.
			for tier = 1, TierConstants.MaxTier - 1 do
				local floor, ceiling = TierSystem.GetTierWindow(tier)
				expect(ceiling).to.be.ok()
				expect((ceiling :: number) > floor).to.equal(true)
			end
		end)
	end)

	describe("TierSystem.GetTierName", function()
		it("returns the ladder's own name for every real tier", function()
			for tier, entry in ipairs(TierConstants.Tiers) do
				expect(TierSystem.GetTierName(tier)).to.equal(entry.Name)
			end
		end)

		it("degrades to UnknownTierName for an out-of-ladder tier rather than erroring", function()
			expect(TierSystem.GetTierName(0)).to.equal(TierConstants.UnknownTierName)
			expect(TierSystem.GetTierName(TierConstants.MaxTier + 1)).to.equal(TierConstants.UnknownTierName)
			expect(TierSystem.GetTierName(0 / 0)).to.equal(TierConstants.UnknownTierName)
		end)
	end)

	describe("TierSystem.GetTier / Evaluate (no profile ever loaded)", function()
		it("GetTier falls back to tier 1 for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(TierSystem.GetTier(fakePlayer)).to.equal(1)
		end)

		it("Evaluate returns false and never errors for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(TierSystem.Evaluate(fakePlayer)).to.equal(false)
		end)
	end)

	describe("Ladder pacing against Constants.Meridian.BaseXPPerKill", function()
		it("prices tier 2 within a first session's worth of kills", function()
			-- Guards TierConstants.Tiers' own stated pacing intent ("Tier 2 in six kills") against a
			-- retune of either number in isolation -- the two are coupled and neither file can see the
			-- other's edit.
			local killsToTier2 = TierConstants.Tiers[2].MeridianXP / Constants.Meridian.BaseXPPerKill
			expect(killsToTier2 <= 10).to.equal(true)
			expect(killsToTier2 > 0).to.equal(true)
		end)

		it("keeps the full ladder a long-tail climb rather than a weekend", function()
			local killsToMax = TierConstants.Tiers[TierConstants.MaxTier].MeridianXP / Constants.Meridian.BaseXPPerKill
			expect(killsToMax >= 200).to.equal(true)
		end)
	end)
end
