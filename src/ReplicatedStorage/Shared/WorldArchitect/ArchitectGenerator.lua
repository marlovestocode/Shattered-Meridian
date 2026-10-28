--!strict
--[[
	ArchitectGenerator.lua

	Owns: procedural layout for the World Architect -- turning a seeded, bounded configuration into a list of template
	placements. Four generators, chosen for what the starter library can actually build:

	  Ruins    scattered sect ruins across an area, spaced so nothing overlaps
	  Grove    the same scatter pulled into one to three clumps, the way trees and stones gather
	  Pathway  a wandering flagstone path along the area's long axis, with markers alternating along its sides
	  Outpost  a palisade perimeter with corner posts and a gate on its front edge, camp pieces inside

	DETERMINISTIC. Everything random comes from one Random.new(Seed) consumed in a fixed order, and every list iterated
	is an array. The same config and the same injected world facts give the same layout, which is what lets the server
	re-run the layout on commit instead of trusting the client's preview -- the preview and the commit are the same call.

	PURE, WITH THE WORLD INJECTED. `heightAt(x, z)` (the ground under a point, or nil for none) and `blockers` (circles
	nothing may be placed into: spawn pads, existing construction) are arguments, so the spec drives it with plain
	functions and tables and the server hands it raycasts and its own footprints.

	NOTHING OVERLAPS AND NOTHING IS SILENTLY DROPPED. A placement is a template's footprint circle; it is refused when it
	leaves the area, touches another placement (closer than Spacing between edges), an exclusion or a blocker, or has no
	ground. Every refusal is counted by reason in the layout, so the panel can say "12 placed, 3 refused (blocked)".
	Path and perimeter pieces tile on purpose and are only refused by exclusions, blockers and missing ground.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Shared.Schema)
local ArchitectConstants = require(script.Parent.ArchitectConstants)
local ArchitectRecord = require(script.Parent.ArchitectRecord)
local ArchitectTemplates = require(script.Parent.ArchitectTemplates)
local StarterTemplates = require(script.Parent.StarterTemplates)

type Template = ArchitectTemplates.Template

local Gen = ArchitectConstants.Generation

local ArchitectGenerator = {}

export type Circle = { Center: Vector3, Radius: number }

export type Config = {
	Type: string,
	Seed: number,
	Center: Vector3,
	-- Width (local X) and depth (local Z) of the area, before Yaw turns it.
	AreaX: number,
	AreaZ: number,
	Yaw: number,
	-- Minimum gap between placement footprints.
	Spacing: number,
	-- 0..1 of the most placements the area could hold at this spacing.
	Density: number,
	-- Each placement turns by up to this many degrees either way.
	RotationJitter: number,
	-- Template pack override; nil uses the type's own.
	Pack: string?,
	Exclusions: { Circle },
	MaxPlacements: number,
	-- Rest each placement on the ground under it.
	FollowGround: boolean,
	-- Whose compound the composing generators build (SectCompound, RuinedQuarter).
	Faction: string,
}

export type Placement = {
	TemplateId: string,
	CFrame: CFrame,
	Radius: number,
	-- Path and perimeter pieces: tiled, not spaced.
	Tiled: boolean,
}

export type Layout = {
	Placements: { Placement },
	Requested: number,
	Refused: { [string]: number },
	-- The area's corners, for drawing the bounds.
	Corners: { Vector3 },
}

local DEFAULT_PACK: { [string]: string } = {
	Ruins = "Ruins",
	Grove = "Grove",
	Pathway = "Pathway",
	Outpost = "Outpost",
}

local PackNames: { string } = {}
for name in StarterTemplates.Packs do
	table.insert(PackNames, name :: string)
end
table.sort(PackNames)
ArchitectGenerator.PackNames = table.freeze(PackNames)

local CircleShape = Schema.Record({
	{ "Center", ArchitectRecord.PositionShape },
	{ "Radius", Schema.Number(1, Gen.MaxArea) },
})

ArchitectGenerator.ConfigShape = Schema.Record({
	{ "Type", Schema.Enum(Gen.Types) },
	{ "Seed", Schema.Number(0, 2 ^ 31 - 1) },
	{ "Center", ArchitectRecord.PositionShape },
	{ "AreaX", Schema.Number(Gen.MinArea, Gen.MaxArea) },
	{ "AreaZ", Schema.Number(Gen.MinArea, Gen.MaxArea) },
	{ "Yaw", Schema.Default(Schema.Number(-360, 360), 0) },
	{ "Spacing", Schema.Number(Gen.MinSpacing, Gen.MaxSpacing) },
	{ "Density", Schema.Number(0, 1) },
	{ "RotationJitter", Schema.Default(Schema.Number(0, 180), 0) },
	{ "Pack", Schema.Optional(Schema.Enum(PackNames)) },
	-- Absent means none; present must be valid. (Schema.Default would turn a malformed list into "no exclusions", and
	-- an exclusion the admin drew silently vanishing is exactly the wrong failure.)
	{
		"Exclusions",
		Schema.Custom(function(raw: unknown): ({ Circle }?, any)
			if raw == nil then
				return {}, nil
			end
			return Schema.Array(CircleShape, Gen.MaxExclusions)(raw)
		end),
	},
	{ "MaxPlacements", Schema.Default(Schema.Number(1, Gen.MaxPlacements), Gen.MaxPlacements) },
	{ "FollowGround", Schema.Default(Schema.Boolean, true) },
	{ "Faction", Schema.Default(Schema.Enum({ "Celestial", "Demonic", "Unbound" }), "Celestial") },
})

-- Decodes an untrusted config. The seed is floored so a fractional seed cannot make two "equal" configs differ.
function ArchitectGenerator.Decode(raw: unknown): (Config?, string?)
	local config, reason = Schema.Decode(ArchitectGenerator.ConfigShape, raw)
	if config == nil then
		return nil, reason
	end
	config.Seed = math.floor(config.Seed)
	config.MaxPlacements = math.floor(config.MaxPlacements)
	return config :: any, nil
end

type Context = {
	Config: Config,
	Rng: Random,
	Frame: CFrame,
	Placed: { Placement },
	Refused: { [string]: number },
	HeightAt: ((x: number, z: number) -> number?)?,
	Blockers: { Circle },
	Resolve: (id: string) -> Template?,
}

local function refuse(context: Context, reason: string): ()
	context.Refused[reason] = (context.Refused[reason] or 0) + 1
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

local function insideArea(context: Context, worldPoint: Vector3, radius: number): boolean
	local localPoint = context.Frame:PointToObjectSpace(worldPoint)
	return math.abs(localPoint.X) + radius <= context.Config.AreaX / 2
		and math.abs(localPoint.Z) + radius <= context.Config.AreaZ / 2
end

-- The refusal reason for a footprint, or nil when it may be placed. `spaced` checks distance to other placements.
local function check(context: Context, point: Vector3, radius: number, spaced: boolean): string?
	for _, exclusion in context.Config.Exclusions do
		if flatDistance(point, exclusion.Center) < exclusion.Radius + radius then
			return "Excluded"
		end
	end
	for _, blocker in context.Blockers do
		if flatDistance(point, blocker.Center) < blocker.Radius + radius then
			return "Blocked"
		end
	end
	if spaced then
		for _, other in context.Placed do
			if flatDistance(point, other.CFrame.Position) < other.Radius + radius + context.Config.Spacing then
				return "Crowded"
			end
		end
	end
	return nil
end

-- Rests a point on the ground, or nil when there is none.
local function grounded(context: Context, point: Vector3): Vector3?
	if not context.Config.FollowGround or context.HeightAt == nil then
		return Vector3.new(point.X, context.Config.Center.Y, point.Z)
	end
	local y = (context.HeightAt :: (number, number) -> number?)(point.X, point.Z)
	if y == nil then
		return nil
	end
	return Vector3.new(point.X, y, point.Z)
end

local function jitter(context: Context): number
	local range = context.Config.RotationJitter
	if range <= 0 then
		return 0
	end
	return context.Rng:NextNumber(-range, range)
end

-- Tries to add one placement; returns whether it landed. Never consumes randomness itself (callers draw first), so a
-- refusal never shifts what later placements draw -- only what was drawn decides.
local function try(
	context: Context,
	templateId: string,
	point: Vector3,
	yawDegrees: number,
	spaced: boolean,
	tiled: boolean
): boolean
	local template = context.Resolve(templateId)
	if template == nil then
		refuse(context, "MissingTemplate")
		return false
	end
	local radius = ArchitectTemplates.FootprintRadius(template)
	if spaced and not insideArea(context, point, radius) then
		refuse(context, "OutsideArea")
		return false
	end
	local reason = check(context, point, radius, spaced)
	if reason then
		refuse(context, reason)
		return false
	end
	local ground = grounded(context, point)
	if ground == nil then
		refuse(context, "NoGround")
		return false
	end
	table.insert(context.Placed, {
		TemplateId = templateId,
		CFrame = CFrame.new(ground) * CFrame.fromOrientation(0, math.rad(context.Config.Yaw + yawDegrees), 0),
		Radius = radius,
		Tiled = tiled,
	})
	return true
end

local function packOf(context: Context): { string }
	local name = context.Config.Pack or DEFAULT_PACK[context.Config.Type] or "Ruins"
	return StarterTemplates.Packs[name] or StarterTemplates.Packs.Ruins
end

-- How many scattered placements the area is asked for: Density of what fits at this spacing, capped.
local function wanted(context: Context, budget: number): number
	local c = context.Config
	local cell = math.max(c.Spacing * 2, 6)
	local capacity = math.floor((c.AreaX * c.AreaZ) / (cell * cell))
	return math.clamp(math.floor(capacity * c.Density + 0.5), 0, budget)
end

local function scatter(context: Context, count: number, clusters: { Vector3 }?, spread: number?): ()
	local pack = packOf(context)
	local c = context.Config
	for _ = 1, count do
		local landed = false
		for _ = 1, Gen.AttemptsPerPlacement do
			-- Draw everything this attempt needs before checking it, in a fixed order.
			local templateId = pack[context.Rng:NextInteger(1, #pack)]
			local lx, lz
			if clusters and #clusters > 0 then
				local anchor = clusters[context.Rng:NextInteger(1, #clusters)]
				local angle = context.Rng:NextNumber(0, math.pi * 2)
				local distance = math.abs(context.Rng:NextNumber() + context.Rng:NextNumber() - 1) * (spread or 1)
				lx = anchor.X + math.cos(angle) * distance
				lz = anchor.Z + math.sin(angle) * distance
			else
				lx = context.Rng:NextNumber(-c.AreaX / 2, c.AreaX / 2)
				lz = context.Rng:NextNumber(-c.AreaZ / 2, c.AreaZ / 2)
			end
			local yaw = jitter(context)
			local point = context.Frame:PointToWorldSpace(Vector3.new(lx, 0, lz))
			if try(context, templateId, point, yaw, true, false) then
				landed = true
				break
			end
		end
		if not landed then
			refuse(context, "NoRoom")
		end
	end
end

local function generateRuins(context: Context): number
	local count = wanted(context, context.Config.MaxPlacements)
	scatter(context, count, nil, nil)
	return count
end

local function generateGrove(context: Context): number
	local c = context.Config
	local clusterCount = context.Rng:NextInteger(1, 3)
	local clusters: { Vector3 } = {}
	for _ = 1, clusterCount do
		table.insert(
			clusters,
			Vector3.new(
				context.Rng:NextNumber(-c.AreaX / 4, c.AreaX / 4),
				0,
				context.Rng:NextNumber(-c.AreaZ / 4, c.AreaZ / 4)
			)
		)
	end
	local count = wanted(context, c.MaxPlacements)
	scatter(context, count, clusters, math.min(c.AreaX, c.AreaZ) / 3)
	return count
end

local PATH_STEP = 8

local function generatePathway(context: Context): number
	local c = context.Config
	local pack = packOf(context)
	local steps = math.min(math.floor(c.AreaX / PATH_STEP), c.MaxPlacements)
	local wander = context.Rng:NextNumber(0, math.pi * 2)
	local amplitude = math.min(c.AreaZ / 4, 6)
	local requested = 0
	local markerEvery = math.max(math.floor(c.Spacing / PATH_STEP), 1)
	for index = 0, steps - 1 do
		local lx = -c.AreaX / 2 + PATH_STEP / 2 + index * PATH_STEP
		local lz = math.sin(wander + index * 0.45) * amplitude
		requested += 1
		try(
			context,
			pack[1],
			context.Frame:PointToWorldSpace(Vector3.new(lx, 0, lz)),
			jitter(context) * 0.1,
			false,
			true
		)
		if index % markerEvery == 0 and #pack > 1 and #context.Placed < c.MaxPlacements then
			local side = if (index // markerEvery) % 2 == 0 then 1 else -1
			local markerId = pack[2 + (index // markerEvery) % (#pack - 1)]
			local offset = math.min(c.AreaZ / 2 - 2, amplitude + 6)
			requested += 1
			try(
				context,
				markerId,
				context.Frame:PointToWorldSpace(Vector3.new(lx, 0, lz + side * offset)),
				if side > 0 then 180 else 0,
				false,
				true
			)
		end
		if #context.Placed >= c.MaxPlacements then
			break
		end
	end
	return requested
end

local WALL_LENGTH = 16

local function generateOutpost(context: Context): number
	local c = context.Config
	local perimeter = StarterTemplates.Perimeter
	local halfX = math.floor(c.AreaX / 2 / WALL_LENGTH) * WALL_LENGTH
	local halfZ = math.floor(c.AreaZ / 2 / WALL_LENGTH) * WALL_LENGTH
	local requested = 0
	local function place(id: string, lx: number, lz: number, yaw: number): ()
		requested += 1
		if #context.Placed < c.MaxPlacements then
			try(context, id, context.Frame:PointToWorldSpace(Vector3.new(lx, 0, lz)), yaw, false, true)
		end
	end
	-- Corners, then each side's segments; the front side (+Z) has the gate in its middle segment.
	for _, corner in { { -halfX, -halfZ }, { halfX, -halfZ }, { -halfX, halfZ }, { halfX, halfZ } } do
		place(perimeter.Corner, corner[1], corner[2], 0)
	end
	local function side(fromX: number, fromZ: number, alongX: boolean, length: number, yaw: number, gate: boolean): ()
		local segments = math.floor(length / WALL_LENGTH)
		local middle = math.floor((segments + 1) / 2)
		for index = 1, segments do
			local t = -length / 2 + WALL_LENGTH * (index - 0.5)
			local lx = if alongX then t else fromX
			local lz = if alongX then fromZ else t
			place(if gate and index == middle then perimeter.Gate else perimeter.Wall, lx, lz, yaw)
		end
	end
	side(0, -halfZ, true, halfX * 2, 0, false)
	side(0, halfZ, true, halfX * 2, 180, true)
	side(-halfX, 0, false, halfZ * 2, 90, false)
	side(halfX, 0, false, halfZ * 2, -90, false)
	-- Interior: a scatter inside the walls, kept clear of them by one wall thickness plus the spacing.
	local inner = table.clone(c)
	inner.AreaX = math.max(halfX * 2 - 8, 0)
	inner.AreaZ = math.max(halfZ * 2 - 8, 0)
	if inner.AreaX > 8 and inner.AreaZ > 8 then
		local saved = context.Config
		context.Config = inner
		local budget = math.max(c.MaxPlacements - #context.Placed, 0)
		local count = wanted(context, budget)
		requested += count
		scatter(context, count, nil, nil)
		context.Config = saved
	end
	return requested
end

-- A walled sect compound, composed from kit pieces and assemblies rather than scattered: compound walls with a leak
-- window every third bay, corner piers, a moon gate on the front (+Z) axis, the main hall on the central axis at the
-- back, mirrored side halls facing the courtyard, a bell tower in a front corner, a flagstone path from the gate to
-- the hall's steps lined with stone lanterns, banners inside the gate. Whatever the area cannot fit is left out
-- (smaller halls first) rather than overlapped. `ruined` builds the same plan after the Shattering: most pieces swap
-- for their ruins, wall bays go missing, lanterns become rubble and fallen pillars, a Meridian shard has broken through.
local function compound(context: Context, ruined: boolean): number
	local c = context.Config
	local rng = context.Rng
	local faction = string.lower(c.Faction or "Celestial")
	local halfX = math.floor(c.AreaX / 2 / WALL_LENGTH) * WALL_LENGTH
	local halfZ = math.floor(c.AreaZ / 2 / WALL_LENGTH) * WALL_LENGTH
	if halfX < 32 or halfZ < 32 then
		refuse(context, "AreaTooSmall")
		return 0
	end
	local requested = 0
	local function variant(id: string, chance: number?): string
		if ruined and rng:NextNumber() < (chance or 0.7) then
			return id .. ".ruin"
		end
		return id
	end
	local function place(id: string, lx: number, lz: number, yaw: number): ()
		requested += 1
		if #context.Placed < c.MaxPlacements then
			try(context, id, context.Frame:PointToWorldSpace(Vector3.new(lx, 0, lz)), yaw, false, true)
		end
	end

	-- Perimeter.
	local perimeter = StarterTemplates.PerimeterFor(faction)
	for _, corner in { { -halfX, -halfZ }, { halfX, -halfZ }, { -halfX, halfZ }, { halfX, halfZ } } do
		place(variant(perimeter.Corner, 0.5), corner[1], corner[2], 0)
	end
	local function side(fixed: number, alongX: boolean, length: number, yaw: number, gate: boolean): ()
		local segments = math.floor(length / WALL_LENGTH)
		local middle = math.floor((segments + 1) / 2)
		for index = 1, segments do
			local t = -length / 2 + WALL_LENGTH * (index - 0.5)
			local isGate = gate and index == middle
			-- A ruined quarter has lost some of its wall outright; never the gate.
			if not isGate and ruined and rng:NextNumber() < 0.22 then
				continue
			end
			local id = if isGate then perimeter.Gate elseif index % 3 == 2 then perimeter.Window else perimeter.Wall
			place(variant(id), if alongX then t else fixed, if alongX then fixed else t, yaw)
		end
	end
	side(halfZ, true, halfX * 2, 0, true)
	side(-halfZ, true, halfX * 2, 180, false)
	side(-halfX, false, halfZ * 2, 90, false)
	side(halfX, false, halfZ * 2, -90, false)

	-- The main hall on the central axis, its steps toward the gate. A smaller compound gets a side hall instead.
	local big = halfX >= 32 and halfZ >= 48
	local hallId = if big then `sm.hall.main.{faction}` else `sm.hall.side.{faction}`
	local hallDepth = if big then 38 else 22
	local hallZ = -halfZ + 3 + hallDepth / 2
	place(variant(hallId, 0.85), 0, hallZ, 0)
	local hallFront = hallZ + hallDepth / 2 + (if big then 6 else 3)

	-- A bell tower takes the front-left corner when the compound is big enough; side halls, mirrored and facing the
	-- courtyard, fit between the main hall and whatever is left of the front (each hall is 38 long once turned).
	local towerRoom = halfX >= 48 and halfZ >= 48
	if halfX >= 48 then
		local zMin, zMax = hallFront + 19, halfZ - 21 - (if towerRoom then 16 else 0)
		if zMin <= zMax then
			local z = (zMin + zMax) / 2
			place(variant(`sm.hall.side.{faction}`), -halfX + 14, z, 90)
			place(variant(`sm.hall.side.{faction}`), halfX - 14, z, -90)
		end
	end
	if towerRoom then
		place(variant(`sm.tower.bell.{faction}`), -halfX + 11, halfZ - 11, 0)
	end

	-- The axis: flagstones from inside the gate to the hall's steps, lanterns in pairs, banners by the gate.
	local z = halfZ - 6
	local index = 0
	while z - 4 >= hallFront do
		place(if ruined and rng:NextNumber() < 0.35 then "sm.dress.rubble" else "sm.kit.path", 0, z, 0)
		if index % 2 == 1 then
			for _, x in { -6, 6 } do
				if ruined then
					place(
						if rng:NextNumber() < 0.5 then "sm.dress.fallenpillar" else "sm.dress.rubble",
						x,
						z,
						rng:NextNumber(0, 360)
					)
				else
					place("sm.dress.stonelantern", x, z, 0)
				end
			end
		end
		z -= 8
		index += 1
	end
	if not ruined then
		for _, x in { -10, 10 } do
			place(`sm.dress.banner.{faction}`, x, halfZ - 6, 180)
		end
		place("sm.dress.incense", 0, hallFront + 3, 0)
		for _, x in { -18, 18 } do
			if halfX >= 40 then
				place("sm.dress.pineplanter", x, hallFront + 4, 0)
			end
		end
	else
		place(
			"sm.meridian.obelisk",
			(rng:NextNumber() - 0.5) * halfX * 0.6,
			(hallFront + halfZ) / 2,
			rng:NextNumber(0, 360)
		)
		place(
			"sm.dress.boulders",
			(rng:NextNumber() - 0.5) * halfX,
			(hallFront + halfZ) / 2 + 8,
			rng:NextNumber(0, 360)
		)
	end
	return requested
end

local function generateSectCompound(context: Context): number
	return compound(context, false)
end

local function generateRuinedQuarter(context: Context): number
	return compound(context, true)
end

local GENERATORS: { [string]: (Context) -> number } = {
	SectCompound = generateSectCompound,
	RuinedQuarter = generateRuinedQuarter,
	Ruins = generateRuins,
	Grove = generateGrove,
	Pathway = generatePathway,
	Outpost = generateOutpost,
}

-- The layout for `config`. `resolve` finds a template by id (built-ins by default); `heightAt` and `blockers` are the
-- world, injected (see header).
function ArchitectGenerator.Generate(
	config: Config,
	heightAt: ((x: number, z: number) -> number?)?,
	blockers: { Circle }?,
	resolve: ((id: string) -> Template?)?
): Layout
	local frame = CFrame.new(config.Center) * CFrame.fromOrientation(0, math.rad(config.Yaw), 0)
	local context: Context = {
		Config = config,
		Rng = Random.new(config.Seed),
		Frame = frame,
		Placed = {},
		Refused = {},
		HeightAt = heightAt,
		Blockers = blockers or {},
		Resolve = resolve or StarterTemplates.Get,
	}
	local requested = (GENERATORS[config.Type] or generateRuins)(context)
	local corners: { Vector3 } = {}
	for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		table.insert(
			corners,
			frame:PointToWorldSpace(Vector3.new(corner[1] * config.AreaX / 2, 0, corner[2] * config.AreaZ / 2))
		)
	end
	return {
		Placements = context.Placed,
		Requested = requested,
		Refused = context.Refused,
		Corners = corners,
	}
end

-- Every node a layout expands to, as pending nodes for WorldState.Create: one Group for the whole generated area
-- (pivoted at the config's centre, so the area moves and undoes as one thing), one Group per placement under it.
-- Bounded by the caller against Limits.MaxNodesPerTransaction.
function ArchitectGenerator.Expand(
	layout: Layout,
	config: Config,
	resolve: ((id: string) -> Template?)?
): { ArchitectTemplates.PendingNode }
	local lookup: (string) -> Template? = resolve or StarterTemplates.Get
	local area = ArchitectRecord.Default("Group")
	area.Name = `{config.Type} #{config.Seed}`
	area.Position = config.Center
	local out: { ArchitectTemplates.PendingNode } = { { Ref = "area", ParentRef = nil, Record = area } }
	for index, placement in layout.Placements do
		local template = lookup(placement.TemplateId)
		if template then
			local prefix = `g{index}.`
			for _, node in ArchitectTemplates.Instantiate(template, placement.CFrame, prefix) do
				if node.Ref == prefix .. "root" then
					node.ParentRef = "area"
				end
				table.insert(out, node)
			end
		end
	end
	return out
end

return ArchitectGenerator
