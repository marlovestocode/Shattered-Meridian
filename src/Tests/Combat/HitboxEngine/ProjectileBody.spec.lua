--!strict
-- Covers Shared/HitboxEngine/ProjectileBody.lua and the shape fields of ProjectileTypes -- the geometry a
-- projectile flies as. Pure: specs, vectors and CFrames, no Workspace, which is why the same module can
-- be the server's sweep, the client's drawing and the editor's plot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ProjectileBody = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileBody)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

local function spec(overrides: { [string]: any }?): ProjectileTypes.ProjectileSpec
	local result = ProjectileTypes.Defaults() :: any
	for key, value in pairs(overrides or {}) do
		result[key] = value
	end
	return result
end

return function()
	describe("ProjectileTypes -- the body fields", function()
		it("defaults to a sphere, so a record from before shapes existed means what it did", function()
			local defaults = ProjectileTypes.Defaults()
			expect(defaults.Shape).to.equal("Sphere")
			expect(defaults.Size).to.equal(1)
			-- And an old record that has none of the new fields validates to those defaults.
			local old = ProjectileTypes.Defaults() :: any
			for _, name in { "Shape", "Length", "Width", "Height", "InnerRadius", "AngleDegrees" } do
				old[name] = nil
			end
			local validated, reason = ProjectileTypes.Validate(old)
			expect(reason).to.equal(nil)
			expect((validated :: ProjectileTypes.ProjectileSpec).Shape).to.equal("Sphere")
		end)

		it("offers only shapes the engine knows, once each", function()
			local seen: { [string]: boolean } = {}
			for _, shape in ProjectileTypes.Shapes do
				expect(HitboxTypes.IsShapeKind(shape)).to.equal(true)
				expect(seen[shape]).to.equal(nil)
				seen[shape] = true
			end
		end)

		it("refuses a shape that does not exist and clamps a measurement that is out of range", function()
			local _, reason = ProjectileTypes.Validate(spec({ Shape = "Dodecahedron" }))
			expect(reason).to.equal("InvalidProjectile")
			local clamped = ProjectileTypes.Validate(spec({ Length = 9999, Width = -3, Size = 9999 })) :: any
			expect(clamped.Length).to.equal(ProjectileTypes.Limits.Length.Max)
			expect(clamped.Width).to.equal(ProjectileTypes.Limits.Width.Min)
			expect(clamped.Size).to.equal(ProjectileTypes.Limits.Size.Max)
		end)

		it("keeps every preset valid, inside its limits, and reading only fields its shape reads", function()
			expect(#ProjectileTypes.Presets > 0).to.equal(true)
			local ids: { [string]: boolean } = {}
			for _, preset in ProjectileTypes.Presets do
				expect(ids[preset.Id]).to.equal(nil)
				ids[preset.Id] = true
				local candidate = spec(preset.Values)
				local validated, reason = ProjectileTypes.Validate(candidate)
				expect(reason).to.equal(nil)
				expect(validated).to.be.ok()
				-- Nothing was clamped: the preset already sits inside the limits.
				for name, value in preset.Values do
					expect((validated :: any)[name]).to.equal(value)
				end
				-- A measurement is only set if the shape reads it (Size is the Radius field).
				local reads = HitboxTypes.FieldsFor(preset.Values.Shape)
				for name in preset.Values do
					if name ~= "Shape" then
						local field = if name == "Size" then "Radius" else name
						expect(table.find(reads, field) ~= nil).to.equal(true)
					end
				end
				expect(ProjectileTypes.PresetById(preset.Id)).to.equal(preset)
			end
		end)
	end)

	describe("ProjectileBody.Of", function()
		it("makes a sphere of the spec's Size, with its original reach and cast", function()
			local body = ProjectileBody.Of(spec({ Size = 1.5 }))
			expect(body.IsSphere).to.equal(true)
			expect(body.Shape).to.equal("Sphere")
			expect(body.CastRadius).to.equal(1.5)
			expect(body.LeadStuds).to.equal(1.5)
			-- A sphere casts from its centre: its lead and its radius are the same distance.
			expect(body.CastLead).to.equal(0)
			expect(body.Pointed).to.equal(false)
		end)

		it("reads each shape's own measurements through the geometry the engine uses", function()
			local body = ProjectileBody.Of(spec({ Shape = "Capsule", Size = 0.5, Length = 8 }))
			expect(body.IsSphere).to.equal(false)
			expect(body.Dimensions.Radius).to.equal(0.5)
			expect(body.Dimensions.Length).to.equal(8)
			-- The segment between the cap centres is 8 long, so it reaches 4 + 0.5 ahead of its middle.
			expect(math.abs(body.LeadStuds - 4.5) < 1e-6).to.equal(true)
			-- Thin: the world cast is its radius, moved out so the TIP leads.
			expect(math.abs(body.CastRadius - 0.5) < 1e-6).to.equal(true)
			expect(math.abs(body.CastLead - 4) < 1e-6).to.equal(true)
			expect(body.BoundRadius >= body.LeadStuds).to.equal(true)
		end)

		it("flies a reach shape point first, and a centred one centred", function()
			for _, shape in { "Cone", "Pyramid", "Wedge", "Frustum" } do
				expect(ProjectileBody.Of(spec({ Shape = shape })).Pointed).to.equal(true)
			end
			for _, shape in { "Capsule", "Ellipsoid", "Cylinder", "Box", "Crescent", "Cross", "Pillar" } do
				expect(ProjectileBody.Of(spec({ Shape = shape })).Pointed).to.equal(false)
			end
		end)

		it("keeps InnerRadius at or below Size, as the engine's own sanitiser does", function()
			local body = ProjectileBody.Of(spec({ Shape = "Crescent", Size = 3, InnerRadius = 20 }))
			expect(body.Dimensions.InnerRadius).to.equal(3)
		end)
	end)

	describe("ProjectileBody.PoseAt", function()
		local function worldPoint(
			body: ProjectileBody.Body,
			position: Vector3,
			direction: Vector3,
			x: number,
			y: number,
			z: number
		)
			local pose = ProjectileBody.PoseAt(body, position, direction)
			return HitboxGeometry.ContainsPoint(
				body.Shape,
				body.Dimensions,
				pose:PointToObjectSpace(position + Vector3.new(x, y, z)),
				0
			)
		end

		it("lays a capsule along the heading, centred on the shot", function()
			local body = ProjectileBody.Of(spec({ Shape = "Capsule", Size = 0.5, Length = 8 }))
			local position, heading = Vector3.new(10, 5, 10), Vector3.new(1, 0, 0)
			-- Along +X, out to 4.5 each way...
			expect(worldPoint(body, position, heading, 4.3, 0, 0)).to.equal(true)
			expect(worldPoint(body, position, heading, -4.3, 0, 0)).to.equal(true)
			expect(worldPoint(body, position, heading, 4.8, 0, 0)).to.equal(false)
			-- ...and thin across it.
			expect(worldPoint(body, position, heading, 0, 0, 0.9)).to.equal(false)
			expect(worldPoint(body, position, heading, 0, 0.9, 0)).to.equal(false)
		end)

		it("turns a wedge so its apex leads and its wide end trails", function()
			local body = ProjectileBody.Of(spec({ Shape = "Wedge", Width = 4, Height = 1, Length = 6 }))
			local position, heading = Vector3.zero, Vector3.new(0, 0, -1)
			-- Its tip is half a length AHEAD of the shot, its wide end half a length behind.
			expect(worldPoint(body, position, heading, 0, 0, -2.9)).to.equal(true)
			expect(worldPoint(body, position, heading, 1.5, 0, -2.9)).to.equal(false)
			expect(worldPoint(body, position, heading, 1.5, 0, 2.9)).to.equal(true)
			expect(worldPoint(body, position, heading, 0, 0, -3.5)).to.equal(false)
			expect(worldPoint(body, position, heading, 0, 0, 3.5)).to.equal(false)
		end)

		it("bulges a crescent forward, horns trailing", function()
			local body =
				ProjectileBody.Of(spec({ Shape = "Crescent", Size = 5, InnerRadius = 4.2, Length = 2, Height = 1.6 }))
			local position, heading = Vector3.zero, Vector3.new(0, 0, -1)
			-- Thick dead ahead...
			expect(worldPoint(body, position, heading, 0, 0, -4.5)).to.equal(true)
			-- ...hollow in the middle...
			expect(worldPoint(body, position, heading, 0, 0, 0)).to.equal(false)
			-- ...and a horn out to the side, behind the middle.
			expect(worldPoint(body, position, heading, 4.7, 0, 1)).to.equal(true)
		end)

		it("survives a straight-up heading, where a look vector has no unique up", function()
			local body = ProjectileBody.Of(spec({ Shape = "Box", Width = 2, Height = 2, Length = 6 }))
			local pose = ProjectileBody.PoseAt(body, Vector3.zero, Vector3.new(0, 1, 0))
			expect(pose.Position.Magnitude < 1e-6).to.equal(true)
			expect(pose.LookVector.Y > 0.99).to.equal(true)
		end)

		it("treats a zero heading as a heading rather than dividing by it", function()
			local body = ProjectileBody.Of(spec({ Shape = "Box" }))
			local pose = ProjectileBody.PoseAt(body, Vector3.new(1, 2, 3), Vector3.zero)
			expect(pose.Position.X).to.equal(1)
			expect(pose.LookVector.X == pose.LookVector.X).to.equal(true)
		end)
	end)

	describe("ProjectileBody -- the swept test the simulator runs", function()
		it("catches a target a thin shot flew straight through between two samples", function()
			local body = ProjectileBody.Of(spec({ Shape = "Capsule", Size = 0.4, Length = 3 }))
			local heading = Vector3.new(0, 0, -1)
			local a, b = Vector3.new(0, 0, 0), Vector3.new(0, 0, -9)
			local start = ProjectileBody.PoseAt(body, a, heading)
			local finish = ProjectileBody.PoseAt(body, b, heading)
			local target = Vector3.new(0.2, 0, -4.5)
			expect(HitboxGeometry.ContainsPoint(body.Shape, body.Dimensions, finish:PointToObjectSpace(target), 0)).to.equal(
				false
			)
			expect(
				HitboxGeometry.SweptContainsPoint(
					body.Shape,
					body.Dimensions,
					start,
					body.Dimensions,
					finish,
					target,
					0
				)
			).to.equal(true)
		end)

		it("misses a target beside the line that a sphere of the same Size would also miss", function()
			local body = ProjectileBody.Of(spec({ Shape = "Capsule", Size = 0.4, Length = 3 }))
			local heading = Vector3.new(0, 0, -1)
			local start = ProjectileBody.PoseAt(body, Vector3.zero, heading)
			local finish = ProjectileBody.PoseAt(body, Vector3.new(0, 0, -9), heading)
			expect(
				HitboxGeometry.SweptContainsPoint(
					body.Shape,
					body.Dimensions,
					start,
					body.Dimensions,
					finish,
					Vector3.new(2, 0, -4.5),
					0
				)
			).to.equal(false)
		end)
	end)

	describe("ProjectileBody.Look", function()
		it("draws a sphere as a ball of its diameter", function()
			local partType, size = ProjectileBody.Look(ProjectileBody.Of(spec({ Size = 2 })))
			expect(partType).to.equal("Ball")
			expect(size.X).to.equal(4)
		end)

		it("draws a capsule as a cylinder of its full length, a pillar standing, and the rest as blocks", function()
			local capsuleType, capsuleSize =
				ProjectileBody.Look(ProjectileBody.Of(spec({ Shape = "Capsule", Size = 0.5, Length = 8 })))
			expect(capsuleType).to.equal("Cylinder")
			expect(capsuleSize.X).to.equal(9)
			local pillarType, pillarSize, pillarTurn =
				ProjectileBody.Look(ProjectileBody.Of(spec({ Shape = "Pillar", Size = 2, Height = 0.5 })))
			expect(pillarType).to.equal("Cylinder")
			expect(pillarSize.X).to.equal(0.5)
			-- Standing: its long axis (X) is turned to Y.
			expect(math.abs(pillarTurn:VectorToWorldSpace(Vector3.xAxis).Y) > 0.99).to.equal(true)
			expect((ProjectileBody.Look(ProjectileBody.Of(spec({ Shape = "Wedge" }))))).to.equal("Block")
		end)
	end)
end
