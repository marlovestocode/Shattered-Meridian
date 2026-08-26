--!strict
-- Covers Server/Blimp/BlimpSafety.lua -- the pure arithmetic behind the player-contact velocity
-- clamp. See that file's own header for why this exists separately from BlimpDrive.ClampLead: this
-- one bounds a PLAYER'S speed while they touch a hull, not the hull's own.
--
-- What is NOT covered here, and cannot be: whether Touched/TouchEnded actually fires, whether a
-- welded pilot is correctly excluded, whether the clamp actually reaches a live
-- AssemblyLinearVelocity. Those need real Instances and are exercised by playing the game -- the
-- same split every other Blimp spec in this folder already draws.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpSafety = require(ServerScriptService.Server.Blimp.BlimpSafety)

return function()
	describe("ClampSpeed", function()
		it("passes a velocity back unchanged when it is already within the bound", function()
			local velocity = Vector3.new(50, 0, 0)
			local clamped = BlimpSafety.ClampSpeed(velocity, 180)
			-- Same value, not merely an equal one -- the caller uses this identity to decide whether it
			-- has anything to write back onto a live character's AssemblyLinearVelocity at all.
			expect(clamped).to.equal(velocity)
		end)

		it("passes a velocity back unchanged exactly at the bound", function()
			local velocity = Vector3.new(180, 0, 0)
			local clamped = BlimpSafety.ClampSpeed(velocity, 180)
			expect(clamped).to.equal(velocity)
		end)

		it("scales an over-limit velocity down to exactly the bound", function()
			local velocity = Vector3.new(0, 0, -900)
			local clamped = BlimpSafety.ClampSpeed(velocity, 180)
			expect(math.abs(clamped.Magnitude - 180) < 1e-4).to.equal(true)
		end)

		it("preserves direction exactly -- scaled, never zeroed", function()
			local direction = Vector3.new(3, 4, 0).Unit -- an easy 3-4-5 triangle, magnitude 5
			local velocity = direction * 500
			local clamped = BlimpSafety.ClampSpeed(velocity, 180)
			expect((clamped.Unit - direction).Magnitude < 1e-4).to.equal(true)
			expect(math.abs(clamped.Magnitude - 180) < 1e-4).to.equal(true)
		end)

		it("clamps a velocity in any direction, not just along a world axis", function()
			local velocity = Vector3.new(120, 200, -300)
			local clamped = BlimpSafety.ClampSpeed(velocity, 180)
			expect(math.abs(clamped.Magnitude - 180) < 1e-3).to.equal(true)
			-- Still parallel to the original -- the ratio between any two components is unchanged.
			expect(math.abs(clamped.X / clamped.Y - velocity.X / velocity.Y) < 1e-3).to.equal(true)
		end)

		it("treats the zero vector as already within any non-negative bound", function()
			local velocity = Vector3.new(0, 0, 0)
			local clamped = BlimpSafety.ClampSpeed(velocity, 180)
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
end
