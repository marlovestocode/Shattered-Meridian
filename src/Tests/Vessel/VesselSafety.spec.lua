--!strict
-- Covers Shared/Vessel/VesselSafety.lua -- the pure arithmetic behind the player-contact velocity
-- clamp. See that file's own header for why this exists separately from BlimpDrive.ClampLead: this
-- one bounds a PLAYER'S speed while they touch a hull, not the hull's own.
--
-- What is NOT covered here, and cannot be: whether Touched/TouchEnded actually fires, whether a
-- welded pilot is correctly excluded, whether the clamp actually reaches a live
-- AssemblyLinearVelocity. Those need real Instances and are exercised by playing the game -- the
-- same split every vehicle spec in this codebase already draws.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local VesselSafety = require(ReplicatedStorage.Shared.Vessel.VesselSafety)

return function()
	describe("ClampSpeed", function()
		it("passes a velocity back unchanged when it is already within the bound", function()
			local velocity = Vector3.new(50, 0, 0)
			local clamped = VesselSafety.ClampSpeed(velocity, 180)
			-- Same value, not merely an equal one -- the caller uses this identity to decide whether it
			-- has anything to write back onto a live character's AssemblyLinearVelocity at all.
			expect(clamped).to.equal(velocity)
		end)

		it("passes a velocity back unchanged exactly at the bound", function()
			local velocity = Vector3.new(180, 0, 0)
			local clamped = VesselSafety.ClampSpeed(velocity, 180)
			expect(clamped).to.equal(velocity)
		end)

		it("scales an over-limit velocity down to exactly the bound", function()
			local velocity = Vector3.new(0, 0, -900)
			local clamped = VesselSafety.ClampSpeed(velocity, 180)
			expect(math.abs(clamped.Magnitude - 180) < 1e-4).to.equal(true)
		end)

		it("preserves direction exactly -- scaled, never zeroed", function()
			local direction = Vector3.new(3, 4, 0).Unit -- an easy 3-4-5 triangle, magnitude 5
			local velocity = direction * 500
			local clamped = VesselSafety.ClampSpeed(velocity, 180)
			expect((clamped.Unit - direction).Magnitude < 1e-4).to.equal(true)
			expect(math.abs(clamped.Magnitude - 180) < 1e-4).to.equal(true)
		end)

		it("clamps a velocity in any direction, not just along a world axis", function()
			local velocity = Vector3.new(120, 200, -300)
			local clamped = VesselSafety.ClampSpeed(velocity, 180)
			expect(math.abs(clamped.Magnitude - 180) < 1e-3).to.equal(true)
			-- Still parallel to the original -- the ratio between any two components is unchanged.
			expect(math.abs(clamped.X / clamped.Y - velocity.X / velocity.Y) < 1e-3).to.equal(true)
		end)

		it("treats the zero vector as already within any non-negative bound", function()
			local velocity = Vector3.new(0, 0, 0)
			local clamped = VesselSafety.ClampSpeed(velocity, 180)
			expect(clamped).to.equal(velocity)
		end)
	end)

	describe("BlimpConstants.Safety", function()
		it("keeps MaxContactSpeed generous relative to the hull's own top speeds", function()
			-- Must clear the fastest thing the hull itself can command, or a player standing near a
			-- blimp under nitrous would get clipped by their OWN vehicle's cruise -- an own-goal this
			-- constant exists to avoid, not cause.
			local safety = BlimpConstants.Safety
			local drive = BlimpConstants.Drive
			local physics = BlimpConstants.Physics
			expect(safety.MaxContactSpeed > drive.CruiseSpeed).to.equal(true)
			expect(safety.MaxContactSpeed > drive.NitrousSpeed).to.equal(true)
			expect(safety.MaxContactSpeed > physics.MaxDriveVelocity).to.equal(true)
		end)

		it("is pinned to ParkourConstants.Validation.MaxTravelSpeed, not a silently drifted copy", function()
			-- See BlimpConstants.Safety.MaxContactSpeed's own header: this is deliberately the SAME
			-- number as this codebase's own authored ceiling for "the fastest a player's velocity could
			-- plausibly, legitimately be" -- reused rather than reinvented so a retune of one is forced
			-- to look at the other instead of the two silently drifting apart.
			local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
			expect(BlimpConstants.Safety.MaxContactSpeed).to.equal(ParkourConstants.Validation.MaxTravelSpeed)
		end)
	end)

	-- The RELEASE clamp, which is a different clamp with a different job from the contact one above --
	-- see BlimpConstants.Mount.ReleaseSpeedMargin and BlimpSystem.applyReleaseVelocity. It runs on a
	-- body that has just STOPPED being part of a hull, and its ceiling is relative to the hull rather
	-- than absolute. The arithmetic is the same ClampSpeed; what is pinned here is the POLICY, which is
	-- the part a future retune could quietly get wrong.
	--
	-- The ceiling BlimpSystem.releaseSpeedCeiling computes, restated: hull speed plus the margin. Kept
	-- as a local here rather than reached for through BlimpSystem, which needs live Instances to build a
	-- hull at all -- see this file's header on the split every Blimp spec draws.
	describe("BlimpConstants.Mount release velocity", function()
		local function ceiling(hullSpeed: number): number
			return hullSpeed + BlimpConstants.Mount.ReleaseSpeedMargin
		end

		it("lets a body leaving a cruising hull keep the hull's own velocity, untouched", function()
			-- THE load-bearing property of the whole release clamp, and the reason the ceiling is
			-- relative instead of a flat number. A passenger who steps off at cruise carrying exactly the
			-- ship's velocity lands back on its deck and walks. Trim them to some pedestrian absolute and
			-- they are instantly CruiseSpeed slower than the deck they are standing over, and the moving
			-- hull sweeps into them -- which launches them harder than the inheritance ever did.
			local hullVelocity = Vector3.new(BlimpConstants.Drive.CruiseSpeed, 0, 0)
			local clamped = VesselSafety.ClampSpeed(hullVelocity, ceiling(hullVelocity.Magnitude))
			expect(clamped).to.equal(hullVelocity)
		end)

		it("passes the hull's velocity through at nitrous too, not just at cruise", function()
			local hullVelocity = Vector3.new(0, 0, -BlimpConstants.Drive.NitrousSpeed)
			local clamped = VesselSafety.ClampSpeed(hullVelocity, ceiling(hullVelocity.Magnitude))
			expect(clamped).to.equal(hullVelocity)
		end)

		it("trims the lever-arm excess a station far from the hull's centre contributes", function()
			-- omega x r: a station eighty studs down the gondola of a yawing hull separates carrying the
			-- hull's velocity PLUS a tangential term unbounded in a radius no constant knows about. That
			-- surplus is the part that is never legitimate, and it is the only part this removes.
			local hullSpeed = BlimpConstants.Drive.CruiseSpeed
			local carried = Vector3.new(hullSpeed, 0, 0) + Vector3.new(0, 0, 400)
			local clamped = VesselSafety.ClampSpeed(carried, ceiling(hullSpeed))
			expect(math.abs(clamped.Magnitude - ceiling(hullSpeed)) < 1e-3).to.equal(true)
			expect(clamped.Magnitude < carried.Magnitude).to.equal(true)
		end)

		it("holds a body leaving a stationary hull to the margin alone", function()
			-- A moored blimp contributes nothing, so the ceiling collapses to what a person could be
			-- doing under their own power -- which is the correct answer for stepping off something
			-- parked, and is what stops a hover dismount reading as a launch.
			local carried = Vector3.new(0, 300, 0)
			local clamped = VesselSafety.ClampSpeed(carried, ceiling(0))
			expect(math.abs(clamped.Magnitude - BlimpConstants.Mount.ReleaseSpeedMargin) < 1e-3).to.equal(true)
		end)

		it("leaves an honest self-propelled jump off a moored hull alone", function()
			-- The margin has to sit above what a player can legitimately be doing on their own legs, or
			-- a dash off the deck of a parked blimp gets clipped mid-move. See the constant's header.
			local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
			expect(BlimpConstants.Mount.ReleaseSpeedMargin > ParkourConstants.Locomotion.WalkSpeed).to.equal(true)
		end)

		it("is the TIGHTER of the two clamps, and only ever runs for a moment", function()
			-- The contact clamp is a wide anti-exploit ceiling that runs for as long as somebody leans on
			-- the hull; this is a narrow one that runs for a settle window. If the margin ever grew past
			-- MaxContactSpeed the release clamp would be dead code -- the wider one would already have
			-- caught everything it could.
			local mount = BlimpConstants.Mount
			expect(mount.ReleaseSpeedMargin > 0).to.equal(true)
			expect(mount.ReleaseSpeedMargin < BlimpConstants.Safety.MaxContactSpeed).to.equal(true)
			expect(mount.ReleaseSettleSeconds > 0).to.equal(true)
			-- A settle window for a separation impulse, not an ongoing leash on somebody who has walked
			-- away -- if this ever grew to seconds it would be clamping a player's own movement long
			-- after they left the ship.
			expect(mount.ReleaseSettleSeconds <= 2).to.equal(true)
		end)

		it("lifts the released body clear before handing it back", function()
			expect(BlimpConstants.Mount.ReleaseClearance > 0).to.equal(true)
		end)
	end)
end
