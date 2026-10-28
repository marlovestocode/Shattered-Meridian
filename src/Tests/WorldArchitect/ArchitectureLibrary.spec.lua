--!strict
-- The sect-era built-in library holds together: every template validates, every colour is a named tone, kit pieces
-- tile on the 4-stud grid, ruins share their intact footprint and are deterministic, budgets and roles hold, and the
-- composing generators build a whole compound inside the node budget.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectGenerator = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectGenerator)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTemplates = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTemplates)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)
local Kit = require(ReplicatedStorage.Shared.WorldArchitect.Library.ArchitectureKit)

type Template = ArchitectTemplates.Template
type NodeRecord = ArchitectRecord.NodeRecord

local BUDGET: { [string]: number } = { Dressing = 30, Kit = 60, Assembly = 250, Landmark = 400 }

local function key(c: Color3): string
	return `{math.round(c.R * 255)},{math.round(c.G * 255)},{math.round(c.B * 255)}`
end

local TONES: { [string]: boolean } = {}
for _, tone in Kit.Tones do
	TONES[key(tone)] = true
end

-- The parts under the template's Base layer group.
local function baseParts(template: Template): { NodeRecord }
	local baseKeys: { [number]: boolean } = {}
	for _, node in template.Nodes do
		if node.Record.Kind == "Group" and node.Record.Name == "Base" and node.Parent == nil then
			baseKeys[node.Key] = true
		end
	end
	local out: { NodeRecord } = {}
	for _, node in template.Nodes do
		if node.Record.Kind == "Part" and node.Parent and baseKeys[node.Parent] then
			table.insert(out, node.Record)
		end
	end
	return out
end

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or 0.05)
end

return function()
	local all = StarterTemplates.All()

	describe("the library", function()
		it("has over a hundred built-ins with unique ids", function()
			expect(#all >= 100).to.equal(true)
			local seen: { [string]: boolean } = {}
			for _, template in all do
				expect(seen[template.Id]).to.equal(nil)
				seen[template.Id] = true
			end
		end)

		it("builds every faction family in all three factions, and its ruin when it has one", function()
			for _, family in StarterTemplates.Families() do
				if family.Factions then
					for _, faction in family.Factions :: { string } do
						local id = `{family.Id}.{string.lower(faction)}`
						local intact = StarterTemplates.Get(id)
						assert(intact, `missing {id}`)
						expect(intact.Faction).to.equal(faction)
						expect(intact.Variant).to.equal("Intact")
						if family.Ruins then
							local ruin = StarterTemplates.Get(id .. ".ruin")
							assert(ruin, `missing {id}.ruin`)
							expect(ruin.Variant).to.equal("Ruined")
						end
					end
				end
			end
		end)

		it("offers every type, every faction and every region", function()
			local types, factions, regions = {}, {}, {}
			for _, template in all do
				types[template.Type] = true
				factions[template.Faction] = true
				regions[template.Region] = true
			end
			for _, kind in ArchitectConstants.TemplateTypes do
				expect(types[kind]).to.equal(true)
			end
			for _, faction in ArchitectConstants.Factions do
				expect(factions[faction]).to.equal(true)
			end
			for _, region in ArchitectConstants.Regions do
				expect(regions[region]).to.equal(true)
			end
		end)
	end)

	describe("cohesion rules", function()
		it("every colour is one of the named tones", function()
			for _, template in all do
				for _, node in template.Nodes do
					if node.Record.Kind == "Part" then
						local ok = TONES[key(node.Record.Color)] == true
						if not ok then
							error(`{template.Id}: {node.Record.Name} uses an unnamed colour {key(node.Record.Color)}`)
						end
					end
				end
			end
		end)

		it("kit pieces are centred and a whole number of modules wide, so they tile", function()
			for _, template in all do
				if template.Type == "Kit" then
					local low, high = ArchitectTransform.Bounds(baseParts(template))
					assert(low and high, `{template.Id} has no base`)
					local width = high.X - low.X
					local modules = width / Kit.Module
					if not near(modules, math.round(modules), 0.02) or not near(low.X + high.X, 0) then
						error(`{template.Id}: base spans {low.X}..{high.X}, not centred whole modules`)
					end
				end
			end
		end)

		it("every ruin keeps its intact footprint exactly", function()
			for _, template in all do
				if string.sub(template.Id, -5) == ".ruin" then
					local intact = StarterTemplates.Get(string.sub(template.Id, 1, -6))
					assert(intact, `no intact pair for {template.Id}`)
					local a, b = ArchitectTransform.Bounds(baseParts(intact))
					local c, d = ArchitectTransform.Bounds(baseParts(template))
					assert(a and b and c and d, `{template.Id}: base missing`)
					for _, axis in { "X", "Z" } do
						local same = near(
							ArchitectTransform.Component(a, axis :: any),
							ArchitectTransform.Component(c, axis :: any)
						) and near(
							ArchitectTransform.Component(b, axis :: any),
							ArchitectTransform.Component(d, axis :: any)
						)
						if not same then
							error(`{template.Id}: footprint differs from its intact pair on {axis}`)
						end
					end
				end
			end
		end)

		it("stays inside each type's part budget", function()
			for _, template in all do
				local budget = BUDGET[template.Type]
				if #template.Nodes > budget then
					error(`{template.Id}: {#template.Nodes} nodes over the {template.Type} budget of {budget}`)
				end
			end
		end)

		it("glows are decoration and cast no shadow; floors, steps and decks are walkable", function()
			for _, template in all do
				for _, node in template.Nodes do
					local record = node.Record
					if record.Kind == "Part" and record.Material == "Neon" then
						expect(record.Role).to.equal("Decor")
						expect(record.CastShadow).to.equal(false)
					end
					local name = record.Name
					for _, prefix in { "Step", "TopPaving", "Deck", "Floor", "Threshold" } do
						if string.sub(name, 1, #prefix) == prefix and record.Kind == "Part" then
							if record.Role ~= "Walkable" then
								error(`{template.Id}: {name} should be Walkable, is {record.Role}`)
							end
						end
					end
				end
			end
		end)

		it("the ruin pass is deterministic for a seed", function()
			local family = StarterTemplates.Families()[1]
			local function build(): { any }
				local b = Kit.Builder(Kit.Styles.Demonic)
				family.Build(b)
				Kit.Ruin(b, "seed")
				return Kit.Export(b)
			end
			local first, second = build(), build()
			expect(#first).to.equal(#second)
			for index, node in first do
				expect((node.Record.Position - second[index].Record.Position).Magnitude < 1e-6).to.equal(true)
			end
		end)

		it("a ruin loses most of its roof but none of its platform", function()
			local intact = StarterTemplates.Get("sm.hall.main.celestial") :: Template
			local ruin = StarterTemplates.Get("sm.hall.main.celestial.ruin") :: Template
			local function count(template: Template, prefix: string): number
				local n = 0
				for _, node in template.Nodes do
					if node.Record.Kind == "Part" and string.sub(node.Record.Name, 1, #prefix) == prefix then
						n += 1
					end
				end
				return n
			end
			expect(count(ruin, "RoofRib") < count(intact, "RoofRib")).to.equal(true)
			expect(#baseParts(ruin)).to.equal(#baseParts(intact))
			expect(count(ruin, "MeridianSeam") > 0).to.equal(true)
		end)
	end)

	describe("composing generators", function()
		local function config(kind: string, faction: string): ArchitectGenerator.Config
			local decoded = ArchitectGenerator.Decode({
				Type = kind,
				Seed = 4242,
				Center = Vector3.new(0, 0, 0),
				AreaX = 128,
				AreaZ = 128,
				Spacing = 6,
				Density = 0.5,
				FollowGround = false,
				Faction = faction,
			})
			assert(decoded, "config decodes")
			return decoded
		end

		for _, faction in Kit.FactionNames do
			it(`a {faction} sect compound has its gate, hall, side halls, tower and corners, within budget`, function()
				local layout = ArchitectGenerator.Generate(config("SectCompound", faction), nil, {}, nil)
				local counts: { [string]: number } = {}
				for _, placement in layout.Placements do
					counts[placement.TemplateId] = (counts[placement.TemplateId] or 0) + 1
				end
				local f = string.lower(faction)
				expect(counts[`sm.kit.moongate.{f}`]).to.equal(1)
				expect(counts[`sm.hall.main.{f}`]).to.equal(1)
				expect(counts[`sm.hall.side.{f}`]).to.equal(2)
				expect(counts[`sm.tower.bell.{f}`]).to.equal(1)
				expect(counts[`sm.kit.corner.{f}`]).to.equal(4)
				local nodes = #ArchitectGenerator.Expand(layout, config("SectCompound", faction), nil)
				expect(nodes <= ArchitectConstants.Limits.MaxNodesPerTransaction).to.equal(true)
			end)
		end

		it("a ruined quarter is deterministic, mostly ruins, and missing some wall", function()
			local a = ArchitectGenerator.Generate(config("RuinedQuarter", "Celestial"), nil, {}, nil)
			local b = ArchitectGenerator.Generate(config("RuinedQuarter", "Celestial"), nil, {}, nil)
			expect(#a.Placements).to.equal(#b.Placements)
			local ruins, walls = 0, 0
			for index, placement in a.Placements do
				expect(placement.TemplateId).to.equal(b.Placements[index].TemplateId)
				if string.sub(placement.TemplateId, -5) == ".ruin" then
					ruins += 1
				end
				if
					string.find(placement.TemplateId, "sm.kit.wall", 1, true)
					or string.find(placement.TemplateId, "sm.kit.moongate", 1, true)
				then
					walls += 1
				end
			end
			local intact = ArchitectGenerator.Generate(config("SectCompound", "Celestial"), nil, {}, nil)
			local intactWalls = 0
			for _, placement in intact.Placements do
				if
					string.find(placement.TemplateId, "sm.kit.wall", 1, true)
					or string.find(placement.TemplateId, "sm.kit.moongate", 1, true)
				then
					intactWalls += 1
				end
			end
			expect(ruins > #a.Placements / 3).to.equal(true)
			expect(walls < intactWalls).to.equal(true)
		end)

		it("refuses an area too small for a compound", function()
			local small = ArchitectGenerator.Decode({
				Type = "SectCompound",
				Seed = 1,
				Center = Vector3.zero,
				AreaX = 40,
				AreaZ = 40,
				Spacing = 6,
				Density = 0.5,
				FollowGround = false,
			})
			assert(small, "decodes")
			local layout = ArchitectGenerator.Generate(small, nil, {}, nil)
			expect(#layout.Placements).to.equal(0)
			expect(layout.Refused.AreaTooSmall).to.equal(1)
		end)
	end)
end
