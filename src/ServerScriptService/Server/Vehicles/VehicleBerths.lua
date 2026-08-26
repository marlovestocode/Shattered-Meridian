--!strict
--[[
	VehicleBerths.lua

	Owns: reading VehicleConstants.Tags.Berth off the world into named, filtered, occupancy-aware
	berths -- the "spawn it at the dock" half of the registry, as opposed to VehicleCatalog's "which
	vehicles exist" half. Resolution and the accept-list rule only; it never spawns, never moves
	anything, and holds no state of its own.

	RESOLVED ON EVERY CALL, NOT CACHED AT BOOT, and this is the one place in the vehicle layer that
	deliberately differs from how BlimpSystem treats its own tags. A blimp caches its station lookup
	at registration because re-reading it per tick would be real per-frame work on a live hull. A
	berth is read when an admin opens a menu or presses a button -- single-digit times a minute, over
	a handful of tagged parts -- so caching would buy nothing measurable and would cost the one
	property this is actually wanted for: a builder tags a new pad in Studio and it is there, with no
	re-registration step to remember.

	AN EMPTY ACCEPT-LIST MEANS ANY, NOT NONE. The Attribute is absent on every berth a builder makes
	without thinking about it, which is most of them, and resolving absent as "accepts nothing" would
	make the default berth a berth that rejects everything -- a failure that looks exactly like the
	feature being broken. Accepts is a restriction you opt into.

	OCCUPANCY IS PROXIMITY, NOT A RESERVATION. A berth is taken while some live vehicle's pivot is
	within BerthClearRadiusStuds of it, computed from the pivots the caller passes in. No berth ever
	holds a lease on a vehicle, and that is what keeps this correct across every way a vehicle can
	leave: despawned, destroyed in Studio, flown away by a pilot, or reclaimed by the owner-leave
	sweep. A reservation table would have to be told about all five, and would silently strand a
	berth the first time one of them was missed.

	Does not own: the live vehicle registry (Server/Systems/VehicleManager.lua owns it and passes
	pivots down), the placement arithmetic (Server/Vehicles/VehiclePlacement.lua), or the tag NAME
	(Shared/Vehicle/VehicleConstants.lua).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local VehicleCatalog = require(ReplicatedStorage.Shared.Vehicle.VehicleCatalog)
local VehicleConstants = require(ReplicatedStorage.Shared.Vehicle.VehicleConstants)

local logger = Logger.scope("VehicleBerths")

local VehicleBerths = {}

export type Berth = {
	Part: BasePart,
	Name: string,
	-- Empty means any -- see this file's header.
	Accepts: { string },
}

-- Every tagged berth currently in the world, sorted by name so the Dev Menu's berth list is stable
-- between fetches. A berth tagged on something that is not a BasePart has no position and no heading,
-- so it cannot place anything; it is warned about once per scan rather than skipped silently, since a
-- builder who tagged the Model instead of the pad gets no other feedback.
function VehicleBerths.Resolve(): { Berth }
	local berths: { Berth } = {}
	local seenNames: { [string]: BasePart } = {}

	for _, tagged in CollectionService:GetTagged(VehicleConstants.Tags.Berth) do
		if not tagged:IsA("BasePart") then
			logger:warn("Berth tag on a non-BasePart; ignoring", { instance = tagged:GetFullName() })
			continue
		end
		local part = tagged :: BasePart

		local rawName = part:GetAttribute(VehicleConstants.Attributes.BerthName)
		local name = if typeof(rawName) == "string" and #(rawName :: string) > 0 then rawName :: string else part.Name

		-- Two berths under one name is a build error rather than a two-pad feature: a spawn names a
		-- berth, so the second one is simply unreachable. Kept-first-and-logged, the same resolution
		-- (and for the same reason) BlimpTagging.ResolveStations gives a model with two helms -- an
		-- assert here would take the whole vehicle system down over one duplicated pad.
		local existing = seenNames[name]
		if existing then
			logger:warn("Two berths share a name; ignoring the second", {
				name = name,
				keeping = existing:GetFullName(),
				ignoring = part:GetFullName(),
			})
			continue
		end
		seenNames[name] = part

		local rawAccepts = part:GetAttribute(VehicleConstants.Attributes.BerthAccepts)
		local accepts = VehicleCatalog.SplitList(if typeof(rawAccepts) == "string" then rawAccepts :: string else nil)

		table.insert(berths, { Part = part, Name = name, Accepts = accepts })
	end

	table.sort(berths, function(a, b)
		return a.Name < b.Name
	end)

	return berths
end

function VehicleBerths.Accepts(berth: Berth, vehicleId: string): boolean
	if #berth.Accepts == 0 then
		return true
	end
	return table.find(berth.Accepts, vehicleId) ~= nil
end

-- Whether any of `occupiedPivots` sits close enough to count as parked here. Takes the positions
-- rather than reaching for the live registry, which keeps this function pure and is what lets the
-- radius rule be tested without spawning anything.
function VehicleBerths.IsOccupied(berth: Berth, occupiedPivots: { Vector3 }): boolean
	local radius = VehicleConstants.Spawn.BerthClearRadiusStuds
	local origin = berth.Part.Position
	for _, pivot in occupiedPivots do
		if (pivot - origin).Magnitude <= radius then
			return true
		end
	end
	return false
end

-- The berth called `name`, or nil. Case-sensitive, matching how a builder typed it -- a
-- case-insensitive match would let two berths named "Dock" and "dock" both resolve to the first one
-- while Resolve above reports them as distinct, which is a disagreement between two functions in the
-- same file.
function VehicleBerths.Find(berths: { Berth }, name: string): Berth?
	for _, berth in berths do
		if berth.Name == name then
			return berth
		end
	end
	return nil
end

return VehicleBerths
