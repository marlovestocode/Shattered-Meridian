--!strict
-- Covers Shared/PingReading.lua -- the one place that decides what a GetNetworkPing reading means.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PingReading = require(ReplicatedStorage.Shared.PingReading)

return function()
	describe("PingReading", function()
		local shipped = PingReading.REPORTS_ROUND_TRIP

		afterEach(function()
			PingReading.REPORTS_ROUND_TRIP = shipped
		end)

		it("reads a round-trip reading as itself, and halves it for one way", function()
			PingReading.REPORTS_ROUND_TRIP = true
			expect(PingReading.RoundTrip(0.2)).to.equal(0.2)
			expect(PingReading.OneWay(0.2)).to.equal(0.1)
		end)

		it("reads a one-way reading as itself, and doubles it for the round trip", function()
			PingReading.REPORTS_ROUND_TRIP = false
			expect(PingReading.OneWay(0.1)).to.equal(0.1)
			expect(PingReading.RoundTrip(0.1)).to.equal(0.2)
		end)

		it("reads garbage as no latency at all, never as a refund", function()
			for _, bad in { -1, 0 / 0, math.huge, "fast" :: any, nil :: any } do
				expect(PingReading.RoundTrip(bad)).to.equal(0)
				expect(PingReading.OneWay(bad)).to.equal(0)
			end
		end)

		it("ships assuming a round trip, so nothing changes until the probe says otherwise", function()
			expect(shipped).to.equal(true)
		end)
	end)
end
