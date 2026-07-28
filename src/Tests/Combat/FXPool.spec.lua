--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local FXPool = require(StarterPlayer.StarterPlayerScripts.Client.FX.FXPool) :: any

-- A factory that hands out uniquely-tagged tables and counts how many it built, so tests can assert
-- reuse (by identity) and that the pool never over-creates past its cap.
local function countingFactory()
	local made = 0
	local factory = function()
		made += 1
		return { id = made }
	end
	return factory, function()
		return made
	end
end

return function()
	describe("FXPool.Acquire", function()
		it("creates fresh items up to MaxSize", function()
			local factory, madeCount = countingFactory()
			local pool = FXPool.New(factory, nil, 3)
			local a = pool:Acquire()
			local b = pool:Acquire()
			local c = pool:Acquire()
			expect(a).to.be.ok()
			expect(b).to.be.ok()
			expect(c).to.be.ok()
			expect(madeCount()).to.equal(3)
			expect(pool:CountActive()).to.equal(3)
		end)

		it("returns nil once at cap with none free", function()
			local factory = countingFactory()
			local pool = FXPool.New(factory, nil, 2)
			pool:Acquire()
			pool:Acquire()
			expect(pool:Acquire()).to.equal(nil)
		end)
	end)

	describe("FXPool.Release", function()
		it("reuses a freed item instead of creating a new one", function()
			local factory, madeCount = countingFactory()
			local pool = FXPool.New(factory, nil, 2)
			local a = pool:Acquire()
			pool:Release(a)
			local b = pool:Acquire()
			expect(b).to.equal(a) -- same identity, reused
			expect(madeCount()).to.equal(1) -- factory ran only once
		end)

		it("frees a cap slot so acquire succeeds again after release", function()
			local factory = countingFactory()
			local pool = FXPool.New(factory, nil, 1)
			local a = pool:Acquire()
			expect(pool:Acquire()).to.equal(nil) -- at cap
			pool:Release(a)
			expect(pool:Acquire()).to.equal(a) -- freed slot reused
		end)

		it("runs the reset callback on release", function()
			local factory = countingFactory()
			local resetCalls = {}
			local pool = FXPool.New(factory, function(item)
				table.insert(resetCalls, item.id)
			end, 2)
			local a = pool:Acquire()
			pool:Release(a)
			expect(#resetCalls).to.equal(1)
			expect(resetCalls[1]).to.equal(a.id)
		end)
	end)

	describe("FXPool counts", function()
		it("tracks active and free across acquire/release", function()
			local factory = countingFactory()
			local pool = FXPool.New(factory, nil, 4)
			local a = pool:Acquire()
			local b = pool:Acquire()
			expect(pool:CountActive()).to.equal(2)
			expect(pool:CountFree()).to.equal(0)
			pool:Release(a)
			expect(pool:CountActive()).to.equal(1)
			expect(pool:CountFree()).to.equal(1)
			pool:Release(b)
			expect(pool:CountActive()).to.equal(0)
			expect(pool:CountFree()).to.equal(2)
		end)
	end)
end
