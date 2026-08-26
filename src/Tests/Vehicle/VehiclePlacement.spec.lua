--!strict
-- Covers Server/Vehicles/VehiclePlacement.lua -- the arithmetic that decides where a hull actually
-- materialises. Every function under test is pure, so nothing here builds an Instance.
--
-- The case that matters most is "a big hull spawned in front of you". The bug this file exists to
-- prevent is the one every other spawn-near-me dev action in this codebase would have had if it were
-- pointed at an airship: a fixed offset does not put a 200-stud hull in front of the requester, it
-- puts it around them, and the physics solver resolves that by throwing somebody.

local ServerScriptService = game:GetService("ServerScriptService")

local VehiclePlacement = require(ServerScriptService.Server.Vehicles.VehiclePlacement)

-- Studs of slack allowed when comparing two positions. Generous relative to the quantities being
-- checked (tens of studs) and far tighter than any error the tests are actually looking for.
local EPSILON = 1e-3

return function()
	describe("HorizontalRadius", function()
		it("ignores height entirely", function()
			local flat = VehiclePlacement.HorizontalRadius(Vector3.new(30, 4, 40))
			local tall = VehiclePlacement.HorizontalRadius(Vector3.new(30, 400, 40))
			expect(math.abs(flat - tall) < EPSILON).to.equal(true)
		end)

		it("contains the footprint at any yaw", function()
			-- Half the diagonal of a 30x40 footprint is 25, which is larger than half of either side
			-- (15 and 20) -- i.e. the circumscribing circle, which is the whole point.
			expect(math.abs(VehiclePlacement.HorizontalRadius(Vector3.new(30, 1, 40)) - 25) < EPSILON).to.equal(true)
		end)
	end)

	describe("FlattenYaw", function()
		it("discards pitch while keeping the heading", function()
			local pitched = CFrame.new(Vector3.new(10, 20, 30)) * CFrame.Angles(math.rad(-40), math.rad(90), 0)
			local flat = VehiclePlacement.FlattenYaw(pitched)

			expect(math.abs(flat.LookVector.Y) < EPSILON).to.equal(true)
			expect((flat.Position - pitched.Position).Magnitude < EPSILON).to.equal(true)

			-- The compass heading survives: both look the same way once flattened.
			local wantedHeading = Vector3.new(pitched.LookVector.X, 0, pitched.LookVector.Z).Unit
			expect((flat.LookVector - wantedHeading).Magnitude < EPSILON).to.equal(true)
		end)

		it("returns the original for a straight-down look, rather than inventing a heading", function()
			local straightDown = CFrame.lookAt(Vector3.new(0, 50, 0), Vector3.new(0, 0, 0))
			local flat = VehiclePlacement.FlattenYaw(straightDown)
			expect((flat.LookVector - straightDown.LookVector).Magnitude < EPSILON).to.equal(true)
		end)
	end)

	describe("InFrontOf", function()
		it("clears a large hull by its own radius plus the gap", function()
			local origin = CFrame.new(0, 5, 0)
			local size = Vector3.new(60, 40, 200)
			local gap = 12

			local pivot = VehiclePlacement.InFrontOf(origin, size, gap)
			local distance = (pivot.Position - origin.Position).Magnitude
			local wanted = VehiclePlacement.HorizontalRadius(size) + gap

			expect(math.abs(distance - wanted) < EPSILON).to.equal(true)
			-- The nearest possible point of the hull is still `gap` clear of the requester, which is
			-- the property that actually matters and the one a fixed offset breaks.
			expect(distance - VehiclePlacement.HorizontalRadius(size) >= gap - EPSILON).to.equal(true)
		end)

		it("scales the offset with the hull rather than using a fixed distance", function()
			local origin = CFrame.new(0, 5, 0)
			local small = VehiclePlacement.InFrontOf(origin, Vector3.new(4, 4, 4), 12)
			local large = VehiclePlacement.InFrontOf(origin, Vector3.new(60, 40, 200), 12)

			local smallDistance = (small.Position - origin.Position).Magnitude
			local largeDistance = (large.Position - origin.Position).Magnitude
			expect(largeDistance > smallDistance * 5).to.equal(true)
		end)

		it("places the hull along the requester's heading and facing the same way", function()
			-- Facing world +X, so the hull belongs at +X and must also look at +X.
			local origin = CFrame.lookAt(Vector3.new(0, 5, 0), Vector3.new(1, 5, 0))
			local pivot = VehiclePlacement.InFrontOf(origin, Vector3.new(10, 10, 10), 12)

			expect(pivot.Position.X > 0).to.equal(true)
			expect(math.abs(pivot.Position.Z) < EPSILON).to.equal(true)
			expect((pivot.LookVector - Vector3.new(1, 0, 0)).Magnitude < EPSILON).to.equal(true)
		end)

		it("does not inherit the requester's camera pitch", function()
			local lookingUp = CFrame.new(Vector3.new(0, 5, 0)) * CFrame.Angles(math.rad(45), 0, 0)
			local pivot = VehiclePlacement.InFrontOf(lookingUp, Vector3.new(60, 40, 200), 12)

			expect(math.abs(pivot.LookVector.Y) < EPSILON).to.equal(true)
			-- And it stays at the requester's own altitude rather than being flung into the sky by
			-- however far they happened to be looking up.
			expect(math.abs(pivot.Position.Y - 5) < EPSILON).to.equal(true)
		end)
	end)

	describe("SeatOnGround", function()
		it("puts the hull's underside at the clearance, not its pivot", function()
			local size = Vector3.new(60, 40, 200)
			local seated = VehiclePlacement.SeatOnGround(CFrame.new(0, 999, 0), size, 100, 4)

			-- The bottom of the bounding box, which is the pivot minus half the height.
			local underside = seated.Position.Y - size.Y * 0.5
			expect(math.abs(underside - 104) < EPSILON).to.equal(true)
		end)

		it("moves only the height", function()
			local original = CFrame.lookAt(Vector3.new(12, 999, -34), Vector3.new(13, 999, -34))
			local seated = VehiclePlacement.SeatOnGround(original, Vector3.new(10, 10, 10), 0, 4)

			expect(math.abs(seated.Position.X - 12) < EPSILON).to.equal(true)
			expect(math.abs(seated.Position.Z - -34) < EPSILON).to.equal(true)
			expect((seated.LookVector - original.LookVector).Magnitude < EPSILON).to.equal(true)
		end)
	end)

	describe("AtBerth", function()
		it("seats the hull on the pad's top face, not its centre", function()
			-- A pad 8 studs thick centred at y = 50, so its deck is at y = 54.
			local berthCFrame = CFrame.new(0, 50, 0)
			local berthSize = Vector3.new(80, 8, 80)
			local modelSize = Vector3.new(60, 40, 200)

			local pivot = VehiclePlacement.AtBerth(berthCFrame, berthSize, modelSize, 4)
			local underside = pivot.Position.Y - modelSize.Y * 0.5
			expect(math.abs(underside - 58) < EPSILON).to.equal(true)
		end)

		it("flattens a pad a builder left slightly tilted", function()
			local tilted = CFrame.new(0, 50, 0) * CFrame.Angles(math.rad(7), 0, math.rad(-3))
			local pivot = VehiclePlacement.AtBerth(tilted, Vector3.new(80, 8, 80), Vector3.new(10, 10, 10), 4)
			expect(math.abs(pivot.LookVector.Y) < EPSILON).to.equal(true)
		end)
	end)
end
