--!strict
--[[
	TerrainBrush.lua

	Owns: the World Architect's terrain edits -- one bounded brush stroke at a time (Add, Subtract, Flatten, Smooth,
	Paint) -- and the voxel snapshot that makes every stroke recoverable.

	BOUNDED BY CONSTRUCTION. A stroke is a sphere (a cylinder for Flatten) of radius at most Terrain.MaxRadius, so the
	region it can change is at most ~52 studs on a side: a few thousand voxels. There is no "fill this region" or "clear
	the map" operation, so no request can make a destructive edit larger than one brush.

	RECOVERY. `Snapshot` reads the stroke's whole region (materials and occupancies) BEFORE it is applied; `Restore`
	writes it back exactly. Undo of the most recent stroke is therefore exact. Undo of an OLDER stroke is refused by the
	System when a later stroke's region overlaps it -- restoring the old snapshot would erase the later stroke.

	DETERMINISTIC. Given the same terrain and the same strokes in the same order, Apply produces the same voxels, which is
	what lets the stroke log be persisted with a world and replayed when it loads.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ArchitectCodec = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectCodec)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

type Stroke = ArchitectCodec.Stroke

local Config = ArchitectConstants.Terrain

local TerrainBrush = {}

export type Snapshot = {
	Region: Region3,
	Materials: { { { Enum.Material } } },
	Occupancies: { { { number } } },
}

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.Ground
end

-- The grid-aligned region a stroke can change.
function TerrainBrush.RegionOf(stroke: Stroke): Region3
	local r = stroke.Radius + Config.Resolution
	local low = stroke.Center - Vector3.new(r, r, r)
	local high = stroke.Center + Vector3.new(r, r, r)
	if stroke.Mode == "Flatten" and stroke.Height then
		local h = stroke.Height :: number
		low = Vector3.new(low.X, math.min(low.Y, h - r), low.Z)
		high = Vector3.new(high.X, math.max(high.Y, h + r), high.Z)
	end
	return Region3.new(low, high):ExpandToGrid(Config.Resolution)
end

-- Whether two strokes' regions overlap (so undoing the older would clobber the newer).
function TerrainBrush.Overlaps(a: Stroke, b: Stroke): boolean
	local ra, rb = TerrainBrush.RegionOf(a), TerrainBrush.RegionOf(b)
	local ah, bh = ra.Size / 2, rb.Size / 2
	local d = ra.CFrame.Position - rb.CFrame.Position
	return math.abs(d.X) < ah.X + bh.X and math.abs(d.Y) < ah.Y + bh.Y and math.abs(d.Z) < ah.Z + bh.Z
end

function TerrainBrush.Snapshot(terrain: Terrain, stroke: Stroke): Snapshot
	local region = TerrainBrush.RegionOf(stroke)
	local materials, occupancies = terrain:ReadVoxels(region, Config.Resolution)
	return { Region = region, Materials = materials :: any, Occupancies = occupancies :: any }
end

function TerrainBrush.Restore(terrain: Terrain, snapshot: Snapshot): ()
	terrain:WriteVoxels(snapshot.Region, Config.Resolution, snapshot.Materials, snapshot.Occupancies)
end

-- The voxel centre at grid index (x, y, z) of a region read at the brush resolution.
local function voxelCenter(region: Region3, x: number, y: number, z: number): Vector3
	local low = region.CFrame.Position - region.Size / 2
	return low + Vector3.new(x - 0.5, y - 0.5, z - 0.5) * Config.Resolution
end

local function smooth(terrain: Terrain, stroke: Stroke): ()
	local region = TerrainBrush.RegionOf(stroke)
	local materials, occupancies = terrain:ReadVoxels(region, Config.Resolution)
	local size = materials.Size
	local nextOcc = {}
	local nextMat = {}
	local function occAt(x: number, y: number, z: number, fallback: number): number
		if x < 1 or y < 1 or z < 1 or x > size.X or y > size.Y or z > size.Z then
			return fallback
		end
		return occupancies[x][y][z]
	end
	for x = 1, size.X do
		nextOcc[x], nextMat[x] = {}, {}
		for y = 1, size.Y do
			nextOcc[x][y], nextMat[x][y] = {}, {}
			for z = 1, size.Z do
				local occ = occupancies[x][y][z]
				local mat = materials[x][y][z]
				local distance = (voxelCenter(region, x, y, z) - stroke.Center).Magnitude
				if distance <= stroke.Radius then
					local sum = occAt(x - 1, y, z, occ)
						+ occAt(x + 1, y, z, occ)
						+ occAt(x, y - 1, z, occ)
						+ occAt(x, y + 1, z, occ)
						+ occAt(x, y, z - 1, occ)
						+ occAt(x, y, z + 1, occ)
					local falloff = 1 - distance / stroke.Radius
					local blended = occ + (sum / 6 - occ) * stroke.Strength * falloff
					if mat == Enum.Material.Air and blended > 0.05 then
						mat = material(stroke.Material)
					end
					occ = math.clamp(blended, 0, 1)
				end
				nextOcc[x][y][z] = occ
				nextMat[x][y][z] = mat
			end
		end
	end
	terrain:WriteVoxels(region, Config.Resolution, nextMat, nextOcc)
end

local function paint(terrain: Terrain, stroke: Stroke): ()
	local region = TerrainBrush.RegionOf(stroke)
	local materials, occupancies = terrain:ReadVoxels(region, Config.Resolution)
	local size = materials.Size
	local target = material(stroke.Material)
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if
					occupancies[x][y][z] > 0
					and materials[x][y][z] ~= Enum.Material.Air
					and materials[x][y][z] ~= Enum.Material.Water
					and (voxelCenter(region, x, y, z) - stroke.Center).Magnitude <= stroke.Radius
				then
					materials[x][y][z] = target
				end
			end
		end
	end
	terrain:WriteVoxels(region, Config.Resolution, materials, occupancies)
end

function TerrainBrush.Apply(terrain: Terrain, stroke: Stroke): ()
	local mode = stroke.Mode
	if mode == "Add" then
		terrain:FillBall(stroke.Center, stroke.Radius * math.max(stroke.Strength, 0.25), material(stroke.Material))
	elseif mode == "Subtract" then
		terrain:FillBall(stroke.Center, stroke.Radius * math.max(stroke.Strength, 0.25), Enum.Material.Air)
	elseif mode == "Flatten" then
		local h = stroke.Height or stroke.Center.Y
		local depth = stroke.Radius
		local base = CFrame.new(stroke.Center.X, h - depth / 2, stroke.Center.Z)
		local clear = CFrame.new(stroke.Center.X, h + depth / 2, stroke.Center.Z)
		terrain:FillCylinder(clear, depth, stroke.Radius, Enum.Material.Air)
		terrain:FillCylinder(base, depth, stroke.Radius, material(stroke.Material))
	elseif mode == "Smooth" then
		smooth(terrain, stroke)
	elseif mode == "Paint" then
		paint(terrain, stroke)
	end
end

return TerrainBrush
