--!strict
--[[
	ArchitectCodec.lua

	Owns: how World Architect content is written to a DataStore and read back -- a node record as a compact array, a
	whole world as size-bounded chunks, terrain strokes, saved templates, and the schema-version gate on the way in.

	EXPLICIT FIELDS BOTH WAYS. Encode lists every field it writes; decode rebuilds a raw table and hands it to the SAME
	validators a client request goes through (ArchitectRecord.DecodeNew, ArchitectTemplates.Validate). A stored record
	is untrusted data like any other: a corrupted or hand-edited key cannot put anything into the world that a request
	could not. This is the bug class the Move Editor's Art/Grab persistence failure taught (an encoder that forgot a
	field); Tests/WorldArchitect/ArchitectCodec.spec.lua round-trips every field.

	NAMES, NOT INDICES, for shapes, materials and roles: reordering ArchitectConstants' lists must never re-skin a saved
	world. Numbers round to a thousandth so a save/load round trip is stable.

	CHUNKS SPLIT AT RECORD BOUNDARIES, never mid-string (a byte split can cut a UTF-8 name in half). Each chunk's JSON is
	at most Persistence.ChunkBytes; chunk 1 also carries the header (version, next id, terrain strokes). A world that
	would need more than Persistence.MaxChunks is refused at encode, before anything is written.

	VERSIONS. Every chunk carries V. A chunk from a NEWER schema than this build knows is refused (FutureSchema) rather
	than read lossily -- an older server must never load and then re-save a newer world. Older versions migrate in
	`migrate` below (v1 is the first; the function is where v2's step goes).
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Shared.Schema)
local ArchitectConstants = require(script.Parent.ArchitectConstants)
local ArchitectRecord = require(script.Parent.ArchitectRecord)
local ArchitectTemplates = require(script.Parent.ArchitectTemplates)

type NodeRecord = ArchitectRecord.NodeRecord

local Persistence = ArchitectConstants.Persistence

local ArchitectCodec = {}

export type Stroke = {
	Id: number,
	Mode: string,
	Center: Vector3,
	Radius: number,
	Strength: number,
	Material: string,
	-- Flatten's target height.
	Height: number?,
}

export type WorldDoc = {
	NextId: number,
	Records: { NodeRecord },
	Strokes: { Stroke },
}

local FLAG_ANCHORED = 1
local FLAG_COLLIDE = 2
local FLAG_TOUCH = 4
local FLAG_QUERY = 8
local FLAG_SHADOW = 16
local FLAG_LOCKED = 32

local function round(n: number): number
	return math.round(n * 1000) / 1000
end

local function colorInt(c: Color3): number
	return math.round(c.R * 255) * 65536 + math.round(c.G * 255) * 256 + math.round(c.B * 255)
end

local function intColor(n: number): Color3
	local value = math.clamp(math.floor(n), 0, 0xFFFFFF)
	return Color3.fromRGB(value // 65536, (value // 256) % 256, value % 256)
end

function ArchitectCodec.EncodeRecord(record: NodeRecord): { any }
	local flags = (if record.Anchored then FLAG_ANCHORED else 0)
		+ (if record.CanCollide then FLAG_COLLIDE else 0)
		+ (if record.CanTouch then FLAG_TOUCH else 0)
		+ (if record.CanQuery then FLAG_QUERY else 0)
		+ (if record.CastShadow then FLAG_SHADOW else 0)
		+ (if record.Locked then FLAG_LOCKED else 0)
	local p, o, s = record.Position, record.Orientation, record.Size
	return {
		record.Id,
		record.Kind,
		record.Parent or "",
		record.Name,
		round(p.X),
		round(p.Y),
		round(p.Z),
		round(o.X),
		round(o.Y),
		round(o.Z),
		round(s.X),
		round(s.Y),
		round(s.Z),
		record.Shape,
		colorInt(record.Color),
		record.Material,
		round(record.Transparency),
		round(record.Reflectance),
		flags,
		record.Role,
		record.Template or "",
	}
end

local number = Schema.Number(-1e7, 1e7)

local function num(raw: { unknown }, index: number): number?
	return (number(raw[index]))
end

local function has(flags: number, bit: number): boolean
	return (flags // bit) % 2 == 1
end

-- The raw table a request would carry, rebuilt from an encoded array; validated by the caller. Nil when the array is
-- not even the right shape.
local function rawFromArray(raw: unknown): { [string]: any }?
	if not Schema.IsTable(raw) then
		return nil
	end
	local a = raw :: { unknown }
	local px, py, pz = num(a, 5), num(a, 6), num(a, 7)
	local ox, oy, oz = num(a, 8), num(a, 9), num(a, 10)
	local sx, sy, sz = num(a, 11), num(a, 12), num(a, 13)
	local color, transparency, reflectance, flags = num(a, 15), num(a, 17), num(a, 18), num(a, 19)
	if
		px == nil
		or py == nil
		or pz == nil
		or ox == nil
		or oy == nil
		or oz == nil
		or sx == nil
		or sy == nil
		or sz == nil
		or color == nil
		or transparency == nil
		or reflectance == nil
		or flags == nil
	then
		return nil
	end
	local f = math.floor(flags :: number)
	return {
		Id = a[1],
		Kind = a[2],
		Parent = if a[3] == "" then nil else a[3],
		Name = a[4],
		Position = Vector3.new(px :: number, py :: number, pz :: number),
		Orientation = Vector3.new(ox :: number, oy :: number, oz :: number),
		Size = Vector3.new(sx :: number, sy :: number, sz :: number),
		Shape = a[14],
		Color = intColor(color :: number),
		Material = a[16],
		Transparency = transparency,
		Reflectance = reflectance,
		Anchored = has(f, FLAG_ANCHORED),
		CanCollide = has(f, FLAG_COLLIDE),
		CanTouch = has(f, FLAG_TOUCH),
		CanQuery = has(f, FLAG_QUERY),
		CastShadow = has(f, FLAG_SHADOW),
		Locked = has(f, FLAG_LOCKED),
		Role = a[20],
		Template = if a[21] == "" then nil else a[21],
	}
end

-- A stored record, validated exactly as a new node from a client is, with its id and parent checked too.
function ArchitectCodec.DecodeRecord(raw: unknown): (NodeRecord?, string?)
	local fields = rawFromArray(raw)
	if fields == nil then
		return nil, "malformed record"
	end
	local id = ArchitectRecord.IdShape(fields.Id)
	if id == nil then
		return nil, "malformed id"
	end
	local parent: string? = nil
	if fields.Parent ~= nil then
		parent = ArchitectRecord.IdShape(fields.Parent)
		if parent == nil then
			return nil, "malformed parent"
		end
	end
	local record, reason = ArchitectRecord.DecodeNew(fields)
	if record == nil then
		return nil, reason
	end
	record.Id = id :: string
	record.Parent = parent
	record.Rev = 1
	-- DecodeNew applies role defaults for unnamed flags; a stored record names every one, so restore them exactly.
	record.Anchored = fields.Anchored
	record.CanCollide = fields.CanCollide
	record.CanTouch = fields.CanTouch
	record.CanQuery = fields.CanQuery
	record.CastShadow = fields.CastShadow
	record.Locked = fields.Locked
	return record, nil
end

function ArchitectCodec.EncodeStroke(stroke: Stroke): { any }
	return {
		stroke.Id,
		stroke.Mode,
		round(stroke.Center.X),
		round(stroke.Center.Y),
		round(stroke.Center.Z),
		round(stroke.Radius),
		round(stroke.Strength),
		stroke.Material,
		if stroke.Height then round(stroke.Height) else "",
	}
end

local StrokeModeShape = Schema.Enum(ArchitectConstants.Terrain.Modes)
local TerrainMaterialShape = Schema.Enum(ArchitectConstants.TerrainMaterials)

function ArchitectCodec.DecodeStroke(raw: unknown): Stroke?
	if not Schema.IsTable(raw) then
		return nil
	end
	local a = raw :: { unknown }
	local id, cx, cy, cz = num(a, 1), num(a, 3), num(a, 4), num(a, 5)
	local mode = StrokeModeShape(a[2])
	local material = TerrainMaterialShape(a[8])
	local radius = Schema.Number(ArchitectConstants.Terrain.MinRadius, ArchitectConstants.Terrain.MaxRadius)(a[6])
	local strength = Schema.Number(0, 1)(a[7])
	if
		id == nil
		or cx == nil
		or cy == nil
		or cz == nil
		or mode == nil
		or material == nil
		or radius == nil
		or strength == nil
	then
		return nil
	end
	local center, centerReason = ArchitectRecord.PositionShape(Vector3.new(cx :: number, cy :: number, cz :: number))
	if centerReason ~= nil or center == nil then
		return nil
	end
	return {
		Id = math.floor(id :: number),
		Mode = mode :: string,
		Center = center :: Vector3,
		Radius = radius :: number,
		Strength = strength :: number,
		Material = material :: string,
		Height = num(a, 9),
	}
end

local function jsonSize(value: any): number
	return #HttpService:JSONEncode(value)
end

-- A world as chunk tables, each under Persistence.ChunkBytes of JSON. Nil and a reason when it would need too many.
function ArchitectCodec.EncodeWorld(doc: WorldDoc): ({ { [string]: any } }?, string?)
	local strokes: { any } = {}
	for _, stroke in doc.Strokes do
		table.insert(strokes, ArchitectCodec.EncodeStroke(stroke))
	end
	local chunks: { { [string]: any } } = {}
	local current: { [string]: any } = {
		V = ArchitectConstants.SchemaVersion,
		I = 1,
		N = doc.NextId,
		T = strokes,
		R = {},
	}
	local size = jsonSize(current)
	for _, record in doc.Records do
		local encoded = ArchitectCodec.EncodeRecord(record)
		local cost = jsonSize(encoded) + 1
		if size + cost > Persistence.ChunkBytes and #current.R > 0 then
			table.insert(chunks, current)
			current = { V = ArchitectConstants.SchemaVersion, I = #chunks + 1, R = {} }
			size = jsonSize(current)
		end
		table.insert(current.R, encoded)
		size += cost
	end
	table.insert(chunks, current)
	if #chunks > Persistence.MaxChunks then
		return nil, "WorldTooLarge"
	end
	return chunks, nil
end

-- Older chunk versions are brought up to the current one here. v1 is the first schema.
local function migrate(chunk: { [string]: any }): ({ [string]: any }?, string?)
	local version = Schema.NumberOr(chunk.V, 0)
	if version > ArchitectConstants.SchemaVersion then
		return nil, "FutureSchema"
	end
	if version < 1 then
		return nil, "UnknownSchema"
	end
	return chunk, nil
end

export type DecodeReport = {
	Doc: WorldDoc?,
	Reason: string?,
	-- Records and strokes that failed validation and were left out, by index. A partially bad save still loads
	-- everything that is good, and says how much it dropped.
	Skipped: number,
}

-- Chunks back into a world. Chunks must be in order and complete; records are validated one by one, and any whose
-- parent did not survive is re-rooted rather than dropped.
function ArchitectCodec.DecodeWorld(rawChunks: { unknown }): DecodeReport
	local records: { NodeRecord } = {}
	local strokes: { Stroke } = {}
	local nextId = 1
	local skipped = 0
	for index, rawChunk in rawChunks do
		if not Schema.IsTable(rawChunk) then
			return { Doc = nil, Reason = `MissingChunk{index}`, Skipped = skipped }
		end
		local chunk, reason = migrate(rawChunk :: { [string]: any })
		if chunk == nil then
			return { Doc = nil, Reason = reason, Skipped = skipped }
		end
		if Schema.NumberOr(chunk.I, -1) ~= index then
			return { Doc = nil, Reason = "ChunkOrder", Skipped = skipped }
		end
		if index == 1 then
			nextId = math.max(math.floor(Schema.NumberOr(chunk.N, 1)), 1)
			if Schema.IsTable(chunk.T) then
				for _, rawStroke in ipairs(chunk.T :: { unknown }) do
					local stroke = ArchitectCodec.DecodeStroke(rawStroke)
					if stroke then
						table.insert(strokes, stroke)
					else
						skipped += 1
					end
				end
			end
		end
		if Schema.IsTable(chunk.R) then
			for _, rawRecord in ipairs(chunk.R :: { unknown }) do
				local record = ArchitectCodec.DecodeRecord(rawRecord)
				if record then
					table.insert(records, record)
				else
					skipped += 1
				end
			end
		end
	end
	local ids: { [string]: NodeRecord } = {}
	for _, record in records do
		ids[record.Id] = record
	end
	for _, record in records do
		if record.Parent and (ids[record.Parent] == nil or ids[record.Parent].Kind ~= "Group") then
			record.Parent = nil
		end
	end
	return { Doc = { NextId = nextId, Records = records, Strokes = strokes }, Reason = nil, Skipped = skipped }
end

--
-- Templates
--

function ArchitectCodec.EncodeTemplate(template: ArchitectTemplates.Template): { [string]: any }
	local nodes: { any } = {}
	for _, node in template.Nodes do
		table.insert(nodes, { node.Key :: any, node.Parent or 0, ArchitectCodec.EncodeRecord(node.Record) })
	end
	return {
		V = ArchitectConstants.SchemaVersion,
		Name = template.Name,
		Category = template.Category,
		Description = template.Description,
		Tags = template.Tags,
		Version = template.Version,
		Type = template.Type,
		Faction = template.Faction,
		Region = template.Region,
		Variant = template.Variant,
		Author = template.Author or "",
		UpdatedAt = template.UpdatedAt or 0,
		Nodes = nodes,
	}
end

-- A stored template, validated by ArchitectTemplates.Validate like a freshly captured one.
function ArchitectCodec.DecodeTemplate(raw: unknown, id: string): (ArchitectTemplates.Template?, string?)
	if not Schema.IsTable(raw) then
		return nil, "malformed template"
	end
	local source = raw :: { [string]: any }
	local migrated, reason = migrate(source)
	if migrated == nil then
		return nil, reason
	end
	local nodes: { any } = {}
	if Schema.IsTable(source.Nodes) then
		for _, entry in ipairs(source.Nodes :: { unknown }) do
			if Schema.IsTable(entry) then
				local e = entry :: { unknown }
				local fields = rawFromArray(e[3])
				if fields == nil then
					return nil, "malformed template node"
				end
				local parent = Schema.NumberOr(e[2], 0)
				table.insert(nodes, { Key = e[1], Parent = if parent > 0 then parent else nil, Record = fields })
			end
		end
	end
	local template, validateReason = ArchitectTemplates.Validate({
		Name = source.Name,
		Category = source.Category,
		Description = source.Description,
		Tags = source.Tags,
		Version = source.Version,
		-- Absent on templates saved before these existed: Validate's defaults fill them, so no migration step.
		Type = source.Type,
		Faction = source.Faction,
		Region = source.Region,
		Variant = source.Variant,
		Nodes = nodes,
	}, id, false)
	if template == nil then
		return nil, validateReason
	end
	template.Author = if Schema.IsString(source.Author) and source.Author ~= "" then source.Author else nil
	template.UpdatedAt = if Schema.IsNumber(source.UpdatedAt) then source.UpdatedAt else nil
	return template, nil
end

return ArchitectCodec
