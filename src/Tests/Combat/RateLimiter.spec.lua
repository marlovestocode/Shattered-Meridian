--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

return function()
	describe("RateLimiter", function()
		it("allows up to maxPerSecond calls in a window", function()
			local limiter = RateLimiter.New(3)
			local player = {} :: any

			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(false)
		end)

		it("rejects the call past maxPerSecond within the same window", function()
			local limiter = RateLimiter.New(2)
			local player = {} :: any

			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(true)
		end)

		it("resets the budget after the window elapses", function()
			local limiter = RateLimiter.New(1)
			local player = {} :: any

			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(true)

			task.wait(1.1)

			expect(limiter:IsLimited(player)).to.equal(false)
		end)

		it("tracks independent budgets per player", function()
			local limiter = RateLimiter.New(1)
			local playerA = {} :: any
			local playerB = {} :: any

			expect(limiter:IsLimited(playerA)).to.equal(false)
			expect(limiter:IsLimited(playerB)).to.equal(false)
			expect(limiter:IsLimited(playerA)).to.equal(true)
			expect(limiter:IsLimited(playerB)).to.equal(true)
		end)

		it("keeps separate instances independent (category tiering)", function()
			local combatCritical = RateLimiter.New(1)
			local utility = RateLimiter.New(1)
			local player = {} :: any

			expect(combatCritical:IsLimited(player)).to.equal(false)
			expect(combatCritical:IsLimited(player)).to.equal(true)
			-- A burst against combatCritical's budget must never affect utility's own budget.
			expect(utility:IsLimited(player)).to.equal(false)
		end)

		it("Clear drops a player's bucket so their next call is unthrottled", function()
			local limiter = RateLimiter.New(1)
			local player = {} :: any

			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(true)

			limiter:Clear(player)

			expect(limiter:IsLimited(player)).to.equal(false)
		end)
	end)
end
