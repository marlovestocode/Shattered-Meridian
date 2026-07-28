--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CharacterCreationSystem = require(ServerScriptService.Server.Systems.CharacterCreationSystem) :: any
local Constants = require(ReplicatedStorage.Shared.Constants)

-- Pure-logic surface only -- ValidateRaceId/ValidateAttributeBlock/ValidateDisplayName never touch a
-- live Player, PlayerDataSystem, AdminActionSystem, or the DataStore/TextService. Requiring this
-- module never calls CharacterCreationSystem.Init(), so no remote is ever created here -- same
-- "requiring the module never calls Init()" contract BugReportSystem.spec/PlayerDataSystem.spec
-- already rely on.

-- Every attribute at 13 sums to exactly the 78 budget (13 * 6 = 78) and sits comfortably within
-- [5, 20] -- the simplest possible "valid" fixture, reused across every ValidateAttributeBlock test
-- that needs a known-good starting point to mutate one field of.
local function validAttributeBlock(): { [string]: number }
	return {
		Vitality = 13,
		Fortitude = 13,
		MeridianFlow = 13,
		Might = 13,
		Pressure = 13,
		Fleetness = 13,
	}
end

return function()
	describe("CharacterCreationSystem.ValidateRaceId", function()
		for _, raceId in ipairs(Constants.CharacterCreation.RaceIds) do
			it(`accepts the known race "{raceId}"`, function()
				expect(CharacterCreationSystem.ValidateRaceId(raceId)).to.equal(raceId)
			end)
		end

		it("rejects an unknown string", function()
			expect(CharacterCreationSystem.ValidateRaceId("NotARace")).to.equal(nil)
		end)

		it("rejects a non-string value", function()
			expect(CharacterCreationSystem.ValidateRaceId(42)).to.equal(nil)
			expect(CharacterCreationSystem.ValidateRaceId(nil)).to.equal(nil)
			expect(CharacterCreationSystem.ValidateRaceId(true)).to.equal(nil)
		end)
	end)

	describe("CharacterCreationSystem.ValidateAttributeBlock", function()
		it("accepts a block that sums to exactly the total budget", function()
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(validAttributeBlock(), "Human")
			expect(reason).to.equal(nil)
			expect(block).never.to.equal(nil)
			expect((block :: any).Vitality).to.equal(13)
		end)

		it("accepts the minimum-Vitality/maximum-Might extreme still within budget", function()
			local budget = Constants.CharacterCreation.AttributeBudget
			local block = validAttributeBlock()
			block.Vitality = budget.MinPerAttribute
			block.Might = budget.MaxPerAttribute
			-- Spread the remainder evenly across the other four fields so the block still sums to
			-- TotalBudget exactly, however MinPerAttribute/MaxPerAttribute happen to be tuned.
			local remainder = (budget.TotalBudget - block.Vitality - block.Might) / 4
			block.Fortitude = remainder
			block.MeridianFlow = remainder
			block.Pressure = remainder
			block.Fleetness = remainder
			local validated, reason = CharacterCreationSystem.ValidateAttributeBlock(block, "Human")
			expect(reason).to.equal(nil)
			expect(validated).never.to.equal(nil)
		end)

		it("rejects a non-table value", function()
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock("not a table", "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("InvalidType")
		end)

		it("rejects a block missing a required field", function()
			local raw = validAttributeBlock()
			raw.Fleetness = nil :: any
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("MissingField")
		end)

		it("rejects a non-numeric field", function()
			local raw = validAttributeBlock()
			raw.Might = "13" :: any
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("MissingField")
		end)

		it("rejects a non-integer field", function()
			local raw = validAttributeBlock()
			raw.Pressure = 12.5
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("NotInteger")
		end)

		it("rejects a field below MinPerAttribute (Human has no prefill to grandfather it in)", function()
			local raw = validAttributeBlock()
			raw.Vitality = Constants.CharacterCreation.AttributeBudget.MinPerAttribute - 1
			raw.Might = raw.Might + 1 -- keep the sum irrelevant -- OutOfRange should fire first
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("OutOfRange")
		end)

		it("rejects a field above MaxPerAttribute", function()
			local raw = validAttributeBlock()
			raw.Might = Constants.CharacterCreation.AttributeBudget.MaxPerAttribute + 1
			raw.Vitality = raw.Vitality - 1
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("OutOfRange")
		end)

		it("rejects a block whose sum is under the total budget", function()
			local raw = validAttributeBlock()
			raw.Vitality = 12
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("BudgetMismatch")
		end)

		it("rejects a block whose sum is over the total budget", function()
			local raw = validAttributeBlock()
			raw.Vitality = 14
			local block, reason = CharacterCreationSystem.ValidateAttributeBlock(raw, "Human")
			expect(block).to.equal(nil)
			expect(reason).to.equal("BudgetMismatch")
		end)
	end)

	-- The interim point-pool rebalance (docs/design/intro-redesign-handoff.md Phase D, 2026-07-25):
	-- MinPerAttribute is now 10, but a race's own prefill can grandfather a field in below that --
	-- see Constants.lua's own AttributeFloors comment for the full rationale. Hollowborn's Vitality
	-- (base 10 - 1 = 9) is the only real case today.
	describe("CharacterCreationSystem.ValidateAttributeBlock -- race-aware floor", function()
		it("accepts Hollowborn at its own Vitality prefill even though it sits below the flat floor", function()
			local budget = Constants.CharacterCreation.AttributeBudget
			local block = validAttributeBlock()
			local floorValue = budget.BaseValuePerAttribute - 1 -- Hollowborn's own RacePrefills.Vitality delta.
			local drop = 13 - floorValue
			block.Vitality = floorValue
			block.MeridianFlow += drop -- rebalance so the block still sums to TotalBudget exactly.
			local validated, reason = CharacterCreationSystem.ValidateAttributeBlock(block, "Hollowborn")
			expect(reason).to.equal(nil)
			expect(validated).never.to.equal(nil)
		end)

		it("rejects that SAME block for Human, who has no Vitality prefill to grandfather it in", function()
			local budget = Constants.CharacterCreation.AttributeBudget
			local block = validAttributeBlock()
			local floorValue = budget.BaseValuePerAttribute - 1
			local drop = 13 - floorValue
			block.Vitality = floorValue
			block.MeridianFlow += drop
			local validated, reason = CharacterCreationSystem.ValidateAttributeBlock(block, "Human")
			expect(validated).to.equal(nil)
			expect(reason).to.equal("OutOfRange")
		end)

		it("still rejects Hollowborn going even lower than its own Vitality floor", function()
			local budget = Constants.CharacterCreation.AttributeBudget
			local hollowbornFloor = budget.BaseValuePerAttribute - 1
			local block = validAttributeBlock()
			local drop = 13 - (hollowbornFloor - 1)
			block.Vitality = hollowbornFloor - 1
			block.MeridianFlow += drop
			local validated, reason = CharacterCreationSystem.ValidateAttributeBlock(block, "Hollowborn")
			expect(validated).to.equal(nil)
			expect(reason).to.equal("OutOfRange")
		end)

		it("does not raise a race's floor above MinPerAttribute just because its prefill is positive", function()
			-- Firmborn's own Fortitude prefill is +2 (base 12), but the floor should still be the
			-- flat MinPerAttribute (10), not 12 -- a prefill is a starting lean the player must stay
			-- free to reallocate away, not a locked-in minimum.
			local budget = Constants.CharacterCreation.AttributeBudget
			local block = validAttributeBlock()
			local drop = 13 - budget.MinPerAttribute
			block.Fortitude = budget.MinPerAttribute
			block.Might += drop
			local validated, reason = CharacterCreationSystem.ValidateAttributeBlock(block, "Firmborn")
			expect(reason).to.equal(nil)
			expect(validated).never.to.equal(nil)
		end)
	end)

	describe("CharacterCreationSystem.ValidateDisplayName", function()
		it("accepts a plain ASCII name within bounds", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Wren Ashfall")
			expect(reason).to.equal(nil)
			expect(name).to.equal("Wren Ashfall")
		end)

		it("accepts a name using every allowed punctuation character", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Mar'e-Lin")
			expect(reason).to.equal(nil)
			expect(name).to.equal("Mar'e-Lin")
		end)

		it("accepts non-ASCII unicode letters", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Renée")
			expect(reason).to.equal(nil)
			expect(name).to.equal("Renée")
		end)

		it("rejects a non-string value", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName(42)
			expect(name).to.equal(nil)
			expect(reason).to.equal("InvalidType")
		end)

		it("rejects a name shorter than the minimum length", function()
			local tooShort = string.rep("a", Constants.CharacterCreation.DisplayName.MinLength - 1)
			local name, reason = CharacterCreationSystem.ValidateDisplayName(tooShort)
			expect(name).to.equal(nil)
			expect(reason).to.equal("TooShort")
		end)

		it("accepts a name exactly at the minimum length", function()
			local exact = string.rep("a", Constants.CharacterCreation.DisplayName.MinLength)
			local name, reason = CharacterCreationSystem.ValidateDisplayName(exact)
			expect(reason).to.equal(nil)
			expect(name).to.equal(exact)
		end)

		it("rejects a name longer than the maximum length", function()
			local tooLong = string.rep("a", Constants.CharacterCreation.DisplayName.MaxLength + 1)
			local name, reason = CharacterCreationSystem.ValidateDisplayName(tooLong)
			expect(name).to.equal(nil)
			expect(reason).to.equal("TooLong")
		end)

		it("accepts a name exactly at the maximum length", function()
			local exact = string.rep("a", Constants.CharacterCreation.DisplayName.MaxLength)
			local name, reason = CharacterCreationSystem.ValidateDisplayName(exact)
			expect(reason).to.equal(nil)
			expect(name).to.equal(exact)
		end)

		it("rejects a leading space", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName(" Wren")
			expect(name).to.equal(nil)
			expect(reason).to.equal("LeadingOrTrailingSpace")
		end)

		it("rejects a trailing space", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Wren ")
			expect(name).to.equal(nil)
			expect(reason).to.equal("LeadingOrTrailingSpace")
		end)

		it("rejects consecutive spaces", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Wren  Ashfall")
			expect(name).to.equal(nil)
			expect(reason).to.equal("ConsecutiveSpaces")
		end)

		it("rejects a disallowed ASCII symbol", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Wren@Ashfall")
			expect(name).to.equal(nil)
			expect(reason).to.equal("InvalidCharacter")
		end)

		it("rejects a control character", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Wren\tAshfall")
			expect(name).to.equal(nil)
			expect(reason).to.equal("InvalidCharacter")
		end)

		it("rejects a zero-width space (name-spoofing character)", function()
			local name, reason = CharacterCreationSystem.ValidateDisplayName("Wren\u{200B}Ashfall")
			expect(name).to.equal(nil)
			expect(reason).to.equal("InvalidCharacter")
		end)
	end)
end
