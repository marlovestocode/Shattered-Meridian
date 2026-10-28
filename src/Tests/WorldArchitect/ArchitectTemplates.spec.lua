--!strict
-- Templates: the built-in library validates, packs name real templates, the validator refuses every malformed shape,
-- and capture -> validate -> instantiate keeps a composition's relative layout.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTemplates = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTemplates)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)

local Limits = ArchitectConstants.Limits

local function partNode(key: number, parent: number?, position: Vector3): { [string]: any }
	local record = ArchitectRecord.Default("Part", "Structure")
	record.Position = position
	return { Key = key, Parent = parent, Record = record }
end

local function groupNode(key: number, parent: number?): { [string]: any }
	local record = ArchitectRecord.Default("Group")
	return { Key = key, Parent = parent, Record = record }
end

local function template(nodes: { any }): { [string]: any }
	return { Name = "Test", Category = "Tests", Description = "", Tags = {}, Version = 1, Nodes = nodes }
end

return function()
	describe("the starter library", function()
		it("has over a hundred built-ins and every one validates", function()
			local all = StarterTemplates.All()
			expect(#all >= 100).to.equal(true)
			for _, entry in all do
				expect(entry.Builtin).to.equal(true)
				expect(#entry.Nodes > 0).to.equal(true)
			end
		end)

		it("covers the categories the brief asks for", function()
			local categories: { [string]: boolean } = {}
			for _, entry in StarterTemplates.All() do
				categories[entry.Category] = true
			end
			for _, wanted in
				{
					"Halls",
					"Gates",
					"Towers",
					"Pavilions",
					"Bridges",
					"Walls",
					"Galleries",
					"Stairs & Platforms",
					"Landmarks",
					"Lanterns & Shrines",
					"Props",
					"Nature",
					"Ruins",
				}
			do
				expect(categories[wanted]).to.equal(true)
			end
		end)

		it("every pack and perimeter id names a real built-in", function()
			for _, pack in StarterTemplates.Packs do
				for _, id in pack do
					expect(StarterTemplates.Get(id) ~= nil).to.equal(true)
				end
			end
			for _, id in StarterTemplates.Perimeter do
				expect(StarterTemplates.Get(id) ~= nil).to.equal(true)
			end
		end)
	end)

	describe("Validate", function()
		it("accepts a nested template whose parents come first", function()
			local result = ArchitectTemplates.Validate(
				template({ groupNode(1, nil), partNode(2, 1, Vector3.new(0, 1, 0)) }),
				"t1",
				false
			)
			assert(result, "expected a template")
			expect(#result.Nodes).to.equal(2)
			expect(result.Builtin).to.equal(false)
		end)

		it("refuses a forward or non-group parent, which is what rules out cycles", function()
			local forward, reason =
				ArchitectTemplates.Validate(template({ partNode(1, 2, Vector3.zero), groupNode(2, nil) }), "t", false)
			expect(forward).to.equal(nil)
			expect(string.find(reason or "", "earlier Group") ~= nil).to.equal(true)
			local partParent = ArchitectTemplates.Validate(
				template({ partNode(1, nil, Vector3.zero), partNode(2, 1, Vector3.zero) }),
				"t",
				false
			)
			expect(partParent).to.equal(nil)
		end)

		it("refuses duplicate keys, empty templates and templates with no parts", function()
			expect(
				ArchitectTemplates.Validate(
					template({ partNode(1, nil, Vector3.zero), partNode(1, nil, Vector3.zero) }),
					"t",
					false
				)
			).to.equal(nil)
			expect(ArchitectTemplates.Validate(template({}), "t", false)).to.equal(nil)
			expect(ArchitectTemplates.Validate(template({ groupNode(1, nil) }), "t", false)).to.equal(nil)
		end)

		it("refuses templates larger than the template extent", function()
			local half = Limits.MaxTemplateExtent / 2 + 10
			local nodes = { partNode(1, nil, Vector3.new(-half, 0, 0)), partNode(2, nil, Vector3.new(half, 0, 0)) }
			expect(ArchitectTemplates.Validate(template(nodes), "t", false)).to.equal(nil)
		end)

		it("refuses more nodes than the template limit", function()
			local nodes = {}
			for key = 1, Limits.MaxTemplateNodes + 1 do
				table.insert(nodes, partNode(key, nil, Vector3.zero))
			end
			expect(ArchitectTemplates.Validate(template(nodes), "t", false)).to.equal(nil)
		end)

		it("refuses nesting deeper than the depth limit", function()
			local nodes = {}
			for key = 1, Limits.MaxDepth + 1 do
				table.insert(nodes, groupNode(key, if key > 1 then key - 1 else nil))
			end
			table.insert(nodes, partNode(Limits.MaxDepth + 2, Limits.MaxDepth + 1, Vector3.zero))
			expect(ArchitectTemplates.Validate(template(nodes), "t", false)).to.equal(nil)
		end)

		it("refuses a missing name", function()
			local raw = template({ partNode(1, nil, Vector3.zero) })
			raw.Name = ""
			expect(ArchitectTemplates.Validate(raw, "t", false)).to.equal(nil)
		end)
	end)

	describe("Instantiate and Capture", function()
		it("wraps a placement in one group pivoted where it was placed", function()
			local gate = StarterTemplates.Get("sm.gate.house.celestial")
			assert(gate, "gate")
			local pivot = CFrame.new(100, 5, 50) * CFrame.fromOrientation(0, math.rad(90), 0)
			local pending = ArchitectTemplates.Instantiate(gate, pivot, nil)
			expect(pending[1].ParentRef).to.equal(nil)
			expect(pending[1].Record.Kind).to.equal("Group")
			expect((pending[1].Record.Position - pivot.Position).Magnitude < 1e-3).to.equal(true)
			for index = 2, #pending do
				expect(pending[index].ParentRef ~= nil).to.equal(true)
				expect(pending[index].Record.Template).to.equal("sm.gate.house.celestial")
			end
		end)

		it("capture then validate then instantiate reproduces the relative layout", function()
			local a = ArchitectRecord.Default("Part", "Structure", "n1")
			a.Position = Vector3.new(50, 3, 50)
			local b = ArchitectRecord.Default("Part", "Decor", "n2")
			b.Position = Vector3.new(56, 4, 48)
			b.Orientation = Vector3.new(0, 30, 0)
			local raw = ArchitectTemplates.Capture({ a, b })
			raw.Name = "Pair"
			local captured = ArchitectTemplates.Validate(raw, "tpair", false)
			assert(captured, "captured template validates")
			local placed = ArchitectTemplates.Instantiate(captured, CFrame.new(0, 0, 0), nil)
			local first, second
			for _, entry in placed do
				if entry.Record.Kind == "Part" and entry.Record.Role == "Structure" then
					first = entry.Record
				elseif entry.Record.Kind == "Part" then
					second = entry.Record
				end
			end
			assert(first and second, "both parts placed")
			expect(((second.Position - first.Position) - (b.Position - a.Position)).Magnitude < 1e-3).to.equal(true)
			expect(math.abs(second.Orientation.Y - 30) < 1e-2).to.equal(true)
		end)

		it("capture drops parents outside the captured set and never keeps ids or locks", function()
			local a = ArchitectRecord.Default("Part", "Structure", "n1")
			a.Parent = "nOutside"
			a.Locked = true
			local raw = ArchitectTemplates.Capture({ a })
			expect(raw.Nodes[1].Parent).to.equal(nil)
			expect(raw.Nodes[1].Record.Id).to.equal("")
			expect(raw.Nodes[1].Record.Locked).to.equal(false)
		end)
	end)
end
