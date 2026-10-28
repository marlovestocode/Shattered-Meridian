--!strict
-- Covers the 2026-10-27 hit-stop smoothness rules in Client/FX/HitStop.lua -- the pure halves: latency aging
-- (AgedSeconds), the chain cap, gap and never-shorten rule (ChainedSeconds), and the stun slow's eased release
-- (SlowMultiplierAt). The freezes themselves are AnimationFreezeGuard.spec's and AnimationManagerFreezeFor.spec's.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local HitStop = require(StarterPlayer.StarterPlayerScripts.Client.FX.HitStop)

local CONFIG = FXConstants.HitStop

return function()
	describe("HitStop.AgedSeconds", function()
		it("holds a predicted impact's full beat", function()
			expect(HitStop.AgedSeconds(0.12, nil)).to.equal(0.12)
			expect(HitStop.AgedSeconds(0.12, 0)).to.equal(0.12)
		end)

		it("takes a verdict's trip off its beat, never below the stinger", function()
			if not CONFIG.AgeByLatency then
				return
			end
			expect(HitStop.AgedSeconds(0.14, 0.05)).to.be.near(0.09, 1e-9)
			expect(HitStop.AgedSeconds(0.14, 0.5)).to.equal(CONFIG.MinStingerSeconds)
			-- A beat already shorter than the stinger is never lengthened by being late.
			expect(HitStop.AgedSeconds(0.02, 0.5)).to.equal(0.02)
		end)
	end)

	describe("HitStop.ChainedSeconds", function()
		local idleSince = -1000

		it("starts a fresh chain at the beat, capped, and refuses one too short to read", function()
			expect(HitStop.ChainedSeconds(0.09, 0, idleSince, idleSince)).to.equal(0.09)
			expect(HitStop.ChainedSeconds(5, 0, idleSince, idleSince)).to.equal(CONFIG.MaxChainSeconds)
			expect(HitStop.ChainedSeconds(CONFIG.MinFreezeSeconds / 2, 0, idleSince, idleSince)).to.equal(0)
		end)

		it("extends a live chain only up to its budget, and never shortens it", function()
			-- A chain began at 0 and holds until 0.09.
			local extended = HitStop.ChainedSeconds(0.12, 0.05, 0, 0.09)
			expect(extended).to.be.near(0.12, 1e-9)
			-- A freeze ending before the hold does nothing.
			expect(HitStop.ChainedSeconds(0.02, 0.05, 0, 0.09)).to.equal(0)
			-- Hits keep arriving: the chain never holds past MaxChainSeconds from its start.
			local late = HitStop.ChainedSeconds(0.2, CONFIG.MaxChainSeconds - 0.05, 0, CONFIG.MaxChainSeconds - 0.01)
			expect(late).to.be.near(0.05, 1e-9)
			expect(HitStop.ChainedSeconds(0.2, CONFIG.MaxChainSeconds, 0, CONFIG.MaxChainSeconds + 1e-3)).to.equal(0)
		end)

		it("leaves free motion between two chains", function()
			local endedAt = 1
			expect(HitStop.ChainedSeconds(0.09, endedAt + CONFIG.ChainGapSeconds / 2, 0.8, endedAt)).to.equal(0)
			expect(HitStop.ChainedSeconds(0.09, endedAt + CONFIG.ChainGapSeconds, 0.8, endedAt)).to.equal(0.09)
		end)

		it("can never hold a stream of hits longer than the cap", function()
			-- A hit every 50 ms for two seconds, each asking for a perfect parry's beat.
			local startedAt, heldUntil = -math.huge, -math.huge
			local longest = 0
			for step = 0, 40 do
				local now = step * 0.05
				local granted = HitStop.ChainedSeconds(CONFIG.PerfectParrySeconds, now, startedAt, heldUntil)
				if granted > 0 then
					if now >= heldUntil then
						startedAt = now
					end
					heldUntil = now + granted
				end
				longest = math.max(longest, heldUntil - startedAt)
			end
			expect(longest <= CONFIG.MaxChainSeconds + 1e-9).to.equal(true)
		end)
	end)

	describe("HitStop.SlowMultiplierAt", function()
		it("holds the slow, then eases back to full speed over the release", function()
			local release = CONFIG.SlowReleaseSeconds
			expect(HitStop.SlowMultiplierAt(0.25, 10, 10 - release - 0.1)).to.equal(0.25)
			expect(HitStop.SlowMultiplierAt(0.25, 10, 10 - release / 2)).to.be.near(0.625, 1e-6)
			expect(HitStop.SlowMultiplierAt(0.25, 10, 10)).to.be.near(1, 1e-9)
			expect(HitStop.SlowMultiplierAt(0.25, nil, 0)).to.equal(0.25)
		end)
	end)
end
