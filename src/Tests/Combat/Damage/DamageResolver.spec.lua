--!strict
-- Covers Server/Combat/Damage/DamageResolver.lua -- what one already-classified contact costs.
--
-- Pure, so this whole file needs no rig, no Workspace, no clock and no engine: every case is a table
-- of numbers in and a table of numbers out. That is the entire reason the resolver was split from
-- DamageSystem, the same way OutcomeResolver was split from DefenseSystem.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageResolver = require(ServerScriptService.Server.Combat.Damage.DamageResolver)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)

local DAMAGE = 10
local POSTURE = 20

local function profile(overrides: { [string]: any }?): DamageTypes.DamageProfile
	local base: { [string]: any } = {
		Damage = DAMAGE,
		PostureDamage = POSTURE,
		Knockback = nil,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base :: any
end

return function()
	describe("DamageResolver.ComboMultiplier", function()
		it("leaves stage 1 at exactly the authored damage", function()
			-- The property an author reads off the Move Editor: the number they typed is the number the
			-- first hit of a string deals. Anything else here would make every authored value a lie.
			expect(DamageResolver.ComboMultiplier(1)).to.equal(1)
		end)

		it("grows one step per stage", function()
			expect(DamageResolver.ComboMultiplier(2)).to.be.near(
				1 + DamageConstants.Combo.DamageMultiplierPerStage,
				1e-6
			)
		end)

		it("clamps past the ceiling rather than growing forever", function()
			local atCap = DamageResolver.ComboMultiplier(DamageConstants.Combo.MaxStage)
			expect(DamageResolver.ComboMultiplier(DamageConstants.Combo.MaxStage + 50)).to.be.near(atCap, 1e-6)
		end)

		it("treats a garbage stage as stage 1 rather than propagating it", function()
			-- A NaN here would flow into TakeDamage and take the health bar with it, erroring nowhere
			-- useful. Stages come from a live table, so this is cheap insurance rather than paranoia.
			expect(DamageResolver.ComboMultiplier(0 / 0)).to.equal(1)
			expect(DamageResolver.ComboMultiplier(0)).to.equal(1)
			expect(DamageResolver.ComboMultiplier(-3)).to.equal(1)
		end)
	end)

	describe("DamageResolver.AdvancesCombo", function()
		it("credits only the outcomes that actually got through a defence", function()
			expect(DamageResolver.AdvancesCombo("Clean")).to.equal(true)
			expect(DamageResolver.AdvancesCombo("Backstab")).to.equal(true)
			expect(DamageResolver.AdvancesCombo("GuardBroken")).to.equal(true)
			expect(DamageResolver.AdvancesCombo("Blocked")).to.equal(false)
			expect(DamageResolver.AdvancesCombo("Parried")).to.equal(false)
			expect(DamageResolver.AdvancesCombo("Trade")).to.equal(false)
		end)
	end)

	describe("DamageResolver.Resolve -- a clean hit", function()
		it("applies full authored damage, full posture pressure and hitstun", function()
			local result = DamageResolver.Resolve("Clean", "Neutral", profile(), 1)
			expect(result.Damage).to.be.near(DAMAGE, 1e-6)
			expect(result.GuardDrain).to.be.near(POSTURE * DamageConstants.Guard.PressurePerPostureDamage, 1e-6)
			expect(result.HitstunSeconds).to.equal(DamageConstants.Hitstun.Seconds)
			expect(result.AdvancesCombo).to.equal(true)
		end)

		it("scales with the stage it is told it landed at", function()
			local result = DamageResolver.Resolve("Clean", "Neutral", profile(), 3)
			expect(result.Damage).to.be.near(DAMAGE * DamageResolver.ComboMultiplier(3), 1e-6)
		end)

		it("carries knockback through without applying it", function()
			local knockback = { UpVelocity = 40, HorizontalVelocity = 20, RagdollSeconds = 0.5 }
			local result = DamageResolver.Resolve("Clean", "Neutral", profile({ Knockback = knockback }), 1)
			expect(result.Knockback).to.equal(knockback)
		end)
	end)

	describe("DamageResolver.Resolve -- a backstab", function()
		it("multiplies health damage AND posture pressure", function()
			-- Posture too, deliberately: a backstab that cost only health would punish the worst
			-- possible defensive read exactly as much as being caught standing still.
			local result = DamageResolver.Resolve("Backstab", "Blocking", profile(), 1)
			expect(result.Damage).to.be.near(DAMAGE * DamageConstants.Backstab.Multiplier, 1e-6)
			expect(result.GuardDrain).to.be.near(
				POSTURE * DamageConstants.Guard.PressurePerPostureDamage * DamageConstants.Backstab.Multiplier,
				1e-6
			)
		end)
	end)

	describe("DamageResolver.Resolve -- a guard break", function()
		it("deals full damage but drains no further guard", function()
			-- Not a discount: GuardBroken means the guard is GONE, which is a real opening. The pressure
			-- is zero only because DefenseSystem already emptied that same pool on this very contact,
			-- and draining again here would charge one hit twice against one meter.
			local result = DamageResolver.Resolve("GuardBroken", "Blocking", profile(), 1)
			expect(result.Damage).to.be.near(DAMAGE, 1e-6)
			expect(result.GuardDrain).to.equal(0)
			expect(result.AdvancesCombo).to.equal(true)
		end)
	end)

	describe("DamageResolver.Resolve -- a blocked hit", function()
		it("costs the defender nothing this layer owns", function()
			-- DefenseSystem already charged the block through GuardMeter.DrainFor. Draining here as well
			-- would make blocking cost double what its own tuning says.
			local result = DamageResolver.Resolve("Blocked", "Blocking", profile(), 1)
			expect(result.Damage).to.equal(0)
			expect(result.GuardDrain).to.equal(0)
			expect(result.HitstunSeconds).to.equal(0)
		end)

		it("denies the attacker escalation credit outright", function()
			-- The deliberate call over partial credit: a defender who successfully raises a guard
			-- deserves an unambiguous answer to "did that work".
			local result = DamageResolver.Resolve("Blocked", "Blocking", profile(), 1)
			expect(result.AdvancesCombo).to.equal(false)
		end)

		it("leaks damage through a block held while staggered", function()
			-- The counterweight that stops "a parried attacker can still block" from making the punish
			-- hollow, which the previous design measured happening and wrote down.
			-- DefenseConstants.Stagger.MitigationMultiplier has had no consumer until this layer.
			local result = DamageResolver.Resolve("Blocked", "Staggered", profile(), 1)
			local expected = DAMAGE * (1 - DefenseConstants.Stagger.MitigationMultiplier)
			expect(result.Damage).to.be.near(expected, 1e-6)
			expect(result.Damage > 0).to.equal(true)
		end)
	end)

	describe("DamageResolver.Resolve -- a parry or a trade", function()
		it("moves no resource at all, for either kind", function()
			-- DefenseSystem has already cancelled the swing and settled the exchange. The Kind survives
			-- so both clients still get accurate feedback, but nothing here costs anybody anything.
			for _, kind in { "Parried", "Trade" } do
				local result = DamageResolver.Resolve(kind :: any, "ParryWindow", profile(), 4)
				expect(result.Kind).to.equal(kind)
				expect(result.Damage).to.equal(0)
				expect(result.GuardDrain).to.equal(0)
				expect(result.HitstunSeconds).to.equal(0)
				expect(result.AdvancesCombo).to.equal(false)
			end
		end)
	end)

	describe("DamageResolver.Resolve -- an evaded swing", function()
		it("prices to nothing and earns the attacker no escalation", function()
			-- The defender was not there. A move with knockback and a grab authored on it must carry
			-- neither through, or an evaded swing would still launch or hold the body it missed.
			local knockback = { UpVelocity = 40, HorizontalVelocity = 20, RagdollSeconds = 0.5 }
			local result = DamageResolver.Resolve("Evaded", "Neutral", profile({ Knockback = knockback }), 4)
			expect(result.Kind).to.equal("Evaded")
			expect(result.Damage).to.equal(0)
			expect(result.GuardDrain).to.equal(0)
			expect(result.HitstunSeconds).to.equal(0)
			expect(result.AdvancesCombo).to.equal(false)
			expect(result.Knockback).to.equal(nil)
			expect(result.Grab).to.equal(nil)
			expect(DamageResolver.AdvancesCombo("Evaded")).to.equal(false)
		end)
	end)

	describe("DamageResolver.Resolve -- malformed authored numbers", function()
		it("treats a NaN or negative authored value as zero rather than propagating it", function()
			-- These come from the Move Editor by way of a DataStore, so a record written by an older
			-- schema can carry one. A NaN reaching Humanoid:TakeDamage destroys the health bar and
			-- errors nowhere useful.
			local result =
				DamageResolver.Resolve("Clean", "Neutral", profile({ Damage = 0 / 0, PostureDamage = -5 }), 1)
			expect(result.Damage).to.equal(0)
			expect(result.GuardDrain).to.equal(0)
		end)
	end)
end
