--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)

-- Roblox refuses to render a Part below 0.05 studs on any axis, which is why BuildPreviewParts
-- floors every extent -- mirrored here rather than imported because it is a private constant.
local MIN_PREVIEW_EXTENT = 0.05

-- Slack for the "every preview piece's centre lies inside BoundingBox" property below. The two
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

	-- THE ContainsPoint DESCRIBE BLOCK IS GONE, with the function it tested. It exercised a
	-- twelve-shape narrow-phase containment test in a module that resolves no hits: the live narrow
	-- phase is Shared/HitboxEngine/HitboxGeometry.lua, over HitboxTypes' seven ShapeKinds, and
	-- MoveTypes maps the five authoring-only shapes down to those before anything is resolved. Its
	-- headline case -- "never accepts a point outside the shape's own bounding box" -- could not be
	-- repointed at HitboxGeometry, because five of the twelve shapes it swept do not exist there.
	--
	-- What that leaves genuinely uncovered is HitboxGeometry's own ContainsPoint/SweptContainsPoint,
	-- which has no spec of its own and never did -- this file only ever looked like coverage of it.
	-- Worth writing; deliberately not written here, since a new spec for a different module is not the
	-- same change as deleting a dead one.

	-- THE AUTHORING CAPS AND THE ENGINE CAPS DISAGREE, and this pins the disagreement rather than
	-- papering over it, because closing it is a design call with two defensible answers and I do not
	-- have the context to pick one.
	--
	-- HitboxShapes.FIELD_SPECS is what the Move Editor lets an author type.
	-- HitboxEngine/HitboxTypes.FIELD_BOUNDS is what the engine actually resolves against, after
	-- MoveTypes maps an authored move down to an engine one. Where the editor's cap is HIGHER, an
	-- author enters a number, the editor accepts it, the DataStore stores it, and the engine silently
	-- clamps it -- so the move plays smaller than it reads.
	--
	-- Radius and InnerRadius are that case today: 500 and 100 here against 256 and 256 there. Width,
	-- Height and Length are fine (500 here, 512 there -- the editor is the stricter one, which is the
	-- harmless direction).
	--
	-- The two fixes, both one line:
	--   * Lower FIELD_SPECS.Radius/.InnerRadius to 256. Changes NO gameplay -- the engine already
	--     clamps there -- and makes the editor stop accepting numbers that do nothing.
	--   * Raise FIELD_BOUNDS.Radius/.InnerRadius to 500. Honours what the 2026-08-12 "much larger
	--     hitboxes" pass evidently intended (FIELD_SPECS' own comment says Radius was raised
	--     "alongside Height/Depth/Length/Radius/InnerRadius"; FIELD_BOUNDS was not), but it CHANGES
	--     GAMEPLAY: any stored move authored above 256 would start resolving larger than it does now.
	--
	-- Either way this test fails and forces the choice to be stated. There is also a third, smaller
	-- discrepancy inside FIELD_SPECS itself: InnerRadius' own comment says it "mirrors Radius' own Max
	-- above" so the strictly-inside invariant means something, and it does not (100 against 500).
	describe("the authoring caps against the engine's own", function()
		local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

		it("is stricter than the engine for every box dimension", function()
			for _, field in { "Width", "Height", "Length" } do
				local authoring = HitboxShapes.GetFieldSpec(field :: any).Max
				local engine = HitboxTypes.FieldBounds()[field].Max
				expect(authoring <= engine).to.equal(true)
			end
		end)

		it("is LOOSER than the engine for Radius and InnerRadius -- the open discrepancy above", function()
			expect(HitboxShapes.GetFieldSpec("Radius").Max).to.equal(500)
			expect(HitboxTypes.FieldBounds().Radius.Max).to.equal(256)
			expect(HitboxShapes.GetFieldSpec("InnerRadius").Max).to.equal(100)
			expect(HitboxTypes.FieldBounds().InnerRadius.Max).to.equal(256)
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
