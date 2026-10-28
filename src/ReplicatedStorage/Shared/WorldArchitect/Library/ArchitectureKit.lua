--!strict
--[[
	ArchitectureKit.lua

	Owns: the building grammar every built-in World Architect template is composed from -- the named palette, the
	three faction styles, the 4-stud module grid and its datums, a builder with a frame stack, the shared pieces
	(platforms, stairs, columns with bracket sets, wall panels, compound-wall coping, the one roof language, eave
	rings, railings), and the deterministic ruin pass that turns an intact structure into its post-Shattering ruin.

	WHY ONE GRAMMAR. Pieces read as one world only if they share proportions and a vocabulary: the same bay, the same
	floor heights, the same eave overhang and corner upturn, the same few tones. Every template in Library/* is built
	through these helpers and never writes a Color3 or a roof by hand, so a change to the roof profile or a tone
	changes the whole library at once (Tests/WorldArchitect/ArchitectureLibrary.spec.lua holds the rules).

	THE STYLE: sect-era architecture of the Meridian world -- halls raised on stone platforms, timber post-and-beam
	frames, bracket sets under deep eaves, hip-and-gable roofs with upturned corners, moon gates, covered galleries --
	three generations after the Shattering. Celestial builds are ordered and pale; Demonic builds are basalt and
	scorched timber with a sparing ember glow; Unbound builds are salvaged and patched. The Meridian's cyan shows only
	where stone has cracked.

	PRIMITIVES ONLY (no meshes or asset ids exist for world pieces). Detail comes from composition: a bracket set is
	three blocks, a roof is two slopes, two hip skirts, a ridge, fascia, upturned corners and tile ribs.

	CONVENTIONS. Template space: pivot at the floor centre, y = 0 the ground, the FRONT faces +Z (steps, doors and
	gates are on +Z). A WedgePart at yaw 0 rises toward +Z, so a slope descending to the front is yaw 180.
]]

local ArchitectRecord = require(script.Parent.Parent.ArchitectRecord)

type NodeRecord = ArchitectRecord.NodeRecord

local Kit = {}

--
-- Grid and datums
--

Kit.Module = 4
Kit.Bay = 16
Kit.Overhang = 3
Kit.DoorWidth = 6
Kit.DoorHeight = 10
Kit.RailHeight = 3.5

--
-- Palette: every colour any built-in uses. Ten inherited from the first starter kit, four added for the sect
-- library, each with one job.
--

Kit.Tones = table.freeze({
	Stone = Color3.fromRGB(104, 101, 106),
	StoneDark = Color3.fromRGB(74, 72, 79),
	Basalt = Color3.fromRGB(40, 39, 46),
	Moss = Color3.fromRGB(70, 86, 62),
	Leaf = Color3.fromRGB(58, 74, 52),
	Timber = Color3.fromRGB(84, 62, 46),
	TimberDark = Color3.fromRGB(58, 43, 34),
	Bronze = Color3.fromRGB(112, 96, 70),
	Jade = Color3.fromRGB(84, 132, 116),
	Meridian = Color3.fromRGB(150, 214, 228),
	Cloth = Color3.fromRGB(96, 46, 44),
	-- New for the sect library:
	-- Aged whitewash: Celestial wall infill.
	Plaster = Color3.fromRGB(150, 145, 138),
	-- Dark glazed roof tile, blue-grey: every intact Celestial roof.
	RoofTile = Color3.fromRGB(52, 58, 64),
	-- Oxblood lacquer: Celestial columns and gate leaves.
	Lacquer = Color3.fromRGB(98, 40, 34),
	-- Ember: the Demonic accent, only ever a small Neon glow.
	Ember = Color3.fromRGB(196, 74, 40),
})

export type Style = {
	Name: string,
	Wall: Color3,
	WallMaterial: string,
	WallBase: Color3,
	Post: Color3,
	PostMaterial: string,
	Beam: Color3,
	Roof: Color3,
	RoofMaterial: string,
	RoofTrim: Color3,
	Platform: Color3,
	PlatformTrim: Color3,
	Accent: Color3,
	AccentMaterial: string,
	Metal: Color3,
	Lattice: Color3,
	Banner: Color3,
}

local T = Kit.Tones

Kit.Styles = table.freeze({
	Celestial = table.freeze({
		Name = "Celestial",
		Wall = T.Plaster,
		WallMaterial = "Concrete",
		WallBase = T.Stone,
		Post = T.Lacquer,
		PostMaterial = "Wood",
		Beam = T.TimberDark,
		Roof = T.RoofTile,
		RoofMaterial = "Slate",
		RoofTrim = T.StoneDark,
		Platform = T.Stone,
		PlatformTrim = T.StoneDark,
		Accent = T.Jade,
		AccentMaterial = "Marble",
		Metal = T.Bronze,
		Lattice = T.TimberDark,
		Banner = T.Jade,
	} :: Style),
	Demonic = table.freeze({
		Name = "Demonic",
		Wall = T.Basalt,
		WallMaterial = "Basalt",
		WallBase = T.StoneDark,
		Post = T.TimberDark,
		PostMaterial = "Wood",
		Beam = T.Basalt,
		Roof = T.Basalt,
		RoofMaterial = "Slate",
		RoofTrim = T.Bronze,
		Platform = T.Basalt,
		PlatformTrim = T.StoneDark,
		Accent = T.Ember,
		AccentMaterial = "Neon",
		Metal = T.Bronze,
		Lattice = T.TimberDark,
		Banner = T.Lacquer,
	} :: Style),
	Unbound = table.freeze({
		Name = "Unbound",
		Wall = T.Stone,
		WallMaterial = "Cobblestone",
		WallBase = T.StoneDark,
		Post = T.Timber,
		PostMaterial = "Wood",
		Beam = T.TimberDark,
		Roof = T.StoneDark,
		RoofMaterial = "WoodPlanks",
		RoofTrim = T.Timber,
		Platform = T.StoneDark,
		PlatformTrim = T.Basalt,
		Accent = T.Bronze,
		AccentMaterial = "CorrodedMetal",
		Metal = T.Bronze,
		Lattice = T.Timber,
		Banner = T.Cloth,
	} :: Style),
})

Kit.FactionNames = table.freeze({ "Celestial", "Demonic", "Unbound" })

--
-- Builder
--

export type Node = {
	Key: number,
	Parent: number?,
	Record: NodeRecord,
	-- Base / Frame / Walls / Roof / Ornament / Ruin: what the ruin pass and the specs read. Never stored.
	Layer: string,
}

export type Builder = {
	Nodes: { Node },
	Next: number,
	Style: Style,
	Frames: { CFrame },
	Group: number?,
	Layer: string,
}

function Kit.Builder(style: Style?): Builder
	return {
		Nodes = {},
		Next = 1,
		Style = style or Kit.Styles.Celestial,
		Frames = { CFrame.identity },
		Group = nil,
		Layer = "Base",
	}
end

local function frameOf(b: Builder): CFrame
	return b.Frames[#b.Frames]
end

-- Everything built inside `body` is placed relative to `cframe` (composed with any outer frame).
function Kit.Within(b: Builder, cframe: CFrame, body: () -> ()): ()
	table.insert(b.Frames, frameOf(b) * cframe)
	body()
	table.remove(b.Frames)
end

-- A top-level layer group; later parts go into it. Layers are what an admin strips or swaps, and what ruin reads.
function Kit.Layer(b: Builder, name: string): number
	local record = ArchitectRecord.Default("Group")
	record.Name = name
	local key = b.Next
	b.Next += 1
	table.insert(b.Nodes, { Key = key, Parent = nil, Record = record, Layer = name })
	b.Group = key
	b.Layer = name
	return key
end

-- A group inside the current one, pivoted at `cframe` (local), that later parts go into until the caller restores
-- b.Group. What a fit-out uses to make each piece of furniture its own selectable item.
function Kit.Group(b: Builder, name: string, cframe: CFrame): number
	local record = ArchitectRecord.WithCFrame(ArchitectRecord.Default("Group"), frameOf(b) * cframe)
	record.Name = name
	local key = b.Next
	b.Next += 1
	table.insert(b.Nodes, { Key = key, Parent = b.Group, Record = record, Layer = b.Layer })
	b.Group = key
	return key
end

local function rotation(degrees: Vector3?): CFrame
	if degrees == nil then
		return CFrame.identity
	end
	return CFrame.fromOrientation(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
end

export type PartOptions = {
	Role: string?,
	Shape: string?,
	Rot: Vector3?,
	Transparency: number?,
}

-- One part at a local CFrame.
function Kit.PartAt(
	b: Builder,
	name: string,
	cframe: CFrame,
	size: Vector3,
	tone: Color3,
	material: string,
	options: PartOptions?
): NodeRecord
	local o: PartOptions = options or {}
	local neon = material == "Neon"
	local role = o.Role or (if neon then "Decor" else "Structure")
	local record = ArchitectRecord.WithCFrame(ArchitectRecord.Default("Part", role), frameOf(b) * cframe)
	record.Name = name
	record.Size = size
	record.Color = tone
	record.Material = material
	record.Shape = o.Shape or "Block"
	record.Transparency = o.Transparency or 0
	if neon then
		record.CastShadow = false
	end
	table.insert(b.Nodes, { Key = b.Next, Parent = b.Group, Record = record, Layer = b.Layer })
	b.Next += 1
	return record
end

function Kit.Box(
	b: Builder,
	name: string,
	position: Vector3,
	size: Vector3,
	tone: Color3,
	material: string,
	options: PartOptions?
): NodeRecord
	local o: PartOptions = options or {}
	return Kit.PartAt(b, name, CFrame.new(position) * rotation(o.Rot), size, tone, material, o)
end

function Kit.Wedge(
	b: Builder,
	name: string,
	position: Vector3,
	size: Vector3,
	tone: Color3,
	material: string,
	options: PartOptions?
): NodeRecord
	local o = table.clone(options or {}) :: PartOptions
	o.Shape = "Wedge"
	return Kit.Box(b, name, position, size, tone, material, o)
end

-- A vertical cylinder standing on `base` (Roblox cylinders run along X, so it is turned upright).
function Kit.Post(
	b: Builder,
	name: string,
	base: Vector3,
	height: number,
	diameter: number,
	tone: Color3,
	material: string,
	options: PartOptions?
): NodeRecord
	local o = table.clone(options or {}) :: PartOptions
	o.Shape = "Cylinder"
	local cframe = CFrame.new(base + Vector3.new(0, height / 2, 0))
		* rotation(o.Rot)
		* CFrame.fromOrientation(0, 0, math.rad(90))
	return Kit.PartAt(b, name, cframe, Vector3.new(height, diameter, diameter), tone, material, o)
end

function Kit.Ball(
	b: Builder,
	name: string,
	position: Vector3,
	diameter: number,
	tone: Color3,
	material: string,
	role: string?
): NodeRecord
	return Kit.Box(
		b,
		name,
		position,
		Vector3.new(diameter, diameter, diameter),
		tone,
		material,
		{ Shape = "Ball", Role = role or "Decor" }
	)
end

--
-- Shared pieces
--

-- A stone platform of height h: plinth band, core, and a walkable paved cap. Top at y = h.
function Kit.Platform(b: Builder, center: Vector3, w: number, d: number, h: number): ()
	local s = b.Style
	Kit.Box(b, "Plinth", center + Vector3.new(0, 0.4, 0), Vector3.new(w, 0.8, d), s.PlatformTrim, "Slate")
	Kit.Box(
		b,
		"Core",
		center + Vector3.new(0, (h - 0.6) / 2 + 0.4, 0),
		Vector3.new(w - 0.6, h - 1.4, d - 0.6),
		s.Platform,
		"Slate"
	)
	Kit.Box(
		b,
		"TopPaving",
		center + Vector3.new(0, h - 0.3, 0),
		Vector3.new(w, 0.6, d),
		s.Platform,
		"Pavement",
		{ Role = "Walkable" }
	)
end

-- A flight climbing `rise` studs toward +Z from a bottom-front edge at `front`, `width` wide including its cheeks.
function Kit.Steps(b: Builder, front: Vector3, width: number, rise: number): ()
	local s = b.Style
	local run = 1.5
	local tread = width - 1.6
	for i = 1, rise do
		Kit.Box(
			b,
			`Step{i}`,
			front + Vector3.new(0, i / 2, (rise - i + 0.5) * -run + rise * run),
			Vector3.new(tread, i, run),
			s.Platform,
			"Slate",
			{ Role = "Walkable" }
		)
	end
	for _, side in { -1, 1 } do
		Kit.Wedge(
			b,
			"Cheek",
			front + Vector3.new(side * (width / 2 - 0.4), rise / 2, rise * run / 2),
			Vector3.new(0.8, rise, rise * run),
			s.PlatformTrim,
			"Slate"
		)
	end
end

-- A column standing at `base`: stone drum, lacquered shaft, capital, and a three-block bracket set above it.
-- Returns the height of the bracket top.
function Kit.Column(b: Builder, base: Vector3, height: number, brackets: boolean?): number
	local s = b.Style
	Kit.Post(b, "ColumnBase", base, 0.7, 2.4, s.PlatformTrim, "Slate")
	Kit.Post(b, "Column", base + Vector3.new(0, 0.7, 0), height - 1.3, 1.4, s.Post, s.PostMaterial)
	Kit.Box(b, "Capital", base + Vector3.new(0, height - 0.3, 0), Vector3.new(1.9, 0.6, 1.9), s.Beam, "Wood")
	if brackets == false then
		return height
	end
	Kit.Box(
		b,
		"BracketBlock",
		base + Vector3.new(0, height + 0.25, 0),
		Vector3.new(1.3, 0.5, 1.3),
		s.Beam,
		"Wood",
		{ Role = "Decor" }
	)
	Kit.Box(
		b,
		"BracketArmX",
		base + Vector3.new(0, height + 0.75, 0),
		Vector3.new(3.2, 0.5, 0.8),
		s.Beam,
		"Wood",
		{ Role = "Decor" }
	)
	Kit.Box(
		b,
		"BracketArmZ",
		base + Vector3.new(0, height + 0.75, 0),
		Vector3.new(0.8, 0.5, 3.2),
		s.Beam,
		"Wood",
		{ Role = "Decor" }
	)
	return height + 1
end

-- A beam between two points at the same height.
function Kit.Beam(b: Builder, from: Vector3, to: Vector3, thickness: number?, tone: Color3?): ()
	local t = thickness or 0.9
	local length = (to - from).Magnitude
	Kit.PartAt(b, "Beam", CFrame.lookAt((from + to) / 2, to), Vector3.new(t, t, length), tone or b.Style.Beam, "Wood")
end

export type PanelKind = "Solid" | "Window" | "Door" | "Screen"

-- A wall panel along local X, centred, standing on y = 0 of the current frame, `length` long and `height` tall.
function Kit.Panel(b: Builder, center: Vector3, length: number, height: number, kind: PanelKind): ()
	local s = b.Style
	local thick = 1.2
	Kit.Box(b, "Sill", center + Vector3.new(0, 0.5, 0), Vector3.new(length, 1, thick + 0.4), s.WallBase, "Slate")
	Kit.Box(
		b,
		"HeadBeam",
		center + Vector3.new(0, height - 0.5, 0),
		Vector3.new(length, 1, thick + 0.3),
		s.Beam,
		"Wood"
	)
	local bodyBottom, bodyTop = 1, height - 1
	local bodyHeight = bodyTop - bodyBottom
	local function body(name: string, x: number, y0: number, y1: number, w: number)
		if w > 0.05 and y1 - y0 > 0.05 then
			Kit.Box(
				b,
				name,
				center + Vector3.new(x, (y0 + y1) / 2, 0),
				Vector3.new(w, y1 - y0, thick),
				s.Wall,
				s.WallMaterial
			)
		end
	end
	if kind == "Solid" then
		body("Wall", 0, bodyBottom, bodyTop, length)
	elseif kind == "Window" then
		local ww = math.min(length * 0.5, 6)
		local w0, w1 = bodyBottom + bodyHeight * 0.35, bodyBottom + bodyHeight * 0.8
		local side = (length - ww) / 2
		body("Wall", -(ww + side) / 2, bodyBottom, bodyTop, side)
		body("Wall", (ww + side) / 2, bodyBottom, bodyTop, side)
		body("Wall", 0, bodyBottom, w0, ww)
		body("Wall", 0, w1, bodyTop, ww)
		-- Lattice: a frame and a grid of mullions, set in the opening.
		local cy = (w0 + w1) / 2
		local wh = w1 - w0
		Kit.Box(
			b,
			"Lattice",
			center + Vector3.new(0, cy, 0),
			Vector3.new(ww, 0.25, 0.3),
			s.Lattice,
			"Wood",
			{ Role = "Decor" }
		)
		for i = -1, 1 do
			Kit.Box(
				b,
				"Lattice",
				center + Vector3.new(i * ww / 4, cy, 0),
				Vector3.new(0.25, wh, 0.3),
				s.Lattice,
				"Wood",
				{ Role = "Decor" }
			)
		end
		Kit.Box(
			b,
			"WindowFrame",
			center + Vector3.new(0, w1, 0),
			Vector3.new(ww + 0.4, 0.35, 0.5),
			s.Beam,
			"Wood",
			{ Role = "Decor" }
		)
		Kit.Box(
			b,
			"WindowFrame",
			center + Vector3.new(0, w0, 0),
			Vector3.new(ww + 0.4, 0.35, 0.5),
			s.Beam,
			"Wood",
			{ Role = "Decor" }
		)
	elseif kind == "Door" then
		local dw = math.min(Kit.DoorWidth, length - 2)
		local dh = math.min(Kit.DoorHeight, bodyTop - 0.5)
		local side = (length - dw) / 2
		body("Wall", -(dw + side) / 2, bodyBottom, bodyTop, side)
		body("Wall", (dw + side) / 2, bodyBottom, bodyTop, side)
		body("Transom", 0, dh, bodyTop, dw)
		for _, x in { -dw / 2 - 0.2, dw / 2 + 0.2 } do
			Kit.Box(
				b,
				"DoorJamb",
				center + Vector3.new(x, dh / 2, 0),
				Vector3.new(0.4, dh, thick + 0.3),
				s.Post,
				s.PostMaterial
			)
		end
		Kit.Box(
			b,
			"Lintel",
			center + Vector3.new(0, dh + 0.25, 0),
			Vector3.new(dw + 1.2, 0.5, thick + 0.4),
			s.Post,
			s.PostMaterial
		)
		Kit.Box(
			b,
			"Threshold",
			center + Vector3.new(0, 1.15, 0),
			Vector3.new(dw, 0.3, thick + 0.4),
			s.WallBase,
			"Slate",
			{ Role = "Walkable" }
		)
	else
		-- Screen: an open lattice of uprights between sill and head, for galleries and front bays.
		local count = math.max(math.floor(length / 2), 2)
		for i = 0, count do
			Kit.Box(
				b,
				"Screen",
				center + Vector3.new(-length / 2 + 0.3 + i * (length - 0.6) / count, (bodyBottom + bodyTop) / 2, 0),
				Vector3.new(0.3, bodyHeight, 0.3),
				s.Lattice,
				"Wood"
			)
		end
		Kit.Box(
			b,
			"ScreenRail",
			center + Vector3.new(0, bodyBottom + bodyHeight * 0.5, 0),
			Vector3.new(length, 0.3, 0.35),
			s.Lattice,
			"Wood",
			{ Role = "Decor" }
		)
	end
end

-- A low railing along local X: posts and two rails, length `length`, standing on y = 0 of the current frame.
function Kit.Railing(b: Builder, center: Vector3, length: number): ()
	local s = b.Style
	local count = math.max(math.floor(length / Kit.Module), 1)
	for i = 0, count - 1 do
		local x = -length / 2 + Kit.Module * (i + 0.5)
		Kit.Box(
			b,
			"RailPost",
			center + Vector3.new(x, Kit.RailHeight / 2, 0),
			Vector3.new(0.5, Kit.RailHeight, 0.5),
			s.Lattice,
			"Wood"
		)
	end
	Kit.Box(b, "Rail", center + Vector3.new(0, Kit.RailHeight - 0.15, 0), Vector3.new(length, 0.3, 0.5), s.Beam, "Wood")
	Kit.Box(
		b,
		"RailLow",
		center + Vector3.new(0, 1, 0),
		Vector3.new(length, 0.25, 0.3),
		s.Lattice,
		"Wood",
		{ Role = "Decor" }
	)
end

export type RoofOptions = {
	-- Ridge height above the eave line; defaults to a third of the depth (with overhang).
	Height: number?,
	Overhang: number?,
	-- Tile ribs per slope; 0 for none.
	Ribs: number?,
	-- Hip skirts at the gable ends (hip-and-gable). Default true.
	Skirts: boolean?,
	-- Ridge-end ornaments. Default true.
	Ornaments: boolean?,
	-- Name prefix, so a pagoda's tiers read apart in the Scene tree.
	Name: string?,
}

-- THE roof. Ridge along local X, eave line at `center.Y`, covering w x d plus the overhang. Slopes, hip skirts, a
-- ridge with upturned ends, fascia boards, four flying corners and tile ribs. Slopes are walkable (rooftop routes).
function Kit.Roof(b: Builder, center: Vector3, w: number, d: number, options: RoofOptions?): number
	local s = b.Style
	local o: RoofOptions = options or {}
	local ov = o.Overhang or Kit.Overhang
	local W, D = w + ov * 2, d + ov * 2
	local h = o.Height or D / 3
	local prefix = o.Name or "Roof"
	local half = D / 2
	for _, side in { -1, 1 } do
		-- side -1: back slope (yaw 0, rises toward +Z, i.e. toward the ridge); side 1: front slope (yaw 180).
		Kit.Wedge(
			b,
			`{prefix}Slope`,
			center + Vector3.new(0, h / 2, side * half / 2),
			Vector3.new(W, h, half),
			s.Roof,
			s.RoofMaterial,
			{ Role = "Walkable", Rot = Vector3.new(0, if side > 0 then 180 else 0, 0) }
		)
	end
	if o.Skirts ~= false then
		local skirtDepth = ov * 2 + 1
		local skirtHeight = h * 0.45
		for _, side in { -1, 1 } do
			Kit.Wedge(
				b,
				`{prefix}Skirt`,
				center + Vector3.new(side * (W / 2 - skirtDepth / 2), skirtHeight / 2, 0),
				Vector3.new(D * 0.96, skirtHeight, skirtDepth),
				s.Roof,
				s.RoofMaterial,
				{ Rot = Vector3.new(0, if side < 0 then 90 else -90, 0) }
			)
		end
	end
	Kit.Box(
		b,
		`{prefix}Ridge`,
		center + Vector3.new(0, h + 0.2, 0),
		Vector3.new(W * 0.9, 0.8, 1),
		s.RoofTrim,
		"Slate",
		{ Role = "Walkable" }
	)
	if o.Ornaments ~= false then
		for _, side in { -1, 1 } do
			Kit.Wedge(
				b,
				`{prefix}RidgeBeast`,
				center + Vector3.new(side * W * 0.45, h + 1.2, 0),
				Vector3.new(0.9, 1.6, 1.4),
				s.RoofTrim,
				"Slate",
				{ Role = "Decor", Rot = Vector3.new(0, if side < 0 then 90 else -90, 0) }
			)
		end
	end
	-- Fascia along the eaves, and the upturned corners every roof shares.
	for _, side in { -1, 1 } do
		Kit.Box(
			b,
			`{prefix}Fascia`,
			center + Vector3.new(0, 0.2, side * half),
			Vector3.new(W, 0.5, 0.4),
			s.Beam,
			"Wood",
			{ Role = "Decor" }
		)
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local yaw = math.deg(math.atan2(-sx, -sz))
			Kit.Wedge(
				b,
				`{prefix}FlyingCorner`,
				center + Vector3.new(sx * (W / 2 - 0.3), 0.55, sz * (half - 0.3)),
				Vector3.new(0.9, 1.1, 2.6),
				s.RoofTrim,
				"Slate",
				{ Role = "Decor", Rot = Vector3.new(-14, yaw + 180, 0) }
			)
		end
	end
	-- Tile ribs, lying on each slope.
	local ribs = o.Ribs or 0
	if ribs > 0 then
		local slopeLength = math.sqrt(h * h + half * half)
		local pitch = math.deg(math.atan2(h, half))
		local spacing = W / (ribs + 1)
		for _, side in { -1, 1 } do
			for i = 1, ribs do
				local x = -W / 2 + spacing * i
				-- On the back slope the rib's +Z runs up toward the ridge; the front slope is the same turned 180.
				-- A positive X rotation tips +Z DOWN, so the uphill tilt is the negative pitch.
				local local_ = CFrame.new(0, h / 2, -half / 2)
					* CFrame.fromOrientation(math.rad(-pitch), 0, 0)
					* CFrame.new(0, 0.2, 0)
				local turned = if side > 0 then CFrame.fromOrientation(0, math.rad(180), 0) * local_ else local_
				Kit.PartAt(
					b,
					`{prefix}Rib`,
					CFrame.new(center + Vector3.new(x, 0, 0)) * turned,
					Vector3.new(0.35, 0.3, slopeLength),
					s.RoofTrim,
					"Slate",
					{ Role = "Decor" }
				)
			end
		end
	end
	return center.Y + h
end

-- A lower eave ring (the first eave of a double-eave hall): four slopes around a w x d footprint, `depth` deep,
-- dropping `drop` toward the outside, with flying corners.
function Kit.EaveRing(b: Builder, center: Vector3, w: number, d: number, depth: number, drop: number): ()
	local s = b.Style
	for _, side in { -1, 1 } do
		Kit.Wedge(
			b,
			"EaveRing",
			center + Vector3.new(0, drop / 2, side * (d / 2 - depth / 2)),
			Vector3.new(w, drop, depth),
			s.Roof,
			s.RoofMaterial,
			{ Role = "Walkable", Rot = Vector3.new(0, if side > 0 then 180 else 0, 0) }
		)
		Kit.Wedge(
			b,
			"EaveRing",
			center + Vector3.new(side * (w / 2 - depth / 2), drop / 2, 0),
			Vector3.new(d - depth * 2, drop, depth),
			s.Roof,
			s.RoofMaterial,
			{ Role = "Walkable", Rot = Vector3.new(0, if side > 0 then -90 else 90, 0) }
		)
		Kit.Box(
			b,
			"EaveFascia",
			center + Vector3.new(0, 0.2, side * d / 2),
			Vector3.new(w, 0.5, 0.4),
			s.Beam,
			"Wood",
			{ Role = "Decor" }
		)
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local yaw = math.deg(math.atan2(-sx, -sz))
			Kit.Wedge(
				b,
				"EaveCorner",
				center + Vector3.new(sx * (w / 2 - 0.3), 0.55, sz * (d / 2 - 0.3)),
				Vector3.new(0.9, 1.1, 2.6),
				s.RoofTrim,
				"Slate",
				{ Role = "Decor", Rot = Vector3.new(-14, yaw + 180, 0) }
			)
		end
	end
end

-- The tile coping that caps a compound wall: a small gable along local X at height `y`.
function Kit.Coping(b: Builder, center: Vector3, length: number): ()
	local s = b.Style
	for _, side in { -1, 1 } do
		Kit.Wedge(
			b,
			"Coping",
			center + Vector3.new(0, 0.6, side * 1.1),
			Vector3.new(length, 1.2, 2.2),
			s.Roof,
			s.RoofMaterial,
			{ Role = "Walkable", Rot = Vector3.new(0, if side > 0 then 180 else 0, 0) }
		)
		Kit.Box(
			b,
			"CopingEave",
			center + Vector3.new(0, 0.1, side * 2.2),
			Vector3.new(length, 0.25, 0.25),
			s.Beam,
			"Wood",
			{ Role = "Decor" }
		)
	end
	Kit.Box(
		b,
		"CopingRidge",
		center + Vector3.new(0, 1.35, 0),
		Vector3.new(length, 0.4, 0.6),
		s.RoofTrim,
		"Slate",
		{ Role = "Walkable" }
	)
end

-- A hanging plaque with a glowing (Demonic) or carved accent.
function Kit.Plaque(b: Builder, center: Vector3, width: number): ()
	local s = b.Style
	Kit.Box(b, "PlaqueFrame", center, Vector3.new(width + 0.6, 2.2, 0.3), s.Beam, "Wood", { Role = "Decor" })
	Kit.Box(
		b,
		"Plaque",
		center + Vector3.new(0, 0, 0.18),
		Vector3.new(width, 1.6, 0.1),
		s.Accent,
		s.AccentMaterial,
		{ Role = "Decor" }
	)
end

-- A hanging lantern: cap, body, glow.
function Kit.HangingLantern(b: Builder, position: Vector3, glow: Color3?): ()
	local s = b.Style
	Kit.Box(
		b,
		"LanternCord",
		position + Vector3.new(0, 1.2, 0),
		Vector3.new(0.1, 1.2, 0.1),
		s.Metal,
		"Metal",
		{ Role = "Decor" }
	)
	Kit.Box(
		b,
		"LanternCap",
		position + Vector3.new(0, 0.55, 0),
		Vector3.new(1.1, 0.25, 1.1),
		s.Metal,
		"CorrodedMetal",
		{ Role = "Decor" }
	)
	Kit.Box(
		b,
		"Lantern",
		position,
		Vector3.new(0.9, 0.9, 0.9),
		s.Banner,
		"Fabric",
		{ Role = "Decor", Transparency = 0.15 }
	)
	Kit.Box(b, "LanternGlow", position, Vector3.new(0.5, 0.6, 0.5), glow or T.Meridian, "Neon")
end

-- A guardian statue on a plinth (the stone lions of a sect gate, abstracted).
function Kit.Guardian(b: Builder, base: Vector3, facing: number): ()
	local s = b.Style
	Kit.Box(b, "GuardianPlinth", base + Vector3.new(0, 1, 0), Vector3.new(2.6, 2, 2.6), s.PlatformTrim, "Slate")
	Kit.Box(
		b,
		"GuardianBody",
		base + Vector3.new(0, 3, 0),
		Vector3.new(1.8, 2, 2.4),
		s.Platform,
		"Granite",
		{ Rot = Vector3.new(0, facing, 0) }
	)
	Kit.Ball(
		b,
		"GuardianHead",
		base
			+ Vector3.new(0, 4.6, 0)
			+ CFrame.fromOrientation(0, math.rad(facing), 0):VectorToWorldSpace(Vector3.new(0, 0, -0.7)),
		1.7,
		s.Platform,
		"Granite",
		"Structure"
	)
	Kit.Ball(
		b,
		"GuardianPearl",
		base
			+ Vector3.new(0, 2.3, 0)
			+ CFrame.fromOrientation(0, math.rad(facing), 0):VectorToWorldSpace(Vector3.new(0, 0, -1.4)),
		0.7,
		s.Accent,
		s.AccentMaterial
	)
end

-- A rubble pile of a few broken blocks at `center` (ground).
function Kit.Rubble(b: Builder, center: Vector3, rng: Random, count: number): ()
	for i = 1, count do
		local size = Vector3.new(rng:NextNumber(0.8, 2.2), rng:NextNumber(0.6, 1.4), rng:NextNumber(0.8, 2))
		local offset = Vector3.new(rng:NextNumber(-2, 2), size.Y / 2 - 0.1, rng:NextNumber(-2, 2))
		Kit.Box(
			b,
			"Rubble",
			center + offset,
			size,
			if i % 2 == 0 then T.StoneDark else T.Stone,
			"Rock",
			{ Rot = Vector3.new(rng:NextNumber(-25, 25), rng:NextInteger(0, 359), rng:NextNumber(-25, 25)) }
		)
	end
end

--
-- The ruin pass
--

local function hash(text: string): number
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 2147483647
	end
	return h
end

-- The local axis of a CFrame most aligned with world up, and its sign.
local function upAxis(cframe: CFrame): (string, number)
	local axes: { [string]: number } = { X = cframe.RightVector.Y, Y = cframe.UpVector.Y, Z = -cframe.LookVector.Y }
	local best: string, value: number = "Y", 0
	for name, dot in axes do
		if math.abs(dot) > math.abs(value) then
			best, value = name, dot
		end
	end
	return best, if value >= 0 then 1 else -1
end

-- Shortens a part to `factor` of its vertical length, keeping its bottom where it was: a snapped post, a broken wall.
local function truncate(record: NodeRecord, factor: number): NodeRecord
	local cframe = ArchitectRecord.CFrameOf(record)
	local axis, sign = upAxis(cframe)
	local size = record.Size
	local length = if axis == "X" then size.X elseif axis == "Y" then size.Y else size.Z
	local cut = length * (1 - factor)
	local copy = ArchitectRecord.Clone(record)
	copy.Size = if axis == "X"
		then Vector3.new(size.X - cut, size.Y, size.Z)
		elseif axis == "Y" then Vector3.new(size.X, size.Y - cut, size.Z)
		else Vector3.new(size.X, size.Y, size.Z - cut)
	local localShift = if axis == "X"
		then Vector3.new(-sign * cut / 2, 0, 0)
		elseif axis == "Y" then Vector3.new(0, -sign * cut / 2, 0)
		else Vector3.new(0, 0, sign * cut / 2)
	return ArchitectRecord.WithCFrame(copy, cframe * CFrame.new(localShift))
end

-- A part fallen to the ground near where it was: lying down, tilted, turned.
local function fall(record: NodeRecord, rng: Random): NodeRecord
	local p = record.Position
	local s = record.Size
	local lying = math.min(s.X, s.Y, s.Z) / 2
	local frame = CFrame.new(p.X + rng:NextNumber(-4, 4), lying + 0.1, p.Z + rng:NextNumber(-4, 4))
		* CFrame.fromOrientation(
			math.rad(rng:NextNumber(-12, 12)),
			math.rad(rng:NextNumber(0, 360)),
			math.rad(rng:NextNumber(-12, 12))
		)
	-- Laid on its thinnest axis.
	if s.X <= s.Y and s.X <= s.Z then
		frame *= CFrame.fromOrientation(0, 0, math.rad(90))
	elseif s.Z <= s.Y then
		frame *= CFrame.fromOrientation(math.rad(90), 0, 0)
	end
	local copy = ArchitectRecord.WithCFrame(record, frame)
	-- Fallen stone and timber is cover now; a fallen glow stays decoration.
	copy.Role = if record.Material == "Neon" then "Decor" else "Structure"
	copy.Name = "Fallen" .. record.Name
	return copy
end

-- The post-Shattering ruin of a built structure, deterministic for `seed`: roofs mostly gone or fallen, posts and
-- walls snapped, ornament stripped, rubble and moss added, and Meridian seams glowing through the cracked platform.
-- The Base layer is never touched, so an intact structure and its ruin share their footprint exactly.
function Kit.Ruin(b: Builder, seed: string): ()
	local rng = Random.new(hash(seed))
	local kept: { Node } = {}
	local low, high = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local baseTop = 0
	for _, node in b.Nodes do
		local record = node.Record
		if record.Kind == "Group" or node.Layer == "Base" then
			if record.Kind == "Part" then
				low = low:Min(record.Position - record.Size / 2)
				high = high:Max(record.Position + record.Size / 2)
				baseTop = math.max(baseTop, record.Position.Y + record.Size.Y / 2)
			end
			table.insert(kept, node)
			continue
		end
		local roll = rng:NextNumber()
		local layer = node.Layer
		if layer == "Roof" then
			if roll < 0.5 then
				continue
			elseif roll < 0.7 and record.Size.Magnitude > 3 then
				node.Record = fall(record, rng)
			end
		elseif layer == "Ornament" then
			if roll < 0.55 then
				continue
			elseif roll < 0.7 then
				node.Record = fall(record, rng)
			end
		elseif layer == "Frame" or layer == "Walls" then
			local tall = math.max(record.Size.X, record.Size.Y, record.Size.Z) > 3
			if roll < 0.18 then
				continue
			elseif roll < 0.55 and tall then
				node.Record = truncate(record, rng:NextNumber(0.3, 0.75))
			end
		end
		table.insert(kept, node)
	end
	b.Nodes = kept
	if low.X == math.huge then
		low, high = Vector3.new(-4, 0, -4), Vector3.new(4, 0, 4)
	end
	-- What the ruin adds: rubble, moss and Meridian seams.
	Kit.Layer(b, "Ruin")
	local span = high - low
	local piles = math.clamp(math.floor((span.X * span.Z) / 120), 1, 5)
	for _ = 1, piles do
		Kit.Rubble(b, Vector3.new(rng:NextNumber(low.X, high.X), baseTop, rng:NextNumber(low.Z, high.Z)), rng, 3)
	end
	for i = 1, 2 do
		local x = rng:NextNumber(low.X + 1, high.X - 1)
		local z = rng:NextNumber(low.Z + 1, high.Z - 1)
		Kit.Box(
			b,
			"MeridianSeam",
			Vector3.new(x, baseTop + 0.03, z),
			Vector3.new(0.18, 0.06, math.min(span.Z * 0.5, 9)),
			T.Meridian,
			"Neon",
			{ Rot = Vector3.new(0, rng:NextNumber(0, 180) + i * 40, 0) }
		)
	end
	for _ = 1, 3 do
		Kit.Box(
			b,
			"Moss",
			Vector3.new(rng:NextNumber(low.X, high.X), baseTop + 0.05, rng:NextNumber(low.Z, high.Z)),
			Vector3.new(rng:NextNumber(2, 5), 0.1, rng:NextNumber(2, 5)),
			T.Moss,
			"Grass",
			{ Role = "Decor", Rot = Vector3.new(0, rng:NextNumber(0, 90), 0) }
		)
	end
end

-- The builder's nodes in the shape ArchitectTemplates.Validate reads.
function Kit.Export(b: Builder): { { [string]: any } }
	local out = {}
	for _, node in b.Nodes do
		table.insert(out, { Key = node.Key, Parent = node.Parent, Record = node.Record })
	end
	return out
end

Kit.Hash = hash

return Kit
