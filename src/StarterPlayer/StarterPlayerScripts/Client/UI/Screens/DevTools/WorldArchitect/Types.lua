--!strict
--[[
	WorldArchitect/Types.lua

	Owns: the World Architect screen's handle -- every piece of state its panels read, and the ONE intent signal they
	write through -- plus the small shared view helpers (asset keys, record lookups) both the panels and the driver use.

	ONE INTENT SIGNAL, the DevMenu's shape: a panel never calls a remote or touches the world; it fires an Intent
	({ Kind = "...", ... }) and Client/DevTools/WorldArchitect/WorldArchitectClient.lua does the work and writes the
	result back into these Values. So every control's effect is in one file, and a panel is only layout.

	Does not own: what an intent does (the driver), or the 3D viewport (EditorViewport).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTemplates = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTemplates)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)

type Value<T> = Fusion.Value<T>

local Types = {}

export type NodeRecord = ArchitectRecord.NodeRecord
export type TemplateSummary = ArchitectTemplates.TemplateSummary

export type Tool = "Select" | "Move" | "Rotate" | "Scale" | "Place" | "Terrain"

export type Tone = "Info" | "Good" | "Warn" | "Bad"

export type Intent = { [string]: any }

export type GenerationSettings = {
	Type: string,
	Seed: number,
	AreaX: number,
	AreaZ: number,
	Yaw: number,
	Spacing: number,
	Density: number,
	RotationJitter: number,
	Pack: string,
	FollowGround: boolean,
	Faction: string,
}

export type GenerationPreview = {
	Placed: number,
	Requested: number,
	Refused: { [string]: number },
	NodeCount: number,
	OverBudget: boolean,
}

export type TerrainSettings = {
	Mode: string,
	Material: string,
	Radius: number,
	Strength: number,
}

export type ServerStatus = {
	Revision: number,
	Count: number,
	Strokes: number,
	Unpublished: boolean,
	LiveGeneration: number?,
	Ready: boolean,
	StorageAvailable: boolean,
}

export type Handle = {
	IsOpen: Value<boolean>,
	-- The last thing that happened, and how it went.
	Message: Value<string>,
	Tone: Value<Tone>,
	-- The server-mirrored world: replaced (never mutated) on every delta.
	Records: Value<{ [string]: NodeRecord }>,
	Selection: Value<{ string }>,
	Hidden: Value<{ [string]: boolean }>,
	Expanded: Value<{ [string]: boolean }>,
	Tool: Value<Tool>,
	-- Clicks select the single part under the cursor rather than the whole placed item it belongs to.
	DeepPick: Value<boolean>,
	Grid: Value<number>,
	RotationStep: Value<number>,
	Space: Value<"World" | "Local">,
	SurfaceSnap: Value<boolean>,
	UndoLabel: Value<string?>,
	RedoLabel: Value<string?>,
	Templates: Value<{ TemplateSummary }>,
	-- Full templates fetched for preview / placement ghosts, by id (built-ins are read locally and never cached here).
	TemplateCache: Value<{ [string]: ArchitectTemplates.Template }>,
	-- The asset the Place tool drops: "prim:<Shape>" or a template id.
	ActiveAsset: Value<string?>,
	-- The asset the browser's detail block describes (may differ from the one being placed).
	FocusedAsset: Value<string?>,
	Favorites: Value<{ [string]: boolean }>,
	Recent: Value<{ string }>,
	Server: Value<ServerStatus?>,
	Slots: Value<{ any }>,
	Report: Value<any?>,
	-- Finding ids whose nodes the viewport is outlining.
	PreviewFindings: Value<{ [string]: boolean }>,
	Generation: Value<GenerationSettings>,
	GenerationPreview: Value<GenerationPreview?>,
	Terrain: Value<TerrainSettings>,
	LeftOpen: Value<boolean>,
	RightOpen: Value<boolean>,
	LeftTab: Value<string>,
	RightTab: Value<string>,
	Intent: RBXScriptSignal,
	Fire: (Intent) -> (),
}

Types.PrimitivePrefix = "prim:"

function Types.IsPrimitive(asset: string?): boolean
	return asset ~= nil and string.sub(asset, 1, #Types.PrimitivePrefix) == Types.PrimitivePrefix
end

function Types.PrimitiveShape(asset: string): string
	return string.sub(asset, #Types.PrimitivePrefix + 1)
end

-- The top-level item a node belongs to: itself at the root, else its outermost group. Clicking a part selects this,
-- the way a 3D editor selects the model a part is in.
function Types.TopOf(records: { [string]: NodeRecord }, id: string): string
	local current = records[id]
	local steps = 0
	while current and current.Parent and records[current.Parent] and steps < 32 do
		current = records[current.Parent]
		steps += 1
	end
	return if current then current.Id else id
end

-- `ids` plus every descendant of each, each once, parents first.
function Types.WithDescendants(records: { [string]: NodeRecord }, ids: { string }): { NodeRecord }
	local childrenOf: { [string]: { string } } = {}
	for id, record in records do
		if record.Parent then
			local list = childrenOf[record.Parent] or {}
			table.insert(list, id)
			childrenOf[record.Parent] = list
		end
	end
	local out: { NodeRecord } = {}
	local seen: { [string]: boolean } = {}
	local function visit(id: string)
		if seen[id] or records[id] == nil then
			return
		end
		seen[id] = true
		table.insert(out, records[id])
		for _, child in childrenOf[id] or {} do
			visit(child)
		end
	end
	for _, id in ids do
		visit(id)
	end
	return out
end

-- The default size a primitive is placed at.
Types.PrimitiveSize = table.freeze({
	Block = Vector3.new(4, 1, 4),
	Wedge = Vector3.new(4, 2, 4),
	CornerWedge = Vector3.new(4, 2, 4),
	Cylinder = Vector3.new(4, 4, 4),
	Ball = Vector3.new(4, 4, 4),
})

-- The records an asset would place, in its own space (pivot at the origin, floor at y = 0), with refs as ids so a
-- preview can parent them. Nil for a saved template not fetched yet.
function Types.AssetRecords(asset: string, cache: { [string]: ArchitectTemplates.Template }): { NodeRecord }?
	if Types.IsPrimitive(asset) then
		local shape = Types.PrimitiveShape(asset)
		local record = ArchitectRecord.Default("Part", "Structure", "p")
		record.Shape = shape
		record.Size = Types.PrimitiveSize[shape] or Vector3.new(4, 1, 4)
		record.Position = Vector3.new(0, record.Size.Y / 2, 0)
		record.Name = shape
		return { record }
	end
	local template = StarterTemplates.Get(asset) or cache[asset]
	if template == nil then
		return nil
	end
	local out: { NodeRecord } = {}
	for _, node in ArchitectTemplates.Instantiate(template, CFrame.identity, "a") do
		local record = table.clone(node.Record)
		record.Id = node.Ref
		record.Parent = node.ParentRef
		table.insert(out, record)
	end
	return out
end

return Types
