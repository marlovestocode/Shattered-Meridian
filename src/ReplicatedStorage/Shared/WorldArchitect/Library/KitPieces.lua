--!strict
--[[
	Library/KitPieces.lua

	Owns: the modular pieces of the built-in library -- the parts an admin (and the Sect Compound generator) snaps
	together on the 4-stud grid: compound wall, leak-window wall, moon gate, corner pier, covered gallery, stair
	flight, platform tile, railing and stone path.

	THEY TILE. Every piece's Base layer is centred and a whole number of modules wide along X (the connecting axis),
	so with GRID 4 a run of walls, galleries or railings meets with no gap and no overlap, and a corner pier sits on
	the meeting point. Tests/WorldArchitect/ArchitectureLibrary.spec.lua checks every Kit-type template for it.

	A wall bay is 16 long, 2 thick, its body 7 tall under a tile coping; a moon gate bay is the same length and taller.
]]

local Kit = require(script.Parent.ArchitectureKit)
local Structures = require(script.Parent.Structures)

type Builder = Kit.Builder
type Family = Structures.Family

local KitPieces = {}

local function footing(b: Builder, length: number)
	Kit.Layer(b, "Base")
	Kit.Box(b, "Footing", Vector3.new(0, 0.6, 0), Vector3.new(length, 1.2, 3), b.Style.WallBase, "Slate")
end

KitPieces.Families = {
	{
		Id = "sm.kit.wall",
		Name = "Compound Wall",
		Category = "Walls",
		Description = "A sixteen-stud compound wall bay under a tile coping. Snaps end to end on GRID 4; the coping is a "
			.. "rooftop route.",
		Tags = { "wall", "modular", "16", "perimeter" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			footing(b, 16)
			Kit.Layer(b, "Walls")
			Kit.Box(b, "WallBody", Vector3.new(0, 4.7, 0), Vector3.new(16, 7, 2), b.Style.Wall, b.Style.WallMaterial)
			Kit.Box(
				b,
				"WallBand",
				Vector3.new(0, 7.6, 0),
				Vector3.new(16, 0.6, 2.2),
				b.Style.Beam,
				"Wood",
				{ Role = "Decor" }
			)
			Kit.Layer(b, "Roof")
			Kit.Coping(b, Vector3.new(0, 8.2, 0), 16)
		end,
	},
	{
		Id = "sm.kit.wallwindow",
		Name = "Leak-Window Wall",
		Category = "Walls",
		Description = "A compound wall bay pierced by a lattice window, so a courtyard can be glimpsed from the road.",
		Tags = { "wall", "modular", "16", "window" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			footing(b, 16)
			Kit.Layer(b, "Walls")
			for _, x in { -5, 5 } do
				Kit.Box(b, "WallBody", Vector3.new(x, 4.7, 0), Vector3.new(6, 7, 2), s.Wall, s.WallMaterial)
			end
			Kit.Box(b, "WallBody", Vector3.new(0, 2.45, 0), Vector3.new(4, 2.5, 2), s.Wall, s.WallMaterial)
			Kit.Box(b, "WallBody", Vector3.new(0, 7.45, 0), Vector3.new(4, 1.5, 2), s.Wall, s.WallMaterial)
			-- The lattice: a frame and a diamond of bars.
			for _, y in { 3.7, 6.7 } do
				Kit.Box(
					b,
					"WindowFrame",
					Vector3.new(0, y, 0),
					Vector3.new(4, 0.35, 2.1),
					s.Beam,
					"Wood",
					{ Role = "Decor" }
				)
			end
			for _, angle in { 45, -45 } do
				Kit.Box(
					b,
					"Lattice",
					Vector3.new(0, 5.2, 0),
					Vector3.new(0.25, 3.8, 0.3),
					s.Lattice,
					"Wood",
					{ Role = "Decor", Rot = Vector3.new(0, 0, angle) }
				)
			end
			Kit.Box(
				b,
				"Lattice",
				Vector3.new(0, 5.2, 0),
				Vector3.new(0.25, 3, 0.3),
				s.Lattice,
				"Wood",
				{ Role = "Decor" }
			)
			Kit.Layer(b, "Roof")
			Kit.Coping(b, Vector3.new(0, 8.2, 0), 16)
		end,
	},
	{
		Id = "sm.kit.moongate",
		Name = "Moon Gate",
		Category = "Gates",
		Description = "A compound wall bay with a round moon gate, a stone ring set around the opening and a plaque above. "
			.. "The same length as a wall bay; the gate rises above the run.",
		Tags = { "gate", "modular", "16", "entrance" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			footing(b, 16)
			Kit.Box(
				b,
				"Threshold",
				Vector3.new(0, 1.35, 0),
				Vector3.new(6, 0.3, 2.6),
				s.WallBase,
				"Slate",
				{ Role = "Walkable" }
			)
			Kit.Layer(b, "Walls")
			for _, x in { -5.5, 5.5 } do
				Kit.Box(b, "GatePier", Vector3.new(x, 5.7, 0), Vector3.new(5, 9, 2.4), s.Wall, s.WallMaterial)
			end
			Kit.Box(b, "GateHead", Vector3.new(0, 8.9, 0), Vector3.new(6, 2.6, 2.4), s.Wall, s.WallMaterial)
			-- The moon ring: eight stones around the opening's centre.
			local center = Vector3.new(0, 4.6, 0)
			for k = 0, 7 do
				local angle = math.rad(k * 45 + 22.5)
				Kit.Box(
					b,
					"MoonRing",
					center + Vector3.new(math.cos(angle) * 3.5, math.sin(angle) * 3.5, 0),
					Vector3.new(0.6, 2.9, 2.6),
					s.PlatformTrim,
					"Slate",
					{ Role = "Decor", Rot = Vector3.new(0, 0, k * 45 + 22.5) }
				)
			end
			Kit.Layer(b, "Roof")
			Kit.Coping(b, Vector3.new(0, 10.2, 0), 16)
			Kit.Layer(b, "Ornament")
			Kit.Plaque(b, Vector3.new(0, 9.2, 1.4), 3)
		end,
	},
	{
		Id = "sm.kit.corner",
		Name = "Corner Pier",
		Category = "Walls",
		Description = "A square pier with a capstone and finial, set where two wall runs meet.",
		Tags = { "wall", "modular", "corner" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(b, "Footing", Vector3.new(0, 0.6, 0), Vector3.new(4, 1.2, 4), s.WallBase, "Slate")
			Kit.Layer(b, "Walls")
			Kit.Box(b, "Pier", Vector3.new(0, 5.7, 0), Vector3.new(3.4, 9, 3.4), s.WallBase, "Cobblestone")
			Kit.Box(
				b,
				"Capstone",
				Vector3.new(0, 10.6, 0),
				Vector3.new(4, 0.8, 4),
				s.RoofTrim,
				"Slate",
				{ Role = "Walkable" }
			)
			Kit.Layer(b, "Ornament")
			Kit.Box(
				b,
				"FinialBase",
				Vector3.new(0, 11.3, 0),
				Vector3.new(1.6, 0.6, 1.6),
				s.Metal,
				"CorrodedMetal",
				{ Role = "Decor" }
			)
			Kit.Ball(b, "Finial", Vector3.new(0, 12.1, 0), 1.2, s.Accent, s.AccentMaterial)
		end,
	},
	{
		Id = "sm.kit.gallery",
		Name = "Covered Gallery",
		Category = "Galleries",
		Description = "A sixteen-stud covered walkway: a raised deck, posts, railings and a ribbed gable roof. Runs join "
			.. "end to end into the corridors that link halls.",
		Tags = { "gallery", "modular", "16", "walkable", "parkour" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(b, "GalleryFooting", Vector3.new(0, 0.4, 0), Vector3.new(16, 0.8, 6.4), s.PlatformTrim, "Slate")
			Kit.Box(
				b,
				"Deck",
				Vector3.new(0, 1.05, 0),
				Vector3.new(16, 0.5, 6),
				s.Platform,
				"Pavement",
				{ Role = "Walkable" }
			)
			Kit.Layer(b, "Frame")
			for _, x in { -7, 7 } do
				for _, z in { -2.6, 2.6 } do
					Kit.Post(b, "Post", Vector3.new(x, 1.3, z), 8, 0.9, s.Post, s.PostMaterial)
				end
			end
			for _, z in { -2.6, 2.6 } do
				Kit.Box(b, "Beam", Vector3.new(0, 9.1, z), Vector3.new(16, 0.7, 0.7), s.Beam, "Wood")
			end
			Kit.Layer(b, "Walls")
			for _, z in { -2.6, 2.6 } do
				Kit.Railing(b, Vector3.new(0, 1.3, z), 16)
			end
			Kit.Layer(b, "Roof")
			Kit.Roof(
				b,
				Vector3.new(0, 9.45, 0),
				16,
				5.2,
				{ Height = 2.6, Overhang = 1.4, Ribs = 5, Skirts = false, Ornaments = false }
			)
		end,
	},
	{
		Id = "sm.kit.stairs",
		Name = "Stair Flight",
		Category = "Stairs & Platforms",
		Description = "Four steps climbing four studs toward the back, eight wide with stone cheeks. Sits against a "
			.. "platform tile's front edge.",
		Tags = { "stairs", "modular", "walkable" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Within(b, CFrame.new(0, 0, 3) * CFrame.fromOrientation(0, math.pi, 0), function()
				Kit.Steps(b, Vector3.zero, 8, 4)
			end)
		end,
	},
	{
		Id = "sm.kit.platform",
		Name = "Platform Tile",
		Category = "Stairs & Platforms",
		Description = "A sixteen-square stone terrace four studs high: plinth, core and paving. Tiles side by side into "
			.. "any raised courtyard.",
		Tags = { "platform", "modular", "16", "walkable" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Platform(b, Vector3.zero, 16, 16, 4)
		end,
	},
	{
		Id = "sm.kit.railing",
		Name = "Railing",
		Category = "Stairs & Platforms",
		Description = "Sixteen studs of timber railing for terrace edges and bridges.",
		Tags = { "railing", "modular", "16" },
		Type = "Kit",
		Factions = Kit.FactionNames,
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Railing(b, Vector3.zero, 16)
		end,
	},
	{
		Id = "sm.kit.path",
		Name = "Stone Path",
		Category = "Stairs & Platforms",
		Description = "Eight studs of flagstone path set in a grout bed, flush with the ground.",
		Tags = { "path", "modular", "8", "walkable" },
		Type = "Kit",
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Box(
				b,
				"PathBed",
				Vector3.new(0, 0.1, 0),
				Vector3.new(8, 0.2, 8),
				Kit.Tones.StoneDark,
				"Ground",
				{ Role = "Walkable" }
			)
			for i, offset in
				{ Vector3.new(-2, 0, -2), Vector3.new(2, 0, -2), Vector3.new(-2, 0, 2), Vector3.new(2, 0, 2) }
			do
				Kit.Box(
					b,
					"Flagstone",
					offset + Vector3.new(0, 0.3, 0),
					Vector3.new(3.6, 0.3, 3.6),
					if i % 2 == 0 then Kit.Tones.Stone else Kit.Tones.StoneDark,
					"Pavement",
					{ Role = "Walkable", Rot = Vector3.new(0, (i - 2.5) * 3, 0) }
				)
			end
		end,
	},
} :: { Family }

return KitPieces
