--!strict
--[[
	VehicleConstants.lua

	Owns: the whole authoring contract for the vehicle registry -- where a builder puts a vehicle, what
	they may tag, what Attributes they may set on it, and every tunable VehicleManager reads. This file
	is written to be read BY A BUILDER, top to bottom, as the answer to "how do I add a vehicle" -- the
	same job BlimpConstants.lua does for one hull's tuning, scoped up to the catalog.

	=== ADDING A VEHICLE, IN FULL ===

	  ServerStorage/
	    Vehicles/              <- the registry root (Registry.FolderName)
	      Blimp/               <- one folder per vehicle; ITS NAME IS THE VEHICLE ID
	        Model              <- the Model that gets cloned on every spawn

	That is the whole requirement. `Vehicles/Blimp` may also just BE the Model rather than a folder
	containing one -- see VehicleCatalog.ReadRegistry, which accepts both -- but the folder form is
	what the existing content uses and is the one to copy, because a folder gives you somewhere to
	keep a vehicle's own reference art and notes next to the thing itself.

	Nothing here has to be tagged. A spawned vehicle is tagged Tags.Vehicle by VehicleManager itself,
	and every tag the builder put ON the template (a Blimp's own Blimp/BlimpHelm/BlimpFurnace tags)
	survives :Clone() for free -- which is the entire integration between this system and BlimpSystem.
	VehicleManager clones and parents; BlimpSystem's existing
	CollectionService:GetInstanceAddedSignal("Blimp") does the rest, and neither module knows the
	other's name.

	=== THE REGISTRY BELONGS IN SERVERSTORAGE ===

	Registry.SearchOrder below resolves ServerStorage first, then ReplicatedStorage, then Workspace,
	and VehicleManager warns on either of the last two. That is a migration aid, not three supported
	options:

	  * ReplicatedStorage means every client downloads every vehicle mesh at join whether or not one
	    is ever spawned, and hands a client a live handle to the thing spawns are cloned from.
	  * WORKSPACE IS ACTIVELY HARMFUL and is why the fallback exists at all. A template in Workspace
	    is a real, replicated, physically-simulated model -- and if it carries a builder's gameplay
	    tags (which it must, per the paragraph above), then every System that discovers its content by
	    tag has been registering the TEMPLATE as a live instance since the moment it was placed. A
	    Blimp template sitting in Workspace is a flyable blimp with a working helm.

	Moving the folder to ServerStorage is a drag in the Explorer and needs no code change.
]]

local VehicleConstants = {}

VehicleConstants.Registry = {
	-- The folder name looked for inside each service in SearchOrder below.
	FolderName = "Vehicles",
	-- Resolved in this order, first hit wins. See this file's header on why the last two are a
	-- migration aid rather than supported homes.
	SearchOrder = { "ServerStorage", "ReplicatedStorage", "Workspace" },
	-- The one service a healthy install resolves to; VehicleManager warns when the winner is not this.
	PreferredService = "ServerStorage",
	-- When a vehicle folder holds more than one Model, the one with this name wins outright rather
	-- than the entry being rejected as ambiguous -- it is what the existing content is called, and a
	-- builder keeping a Model_Old beside the live one is a normal thing to do, not a build error.
	PreferredTemplateName = "Model",
	-- Where clones are parented. A folder rather than Workspace directly, so "what did this system
	-- put in the world" is one collapsed row in the Explorer and DespawnAll has one place to look.
	SpawnFolderName = "SpawnedVehicles",
}

VehicleConstants.Tags = {
	-- Applied BY VehicleManager to every clone it parents (never authored on a template). This is what
	-- makes a spawned vehicle findable as one -- including after a script reload, which is why the live
	-- registry can be rebuilt from the world rather than only from memory.
	Vehicle = "Vehicle",
	-- Authored by a builder on any BasePart in the world: a berth, i.e. a named pad a vehicle can be
	-- spawned onto instead of in front of whoever asked. The part's own top surface is the deck the
	-- hull is seated on, and its CFrame's LookVector is the heading the hull is pointed down.
	Berth = "VehicleBerth",
}

-- Every Attribute a builder may set. Two groups, and the split matters: TEMPLATE attributes are
-- authored and read once at scan time, RUNTIME attributes are written by VehicleManager onto each
-- clone and are the only thing another System should ever read to answer "what is this Model".
VehicleConstants.Attributes = {
	-- === On the template Model (authored) ===
	-- Overrides the folder name in every piece of UI. The folder name stays the ID regardless -- a
	-- display name is a label a designer retitles freely, and letting it be the key would mean
	-- renaming it invalidated every berth that named it.
	DisplayName = "VehicleDisplayName",
	-- Free-form grouping label. Nothing branches on it -- see VehicleTypes.VehicleDefinition.Kind.
	Kind = "VehicleKind",
	-- Per-vehicle live cap. Overrides Limits.MaxLivePerVehicle's default; still bounded by
	-- Limits.MaxLiveTotal, which no Attribute can raise.
	MaxLive = "VehicleMaxLive",
	-- Set false for a vehicle that should outlive whoever spawned it (a scheduled ferry, a set piece).
	-- Defaults true: the overwhelmingly common case is somebody spawning one to test with.
	DespawnOnOwnerLeave = "VehicleDespawnOnOwnerLeave",

	-- === On a berth part (authored) ===
	-- The berth's name, as typed at a spawn call and shown in the Dev Menu. Falls back to the part's
	-- own Name.
	BerthName = "VehicleBerthName",
	-- Comma-separated vehicle IDs this berth accepts. Absent or empty means any.
	BerthAccepts = "VehicleBerthAccepts",

	-- === On the spawned clone (written by VehicleManager) ===
	-- The session-local handle -- see VehicleTypes.InstanceId.
	InstanceId = "VehicleInstanceId",
	-- The registry key this was cloned from, so a Model found in the world can be traced back to its
	-- template without a lookup table.
	VehicleId = "VehicleId",
	-- 0 for an unowned spawn.
	OwnerUserId = "VehicleOwnerUserId",
}

VehicleConstants.Limits = {
	-- Hard ceiling across every vehicle kind in one server. A spawn that would exceed it evicts the
	-- OLDEST live vehicle rather than being refused -- the same choice Constants.Debug.TrainingDummy.
	-- MaxActive already makes, and for the same reason: a dev tool that starts silently refusing is
	-- read as broken, where one that quietly recycles is read as working.
	MaxLiveTotal = 8,
	-- Default per-vehicle cap when a template sets no MaxLive Attribute.
	MaxLivePerVehicle = 3,
}

VehicleConstants.Spawn = {
	-- Clear air between the requester and the nearest point of the hull. Added to the hull's own
	-- horizontal radius, never used alone -- see VehiclePlacement.InFrontOf, and note that a 200-stud
	-- airship spawned at a fixed 6-stud offset would materialise around the person who asked for it.
	GapStuds = 12,
	-- How far the hull's underside is held above whatever the ground probe found. Not zero: a hull
	-- seated exactly on the deck is interpenetrating it by whatever the mesh's own collision hull
	-- rounds to, and the first physics step throws it.
	GroundClearanceStuds = 4,
	-- How far down to look for ground beneath a free spawn. A spawn over a canyon simply finds nothing
	-- and keeps the requester's own altitude, which is the honest answer.
	GroundProbeStuds = 512,
	-- A berth counts as taken while a live vehicle's pivot is within this of it. Generous, because the
	-- failure it prevents (two hulls spawned into each other, which the physics solver resolves by
	-- flinging both) is far worse than being told a free berth is busy.
	BerthClearRadiusStuds = 60,
}

VehicleConstants.Lifetime = {
	-- After an owner disconnects, how long their vehicle survives before being reclaimed. Long enough
	-- to cover a rejoin after a crash, short enough that a testing session does not silt up.
	OwnerLeaveGraceSeconds = 120,
	-- A vehicle with a player's root inside its own bounding radius is never reclaimed on an owner
	-- leave -- this is the margin added to that radius. Deliberately generous: an airship's bounding
	-- sphere already covers its deck, and the cost of being wrong is deleting the hull out from under
	-- somebody flying it.
	OccupancyMarginStuds = 8,
	-- How often the reclaim sweep runs. This is bookkeeping, not simulation -- a per-frame sweep of
	-- at most MaxLiveTotal entries would cost little, but it would also be the wrong signal to anyone
	-- reading this file about what kind of work it does.
	SweepIntervalSeconds = 5,
}

-- Every remote this system's owning System (Server/Systems/VehicleManager.lua) creates. All
-- RemoteFunctions and all admin-gated: there is no player-facing way to spawn a vehicle yet, and when
-- there is, it will be a different, narrower remote rather than these with the gate relaxed.
VehicleConstants.RemoteNames = {
	-- Client -> server. The whole tab's state in one round trip: catalog, live list, berths, where the
	-- registry resolved, and any rejected entries. ONE remote rather than four because every one of
	-- those changes whenever any of them does (a spawn changes the live list AND the catalog's
	-- LiveCount AND a berth's Occupied), so four remotes would only ever be called together and could
	-- disagree with each other in between.
	GetState = "Vehicle_GetState",
	-- Client -> server. (vehicleId, berthName?) -- a berth name, never a position: a client that could
	-- name a CFrame could spawn a hull inside somebody's head from across the map.
	Spawn = "Vehicle_Spawn",
	-- Client -> server. (instanceId) -- see VehicleTypes.InstanceId on why this is not a Model.
	Despawn = "Vehicle_Despawn",
	DespawnAll = "Vehicle_DespawnAll",
	-- Client -> server. Re-scans the registry root without a server restart, so a builder can add a
	-- model in Studio and see it in the tab. Does not touch anything already spawned -- a live vehicle
	-- keeps the definition it was cloned from.
	ReloadRegistry = "Vehicle_ReloadRegistry",
}

return VehicleConstants
