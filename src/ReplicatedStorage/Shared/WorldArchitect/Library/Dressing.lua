--!strict
--[[
	Library/Dressing.lua

	Owns: the small things that make a built place feel lived in, fought over or abandoned -- lanterns, braziers,
	banners, weapon racks, incense burners, planted pines, bamboo, boulders, rubble, fallen pillars, charred timber,
	Void fragments and supply crates. Each is tagged with the region it belongs to (or Any), and banners come in each
	faction's colours. Kept small (Tests/WorldArchitect/ArchitectureLibrary.spec.lua holds dressing to 30 parts), so a
	courtyard can carry dozens.
]]

local Kit = require(script.Parent.ArchitectureKit)
local Structures = require(script.Parent.Structures)
local Landmarks = require(script.Parent.Landmarks)

type Builder = Kit.Builder
type Family = Structures.Family

local T = Kit.Tones

local Dressing = {}

local function pine(b: Builder, base: Vector3, scale: number)
	Kit.Post(b, "Trunk", base, 6 * scale, 1.1 * scale, T.Timber, "Wood")
	for tier = 0, 3 do
		local width = (6.5 - tier * 1.4) * scale
		Kit.Box(
			b,
			"Bough",
			base + Vector3.new((tier % 2 - 0.5) * 0.6 * scale, (3.6 + tier * 1.5) * scale, 0),
			Vector3.new(width, 1.4 * scale, width * 0.8),
			if tier % 2 == 0 then T.Leaf else T.Moss,
			"LeafyGrass",
			{ Role = "Decor", Shape = "Ball", Rot = Vector3.new(0, tier * 37, 0) }
		)
	end
end

Dressing.Families = {
	{
		Id = "sm.dress.stonelantern",
		Name = "Stone Lantern",
		Category = "Lanterns & Shrines",
		Description = "A carved stone lantern with a Meridian glow in its firebox, for paths, gates and shrine steps.",
		Tags = { "lantern", "light", "path" },
		Type = "Dressing",
		Build = function(b)
			Kit.Layer(b, "Base")
			Landmarks.StoneLantern(b, Vector3.zero)
		end,
	},
	{
		Id = "sm.dress.lanternpost",
		Name = "Lantern Post",
		Category = "Lanterns & Shrines",
		Description = "A lacquered post with a cloth lantern hung from its arm.",
		Tags = { "lantern", "light", "path" },
		Type = "Dressing",
		Factions = Kit.FactionNames,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(b, "PostFooting", Vector3.new(0, 0.3, 0), Vector3.new(1.4, 0.6, 1.4), s.PlatformTrim, "Slate")
			Kit.Post(b, "LanternPost", Vector3.new(0, 0.6, 0), 8, 0.7, s.Post, s.PostMaterial)
			Kit.Box(
				b,
				"LanternArm",
				Vector3.new(0.9, 8.2, 0),
				Vector3.new(2.2, 0.35, 0.35),
				s.Beam,
				"Wood",
				{ Role = "Decor" }
			)
			Kit.HangingLantern(b, Vector3.new(1.7, 6.6, 0), if s.Name == "Demonic" then T.Ember else T.Meridian)
		end,
	},
	{
		Id = "sm.dress.brazier",
		Name = "Ember Brazier",
		Category = "Lanterns & Shrines",
		Description = "A bronze bowl of embers on three legs; the light the Demonic sects keep.",
		Tags = { "light", "demonic", "fire" },
		Type = "Dressing",
		Region = "DemonicLandscape",
		Style = "Demonic",
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			for k = 0, 2 do
				local angle = math.rad(k * 120)
				Kit.Beam(
					b,
					Vector3.new(math.cos(angle) * 1.2, 0, math.sin(angle) * 1.2),
					Vector3.new(math.cos(angle) * 0.4, 2.6, math.sin(angle) * 0.4),
					0.3,
					s.Metal
				)
			end
			Kit.Post(b, "Bowl", Vector3.new(0, 2.4, 0), 0.9, 2.6, s.Metal, "CorrodedMetal")
			Kit.Post(b, "BowlRim", Vector3.new(0, 3.2, 0), 0.2, 2.9, s.Metal, "CorrodedMetal", { Role = "Decor" })
			Kit.Ball(b, "Embers", Vector3.new(0, 3.3, 0), 1.8, T.Ember, "Neon")
			Kit.Ball(b, "Coal", Vector3.new(0.5, 3.4, 0.3), 0.7, T.Basalt, "Basalt")
		end,
	},
	{
		Id = "sm.dress.banner",
		Name = "Sect Banner",
		Category = "Props",
		Description = "A tall banner pole in the sect's colours, its emblem stitched in the faction's accent.",
		Tags = { "banner", "faction", "courtyard" },
		Type = "Dressing",
		Factions = Kit.FactionNames,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(b, "BannerBase", Vector3.new(0, 0.5, 0), Vector3.new(2, 1, 2), s.PlatformTrim, "Slate")
			Kit.Post(b, "BannerPole", Vector3.new(0, 1, 0), 13, 0.5, s.Post, s.PostMaterial)
			Kit.Box(
				b,
				"BannerBar",
				Vector3.new(1.2, 13.4, 0),
				Vector3.new(3.4, 0.3, 0.3),
				s.Beam,
				"Wood",
				{ Role = "Decor" }
			)
			Kit.Box(
				b,
				"Banner",
				Vector3.new(1.4, 9.6, 0),
				Vector3.new(2.6, 7.4, 0.1),
				s.Banner,
				"Fabric",
				{ Role = "Decor" }
			)
			Kit.Box(
				b,
				"BannerEmblem",
				Vector3.new(1.4, 10.6, 0.08),
				Vector3.new(1.2, 1.2, 0.05),
				s.Accent,
				s.AccentMaterial,
				{ Role = "Decor", Rot = Vector3.new(0, 0, 45) }
			)
			Kit.Ball(b, "PoleFinial", Vector3.new(0, 14.2, 0), 0.6, s.Metal, "Metal")
		end,
	},
	{
		Id = "sm.dress.weaponrack",
		Name = "Weapon Rack",
		Category = "Props",
		Description = "A training-yard rack holding three spears and two straight swords.",
		Tags = { "prop", "courtyard", "training" },
		Type = "Dressing",
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			for _, x in { -2.2, 2.2 } do
				Kit.Box(b, "RackPost", Vector3.new(x, 2.2, 0), Vector3.new(0.5, 4.4, 0.8), s.Beam, "Wood")
			end
			Kit.Box(b, "RackBar", Vector3.new(0, 3.8, 0), Vector3.new(4.9, 0.35, 0.5), s.Beam, "Wood")
			Kit.Box(b, "RackFoot", Vector3.new(0, 0.6, 0.6), Vector3.new(4.9, 0.3, 0.6), s.Beam, "Wood")
			for i = -1, 1 do
				local x = i * 1.4
				Kit.Post(
					b,
					"SpearShaft",
					Vector3.new(x, 0.4, 0.5),
					6.4,
					0.18,
					T.Timber,
					"Wood",
					{ Role = "Decor", Rot = Vector3.new(-8, 0, 0) }
				)
				Kit.Wedge(
					b,
					"SpearHead",
					Vector3.new(x, 7.1, 0.0),
					Vector3.new(0.12, 0.9, 0.3),
					s.Metal,
					"Metal",
					{ Role = "Decor", Rot = Vector3.new(-8, 0, 0) }
				)
			end
			for _, x in { -0.7, 0.7 } do
				Kit.Box(
					b,
					"SwordBlade",
					Vector3.new(x, 2.7, -0.4),
					Vector3.new(0.12, 3, 0.35),
					s.Metal,
					"Metal",
					{ Role = "Decor" }
				)
				Kit.Box(
					b,
					"SwordGuard",
					Vector3.new(x, 4.25, -0.4),
					Vector3.new(0.2, 0.15, 0.8),
					s.Metal,
					"Metal",
					{ Role = "Decor" }
				)
			end
		end,
	},
	{
		Id = "sm.dress.incense",
		Name = "Incense Burner",
		Category = "Lanterns & Shrines",
		Description = "A three-legged bronze ding before a hall's steps, its lid crowned with a Meridian bead.",
		Tags = { "shrine", "courtyard", "bronze" },
		Type = "Dressing",
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			for k = 0, 2 do
				local angle = math.rad(k * 120 + 30)
				Kit.Post(
					b,
					"DingLeg",
					Vector3.new(math.cos(angle) * 1, 0, math.sin(angle) * 1),
					1.2,
					0.35,
					s.Metal,
					"CorrodedMetal"
				)
			end
			Kit.Post(b, "DingBody", Vector3.new(0, 1.2, 0), 1.6, 2.6, s.Metal, "CorrodedMetal")
			Kit.Post(b, "DingRim", Vector3.new(0, 2.8, 0), 0.25, 3, s.Metal, "CorrodedMetal", { Role = "Decor" })
			for _, side in { -1, 1 } do
				Kit.Box(
					b,
					"DingHandle",
					Vector3.new(side * 1.1, 3.3, 0),
					Vector3.new(0.25, 0.9, 0.7),
					s.Metal,
					"CorrodedMetal",
					{ Role = "Decor" }
				)
			end
			Kit.Box(
				b,
				"DingLid",
				Vector3.new(0, 3.15, 0),
				Vector3.new(1.9, 0.5, 1.9),
				s.Metal,
				"CorrodedMetal",
				{ Role = "Decor", Shape = "Ball" }
			)
			Kit.Ball(b, "DingBead", Vector3.new(0, 3.6, 0), 0.45, T.Meridian, "Neon")
		end,
	},
	{
		Id = "sm.dress.pineplanter",
		Name = "Pine Planter",
		Category = "Nature",
		Description = "A stone planter with a trained pine, for courtyards and terrace corners.",
		Tags = { "nature", "courtyard", "tree" },
		Type = "Dressing",
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Box(b, "Planter", Vector3.new(0, 1, 0), Vector3.new(4, 2, 4), s.Platform, "Granite")
			Kit.Box(
				b,
				"PlanterRim",
				Vector3.new(0, 2.1, 0),
				Vector3.new(4.4, 0.3, 4.4),
				s.PlatformTrim,
				"Slate",
				{ Role = "Walkable" }
			)
			Kit.Box(
				b,
				"Soil",
				Vector3.new(0, 2.15, 0),
				Vector3.new(3.4, 0.2, 3.4),
				T.TimberDark,
				"Ground",
				{ Role = "Decor" }
			)
			pine(b, Vector3.new(0, 2.2, 0), 0.6)
		end,
	},
	{
		Id = "sm.dress.pine",
		Name = "Mountain Pine",
		Category = "Nature",
		Description = "A full mountain pine, its boughs in layered tiers.",
		Tags = { "nature", "tree" },
		Type = "Dressing",
		Region = "MedianParadise",
		Build = function(b)
			Kit.Layer(b, "Base")
			pine(b, Vector3.zero, 1.4)
		end,
	},
	{
		Id = "sm.dress.bamboo",
		Name = "Bamboo Stand",
		Category = "Nature",
		Description = "A clump of tall bamboo with leaf clusters at the tops; screens a path or a hidden approach.",
		Tags = { "nature", "cover", "covert" },
		Type = "Dressing",
		Region = "MedianParadise",
		Build = function(b)
			local rng = Random.new(91)
			Kit.Layer(b, "Base")
			for i = 1, 9 do
				local angle = i * 2.4
				local r = 0.6 + (i % 3) * 0.9
				local base = Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
				local height = rng:NextNumber(11, 16)
				Kit.Post(
					b,
					"Culm",
					base,
					height,
					0.45,
					T.Moss,
					"Wood",
					{ Rot = Vector3.new(rng:NextNumber(-4, 4), 0, rng:NextNumber(-4, 4)) }
				)
				if i % 2 == 1 then
					Kit.Box(
						b,
						"BambooLeaves",
						base + Vector3.new(0, height - 1, 0),
						Vector3.new(3, 1.6, 2.4),
						T.Leaf,
						"LeafyGrass",
						{ Role = "Decor", Shape = "Ball" }
					)
				end
			end
		end,
	},
	{
		Id = "sm.dress.boulders",
		Name = "Mossy Boulders",
		Category = "Nature",
		Description = "Three weathered boulders, moss on their crowns; low cover.",
		Tags = { "nature", "cover" },
		Type = "Dressing",
		Region = "MedianParadise",
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Box(
				b,
				"Boulder",
				Vector3.new(0, 2.2, 0),
				Vector3.new(5.5, 4.4, 5),
				T.StoneDark,
				"Rock",
				{ Shape = "Ball" }
			)
			Kit.Box(
				b,
				"Boulder",
				Vector3.new(4.2, 1.4, 1.6),
				Vector3.new(3.2, 2.8, 3),
				T.Stone,
				"Rock",
				{ Shape = "Ball" }
			)
			Kit.Box(
				b,
				"Boulder",
				Vector3.new(-3.6, 1.1, 2.4),
				Vector3.new(2.6, 2.2, 2.4),
				T.Stone,
				"Rock",
				{ Shape = "Ball" }
			)
			Kit.Box(
				b,
				"MossCrown",
				Vector3.new(0, 4.15, 0),
				Vector3.new(3.4, 0.6, 3),
				T.Moss,
				"Grass",
				{ Role = "Decor", Shape = "Ball" }
			)
			Kit.Box(
				b,
				"MossCrown",
				Vector3.new(4.2, 2.65, 1.6),
				Vector3.new(1.8, 0.4, 1.6),
				T.Moss,
				"Grass",
				{ Role = "Decor", Shape = "Ball" }
			)
		end,
	},
	{
		Id = "sm.dress.rubble",
		Name = "Rubble Pile",
		Category = "Ruins",
		Description = "Broken masonry from a fallen wall, with a Meridian seam glowing between the stones.",
		Tags = { "ruin", "cover", "small" },
		Type = "Dressing",
		Ruined = true,
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Rubble(b, Vector3.zero, Random.new(11), 6)
			Kit.Rubble(b, Vector3.new(3, 0, 1), Random.new(12), 3)
			Kit.Box(
				b,
				"MeridianSeam",
				Vector3.new(0.5, 0.04, 0.5),
				Vector3.new(0.18, 0.06, 4),
				T.Meridian,
				"Neon",
				{ Rot = Vector3.new(0, 35, 0) }
			)
		end,
	},
	{
		Id = "sm.dress.fallenpillar",
		Name = "Fallen Pillar",
		Category = "Ruins",
		Description = "A hall column thrown down in pieces beside its stone drum, moss creeping over the shaft.",
		Tags = { "ruin", "cover" },
		Type = "Dressing",
		Ruined = true,
		Build = function(b)
			local s = b.Style
			Kit.Layer(b, "Base")
			Kit.Post(b, "ColumnBase", Vector3.zero, 0.7, 2.4, s.PlatformTrim, "Slate")
			Kit.Post(b, "Stump", Vector3.new(0, 0.7, 0), 2.2, 1.4, s.Post, s.PostMaterial)
			Kit.PartAt(
				b,
				"FallenShaft",
				CFrame.new(4, 0.7, 1) * CFrame.fromOrientation(0, math.rad(20), 0),
				Vector3.new(6, 1.4, 1.4),
				s.Post,
				s.PostMaterial,
				{ Shape = "Cylinder" }
			)
			Kit.PartAt(
				b,
				"FallenShaft",
				CFrame.new(9.5, 0.7, 3.2) * CFrame.fromOrientation(0, math.rad(35), math.rad(4)),
				Vector3.new(4, 1.4, 1.4),
				s.Post,
				s.PostMaterial,
				{ Shape = "Cylinder" }
			)
			Kit.Box(
				b,
				"FallenCapital",
				Vector3.new(12.4, 0.45, 5.2),
				Vector3.new(1.9, 0.6, 1.9),
				s.Beam,
				"Wood",
				{ Rot = Vector3.new(8, 30, 0) }
			)
			Kit.Box(
				b,
				"Moss",
				Vector3.new(4, 1.35, 1),
				Vector3.new(3, 0.12, 1.2),
				T.Moss,
				"Grass",
				{ Role = "Decor", Rot = Vector3.new(0, 20, 0) }
			)
		end,
	},
	{
		Id = "sm.dress.charred",
		Name = "Charred Timbers",
		Category = "Ruins",
		Description = "The burned frame of something that stood here, embers still glinting in the cracks.",
		Tags = { "ruin", "demonic", "fire", "cover" },
		Type = "Dressing",
		Region = "DemonicLandscape",
		Ruined = true,
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Box(
				b,
				"CharredBeam",
				Vector3.new(0, 0.5, 0),
				Vector3.new(9, 1, 1),
				T.Basalt,
				"Wood",
				{ Rot = Vector3.new(0, 15, 4) }
			)
			Kit.Box(
				b,
				"CharredBeam",
				Vector3.new(0.5, 1.3, 0.4),
				Vector3.new(7, 0.9, 0.9),
				T.TimberDark,
				"Wood",
				{ Rot = Vector3.new(0, -40, 8) }
			)
			Kit.Box(
				b,
				"CharredPost",
				Vector3.new(-3, 2.2, -1.5),
				Vector3.new(1, 4.4, 1),
				T.Basalt,
				"Wood",
				{ Rot = Vector3.new(0, 0, 14) }
			)
			Kit.Box(
				b,
				"CharredBeam",
				Vector3.new(2.5, 0.45, -2),
				Vector3.new(5, 0.9, 0.9),
				T.Basalt,
				"Wood",
				{ Rot = Vector3.new(0, 70, -3) }
			)
			for i, at in { Vector3.new(0.2, 1.02, 0.1), Vector3.new(-2.6, 2.8, -1.4), Vector3.new(2.2, 0.92, -1.8) } do
				Kit.Box(
					b,
					"EmberGlint",
					at,
					Vector3.new(0.6, 0.08, 0.2),
					T.Ember,
					"Neon",
					{ Rot = Vector3.new(0, i * 50, 0) }
				)
			end
		end,
	},
	{
		Id = "sm.dress.voidfragments",
		Name = "Void Fragments",
		Category = "Nature",
		Description = "Shards of stone and Meridian crystal hanging where the Void has pulled the ground apart.",
		Tags = { "void", "meridian", "floating" },
		Type = "Dressing",
		Region = "Void",
		Build = function(b)
			local rng = Random.new(47)
			Kit.Layer(b, "Base")
			for i = 1, 7 do
				local angle = i * 0.9
				local crystal = i % 3 == 0
				Kit.Wedge(
					b,
					if crystal then "Shard" else "Fragment",
					Vector3.new(math.cos(angle) * (2 + i * 0.6), 2 + i * 1.1, math.sin(angle) * (2 + i * 0.6)),
					if crystal
						then Vector3.new(0.8, 2.6, 1)
						else Vector3.new(rng:NextNumber(1.5, 3), rng:NextNumber(1, 2), rng:NextNumber(1.5, 3)),
					if crystal then T.Meridian else T.Basalt,
					if crystal then "Glass" else "Rock",
					{
						Role = "Decor",
						Rot = Vector3.new(rng:NextNumber(0, 180), rng:NextNumber(0, 360), rng:NextNumber(0, 180)),
						Transparency = if crystal then 0.3 else 0,
					}
				)
			end
		end,
	},
	{
		Id = "sm.dress.crates",
		Name = "Supply Crates",
		Category = "Props",
		Description = "Stacked crates, a sack and a coil of rope: the stores of a camp or a smugglers' cache.",
		Tags = { "prop", "camp", "cover" },
		Type = "Dressing",
		Style = "Unbound",
		Build = function(b)
			Kit.Layer(b, "Base")
			Kit.Box(b, "Crate", Vector3.new(0, 1.5, 0), Vector3.new(3, 3, 3), T.Timber, "WoodPlanks")
			Kit.Box(
				b,
				"Crate",
				Vector3.new(3.1, 1.25, 0.4),
				Vector3.new(2.5, 2.5, 2.5),
				T.TimberDark,
				"WoodPlanks",
				{ Rot = Vector3.new(0, 14, 0) }
			)
			Kit.Box(
				b,
				"Crate",
				Vector3.new(0.4, 4.25, 0.2),
				Vector3.new(2.5, 2.5, 2.5),
				T.Timber,
				"WoodPlanks",
				{ Rot = Vector3.new(0, -9, 0) }
			)
			Kit.Box(
				b,
				"Sack",
				Vector3.new(-2.3, 0.7, 1.4),
				Vector3.new(1.8, 1.4, 1.4),
				T.Bronze,
				"Fabric",
				{ Role = "Decor", Shape = "Ball" }
			)
			Kit.Post(b, "RopeCoil", Vector3.new(-1.8, 0, -1.6), 0.5, 1.6, T.Bronze, "Fabric", { Role = "Decor" })
		end,
	},
	{
		Id = "sm.dress.guardians",
		Name = "Stone Guardians",
		Category = "Props",
		Description = "A pair of guardian statues to flank a hall's steps or a gate.",
		Tags = { "statue", "gate", "courtyard" },
		Type = "Dressing",
		Build = function(b)
			Kit.Layer(b, "Base")
			for _, side in { -1, 1 } do
				Kit.Guardian(b, Vector3.new(side * 5, 0, 0), 180)
			end
		end,
	},
} :: { Family }

return Dressing
