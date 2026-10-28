--!strict
--[[
	ProtectedZones.lua

	Owns: finding the areas of the map nothing built with the World Architect may intrude on, as world-axis boxes for
	WorldState.SetZones (refused edits) and as circles for the generator (refused placements).

	TWO SOURCES:
	  * every SpawnLocation in Workspace (the onboarding threshold, the race arrival pads, anything a map author adds),
	    inflated so a spawn can never be walled in or buried -- a player must always arrive standing in open space;
	  * anything tagged `ArchitectProtected` (CollectionService) -- a BasePart's own box or a Model's bounding box --
	    for a map author to fence off an arena, a landmark or a route without touching code.

	Read when the server boots and again whenever an admin opens the editor, so a tag added in a live session counts.
	Nothing under the managed world's own folder is ever a zone (a builder cannot protect its own work from itself).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)

local ProtectedZones = {}

export type Zone = { Name: string, Min: Vector3, Max: Vector3 }

ProtectedZones.Tag = "ArchitectProtected"
-- Clearance around a spawn pad: sideways, and above it (a player is ~5 studs tall; this leaves headroom).
ProtectedZones.SpawnMargin = Vector3.new(6, 12, 6)

local function boxOf(instance: Instance): (Vector3?, Vector3?)
	if instance:IsA("BasePart") then
		local half = instance.Size / 2
		local cframe = instance.CFrame
		local extent = Vector3.new(
			math.abs(cframe.RightVector.X) * half.X
				+ math.abs(cframe.UpVector.X) * half.Y
				+ math.abs(cframe.LookVector.X) * half.Z,
			math.abs(cframe.RightVector.Y) * half.X
				+ math.abs(cframe.UpVector.Y) * half.Y
				+ math.abs(cframe.LookVector.Y) * half.Z,
			math.abs(cframe.RightVector.Z) * half.X
				+ math.abs(cframe.UpVector.Z) * half.Y
				+ math.abs(cframe.LookVector.Z) * half.Z
		)
		return cframe.Position - extent, cframe.Position + extent
	elseif instance:IsA("Model") then
		local cframe, size = instance:GetBoundingBox()
		return cframe.Position - size / 2, cframe.Position + size / 2
	end
	return nil, nil
end

function ProtectedZones.Collect(container: Instance): { Zone }
	local root = container:FindFirstChild(ArchitectConstants.RootFolderName)
	local zones: { Zone } = {}
	local function inManagedWorld(instance: Instance): boolean
		return root ~= nil and instance:IsDescendantOf(root)
	end
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("SpawnLocation") and not inManagedWorld(descendant) then
			local low, high = boxOf(descendant)
			if low and high then
				table.insert(zones, {
					Name = `Spawn {descendant:GetFullName()}`,
					Min = low - Vector3.new(ProtectedZones.SpawnMargin.X, 0, ProtectedZones.SpawnMargin.Z),
					Max = high + ProtectedZones.SpawnMargin,
				})
			end
		end
	end
	for _, tagged in CollectionService:GetTagged(ProtectedZones.Tag) do
		if tagged:IsDescendantOf(container) and not inManagedWorld(tagged) then
			local low, high = boxOf(tagged)
			if low and high then
				table.insert(zones, { Name = tagged:GetFullName(), Min = low, Max = high })
			end
		end
	end
	return zones
end

-- The zones as ground circles for the generator: centre on the box, radius to its far corner on the ground plane.
function ProtectedZones.Circles(zones: { Zone }): { { Center: Vector3, Radius: number } }
	local out = {}
	for _, zone in zones do
		local center = (zone.Min + zone.Max) / 2
		local half = (zone.Max - zone.Min) / 2
		table.insert(out, { Center = center, Radius = Vector2.new(half.X, half.Z).Magnitude })
	end
	return out
end

return ProtectedZones
