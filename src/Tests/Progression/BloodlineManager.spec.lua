--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager)

local function baseCandidate(overrides: { [string]: any }?): { [string]: any }
	local candidate: { [string]: any } = {
		BloodlineId = "ashen-current",
		DisplayName = "Ashen Current",
		RarityTier = "Rare",
		FlavorText = "A bloodline said to run cold even in the heat of battle.",
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = 10 } },
		Stages = {
			{
				StageIndex = 1,
				DisplayName = "First Chill",
				PassiveEffects = {
					{ Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Fortitude", Delta = 3 },
				},
			},
		},
	}
	if overrides then
		for key, value in overrides do
			candidate[key] = value
		end
	end
	return candidate
end

local function upsert(overrides: { [string]: any }?): any
	local validated, reason = BloodlineManager.Validate(baseCandidate(overrides))
	if not validated then
		error(`Validate rejected: {tostring(reason)}`)
	end
	BloodlineManager.Upsert(validated)
	return validated
end

-- BloodlineManager owns a single shared, module-level `bloodlines` table -- Init() resets it to
-- empty so each test starts from a known-clean slate, the same discipline RaceManager.spec.lua's own
-- reset() already establishes for its identically-shaped module-level state.
local function reset(): ()
	BloodlineManager.Init()
end

return function()
	describe("BloodlineManager.Validate -- structural rejects", function()
		it("rejects a non-table candidate", function()
			local validated, reason = BloodlineManager.Validate("not-a-table")
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidShape")
		end)

		it("rejects an empty BloodlineId", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({ BloodlineId = "" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidBloodlineId")
		end)

		it("rejects a NativeRaceId outside the four fixed races", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({ NativeRaceId = "NotARace" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidNativeRaceId")
		end)

		it("accepts a nil NativeRaceId -- obtainable by any race", function()
			local validated = BloodlineManager.Validate(baseCandidate())
			expect(validated).to.be.ok()
			expect((validated :: any).NativeRaceId).to.equal(nil)
		end)

		it("accepts a valid NativeRaceId", function()
			local validated = BloodlineManager.Validate(baseCandidate({ NativeRaceId = "Hollowborn" }))
			expect(validated).to.be.ok()
			expect((validated :: any).NativeRaceId).to.equal("Hollowborn")
		end)

		it("rejects a missing/non-table AwakeningCondition", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({ AwakeningCondition = "not-a-table" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAwakeningCondition")
		end)

		it("rejects an AwakeningCondition with an empty Kind", function()
			local validated, reason =
				BloodlineManager.Validate(baseCandidate({ AwakeningCondition = { Kind = "", Params = {} } }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAwakeningConditionKind")
		end)

		it("accepts an open-string Kind -- not a closed union", function()
			-- BloodlineAwakeningCondition.Kind is deliberately open (Types.lua/BloodlineTypes.lua's own
			-- header) -- any non-empty string is structurally valid, even one this pass never triggers on.
			local validated = BloodlineManager.Validate(baseCandidate({
				AwakeningCondition = { Kind = "SomeFutureTrigger", Params = { Whatever = 5 } },
			}))
			expect(validated).to.be.ok()
			expect((validated :: any).AwakeningCondition.Kind).to.equal("SomeFutureTrigger")
		end)

		it("drops a malformed Params entry rather than rejecting the whole condition", function()
			local validated = BloodlineManager.Validate(baseCandidate({
				AwakeningCondition = {
					Kind = "OnPlayerKilled",
					Params = { RequiredKills = 10, BadEntry = "not-a-number", [42] = 1 },
				},
			}))
			expect(validated).to.be.ok()
			local params = (validated :: any).AwakeningCondition.Params
			expect(params.RequiredKills).to.equal(10)
			expect(params.BadEntry).to.equal(nil)
		end)

		it("rejects a non-table Stages list", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({ Stages = "not-a-table" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidStages")
		end)

		it("rejects a stage with a missing StageIndex", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({
				Stages = { { DisplayName = "No Index", PassiveEffects = {} } },
			}))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidStageIndex")
		end)

		it("rejects a stage with a non-table PassiveEffects", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({
				Stages = { { StageIndex = 1, DisplayName = "X", PassiveEffects = "not-a-table" } },
			}))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffects")
		end)

		it("accepts a stage with no GrantedAbility -- a pure stat-passive stage", function()
			local validated = BloodlineManager.Validate(baseCandidate())
			expect(validated).to.be.ok()
			expect((validated :: any).Stages[1].GrantedAbility).to.equal(nil)
		end)

		it("rejects a stage whose GrantedAbility fails KitValidation", function()
			local validated, reason = BloodlineManager.Validate(baseCandidate({
				Stages = {
					{
						StageIndex = 1,
						DisplayName = "X",
						PassiveEffects = {},
						GrantedAbility = {
							Id = "",
							DisplayName = "Bad",
							Kind = "Active",
							CooldownSeconds = 0,
							QiCost = 0,
							Effects = {},
						},
					},
				},
			}))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAbilityId")
		end)

		it("accepts a well-formed stage with an Active GrantedAbility", function()
			local validated = BloodlineManager.Validate(baseCandidate({
				Stages = {
					{
						StageIndex = 1,
						DisplayName = "X",
						PassiveEffects = {},
						GrantedAbility = {
							Id = "ashen-current-strike",
							DisplayName = "Ashen Strike",
							Description = "",
							Kind = "Active",
							CooldownSeconds = 10,
							QiCost = 15,
							Effects = { { Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 5 } },
						},
					},
				},
			}))
			expect(validated).to.be.ok()
			expect((validated :: any).Stages[1].GrantedAbility.Id).to.equal("ashen-current-strike")
		end)
	end)

	describe("BloodlineManager.Validate -- clamping", function()
		it("clamps a stage's StageIndex into Constants.Kit.Limits.StageIndex and floors it", function()
			local Constants = require(game:GetService("ReplicatedStorage").Shared.Constants)
			local validated = BloodlineManager.Validate(baseCandidate({
				Stages = { { StageIndex = 999.6, DisplayName = "X", PassiveEffects = {} } },
			}))
			expect((validated :: any).Stages[1].StageIndex).to.equal(Constants.Kit.Limits.StageIndex.Max)
		end)
	end)

	describe("BloodlineManager round trip", function()
		it("List returns nothing before any Upsert", function()
			reset()
			expect(#BloodlineManager.List()).to.equal(0)
		end)

		it("Upsert then Get returns the same bloodline by BloodlineId", function()
			reset()
			upsert()
			local fetched = BloodlineManager.Get("ashen-current")
			expect(fetched).to.be.ok()
			expect((fetched :: any).DisplayName).to.equal("Ashen Current")
		end)

		it("Get returns nil for an unknown BloodlineId", function()
			reset()
			expect(BloodlineManager.Get("does-not-exist")).to.equal(nil)
		end)

		it("List reflects every Upserted bloodline", function()
			reset()
			upsert({ BloodlineId = "bloodline-a" })
			upsert({ BloodlineId = "bloodline-b" })
			expect(#BloodlineManager.List()).to.equal(2)
		end)

		it("Upsert with the same BloodlineId replaces, not appends", function()
			reset()
			upsert()
			local candidate = baseCandidate()
			candidate.DisplayName = "Renamed"
			local validated = BloodlineManager.Validate(candidate) :: any
			BloodlineManager.Upsert(validated)
			expect(#BloodlineManager.List()).to.equal(1)
			expect((BloodlineManager.Get("ashen-current") :: any).DisplayName).to.equal("Renamed")
		end)

		it("Delete removes a bloodline so Get returns nil afterward", function()
			reset()
			upsert()
			BloodlineManager.Delete("ashen-current")
			expect(BloodlineManager.Get("ashen-current")).to.equal(nil)
			expect(#BloodlineManager.List()).to.equal(0)
		end)

		it("Get/List return copies, not the live table -- mutating one never corrupts the registry", function()
			reset()
			upsert()
			local fetched = BloodlineManager.Get("ashen-current") :: any
			fetched.Stages[1].PassiveEffects[1].Delta = 999
			table.insert(fetched.Stages, { StageIndex = 2, DisplayName = "Injected", PassiveEffects = {} })
			fetched.AwakeningCondition.Params.RequiredKills = 999

			local fresh = BloodlineManager.Get("ashen-current") :: any
			expect(fresh.Stages[1].PassiveEffects[1].Delta).to.equal(3)
			expect(#fresh.Stages).to.equal(1)
			expect(fresh.AwakeningCondition.Params.RequiredKills).to.equal(10)
		end)
	end)

	describe("BloodlineManager.AuditStages", function()
		it("returns no problems for a contiguous, non-duplicated stage list", function()
			reset()
			upsert({
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 2, DisplayName = "B", PassiveEffects = {} },
					{ StageIndex = 3, DisplayName = "C", PassiveEffects = {} },
				},
			})
			expect(#BloodlineManager.AuditStages("ashen-current")).to.equal(0)
		end)

		it("flags a gap in the stage ladder", function()
			reset()
			upsert({
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 3, DisplayName = "C", PassiveEffects = {} },
				},
			})
			local problems = BloodlineManager.AuditStages("ashen-current")
			expect(#problems).to.equal(1)
		end)

		it("flags a duplicate StageIndex", function()
			reset()
			upsert({
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 1, DisplayName = "A-again", PassiveEffects = {} },
				},
			})
			local problems = BloodlineManager.AuditStages("ashen-current")
			expect(#problems).to.equal(1)
		end)

		it("returns {} for an unknown BloodlineId", function()
			reset()
			expect(#BloodlineManager.AuditStages("does-not-exist")).to.equal(0)
		end)
	end)

	-- AuditAll is what a POST-LOAD caller uses: KitEditorSystem has just replayed N persisted records
	-- back through Validate/Upsert and wants to know whether any of them are bad, without knowing
	-- their ids. It exists because the audit that used to run in BloodlineManager.Init could only ever
	-- see an empty registry -- that Manager boots long before the records load -- so it logged clean
	-- every boot, which reads like a check that passed rather than one that never ran.
	describe("BloodlineManager.AuditAll", function()
		it("returns nothing for an empty registry", function()
			reset()
			expect(#BloodlineManager.AuditAll()).to.equal(0)
		end)

		it("returns nothing when every bloodline is well-formed", function()
			reset()
			upsert({
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 2, DisplayName = "B", PassiveEffects = {} },
				},
			})
			expect(#BloodlineManager.AuditAll()).to.equal(0)
		end)

		it("surfaces a problem without being told which bloodline to look at", function()
			reset()
			upsert({
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 3, DisplayName = "C", PassiveEffects = {} },
				},
			})
			expect(#BloodlineManager.AuditAll()).to.equal(1)
		end)

		-- The whole point of aggregating: two bad records must both be reported, not just whichever the
		-- caller happened to ask about.
		it("aggregates problems across every bloodline in the registry", function()
			reset()
			upsert({
				BloodlineId = "ashen-current",
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 3, DisplayName = "C", PassiveEffects = {} },
				},
			})
			upsert({
				BloodlineId = "second-line",
				Stages = {
					{ StageIndex = 1, DisplayName = "A", PassiveEffects = {} },
					{ StageIndex = 1, DisplayName = "A-again", PassiveEffects = {} },
				},
			})
			expect(#BloodlineManager.AuditAll()).to.equal(2)
		end)
	end)
end
