--!strict
--[[
	Library/Landmarks.lua

	Owns: the one-of-a-kind set pieces of the built-in library -- the places a region is remembered by. Each belongs
	to a region (world-design.md) and is built in that region's register: the Shattered Sect Gate and the Meridian
	Shrine in the Median Paradise's contested heartland, the Meridian Shard and the Floating Terrace in the Void, the
	Ember Altar in the Demonic Disastrous Landscape.

	They use the same grammar as every structure (ArchitectureKit), so a landmark sits in a compound without looking
	imported from somewhere else.
]]

local Kit = require(script.Parent.ArchitectureKit)
local Structures = require(script.Parent.Structures)

type Builder = Kit.Builder
type Family = Structures.Family

local T = Kit.Tones

local Landmarks = {}

-- A stone lantern: base, shaft, deck, firebox with a Meridian glow, and a small roof. Shared with Dressing.
function Landmarks.StoneLantern(b: Builder, base: Vector3): ()
	local s = b.Style
	Kit.Box(b, "LanternBase", base + Vector3.new(0, 0.3, 0), Vector3.new(1.8, 0.6, 1.8), s.PlatformTrim, "Slate")
	Kit.Post(b, "LanternShaft", base + Vector3.new(0, 0.6, 0), 2.6, 0.8, s.Platform, "Granite")
	Kit.Box(b, "LanternDeck", base + Vector3.new(0, 3.35, 0), Vector3.new(1.6, 0.3, 1.6), s.PlatformTrim, "Slate")
	Kit.Box(b, "Firebox", base + Vector3.new(0, 4.1, 0), Vector3.new(1.1, 1.2, 1.1), s.Platform, "Granite")
	Kit.Box(b, "FireboxGlow", base + Vector3.new(0, 4.1, 0), Vector3.new(1.16, 0.6, 0.5), T.Meridian, "Neon")
	Kit.Roof(
		b,
		base + Vector3.new(0, 4.7, 0),
		1.2,
		1.2,
		{ Height = 0.6, Overhang = 0.4, Ribs = 0, Skirts = false, Ornaments = false, Name = "LanternRoof" }
	)
	Kit.Ball(b, "LanternFinial", base + Vector3.new(0, 5.55, 0), 0.4, s.PlatformTrim, "Slate")
end

Landmarks.Families = {
	{
		Id = "sm.landmark.sectgate",
		Name = "Shattered Sect Gate",
		Category = "Landmarks",
		Description = "A thirty-two stud sect archway split by the Shattering: the right wing has fallen, and the Meridian "
			.. "glows through the crack that runs under the central bay.",
		Tags = { "gate", "landmark", "ruin", "meridian" },
		Type = "Landmark",
		Region = "MedianParadise",
		Ruined = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(
				b,
				"Causeway",
				Vector3.new(0, 0.3, 0),
				Vector3.new(32, 0.6, 8),
				s.Platform,
				"Pavement",
				{ Role = "Walkable" }
			)
			Kit.Layer(b, "Frame")
			for _, pillar in { { -12, 11 }, { -5, 16 }, { 5, 16 } } do
				Kit.Box(
					b,
					"PillarBase",
					Vector3.new(pillar[1], 1.6, 0),
					Vector3.new(3.2, 2, 3.2),
					s.PlatformTrim,
					"Slate"
				)
				Kit.Box(
					b,
					"Pillar",
					Vector3.new(pillar[1], 2.6 + pillar[2] / 2, 0),
					Vector3.new(2, pillar[2], 2),
					s.Platform,
					"Granite"
				)
			end
			-- The right outer pillar, snapped at four studs; its top lies in front of it.
			Kit.Box(b, "PillarBase", Vector3.new(12, 1.6, 0), Vector3.new(3.2, 2, 3.2), s.PlatformTrim, "Slate")
			Kit.Box(b, "Pillar", Vector3.new(12, 4.6, 0), Vector3.new(2, 4, 2), s.Platform, "Granite")
			Kit.Box(
				b,
				"FallenPillar",
				Vector3.new(14, 1.2, 6),
				Vector3.new(2, 2, 6.5),
				s.Platform,
				"Granite",
				{ Rot = Vector3.new(0, 25, 8) }
			)
			Kit.Box(b, "Lintel", Vector3.new(0, 15.2, 0), Vector3.new(12, 1.6, 2.4), s.Beam, "Wood")
			Kit.Box(b, "Lintel", Vector3.new(0, 12.6, 0), Vector3.new(10, 1.2, 2), s.Beam, "Wood")
			Kit.Box(b, "Lintel", Vector3.new(-8.5, 12, 0), Vector3.new(7, 1.2, 2), s.Beam, "Wood")
			Kit.Layer(b, "Roof")
			Kit.Roof(b, Vector3.new(0, 16, 0), 12, 2.6, { Height = 2.6, Overhang = 1.6, Ribs = 4, Name = "CentreRoof" })
			Kit.Roof(b, Vector3.new(-8.5, 12.6, 0), 7, 2.4, { Height = 2, Overhang = 1.2, Ribs = 2, Name = "WingRoof" })
			-- The fallen right wing roof, lying across the causeway edge.
			Kit.Wedge(
				b,
				"FallenWingRoof",
				Vector3.new(10, 1.3, -5),
				Vector3.new(8, 2, 3),
				s.Roof,
				s.RoofMaterial,
				{ Rot = Vector3.new(12, -20, 160) }
			)
			Kit.Layer(b, "Ornament")
			Kit.Plaque(b, Vector3.new(0, 13.9, 1.3), 4)
			Kit.Layer(b, "Ruin")
			-- The crack: a zigzag of Meridian light through the causeway, and up the left inner pillar.
			local points = {
				Vector3.new(-1, 0.62, -4),
				Vector3.new(1.5, 0.62, -1),
				Vector3.new(-0.5, 0.62, 1.5),
				Vector3.new(1, 0.62, 4),
			}
			for i = 1, #points - 1 do
				local a, c = points[i], points[i + 1]
				Kit.PartAt(
					b,
					"MeridianSeam",
					CFrame.lookAt((a + c) / 2, c),
					Vector3.new(0.22, 0.06, (c - a).Magnitude),
					T.Meridian,
					"Neon"
				)
			end
			Kit.Box(
				b,
				"MeridianSeam",
				Vector3.new(-3.98, 8, 0.4),
				Vector3.new(0.06, 7, 0.2),
				T.Meridian,
				"Neon",
				{ Rot = Vector3.new(0, 0, 6) }
			)
			Kit.Rubble(b, Vector3.new(11, 0.6, -2), Random.new(31), 4)
			Kit.Rubble(b, Vector3.new(-14, 0, 4), Random.new(32), 2)
		end,
	},
	{
		Id = "sm.landmark.shrine",
		Name = "Meridian Shrine",
		Category = "Landmarks",
		Description = "A roadside shrine where travellers leave qi offerings: a stone terrace, a roofed altar with a glowing "
			.. "bowl, a rack of jade prayer tablets and a stone lantern either side.",
		Tags = { "shrine", "landmark", "meridian", "small" },
		Type = "Landmark",
		Region = "MedianParadise",
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Platform(b, Vector3.zero, 16, 12, 1)
			Kit.Within(b, CFrame.new(0, 0, 6 + 1.5) * CFrame.fromOrientation(0, math.pi, 0), function()
				Kit.Steps(b, Vector3.zero, 6, 1)
			end)
			Kit.Layer(b, "Frame")
			for _, x in { -3, 3 } do
				for _, z in { -3, 1 } do
					Kit.Post(b, "CanopyPost", Vector3.new(x, 1, z), 7, 0.8, s.Post, s.PostMaterial)
				end
			end
			Kit.Box(b, "Altar", Vector3.new(0, 2.25, -1), Vector3.new(4, 2.5, 2.4), s.Platform, "Granite")
			Kit.Box(b, "AltarTop", Vector3.new(0, 3.6, -1), Vector3.new(4.6, 0.3, 2.8), s.PlatformTrim, "Slate")
			Kit.Post(b, "QiBowl", Vector3.new(0, 3.75, -1), 0.6, 2, s.Metal, "CorrodedMetal", { Role = "Decor" })
			Kit.Post(b, "QiGlow", Vector3.new(0, 4.2, -1), 0.12, 1.6, T.Meridian, "Neon")
			Kit.Layer(b, "Roof")
			Kit.Roof(b, Vector3.new(0, 8, -1), 6, 4, { Height = 2.4, Overhang = 1.4, Ribs = 3 })
			Kit.Layer(b, "Ornament")
			Kit.Box(b, "TabletRack", Vector3.new(0, 1.9, -4.6), Vector3.new(7, 1.8, 0.8), s.Beam, "Wood")
			for i = -2, 2 do
				Kit.Box(
					b,
					"PrayerTablet",
					Vector3.new(i * 1.3, 3.5, -4.6),
					Vector3.new(0.9, 1.6, 0.2),
					T.Jade,
					"Marble",
					{ Role = "Decor" }
				)
			end
			for _, x in { -6, 6 } do
				Landmarks.StoneLantern(b, Vector3.new(x, 1, 3.5))
			end
		end,
	},
	{
		Id = "sm.meridian.obelisk",
		Name = "Meridian Shard",
		Category = "Landmarks",
		Description = "A tilted crystal of condensed Meridian standing in a ring of fractured basalt, its core alight, "
			.. "splinters of it hanging in the air around it.",
		Tags = { "meridian", "landmark", "void", "light" },
		Type = "Landmark",
		Region = "Void",
		Build = function(b)
			local rng = Random.new(77)
			Kit.Layer(b, "Base")
			for k = 0, 5 do
				local angle = math.rad(k * 60 + 15)
				Kit.Box(
					b,
					"BasaltRing",
					Vector3.new(math.cos(angle) * 4.5, 0.9, math.sin(angle) * 4.5),
					Vector3.new(2.8, 1.8 + (k % 3) * 0.6, 1.8),
					T.Basalt,
					"Basalt",
					{ Rot = Vector3.new(rng:NextNumber(-10, 10), -k * 60 - 15 + 90, rng:NextNumber(-8, 8)) }
				)
			end
			Kit.Box(b, "Bed", Vector3.new(0, 0.3, 0), Vector3.new(6, 0.6, 6), T.Basalt, "Basalt", { Role = "Walkable" })
			Kit.Layer(b, "Frame")
			Kit.Box(
				b,
				"Crystal",
				Vector3.new(0.4, 7.6, 0),
				Vector3.new(2.8, 13, 2.8),
				T.Meridian,
				"Glass",
				{ Rot = Vector3.new(0, 45, 8), Transparency = 0.35 }
			)
			Kit.Box(
				b,
				"Core",
				Vector3.new(0.4, 7.6, 0),
				Vector3.new(0.9, 10, 0.9),
				T.Meridian,
				"Neon",
				{ Rot = Vector3.new(0, 45, 8) }
			)
			Kit.Layer(b, "Ornament")
			for i = 1, 5 do
				local angle = math.rad(i * 72)
				Kit.Wedge(
					b,
					"Splinter",
					Vector3.new(math.cos(angle) * 6.5, 4 + i * 1.4, math.sin(angle) * 6.5),
					Vector3.new(0.8, 2.4, 1),
					T.Meridian,
					"Glass",
					{
						Role = "Decor",
						Rot = Vector3.new(rng:NextNumber(-40, 40), i * 72, rng:NextNumber(-40, 40)),
						Transparency = 0.3,
					}
				)
			end
			for i = 1, 3 do
				Kit.Box(
					b,
					"MeridianSeam",
					Vector3.new(0, 0.62, 0),
					Vector3.new(0.2, 0.05, 11),
					T.Meridian,
					"Neon",
					{ Rot = Vector3.new(0, i * 60, 0) }
				)
			end
		end,
	},
	{
		Id = "sm.landmark.voidterrace",
		Name = "Floating Terrace",
		Category = "Landmarks",
		Description = "A terrace torn loose by the Shattering and left hanging in the Void: an inverted crag of rock beneath, "
			.. "the broken frame of a pavilion on top, debris drifting around it.",
		Tags = { "void", "landmark", "floating", "parkour", "walkable" },
		Type = "Landmark",
		Region = "Void",
		Ruined = true,
		Build = function(b)
			local s = b.Style
			local rng = Random.new(53)
			Kit.Layer(b, "Base")
			Kit.Box(
				b,
				"TerraceTop",
				Vector3.new(0, 14, 0),
				Vector3.new(20, 1, 16),
				s.Platform,
				"Pavement",
				{ Role = "Walkable" }
			)
			Kit.Box(b, "TerraceBody", Vector3.new(0, 12.4, 0), Vector3.new(19, 2.4, 15), T.Basalt, "Basalt")
			-- The crag: stacked wedges and corner wedges narrowing to a point below.
			for i, layer in { { 16, 12, 3 }, { 12, 9, 3.4 }, { 7, 6, 3.6 } } do
				local y = 11.2 - (i - 1) * 3.2 - layer[3] / 2
				for _, side in { -1, 1 } do
					Kit.Wedge(
						b,
						"Crag",
						Vector3.new(0, y, side * layer[2] / 4),
						Vector3.new(layer[1], layer[3], layer[2] / 2),
						if i % 2 == 0 then T.StoneDark else T.Basalt,
						"Rock",
						{ Rot = Vector3.new(180, if side > 0 then 0 else 180, 0) }
					)
				end
			end
			Kit.Layer(b, "Frame")
			for _, x in { -5, 5 } do
				Kit.Column(b, Vector3.new(x, 14.5, -4), 9)
			end
			Kit.Column(b, Vector3.new(-5, 14.5, 4), 9, false)
			Kit.Box(b, "BrokenColumn", Vector3.new(5, 16.5, 4), Vector3.new(1.4, 4, 1.4), s.Post, s.PostMaterial)
			Kit.Beam(b, Vector3.new(-5, 23, -4), Vector3.new(5, 23, -4))
			Kit.Layer(b, "Roof")
			Kit.Wedge(
				b,
				"HalfRoof",
				Vector3.new(0, 25, -2.5),
				Vector3.new(14, 3, 6),
				s.Roof,
				s.RoofMaterial,
				{ Role = "Walkable", Rot = Vector3.new(0, 0, -6) }
			)
			Kit.Layer(b, "Ornament")
			for i = 1, 6 do
				local angle = math.rad(i * 60 + rng:NextNumber(-15, 15))
				Kit.Box(
					b,
					"Debris",
					Vector3.new(math.cos(angle) * 15, rng:NextNumber(6, 20), math.sin(angle) * 12),
					Vector3.new(rng:NextNumber(1.5, 3.5), rng:NextNumber(1, 2.5), rng:NextNumber(1.5, 3)),
					if i % 2 == 0 then T.Basalt else T.StoneDark,
					"Rock",
					{ Rot = Vector3.new(rng:NextNumber(0, 60), rng:NextNumber(0, 360), rng:NextNumber(0, 60)) }
				)
			end
			Kit.Layer(b, "Ruin")
			for i = 1, 3 do
				Kit.Box(
					b,
					"MeridianSeam",
					Vector3.new(rng:NextNumber(-6, 6), 14.52, rng:NextNumber(-5, 5)),
					Vector3.new(0.2, 0.05, 7),
					T.Meridian,
					"Neon",
					{ Rot = Vector3.new(0, i * 55, 0) }
				)
			end
			Kit.Box(
				b,
				"MeridianVein",
				Vector3.new(0.3, 7, 0),
				Vector3.new(0.25, 8, 0.25),
				T.Meridian,
				"Neon",
				{ Rot = Vector3.new(0, 0, 8) }
			)
		end,
	},
	{
		Id = "sm.landmark.emberaltar",
		Name = "Ember Altar",
		Category = "Landmarks",
		Description = "An octagonal basalt dais where Demonic disciples temper themselves: a cracked obsidian spire leaking "
			.. "ember light, chained to four braziers.",
		Tags = { "demonic", "landmark", "altar", "light" },
		Type = "Landmark",
		Region = "DemonicLandscape",
		Style = "Demonic",
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			for k = 0, 7 do
				local angle = math.rad(k * 45)
				Kit.Box(
					b,
					"DaisStep",
					Vector3.new(math.cos(angle) * 8, 0.5, math.sin(angle) * 8),
					Vector3.new(7, 1, 4),
					T.Basalt,
					"Basalt",
					{ Role = "Walkable", Rot = Vector3.new(0, -k * 45 + 90, 0) }
				)
			end
			Kit.Post(b, "Dais", Vector3.zero, 1.6, 15, T.Basalt, "Basalt", { Role = "Walkable" })
			Kit.Layer(b, "Frame")
			Kit.Wedge(
				b,
				"Spire",
				Vector3.new(0, 7.6, 0),
				Vector3.new(2.6, 12, 3.4),
				T.Basalt,
				"Glass",
				{ Rot = Vector3.new(6, 30, 4) }
			)
			Kit.Box(
				b,
				"SpireCrack",
				Vector3.new(0.2, 7, 0.2),
				Vector3.new(0.15, 9, 0.15),
				T.Ember,
				"Neon",
				{ Rot = Vector3.new(6, 30, 4) }
			)
			Kit.Layer(b, "Ornament")
			for k = 0, 3 do
				local angle = math.rad(k * 90 + 45)
				local at = Vector3.new(math.cos(angle) * 6, 1.6, math.sin(angle) * 6)
				Kit.Post(b, "BrazierStem", at, 2.2, 0.6, s.Metal, "CorrodedMetal")
				Kit.Post(b, "BrazierBowl", at + Vector3.new(0, 2.2, 0), 0.8, 2.2, s.Metal, "CorrodedMetal")
				Kit.Ball(b, "BrazierEmber", at + Vector3.new(0, 3.1, 0), 1.3, T.Ember, "Neon")
				Kit.Beam(b, at + Vector3.new(0, 3, 0), Vector3.new(0, 9, 0), 0.2, s.Metal)
			end
			for k = 0, 7 do
				local angle = math.rad(k * 45 + 22.5)
				Kit.Box(
					b,
					"EmberCrack",
					Vector3.new(math.cos(angle) * 5, 1.62, math.sin(angle) * 5),
					Vector3.new(0.18, 0.05, 3),
					T.Ember,
					"Neon",
					{ Rot = Vector3.new(0, -k * 45 - 22.5, 0) }
				)
			end
		end,
	},
} :: { Family }

return Landmarks
