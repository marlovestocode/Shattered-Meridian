--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RaceManager = require(ServerScriptService.Server.Managers.RaceManager)
local Constants = require(ReplicatedStorage.Shared.Constants)

local KitLimits = Constants.Kit.Limits

local function baseCandidate(overrides: { [string]: any }?): { [string]: any }
	local candidate: { [string]: any } = {
		TraitId = "human-resolve",
		RaceId = "Human",
		RequiredTier = 1,
		Ability = {
			Id = "human-resolve-ability",
			DisplayName = "Steadfast Resolve",
			Description = "A calm, unshakeable will.",
			Kind = "Passive",
			CooldownSeconds = 0,
			QiCost = 0,
			Effects = {
				{ Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Fortitude", Delta = 5 },
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
	local validated, reason = RaceManager.Validate(baseCandidate(overrides))
	if not validated then
		error(`Validate rejected: {tostring(reason)}`)
	end
	RaceManager.Upsert(validated)
	return validated
end

-- RaceManager owns a single shared, module-level `traits` table (no per-instance registry object --
-- see its own header) -- Init() resets it to empty so each test starts from a known-clean slate, the
-- same discipline MoveRegistryManager.spec.lua's own reset() already establishes for its identically-
-- shaped module-level state.
local function reset(): ()
	RaceManager.Init()
end

return function()
	describe("RaceManager.Validate -- structural rejects", function()
		it("rejects a non-table candidate", function()
			local validated, reason = RaceManager.Validate("not-a-table")
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidShape")
		end)

		it("rejects an empty TraitId", function()
			local validated, reason = RaceManager.Validate(baseCandidate({ TraitId = "" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidTraitId")
		end)

		it("rejects a RaceId outside the four fixed races", function()
			local validated, reason = RaceManager.Validate(baseCandidate({ RaceId = "NotARace" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidRaceId")
		end)

		it("accepts every one of the four fixed races", function()
			for _, raceId in { "Human", "Firmborn", "Rivenkin", "Hollowborn" } do
				local validated = RaceManager.Validate(baseCandidate({ RaceId = raceId, TraitId = raceId .. "-trait" }))
				expect(validated).to.be.ok()
			end
		end)

		it("rejects a missing/non-table Ability", function()
			local validated, reason = RaceManager.Validate(baseCandidate({ Ability = "not-a-table" }))
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAbility")
		end)

		it("rejects an Ability with an empty Id", function()
			local candidate = baseCandidate()
			candidate.Ability.Id = ""
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAbilityId")
		end)

		it("rejects an Ability Kind outside Passive/Active", function()
			local candidate = baseCandidate()
			candidate.Ability.Kind = "Ultimate"
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAbilityKind")
		end)

		it("rejects an Ability with a missing CooldownSeconds/QiCost", function()
			local candidate = baseCandidate()
			candidate.Ability.CooldownSeconds = nil
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidAbilityCost")
		end)

		it("rejects a non-table Effects list", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = "not-a-table"
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffects")
		end)
	end)

	describe("RaceManager.Validate -- effect-specific structural rejects", function()
		it("rejects an effect Kind outside AttributeDelta/Tag/QiRestore", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "NotAKind", Lifetime = "Bound" } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectKind")
		end)

		it("rejects an effect Lifetime outside Instant/Timed/Bound", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "Tag", Lifetime = "Forever", Tag = "X", Magnitude = 1 } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectLifetime")
		end)

		it("rejects an AttributeDelta effect with no AttributeKey", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "AttributeDelta", Lifetime = "Bound", Delta = 5 } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectAttributeKey")
		end)

		it("rejects an AttributeDelta effect naming an unknown attribute", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects =
				{ { Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Luck", Delta = 5 } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectAttributeKey")
		end)

		it("rejects a Tag effect with an empty Tag", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "Tag", Lifetime = "Bound", Tag = "", Magnitude = 1 } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectTag")
		end)

		it("rejects a QiRestore effect with no QiRestoreAmount", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "QiRestore", Lifetime = "Instant" } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectQiRestoreAmount")
		end)

		it("rejects a Timed effect with no DurationSeconds", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "Tag", Lifetime = "Timed", Tag = "X", Magnitude = 1 } }
			local validated, reason = RaceManager.Validate(candidate)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidEffectDuration")
		end)

		it("accepts a Bound Tag effect with no DurationSeconds required", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects = { { Kind = "Tag", Lifetime = "Bound", Tag = "X", Magnitude = 1 } }
			local validated = RaceManager.Validate(candidate)
			expect(validated).to.be.ok()
		end)

		it("accepts a well-formed QiRestore Instant effect", function()
			local candidate = baseCandidate()
			candidate.Ability.Kind = "Active"
			candidate.Ability.Effects = { { Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 25 } }
			local validated = RaceManager.Validate(candidate)
			expect(validated).to.be.ok()
			expect((validated :: any).Ability.Effects[1].QiRestoreAmount).to.equal(25)
		end)
	end)

	describe("RaceManager.Validate -- clamping", function()
		it("clamps RequiredTier into Constants.Kit.Limits.RequiredTier and floors it", function()
			local validated = RaceManager.Validate(baseCandidate({ RequiredTier = 999.7 }))
			expect((validated :: any).RequiredTier).to.equal(KitLimits.RequiredTier.Max)
		end)

		it("clamps a below-range RequiredTier up to the floor", function()
			local validated = RaceManager.Validate(baseCandidate({ RequiredTier = -50 }))
			expect((validated :: any).RequiredTier).to.equal(KitLimits.RequiredTier.Min)
		end)

		it("clamps Ability.QiCost/CooldownSeconds into their own limits", function()
			local candidate = baseCandidate()
			candidate.Ability.QiCost = 99999
			candidate.Ability.CooldownSeconds = -10
			local validated = RaceManager.Validate(candidate)
			expect((validated :: any).Ability.QiCost).to.equal(KitLimits.QiCost.Max)
			expect((validated :: any).Ability.CooldownSeconds).to.equal(KitLimits.CooldownSeconds.Min)
		end)

		it("clamps an AttributeDelta effect's Delta into range", function()
			local candidate = baseCandidate()
			candidate.Ability.Effects =
				{ { Kind = "AttributeDelta", Lifetime = "Bound", AttributeKey = "Might", Delta = 99999 } }
			local validated = RaceManager.Validate(candidate)
			expect((validated :: any).Ability.Effects[1].Delta).to.equal(KitLimits.Delta.Max)
		end)
	end)

	describe("RaceManager round trip", function()
		it("List returns nothing before any Upsert", function()
			reset()
			expect(#RaceManager.List()).to.equal(0)
		end)

		it("Upsert then Get returns the same trait by TraitId", function()
			reset()
			upsert()
			local fetched = RaceManager.Get("human-resolve")
			expect(fetched).to.be.ok()
			expect((fetched :: any).Ability.DisplayName).to.equal("Steadfast Resolve")
		end)

		it("Get returns nil for an unknown TraitId", function()
			reset()
			expect(RaceManager.Get("does-not-exist")).to.equal(nil)
		end)

		it("List reflects every Upserted trait", function()
			reset()
			upsert({ TraitId = "trait-a" })
			upsert({ TraitId = "trait-b" })
			expect(#RaceManager.List()).to.equal(2)
		end)

		it("Upsert with the same TraitId replaces, not appends", function()
			reset()
			upsert()
			local candidate = baseCandidate()
			candidate.Ability.DisplayName = "Renamed"
			local validated = RaceManager.Validate(candidate) :: any
			RaceManager.Upsert(validated)
			expect(#RaceManager.List()).to.equal(1)
			expect((RaceManager.Get("human-resolve") :: any).Ability.DisplayName).to.equal("Renamed")
		end)

		it("Delete removes a trait so Get returns nil afterward", function()
			reset()
			upsert()
			RaceManager.Delete("human-resolve")
			expect(RaceManager.Get("human-resolve")).to.equal(nil)
			expect(#RaceManager.List()).to.equal(0)
		end)

		it("Get/List return copies, not the live table -- mutating one never corrupts the registry", function()
			reset()
			upsert()
			local fetched = RaceManager.Get("human-resolve") :: any
			fetched.Ability.Effects[1].Delta = 999
			table.insert(fetched.Ability.Effects, { Kind = "Tag", Lifetime = "Bound", Tag = "Injected", Magnitude = 1 })

			local fresh = RaceManager.Get("human-resolve") :: any
			expect(fresh.Ability.Effects[1].Delta).to.equal(5)
			expect(#fresh.Ability.Effects).to.equal(1)
		end)
	end)

	describe("RaceManager.GetTraitsForRace", function()
		it("returns only traits for the given race", function()
			reset()
			upsert({ TraitId = "human-a", RaceId = "Human" })
			upsert({ TraitId = "firmborn-a", RaceId = "Firmborn" })

			local humanTraits = RaceManager.GetTraitsForRace("Human")
			expect(#humanTraits).to.equal(1)
			expect(humanTraits[1].TraitId).to.equal("human-a")
		end)

		it("returns an empty list for a race with nothing authored", function()
			reset()
			expect(#RaceManager.GetTraitsForRace("Rivenkin")).to.equal(0)
		end)

		it("orders by RequiredTier ascending, then TraitId for a tie", function()
			reset()
			upsert({ TraitId = "z-tier2", RaceId = "Human", RequiredTier = 2 })
			upsert({ TraitId = "a-tier1-b", RaceId = "Human", RequiredTier = 1 })
			upsert({ TraitId = "a-tier1-a", RaceId = "Human", RequiredTier = 1 })

			local ordered = RaceManager.GetTraitsForRace("Human")
			expect(#ordered).to.equal(3)
			expect(ordered[1].TraitId).to.equal("a-tier1-a")
			expect(ordered[2].TraitId).to.equal("a-tier1-b")
			expect(ordered[3].TraitId).to.equal("z-tier2")
		end)
	end)
end
