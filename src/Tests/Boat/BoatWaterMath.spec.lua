--!strict
-- Covers Shared/Boat/BoatWaterMath.lua -- plane containment, the swell, and the tilt signs.
--
-- The planes below are built as plain tables rather than from real BaseParts, which is the whole payoff
-- of the split between this module and Server/Boat/BoatWater.lua: containment is answerable without a
-- place file, a builder, or a sea.
--
-- What is NOT covered here, and cannot be: whether GetTagged actually finds a builder's water, whether a
-- re-tag rebuilds the cache, or whether the TopY read off a real part matches its rendered surface.
-- Those need real Instances and are Server/Boat/BoatWater.lua's, exercised by playing the game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)
local BoatWaterMath = require(ReplicatedStorage.Shared.Boat.BoatWaterMath)

-- A level, axis-aligned plane -- the shape every sea in this game is built out of.
local function plane(centre: Vector3, size: Vector3): BoatTypes.WaterPlane
	local cframe = CFrame.new(centre)
	return {
		TopY = centre.Y + size.Y * 0.5,
		Inverse = cframe:Inverse(),
		HalfX = size.X * 0.5,
		HalfZ = size.Z * 0.5,
	}
end

-- The same, yawed -- the other shape a builder plausibly makes (a river running diagonally).
local function yawedPlane(centre: Vector3, size: Vector3, yaw: number): BoatTypes.WaterPlane
	local cframe = CFrame.new(centre) * CFrame.Angles(0, yaw, 0)
	return {
		TopY = centre.Y + size.Y * 0.5,
		Inverse = cframe:Inverse(),
		HalfX = size.X * 0.5,
		HalfZ = size.Z * 0.5,
	}
end

return function()
	describe("SurfaceUnder", function()
		it("finds nothing in a world with no tagged water -- which is the Beached condition", function()
			expect(BoatWaterMath.SurfaceUnder({}, Vector3.new(0, 0, 0))).to.equal(nil)
		end)

		it("returns the plane's top face, not its centre", function()
			local planes = { plane(Vector3.new(0, 10, 0), Vector3.new(200, 4, 200)) }
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(5, 0, 5))).to.equal(12)
		end)

		it("finds nothing outside the plane's horizontal extent", function()
			local planes = { plane(Vector3.new(0, 10, 0), Vector3.new(100, 4, 100)) }
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(80, 0, 0))).to.equal(nil)
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(0, 0, -80))).to.equal(nil)
		end)

		it("ignores the sample's own height entirely", function()
			-- A hull shoved under the surface by a collision, or riding high on a swell, is still on the
			-- water. A height test here would beach her for the duration and then un-beach her.
			local planes = { plane(Vector3.new(0, 10, 0), Vector3.new(100, 4, 100)) }
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(0, -500, 0))).to.equal(12)
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(0, 900, 0))).to.equal(12)
		end)

		it("resolves overlapping planes to the HIGHEST -- a lock laid over a sea", function()
			local planes = {
				plane(Vector3.new(0, 0, 0), Vector3.new(400, 4, 400)),
				plane(Vector3.new(0, 30, 0), Vector3.new(60, 4, 60)),
			}
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(0, 0, 0))).to.equal(32)
			-- ...and to the sea again once you are off the lock.
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(120, 0, 0))).to.equal(2)
		end)

		it("respects a yawed plane's own axes rather than a world-aligned box", function()
			-- A 200x20 strip turned 90 degrees: a point 60 studs out along world Z is inside it, and one
			-- 60 studs out along world X is not. A world-aligned bounding test would get both wrong.
			local planes = { yawedPlane(Vector3.new(0, 0, 0), Vector3.new(200, 2, 20), math.pi / 2) }
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(0, 0, 60))).to.equal(1)
			expect(BoatWaterMath.SurfaceUnder(planes, Vector3.new(60, 0, 0))).to.equal(nil)
		end)
	end)

	describe("Swell", function()
		it("is a pure function of position and the clock", function()
			local h1 = BoatWaterMath.Swell(12, 34, 56)
			local h2 = BoatWaterMath.Swell(12, 34, 56)
			expect(h1).to.equal(h2)
		end)

		it("stays inside the sum of its two authored amplitudes", function()
			local ceiling = BoatConstants.Swell.Amplitude + BoatConstants.Swell.CrossAmplitude
			for step = 0, 300 do
				local height = BoatWaterMath.Swell(step * 7.3, step * -4.1, step * 0.31)
				expect(math.abs(height) <= ceiling + 1e-9).to.equal(true)
			end
		end)

		it("moves -- a sea that stood still would be a floor", function()
			local a = BoatWaterMath.Swell(0, 0, 0)
			local b = BoatWaterMath.Swell(0, 0, BoatConstants.Swell.PeriodSeconds * 0.25)
			expect(math.abs(a - b) > 1e-3).to.equal(true)
		end)

		it("does not repeat on either train's own period -- which one sine would", function()
			-- The whole reason there are two crossed trains: a single sine returns exactly to itself after
			-- one period, and a player feels that metronome within seconds.
			local a = BoatWaterMath.Swell(0, 0, 0)
			local b = BoatWaterMath.Swell(0, 0, BoatConstants.Swell.PeriodSeconds)
			expect(math.abs(a - b) > 1e-4).to.equal(true)
		end)

		it("reports slopes that match its own height function", function()
			-- The claim the analytic derivative makes, checked against a numeric one. If these ever
			-- disagree, the hull is being tilted to match water it is not sitting on.
			local step = 1e-4
			for _, sample in { { 0, 0, 0 }, { 137, -42, 9.5 }, { -800, 620, 31.25 } } do
				local x, z, now = sample[1], sample[2], sample[3]
				local _, slopeX, slopeZ = BoatWaterMath.Swell(x, z, now)

				local aheadX = BoatWaterMath.Swell(x + step, z, now)
				local behindX = BoatWaterMath.Swell(x - step, z, now)
				expect(slopeX).to.be.near((aheadX - behindX) / (2 * step), 1e-5)

				local aheadZ = BoatWaterMath.Swell(x, z + step, now)
				local behindZ = BoatWaterMath.Swell(x, z - step, now)
				expect(slopeZ).to.be.near((aheadZ - behindZ) / (2 * step), 1e-5)
			end
		end)
	end)

	describe("Sample", function()
		it("reports Supported = false and a deliberately useless height with no water under it", function()
			local sample = BoatWaterMath.Sample({}, Vector3.new(300, 0, 300), 0)
			expect(sample.Supported).to.equal(false)
			-- 0 rather than a plausible sea level, so a caller that forgets the flag gets an obviously
			-- wrong answer at the origin instead of a subtly wrong one over a mountain.
			expect(sample.SurfaceY).to.equal(0)
		end)

		it("adds the swell onto the plane's own top face", function()
			local planes = { plane(Vector3.new(0, 50, 0), Vector3.new(400, 4, 400)) }
			local sample = BoatWaterMath.Sample(planes, Vector3.new(10, 0, 20), 3.5)
			local swell = BoatWaterMath.Swell(10, 20, 3.5)
			expect(sample.Supported).to.equal(true)
			expect(sample.SurfaceY).to.be.near(52 + swell, 1e-9)
		end)
	end)

	describe("TiltFor", function()
		local FORWARD = Vector3.new(0, 0, -1)
		local RIGHT = Vector3.new(1, 0, 0)

		it("lifts the bow when the water ahead of her is higher", function()
			-- Forward is world -Z, so water rising toward -Z is a NEGATIVE dY/dZ.
			local pitch = BoatWaterMath.TiltFor(0, -1, FORWARD, RIGHT)
			expect(pitch > 0).to.equal(true)
		end)

		it("drops the bow when the water ahead of her is lower", function()
			local pitch = BoatWaterMath.TiltFor(0, 1, FORWARD, RIGHT)
			expect(pitch < 0).to.equal(true)
		end)

		it("lifts the starboard side when the water to starboard is higher", function()
			-- Starboard is world +X, so water rising toward +X is a POSITIVE dY/dX, and a positive roll
			-- about the local Z lifts starboard.
			local _, roll = BoatWaterMath.TiltFor(1, 0, FORWARD, RIGHT)
			expect(roll > 0).to.equal(true)
		end)

		it("lies flat on flat water", function()
			local pitch, roll = BoatWaterMath.TiltFor(0, 0, FORWARD, RIGHT)
			expect(pitch).to.equal(0)
			expect(roll).to.equal(0)
		end)

		it("never exceeds its authored ceiling, however steep the water", function()
			local pitch, roll = BoatWaterMath.TiltFor(500, -500, FORWARD, RIGHT)
			expect(math.abs(pitch) <= BoatConstants.Swell.MaxTiltRadians + 1e-9).to.equal(true)
			expect(math.abs(roll) <= BoatConstants.Swell.MaxTiltRadians + 1e-9).to.equal(true)
		end)

		it("follows the water less than exactly -- a hull with a keel is not a raft", function()
			expect(BoatConstants.Swell.TiltPerSlope < 1).to.equal(true)
			expect(BoatConstants.Swell.TiltPerSlope > 0).to.equal(true)
		end)
	end)
end
