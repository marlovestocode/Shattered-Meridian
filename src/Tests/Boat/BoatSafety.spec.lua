--!strict
-- Covers the Boat layer's two velocity ceilings as POLICY, not as arithmetic -- the arithmetic is
-- Shared/Vessel/VesselSafety.ClampSpeed's and is pinned by src/Tests/Vessel/VesselSafety.spec.lua.
--
-- WHAT THIS FILE IS ACTUALLY FOR is the first block: there are now THREE copies of one number in this
-- codebase -- ParkourConstants.Validation.MaxTravelSpeed, BlimpConstants.Safety.MaxContactSpeed and
-- BoatConstants.Safety.MaxContactSpeed -- and all three are the same authored answer to "the fastest a
-- player's velocity could plausibly, legitimately be". Three copies is worse than one, and a
-- cross-require from a standalone vehicle module into Parkour's constants is worse still (see
-- BlimpConstants.Safety.MaxContactSpeed's own header on why it is a literal). This assertion is what
-- makes the copies safe: a retune of any one of them fails here until somebody has looked at the others.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local VesselSafety = require(ReplicatedStorage.Shared.Vessel.VesselSafety)

return function()
	describe("MaxContactSpeed", function()
		it("is the same number all three places it is written down", function()
			expect(BoatConstants.Safety.MaxContactSpeed).to.equal(ParkourConstants.Validation.MaxTravelSpeed)
			expect(BoatConstants.Safety.MaxContactSpeed).to.equal(BlimpConstants.Safety.MaxContactSpeed)
		end)

		it("sits above everything a boat can legitimately do to a body touching her", function()
			-- The clamp is an anti-exploit backstop, not a speed limit on the vehicle. If it ever dropped
			-- below what the hull itself can move at, it would start trimming honest velocity off players
			-- standing on a deck that is simply going fast.
			expect(BoatConstants.Safety.MaxContactSpeed > BoatConstants.Drive.HullSpeed).to.equal(true)
			expect(BoatConstants.Safety.MaxContactSpeed > BoatConstants.Physics.MaxDriveVelocity).to.equal(true)
		end)
	end)

	-- The RELEASE clamp, which is a different clamp with a different job -- see
	-- BoatConstants.Mount.ReleaseSpeedMargin and Server/Vessel/VesselMount.ReleaseSpeedCeiling. It runs
	-- on a body that has just STOPPED being part of a hull, and its ceiling is relative to the hull
	-- rather than absolute. What is pinned here is the POLICY, which is the part a future retune could
	-- quietly get wrong. The ceiling is restated as a local rather than reached for through VesselMount,
	-- which needs live Instances to bind at all.
	describe("the release ceiling", function()
		local function ceiling(hullSpeed: number): number
			return hullSpeed + BoatConstants.Mount.ReleaseSpeedMargin
		end

		it("lets a body leaving a boat under way keep the hull's own velocity, untouched", function()
			-- THE load-bearing property, and the reason the ceiling is relative instead of flat. A
			-- passenger who steps off at speed carrying exactly the ship's velocity lands back on her deck
			-- and walks. Trim them to some pedestrian absolute and they are instantly a hull-speed slower
			-- than the deck they are standing over, and the moving hull sweeps into them.
			local hullVelocity = Vector3.new(BoatConstants.Drive.HullSpeed, 0, 0)
			expect(VesselSafety.ClampSpeed(hullVelocity, ceiling(hullVelocity.Magnitude))).to.equal(hullVelocity)
		end)

		it("trims the lever-arm excess a station far from the hull's centre contributes", function()
			-- omega x r: a station forty studs forward of a yawing hull's centre separates carrying the
			-- hull's velocity PLUS a tangential term unbounded in a radius no constant knows about.
			local hullSpeed = BoatConstants.Drive.HullSpeed
			local carried = Vector3.new(hullSpeed, 0, 0) + Vector3.new(0, 0, 400)
			local clamped = VesselSafety.ClampSpeed(carried, ceiling(hullSpeed))
			expect(clamped.Magnitude).to.be.near(ceiling(hullSpeed), 1e-3)
			expect(clamped.Magnitude < carried.Magnitude).to.equal(true)
		end)

		it("holds a body leaving a moored boat to the margin alone", function()
			local clamped = VesselSafety.ClampSpeed(Vector3.new(0, 300, 0), ceiling(0))
			expect(clamped.Magnitude).to.be.near(BoatConstants.Mount.ReleaseSpeedMargin, 1e-3)
		end)

		it("leaves an honest self-propelled jump off a moored boat alone", function()
			expect(BoatConstants.Mount.ReleaseSpeedMargin > ParkourConstants.Locomotion.WalkSpeed).to.equal(true)
		end)

		it("is the TIGHTER of the two clamps, so it is not dead code", function()
			-- If the margin ever grew past MaxContactSpeed the release clamp would never bind -- the wide
			-- contact ceiling would already have trimmed everything this one would.
			expect(BoatConstants.Mount.ReleaseSpeedMargin < BoatConstants.Safety.MaxContactSpeed).to.equal(true)
		end)
	end)
end
