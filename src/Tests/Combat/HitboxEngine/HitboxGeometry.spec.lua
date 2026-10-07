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

	describe("HitboxGeometry.ContainsPoint -- the engine's second tier of shapes", function()
		local function inside(shape: string, d: Dimensions, x: number, y: number, z: number, margin: number?): boolean
			return HitboxGeometry.ContainsPoint(shape :: any, d, Vector3.new(x, y, z), margin or 0)
		end

		it("Ellipsoid is round in each axis at its own semi-axis, and rejects the corners a Box would hold", function()
			local ellipsoid = dims({ Width = 4, Height = 6, Length = 10 })
			expect(inside("Ellipsoid", ellipsoid, 0, 0, -4.9)).to.equal(true)
			expect(inside("Ellipsoid", ellipsoid, 1.9, 0, 0)).to.equal(true)
			expect(inside("Ellipsoid", ellipsoid, 0, 2.9, 0)).to.equal(true)
			expect(inside("Ellipsoid", ellipsoid, 0, 0, -5.1)).to.equal(false)
			-- The corner of its own bounding box is well outside it.
			expect(inside("Ellipsoid", ellipsoid, 1.9, 2.9, 4.9)).to.equal(false)
		end)

		it("Ellipsoid survives a zero axis without dividing by it", function()
			local flat = dims({ Width = 0, Height = 4, Length = 4 })
			expect(inside("Ellipsoid", flat, 0, 0, 0)).to.equal(true)
			expect(inside("Ellipsoid", flat, 1, 0, 0)).to.equal(false)
		end)

		it("Hemisphere is a dome: nothing behind its flat face, round in front of it", function()
			local dome = dims({ Radius = 6 })
			expect(inside("Hemisphere", dome, 0, 0, -5.9)).to.equal(true)
			expect(inside("Hemisphere", dome, 3, 3, -3)).to.equal(true)
			expect(inside("Hemisphere", dome, 0, 0, 0.5)).to.equal(false)
			expect(inside("Hemisphere", dome, 0, 0, -6.1)).to.equal(false)
			expect(inside("Hemisphere", dome, 5, 0, -5)).to.equal(false)
		end)

		it("Frustum is wide at its origin and widens (or narrows) to its far radius", function()
			local funnel = dims({ Radius = 6, InnerRadius = 2, Length = 10 })
			-- At the origin it is already InnerRadius wide...
			expect(inside("Frustum", funnel, 1.9, 0, -0.1)).to.equal(true)
			expect(inside("Frustum", funnel, 2.5, 0, -0.1)).to.equal(false)
			-- ...and Radius wide at Length.
			expect(inside("Frustum", funnel, 5.9, 0, -9.9)).to.equal(true)
			expect(inside("Frustum", funnel, 6.5, 0, -9.9)).to.equal(false)
			-- Halfway it is halfway between the two.
			expect(inside("Frustum", funnel, 3.9, 0, -5)).to.equal(true)
			expect(inside("Frustum", funnel, 4.2, 0, -5)).to.equal(false)
			expect(inside("Frustum", funnel, 0, 0, 1)).to.equal(false)
		end)

		it("Pyramid closes in on BOTH axes toward its apex; Wedge only sideways", function()
			local box = dims({ Width = 8, Height = 8, Length = 10 })
			-- Halfway along, each half-extent is half of the far face's.
			expect(inside("Pyramid", box, 1.9, 1.9, -5)).to.equal(true)
			expect(inside("Pyramid", box, 2.2, 0, -5)).to.equal(false)
			expect(inside("Pyramid", box, 0, 2.2, -5)).to.equal(false)
			expect(inside("Wedge", box, 2.2, 0, -5)).to.equal(false)
			-- A Wedge keeps its whole height all the way back to the apex edge; a Pyramid does not.
			expect(inside("Wedge", box, 0, 3.9, -1)).to.equal(true)
			expect(inside("Pyramid", box, 0, 3.9, -1)).to.equal(false)
			-- Both grow forward only.
			expect(inside("Pyramid", box, 0, 0, 1)).to.equal(false)
			expect(inside("Wedge", box, 0, 0, 1)).to.equal(false)
			expect(inside("Wedge", box, 3.9, 0, -9.9)).to.equal(true)
			expect(inside("Wedge", box, 0, 0, -10.5)).to.equal(false)
		end)

		it("Pillar stands upright: round in the ground plane, tall in Y", function()
			local pillar = dims({ Radius = 3, Height = 10 })
			expect(inside("Pillar", pillar, 2.9, 4.9, 0)).to.equal(true)
			expect(inside("Pillar", pillar, 0, 5.1, 0)).to.equal(false)
			expect(inside("Pillar", pillar, 2.2, 0, 2.2)).to.equal(false)
			-- Unlike a Cylinder it does not lie along the facing.
			expect(inside("Pillar", pillar, 0, 0, -6)).to.equal(false)
		end)

		it("Crescent is the outer disc minus a bite taken from behind -- thick ahead, hollow behind", function()
			local sickle = dims({ Radius = 8, InnerRadius = 7, Length = 3, Height = 4 })
			-- Dead ahead the rim is at -8 and the bite starts at 3 - 7 = -4: a thick front.
			expect(inside("Crescent", sickle, 0, 0, -6)).to.equal(true)
			-- Inside the bite.
			expect(inside("Crescent", sickle, 0, 0, 0)).to.equal(false)
			expect(inside("Crescent", sickle, 0, 0, 2)).to.equal(false)
			-- Past the outer rim.
			expect(inside("Crescent", sickle, 0, 0, -8.5)).to.equal(false)
			-- A horn trails back past the origin on the outer edge.
			expect(inside("Crescent", sickle, 7.5, 0, 1)).to.equal(true)
			expect(inside("Crescent", sickle, 0, 2.5, -6)).to.equal(false)
		end)

		it("a Crescent with no bite is a plain disc", function()
			local disc = dims({ Radius = 4, InnerRadius = 0, Length = 3, Height = 2 })
			expect(inside("Crescent", disc, 0, 0, 0)).to.equal(true)
			expect(inside("Crescent", disc, 3.9, 0, 0)).to.equal(true)
		end)

		it("Cross is two bars through the origin and leaves its corners empty", function()
			local cross = dims({ Width = 12, Length = 8, Height = 4, Radius = 1 })
			expect(inside("Cross", cross, 5.9, 0, 0.9)).to.equal(true)
			expect(inside("Cross", cross, 0.9, 0, 3.9)).to.equal(true)
			expect(inside("Cross", cross, 5, 0, 3)).to.equal(false)
			expect(inside("Cross", cross, 6.5, 0, 0)).to.equal(false)
			expect(inside("Cross", cross, 0, 2.5, 0)).to.equal(false)
		end)

		it("every new shape honours the margin by growing, never by shrinking", function()
			local d = dims({ Width = 4, Height = 4, Length = 4, Radius = 2, InnerRadius = 1, AngleDegrees = 90 })
			for _, shape in { "Ellipsoid", "Hemisphere", "Frustum", "Pyramid", "Wedge", "Crescent", "Cross", "Pillar" } do
				-- Whatever is inside at margin 0 is still inside at a positive one.
				for _, point in { Vector3.new(0, 0, -1), Vector3.new(0.5, 0.2, -1.5), Vector3.new(1, 0, -0.5) } do
					if HitboxGeometry.ContainsPoint(shape :: any, d, point, 0) then
						expect(HitboxGeometry.ContainsPoint(shape :: any, d, point, 0.75)).to.equal(true)
					end
				end
			end
		end)
	end)

	describe("HitboxGeometry -- every shape's bounding box actually bounds it", function()
		it("holds every contained sample point inside BoundingBox, for every shape", function()
			local d = dims({ Width = 6, Height = 5, Length = 9, Radius = 3, InnerRadius = 1, AngleDegrees = 100 })
			for _, shape in HitboxTypes.ShapeOrder do
				local size, centre = HitboxGeometry.BoundingBox(shape, d)
				local half = size / 2 + Vector3.one * 1e-3
				for x = -10, 10, 1 do
					for y = -10, 10, 1 do
						for z = -14, 14, 1 do
							local point = Vector3.new(x * 0.5, y * 0.5, z * 0.5)
							if HitboxGeometry.ContainsPoint(shape, d, point, 0) then
								local inBox = centre:PointToObjectSpace(point)
								expect(
									math.abs(inBox.X) <= half.X
										and math.abs(inBox.Y) <= half.Y
										and math.abs(inBox.Z) <= half.Z
								).to.equal(true)
							end
						end
					end
				end
			end
		end)

		it("reports a reach no smaller than the furthest contained point forward", function()
			local d = dims({ Width = 6, Height = 5, Length = 9, Radius = 3, InnerRadius = 1, AngleDegrees = 100 })
			for _, shape in HitboxTypes.ShapeOrder do
				local reach = HitboxGeometry.Reach(shape, d)
				for z = 1, 40 do
					local forward = z * 0.5
					if HitboxGeometry.ContainsPoint(shape, d, Vector3.new(0, 0, -forward), 0) then
						expect(forward <= reach + 1e-6).to.equal(true)
					end
				end
			end
		end)

		it("gives every shape a positive MinExtent", function()
			local d = dims({ Width = 6, Height = 5, Length = 9, Radius = 3, InnerRadius = 1, AngleDegrees = 100 })
			for _, shape in HitboxTypes.ShapeOrder do
				expect(HitboxGeometry.MinExtent(shape, d) > 0).to.equal(true)
			end
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
