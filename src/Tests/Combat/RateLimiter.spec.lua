--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

-- The RateLimiter entries Logger captured after `baseline` (a sequence number).
local function droppedSince(baseline: number): { any }
	local found = {}
	for _, entry in Logger.GetBufferSnapshot(baseline) do
		if entry.Scope == "RateLimiter" then
			table.insert(found, entry)
		end
	end
	return found
end

local function currentSequence(): number
	local snapshot = Logger.GetBufferSnapshot()
	return if #snapshot > 0 then snapshot[#snapshot].Sequence else 0
end

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

		it("says so when it drops a call -- once per player per window, never for a call it allowed", function()
			local limiter = RateLimiter.New(2)
			local player = { Name = "SpecDropper" } :: any
			local baseline = currentSequence()

			expect(limiter:IsLimited(player)).to.equal(false)
			expect(limiter:IsLimited(player)).to.equal(false)
			expect(#droppedSince(baseline)).to.equal(0)

			expect(limiter:IsLimited(player)).to.equal(true)
			local first = droppedSince(baseline)
			expect(#first).to.equal(1)
			expect(first[1].Level).to.equal("Warn")
			expect((first[1].Fields :: any).player).to.equal("SpecDropper")
			expect((first[1].Fields :: any).maxPerSecond).to.equal(2)
			-- It names the script that built the limiter, so "which budget" is answerable.
			expect(string.find((first[1].Fields :: any).limiter, "RateLimiter.spec", 1, true) ~= nil).to.equal(true)

			-- A flood is still one line for this window.
			expect(limiter:IsLimited(player)).to.equal(true)
			expect(limiter:IsLimited(player)).to.equal(true)
			expect(#droppedSince(baseline)).to.equal(1)
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
