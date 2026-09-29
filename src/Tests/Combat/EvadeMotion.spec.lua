--!strict
-- Covers Shared/Combat/EvadeMotion.lua: the evade's speed curve, its distance, and the directional
-- variant -- the one definition both the player's glide (States/Evading) and the training bot's drive.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)
local EvadeMotion = require(ReplicatedStorage.Shared.Combat.EvadeMotion)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

local T = EvadeConstants.DurationSeconds
local PEAK = EvadeConstants.PeakSpeed

return function()
	describe("EvadeMotion.SpeedAt", function()
		it("leaves at full speed and arrives at rest", function()
			expect(EvadeMotion.SpeedAt(0)).to.equal(PEAK)
			expect(EvadeMotion.SpeedAt(T)).to.equal(0)
			expect(EvadeMotion.SpeedAt(T * 0.999) < PEAK * 0.01).to.equal(true)
		end)

		it("is zero outside the glide", function()
			expect(EvadeMotion.SpeedAt(-0.01)).to.equal(0)
			expect(EvadeMotion.SpeedAt(T + 1)).to.equal(0)
		end)

		it("only ever slows down", function()
			local previous = math.huge
			for step = 0, 24 do
				local speed = EvadeMotion.SpeedAt(T * step / 25)
				expect(speed <= previous).to.equal(true)
				previous = speed
			end
		end)

		it("never claims a speed the movement validator would refuse", function()
			expect(PEAK < ParkourConstants.Validation.MaxReportedSpeed).to.equal(true)
			expect(PEAK < ParkourConstants.Validation.MaxTravelSpeed).to.equal(true)
		end)
	end)

	describe("EvadeMotion.DistanceAt", function()
		it("integrates to two thirds of peak times duration", function()
			local expected = PEAK * T * 2 / 3
			expect(math.abs(EvadeMotion.TotalDistance() - expected) < 1e-6).to.equal(true)
		end)

		it("matches a numeric integration of SpeedAt", function()
			local sum = 0
			local steps = 2000
			local dt = T / steps
			for step = 0, steps - 1 do
				sum += EvadeMotion.SpeedAt((step + 0.5) * dt) * dt
			end
			expect(math.abs(sum - EvadeMotion.TotalDistance()) < 1e-3).to.equal(true)
		end)

		it("is front-loaded -- most of the distance in the first 0.15s, so it reads as a flash-step", function()
			expect(EvadeMotion.DistanceAt(0.15) / EvadeMotion.TotalDistance() > 0.75).to.equal(true)
		end)

		it("clamps past the end of the glide", function()
			expect(EvadeMotion.DistanceAt(T + 5)).to.equal(EvadeMotion.TotalDistance())
			expect(EvadeMotion.DistanceAt(-1)).to.equal(0)
		end)
	end)

	describe("EvadeMotion.DirectionalVariant", function()
		local facing = Vector3.new(0, 0, -1)

		it("names the four directions relative to facing", function()
			expect(EvadeMotion.DirectionalVariant(Vector3.new(0, 0, -1), facing)).to.equal("Forward")
			expect(EvadeMotion.DirectionalVariant(Vector3.new(0, 0, 1), facing)).to.equal("Back")
			expect(EvadeMotion.DirectionalVariant(Vector3.new(1, 0, 0), facing)).to.equal("Right")
			expect(EvadeMotion.DirectionalVariant(Vector3.new(-1, 0, 0), facing)).to.equal("Left")
		end)

		it("resolves an exact diagonal to Forward/Back", function()
			expect(EvadeMotion.DirectionalVariant(Vector3.new(1, 0, 1), facing)).to.equal("Back")
			expect(EvadeMotion.DirectionalVariant(Vector3.new(-1, 0, -1), facing)).to.equal("Forward")
		end)

		it("ignores the vertical component", function()
			expect(EvadeMotion.DirectionalVariant(Vector3.new(1, 5, 0), facing)).to.equal("Right")
		end)
	end)
end
