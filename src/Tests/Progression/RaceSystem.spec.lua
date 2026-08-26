--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local RaceSystem = require(ServerScriptService.Server.Systems.RaceSystem)
local RaceManager = require(ServerScriptService.Server.Managers.RaceManager)

-- RaceSystem.Init() is never called here -- it subscribes to PlayerDataSystem/GameplayEvents, neither
-- of which this file needs. The per-player surface (GetEligibleTraits, CanUseAbility, UseAbility) is
-- exercised only on its no-profile path, the same Studio/live-server-only gap ArtSystem.spec.lua's
-- own header documents for the identically-shaped ArtSystem.CanUnlock/Unlock/UseArt: a real
-- eligibility check needs PlayerDataSystem's DataStore-backed load flow for a live Player.
--
-- What IS fully exercised here is RaceSystem's own early-exit gates that resolve BEFORE a profile is
-- ever read (UnknownTrait, NotActive) -- those are pure, registry-driven decisions, no Player needed.

local function upsertTrait(overrides: { [string]: any }?): any
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
	local validated, reason = RaceManager.Validate(candidate)
	if not validated then
		error(`Validate rejected: {tostring(reason)}`)
	end
	RaceManager.Upsert(validated)
	return validated
end

return function()
	describe("RaceSystem (no profile loaded)", function()
		it("GetEligibleTraits is empty for a player with no loaded profile", function()
			RaceManager.Init()
			expect(#RaceSystem.GetEligibleTraits({} :: any)).to.equal(0)
		end)

		it("CanUseAbility reports UnknownTrait for a TraitId the registry has never seen", function()
			RaceManager.Init()
			expect(RaceSystem.CanUseAbility({} :: any, "nothing-here")).to.equal("UnknownTrait")
		end)

		it("UseAbility reports UnknownTrait for a TraitId the registry has never seen", function()
			RaceManager.Init()
			expect(RaceSystem.UseAbility({} :: any, "nothing-here")).to.equal("UnknownTrait")
		end)

		it("CanUseAbility/UseAbility refuse a Passive-kind trait's ability with NotActive", function()
			RaceManager.Init()
			local trait = upsertTrait()
			expect(trait.Ability.Kind).to.equal("Passive")

			expect(RaceSystem.CanUseAbility({} :: any, "human-resolve")).to.equal("NotActive")
			expect(RaceSystem.UseAbility({} :: any, "human-resolve")).to.equal("NotActive")
		end)

		it("CanUseAbility/UseAbility refuse an Active trait's ability with ProfileNotLoaded", function()
			RaceManager.Init()
			local candidate = {
				TraitId = "human-focus",
				RaceId = "Human",
				RequiredTier = 1,
				Ability = {
					Id = "human-focus-ability",
					DisplayName = "Focused Strike",
					Description = "",
					Kind = "Active",
					CooldownSeconds = 5,
					QiCost = 10,
					Effects = { { Kind = "QiRestore", Lifetime = "Instant", QiRestoreAmount = 10 } },
				},
			}
			local validated = RaceManager.Validate(candidate)
			RaceManager.Upsert(validated :: any)

			expect(RaceSystem.CanUseAbility({} :: any, "human-focus")).to.equal("ProfileNotLoaded")
			expect(RaceSystem.UseAbility({} :: any, "human-focus")).to.equal("ProfileNotLoaded")
		end)
	end)
end
