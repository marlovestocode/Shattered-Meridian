--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminGate = require(ServerScriptService.Server.Network.AdminGate)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local AdminConfig = require(ServerScriptService.Server.Config.AdminConfig)

return function()
	describe("AdminGate.IsAuthorized", function()
		it("is true for a whitelisted UserId", function()
			local anyAuthorizedId = next(AdminConfig.AuthorizedUserIds)
			assert(anyAuthorizedId ~= nil, "AdminConfig.AuthorizedUserIds must not be empty for this spec")
			local player = { UserId = anyAuthorizedId, Name = "Admin" } :: any

			expect(AdminGate.IsAuthorized(player)).to.equal(true)
		end)

		it("is false for a UserId not on the whitelist", function()
			local player = { UserId = -1, Name = "Nobody" } :: any

			expect(AdminGate.IsAuthorized(player)).to.equal(false)
		end)
	end)

	describe("AdminGate.Check", function()
		it("rejects an unauthorized player before ever touching the rate limiter", function()
			local limiter = RateLimiter.New(1)
			local player = { UserId = -1, Name = "Nobody" } :: any

			local allowed, reason = AdminGate.Check(player, "TestAction", limiter)

			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotAuthorized")
			-- An unauthorized call must not consume rate-limit budget -- otherwise a flood of
			-- unauthorized requests could exhaust a legitimate admin's own bucket.
			expect(limiter:IsLimited(player)).to.equal(false)
		end)

		it("allows an authorized player under budget", function()
			local anyAuthorizedId = next(AdminConfig.AuthorizedUserIds)
			assert(anyAuthorizedId ~= nil, "AdminConfig.AuthorizedUserIds must not be empty for this spec")
			local limiter = RateLimiter.New(2)
			local player = { UserId = anyAuthorizedId, Name = "Admin" } :: any

			local allowed, reason = AdminGate.Check(player, "TestAction", limiter)

			expect(allowed).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("rejects an authorized player once the caller-supplied limiter is exhausted", function()
			local anyAuthorizedId = next(AdminConfig.AuthorizedUserIds)
			assert(anyAuthorizedId ~= nil, "AdminConfig.AuthorizedUserIds must not be empty for this spec")
			local limiter = RateLimiter.New(1)
			local player = { UserId = anyAuthorizedId, Name = "Admin" } :: any

			local firstAllowed = AdminGate.Check(player, "TestAction", limiter)
			local secondAllowed, secondReason = AdminGate.Check(player, "TestAction", limiter)

			expect(firstAllowed).to.equal(true)
			expect(secondAllowed).to.equal(false)
			expect(secondReason).to.equal("RateLimited")
		end)

		it("keeps two callers' limiters independent -- no shared default bucket", function()
			local anyAuthorizedId = next(AdminConfig.AuthorizedUserIds)
			assert(anyAuthorizedId ~= nil, "AdminConfig.AuthorizedUserIds must not be empty for this spec")
			local player = { UserId = anyAuthorizedId, Name = "Admin" } :: any
			local limiterA = RateLimiter.New(1)
			local limiterB = RateLimiter.New(1)

			AdminGate.Check(player, "ActionA", limiterA)

			-- Exhausting limiterA must never affect limiterB, since AdminGate never constructs or
			-- shares a bucket of its own.
			local allowed = AdminGate.Check(player, "ActionB", limiterB)
			expect(allowed).to.equal(true)
		end)
	end)
end
