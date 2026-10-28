--!strict
-- ArchitectCodec: every field survives a round trip, worlds chunk at record boundaries, a newer schema is refused,
-- and corrupt records are skipped rather than costing the whole world.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectCodec = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectCodec)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)

type NodeRecord = ArchitectRecord.NodeRecord

local function full(id: string): NodeRecord
	local record = ArchitectRecord.Default("Part", "Decor", id)
	record.Name = "Ruined Pillar ✦"
	record.Position = Vector3.new(12.345, -6.5, 1000.125)
	record.Orientation = Vector3.new(10, -45.5, 170)
	record.Size = Vector3.new(2.5, 13, 0.75)
	record.Shape = "Cylinder"
	record.Color = Color3.fromRGB(84, 132, 116)
	record.Material = "Marble"
	record.Transparency = 0.25
	record.Reflectance = 0.1
	record.Anchored = false
	record.CanCollide = true
	record.CanTouch = true
	record.CanQuery = true
	record.CastShadow = false
	record.Locked = true
	record.Template = "sm.ruin.column"
	return record
end

local function same(a: NodeRecord, b: NodeRecord): boolean
	for _, field in ArchitectRecord.PatchFields do
		local x, y = (a :: any)[field], (b :: any)[field]
		if typeof(x) == "Vector3" then
			if ((x :: Vector3) - (y :: Vector3)).Magnitude > 1e-3 then
				return false
			end
		elseif typeof(x) == "Color3" then
			local cx, cy = x :: Color3, y :: Color3
			if math.abs(cx.R - cy.R) + math.abs(cx.G - cy.G) + math.abs(cx.B - cy.B) > 1e-2 then
				return false
			end
		elseif x ~= y then
			return false
		end
	end
	return a.Id == b.Id and a.Parent == b.Parent and a.Kind == b.Kind and a.Template == b.Template
end

-- The encoded array as it would come back from a DataStore (JSON round trip).
local function stored(value: any): any
	return HttpService:JSONDecode(HttpService:JSONEncode(value))
end

-- Enough records that their encoded size is ~1.5 chunks, measured rather than guessed.
local function manyRecords(): { NodeRecord }
	local sample = full("n1")
	sample.Name = string.rep("x", 48)
	local each = #HttpService:JSONEncode(ArchitectCodec.EncodeRecord(sample)) + 1
	local count = math.ceil(ArchitectConstants.Persistence.ChunkBytes * 1.5 / each)
	local records: { NodeRecord } = {}
	for index = 1, count do
		local record = full(`n{index}`)
		record.Name = string.rep("x", 48)
		table.insert(records, record)
	end
	return records
end

return function()
	describe("records", function()
		it("round-trips every field through JSON", function()
			local record = full("n1")
			record.Parent = "n0"
			local back = ArchitectCodec.DecodeRecord(stored(ArchitectCodec.EncodeRecord(record)))
			assert(back, "decoded")
			expect(same(record, back)).to.equal(true)
		end)

		it("refuses a corrupted array, a bad id and an out-of-world position", function()
			local encoded = stored(ArchitectCodec.EncodeRecord(full("n1")))
			local badId = table.clone(encoded)
			badId[1] = "../x"
			expect((ArchitectCodec.DecodeRecord(badId))).to.equal(nil)
			local badPosition = table.clone(encoded)
			badPosition[5] = 1e6
			expect((ArchitectCodec.DecodeRecord(badPosition))).to.equal(nil)
			local truncated = table.move(encoded, 1, 10, 1, {})
			expect((ArchitectCodec.DecodeRecord(truncated))).to.equal(nil)
			expect((ArchitectCodec.DecodeRecord("nope"))).to.equal(nil)
		end)
	end)

	describe("worlds", function()
		it("chunks a large world at record boundaries and reads it back whole", function()
			local records = manyRecords()
			local chunks = ArchitectCodec.EncodeWorld({ NextId = #records + 1, Records = records, Strokes = {} })
			assert(chunks, "encoded")
			expect(#chunks).to.equal(2)
			for _, chunk in chunks do
				expect(#HttpService:JSONEncode(chunk) <= ArchitectConstants.Persistence.ChunkBytes).to.equal(true)
			end
			local report = ArchitectCodec.DecodeWorld(stored(chunks))
			assert(report.Doc, `decoded: {tostring(report.Reason)}`)
			expect(#report.Doc.Records).to.equal(#records)
			expect(report.Doc.NextId).to.equal(#records + 1)
			expect(report.Skipped).to.equal(0)
		end)

		it("keeps terrain strokes", function()
			local stroke = {
				Id = 3,
				Mode = "Flatten",
				Center = Vector3.new(1, 2, 3),
				Radius = 8,
				Strength = 0.5,
				Material = "Grass",
				Height = 2,
			}
			local chunks = ArchitectCodec.EncodeWorld({ NextId = 1, Records = {}, Strokes = { stroke } })
			local report = ArchitectCodec.DecodeWorld(stored(chunks))
			assert(report.Doc, "decoded")
			expect(#report.Doc.Strokes).to.equal(1)
			expect(report.Doc.Strokes[1].Mode).to.equal("Flatten")
			expect(report.Doc.Strokes[1].Height).to.equal(2)
		end)

		it("refuses a chunk from a newer schema rather than reading it lossily", function()
			local chunks = stored(ArchitectCodec.EncodeWorld({ NextId = 1, Records = { full("n1") }, Strokes = {} }))
			chunks[1].V = ArchitectConstants.SchemaVersion + 1
			local report = ArchitectCodec.DecodeWorld(chunks)
			expect(report.Doc).to.equal(nil)
			expect(report.Reason).to.equal("FutureSchema")
		end)

		it("refuses chunks out of order or missing", function()
			local chunks = stored(ArchitectCodec.EncodeWorld({ NextId = 1, Records = manyRecords(), Strokes = {} }))
			expect(#chunks > 1).to.equal(true)
			local swapped = { chunks[2], chunks[1] }
			expect(ArchitectCodec.DecodeWorld(swapped).Reason).to.equal("ChunkOrder")
			expect(ArchitectCodec.DecodeWorld({ chunks[1], "garbage" }).Doc).to.equal(nil)
		end)

		it("skips a corrupt record, keeps the rest, and re-roots its orphaned children", function()
			local group = ArchitectRecord.Default("Group", nil, "g1")
			local child = full("n2")
			child.Parent = "g1"
			local keep = full("n3")
			local chunks =
				stored(ArchitectCodec.EncodeWorld({ NextId = 4, Records = { group, child, keep }, Strokes = {} }))
			chunks[1].R[1][2] = "Script" -- corrupt the group's kind
			local report = ArchitectCodec.DecodeWorld(chunks)
			assert(report.Doc, "decoded")
			expect(report.Skipped).to.equal(1)
			expect(#report.Doc.Records).to.equal(2)
			for _, record in report.Doc.Records do
				expect(record.Parent).to.equal(nil)
			end
		end)
	end)

	describe("templates", function()
		it("a built-in round-trips through storage and validates again", function()
			local original = StarterTemplates.Get("sm.meridian.obelisk")
			assert(original, "obelisk")
			local back, reason = ArchitectCodec.DecodeTemplate(stored(ArchitectCodec.EncodeTemplate(original)), "copy")
			assert(back, `decoded: {tostring(reason)}`)
			expect(back.Id).to.equal("copy")
			expect(back.Builtin).to.equal(false)
			expect(#back.Nodes).to.equal(#original.Nodes)
			expect(back.Nodes[2].Parent).to.equal(original.Nodes[2].Parent)
		end)

		it("keeps type, faction, region and variant through storage", function()
			local original = StarterTemplates.Get("sm.hall.side.demonic.ruin")
			assert(original, "side hall ruin")
			local back = ArchitectCodec.DecodeTemplate(stored(ArchitectCodec.EncodeTemplate(original)), "copy")
			assert(back, "decoded")
			expect(back.Type).to.equal("Assembly")
			expect(back.Faction).to.equal("Demonic")
			expect(back.Region).to.equal("Any")
			expect(back.Variant).to.equal("Ruined")
		end)

		it("a template saved before the metadata existed loads with the defaults", function()
			local original = StarterTemplates.Get("sm.dress.stonelantern")
			assert(original, "lantern")
			local old = stored(ArchitectCodec.EncodeTemplate(original))
			old.Type, old.Faction, old.Region, old.Variant = nil, nil, nil, nil
			local back = ArchitectCodec.DecodeTemplate(old, "old")
			assert(back, "decoded")
			expect(back.Type).to.equal("Assembly")
			expect(back.Faction).to.equal("Any")
			expect(back.Variant).to.equal("Intact")
		end)
	end)
end
