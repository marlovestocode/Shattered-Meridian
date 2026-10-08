--!strict
-- Covers Client/DevTools/PingProbe.lua's verdict -- the median ratio of GetNetworkPing to the overlay's
-- round-trip ping, and which way it points (Shared/PingReading.REPORTS_ROUND_TRIP).

local StarterPlayer = game:GetService("StarterPlayer")

local PingProbe = require(StarterPlayer.StarterPlayerScripts.Client.DevTools.PingProbe)

return function()
	describe("PingProbe.Verdict", function()
		it("has no verdict without samples", function()
			local median, roundTrip = PingProbe.Verdict({})
			expect(median).to.equal(nil)
			expect(roundTrip).to.equal(nil)
		end)

		it("reads a reading near the overlay as a round trip", function()
			local median, roundTrip = PingProbe.Verdict({ 0.92, 0.85, 0.97 })
			expect(median).to.equal(0.92)
			expect(roundTrip).to.equal(true)
		end)

		it("reads a reading near half the overlay as one way", function()
			local median, roundTrip = PingProbe.Verdict({ 0.5, 0.46, 0.55, 0.49 })
			expect(math.abs((median :: number) - 0.495) < 1e-9).to.equal(true)
			expect(roundTrip).to.equal(false)
		end)

		it("is not swayed by one outlier", function()
			local _, roundTrip = PingProbe.Verdict({ 0.5, 0.52, 3.0 })
			expect(roundTrip).to.equal(false)
		end)
	end)
end
