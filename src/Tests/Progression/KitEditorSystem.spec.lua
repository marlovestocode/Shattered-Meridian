--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local KitEditorSystem = require(ServerScriptService.Server.Systems.KitEditorSystem)
local RaceManager = require(ServerScriptService.Server.Managers.RaceManager)
local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager)

-- EncodeRaceTraitRecord/EncodeBloodlineRecord never touch a live remote, a DataStore, or a Player --
-- KitEditorSystem.Init() is never called in this spec file, the same "requiring the module never
-- calls Init()" contract every other System's own spec relies on.
--
-- This file exists for the exact reason MoveEditorSystem.spec.lua's own header names: an encode
-- function that silently omits a field validates fine and works immediately in the live in-memory
-- registry, so an admin's edit LOOKS saved right up until the next server restart re-loads content
-- from a DataStore record that never had the field at all. Every RaceTraitDefinition/
-- BloodlineDefinition field should have a round-trip case here -- "round-trip" meaning encode, then
-- feed the result straight back through RaceManager.Validate/BloodlineManager.Validate (this System's
-- own decode step, per its header -- no separate CandidateFromStoredRecord exists because neither
-- schema carries a Roblox-specific value type).

local function baseTrait(overrides: { [string]: any }?): { [string]: any }
	local trait: { [string]: any } = {
		TraitId = "human-resolve",
		RaceId = "Human",
		RequiredTier = 3,
		Ability = {
			Id = "human-resolve-ability",
			DisplayName = "Steadfast Resolve",
			Description = "A calm, unshakeable will.",
			Kind = "Passive",
			CooldownSeconds = 0,
			QiCost = 0,
			Effects = {
				{ Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Fortitude", Delta = 5 },
				{ Kind = "Tag", Lifetime = "Bound", Tag = "Steadfast", Magnitude = 1 },
			},
		},
	}
	if overrides then
		for key, value in overrides do
			trait[key] = value
		end
	end
	return trait
end

local function baseBloodline(overrides: { [string]: any }?): { [string]: any }
	local bloodline: { [string]: any } = {
		BloodlineId = "ashen-current",
		DisplayName = "Ashen Current",
		RarityTier = "Rare",
		FlavorText = "A bloodline said to run cold even in the heat of battle.",
		NativeRaceId = "Hollowborn",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = 10, RequiresAscended = 1 } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "First Chill",
				PassiveEffects = {
					{ Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Fortitude", Delta = 3 },
				},
			},
			{
				StageIndex = 2,
				DisplayName = "Deepening Frost",
				PassiveEffects = {},
				GrantedAbility = {
					Id = "ashen-current-strike",
					DisplayName = "Ashen Strike",
					Description = "A sudden burst of cold.",
					Kind = "Active",
					CooldownSeconds = 12,
					QiCost = 20,
					Effects = {
						{ Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 10 },
						{ Kind = "Tag", Lifetime = "Timed", Tag = "Chilled", Magnitude = 2, DurationSeconds = 6 },
					},
				},
			},
		},
	}
	if overrides then
		for key, value in overrides do
			bloodline[key] = value
		end
	end
	return bloodline
end

return function()
	describe("KitEditorSystem.EncodeRaceTraitRecord", function()
		it("writes every top-level field", function()
			local validated = RaceManager.Validate(baseTrait()) :: any
			local record = KitEditorSystem.EncodeRaceTraitRecord(validated)

			expect(record.TraitId).to.equal("human-resolve")
			expect(record.RaceId).to.equal("Human")
			expect(record.RequiredTier).to.equal(3)
			expect(record.Ability).never.to.equal(nil)
		end)

		it("writes every Ability field, including a multi-effect Effects list", function()
			local validated = RaceManager.Validate(baseTrait()) :: any
			local record = KitEditorSystem.EncodeRaceTraitRecord(validated)

			expect(record.Ability.Id).to.equal("human-resolve-ability")
			expect(record.Ability.DisplayName).to.equal("Steadfast Resolve")
			expect(record.Ability.Description).to.equal("A calm, unshakeable will.")
			expect(record.Ability.Kind).to.equal("Passive")
			expect(#record.Ability.Effects).to.equal(2)
			expect(record.Ability.Effects[1].AttributeKey).to.equal("Fortitude")
			expect(record.Ability.Effects[1].Delta).to.equal(5)
			expect(record.Ability.Effects[2].Tag).to.equal("Steadfast")
			expect(record.Ability.Effects[2].Magnitude).to.equal(1)
		end)

		it("round-trips a full trait back through RaceManager.Validate with nothing lost", function()
			local validated = RaceManager.Validate(baseTrait()) :: any
			local record = KitEditorSystem.EncodeRaceTraitRecord(validated)
			local roundTripped, reason = RaceManager.Validate(record)

			expect(roundTripped).to.be.ok()
			local trait = roundTripped :: any
			expect(reason).to.equal(nil)
			expect(trait.TraitId).to.equal(validated.TraitId)
			expect(trait.RaceId).to.equal(validated.RaceId)
			expect(trait.RequiredTier).to.equal(validated.RequiredTier)
			expect(trait.Ability.Id).to.equal(validated.Ability.Id)
			expect(#trait.Ability.Effects).to.equal(#validated.Ability.Effects)
			expect(trait.Ability.Effects[1].Delta).to.equal(validated.Ability.Effects[1].Delta)
		end)

		it("round-trips a Timed effect's DurationSeconds", function()
			local candidate = baseTrait()
			candidate.Ability.Kind = "Active"
			candidate.Ability.Effects =
				{ { Kind = "Tag", Lifetime = "Timed", Tag = "X", Magnitude = 1, DurationSeconds = 15 } }
			local validated = RaceManager.Validate(candidate) :: any
			local record = KitEditorSystem.EncodeRaceTraitRecord(validated)

			expect(record.Ability.Effects[1].DurationSeconds).to.equal(15)
			local roundTripped = RaceManager.Validate(record) :: any
			expect(roundTripped.Ability.Effects[1].DurationSeconds).to.equal(15)
		end)
	end)

	describe("KitEditorSystem.EncodeBloodlineRecord", function()
		it("writes every top-level field, including NativeRaceId", function()
			local validated = BloodlineManager.Validate(baseBloodline()) :: any
			local record = KitEditorSystem.EncodeBloodlineRecord(validated)

			expect(record.BloodlineId).to.equal("ashen-current")
			expect(record.DisplayName).to.equal("Ashen Current")
			expect(record.RarityTier).to.equal("Rare")
			expect(record.FlavorText).to.equal("A bloodline said to run cold even in the heat of battle.")
			expect(record.NativeRaceId).to.equal("Hollowborn")
		end)

		it("omits NativeRaceId for a bloodline obtainable by any race", function()
			-- NOT baseBloodline({ NativeRaceId = nil }) -- a nil-valued key inside a table
			-- CONSTRUCTOR is simply absent, so that override would silently no-op and leave the
			-- base candidate's own "Hollowborn" in place. An explicit assignment after construction
			-- is what actually clears the key.
			local candidate = baseBloodline()
			candidate.NativeRaceId = nil
			local validated = BloodlineManager.Validate(candidate) :: any
			local record = KitEditorSystem.EncodeBloodlineRecord(validated)
			expect(record.NativeRaceId).to.equal(nil)
		end)

		it("writes AwakeningCondition.Kind and every Params entry", function()
			local validated = BloodlineManager.Validate(baseBloodline()) :: any
			local record = KitEditorSystem.EncodeBloodlineRecord(validated)

			expect(record.AwakeningCondition.Kind).to.equal("OnPlayerKilled")
			expect(record.AwakeningCondition.Params.RequiredKills).to.equal(10)
			expect(record.AwakeningCondition.Params.RequiresAscended).to.equal(1)
		end)

		it("writes every Stage, including a stage with no GrantedAbility and one with one", function()
			local validated = BloodlineManager.Validate(baseBloodline()) :: any
			local record = KitEditorSystem.EncodeBloodlineRecord(validated)

			expect(#record.Stages).to.equal(2)
			expect(record.Stages[1].StageIndex).to.equal(1)
			expect(record.Stages[1].GrantedAbility).to.equal(nil)
			expect(#record.Stages[1].PassiveEffects).to.equal(1)

			expect(record.Stages[2].StageIndex).to.equal(2)
			expect(record.Stages[2].GrantedAbility).never.to.equal(nil)
			expect(record.Stages[2].GrantedAbility.Id).to.equal("ashen-current-strike")
			expect(record.Stages[2].GrantedAbility.Kind).to.equal("Active")
			expect(#record.Stages[2].GrantedAbility.Effects).to.equal(2)
			expect(record.Stages[2].GrantedAbility.Effects[2].DurationSeconds).to.equal(6)
		end)

		it("round-trips a full bloodline back through BloodlineManager.Validate with nothing lost", function()
			local validated = BloodlineManager.Validate(baseBloodline()) :: any
			local record = KitEditorSystem.EncodeBloodlineRecord(validated)
			local roundTripped, reason = BloodlineManager.Validate(record)

			expect(roundTripped).to.be.ok()
			local bloodline = roundTripped :: any
			expect(reason).to.equal(nil)
			expect(bloodline.BloodlineId).to.equal(validated.BloodlineId)
			expect(bloodline.NativeRaceId).to.equal(validated.NativeRaceId)
			expect(bloodline.AwakeningCondition.Params.RequiredKills).to.equal(
				validated.AwakeningCondition.Params.RequiredKills
			)
			expect(#bloodline.Stages).to.equal(#validated.Stages)
			expect(bloodline.Stages[2].GrantedAbility.Id).to.equal(validated.Stages[2].GrantedAbility.Id)
			expect(#bloodline.Stages[2].GrantedAbility.Effects).to.equal(#validated.Stages[2].GrantedAbility.Effects)
		end)
	end)
end
