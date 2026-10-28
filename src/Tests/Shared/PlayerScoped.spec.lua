--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerScoped = require(ReplicatedStorage.Shared.PlayerScoped)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Rig = require(script.Parent.Parent.TestHelpers.Rig)

-- Names are VM-wide and New refuses a repeat, so every case scopes under a name of its own.
local caseCounter = 0
local function uniqueName(): string
	caseCounter += 1
	return `PlayerScopedSpec.table{caseCounter}`
end

return function()
	describe("PlayerScoped", function()
		it("hands back an ordinary table that reads, writes and iterates as one", function()
			local map = PlayerScoped.New(uniqueName())
			local player = Rig.FakePlayer("Reader")
			map[player] = 7
			expect(map[player]).to.equal(7)
			local seen = 0
			for key, value in map do
				expect(key).to.equal(player)
				expect(value).to.equal(7)
				seen += 1
			end
			expect(seen).to.equal(1)
		end)

		it("drops only the released player's entry, from every scoped table", function()
			local first = PlayerScoped.New(uniqueName())
			local second = PlayerScoped.New(uniqueName())
			local leaver = Rig.FakePlayer("Leaver")
			local stayer = Rig.FakePlayer("Stayer")
			first[leaver] = true
			first[stayer] = true
			second[leaver] = "x"

			PlayerScoped.Release(leaver)

			expect(first[leaver]).to.equal(nil)
			expect(second[leaver]).to.equal(nil)
			expect(first[stayer]).to.equal(true)
		end)

		it("refuses a second table under the same name", function()
			local name = uniqueName()
			PlayerScoped.New(name)
			expect(function()
				PlayerScoped.New(name)
			end).to.throw()
		end)

		it("counts each named table once", function()
			local before = PlayerScoped.Count()
			PlayerScoped.New(uniqueName())
			expect(PlayerScoped.Count()).to.equal(before + 1)
		end)

		it("scopes a RateLimiter's buckets, so a returning player starts with a fresh budget", function()
			local limiter = RateLimiter.New(1)
			local player = Rig.FakePlayer("Budget")
			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(true)

			PlayerScoped.Release(player)

			expect(limiter:IsLimited(player)).to.equal(false)
		end)
	end)
end
