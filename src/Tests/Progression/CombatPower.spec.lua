--!strict
-- Covers Shared/Progression/CombatPower.lua: reading a combatant's tier, the gap between two, and the scales it
-- yields. Bodies here are bare Models with the Attribute on the Model itself -- the bot/dummy path; the Player
-- path is the same read on a different Instance (Players:GetPlayerFromCharacter), which needs a live Player.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CombatPower = require(ReplicatedStorage.Shared.Progression.CombatPower)
local CombatPowerConstants = require(ReplicatedStorage.Shared.Progression.CombatPowerConstants)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)

local function body(tier: any): Model
	local model = Instance.new("Model")
	if tier ~= nil then
		model:SetAttribute(AttributeConstants.CultivationTier, tier)
	end
	return model
end

return function()
	afterEach(function()
		CombatPower.SetEnabledForTest(nil)
	end)

	describe("CombatPowerConstants", function()
		it("has a non-negative integer gap cap and non-negative per-tier rates", function()
			expect(CombatPowerConstants.MaxTierGap >= 0).to.equal(true)
			expect(CombatPowerConstants.MaxTierGap % 1).to.equal(0)
			expect(CombatPowerConstants.DamagePerTier >= 0).to.equal(true)
			expect(CombatPowerConstants.GuardPerTier >= 0).to.equal(true)
		end)

		it("keeps a one-tier gap winnable: under a 1.25x effective edge", function()
			-- combat-philosophy.md, "Skill vs. power balance". The edge is the square: one side hits harder and
			-- the other side's hits shrink by the same factor. Retune past this only on purpose.
			local damage = CombatPower.ScalesForGap(1)
			expect(damage * damage < 1.25).to.equal(true)
		end)
	end)

	describe("CombatPower.TierOf", function()
		it("reads the tier off a body", function()
			expect(CombatPower.TierOf(body(3))).to.equal(3)
		end)

		it("floors a fractional tier", function()
			expect(CombatPower.TierOf(body(4.7))).to.equal(4)
		end)

		it("has no tier for a missing, out-of-ladder or non-number value", function()
			expect(CombatPower.TierOf(body(nil))).to.equal(nil)
			expect(CombatPower.TierOf(body(0))).to.equal(nil)
			expect(CombatPower.TierOf(body(TierConstants.MaxTier + 1))).to.equal(nil)
			expect(CombatPower.TierOf(body(0 / 0))).to.equal(nil)
			expect(CombatPower.TierOf(body("5"))).to.equal(nil)
			expect(CombatPower.TierOf(nil)).to.equal(nil)
		end)
	end)

	describe("CombatPower.TierGap", function()
		it("is attacker minus defender", function()
			expect(CombatPower.TierGap(body(5), body(3))).to.equal(2)
			expect(CombatPower.TierGap(body(3), body(5))).to.equal(-2)
			expect(CombatPower.TierGap(body(4), body(4))).to.equal(0)
		end)

		it("is clamped to MaxTierGap both ways", function()
			local cap = CombatPowerConstants.MaxTierGap
			expect(CombatPower.TierGap(body(TierConstants.MaxTier), body(1))).to.equal(
				math.min(TierConstants.MaxTier - 1, cap)
			)
			expect(CombatPower.TierGap(body(1), body(TierConstants.MaxTier))).to.equal(
				-math.min(TierConstants.MaxTier - 1, cap)
			)
		end)

		it("is 0 when either side has no tier -- a bot is never treated as tier 1", function()
			expect(CombatPower.TierGap(body(9), body(nil))).to.equal(0)
			expect(CombatPower.TierGap(body(nil), body(9))).to.equal(0)
		end)
	end)

	describe("CombatPower.ScalesForGap", function()
		it("is exactly 1, 1 at no gap", function()
			local damage, guard = CombatPower.ScalesForGap(0)
			expect(damage).to.equal(1)
			expect(guard).to.equal(1)
		end)

		it("is symmetric: the stronger side's gain is the weaker side's loss", function()
			for gap = 1, CombatPowerConstants.MaxTierGap do
				local up, upGuard = CombatPower.ScalesForGap(gap)
				local down, downGuard = CombatPower.ScalesForGap(-gap)
				expect(up * down).to.be.near(1, 1e-9)
				expect(upGuard * downGuard).to.be.near(1, 1e-9)
				expect(up >= 1).to.equal(true)
			end
		end)

		it("compounds per tier", function()
			local damage, guard = CombatPower.ScalesForGap(2)
			expect(damage).to.be.near((1 + CombatPowerConstants.DamagePerTier) ^ 2, 1e-9)
			expect(guard).to.be.near((1 + CombatPowerConstants.GuardPerTier) ^ 2, 1e-9)
		end)
	end)

	describe("CombatPower.Scales -- the switch", function()
		it("is 1, 1 while power is off, whatever the gap", function()
			CombatPower.SetEnabledForTest(false)
			local damage, guard = CombatPower.Scales(body(9), body(1))
			expect(damage).to.equal(1)
			expect(guard).to.equal(1)
		end)

		it("follows the gap while power is on", function()
			CombatPower.SetEnabledForTest(true)
			local damage, guard = CombatPower.Scales(body(6), body(4))
			local expectedDamage, expectedGuard = CombatPower.ScalesForGap(2)
			expect(damage).to.be.near(expectedDamage, 1e-9)
			expect(guard).to.be.near(expectedGuard, 1e-9)
		end)

		it("leaves a fight against a body with no tier unscaled even while on", function()
			CombatPower.SetEnabledForTest(true)
			local damage = CombatPower.Scales(body(9), body(nil))
			expect(damage).to.equal(1)
		end)
	end)
end
