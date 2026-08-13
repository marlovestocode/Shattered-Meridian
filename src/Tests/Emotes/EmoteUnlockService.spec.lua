--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local EmoteUnlockService = require(ServerScriptService.Server.Systems.EmoteUnlockService)

-- EmoteUnlockService.Init() is never called in this spec file -- it subscribes to
-- PlayerDataSystem.OnProfileLoaded, which needs no live wiring for the pure/no-profile surface
-- below. The Player-keyed wrappers (HasUnlocked/GetUnlockedIds/GrantEmote/RollEmote) are exercised
-- only against the "profile never loaded" fallback path (a plain table standing in for Player) --
-- a genuinely loaded profile requires PlayerDataSystem's real DataStore-backed load flow for a live
-- Player, the same already-accepted gap MeridianSystem.spec.lua/PlayerDataSystem.spec.lua document
-- for their own Player-keyed state. The idempotent-grant and pool-exhaustion LOGIC this module
-- exists to prove out is instead covered directly against the exported pure helpers
-- (ComputeGrantOutcome/ComputeEligibleRollIds), which take a plain unlockedEmoteIds table and need
-- no Player/PlayerDataSystem at all.

return function()
	describe("EmoteUnlockService.ComputeGrantOutcome (pure)", function()
		it("succeeds for an unowned, real emote", function()
			local ok, reason = EmoteUnlockService.ComputeGrantOutcome({}, "Wave")
			expect(ok).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("is idempotent -- rejects an already-owned emote as AlreadyOwned", function()
			local ok, reason = EmoteUnlockService.ComputeGrantOutcome({ Wave = true }, "Wave")
			expect(ok).to.equal(false)
			expect(reason).to.equal("AlreadyOwned")
		end)

		it("rejects an unknown emote id as UnknownEmote", function()
			local ok, reason = EmoteUnlockService.ComputeGrantOutcome({}, "DoesNotExist")
			expect(ok).to.equal(false)
			expect(reason).to.equal("UnknownEmote")
		end)
	end)

	describe("EmoteUnlockService.ComputeEligibleRollIds (pure)", function()
		it("returns every pool entry when none are owned yet", function()
			local eligible = EmoteUnlockService.ComputeEligibleRollIds({ "CelestialBow" }, {})
			expect(#eligible).to.equal(1)
			expect(eligible[1]).to.equal("CelestialBow")
		end)

		it("excludes an already-owned pool entry -- pool exhaustion returns an empty list", function()
			local eligible = EmoteUnlockService.ComputeEligibleRollIds({ "CelestialBow" }, { CelestialBow = true })
			expect(#eligible).to.equal(0)
		end)

		it("filters out a pool entry that no longer exists in the live registry", function()
			local eligible = EmoteUnlockService.ComputeEligibleRollIds({ "CelestialBow", "RetiredEmote" }, {})
			expect(#eligible).to.equal(1)
			expect(eligible[1]).to.equal("CelestialBow")
		end)

		it("returns an empty list for a nil pool", function()
			local eligible = EmoteUnlockService.ComputeEligibleRollIds(nil, {})
			expect(#eligible).to.equal(0)
		end)

		it("returns an empty list for an empty pool", function()
			local eligible = EmoteUnlockService.ComputeEligibleRollIds({}, {})
			expect(#eligible).to.equal(0)
		end)
	end)

	describe("EmoteUnlockService.HasUnlocked / GetUnlockedIds (no profile ever loaded)", function()
		it("HasUnlocked is false for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(EmoteUnlockService.HasUnlocked(fakePlayer, "Wave")).to.equal(false)
		end)

		it("GetUnlockedIds returns an empty list for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(#EmoteUnlockService.GetUnlockedIds(fakePlayer)).to.equal(0)
		end)
	end)

	describe("EmoteUnlockService.GrantEmote (no profile ever loaded)", function()
		it("returns false with ProfileNotLoaded rather than erroring", function()
			local fakePlayer = { Name = "Fake" } :: any
			local granted, reason = EmoteUnlockService.GrantEmote(fakePlayer, "Wave", { Type = "Default" })
			expect(granted).to.equal(false)
			expect(reason).to.equal("ProfileNotLoaded")
		end)

		it("rejects an unknown emote id before ever touching PlayerDataSystem", function()
			local fakePlayer = { Name = "Fake" } :: any
			local granted, reason = EmoteUnlockService.GrantEmote(fakePlayer, "DoesNotExist", { Type = "Default" })
			expect(granted).to.equal(false)
			expect(reason).to.equal("UnknownEmote")
		end)
	end)

	describe("EmoteUnlockService.RollEmote (no profile ever loaded)", function()
		it("returns UnknownPool for a poolId with no registered pool", function()
			local fakePlayer = { Name = "Fake" } :: any
			local success, emoteId, reason =
				EmoteUnlockService.RollEmote(fakePlayer, "NotARealPool", { Type = "Roll", Pool = "NotARealPool" })
			expect(success).to.equal(false)
			expect(emoteId).to.equal(nil)
			expect(reason).to.equal("UnknownPool")
		end)

		it("returns ProfileNotLoaded for a real pool when the profile never loaded", function()
			local fakePlayer = { Name = "Fake" } :: any
			local success, emoteId, reason =
				EmoteUnlockService.RollEmote(fakePlayer, "RareEmotes", { Type = "Roll", Pool = "RareEmotes" })
			expect(success).to.equal(false)
			expect(emoteId).to.equal(nil)
			expect(reason).to.equal("ProfileNotLoaded")
		end)
	end)
end
