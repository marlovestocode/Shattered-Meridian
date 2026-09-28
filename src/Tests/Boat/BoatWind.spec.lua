--!strict
-- Covers Shared/Boat/BoatWind.lua -- the polar, the conventions, and the two sign rules the rest of the
-- Boat layer hangs off.
--
-- WHY THIS FILE IS THE MOST VALUABLE SPEC IN THE LAYER: every bug this module can have is silent. A
-- flipped bearing convention gives a boat that sails beautifully at the one heading she should be unable
-- to hold; a sign error in LateralFactor gives a boat that leans INTO the wind, which looks merely odd
-- rather than wrong; a discontinuity at pi gives a heel that snaps sides once, during a gybe, which is
-- exactly the moment nobody is looking at the hull. None of the three errors, none logs, and all three
-- are one assertion each here.
--
-- What is NOT covered here, and cannot be: whether the polar FEELS right. That is a playtest, and the
-- numbers in BoatConstants.Wind are the thing it would retune.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatWind = require(ReplicatedStorage.Shared.Boat.BoatWind)

return function()
	describe("Sample", function()
		it("is a pure function of the clock -- the same instant gives the same wind", function()
			local first = BoatWind.Sample(1234.5)
			local second = BoatWind.Sample(1234.5)
			expect(first.BearingRadians).to.equal(second.BearingRadians)
			expect(first.Strength).to.equal(second.Strength)
		end)

		it("keeps the strength inside its authored band at every sampled instant", function()
			-- Swept across both gust periods rather than at a handful of pretty numbers, since the whole
			-- risk here is a sum of two sines exceeding 1 somewhere in between.
			for step = 0, 600 do
				local sample = BoatWind.Sample(step * 0.83)
				expect(sample.Strength >= BoatConstants.Wind.MinStrength).to.equal(true)
				expect(sample.Strength <= BoatConstants.Wind.MaxStrength).to.equal(true)
			end
		end)

		it("never sits at a flat calm -- see BoatConstants.Wind.MinStrength", function()
			expect(BoatConstants.Wind.MinStrength > 0).to.equal(true)
		end)

		it("keeps the bearing wrapped into -pi..pi", function()
			for step = 0, 400 do
				local sample = BoatWind.Sample(step * 1.7)
				expect(sample.BearingRadians >= -math.pi).to.equal(true)
				expect(sample.BearingRadians <= math.pi).to.equal(true)
			end
		end)

		it("actually moves -- a wind that never shifted would delete the reason to watch it", function()
			local a = BoatWind.Sample(0)
			local b = BoatWind.Sample(BoatConstants.Wind.SwingPeriodSeconds * 0.25)
			expect(math.abs(a.BearingRadians - b.BearingRadians) > 0.05).to.equal(true)
		end)
	end)

	describe("the bearing convention", function()
		it("round-trips a bearing through SourceLook and back", function()
			for _, bearing in { -3, -1.2, 0, 0.4, 2.9 } do
				local recovered = BoatWind.BearingOfLook(BoatWind.SourceLook(bearing))
				expect(recovered).to.be.near(bearing, 1e-5)
			end
		end)

		it("puts bearing 0 on world -Z, which is what every other LookVector in this codebase means", function()
			local look = BoatWind.SourceLook(0)
			expect(look.X).to.be.near(0, 1e-6)
			expect(look.Z).to.be.near(-1, 1e-6)
		end)

		it("answers 0 for a degenerate direction rather than erroring", function()
			expect(BoatWind.BearingOfLook(Vector3.new(0, 1, 0))).to.equal(0)
			expect(BoatWind.BearingOfLook(Vector3.zero)).to.equal(0)
		end)
	end)

	describe("RelativeAngle", function()
		it("is zero when the bow points straight at the wind's source", function()
			expect(BoatWind.RelativeAngle(1.1, 1.1)).to.be.near(0, 1e-9)
		end)

		it("wraps rather than accumulating -- one degree to starboard is not 359 to port", function()
			local angle = BoatWind.RelativeAngle(-math.pi + 0.01, math.pi - 0.01)
			expect(math.abs(angle) < 0.05).to.equal(true)
		end)

		it("is POSITIVE for a wind on the port bow -- the sign every heel in the layer reads", function()
			-- Bow at bearing 0 is facing world -Z, so its starboard side is +X. A wind source at a
			-- positive bearing offset sits toward -X, which is to port.
			local angle = BoatWind.RelativeAngle(0, 1.0)
			expect(angle > 0).to.equal(true)
			local source = BoatWind.SourceLook(1.0)
			expect(source.X < 0).to.equal(true)
		end)
	end)

	describe("Efficiency", function()
		it("is EXACTLY zero anywhere inside the no-go arc, however much canvas is set", function()
			expect(BoatWind.Efficiency(0)).to.equal(0)
			expect(BoatWind.Efficiency(BoatConstants.Wind.NoGoRadians * 0.5)).to.equal(0)
			expect(BoatWind.Efficiency(-BoatConstants.Wind.NoGoRadians * 0.99)).to.equal(0)
		end)

		it("peaks at exactly 1 on the authored best point of sail", function()
			expect(BoatWind.Efficiency(BoatConstants.Wind.PeakRadians)).to.be.near(1, 1e-9)
		end)

		it("falls back to the running figure dead downwind", function()
			expect(BoatWind.Efficiency(math.pi)).to.be.near(BoatConstants.Wind.RunningEfficiency, 1e-9)
		end)

		it("is slower running than reaching -- the reason downwind is not the answer to everything", function()
			expect(BoatWind.Efficiency(math.pi) < BoatWind.Efficiency(BoatConstants.Wind.PeakRadians)).to.equal(true)
		end)

		it("ignores the sign -- which tack you are on has nothing to do with how fast you go", function()
			for _, angle in { 0.9, 1.5, 2.2, 3.0 } do
				expect(BoatWind.Efficiency(angle)).to.be.near(BoatWind.Efficiency(-angle), 1e-12)
			end
		end)

		it("stays inside 0..1 across the whole range", function()
			for step = -360, 360 do
				local value = BoatWind.Efficiency(step * math.pi / 180)
				expect(value >= 0).to.equal(true)
				expect(value <= 1).to.equal(true)
			end
		end)

		it("rises monotonically from the no-go edge to the peak", function()
			local previous = -1
			local span = BoatConstants.Wind.PeakRadians - BoatConstants.Wind.NoGoRadians
			for step = 0, 40 do
				local angle = BoatConstants.Wind.NoGoRadians + span * (step / 40)
				local value = BoatWind.Efficiency(angle)
				expect(value >= previous).to.equal(true)
				previous = value
			end
		end)

		it("has no step at the no-go edge -- the sails fill, they do not switch on", function()
			-- A linear ramp would leave a corner here. The smoothstep's derivative is zero at both ends,
			-- so a degree past the edge is still nearly nothing.
			local justInside = BoatWind.Efficiency(BoatConstants.Wind.NoGoRadians - 1e-4)
			local justOutside = BoatWind.Efficiency(BoatConstants.Wind.NoGoRadians + 0.02)
			expect(justInside).to.equal(0)
			expect(justOutside < 0.02).to.equal(true)
		end)

		it("has no step through a gybe -- the discontinuity that only bites once, at pi", function()
			local before = BoatWind.Efficiency(math.pi - 1e-3)
			local after = BoatWind.Efficiency(-math.pi + 1e-3)
			expect(math.abs(before - after) < 1e-4).to.equal(true)
		end)
	end)

	describe("LateralFactor", function()
		it("is zero head to wind and zero dead astern", function()
			expect(BoatWind.LateralFactor(0)).to.be.near(0, 1e-12)
			expect(BoatWind.LateralFactor(math.pi)).to.be.near(0, 1e-12)
		end)

		it("peaks on the beam, which is where the sideways force actually is", function()
			expect(BoatWind.LateralFactor(math.pi / 2)).to.be.near(1, 1e-12)
			expect(BoatWind.LateralFactor(-math.pi / 2)).to.be.near(-1, 1e-12)
		end)

		it("is POSITIVE for a wind on the port bow -- she is pushed toward starboard", function()
			expect(BoatWind.LateralFactor(1.0) > 0).to.equal(true)
		end)

		it("is CONTINUOUS through a gybe, which a sign() implementation would not be", function()
			-- The whole reason this function is a sin() and not a sign(). A discontinuity here snaps the
			-- heel from one side to the other in a single frame as the stern crosses the wind.
			local before = BoatWind.LateralFactor(math.pi - 1e-4)
			local after = BoatWind.LateralFactor(-math.pi + 1e-4)
			expect(math.abs(before - after) < 1e-3).to.equal(true)
		end)
	end)

	describe("Pressure", function()
		it("is zero in irons, however much canvas is set -- luffing sails do not heel her", function()
			expect(BoatWind.Pressure(1, 1, 0)).to.equal(0)
		end)

		it("is zero with the sails furled, however hard it blows", function()
			expect(BoatWind.Pressure(0, 1, math.pi / 2)).to.equal(0)
		end)

		it("reads the magnitude of the canvas, so backed sails press as hard as set ones", function()
			local set = BoatWind.Pressure(0.8, 1, math.pi / 2)
			local backed = BoatWind.Pressure(-0.8, 1, math.pi / 2)
			expect(set).to.be.near(backed, 1e-12)
		end)

		it("scales with the wind", function()
			local light = BoatWind.Pressure(1, 0.5, math.pi / 2)
			local strong = BoatWind.Pressure(1, 1, math.pi / 2)
			expect(strong > light).to.equal(true)
		end)
	end)

	describe("PointOfSail", function()
		it("names every band in order across the range", function()
			expect(BoatWind.PointOfSail(0)).to.equal("InIrons")
			expect(BoatWind.PointOfSail(BoatConstants.Wind.NoGoRadians + 0.01)).to.equal("CloseHauled")
			expect(BoatWind.PointOfSail(BoatConstants.Wind.CloseHauledMaxRadians + 0.01)).to.equal("BeamReach")
			expect(BoatWind.PointOfSail(BoatConstants.Wind.BeamReachMaxRadians + 0.01)).to.equal("BroadReach")
			expect(BoatWind.PointOfSail(math.pi)).to.equal("Running")
		end)

		it("gives the same name on either tack", function()
			for _, angle in { 0.5, 1.0, 1.6, 2.4, 3.0 } do
				expect(BoatWind.PointOfSail(angle)).to.equal(BoatWind.PointOfSail(-angle))
			end
		end)

		it("has its band edges authored in ascending order and inside the range", function()
			local cfg = BoatConstants.Wind
			expect(cfg.NoGoRadians < cfg.CloseHauledMaxRadians).to.equal(true)
			expect(cfg.CloseHauledMaxRadians < cfg.BeamReachMaxRadians).to.equal(true)
			expect(cfg.BeamReachMaxRadians < cfg.BroadReachMaxRadians).to.equal(true)
			expect(cfg.BroadReachMaxRadians < math.pi).to.equal(true)
		end)

		it("calls the polar's own peak a beam reach", function()
			-- The one invariant worth enforcing between the naming bands and the speed curve. They are
			-- deliberately separate constants (see BoatConstants.Wind.CloseHauledMaxRadians), so nothing
			-- but this assertion stops a retune of one from making the panel say something absurd -- like
			-- calling the fastest heading on the boat "close hauled".
			expect(BoatWind.PointOfSail(BoatConstants.Wind.PeakRadians)).to.equal("BeamReach")
		end)
	end)
end
