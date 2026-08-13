--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MeridianSystem = require(ServerScriptService.Server.Systems.MeridianSystem)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- MeridianSystem.Init() is never called in this spec file -- it creates a live RemoteEvent and
-- subscribes to GameplayEvents, neither of which this file needs to exercise the pure/no-profile
-- surface below. GetMeridianXP/AwardMeridianXP ARE exercised, but only against the "profile never
-- loaded" fallback path (a plain table standing in for Player) -- a genuinely seeded/loaded profile
-- requires PlayerDataSystem's real DataStore-backed load flow for a live Player, which is Studio/
-- live-server verification only, the same already-accepted gap PlayerDataSystem.spec.lua documents
-- for its own Player-keyed state.

return function()
	describe("MeridianSystem.GetMeridianXP (no profile ever loaded)", function()
		it("returns 0 for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(MeridianSystem.GetMeridianXP(fakePlayer)).to.equal(0)
		end)
	end)

	describe("MeridianSystem.AwardMeridianXP", function()
		it("returns false and never errors for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(MeridianSystem.AwardMeridianXP(fakePlayer, 25, "PvPKill")).to.equal(false)
		end)

		it("rejects a non-positive or non-numeric amount before ever touching PlayerDataSystem", function()
			local fakePlayer = {} :: any
			expect(MeridianSystem.AwardMeridianXP(fakePlayer, 0, "Test")).to.equal(false)
			expect(MeridianSystem.AwardMeridianXP(fakePlayer, -10, "Test")).to.equal(false)
		end)
	end)

	describe("Constants.Meridian", function()
		it("BaseXPPerKill is a sane positive number", function()
			expect(Constants.Meridian.BaseXPPerKill).to.be.a("number")
			expect(Constants.Meridian.BaseXPPerKill > 0).to.equal(true)
		end)
	end)
end
