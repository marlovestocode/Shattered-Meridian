--!strict
--[[
	StarterTemplates.lua

	Owns: the World Architect's built-in template library as the rest of the system sees it -- every built-in,
	validated, by id -- plus the template packs and perimeter sets the generators draw from.

	THE LIBRARY ITSELF LIVES IN Library/: ArchitectureKit (the grammar, palette, styles and ruin pass), Structures
	(halls, gates, towers, bridges), KitPieces (the grid-snapping modular pieces), Landmarks and Dressing. Each of those
	declares FAMILIES; this file expands every family into its templates:
	  * a faction family becomes one template per faction (Celestial, Demonic, Unbound), built in that faction's style;
	  * a family with Ruins also becomes the ruin of each, through ArchitectureKit.Ruin -- same footprint, roof mostly
	    gone, posts snapped, rubble, moss and Meridian seams;
	  * a faction-less family is one template (faction Any), built in its Style (Celestial unless named).
	Ids: `<family>.<faction>` and `<family>.<faction>.ruin`; a faction-less family keeps its own id.

	PRIMITIVES ONLY, ON PURPOSE: the map is Studio-authored and no mesh or asset ids exist for world pieces. Every
	template passes ArchitectTemplates.Validate the first time the library is read -- a broken built-in fails loudly
	there (and in Tests/WorldArchitect/ArchitectureLibrary.spec.lua), never at placement.
]]

local ArchitectTemplates = require(script.Parent.ArchitectTemplates)
local Kit = require(script.Parent.Library.ArchitectureKit)
local Structures = require(script.Parent.Library.Structures)
local KitPieces = require(script.Parent.Library.KitPieces)
local Landmarks = require(script.Parent.Library.Landmarks)
local Dressing = require(script.Parent.Library.Dressing)

type Template = ArchitectTemplates.Template
type Family = Structures.Family

local StarterTemplates = {}

local function factionId(family: Family, faction: string): string
	return `{family.Id}.{string.lower(faction)}`
end

-- Which built-ins each scatter generator draws from. Every id must exist (the spec checks).
StarterTemplates.Packs = table.freeze({
	Ruins = table.freeze({
		"sm.hall.side.celestial.ruin",
		"sm.pavilion.square.unbound.ruin",
		"sm.tower.bell.celestial.ruin",
		"sm.dress.fallenpillar",
		"sm.dress.rubble",
		"sm.kit.wall.celestial.ruin",
		"sm.dress.boulders",
	}),
	Outpost = table.freeze({
		"sm.outpost.watch.unbound",
		"sm.dress.crates",
		"sm.dress.weaponrack",
		"sm.dress.lanternpost.unbound",
		"sm.dress.banner.unbound",
	}),
	Pathway = table.freeze({ "sm.kit.path", "sm.dress.stonelantern", "sm.dress.lanternpost.celestial" }),
	Grove = table.freeze({ "sm.dress.pine", "sm.dress.bamboo", "sm.dress.boulders", "sm.dress.pineplanter" }),
	Meridian = table.freeze({
		"sm.meridian.obelisk",
		"sm.landmark.shrine",
		"sm.dress.voidfragments",
		"sm.dress.stonelantern",
	}),
	Demonic = table.freeze({
		"sm.dress.brazier",
		"sm.dress.charred",
		"sm.landmark.emberaltar",
		"sm.dress.banner.demonic",
	}),
})

export type Perimeter = { Wall: string, Window: string, Gate: string, Corner: string }

-- The wall pieces a compound of `faction` is enclosed with (a ruin set when `ruined`).
function StarterTemplates.PerimeterFor(faction: string, ruined: boolean?): Perimeter
	local f = string.lower(faction)
	local suffix = if ruined then ".ruin" else ""
	return {
		Wall = `sm.kit.wall.{f}{suffix}`,
		Window = `sm.kit.wallwindow.{f}{suffix}`,
		Gate = `sm.kit.moongate.{f}{suffix}`,
		Corner = `sm.kit.corner.{f}{suffix}`,
	}
end

-- The outpost generator's palisade: Unbound walls.
StarterTemplates.Perimeter = StarterTemplates.PerimeterFor("Unbound")

local cache: { Template }? = nil
local byId: { [string]: Template } = {}

local function build(family: Family, id: string, faction: string, ruined: boolean): Template
	local styleName = if faction ~= "Any" then faction else (family.Style or "Celestial")
	local b = Kit.Builder((Kit.Styles :: any)[styleName])
	family.Build(b)
	if ruined and not family.Ruined then
		Kit.Ruin(b, id)
	end
	local name = family.Name
	if ruined and not family.Ruined then
		name = `Ruined {name}`
	end
	if faction ~= "Any" then
		name = `{name} ({faction})`
	end
	local template, reason = ArchitectTemplates.Validate({
		Name = name,
		Category = family.Category,
		Description = family.Description,
		Tags = family.Tags,
		Version = 2,
		Type = family.Type,
		Faction = faction,
		Region = family.Region or "Any",
		Variant = if ruined or family.Ruined then "Ruined" else "Intact",
		Nodes = Kit.Export(b),
	}, id, true)
	assert(template, `StarterTemplates: built-in {id} is invalid: {tostring(reason)}`)
	return template
end

-- Every family the library declares, in browse order.
function StarterTemplates.Families(): { Family }
	local out: { Family } = {}
	for _, list in { Structures.Families, KitPieces.Families, Landmarks.Families, Dressing.Families } do
		for _, family in list do
			table.insert(out, family)
		end
	end
	return out
end

-- Every built-in, validated. Errors on a broken definition: a built-in that does not validate is a source bug.
function StarterTemplates.All(): { Template }
	if cache then
		return cache
	end
	local list: { Template } = {}
	local function add(template: Template)
		assert(byId[template.Id] == nil, `StarterTemplates: duplicate id {template.Id}`)
		table.insert(list, template)
		byId[template.Id] = template
	end
	for _, family in StarterTemplates.Families() do
		if family.Factions then
			for _, faction in family.Factions :: { string } do
				local id = factionId(family, faction)
				add(build(family, id, faction, false))
				if family.Ruins then
					add(build(family, id .. ".ruin", faction, true))
				end
			end
		else
			add(build(family, family.Id, "Any", family.Ruined == true))
		end
	end
	cache = list
	return list
end

function StarterTemplates.Get(id: string): Template?
	StarterTemplates.All()
	return byId[id]
end

return StarterTemplates
