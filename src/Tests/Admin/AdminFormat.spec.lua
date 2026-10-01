--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminFormat = require(ReplicatedStorage.Shared.Admin.AdminFormat)

local function entry(overrides: { [string]: any }): any
	local base = {
		UserId = 101,
		Name = "tester",
		DisplayName = "Tester",
		CharacterName = "Lin Wei",
		IsRequester = false,
		Tier = 2,
		PingMs = 40,
		Alive = true,
		HealthFraction = 1,
		InCombat = false,
		Godmode = false,
		Flying = false,
		Frozen = false,
		Invisible = false,
		SpeedMultiplier = 1,
		Muted = false,
		Flagged = false,
		Marked = false,
	}
	for key, value in overrides do
		base[key] = value
	end
	return base
end

return function()
	describe("AdminFormat.Duration", function()
		it("uses at most two units at every scale", function()
			expect(AdminFormat.Duration(12)).to.equal("12s")
			expect(AdminFormat.Duration(185)).to.equal("3m 05s")
			expect(AdminFormat.Duration(2 * 3600 + 14 * 60 + 9)).to.equal("2h 14m")
			expect(AdminFormat.Duration(4 * 86400 + 2 * 3600 + 30)).to.equal("4d 2h")
		end)

		it("floors fractions and never goes negative", function()
			expect(AdminFormat.Duration(9.9)).to.equal("9s")
			expect(AdminFormat.Duration(-5)).to.equal("0s")
		end)
	end)

	describe("AdminFormat.Count", function()
		it("groups thousands", function()
			expect(AdminFormat.Count(0)).to.equal("0")
			expect(AdminFormat.Count(999)).to.equal("999")
			expect(AdminFormat.Count(1000)).to.equal("1,000")
			expect(AdminFormat.Count(123456)).to.equal("123,456")
			expect(AdminFormat.Count(1234567)).to.equal("1,234,567")
			expect(AdminFormat.Count(-4500)).to.equal("-4,500")
		end)
	end)

	describe("AdminFormat.Until", function()
		it("reads a future timestamp as a duration and a past one as expired", function()
			expect(AdminFormat.Until(1000 + 90, 1000)).to.equal("in 1m 30s")
			expect(AdminFormat.Until(1000, 1000)).to.equal("expired")
		end)
	end)

	describe("AdminFormat.RosterFlags", function()
		it("is empty for a player with nothing going on", function()
			expect(#AdminFormat.RosterFlags(entry({}))).to.equal(0)
		end)

		it("leads with the most consequential flags and names speed as a multiplier", function()
			local flags =
				AdminFormat.RosterFlags(entry({ Alive = false, Flagged = true, Godmode = true, SpeedMultiplier = 2 }))
			expect(flags[1]).to.equal("DEAD")
			expect(flags[2]).to.equal("FLAGGED")
			expect(table.find(flags, "GOD")).to.be.ok()
			expect(table.find(flags, "x2")).to.be.ok()
		end)
	end)

	describe("AdminFormat.RosterMatches", function()
		it("matches any name a player goes by, and their UserId, ignoring case and padding", function()
			local player = entry({})
			expect(AdminFormat.RosterMatches(player, "")).to.equal(true)
			expect(AdminFormat.RosterMatches(player, "  TEST ")).to.equal(true)
			expect(AdminFormat.RosterMatches(player, "lin wei")).to.equal(true)
			expect(AdminFormat.RosterMatches(player, "101")).to.equal(true)
			expect(AdminFormat.RosterMatches(player, "nobody")).to.equal(false)
		end)
	end)

	describe("AdminFormat.ParseUserId", function()
		it("accepts a positive whole number, trimmed", function()
			expect(AdminFormat.ParseUserId(" 12345 ")).to.equal(12345)
		end)

		it("refuses anything that is not a plausible UserId", function()
			expect(AdminFormat.ParseUserId("")).to.equal(nil)
			expect(AdminFormat.ParseUserId("0")).to.equal(nil)
			expect(AdminFormat.ParseUserId("-3")).to.equal(nil)
			expect(AdminFormat.ParseUserId("1.5")).to.equal(nil)
			expect(AdminFormat.ParseUserId("12a")).to.equal(nil)
			expect(AdminFormat.ParseUserId("99999999999999999999")).to.equal(nil)
		end)
	end)
end
