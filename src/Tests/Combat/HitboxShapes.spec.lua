--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)

-- Roblox refuses to render a Part below 0.05 studs on any axis, which is why BuildPreviewParts
-- floors every extent -- mirrored here rather than imported because it is a private constant.
local MIN_PREVIEW_EXTENT = 0.05

-- Slack for the "everything ContainsPoint accepts lies inside BoundingBox" property below. The two
-- are computed by different closed-form expressions over the same dimensions, so they agree to
-- floating-point noise, not exactly.
local BOUNDS_EPSILON = 1e-4

local ALL_FIELDS: { HitboxShapes.DimensionField } = {
	"Width",
	"Height",
	"Depth",
	"Length",
	"Thickness",
	"Radius",
	"InnerRadius",
	"AngleDegrees",
}

return function()
	describe("HitboxShapes metadata", function()
		it("lists twelve shapes, each with a spec whose Id matches its key", function()
			local specs = HitboxShapes.ListShapes()
			expect(#specs).to.equal(12)
			for _, spec in ipairs(specs) do
				expect(HitboxShapes.GetSpec(spec.Id)).to.equal(spec)
				expect(#spec.Summary > 0).to.equal(true)
			end
		end)

		it("only names fields that have a field spec, and names at least one", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				expect(#spec.Fields > 0).to.equal(true)
				for _, field in ipairs(spec.Fields) do
					expect(HitboxShapes.GetFieldSpec(field)).to.be.ok()
					expect(HitboxShapes.UsesField(spec.Id, field)).to.equal(true)
				end
			end
		end)

		it("recognizes every listed shape and nothing else", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				expect(HitboxShapes.IsShapeId(spec.Id)).to.equal(true)
			end
			expect(HitboxShapes.IsShapeId("Trapezoid")).to.equal(false)
			expect(HitboxShapes.IsShapeId(42)).to.equal(false)
			expect(HitboxShapes.IsShapeId(nil)).to.equal(false)
		end)

		-- The property that keeps every pre-existing hand-authored attack on its original query path
		-- -- see HitboxShapes' own header and HitboxResolver.isExactShape.
		it("treats exactly Box and Sphere as exact-broadphase shapes", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				local expected = spec.Id == "Box" or spec.Id == "Sphere"
				expect(HitboxShapes.IsExactBroadphase(spec.Id)).to.equal(expected)
			end
		end)
	end)

	describe("HitboxShapes.DefaultDimensions", function()
		it("fully populates every field for every shape, in range", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				local dimensions = HitboxShapes.DefaultDimensions(spec.Id)
				for _, field in ipairs(ALL_FIELDS) do
					local value = dimensions[field]
					local fieldSpec = HitboxShapes.GetFieldSpec(field)
					expect(type(value)).to.equal("number")
					expect(value >= fieldSpec.Min).to.equal(true)
					expect(value <= fieldSpec.Max).to.equal(true)
				end
			end
		end)

		it("applies the shape's own overrides over the global field defaults", function()
			-- Cone authors a much longer default reach than the shared Length default of 8.
			expect(HitboxShapes.DefaultDimensions("Cone").Length).to.equal(12)
			expect(HitboxShapes.DefaultDimensions("Beam").Length).to.equal(20)
			-- Slice is the paper-thin shape -- its default has to be far below Thickness' own 0.5.
			expect(HitboxShapes.DefaultDimensions("Slice").Thickness).to.equal(0.08)
		end)
	end)

	describe("HitboxShapes.Sanitize", function()
		it("clamps out-of-range values to the field bounds", function()
			local dimensions = HitboxShapes.Sanitize("Box", { Width = 1e6, Height = -50, Depth = 4 })
			expect(dimensions.Width).to.equal(HitboxShapes.GetFieldSpec("Width").Max)
			expect(dimensions.Height).to.equal(HitboxShapes.GetFieldSpec("Height").Min)
			expect(dimensions.Depth).to.equal(4)
		end)

		it("falls back to the shape default for a missing or non-numeric field", function()
			local defaults = HitboxShapes.DefaultDimensions("Box")
			local dimensions = HitboxShapes.Sanitize("Box", { Width = "wide", Height = nil, Depth = {} })
			expect(dimensions.Width).to.equal(defaults.Width)
			expect(dimensions.Height).to.equal(defaults.Height)
			expect(dimensions.Depth).to.equal(defaults.Depth)
		end)

		-- NaN survives every comparison-based clamp, so it has to be rejected by identity before the
		-- clamp rather than after -- it would otherwise propagate into the geometry math.
		it("rejects NaN rather than clamping it", function()
			local defaults = HitboxShapes.DefaultDimensions("Sphere")
			local dimensions = HitboxShapes.Sanitize("Sphere", { Radius = 0 / 0 })
			expect(dimensions.Radius).to.equal(defaults.Radius)
		end)

		it("accepts a non-table input and returns the shape's defaults", function()
			local defaults = HitboxShapes.DefaultDimensions("Arc")
			local dimensions = HitboxShapes.Sanitize("Arc", "not a table")
			for _, field in ipairs(ALL_FIELDS) do
				expect(dimensions[field]).to.equal(defaults[field])
			end
		end)

		-- The one cross-field invariant this vocabulary has: a hole punched past the rim leaves a
		-- Disc/Arc enclosing nothing, which reads as a dead hitbox rather than an authoring mistake.
		it("pulls InnerRadius back strictly inside Radius", function()
			local dimensions = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 9 })
			expect(dimensions.InnerRadius < dimensions.Radius).to.equal(true)

			local equal = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 6 })
			expect(equal.InnerRadius < equal.Radius).to.equal(true)
		end)

		it("leaves a legal InnerRadius alone", function()
			local dimensions = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 2 })
			expect(dimensions.Radius).to.equal(6)
			expect(dimensions.InnerRadius).to.equal(2)
		end)

		it("keeps a genuinely paper-thin Thickness", function()
			-- 0.02 is the floor precisely so a "the blade passed through exactly this plane" Slice is
			-- authorable -- clamping it up to something visible would defeat that shape's purpose.
			local dimensions = HitboxShapes.Sanitize("Slice", { Thickness = 0.02 })
			expect(dimensions.Thickness).to.equal(0.02)
		end)
	end)

	describe("HitboxShapes.ContainsPoint", function()
		it("contains the origin for every centred shape", function()
			for _, shapeId in ipairs({ "Box", "Sphere", "Cylinder", "Capsule", "Disc", "Slice", "Wedge" }) do
				local shape = shapeId :: HitboxShapes.ShapeId
				local dimensions = HitboxShapes.DefaultDimensions(shape)
				-- Arc is deliberately absent: its default InnerRadius is 2, so its hub is genuinely
				-- hollow and the origin is correctly outside it. Disc defaults to InnerRadius 0.
				expect(HitboxShapes.ContainsPoint(shape, dimensions, Vector3.zero, 0)).to.equal(true)
			end
		end)

		it("grows a reach shape forward along -Z and not backward", function()
			for _, shapeId in ipairs({ "Cone", "Pyramid", "Beam", "Blade" }) do
				local shape = shapeId :: HitboxShapes.ShapeId
				local dimensions = HitboxShapes.DefaultDimensions(shape)
				local midway = Vector3.new(0, 0, -dimensions.Length / 2)
				local behind = Vector3.new(0, 0, dimensions.Length / 2)
				local beyond = Vector3.new(0, 0, -dimensions.Length * 1.5)
				expect(HitboxShapes.ContainsPoint(shape, dimensions, midway, 0)).to.equal(true)
				expect(HitboxShapes.ContainsPoint(shape, dimensions, behind, 0)).to.equal(false)
				expect(HitboxShapes.ContainsPoint(shape, dimensions, beyond, 0)).to.equal(false)
			end
		end)

		it("tapers a Cone: wide at the base, tight at the apex", function()
			local dimensions = HitboxShapes.Sanitize("Cone", { Length = 10, AngleDegrees = 90 })
			-- A 90 degree full apex angle means a 45 degree half angle, so the allowed radius equals
			-- the forward distance exactly.
			expect(HitboxShapes.ContainsPoint("Cone", dimensions, Vector3.new(8, 0, -9), 0)).to.equal(true)
			expect(HitboxShapes.ContainsPoint("Cone", dimensions, Vector3.new(8, 0, -1), 0)).to.equal(false)
		end)

		it("excludes the hole of a ringed Disc", function()
			local dimensions = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 3, Thickness = 0.4 })
			expect(HitboxShapes.ContainsPoint("Disc", dimensions, Vector3.new(4.5, 0, 0), 0)).to.equal(true)
			expect(HitboxShapes.ContainsPoint("Disc", dimensions, Vector3.zero, 0)).to.equal(false)
		end)

		it("trims an Arc to its swept sector", function()
			local dimensions =
				HitboxShapes.Sanitize("Arc", { Radius = 9, InnerRadius = 2, Height = 5, AngleDegrees = 90 })
			-- Dead ahead is inside a 90 degree sweep; directly behind never is.
			expect(HitboxShapes.ContainsPoint("Arc", dimensions, Vector3.new(0, 0, -6), 0)).to.equal(true)
			expect(HitboxShapes.ContainsPoint("Arc", dimensions, Vector3.new(0, 0, 6), 0)).to.equal(false)
		end)

		it("treats a full 360 degree Arc as a complete ring", function()
			local dimensions =
				HitboxShapes.Sanitize("Arc", { Radius = 9, InnerRadius = 2, Height = 5, AngleDegrees = 360 })
			expect(HitboxShapes.ContainsPoint("Arc", dimensions, Vector3.new(0, 0, 6), 0)).to.equal(true)
			expect(HitboxShapes.ContainsPoint("Arc", dimensions, Vector3.new(-6, 0, 0), 0)).to.equal(true)
		end)

		-- Margin exists because the broadphase hands back whole PARTS, not points, so a part
		-- overlapping the volume by a sliver still legitimately counts as a hit.
		it("inflates the volume by the margin, never deflates it", function()
			local dimensions = HitboxShapes.Sanitize("Sphere", { Radius = 4 })
			local justOutside = Vector3.new(0, 0, -4.5)
			expect(HitboxShapes.ContainsPoint("Sphere", dimensions, justOutside, 0)).to.equal(false)
			expect(HitboxShapes.ContainsPoint("Sphere", dimensions, justOutside, 1)).to.equal(true)
		end)

		-- The invariant the whole broadphase/narrow-phase split rests on: BoundingBox must be a
		-- conservative OVER-estimate, so a point the narrow phase accepts can never sit outside the
		-- box the broadphase queried. If this fails for a shape, that shape silently drops hits.
		it("never accepts a point outside the shape's own bounding box", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				local shape = spec.Id
				local dimensions = HitboxShapes.DefaultDimensions(shape)
				local size, centre = HitboxShapes.BoundingBox(shape, dimensions)
				local half = size / 2
				local extent = HitboxShapes.BoundingRadius(shape, dimensions)

				local samples = 8
				local insideCount = 0
				for xStep = -samples, samples do
					for yStep = -samples, samples do
						for zStep = -samples, samples do
							local point = Vector3.new(
								xStep / samples * extent,
								yStep / samples * extent,
								zStep / samples * extent
							)
							if not HitboxShapes.ContainsPoint(shape, dimensions, point, 0) then
								continue
							end
							insideCount += 1
							local localPoint = centre:PointToObjectSpace(point)
							local withinBounds = math.abs(localPoint.X) <= half.X + BOUNDS_EPSILON
								and math.abs(localPoint.Y) <= half.Y + BOUNDS_EPSILON
								and math.abs(localPoint.Z) <= half.Z + BOUNDS_EPSILON
							if not withinBounds then
								error(
									`{shape}: ContainsPoint accepted {point} which lies outside its own BoundingBox`,
									0
								)
							end
						end
					end
				end
				-- Guards against the assertion above passing vacuously because the sample grid never
				-- landed inside the volume at all.
				expect(insideCount > 0).to.equal(true)
			end
		end)
	end)

	describe("HitboxShapes.Reach and ApproximateVolume", function()
		it("reports a positive reach and volume for every shape", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				local dimensions = HitboxShapes.DefaultDimensions(spec.Id)
				expect(HitboxShapes.Reach(spec.Id, dimensions) > 0).to.equal(true)
				expect(HitboxShapes.ApproximateVolume(spec.Id, dimensions) > 0).to.equal(true)
			end
		end)

		it("reports a reach shape's reach as its full authored Length", function()
			for _, shapeId in ipairs({ "Cone", "Pyramid", "Beam", "Blade" }) do
				local shape = shapeId :: HitboxShapes.ShapeId
				local dimensions = HitboxShapes.DefaultDimensions(shape)
				expect(HitboxShapes.Reach(shape, dimensions)).to.equal(dimensions.Length)
			end
		end)

		it("subtracts the hole from a ringed Disc's volume", function()
			local solid = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 0, Thickness = 1 })
			local ring = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 3, Thickness = 1 })
			local solidVolume = HitboxShapes.ApproximateVolume("Disc", solid)
			local ringVolume = HitboxShapes.ApproximateVolume("Disc", ring)
			expect(ringVolume < solidVolume).to.equal(true)
		end)
	end)

	describe("HitboxShapes.BuildPreviewParts", function()
		-- The preview and the hit math are derived from one description precisely so they cannot
		-- disagree -- a shape whose preview lies is worse than no preview at all.
		it("returns at least one renderable part for every shape", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				local parts = HitboxShapes.BuildPreviewParts(spec.Id, HitboxShapes.DefaultDimensions(spec.Id))
				expect(#parts > 0).to.equal(true)
				for _, piece in ipairs(parts) do
					expect(piece.Size.X >= MIN_PREVIEW_EXTENT).to.equal(true)
					expect(piece.Size.Y >= MIN_PREVIEW_EXTENT).to.equal(true)
					expect(piece.Size.Z >= MIN_PREVIEW_EXTENT).to.equal(true)
				end
			end
		end)

		it("draws the two exact shapes as a single primitive", function()
			expect(#HitboxShapes.BuildPreviewParts("Box", HitboxShapes.DefaultDimensions("Box"))).to.equal(1)
			expect(#HitboxShapes.BuildPreviewParts("Sphere", HitboxShapes.DefaultDimensions("Sphere"))).to.equal(1)
		end)

		it("draws a ringed Disc as a band rather than the solid cylinder a hubless one gets", function()
			local solid = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 0, Thickness = 0.4 })
			local ring = HitboxShapes.Sanitize("Disc", { Radius = 6, InnerRadius = 3, Thickness = 0.4 })
			expect(#HitboxShapes.BuildPreviewParts("Disc", solid)).to.equal(1)
			expect(#HitboxShapes.BuildPreviewParts("Disc", ring) > 1).to.equal(true)
		end)

		-- Every preview piece has to sit inside the volume's own bounding box, or the gizmo an author
		-- tunes against would overstate the hitbox's extent.
		it("keeps every preview piece's centre inside the shape's bounding box", function()
			for _, spec in ipairs(HitboxShapes.ListShapes()) do
				local dimensions = HitboxShapes.DefaultDimensions(spec.Id)
				local size, centre = HitboxShapes.BoundingBox(spec.Id, dimensions)
				local half = size / 2
				for _, piece in ipairs(HitboxShapes.BuildPreviewParts(spec.Id, dimensions)) do
					local localPoint = centre:PointToObjectSpace(piece.CFrame.Position)
					expect(math.abs(localPoint.X) <= half.X + BOUNDS_EPSILON).to.equal(true)
					expect(math.abs(localPoint.Y) <= half.Y + BOUNDS_EPSILON).to.equal(true)
					expect(math.abs(localPoint.Z) <= half.Z + BOUNDS_EPSILON).to.equal(true)
				end
			end
		end)
	end)
end
