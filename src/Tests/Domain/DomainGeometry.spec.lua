--!strict
-- Covers Shared/Domain/DomainGeometry.lua -- the boundary as math, shared by the server's enforcement,
-- the projectile barrier and the owning client's predicted wall.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)

type Boundary = DomainGeometry.Boundary

local function boundary(shape: DomainGeometry.Shape, overrides: { [string]: any }?): Boundary
	local result: any = { Shape = shape, Center = Vector3.zero, Yaw = 0, Radius = 10, Height = 20 }
	for key, value in overrides or {} do
		result[key] = value
	end
	return result
end

return function()
	describe("DomainGeometry.Depth / Contains", function()
		it("measures a sphere radially", function()
			local sphere = boundary("Sphere")
			expect(DomainGeometry.Depth(sphere, Vector3.new(4, 0, 0))).to.be.near(6, 1e-6)
			expect(DomainGeometry.Contains(sphere, Vector3.new(0, 9, 0))).to.equal(true)
			expect(DomainGeometry.Contains(sphere, Vector3.new(0, 11, 0))).to.equal(false)
		end)

		it("gives a cylinder a flat top and bottom", function()
			local cylinder = boundary("Cylinder", { Radius = 10, Height = 6 })
			expect(DomainGeometry.Contains(cylinder, Vector3.new(9, 2, 0))).to.equal(true)
			expect(DomainGeometry.Contains(cylinder, Vector3.new(0, 4, 0))).to.equal(false)
		end)

		it("turns a box with its yaw", function()
			local box = boundary("Box", { Radius = 5, Height = 10, Yaw = math.rad(45) })
			-- (6, 0, 0) is outside the unrotated box's 5-stud half-width, but inside its 45-degree diagonal.
			expect(DomainGeometry.Contains(boundary("Box", { Radius = 5 }), Vector3.new(6, 0, 0))).to.equal(false)
			expect(DomainGeometry.Contains(box, Vector3.new(6, 0, 0))).to.equal(true)
		end)
	end)

	describe("DomainGeometry.ClampInside / ClampOutside", function()
		it("sets a body that stepped out back inside by the margin", function()
			local sphere = boundary("Sphere")
			local clamped = DomainGeometry.ClampInside(sphere, Vector3.new(14, 0, 0), 1)
			expect(DomainGeometry.Depth(sphere, clamped)).to.be.near(1, 1e-4)
		end)

		it("leaves a body that is already deep enough where it is", function()
			local point = Vector3.new(2, 1, 0)
			expect(DomainGeometry.ClampInside(boundary("Cylinder"), point, 1)).to.equal(point)
		end)

		it("pushes a newcomer out horizontally, never over the top", function()
			local cylinder = boundary("Cylinder")
			local pushed = DomainGeometry.ClampOutside(cylinder, Vector3.new(3, 2, 4), 1)
			expect(pushed.Y).to.be.near(2, 1e-6)
			expect(DomainGeometry.Depth(cylinder, pushed) <= -1 + 1e-4).to.equal(true)
		end)

		it("pushes a body out of a box through the nearest face", function()
			local box = boundary("Box", { Radius = 5 })
			local pushed = DomainGeometry.ClampOutside(box, Vector3.new(4, 0, 1), 1)
			expect(pushed.X).to.be.near(6, 1e-4)
		end)
	end)

	describe("DomainGeometry.Crossing / Overlaps", function()
		it("names the direction a step crosses the edge", function()
			local sphere = boundary("Sphere")
			expect(DomainGeometry.Crossing(sphere, Vector3.new(9, 0, 0), Vector3.new(11, 0, 0))).to.equal("Leaving")
			expect(DomainGeometry.Crossing(sphere, Vector3.new(11, 0, 0), Vector3.new(9, 0, 0))).to.equal("Entering")
			expect(DomainGeometry.Crossing(sphere, Vector3.new(1, 0, 0), Vector3.new(2, 0, 0))).to.equal(nil)
		end)

		it("overlaps two realms whose bounds meet, and not two that do not", function()
			local a = boundary("Sphere")
			expect(DomainGeometry.Overlaps(a, boundary("Sphere", { Center = Vector3.new(15, 0, 0) }))).to.equal(true)
			expect(DomainGeometry.Overlaps(a, boundary("Sphere", { Center = Vector3.new(25, 0, 0) }))).to.equal(false)
		end)
	end)

	describe("DomainGeometry.AngularRadius / Scaled", function()
		it("is a right angle from inside and shrinks with distance outside", function()
			local sphere = boundary("Sphere")
			expect(DomainGeometry.AngularRadius(sphere, Vector3.new(3, 0, 0))).to.be.near(math.pi / 2, 1e-6)
			-- 10 studs of radius seen from 20 studs out: asin(0.5) = 30 degrees.
			expect(DomainGeometry.AngularRadius(sphere, Vector3.new(20, 0, 0))).to.be.near(math.rad(30), 1e-6)
			expect(DomainGeometry.AngularRadius(sphere, Vector3.new(200, 0, 0)) < math.rad(3)).to.equal(true)
		end)

		it("fills more of a view the larger the realm is, from the same distance past its edge", function()
			local small = boundary("Sphere", { Radius = 10 })
			local large = boundary("Sphere", { Radius = 120 })
			local smallAngle = DomainGeometry.AngularRadius(small, Vector3.new(20, 0, 0))
			local largeAngle = DomainGeometry.AngularRadius(large, Vector3.new(130, 0, 0))
			expect(largeAngle > smallAngle).to.equal(true)
		end)

		it("scales a boundary about its own centre", function()
			local cylinder = boundary("Cylinder", { Center = Vector3.new(5, 0, 0), Radius = 10, Height = 6 })
			local half = DomainGeometry.Scaled(cylinder, 0.5)
			expect(half.Radius).to.be.near(5, 1e-6)
			expect(half.Height).to.be.near(3, 1e-6)
			expect(half.Center).to.equal(cylinder.Center)
			expect(DomainGeometry.Contains(half, Vector3.new(12, 0, 0))).to.equal(false)
			expect(DomainGeometry.Contains(cylinder, Vector3.new(12, 0, 0))).to.equal(true)
		end)
	end)
end
