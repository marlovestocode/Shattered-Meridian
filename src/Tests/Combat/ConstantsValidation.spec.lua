--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConstantsValidation = require(ReplicatedStorage.Shared.ConstantsValidation)
local Fixtures = require(game:GetService("ServerScriptService").Tests.TestHelpers.Fixtures)

local function makeDefinition(overrides: { [string]: any }?): { [string]: any }
	local definition = {
		DebugName = "TestAttack",
		Size = Vector3.new(5, 5, 5),
		Offset = CFrame.new(0, 0, -3),
		WindupSeconds = 0.1,
		ActiveSeconds = 0.1,
		RecoverySeconds = 0.1,
		Damage = 10,
		PostureDamage = 20,
		Cooldown = 0.5,
	}
	return Fixtures.applyOverrides(definition, overrides)
end

local function makeWeapon(overrides: { [string]: any }?): { [string]: any }
	local weapon = {
		Stages = {
			Basic = { makeDefinition({ DebugName = "Basic1" }) },
			Heavy = { makeDefinition({ DebugName = "Heavy1" }) },
			Finisher = makeDefinition({ DebugName = "Finisher" }),
		},
	}
	return Fixtures.applyOverrides(weapon, overrides)
end

local function makeCombatConstants(overrides: { [string]: any }?): { [string]: any }
	local combatConstants = {
		Weapons = {
			Primary = makeWeapon(),
			Secondary = makeWeapon(),
			Default = "Primary",
			SwapCooldownSeconds = 1,
		},
		Hitboxes = {
			SampleRate = 30,
			MaxSamplesPerSwing = 10,
			MaxCandidateRadius = 20,
			SweepSubsteps = 4,
			MaxPartsPerQuery = 50,
		},
		CombatEngagementRange = 20,
		MaxTrackedOpponents = 4,
		-- Comfortably above makeDefinition's Cooldown (0.5) so the default fixture satisfies the
		-- Heavy-combo reachability relationship -- see the dedicated describe block below.
		HeavyComboResetSeconds = 3.5,
	}
	return Fixtures.applyOverrides(combatConstants, overrides)
end

return function()
	describe("ConstantsValidation.ValidateAttackDefinition", function()
		it("passes a fully-shaped definition", function()
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, makeDefinition())).to.equal(true)
		end)

		it("fails a non-table definition", function()
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, "not a table")).to.equal(false)
		end)

		it("fails when DebugName is missing", function()
			local definition = makeDefinition()
			definition.DebugName = nil
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, definition)).to.equal(false)
		end)

		it("fails when Size is not a Vector3", function()
			local definition = makeDefinition({ Size = "not a vector" })
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, definition)).to.equal(false)
		end)

		it("fails when Offset is not a CFrame", function()
			local definition = makeDefinition({ Offset = "not a cframe" })
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, definition)).to.equal(false)
		end)

		it("fails when a required numeric field is missing", function()
			local definition = makeDefinition()
			definition.Cooldown = nil
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, definition)).to.equal(false)
		end)

		it("fails when a required numeric field is non-numeric", function()
			local definition = makeDefinition({ Damage = "ten" })
			expect(ConstantsValidation.ValidateAttackDefinition("Test", 1, definition)).to.equal(false)
		end)
	end)

	describe("ConstantsValidation.ValidateAttackCategory", function()
		it("passes a non-empty array of valid definitions", function()
			local stages = { makeDefinition(), makeDefinition() }
			expect(ConstantsValidation.ValidateAttackCategory("Basic", stages)).to.equal(true)
		end)

		it("fails an empty array", function()
			expect(ConstantsValidation.ValidateAttackCategory("Basic", {})).to.equal(false)
		end)

		it("fails a non-table value", function()
			expect(ConstantsValidation.ValidateAttackCategory("Basic", "nope")).to.equal(false)
		end)

		it("fails when any one stage in the array is malformed", function()
			local badDefinition = makeDefinition()
			badDefinition.Size = nil
			local stages = { makeDefinition(), badDefinition }
			expect(ConstantsValidation.ValidateAttackCategory("Basic", stages)).to.equal(false)
		end)
	end)

	describe("ConstantsValidation.ValidateWeapon", function()
		it("passes a fully-shaped weapon", function()
			expect(ConstantsValidation.ValidateWeapon("Primary", makeWeapon())).to.equal(true)
		end)

		it("fails a non-table weaponData", function()
			expect(ConstantsValidation.ValidateWeapon("Primary", "nope")).to.equal(false)
		end)

		it("fails when Stages is missing", function()
			expect(ConstantsValidation.ValidateWeapon("Primary", {})).to.equal(false)
		end)

		it("fails when the Finisher definition is malformed", function()
			local weapon = makeWeapon()
			weapon.Stages.Finisher.Damage = nil
			expect(ConstantsValidation.ValidateWeapon("Primary", weapon)).to.equal(false)
		end)

		it("fails when the Basic stage array is empty", function()
			local weapon = makeWeapon()
			weapon.Stages.Basic = {}
			expect(ConstantsValidation.ValidateWeapon("Primary", weapon)).to.equal(false)
		end)
	end)

	describe("ConstantsValidation.ValidateCombatConstants", function()
		it("passes a fully-shaped Constants.Combat fixture", function()
			expect(ConstantsValidation.ValidateCombatConstants(makeCombatConstants())).to.equal(true)
		end)

		it("fails when Weapons is missing entirely", function()
			local combatConstants = makeCombatConstants()
			combatConstants.Weapons = nil
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when Hitboxes is missing entirely", function()
			local combatConstants = makeCombatConstants()
			combatConstants.Hitboxes = nil
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when Weapons.Default doesn't name a real weapon", function()
			local combatConstants = makeCombatConstants()
			combatConstants.Weapons.Default = "Tertiary"
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when Weapons.SwapCooldownSeconds is missing/invalid", function()
			local combatConstants = makeCombatConstants()
			combatConstants.Weapons.SwapCooldownSeconds = -1
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when a Hitboxes numeric field is missing/invalid", function()
			local combatConstants = makeCombatConstants()
			combatConstants.Hitboxes.SampleRate = 0
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when CombatEngagementRange is missing/invalid", function()
			local combatConstants = makeCombatConstants()
			combatConstants.CombatEngagementRange = 0
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when MaxTrackedOpponents is missing/invalid", function()
			local combatConstants = makeCombatConstants()
			combatConstants.MaxTrackedOpponents = nil
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when the Secondary weapon is malformed even if Primary is fine", function()
			local combatConstants = makeCombatConstants()
			combatConstants.Weapons.Secondary.Stages.Heavy = {}
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)
	end)

	-- Regression coverage for the shipped bug where Primary could never throw Heavy2: the Heavy
	-- string is throw-based, so a stage Cooldown at or above the combo's reset window means
	-- comboIndex is always back to 0 before the next Heavy is legal and later stages are
	-- unreachable. Both weapons' data was individually well-formed, so only a check on the
	-- RELATIONSHIP between the two constants can catch it.
	describe("ConstantsValidation.ValidateCombatConstants (Heavy combo reachability)", function()
		local function withHeavyStages(combatConstants, weaponId: string, cooldowns: { number })
			local stages = {}
			for index, cooldown in ipairs(cooldowns) do
				table.insert(stages, makeDefinition({ DebugName = `Heavy{index}`, Cooldown = cooldown }))
			end
			combatConstants.Weapons[weaponId].Stages.Heavy = stages
			return combatConstants
		end

		it("fails when HeavyComboResetSeconds is missing", function()
			local combatConstants = makeCombatConstants()
			combatConstants.HeavyComboResetSeconds = nil
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails when HeavyComboResetSeconds is not a positive number", function()
			local combatConstants = makeCombatConstants()
			combatConstants.HeavyComboResetSeconds = 0
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails a multi-stage Heavy whose stage Cooldown meets the reset window", function()
			-- The exact shape that shipped: Cooldown (3.0) >= window (3.0) strands stage 2.
			local combatConstants = makeCombatConstants({ HeavyComboResetSeconds = 3.0 })
			withHeavyStages(combatConstants, "Primary", { 3.0, 3.0 })
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("fails a multi-stage Heavy whose stage Cooldown exceeds the reset window", function()
			local combatConstants = makeCombatConstants({ HeavyComboResetSeconds = 1.5 })
			withHeavyStages(combatConstants, "Primary", { 3.0, 3.0 })
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("passes a multi-stage Heavy whose Cooldowns sit under the reset window", function()
			local combatConstants = makeCombatConstants({ HeavyComboResetSeconds = 3.5 })
			withHeavyStages(combatConstants, "Primary", { 3.0, 3.0 })
			withHeavyStages(combatConstants, "Secondary", { 0.58, 0.63 })
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(true)
		end)

		it("catches an unreachable stage on Secondary even when Primary is fine", function()
			local combatConstants = makeCombatConstants({ HeavyComboResetSeconds = 1.5 })
			withHeavyStages(combatConstants, "Primary", { 0.5, 0.5 })
			withHeavyStages(combatConstants, "Secondary", { 3.0, 3.0 })
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(false)
		end)

		it("exempts a single-stage Heavy -- there is no stage 2 to strand", function()
			-- A one-stage category re-throws the same stage forever by design, so a long cooldown is a
			-- balance choice rather than a lockout. Guards against the check becoming an obstacle to a
			-- deliberately single-stage weapon.
			local combatConstants = makeCombatConstants({ HeavyComboResetSeconds = 1.5 })
			withHeavyStages(combatConstants, "Primary", { 9.0 })
			withHeavyStages(combatConstants, "Secondary", { 9.0 })
			expect(ConstantsValidation.ValidateCombatConstants(combatConstants)).to.equal(true)
		end)
	end)
end
