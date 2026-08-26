--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager)
local DefaultBloodlineRegistry = require(ServerScriptService.Server.Managers.DefaultBloodlineRegistry)

-- DefaultBloodlineRegistry.Init() is never called here -- it is a boot step, and Main.server.lua is
-- what runs it. This file asserts the CONTENT instead, which is the half that can silently rot:
-- Init logs a validation failure and skips the offending entry rather than throwing, precisely so
-- one bad bloodline can't stop a server -- which also means a mis-authored entry would vanish from
-- the roster in total silence on a live boot. These cases are the thing that would notice.

local function eligibleFor(raceId: string): number
	local count = 0
	for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
		if bloodline.NativeRaceId == nil or bloodline.NativeRaceId == raceId then
			count += 1
		end
	end
	return count
end

return function()
	describe("DefaultBloodlineRegistry roster", function()
		-- world-bible.md fixes the count, and Constants.BloodlineCount is that number in code. A
		-- roster that drifts off it is a content bug, not a tuning choice.
		it("ships exactly the canon number of bloodlines", function()
			expect(#DefaultBloodlineRegistry.List()).to.equal(Constants.BloodlineCount)
		end)

		it("gives every bloodline a unique BloodlineId", function()
			local seen: { [string]: boolean } = {}
			local duplicates: { string } = {}
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				if seen[bloodline.BloodlineId] then
					table.insert(duplicates, bloodline.BloodlineId)
				end
				seen[bloodline.BloodlineId] = true
			end
			-- Concatenated rather than counted so a failure names the offender.
			expect(table.concat(duplicates, ", ")).to.equal("")
		end)

		-- The one that actually protects the roster: every entry goes through the SAME validator a
		-- Kit Editor submission does, so an authored typo fails here rather than being logged and
		-- skipped on a live boot.
		it("passes BloodlineManager.Validate for every entry", function()
			local rejected: { string } = {}
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				local validated, reason = BloodlineManager.Validate(bloodline)
				if not validated then
					table.insert(rejected, `{tostring(bloodline.BloodlineId)}: {tostring(reason)}`)
				end
			end
			expect(table.concat(rejected, " | ")).to.equal("")
		end)

		-- Validate checks one stage at a time; contiguity across the whole ladder is AuditStages'
		-- job, and a gap would strand a player permanently mid-ladder (AdvanceStage returns
		-- "StageGap" and never advances again).
		it("has a contiguous stage ladder for every entry", function()
			BloodlineManager.Init()
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				local validated = BloodlineManager.Validate(bloodline)
				if validated then
					BloodlineManager.Upsert(validated)
				end
			end

			local problems = BloodlineManager.AuditAll()
			expect(table.concat(problems, " | ")).to.equal("")
			BloodlineManager.Init()
		end)

		-- An unrecognised tier is legal (it draws at DefaultWeight -- BloodlineConstants' own
		-- contract), but a tier the roster uses and the weight table has never heard of is almost
		-- always a typo, and it would silently make that bloodline as common as a Common.
		it("only uses rarity tiers that have an authored draw weight", function()
			local unweighted: { string } = {}
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				if BloodlineConstants.RarityWeights[bloodline.RarityTier] == nil then
					table.insert(unweighted, `{bloodline.BloodlineId}: {tostring(bloodline.RarityTier)}`)
				end
			end
			expect(table.concat(unweighted, " | ")).to.equal("")
		end)

		it("names every NativeRaceId as a real race", function()
			local known: { [string]: boolean } = {}
			for _, raceId in ipairs(Constants.CharacterCreation.RaceIds) do
				known[raceId] = true
			end
			local bad: { string } = {}
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				local native = bloodline.NativeRaceId
				if native ~= nil and not known[native] then
					table.insert(bad, `{bloodline.BloodlineId}: {tostring(native)}`)
				end
			end
			expect(table.concat(bad, " | ")).to.equal("")
		end)

		-- What keeps the roll from feeling like chargen already chose for you: every race has to be
		-- able to draw from a real pool, not one or two race-locked entries.
		it("leaves every race a pool worth rolling from", function()
			for _, raceId in ipairs(Constants.CharacterCreation.RaceIds) do
				expect(eligibleFor(raceId) >= 5).to.equal(true)
			end
		end)

		-- Fight-to-grow is the whole advancement model: a bloodline whose condition the on-kill
		-- dispatch can't read (wrong Kind, missing/zero RequiredKills) would be permanently stuck at
		-- stage 1, which is exactly the silent failure requiredKillsFor refuses to paper over.
		it("gives every bloodline an advanceable awakening condition", function()
			local stuck: { string } = {}
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				local condition = bloodline.AwakeningCondition
				local required = if typeof(condition) == "table" then condition.Params.RequiredKills else nil
				if condition.Kind ~= "OnPlayerKilled" or typeof(required) ~= "number" or required <= 0 then
					table.insert(stuck, bloodline.BloodlineId)
				end
			end
			expect(table.concat(stuck, " | ")).to.equal("")
		end)

		-- progression-systems.md: "each stage is a new kit tool, not just a number increase." A
		-- ladder that is only ever stat deltas is the failure mode that rule exists to prevent, so
		-- every bloodline has to grant at least one real ability somewhere on its ladder.
		it("grants a real ability somewhere on every ladder", function()
			local statOnly: { string } = {}
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				local hasAbility = false
				for _, stage in ipairs(bloodline.Stages) do
					if stage.GrantedAbility ~= nil then
						hasAbility = true
						break
					end
				end
				if not hasAbility then
					table.insert(statOnly, bloodline.BloodlineId)
				end
			end
			expect(table.concat(statOnly, " | ")).to.equal("")
		end)

		-- The canon's one named bloodline, and the one whose framing is spelled out in world-bible.md
		-- ("contested authority, not inherited birthright"). Race-agnostic so a Human can draw it at
		-- all; RequiresAscended is what makes that draw contested rather than free.
		it("ships Tianlong as a race-agnostic, Ascension-gated Ascendant", function()
			local tianlong: any = nil
			for _, bloodline in ipairs(DefaultBloodlineRegistry.List()) do
				if bloodline.BloodlineId == "tianlong" then
					tianlong = bloodline
				end
			end
			expect(tianlong).to.be.ok()
			expect(tianlong.RarityTier).to.equal("Ascendant")
			expect(tianlong.NativeRaceId).to.equal(nil)
			expect(tianlong.AwakeningCondition.Params.RequiresAscended).to.be.ok()
		end)
	end)
end
