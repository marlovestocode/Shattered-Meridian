--!strict
--[[
	ArchitectTemplates.lua

	Owns: what a World Architect template is, the one validator every template passes through (a built-in at require
	time in the spec, an admin's saved one on save and again on load), turning a template into world-space nodes at a
	pivot, and capturing a selection back into a template.

	A TEMPLATE IS FLAT DATA. Nodes carry an integer Key and an optional Parent key; records are in TEMPLATE SPACE (the
	pivot at the origin, the floor at y = 0). There is no template-in-template reference at all, so recursion is not
	something the validator has to detect -- it cannot be expressed. Parent cycles can, and are refused: every parent
	must be a Group declared EARLIER in the list, which makes the parent graph a forest by construction.

	BOUNDED. Node count (Limits.MaxTemplateNodes), extent on every axis (Limits.MaxTemplateExtent), nesting depth
	(Limits.MaxDepth), at least one part, and every record through ArchitectRecord's own shapes.

	PLACEMENT IS ONE GROUP. Instantiate wraps the template's roots in one Group named after it, pivoted where it was
	placed, so a placed template moves, rotates, saves and undoes as one thing.

	Pending nodes are the shape a Create carries: a Ref (unique within the request), a ParentRef naming another pending
	Ref or an existing node id, and a record. WorldState.Create is the one consumer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Shared.Schema)
local ArchitectConstants = require(script.Parent.ArchitectConstants)
local ArchitectRecord = require(script.Parent.ArchitectRecord)
local ArchitectTransform = require(script.Parent.ArchitectTransform)

type NodeRecord = ArchitectRecord.NodeRecord

local Limits = ArchitectConstants.Limits

local ArchitectTemplates = {}

export type TemplateNode = {
	Key: number,
	Parent: number?,
	Record: NodeRecord,
}

export type Template = {
	Id: string,
	Name: string,
	Category: string,
	Description: string,
	Tags: { string },
	Version: number,
	-- Kit / Assembly / Landmark / Dressing; Any or a faction; Any or a region; Intact or Ruined.
	Type: string,
	Faction: string,
	Region: string,
	Variant: string,
	Builtin: boolean,
	Author: string?,
	UpdatedAt: number?,
	Nodes: { TemplateNode },
}

-- What a list shows without shipping every node: the browser's row and the preview header.
export type TemplateSummary = {
	Id: string,
	Name: string,
	Category: string,
	Description: string,
	Tags: { string },
	Version: number,
	Type: string,
	Faction: string,
	Region: string,
	Variant: string,
	Builtin: boolean,
	Author: string?,
	UpdatedAt: number?,
	NodeCount: number,
	Extent: Vector3,
	-- The ground footprint in 4-stud modules (X, Z), rounded up.
	Footprint: Vector2,
}

export type PendingNode = {
	Ref: string,
	ParentRef: string?,
	Record: NodeRecord,
}

local TagsShape = Schema.Array(Schema.String(Limits.MaxTagLength), Limits.MaxTags)

local HeaderShape = Schema.Record({
	{ "Name", Schema.NonEmptyString(Limits.MaxNameLength) },
	{ "Category", Schema.Default(Schema.String(Limits.MaxNameLength), "Saved") },
	{ "Description", Schema.Default(Schema.String(Limits.MaxDescriptionLength), "") },
	{ "Tags", Schema.Default(TagsShape, {}) },
	{ "Version", Schema.Default(Schema.Number(1, 1e6), 1) },
	{ "Type", Schema.Default(Schema.Enum(ArchitectConstants.TemplateTypes), "Assembly") },
	{ "Faction", Schema.Default(Schema.Enum(ArchitectConstants.Factions), "Any") },
	{ "Region", Schema.Default(Schema.Enum(ArchitectConstants.Regions), "Any") },
	{ "Variant", Schema.Default(Schema.Enum(ArchitectConstants.Variants), "Intact") },
})

-- Template-space positions are relative to the pivot, so they are bounded by the template extent, not the world.
local function decodeTemplateRecord(raw: unknown): (NodeRecord?, string?)
	local record, reason = ArchitectRecord.DecodeNew(raw)
	if record == nil then
		return nil, reason
	end
	local p = record.Position
	if math.max(math.abs(p.X), math.abs(p.Y), math.abs(p.Z)) > Limits.MaxTemplateExtent then
		return nil, "Position: outside template extent"
	end
	return record, nil
end

-- Validates a template from untrusted data. `id` and `builtin` are the caller's, never the payload's.
function ArchitectTemplates.Validate(raw: unknown, id: string, builtin: boolean): (Template?, string?)
	local header, headerReason = Schema.Decode(HeaderShape, raw)
	if header == nil then
		return nil, headerReason
	end
	local rawNodes = (raw :: { [string]: unknown }).Nodes
	if not Schema.IsTable(rawNodes) then
		return nil, "Nodes: expected array"
	end
	local nodes: { TemplateNode } = {}
	local kindOf: { [number]: string } = {}
	local depthOf: { [number]: number } = {}
	local partCount = 0
	for index, rawNode in ipairs(rawNodes :: { unknown }) do
		if index > Limits.MaxTemplateNodes then
			return nil, `Nodes: more than {Limits.MaxTemplateNodes}`
		end
		if not Schema.IsTable(rawNode) then
			return nil, `Nodes.{index}: expected node`
		end
		local source = rawNode :: { [string]: unknown }
		local key = Schema.Number(1, 1e6)(source.Key)
		if key == nil or key ~= math.floor(key) or kindOf[key] ~= nil then
			return nil, `Nodes.{index}: bad or duplicate Key`
		end
		local parent: number? = nil
		if source.Parent ~= nil then
			parent = Schema.Number(1, 1e6)(source.Parent)
			if parent == nil or kindOf[parent] ~= "Group" then
				-- Parent must be a Group declared earlier: no forward references, so no cycles.
				return nil, `Nodes.{index}: Parent must be an earlier Group`
			end
		end
		local record, reason = decodeTemplateRecord(source.Record)
		if record == nil then
			return nil, `Nodes.{index}.Record: {reason}`
		end
		local depth = if parent then depthOf[parent] + 1 else 1
		if depth > Limits.MaxDepth then
			return nil, `Nodes.{index}: nested deeper than {Limits.MaxDepth}`
		end
		kindOf[key] = record.Kind
		depthOf[key] = depth
		if record.Kind == "Part" then
			partCount += 1
		end
		table.insert(nodes, { Key = key, Parent = parent, Record = record })
	end
	if partCount == 0 then
		return nil, "Nodes: a template needs at least one part"
	end
	local template: Template = {
		Id = id,
		Name = header.Name,
		Category = header.Category,
		Description = header.Description,
		Tags = header.Tags,
		Version = math.floor(header.Version),
		Type = header.Type,
		Faction = header.Faction,
		Region = header.Region,
		Variant = header.Variant,
		Builtin = builtin,
		Author = nil,
		UpdatedAt = nil,
		Nodes = nodes,
	}
	local extent = ArchitectTemplates.Extent(template)
	if math.max(extent.X, extent.Y, extent.Z) > Limits.MaxTemplateExtent then
		return nil, "Nodes: template is larger than the template extent"
	end
	return template, nil
end

function ArchitectTemplates.Records(template: Template): { NodeRecord }
	local out: { NodeRecord } = {}
	for _, node in template.Nodes do
		table.insert(out, node.Record)
	end
	return out
end

-- Size of the template's bounding box.
function ArchitectTemplates.Extent(template: Template): Vector3
	local low, high = ArchitectTransform.Bounds(ArchitectTemplates.Records(template))
	if low == nil or high == nil then
		return Vector3.zero
	end
	return high - low
end

-- The radius of the template's footprint on the ground, about its pivot: what the generator spaces placements by.
function ArchitectTemplates.FootprintRadius(template: Template): number
	local low, high = ArchitectTransform.Bounds(ArchitectTemplates.Records(template))
	if low == nil or high == nil then
		return 0
	end
	local reach = math.max(math.abs(low.X), math.abs(high.X), math.abs(low.Z), math.abs(high.Z))
	return reach
end

function ArchitectTemplates.Summarize(template: Template): TemplateSummary
	local extent = ArchitectTemplates.Extent(template)
	return {
		Id = template.Id,
		Name = template.Name,
		Category = template.Category,
		Description = template.Description,
		Tags = template.Tags,
		Version = template.Version,
		Type = template.Type,
		Faction = template.Faction,
		Region = template.Region,
		Variant = template.Variant,
		Builtin = template.Builtin,
		Author = template.Author,
		UpdatedAt = template.UpdatedAt,
		NodeCount = #template.Nodes,
		Extent = extent,
		Footprint = Vector2.new(math.ceil(extent.X / 4 - 1e-3), math.ceil(extent.Z / 4 - 1e-3)),
	}
end

-- World-space pending nodes for `template` placed at `pivot`: one wrapping Group (Ref "root") plus every node, refs
-- prefixed by `refPrefix` so several placements can share one request.
function ArchitectTemplates.Instantiate(template: Template, pivot: CFrame, refPrefix: string?): { PendingNode }
	local prefix = refPrefix or ""
	local rootRef = prefix .. "root"
	local group = ArchitectRecord.WithCFrame(ArchitectRecord.Default("Group"), pivot)
	group.Name = template.Name
	group.Template = template.Id
	local out: { PendingNode } = { { Ref = rootRef, ParentRef = nil, Record = group } }
	for _, node in template.Nodes do
		local record = ArchitectRecord.WithCFrame(node.Record, pivot * ArchitectRecord.CFrameOf(node.Record))
		record.Template = template.Id
		table.insert(out, {
			Ref = prefix .. tostring(node.Key),
			ParentRef = if node.Parent then prefix .. tostring(node.Parent) else rootRef,
			Record = record,
		})
	end
	return out
end

-- A template captured from `records` (a selection with every descendant). Records' parents outside the set become
-- roots. Positions become relative to the set's pivot. The result still has to pass Validate -- the caller runs it.
function ArchitectTemplates.Capture(records: { NodeRecord }): { [string]: any }
	local pivot = CFrame.new(ArchitectTransform.PivotOf(records))
	local inverse = pivot:Inverse()
	local keyOf: { [string]: number } = {}
	for index, record in records do
		keyOf[record.Id] = index
	end
	-- Order parents before children: depth-first from the roots, so Validate's earlier-parent rule holds.
	local childrenOf: { [string]: { NodeRecord } } = {}
	local roots: { NodeRecord } = {}
	for _, record in records do
		if record.Parent and keyOf[record.Parent] then
			local list = childrenOf[record.Parent] or {}
			table.insert(list, record)
			childrenOf[record.Parent] = list
		else
			table.insert(roots, record)
		end
	end
	local nodes: { { [string]: any } } = {}
	local function visit(record: NodeRecord, parentKey: number?)
		local relative = ArchitectRecord.WithCFrame(record, inverse * ArchitectRecord.CFrameOf(record))
		relative.Id = ""
		relative.Parent = nil
		relative.Rev = 0
		relative.Locked = false
		table.insert(nodes, { Key = keyOf[record.Id], Parent = parentKey, Record = relative })
		for _, child in (childrenOf[record.Id] or {}) :: { NodeRecord } do
			visit(child, keyOf[record.Id])
		end
	end
	for _, root in roots do
		visit(root, nil)
	end
	return { Nodes = nodes }
end

return ArchitectTemplates
