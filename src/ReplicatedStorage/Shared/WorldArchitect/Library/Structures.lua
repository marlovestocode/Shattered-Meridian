--!strict
--[[
	Library/Structures.lua

	Owns: the sect-era buildings of the built-in library -- the assemblies an admin places as whole structures: main
	hall, side hall, barracks, gatehouse, pavilion, pagoda, bell tower, watch post and covered bridge. Each is ONE
	family built through ArchitectureKit with a style argument; StarterTemplates expands every family into its
	Celestial, Demonic and Unbound variants and the ruin of each.

	Every hall shares one frame routine (`hall` below): a stone platform with front steps, columns with bracket sets on
	the bay grid, beams, a frieze under the eaves, wall panels between the columns, and single or double eaves. That is
	what makes a main hall, a side hall and a barracks read as one sect's work: same bay, same column, same eave.

	Layers, in every structure: Base (platform, steps -- never ruined), Frame (columns, beams), Walls, Roof, Ornament.
	Fronts face +Z.
]]

local Kit = require(script.Parent.ArchitectureKit)

type Builder = Kit.Builder

local Structures = {}

export type Family = {
	Id: string,
	Name: string,
	Category: string,
	Description: string,
	Tags: { string },
	Type: string,
	Region: string?,
	-- Built once per faction (nil: once, faction Any, Celestial style).
	Factions: { string }?,
	-- Also emit the ruin of every variant.
	Ruins: boolean?,
	-- Set when the family is itself a ruin (a landmark built broken).
	Ruined: boolean?,
	-- The style a faction-less family is built in (default Celestial).
	Style: string?,
	-- A fit-out set: the building family whose interior it furnishes (placed at that building's own pivot).
	For: string?,
	Build: (b: Builder) -> (),
}

local BAY = Kit.Bay

type HallSpec = {
	BaysX: number,
	BaysZ: number,
	PlatformHeight: number,
	ColumnHeight: number,
	Front: { Kit.PanelKind },
	Back: { Kit.PanelKind },
	Sides: { Kit.PanelKind },
	Double: boolean,
	Ribs: number,
	StepWidth: number,
}

-- The shared hall frame. Returns the eave height, the half width and the half depth.
local function hall(b: Builder, spec: HallSpec): (number, number, number)
	local w, d = spec.BaysX * BAY, spec.BaysZ * BAY
	local ph, H = spec.PlatformHeight, spec.ColumnHeight
	local hw, hd = w / 2, d / 2

	Kit.Layer(b, "Base")
	Kit.Platform(b, Vector3.zero, w + 6, d + 6, ph)
	Kit.Within(b, CFrame.new(0, 0, hd + 3 + ph * 1.5) * CFrame.fromOrientation(0, math.pi, 0), function()
		Kit.Steps(b, Vector3.zero, spec.StepWidth, ph)
	end)

	Kit.Layer(b, "Frame")
	local eave = ph + H + 1
	for i = 0, spec.BaysX do
		local x = -hw + i * BAY
		Kit.Column(b, Vector3.new(x, ph, hd), H)
		Kit.Column(b, Vector3.new(x, ph, -hd), H)
	end
	for j = 1, spec.BaysZ - 1 do
		local z = -hd + j * BAY
		Kit.Column(b, Vector3.new(-hw, ph, z), H)
		Kit.Column(b, Vector3.new(hw, ph, z), H)
	end
	local beamY = ph + H - 0.45
	Kit.Beam(b, Vector3.new(-hw, beamY, hd), Vector3.new(hw, beamY, hd))
	Kit.Beam(b, Vector3.new(-hw, beamY, -hd), Vector3.new(hw, beamY, -hd))
	Kit.Beam(b, Vector3.new(-hw, beamY, -hd), Vector3.new(-hw, beamY, hd))
	Kit.Beam(b, Vector3.new(hw, beamY, -hd), Vector3.new(hw, beamY, hd))
	-- The frieze closes the band between the beams and the eave, and is the hall's ceiling.
	Kit.Box(b, "Frieze", Vector3.new(0, ph + H + 0.5, 0), Vector3.new(w - 1, 1, d - 1), b.Style.Beam, "Wood")

	Kit.Layer(b, "Walls")
	local span = BAY - 1.4
	local wallHeight = H - 0.9
	for i = 1, spec.BaysX do
		local x = -hw + (i - 0.5) * BAY
		Kit.Panel(b, Vector3.new(x, ph, hd), span, wallHeight, spec.Front[i] or "Solid")
		Kit.Panel(b, Vector3.new(x, ph, -hd), span, wallHeight, spec.Back[i] or "Solid")
	end
	for j = 1, spec.BaysZ do
		local z = -hd + (j - 0.5) * BAY
		for _, side in { -1, 1 } do
			Kit.Within(b, CFrame.new(side * hw, 0, z) * CFrame.fromOrientation(0, math.pi / 2, 0), function()
				Kit.Panel(b, Vector3.new(0, ph, 0), span, wallHeight, spec.Sides[j] or "Solid")
			end)
		end
	end

	Kit.Layer(b, "Roof")
	if spec.Double then
		Kit.EaveRing(b, Vector3.new(0, eave, 0), w + 6, d + 6, 6.5, 3)
		local inset = 9
		Kit.Box(
			b,
			"Clerestory",
			Vector3.new(0, eave + 3, 0),
			Vector3.new(w - inset, 4, d - inset),
			b.Style.Wall,
			b.Style.WallMaterial
		)
		Kit.Roof(
			b,
			Vector3.new(0, eave + 5, 0),
			w - inset,
			d - inset,
			{ Height = (d - inset + 6) / 2.6, Ribs = spec.Ribs }
		)
	else
		Kit.Roof(b, Vector3.new(0, eave, 0), w, d, { Height = (d + 6) / 3, Ribs = spec.Ribs })
	end
	return eave, hw, hd
end

local function frontLanterns(b: Builder, hw: number, hd: number, y: number)
	for _, side in { -1, 1 } do
		Kit.HangingLantern(b, Vector3.new(side * (hw - 2), y, hd + 1.6))
	end
end

Structures.Families = {
	{
		Id = "sm.hall.main",
		Name = "Main Hall",
		Category = "Halls",
		Description = "The sect's great hall: three bays by two on a raised platform, double eaves, screened front bays "
			.. "and a central door under the name plaque.",
		Tags = { "hall", "landmark", "double eave", "walkable roof" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local eave, hw, hd = hall(b, {
				BaysX = 3,
				BaysZ = 2,
				PlatformHeight = 4,
				ColumnHeight = 14,
				Front = { "Screen", "Door", "Screen" },
				Back = { "Window", "Solid", "Window" },
				Sides = { "Window", "Solid" },
				Double = true,
				Ribs = 9,
				StepWidth = 16,
			})
			Kit.Layer(b, "Ornament")
			Kit.Plaque(b, Vector3.new(0, eave - 3.5, hd + 0.9), 6)
			frontLanterns(b, hw, hd, eave - 3)
		end,
	},
	{
		Id = "sm.hall.side",
		Name = "Side Hall",
		Category = "Halls",
		Description = "A two-bay hall for the flanks of a courtyard: door and window on the front, windows behind.",
		Tags = { "hall", "modular", "courtyard" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local eave, hw, hd = hall(b, {
				BaysX = 2,
				BaysZ = 1,
				PlatformHeight = 2,
				ColumnHeight = 11,
				Front = { "Door", "Window" },
				Back = { "Window", "Window" },
				Sides = { "Solid" },
				Double = false,
				Ribs = 6,
				StepWidth = 8,
			})
			Kit.Layer(b, "Ornament")
			Kit.HangingLantern(b, Vector3.new(-hw + BAY / 2 + 4, eave - 2.5, hd + 1.6))
		end,
	},
	{
		Id = "sm.hall.barracks",
		Name = "Barracks",
		Category = "Halls",
		Description = "A long three-bay hall where disciples sleep and train; a door in the middle bay, windows along both sides.",
		Tags = { "hall", "long", "courtyard" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local eave, hw, hd = hall(b, {
				BaysX = 3,
				BaysZ = 1,
				PlatformHeight = 2,
				ColumnHeight = 10,
				Front = { "Window", "Door", "Window" },
				Back = { "Window", "Window", "Window" },
				Sides = { "Solid" },
				Double = false,
				Ribs = 8,
				StepWidth = 8,
			})
			Kit.Layer(b, "Ornament")
			frontLanterns(b, hw, hd, eave - 2.5)
		end,
	},
	{
		Id = "sm.gate.house",
		Name = "Gatehouse",
		Category = "Gates",
		Description = "The sect's front gate building: three bays, the middle one open with lacquered leaves swung back, "
			.. "a name plaque over it and a guardian at either side of the steps.",
		Tags = { "gate", "landmark", "entrance" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			local ph, H = 2, 11
			Kit.Layer(b, "Base")
			Kit.Platform(b, Vector3.zero, 28, 16, ph)
			for _, side in { 1, -1 } do
				Kit.Within(
					b,
					CFrame.new(0, 0, side * (8 + ph * 1.5))
						* CFrame.fromOrientation(0, if side > 0 then math.pi else 0, 0),
					function()
						Kit.Steps(b, Vector3.zero, 8, ph)
					end
				)
			end
			Kit.Layer(b, "Frame")
			for _, x in { -12, -4, 4, 12 } do
				for _, z in { -6, 6 } do
					Kit.Column(b, Vector3.new(x, ph, z), H)
				end
			end
			local beamY = ph + H - 0.45
			for _, z in { -6, 6 } do
				Kit.Beam(b, Vector3.new(-12, beamY, z), Vector3.new(12, beamY, z))
			end
			for _, x in { -12, 12 } do
				Kit.Beam(b, Vector3.new(x, beamY, -6), Vector3.new(x, beamY, 6))
			end
			Kit.Box(b, "Frieze", Vector3.new(0, ph + H + 0.5, 0), Vector3.new(23, 1, 11), s.Beam, "Wood")
			Kit.Beam(b, Vector3.new(-4, ph + 10, 0), Vector3.new(4, ph + 10, 0), 1.1)
			Kit.Layer(b, "Walls")
			for _, x in { -8, 8 } do
				Kit.Panel(b, Vector3.new(x, ph, 6), 6.6, H - 0.9, "Solid")
				Kit.Panel(b, Vector3.new(x, ph, -6), 6.6, H - 0.9, "Solid")
			end
			for _, side in { -1, 1 } do
				Kit.Within(b, CFrame.new(side * 12, 0, 0) * CFrame.fromOrientation(0, math.pi / 2, 0), function()
					Kit.Panel(b, Vector3.new(0, ph, 0), 10.6, H - 0.9, "Solid")
				end)
			end
			-- Gate leaves, swung inward on their hinges, studded with bronze.
			for _, side in { -1, 1 } do
				local hinge = CFrame.new(side * 3.8, ph + 4.5, 0) * CFrame.fromOrientation(0, math.rad(side * 70), 0)
				Kit.PartAt(
					b,
					"GateLeaf",
					hinge * CFrame.new(-side * 1.75, 0, 0),
					Vector3.new(3.5, 9, 0.5),
					s.Post,
					s.PostMaterial
				)
				for row = -1, 1 do
					Kit.PartAt(
						b,
						"GateStud",
						hinge * CFrame.new(-side * 1.75, row * 2.6, 0.3),
						Vector3.new(0.5, 0.5, 0.5),
						s.Metal,
						"Metal",
						{ Shape = "Ball", Role = "Decor" }
					)
				end
			end
			Kit.Layer(b, "Roof")
			Kit.Roof(b, Vector3.new(0, ph + H + 1, 0), 24, 12, { Height = 6, Ribs = 6 })
			Kit.Layer(b, "Ornament")
			Kit.Plaque(b, Vector3.new(0, ph + 11.2, 6.9), 5)
			for _, side in { -1, 1 } do
				Kit.Guardian(b, Vector3.new(side * 8, 0, 11), 180)
			end
		end,
	},
	{
		Id = "sm.pavilion.square",
		Name = "Pavilion",
		Category = "Pavilions",
		Description = "An open square pavilion for a courtyard or a cliff edge: four columns, benches between them, a hip "
			.. "roof with a lantern hung at its heart.",
		Tags = { "pavilion", "open", "courtyard", "walkable roof" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local ph, H = 2, 9
			Kit.Layer(b, "Base")
			Kit.Platform(b, Vector3.zero, 20, 20, ph)
			Kit.Within(b, CFrame.new(0, 0, 10 + ph * 1.5) * CFrame.fromOrientation(0, math.pi, 0), function()
				Kit.Steps(b, Vector3.zero, 8, ph)
			end)
			Kit.Layer(b, "Frame")
			for _, x in { -7, 7 } do
				for _, z in { -7, 7 } do
					Kit.Column(b, Vector3.new(x, ph, z), H)
				end
			end
			local beamY = ph + H - 0.45
			Kit.Beam(b, Vector3.new(-7, beamY, 7), Vector3.new(7, beamY, 7))
			Kit.Beam(b, Vector3.new(-7, beamY, -7), Vector3.new(7, beamY, -7))
			Kit.Beam(b, Vector3.new(-7, beamY, -7), Vector3.new(-7, beamY, 7))
			Kit.Beam(b, Vector3.new(7, beamY, -7), Vector3.new(7, beamY, 7))
			Kit.Layer(b, "Walls")
			Kit.Railing(b, Vector3.new(0, ph, -7), 12)
			for _, side in { -1, 1 } do
				Kit.Within(b, CFrame.new(side * 7, 0, 0) * CFrame.fromOrientation(0, math.pi / 2, 0), function()
					Kit.Railing(b, Vector3.new(0, ph, 0), 12)
				end)
			end
			Kit.Layer(b, "Roof")
			Kit.Roof(b, Vector3.new(0, ph + H + 1, 0), 14, 14, { Height = 5.5, Ribs = 5 })
			Kit.Layer(b, "Ornament")
			Kit.HangingLantern(b, Vector3.new(0, ph + H - 1.5, 0))
		end,
	},
	{
		Id = "sm.tower.pagoda",
		Name = "Pagoda",
		Category = "Towers",
		Description = "A three-tier pagoda on a stone platform: each tier narrower under its own eave, a hip roof and a "
			.. "bronze spire tipped with a Meridian light.",
		Tags = { "tower", "landmark", "tall" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Platform(b, Vector3.zero, 22, 22, 2)
			Kit.Within(b, CFrame.new(0, 0, 11 + 3) * CFrame.fromOrientation(0, math.pi, 0), function()
				Kit.Steps(b, Vector3.zero, 8, 2)
			end)
			local y = 2
			local sizes = { 16, 12, 8 }
			for tier, size in sizes do
				local half = size / 2
				Kit.Layer(b, "Frame")
				if tier > 1 then
					Kit.Box(
						b,
						"FloorSlab",
						Vector3.new(0, y - 0.3, 0),
						Vector3.new(size + 1, 0.6, size + 1),
						s.Platform,
						"Pavement",
						{ Role = "Walkable" }
					)
				end
				for _, x in { -half, half } do
					for _, z in { -half, half } do
						Kit.Post(b, "CornerPost", Vector3.new(x, y, z), 7, 1.2, s.Post, s.PostMaterial)
					end
				end
				Kit.Layer(b, "Walls")
				Kit.Panel(b, Vector3.new(0, y, half), size - 1.2, 7, if tier == 1 then "Door" else "Window")
				Kit.Panel(b, Vector3.new(0, y, -half), size - 1.2, 7, "Solid")
				for _, side in { -1, 1 } do
					Kit.Within(b, CFrame.new(side * half, 0, 0) * CFrame.fromOrientation(0, math.pi / 2, 0), function()
						Kit.Panel(b, Vector3.new(0, y, 0), size - 1.2, 7, "Solid")
					end)
				end
				Kit.Layer(b, "Roof")
				if tier < #sizes then
					Kit.EaveRing(b, Vector3.new(0, y + 7, 0), size + 5, size + 5, 3.5, 1.8)
					y += 7.6
				else
					Kit.Roof(
						b,
						Vector3.new(0, y + 7, 0),
						size,
						size,
						{ Height = 4.5, Overhang = 2.5, Ribs = 3, Name = "Crown" }
					)
					y += 7 + 4.5
				end
			end
			Kit.Layer(b, "Ornament")
			Kit.Post(b, "Spire", Vector3.new(0, y, 0), 5, 0.6, s.Metal, "Metal")
			for i = 1, 3 do
				Kit.Ball(b, "SpireRing", Vector3.new(0, y + i * 1.2, 0), 1.6 - i * 0.25, s.Metal, "Metal")
			end
			Kit.Ball(b, "SpireLight", Vector3.new(0, y + 5.2, 0), 0.7, Kit.Tones.Meridian, "Neon")
		end,
	},
	{
		Id = "sm.tower.bell",
		Name = "Bell Tower",
		Category = "Towers",
		Description = "A stone tower base with an arched recess, an open bell chamber above and a bronze bell under a hip roof.",
		Tags = { "tower", "courtyard", "walkable roof" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(b, "Plinth", Vector3.new(0, 0.4, 0), Vector3.new(13, 0.8, 13), s.PlatformTrim, "Slate")
			Kit.Box(b, "TowerBase", Vector3.new(0, 4.4, 0), Vector3.new(12, 7.2, 12), s.WallBase, "Cobblestone")
			Kit.Box(
				b,
				"Arch",
				Vector3.new(0, 3.6, 6.05),
				Vector3.new(4, 5.6, 0.2),
				Kit.Tones.Basalt,
				"Slate",
				{ Role = "Decor" }
			)
			Kit.Box(
				b,
				"FloorTop",
				Vector3.new(0, 8.3, 0),
				Vector3.new(13, 0.6, 13),
				s.Platform,
				"Pavement",
				{ Role = "Walkable" }
			)
			Kit.Layer(b, "Frame")
			for _, x in { -5, 5 } do
				for _, z in { -5, 5 } do
					Kit.Column(b, Vector3.new(x, 8.6, z), 8)
				end
			end
			Kit.Beam(b, Vector3.new(-5, 16.15, 0), Vector3.new(5, 16.15, 0), 1)
			Kit.Layer(b, "Walls")
			for _, z in { -5, 5 } do
				Kit.Railing(b, Vector3.new(0, 8.6, z), 8)
			end
			for _, side in { -1, 1 } do
				Kit.Within(b, CFrame.new(side * 5, 0, 0) * CFrame.fromOrientation(0, math.pi / 2, 0), function()
					Kit.Railing(b, Vector3.new(0, 8.6, 0), 8)
				end)
			end
			Kit.Layer(b, "Ornament")
			Kit.Box(
				b,
				"BellChain",
				Vector3.new(0, 15.2, 0),
				Vector3.new(0.3, 1.4, 0.3),
				s.Metal,
				"Metal",
				{ Role = "Decor" }
			)
			Kit.Post(b, "Bell", Vector3.new(0, 11.2, 0), 3.4, 3.2, s.Metal, "CorrodedMetal")
			Kit.Post(b, "BellLip", Vector3.new(0, 11.0, 0), 0.5, 3.7, s.Metal, "CorrodedMetal", { Role = "Decor" })
			Kit.Ball(b, "BellCrown", Vector3.new(0, 14.7, 0), 1.2, s.Metal, "CorrodedMetal")
			Kit.Layer(b, "Roof")
			Kit.Roof(b, Vector3.new(0, 17.6, 0), 10, 10, { Height = 4.5, Ribs = 4 })
		end,
	},
	{
		Id = "sm.outpost.watch",
		Name = "Watch Post",
		Category = "Towers",
		Description = "A covert lookout on braced timber legs: a screened platform at fourteen studs, a ladder up the front "
			.. "and a small roof to watch the roads from.",
		Tags = { "outpost", "covert", "parkour", "tower" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			for _, x in { -3.5, 3.5 } do
				for _, z in { -3.5, 3.5 } do
					Kit.Box(b, "Footing", Vector3.new(x, 0.4, z), Vector3.new(2, 0.8, 2), s.PlatformTrim, "Slate")
				end
			end
			Kit.Layer(b, "Frame")
			for _, x in { -3.5, 3.5 } do
				for _, z in { -3.5, 3.5 } do
					Kit.Post(b, "Leg", Vector3.new(x, 0.8, z), 13.2, 1, s.Post, s.PostMaterial)
				end
			end
			-- Cross-bracing on every side.
			for _, edge in
				{
					{ -3.5, -3.5, 3.5, -3.5 },
					{ -3.5, 3.5, 3.5, 3.5 },
					{ -3.5, -3.5, -3.5, 3.5 },
					{ 3.5, -3.5, 3.5, 3.5 },
				}
			do
				Kit.Beam(b, Vector3.new(edge[1], 2, edge[2]), Vector3.new(edge[3], 12, edge[4]), 0.5)
				Kit.Beam(b, Vector3.new(edge[3], 2, edge[4]), Vector3.new(edge[1], 12, edge[2]), 0.5)
			end
			Kit.Box(
				b,
				"Floor",
				Vector3.new(0, 14.3, 0),
				Vector3.new(9, 0.6, 9),
				s.Beam,
				"WoodPlanks",
				{ Role = "Walkable" }
			)
			-- The ladder: two rails and rungs, climbable.
			for _, x in { -0.9, 0.9 } do
				Kit.Box(b, "LadderRail", Vector3.new(x, 7.3, 4.8), Vector3.new(0.3, 14.6, 0.3), s.Lattice, "Wood")
			end
			for rung = 1, 7 do
				Kit.Box(b, "Rung", Vector3.new(0, rung * 2, 4.8), Vector3.new(1.9, 0.25, 0.25), s.Lattice, "Wood")
			end
			Kit.Layer(b, "Walls")
			Kit.Panel(b, Vector3.new(0, 14.6, -4.2), 8.4, 4.5, "Screen")
			for _, side in { -1, 1 } do
				Kit.Within(b, CFrame.new(side * 4.2, 0, 0) * CFrame.fromOrientation(0, math.pi / 2, 0), function()
					Kit.Panel(b, Vector3.new(0, 14.6, 0), 8.4, 4.5, "Screen")
				end)
			end
			Kit.Layer(b, "Roof")
			for _, x in { -3.5, 3.5 } do
				for _, z in { -3.5, 3.5 } do
					Kit.Post(b, "RoofPost", Vector3.new(x, 14.6, z), 5.4, 0.7, s.Post, s.PostMaterial)
				end
			end
			Kit.Roof(b, Vector3.new(0, 20, 0), 8, 8, { Height = 3, Overhang = 2, Ribs = 0, Ornaments = false })
			Kit.Layer(b, "Ornament")
			Kit.HangingLantern(b, Vector3.new(3.5, 18.6, 4.6))
		end,
	},
	{
		Id = "sm.bridge.covered",
		Name = "Covered Bridge",
		Category = "Bridges",
		Description = "A thirty-two stud gallery bridge on stone piers: ramps at both ends, railings, and a ribbed roof "
			.. "you can run along.",
		Tags = { "bridge", "walkable", "parkour", "32" },
		Type = "Assembly",
		Factions = Kit.FactionNames,
		Ruins = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			for _, x in { -12, 0, 12 } do
				Kit.Box(b, "Pier", Vector3.new(x, 1.8, 0), Vector3.new(3, 3.6, 7), s.PlatformTrim, "Slate")
			end
			Kit.Box(
				b,
				"Deck",
				Vector3.new(0, 4, 0),
				Vector3.new(32, 0.8, 8),
				s.Beam,
				"WoodPlanks",
				{ Role = "Walkable" }
			)
			for _, side in { -1, 1 } do
				Kit.Wedge(
					b,
					"Ramp",
					Vector3.new(side * 19, 2.2, 0),
					Vector3.new(8, 4.4, 6),
					s.Beam,
					"WoodPlanks",
					-- A wedge rises toward its +Z: yaw 90 turns that to +X, so the left ramp climbs inward to the deck.
					{ Role = "Walkable", Rot = Vector3.new(0, if side < 0 then 90 else -90, 0) }
				)
			end
			Kit.Layer(b, "Frame")
			for _, x in { -16, -8, 0, 8, 16 } do
				for _, z in { -3.6, 3.6 } do
					Kit.Post(b, "Post", Vector3.new(x, 4.4, z), 7, 0.9, s.Post, s.PostMaterial)
				end
			end
			for _, z in { -3.6, 3.6 } do
				Kit.Beam(b, Vector3.new(-16, 11, z), Vector3.new(16, 11, z), 0.8)
			end
			Kit.Layer(b, "Walls")
			for _, z in { -3.6, 3.6 } do
				Kit.Railing(b, Vector3.new(0, 4.4, z), 32)
			end
			Kit.Layer(b, "Roof")
			Kit.Roof(b, Vector3.new(0, 11.4, 0), 32, 7.2, { Height = 3.4, Overhang = 1.6, Ribs = 10, Skirts = false })
		end,
	},
} :: { Family }

return Structures
