--!strict
-- Covers Shared/HitboxEngine/HitboxGeometry.lua -- the pure shape math behind the hitbox engine.
--
-- No character, no Workspace, no engine state: every case here is a point and a volume. That is the
-- point of the module being pure, and a case in this file that needed a rig would be evidence the
-- purity had been lost.
--
-- The swept-containment cases at the bottom are the ones that matter most. They are the only place
-- the anti-tunnelling guarantee is pinned as arithmetic rather than as an emergent property of a
-- running engine, so a regression that quietly reduced the sweep to a single instantaneous test
-- would fail here loudly and nowhere else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

type Dimensions = HitboxTypes.Dimensions

-- Starts from the sanitiser's defaults and overrides only what a case cares about, so a shape's
-- unused fields never have to be spelled out and a new field added to Dimensions doesn't break
-- every case in this file.
local function dims(overrides: { [string]: number }): Dimensions
	local result = HitboxTypes.DefaultDimensions()
	for key, value in overrides do
		(result :: any)[key] = value
	end
	return result
end

return function()
	describe("HitboxGeometry.ContainsPoint -- Box", function()
		local box = dims({ Width = 4, Height = 6, Length = 8 })

		it("contains its own origin", function()
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.zero, 0)).to.equal(true)
		end)

		it("contains a point just inside each half-extent", function()
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(1.9, 2.9, 3.9), 0)).to.equal(true)
		end)

		it("rejects a point past a half-extent on any single axis", function()
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(2.1, 0, 0), 0)).to.equal(false)
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(0, 3.1, 0), 0)).to.equal(false)
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(0, 0, 4.1), 0)).to.equal(false)
		end)

		it("straddles the origin -- it reaches backward as far as forward", function()
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(0, 0, 3.9), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(0, 0, -3.9), 0)).to.equal(true)
		end)

		it("admits a point the margin brings inside", function()
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(2.4, 0, 0), 0)).to.equal(false)
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(2.4, 0, 0), 0.5)).to.equal(true)
		end)

		it("treats a negative margin as zero rather than shrinking the volume", function()
			expect(HitboxGeometry.ContainsPoint("Box", box, Vector3.new(1.9, 0, 0), -5)).to.equal(true)
		end)
	end)

	describe("HitboxGeometry.ContainsPoint -- Sphere", function()
		local sphere = dims({ Radius = 5 })

		it("contains a point inside the radius in any direction", function()
			expect(HitboxGeometry.ContainsPoint("Sphere", sphere, Vector3.new(0, 0, -4.9), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Sphere", sphere, Vector3.new(0, 4.9, 0), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Sphere", sphere, Vector3.new(-4.9, 0, 0), 0)).to.equal(true)
		end)

		it("rejects a point outside the radius", function()
			expect(HitboxGeometry.ContainsPoint("Sphere", sphere, Vector3.new(3, 3, 3), 0)).to.equal(false)
		end)
	end)

	describe("HitboxGeometry.ContainsPoint -- Capsule", function()
		-- Length is the segment BETWEEN the cap centres, so the total forward extent is 5 + 2 = 7.
		local capsule = dims({ Radius = 2, Length = 10 })

		it("contains a point beside the middle of the axis", function()
			expect(HitboxGeometry.ContainsPoint("Capsule", capsule, Vector3.new(1.9, 0, 0), 0)).to.equal(true)
		end)

		it("rounds off at the ends rather than squaring off", function()
			-- Directly on the axis, past the segment but within a cap radius.
			expect(HitboxGeometry.ContainsPoint("Capsule", capsule, Vector3.new(0, 0, 6.9), 0)).to.equal(true)
			-- The same distance along the axis but offset sideways falls outside the sphere cap, which
			-- a Cylinder of the same figures would have contained.
			expect(HitboxGeometry.ContainsPoint("Capsule", capsule, Vector3.new(1.9, 0, 6.9), 0)).to.equal(false)
		end)
	end)

	describe("HitboxGeometry.ContainsPoint -- Cylinder", function()
		local cylinder = dims({ Radius = 3, Length = 10 })

		it("squares off at the ends", function()
			expect(HitboxGeometry.ContainsPoint("Cylinder", cylinder, Vector3.new(2.9, 0, 4.9), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Cylinder", cylinder, Vector3.new(2.9, 0, 5.1), 0)).to.equal(false)
		end)

		it("rejects a point outside the radius anywhere along the axis", function()
			expect(HitboxGeometry.ContainsPoint("Cylinder", cylinder, Vector3.new(3.1, 0, 0), 0)).to.equal(false)
		end)
	end)

	describe("HitboxGeometry.ContainsPoint -- Cone", function()
		-- A reach shape: the apex is the ORIGIN and it grows forward along -Z. AngleDegrees is the full
		-- apex angle, so a 90 degree cone opens 45 degrees off the axis and its base radius equals its
		-- length.
		local cone = dims({ Length = 10, AngleDegrees = 90 })

		it("is a point at its apex and wide at its base", function()
			expect(HitboxGeometry.ContainsPoint("Cone", cone, Vector3.new(0, 0, 0), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Cone", cone, Vector3.new(1, 0, -0.5), 0)).to.equal(false)
			expect(HitboxGeometry.ContainsPoint("Cone", cone, Vector3.new(1, 0, -9), 0)).to.equal(true)
		end)

		it("grows forward only -- a point behind the apex is never inside", function()
			expect(HitboxGeometry.ContainsPoint("Cone", cone, Vector3.new(0, 0, 5), 0)).to.equal(false)
		end)

		it("stops at its length", function()
			expect(HitboxGeometry.ContainsPoint("Cone", cone, Vector3.new(0, 0, -9.9), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Cone", cone, Vector3.new(0, 0, -10.1), 0)).to.equal(false)
		end)
	end)

	describe("HitboxGeometry.ContainsPoint -- Beam", function()
		local beam = dims({ Radius = 2, Length = 20 })

		it("keeps a constant cross-section along its whole length", function()
			expect(HitboxGeometry.ContainsPoint("Beam", beam, Vector3.new(1.9, 0, -0.5), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Beam", beam, Vector3.new(1.9, 0, -19.5), 0)).to.equal(true)
		end)

		it("grows forward only", function()
			expect(HitboxGeometry.ContainsPoint("Beam", beam, Vector3.new(0, 0, 1), 0)).to.equal(false)
		end)
	end)

	describe("HitboxGeometry.ContainsPoint -- Arc", function()
		-- A horizontal annulus sector: radial distance is measured in XZ, thickness is along Y, and the
		-- sector is centred on straight ahead (-Z).
		local arc = dims({ Radius = 10, InnerRadius = 4, Height = 4, AngleDegrees = 90 })

		it("contains a point dead ahead within the ring", function()
			expect(HitboxGeometry.ContainsPoint("Arc", arc, Vector3.new(0, 0, -7), 0)).to.equal(true)
		end)

		it("excludes the hub inside InnerRadius", function()
			expect(HitboxGeometry.ContainsPoint("Arc", arc, Vector3.new(0, 0, -2), 0)).to.equal(false)
		end)

		it("excludes anything past the outer radius", function()
			expect(HitboxGeometry.ContainsPoint("Arc", arc, Vector3.new(0, 0, -11), 0)).to.equal(false)
		end)

		it("excludes a point outside the swept bearing", function()
			-- 90 degrees means +-45 off straight ahead. Directly to the right is 90 degrees off.
			expect(HitboxGeometry.ContainsPoint("Arc", arc, Vector3.new(7, 0, 0), 0)).to.equal(false)
			-- Just inside 45 degrees off-axis, at the same radius.
			expect(HitboxGeometry.ContainsPoint("Arc", arc, Vector3.new(4.5, 0, -5), 0)).to.equal(true)
		end)

		it("excludes a point above or below its height", function()
			expect(HitboxGeometry.ContainsPoint("Arc", arc, Vector3.new(0, 3, -7), 0)).to.equal(false)
		end)

		it("becomes a full ring at 360 degrees", function()
			local ring = dims({ Radius = 10, InnerRadius = 4, Height = 4, AngleDegrees = 360 })
			expect(HitboxGeometry.ContainsPoint("Arc", ring, Vector3.new(0, 0, 7), 0)).to.equal(true)
			expect(HitboxGeometry.ContainsPoint("Arc", ring, Vector3.new(7, 0, 0), 0)).to.equal(true)
		end)
	end)

	describe("HitboxGeometry.BoundingBox", function()
		it("returns a centred box for centred shapes", function()
			local size, centre = HitboxGeometry.BoundingBox("Box", dims({ Width = 4, Height = 6, Length = 8 }))
			expect(size).to.equal(Vector3.new(4, 6, 8))
			expect(centre).to.equal(CFrame.identity)
		end)

		it("offsets the box forward for reach shapes, so it covers what they actually occupy", function()
			local size, centre = HitboxGeometry.BoundingBox("Beam", dims({ Radius = 2, Length = 20 }))
			expect(size).to.equal(Vector3.new(4, 4, 20))
			expect(centre.Position.Z).to.equal(-10)
		end)

		it("encloses a capsule's caps as well as its segment", function()
			local size = HitboxGeometry.BoundingBox("Capsule", dims({ Radius = 2, Length = 10 }))
			expect(size).to.equal(Vector3.new(4, 4, 14))
		end)

		it("uses the full ring for an Arc, since a box cannot express a sector", function()
			local size = HitboxGeometry.BoundingBox("Arc", dims({ Radius = 10, Height = 4, AngleDegrees = 45 }))
			expect(size).to.equal(Vector3.new(20, 4, 20))
		end)
	end)

	describe("HitboxGeometry.Reach", function()
		it("measures forward extent, which differs between centred and reach shapes", function()
			expect(HitboxGeometry.Reach("Box", dims({ Length = 8 }))).to.equal(4)
			expect(HitboxGeometry.Reach("Beam", dims({ Length = 8 }))).to.equal(8)
			expect(HitboxGeometry.Reach("Cone", dims({ Length = 8 }))).to.equal(8)
			expect(HitboxGeometry.Reach("Sphere", dims({ Radius = 5 }))).to.equal(5)
			expect(HitboxGeometry.Reach("Capsule", dims({ Radius = 2, Length = 10 }))).to.equal(7)
		end)
	end)

	describe("HitboxGeometry.MinExtent", function()
		it("finds the thinnest axis, which is what sizes the swept step count", function()
			expect(HitboxGeometry.MinExtent("Box", dims({ Width = 4, Height = 6, Length = 0.5 }))).to.equal(0.5)
			expect(HitboxGeometry.MinExtent("Sphere", dims({ Radius = 3 }))).to.equal(6)
			expect(HitboxGeometry.MinExtent("Arc", dims({ Radius = 10, InnerRadius = 8, Height = 4 }))).to.equal(2)
		end)

		it("never returns zero, so it is always safe as a divisor", function()
			expect(HitboxGeometry.MinExtent("Box", dims({ Width = 0, Height = 0, Length = 0 })) > 0).to.equal(true)
		end)
	end)

	describe("HitboxGeometry.ScaleDimensions", function()
		it("scales every linear measurement", function()
			local out = HitboxTypes.DefaultDimensions()
			HitboxGeometry.ScaleDimensions(dims({ Width = 2, Height = 3, Length = 4, Radius = 5 }), 3, out)
			expect(out.Width).to.equal(6)
			expect(out.Height).to.equal(9)
			expect(out.Length).to.equal(12)
			expect(out.Radius).to.equal(15)
		end)

		it("leaves AngleDegrees alone -- an angle is not a length", function()
			local out = HitboxTypes.DefaultDimensions()
			HitboxGeometry.ScaleDimensions(dims({ AngleDegrees = 60 }), 4, out)
			expect(out.AngleDegrees).to.equal(60)
		end)
	end)

	describe("HitboxGeometry.SweptSteps", function()
		local thin = dims({ Width = 1, Height = 4, Length = 1 })

		it("is 1 when nothing moved -- a stationary hitbox pays nothing for the sweep", function()
			local pose = CFrame.new(0, 0, 0)
			expect(HitboxGeometry.SweptSteps("Box", thin, pose, thin, pose, 0)).to.equal(1)
		end)

		it("rises with distance travelled relative to the shape's own thinnest axis", function()
			local start = CFrame.new(0, 0, 0)
			local finish = CFrame.new(6, 0, 0)
			expect(HitboxGeometry.SweptSteps("Box", thin, start, thin, finish, 0) > 1).to.equal(true)
		end)

		it("counts ROTATION as travel, even with the origin perfectly still", function()
			-- A swing pivoting on a stationary root is most of melee. A translation-only estimate would
			-- size this sweep at one step and tunnel straight through anything the far edge passed.
			local start = CFrame.new(0, 0, 0)
			local spun = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(120), 0)
			local long = dims({ Width = 1, Height = 4, Length = 12 })
			expect(HitboxGeometry.SweptSteps("Box", long, start, long, spun, 0) > 1).to.equal(true)
		end)

		it("stays bounded no matter how absurd the jump", function()
			local start = CFrame.new(0, 0, 0)
			local finish = CFrame.new(10000, 0, 0)
			expect(HitboxGeometry.SweptSteps("Box", thin, start, thin, finish, 0) <= 8).to.equal(true)
		end)
	end)

	describe("HitboxGeometry.SweptContainsPoint", function()
		-- A deliberately thin volume, so the gap between two sampled poses is wide enough to hide a
		-- target -- which is exactly the real-world case (a fist-sized hitbox on a fast arm).
		local thin = dims({ Width = 2, Height = 4, Length = 2 })

		it("catches a point the volume passed straight over between two samples", function()
			local start = CFrame.new(-5, 0, 0)
			local finish = CFrame.new(5, 0, 0)
			local point = Vector3.zero

			-- Neither endpoint contains it: at the start the point is 5 studs to the right of a volume
			-- 1 stud wide, at the end 5 studs to the left. A per-frame hitbox reports nothing here, and
			-- the player watches the swing pass through them.
			expect(HitboxGeometry.ContainsPoint("Box", thin, start:PointToObjectSpace(point), 0)).to.equal(false)
			expect(HitboxGeometry.ContainsPoint("Box", thin, finish:PointToObjectSpace(point), 0)).to.equal(false)

			expect(HitboxGeometry.SweptContainsPoint("Box", thin, start, thin, finish, point, 0)).to.equal(true)
		end)

		it("still rejects a point the volume never passed over", function()
			local start = CFrame.new(-5, 0, 0)
			local finish = CFrame.new(5, 0, 0)
			-- Well off the line of travel: swept containment must not degrade into "anywhere near the
			-- path," or every hitbox silently becomes a capsule the length of the swing.
			expect(HitboxGeometry.SweptContainsPoint("Box", thin, start, thin, finish, Vector3.new(0, 0, 20), 0)).to.equal(
				false
			)
			expect(HitboxGeometry.SweptContainsPoint("Box", thin, start, thin, finish, Vector3.new(0, 30, 0), 0)).to.equal(
				false
			)
		end)

		it("agrees with the instantaneous test when the poses are identical", function()
			local pose = CFrame.new(0, 0, 0)
			expect(HitboxGeometry.SweptContainsPoint("Box", thin, pose, thin, pose, Vector3.zero, 0)).to.equal(true)
			expect(HitboxGeometry.SweptContainsPoint("Box", thin, pose, thin, pose, Vector3.new(50, 0, 0), 0)).to.equal(
				false
			)
		end)

		it("catches a point swept over by ROTATION alone", function()
			-- Origin never moves; the volume's far end whips through the point. This is the case a
			-- translation-only sweep gets wrong, and it is the commonest melee swing there is.
			local reach = dims({ Width = 2, Height = 4, Length = 20 })
			local start = CFrame.Angles(0, math.rad(-60), 0)
			local finish = CFrame.Angles(0, math.rad(60), 0)
			local point = Vector3.new(0, 0, -8)

			expect(HitboxGeometry.ContainsPoint("Box", reach, start:PointToObjectSpace(point), 0)).to.equal(false)
			expect(HitboxGeometry.ContainsPoint("Box", reach, finish:PointToObjectSpace(point), 0)).to.equal(false)

			expect(HitboxGeometry.SweptContainsPoint("Box", reach, start, reach, finish, point, 0)).to.equal(true)
		end)

		it("tests the size the volume had at the START of the interval, not only at the end", function()
			-- A shrinking volume, standing still. The point is well outside the final size but inside
			-- the initial one, so the only way to find it is to actually test the interpolated
			-- dimensions rather than reusing the end sample's for the whole sweep. This is the size
			-- equivalent of the tunnelling case above, and it is what stops a charge attack that is
			-- released (and so snaps back to base size) from dropping the contact it already had.
			local small = dims({ Width = 1, Height = 1, Length = 1 })
			local large = dims({ Width = 40, Height = 40, Length = 40 })
			local pose = CFrame.new(0, 0, 0)

			expect(HitboxGeometry.ContainsPoint("Box", small, pose:PointToObjectSpace(Vector3.new(15, 0, 0)), 0)).to.equal(
				false
			)
			expect(HitboxGeometry.SweptContainsPoint("Box", large, pose, small, pose, Vector3.new(15, 0, 0), 0)).to.equal(
				true
			)
			expect(HitboxGeometry.SweptContainsPoint("Box", small, pose, small, pose, Vector3.new(15, 0, 0), 0)).to.equal(
				false
			)
		end)
	end)
end
