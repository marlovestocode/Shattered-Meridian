--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local BloodlineSystem = require(ServerScriptService.Server.Systems.BloodlineSystem)
local BloodlineManager = require(ServerScriptService.Server.Managers.BloodlineManager)

-- BloodlineSystem.Init() is never called here -- it subscribes to PlayerDataSystem/GameplayEvents,
-- neither of which this file needs. The per-player surface (HasAwakened, GetStage, CanUseAbility,
-- UseAbility, Awaken, AdvanceStage) is exercised only on its no-profile path, the same Studio/
-- live-server-only gap RaceSystem.spec.lua's own header documents for the identically-shaped
-- RaceSystem.CanUseAbility/UseAbility: a real awakening/advancement needs PlayerDataSystem's
-- DataStore-backed load flow for a live Player.
--
-- What IS fully exercised here is BloodlineSystem's own early-exit gates that resolve BEFORE a
-- profile is ever read (UnknownBloodline) and the ones that resolve off GetStage's own safe-zero
-- fallback (NotAwakened) -- both pure, registry-driven decisions, no Player needed.

local function upsertBloodline(overrides: { [string]: any }?): any
	local candidate: { [string]: any } = {
		BloodlineId = "ashen-current",
		DisplayName = "Ashen Current",
		RarityTier = "Rare",
		FlavorText = "",
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
	local validated, reason = BloodlineManager.Validate(candidate)
	if not validated then
		error(`Validate rejected: {tostring(reason)}`)
	end
	BloodlineManager.Upsert(validated)
	return validated
end

return function()
	describe("BloodlineSystem (no profile loaded)", function()
		it("HasAwakened is false for a player with no loaded profile", function()
			BloodlineManager.Init()
			upsertBloodline()
			expect(BloodlineSystem.HasAwakened({} :: any, "ashen-current")).to.equal(false)
		end)

		it("GetStage is 0 for a player with no loaded profile", function()
			BloodlineManager.Init()
			upsertBloodline()
			expect(BloodlineSystem.GetStage({} :: any, "ashen-current")).to.equal(0)
		end)

		it("CanUseAbility/UseAbility report UnknownBloodline for an unregistered BloodlineId", function()
			BloodlineManager.Init()
			expect(BloodlineSystem.CanUseAbility({} :: any, "nothing-here", "any-ability")).to.equal("UnknownBloodline")
			expect(BloodlineSystem.UseAbility({} :: any, "nothing-here", "any-ability")).to.equal("UnknownBloodline")
		end)

		it("CanUseAbility/UseAbility report NotAwakened for a known bloodline with no loaded profile", function()
			BloodlineManager.Init()
			upsertBloodline()
			expect(BloodlineSystem.CanUseAbility({} :: any, "ashen-current", "any-ability")).to.equal("NotAwakened")
			expect(BloodlineSystem.UseAbility({} :: any, "ashen-current", "any-ability")).to.equal("NotAwakened")
		end)

		it("Awaken reports ProfileNotLoaded for a player with no loaded profile", function()
			BloodlineManager.Init()
			upsertBloodline()
			expect(BloodlineSystem.Awaken({} :: any, "ashen-current", "Test")).to.equal("ProfileNotLoaded")
		end)

		it("Awaken reports UnknownBloodline for an unregistered BloodlineId", function()
			BloodlineManager.Init()
			expect(BloodlineSystem.Awaken({} :: any, "nothing-here", "Test")).to.equal("UnknownBloodline")
		end)

		it("AdvanceStage reports NotAwakened for a player with no loaded profile", function()
			BloodlineManager.Init()
			upsertBloodline()
			expect(BloodlineSystem.AdvanceStage({} :: any, "ashen-current")).to.equal("NotAwakened")
		end)

		it("AdvanceStage reports UnknownBloodline for an unregistered BloodlineId", function()
			BloodlineManager.Init()
			expect(BloodlineSystem.AdvanceStage({} :: any, "nothing-here")).to.equal("UnknownBloodline")
		end)
	end)

	-- DrawWeighted is the whole reason the spin's randomness is split from Spin itself: the odds are
	-- the part that can be silently wrong, and they are testable with no Player, no profile and no
	-- DataStore because the [0, 1) sample is injected rather than taken from math.random inside.
	describe("BloodlineSystem.DrawWeighted", function()
		-- Weights come from BloodlineConstants.RarityWeights: Common 100, Rare 18, Ascendant 1.
		local function candidate(bloodlineId: string, rarityTier: string): any
			return { BloodlineId = bloodlineId, RarityTier = rarityTier } :: any
		end

		it("returns nil for an empty candidate list", function()
			expect(BloodlineSystem.DrawWeighted({}, 0.5)).to.equal(nil)
		end)

		it("always returns the only candidate, whatever the roll", function()
			local only = candidate("solo", "Ascendant")
			expect(BloodlineSystem.DrawWeighted({ only }, 0).BloodlineId).to.equal("solo")
			expect(BloodlineSystem.DrawWeighted({ only }, 0.999).BloodlineId).to.equal("solo")
		end)

		-- Common 100 vs Ascendant 1: the first 100/101 of the range is the common one.
		it("lands on the heavier candidate across the bulk of the range", function()
			local pool = { candidate("common", "Common"), candidate("ascendant", "Ascendant") }
			expect(BloodlineSystem.DrawWeighted(pool, 0).BloodlineId).to.equal("common")
			expect(BloodlineSystem.DrawWeighted(pool, 0.5).BloodlineId).to.equal("common")
			expect(BloodlineSystem.DrawWeighted(pool, 0.98).BloodlineId).to.equal("common")
		end)

		it("still reaches the rarest candidate at the top of the range", function()
			local pool = { candidate("common", "Common"), candidate("ascendant", "Ascendant") }
			expect(BloodlineSystem.DrawWeighted(pool, 0.999).BloodlineId).to.equal("ascendant")
		end)

		-- The rounding tail the final `or` in DrawWeighted exists for: a roll of exactly 1 sits a hair
		-- past the accumulated total, and must still draw something rather than reading as "nothing
		-- eligible" to the caller.
		it("draws something at a roll of exactly 1", function()
			local pool = { candidate("a", "Common"), candidate("b", "Rare") }
			expect(BloodlineSystem.DrawWeighted(pool, 1)).to.be.ok()
		end)

		-- RarityTier is free-form by contract, so an unheard-of tier must draw at DefaultWeight rather
		-- than being silently excluded from the pool -- see BloodlineConstants' own header.
		it("includes a candidate whose RarityTier has no authored weight", function()
			local pool = { candidate("mystery", "NotATierAnyoneDefined") }
			expect(BloodlineSystem.DrawWeighted(pool, 0.5).BloodlineId).to.equal("mystery")
		end)
	end)
end
