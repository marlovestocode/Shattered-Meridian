--!strict
-- ArchitectGenerator: the same seed and config give the same layout; placements stay inside the area, never overlap,
-- keep out of exclusions and blockers; bad configs are refused.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectGenerator = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectGenerator)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)

local function config(overrides: { [string]: any }?): ArchitectGenerator.Config
	local raw: { [string]: any } = {
		Type = "Ruins",
		Seed = 1234,
		Center = Vector3.new(0, 10, 0),
		AreaX = 200,
		AreaZ = 200,
		Yaw = 0,
		Spacing = 6,
		Density = 0.6,
		RotationJitter = 180,
		FollowGround = true,
	}
	for key, value in overrides or {} do
		raw[key] = value
	end
	local decoded, reason = ArchitectGenerator.Decode(raw)
	assert(decoded, `config should decode: {tostring(reason)}`)
	return decoded
end

local function flat(_x: number, _z: number): number?
	return 10
end

local function signature(layout: ArchitectGenerator.Layout): string
	local parts: { string } = {}
	for _, placement in layout.Placements do
		local p = placement.CFrame.Position
		table.insert(parts, string.format("%s@%.3f,%.3f", placement.TemplateId, p.X, p.Z))
	end
	return table.concat(parts, ";")
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

return function()
	describe("determinism", function()
		for _, kind in { "Ruins", "Grove", "Pathway", "Outpost", "SectCompound", "RuinedQuarter" } do
			it(`{kind}: the same seed gives the same layout`, function()
				local a = ArchitectGenerator.Generate(config({ Type = kind }), flat, {}, nil)
				local b = ArchitectGenerator.Generate(config({ Type = kind }), flat, {}, nil)
				expect(#a.Placements > 0).to.equal(true)
				expect(signature(a)).to.equal(signature(b))
			end)
		end

		it("a different seed gives a different scatter", function()
			local a = ArchitectGenerator.Generate(config({ Seed = 1 }), flat, {}, nil)
			local b = ArchitectGenerator.Generate(config({ Seed = 2 }), flat, {}, nil)
			expect(signature(a) ~= signature(b)).to.equal(true)
		end)
	end)

	describe("placement rules", function()
		it("keeps scattered footprints inside the area and apart by the spacing", function()
			local c = config({ Density = 1 })
			local layout = ArchitectGenerator.Generate(c, flat, {}, nil)
			for i, a in layout.Placements do
				local p = a.CFrame.Position
				expect(math.abs(p.X) + a.Radius <= c.AreaX / 2 + 1e-3).to.equal(true)
				expect(math.abs(p.Z) + a.Radius <= c.AreaZ / 2 + 1e-3).to.equal(true)
				for j, b in layout.Placements do
					if i < j then
						expect(flatDistance(p, b.CFrame.Position) >= a.Radius + b.Radius + c.Spacing - 1e-3).to.equal(
							true
						)
					end
				end
			end
		end)

		it("never places into an exclusion or a blocker", function()
			local exclusion = { Center = Vector3.new(0, 0, 0), Radius = 40 }
			local blocker = { Center = Vector3.new(60, 0, 60), Radius = 25 }
			local layout =
				ArchitectGenerator.Generate(config({ Exclusions = { exclusion }, Density = 1 }), flat, { blocker }, nil)
			for _, placement in layout.Placements do
				local p = placement.CFrame.Position
				expect(flatDistance(p, exclusion.Center) >= exclusion.Radius + placement.Radius - 1e-3).to.equal(true)
				expect(flatDistance(p, blocker.Center) >= blocker.Radius + placement.Radius - 1e-3).to.equal(true)
			end
		end)

		it("refuses points with no ground and counts why", function()
			local layout = ArchitectGenerator.Generate(config(), function()
				return nil
			end, {}, nil)
			expect(#layout.Placements).to.equal(0)
			expect((layout.Refused.NoGround or 0) > 0).to.equal(true)
		end)

		it("rests placements on the ground it is given", function()
			local layout = ArchitectGenerator.Generate(config(), function(x: number, _z: number)
				return x * 0.1
			end, {}, nil)
			for _, placement in layout.Placements do
				local p = placement.CFrame.Position
				expect(math.abs(p.Y - p.X * 0.1) < 1e-3).to.equal(true)
			end
		end)

		it("never exceeds MaxPlacements", function()
			local layout =
				ArchitectGenerator.Generate(config({ Density = 1, Spacing = 2, MaxPlacements = 5 }), flat, {}, nil)
			expect(#layout.Placements <= 5).to.equal(true)
		end)

		it("an outpost has a gate and corner posts on its perimeter", function()
			local layout =
				ArchitectGenerator.Generate(config({ Type = "Outpost", AreaX = 96, AreaZ = 96 }), flat, {}, nil)
			local counts: { [string]: number } = {}
			for _, placement in layout.Placements do
				counts[placement.TemplateId] = (counts[placement.TemplateId] or 0) + 1
			end
			expect(counts[StarterTemplates.Perimeter.Gate]).to.equal(1)
			expect(counts[StarterTemplates.Perimeter.Corner]).to.equal(4)
		end)

		it("Expand produces one area group with every placement under it", function()
			local c = config()
			local layout = ArchitectGenerator.Generate(c, flat, {}, nil)
			local pending = ArchitectGenerator.Expand(layout, c, nil)
			expect(pending[1].Ref).to.equal("area")
			expect(pending[1].ParentRef).to.equal(nil)
			local roots = 0
			for _, node in pending do
				if node.ParentRef == "area" then
					roots += 1
				end
			end
			expect(roots).to.equal(#layout.Placements)
		end)
	end)

	describe("Decode", function()
		it("refuses unknown types, missing centres and out-of-world centres", function()
			expect((ArchitectGenerator.Decode({
				Type = "Castle",
				Seed = 1,
				Center = Vector3.zero,
				AreaX = 50,
				AreaZ = 50,
				Spacing = 4,
				Density = 0.5,
			}))).to.equal(nil)
			expect((ArchitectGenerator.Decode({
				Type = "Ruins",
				Seed = 1,
				AreaX = 50,
				AreaZ = 50,
				Spacing = 4,
				Density = 0.5,
			}))).to.equal(nil)
			expect((ArchitectGenerator.Decode({
				Type = "Ruins",
				Seed = 1,
				Center = Vector3.new(1e6, 0, 0),
				AreaX = 50,
				AreaZ = 50,
				Spacing = 4,
				Density = 0.5,
			}))).to.equal(nil)
		end)

		it("clamps area and density into range and floors the seed", function()
			local decoded = ArchitectGenerator.Decode({
				Type = "Ruins",
				Seed = 7.9,
				Center = Vector3.zero,
				AreaX = 99999,
				AreaZ = 1,
				Spacing = 4,
				Density = 5,
			})
			assert(decoded, "decoded")
			expect(decoded.Seed).to.equal(7)
			expect(decoded.AreaX).to.equal(600)
			expect(decoded.AreaZ).to.equal(16)
			expect(decoded.Density).to.equal(1)
		end)

		it("refuses too many exclusions", function()
			local many = {}
			for _ = 1, 13 do
				table.insert(many, { Center = Vector3.zero, Radius = 5 })
			end
			expect((ArchitectGenerator.Decode({
				Type = "Ruins",
				Seed = 1,
				Center = Vector3.zero,
				AreaX = 50,
				AreaZ = 50,
				Spacing = 4,
				Density = 0.5,
				Exclusions = many,
			}))).to.equal(nil)
		end)
	end)
end
