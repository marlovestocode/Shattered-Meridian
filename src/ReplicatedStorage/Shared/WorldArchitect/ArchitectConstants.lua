--!strict
--[[
	ArchitectConstants.lua

	Owns: every number and name the World Architect (the admin world-construction tool) is bounded by -- the remote
	names, the size of the world it may build in, how much one request / one world / one history may hold, the closed
	sets of roles, shapes and materials, and the generator / terrain / persistence limits.

	ONE FILE ON PURPOSE. The server decodes every request against these limits and the client sizes its controls from
	the same table, so a limit cannot be loosened on one side only. Design: docs/architecture/2026-10-28-world-architect.md.

	Does not own: what a record is (ArchitectRecord), or which DataStore names the server writes (Server/Config/StorageConfig).
]]

local ArchitectConstants = {}

ArchitectConstants.SchemaVersion = 1

ArchitectConstants.RemoteNames = table.freeze({
	Open = "WorldArchitect_Open",
	Close = "WorldArchitect_Close",
	Page = "WorldArchitect_Page",
	Edit = "WorldArchitect_Edit",
	Undo = "WorldArchitect_Undo",
	Redo = "WorldArchitect_Redo",
	Preview = "WorldArchitect_Preview",
	Template = "WorldArchitect_Template",
	World = "WorldArchitect_World",
	Analyze = "WorldArchitect_Analyze",
	Terrain = "WorldArchitect_Terrain",
	Delta = "WorldArchitect_Delta",
})

-- The Workspace folder every built object lives under. Nothing outside it is ever touched.
ArchitectConstants.RootFolderName = "ArchitectWorld"
-- The Attribute each built Instance carries: its server-issued node id.
ArchitectConstants.IdAttribute = "ArchitectId"
ArchitectConstants.RoleAttribute = "ArchitectRole"

ArchitectConstants.Limits = table.freeze({
	-- Every position must lie inside +-WorldExtent on X and Z, and inside [MinY, MaxY].
	WorldExtent = 8192,
	MinY = -512,
	MaxY = 2048,
	-- Per-axis part size.
	MinPartSize = 0.05,
	MaxPartSize = 512,
	-- Whole working world, counting groups.
	MaxNodes = 6000,
	-- Nodes one request may create, update or delete.
	MaxNodesPerRequest = 600,
	-- Nodes one server-side expansion (template placement, generation commit, duplicate) may create.
	MaxNodesPerTransaction = 1500,
	-- Group nesting depth.
	MaxDepth = 8,
	MaxNameLength = 48,
	MaxDescriptionLength = 240,
	MaxTags = 8,
	MaxTagLength = 20,
	-- Per-admin undo depth, and the total node copies one admin's stacks may hold.
	HistoryDepth = 64,
	HistoryNodeBudget = 24000,
	-- Records per Page / per Delta push: ~150 bytes each on the wire, so a push stays near 18 KB.
	PageSize = 120,
	-- Saved templates in the library, and nodes in one template.
	MaxSavedTemplates = 200,
	MaxTemplateNodes = 400,
	-- A template's bounding box on any axis.
	MaxTemplateExtent = 400,
})

-- A part's role says what gameplay may rely on it for. The optimizer and the inspector both read this: collision is
-- never proposed off for anything but Decor.
ArchitectConstants.Roles = table.freeze({ "Structure", "Walkable", "Decor", "Barrier" })

ArchitectConstants.RoleDescriptions = table.freeze({
	Structure = "Solid construction: walls, pillars. Keeps collision and parkour queries.",
	Walkable = "A surface players stand on: floors, bridges, paths. Keeps collision and queries.",
	Decor = "Visual only. The optimizer may turn its collision, touch and queries off.",
	Barrier = "An invisible or blocking collider. Keeps collision; never optimized.",
})

ArchitectConstants.Shapes = table.freeze({ "Block", "Wedge", "CornerWedge", "Cylinder", "Ball" })

-- Template metadata: what a template is, whose it is, where it belongs, and whether it is whole. Browsable in the
-- Assets tab. Absent on a stored template (saved before these existed) means the first entry of each list but Type,
-- which defaults to Assembly.
ArchitectConstants.TemplateTypes = table.freeze({ "Kit", "Assembly", "Interior", "Landmark", "Dressing" })
ArchitectConstants.Factions = table.freeze({ "Any", "Celestial", "Demonic", "Unbound" })
ArchitectConstants.Regions = table.freeze({ "Any", "MedianParadise", "Void", "DemonicLandscape" })
ArchitectConstants.RegionNames = table.freeze({
	Any = "Any region",
	MedianParadise = "Median Paradise",
	Void = "The Void",
	DemonicLandscape = "Demonic Landscape",
})
ArchitectConstants.Variants = table.freeze({ "Intact", "Ruined" })

-- The materials a part may use. Closed, so a record can never name an Enum.Material that does not render on parts
-- (the terrain-only materials) or one that does not exist.
ArchitectConstants.Materials = table.freeze({
	"Plastic",
	"SmoothPlastic",
	"Slate",
	"Concrete",
	"Cobblestone",
	"Brick",
	"Granite",
	"Marble",
	"Basalt",
	"Rock",
	"Limestone",
	"Sandstone",
	"Pavement",
	"Wood",
	"WoodPlanks",
	"Metal",
	"CorrodedMetal",
	"DiamondPlate",
	"Foil",
	"Glass",
	"Ice",
	"Neon",
	"Fabric",
	"Grass",
	"LeafyGrass",
	"Ground",
	"Mud",
	"Sand",
	"Snow",
	"CrackedLava",
})

-- Terrain materials a brush may paint or fill with.
ArchitectConstants.TerrainMaterials = table.freeze({
	"Grass",
	"LeafyGrass",
	"Ground",
	"Mud",
	"Rock",
	"Slate",
	"Basalt",
	"Sand",
	"Sandstone",
	"Snow",
	"Glacier",
	"Limestone",
	"Pavement",
	"Cobblestone",
	"CrackedLava",
	"Salt",
})

ArchitectConstants.Terrain = table.freeze({
	Modes = table.freeze({ "Add", "Subtract", "Flatten", "Smooth", "Paint" }),
	MinRadius = 2,
	MaxRadius = 24,
	-- Voxel resolution the snapshot is read at (the engine's own).
	Resolution = 4,
	-- Strokes kept in the working log (and therefore persisted / replayable). Each applied stroke holds its voxel
	-- snapshot (up to ~13^3 voxels, ~100 KB of Lua tables) for undo and for reverting before a load, so this bounds
	-- that memory at roughly 25 MB.
	MaxStrokes = 256,
})

ArchitectConstants.Generation = table.freeze({
	Types = table.freeze({ "SectCompound", "RuinedQuarter", "Ruins", "Outpost", "Pathway", "Grove" }),
	MinArea = 16,
	MaxArea = 600,
	MinSpacing = 2,
	MaxSpacing = 120,
	MaxPlacements = 80,
	MaxExclusions = 12,
	-- Attempts per wanted placement before the generator gives up on it (and reports it).
	AttemptsPerPlacement = 12,
})

ArchitectConstants.Persistence = table.freeze({
	-- The slot every server loads at boot. Every other slot is a draft.
	LiveSlot = "Live",
	-- Where the working set is saved before a Load replaces it.
	AutosaveSlot = "Autosave",
	MaxSlots = 24,
	MaxSlotNameLength = 32,
	-- Generations each slot keeps (the newest is current; the rest are restorable snapshots).
	GenerationsKept = 8,
	-- A chunk's encoded size ceiling, in bytes of JSON. DataStore's own limit is 4 MB; this leaves headroom.
	ChunkBytes = 1_000_000,
	MaxChunks = 12,
})

ArchitectConstants.Editor = table.freeze({
	GridSteps = table.freeze({ 0, 0.25, 0.5, 1, 2, 4, 8 }),
	RotationSteps = table.freeze({ 0, 5, 15, 45, 90 }),
	DefaultGrid = 1,
	DefaultRotation = 15,
	-- How far the editor camera may zoom out.
	CameraMaxDistance = 600,
	-- Recently placed assets remembered per session.
	RecentCount = 8,
})

-- Rate limits per admin, by traffic category.
ArchitectConstants.RateLimits = table.freeze({
	Read = 20,
	Edit = 15,
	Heavy = 2,
})

return ArchitectConstants
