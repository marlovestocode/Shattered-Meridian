--!strict
--[[
	BoatWater.lua

	Owns: the world's water, as Instances -- watching BoatConstants.Tags.Water, turning every tagged part
	into the inert BoatTypes.WaterPlane record a containment test actually needs, and keeping that list
	current as a builder tags and untags things at runtime. It answers exactly one question for the rest
	of the layer: "here is a point, is there water under it and how high".

	THE COMPANION TO Shared/Boat/BoatWaterMath.lua, AND THE SPLIT IS THE POINT. That module is pure
	arithmetic over a list of planes and is therefore fully testable; this one is the tag walk, the two
	CollectionService signals and the cache, and is therefore not. Everything that could be on the pure
	side is, which is why the only logic in this file is "when does the list change".

	CACHED AND SIGNAL-DRIVEN, NOT RE-RESOLVED PER TICK, and this is the one place the Boat layer
	deliberately differs from how Server/Vehicles/VehicleBerths.lua treats its own tags. A berth is read
	when an admin opens a menu -- single-digit times a minute -- so caching would buy nothing. Water is
	read once per boat per Heartbeat forever, and GetTagged plus a bounding-box read per tagged part per
	tick would be real, permanent, always-on cost to answer a question that changes when a builder edits
	the map. So the list is built once and rebuilt on GetInstanceAddedSignal/GetInstanceRemovedSignal,
	which gives a builder the same live-edit experience for free.

	A PART'S GEOMETRY IS ALSO CACHED, and that is the part worth knowing about when something looks
	wrong: a plane's top face and extents are read when it is TAGGED, so a builder who resizes or moves
	a water part already in the world does not see the change until it is re-tagged (remove the tag, add
	it back -- one gesture in the Tag Editor, the same one every other tagged system here already
	expects). Watching every tagged part's Size and CFrame instead would be two property connections per
	plane for the lifetime of the server, on a set of objects that are almost by definition static.

	AN EMPTY WORLD IS WARNED ABOUT ONCE. A map with no tagged water at all is the single most likely
	authoring mistake in this layer and the only one that makes every boat in it look broken rather than
	plain -- see BoatConstants' own contract, item 5 -- so the first boat registered into such a world
	says so in the log. Once, not per boat and not per tick: a warning that repeats sixty times a second
	is one a developer turns off.

	Does not own: the containment and swell arithmetic (Shared/Boat/BoatWaterMath.lua), the tag NAME
	(BoatConstants.Tags.Water), or what a hull does with the answer (Server/Boat/BoatDrive.lua).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)
local BoatWaterMath = require(ReplicatedStorage.Shared.Boat.BoatWaterMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local logger = Logger.scope("BoatWater")

local BoatWater = {}

local planes: { BoatTypes.WaterPlane } = {}
local trove: Trove.TroveInstance? = nil
local warnedAboutEmptyWorld = false

-- One tagged part, reduced to what BoatWaterMath.SurfaceUnder needs. The Inverse is cached here rather
-- than computed per test because a containment test runs per boat per tick and CFrame:Inverse() is not
-- free; the half-extents likewise.
--
-- TopY is the centre plus half the height, which is exact for a level slab and for one yawed about Y --
-- the two shapes anybody builds a sea out of -- and merely approximate for one a builder has tilted. See
-- BoatConstants.Tags.Water on why tilting one is unsupported rather than handled.
local function describe(part: BasePart): BoatTypes.WaterPlane
	local size = part.Size
	return {
		TopY = part.Position.Y + size.Y * 0.5,
		Inverse = part.CFrame:Inverse(),
		HalfX = size.X * 0.5,
		HalfZ = size.Z * 0.5,
	}
end

local function rebuild(): ()
	local next: { BoatTypes.WaterPlane } = {}
	for _, instance in CollectionService:GetTagged(BoatConstants.Tags.Water) do
		if instance:IsA("BasePart") then
			table.insert(next, describe(instance :: BasePart))
		end
	end
	-- Swapped wholesale rather than mutated in place, so a boat's tick can never read a half-rebuilt
	-- list. Cheap: this runs on a builder's tag edit, not on a clock.
	planes = next
end

-- Starts watching. Idempotent -- a second call is a no-op rather than a second set of connections,
-- which matters because this is reached from a System's Init and Systems get re-Init'd in the test
-- harness.
function BoatWater.Start(): ()
	if trove then
		return
	end

	local scope = Trove.New()
	trove = scope
	scope:Connect(CollectionService:GetInstanceAddedSignal(BoatConstants.Tags.Water), rebuild)
	scope:Connect(CollectionService:GetInstanceRemovedSignal(BoatConstants.Tags.Water), rebuild)
	rebuild()
end

function BoatWater.Stop(): ()
	local scope = trove
	if not scope then
		return
	end
	trove = nil
	scope:Clean()
	planes = {}
	warnedAboutEmptyWorld = false
end

-- How many planes are currently known. Read by BoatSystem's registration to decide whether to warn --
-- exposed as a count rather than as the list itself so no caller outside this file can start holding a
-- reference to a table that gets swapped out from under it.
function BoatWater.PlaneCount(): number
	return #planes
end

-- Warns, at most once for the life of the process, that this world has no water in it. Called from a
-- boat's registration rather than from Start, because at Start time the map may legitimately not have
-- streamed or been built yet, whereas a boat being registered into an empty sea is a real mistake
-- happening right now.
function BoatWater.WarnIfWorldHasNoWater(model: Model): ()
	if warnedAboutEmptyWorld or #planes > 0 then
		return
	end
	warnedAboutEmptyWorld = true
	logger:warn("No parts are tagged as water, so every boat in this place will read as beached", {
		tag = BoatConstants.Tags.Water,
		firstBoat = model:GetFullName(),
	})
end

-- What the water is doing under `position` right now. The one function the sailing tick calls.
--
-- Reads Workspace:GetServerTimeNow() rather than taking a clock, unlike everything on the pure side of
-- this pair. Deliberate: the swell's whole contract is that the server and every client evaluate it
-- against the SAME clock (see Shared/Boat/BoatWaterMath.lua's header), and letting each caller supply
-- its own is exactly how one of them ends up passing os.clock() and producing a sea that disagrees with
-- everybody else's.
function BoatWater.SampleAt(position: Vector3): BoatTypes.WaterSample
	return BoatWaterMath.Sample(planes, position, Workspace:GetServerTimeNow())
end

-- The swell's two world slopes under `position`, for the presentation tilt. Separate from SampleAt
-- because the tick needs the height BEFORE it integrates and the slopes AFTER, at the position the
-- integration actually reached -- folding them into one call would mean tilting the hull to match water
-- it was standing on a frame ago.
function BoatWater.SlopesAt(position: Vector3): (number, number)
	local _, slopeX, slopeZ = BoatWaterMath.Swell(position.X, position.Z, Workspace:GetServerTimeNow())
	return slopeX, slopeZ
end

return BoatWater
