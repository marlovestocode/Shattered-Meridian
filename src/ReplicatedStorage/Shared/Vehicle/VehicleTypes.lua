--!strict
--[[
	VehicleTypes.lua

	Owns: every shape the vehicle registry crosses a boundary with -- the server's own view of a
	registered template (VehicleDefinition, which holds a real Model and therefore never leaves the
	server), and the four wire-safe snapshots the Dev Menu's Vehicles tab reads (VehicleCatalogEntry,
	VehicleBerthInfo, LiveVehicleInfo, and the three Result shapes).

	SPLIT FROM VehicleConstants.lua for the same reason BlimpTypes.lua is split from BlimpConstants:
	the constants file is the contract a BUILDER reads and has to stay readable as one. Same split,
	same reason.

	THE CATALOG ENTRY IS NOT THE DEFINITION, and that separation is load-bearing rather than
	cosmetic. A VehicleDefinition carries `Template: Model` -- a live Instance sitting in
	ServerStorage. Handing that across a RemoteFunction would either fail outright (an unreplicated
	Instance arrives as nil) or, worse, succeed for a template that happens to live in
	ReplicatedStorage and hand a client a direct handle to the thing every spawn is cloned from.
	VehicleCatalogEntry is the deliberately inert projection of it: strings and numbers only.

	Does not own: the tag/attribute NAMES a builder authors against (VehicleConstants.lua), reading a
	registry folder into definitions (VehicleCatalog.lua), or anything about how a spawned vehicle
	then BEHAVES -- a blimp's flight lives entirely in Shared/Blimp + Server/Blimp and this file has
	no vocabulary for it on purpose.
]]

local VehicleTypes = {}

-- The registry key for one vehicle -- the name of its folder under the registry root, e.g. "Blimp".
-- Stable across sessions because a builder chose it, unlike an InstanceId below.
export type VehicleId = string

-- One live spawned vehicle's server-local handle. Unique for the session and NOT stable across
-- servers or restarts: it exists so the Dev Menu can say "despawn THAT one" without sending an
-- Instance reference back to the server, which a client could substitute for any Model in the place.
export type InstanceId = string

-- SERVER ONLY -- see this file's header on why this never crosses a remote.
export type VehicleDefinition = {
	Id: VehicleId,
	DisplayName: string,
	-- Free-form grouping label off the template's own Attribute ("Airship", "Ground", ...), used for
	-- nothing but sorting and display. Deliberately not an enum: VehicleManager never branches on it,
	-- and the moment it did, this field would have become a behaviour switch that belongs in the
	-- owning System instead.
	Kind: string,
	-- What gets cloned. Never reparented, never mutated -- every spawn is a fresh :Clone().
	Template: Model,
	-- Cached at scan time from Template:GetBoundingBox(), because a spawn needs it to work out how
	-- far in front of the requester the hull has to start, and measuring a large model is not free.
	Size: Vector3,
	-- How many of THIS vehicle may be live at once before the oldest is evicted. Off the template's
	-- own Attribute, defaulted from VehicleConstants.
	MaxLive: number,
	-- Whether a spawn owned by a player should be reclaimed once that player leaves. Off the
	-- template's Attribute; defaults true, since the overwhelmingly common case is an admin spawning
	-- something to test with.
	DespawnOnOwnerLeave: boolean,
}

-- Why one entry under the registry root produced no definition. Surfaced rather than swallowed: a
-- builder who drops a folder in and sees nothing appear in the Dev Menu needs to be told which of
-- the three shapes they got wrong, not left to guess.
export type RegistryRejection = {
	Path: string,
	Reason: string,
}

-- The wire-safe projection of a VehicleDefinition -- see this file's header.
export type VehicleCatalogEntry = {
	Id: VehicleId,
	DisplayName: string,
	Kind: string,
	MaxLive: number,
	-- Longest horizontal dimension, rounded, purely so the tab can say "212 studs" next to a name and
	-- an admin knows what they are about to drop on their head.
	FootprintStuds: number,
	LiveCount: number,
}

-- One tagged berth (a spawn pad) as the Dev Menu sees it.
export type VehicleBerthInfo = {
	Name: string,
	-- Empty means "any vehicle" -- see VehicleConstants.Attributes.BerthAccepts.
	Accepts: { VehicleId },
	Occupied: boolean,
}

-- One live spawned vehicle as the Dev Menu sees it. Position is a Vector3 rather than a formatted
-- string because the client formats it (docs/ui-ux-philosophy.md's "already-computed value in,
-- presentation out" rule applies to the SCREEN module, not to the remote).
export type LiveVehicleInfo = {
	InstanceId: InstanceId,
	VehicleId: VehicleId,
	DisplayName: string,
	-- 0 when nothing owns it (spawned at a berth by the server rather than by a person).
	OwnerUserId: number,
	OwnerName: string,
	Position: Vector3,
	AgeSeconds: number,
	-- True while at least one player's root is inside the hull's own bounding radius -- what keeps an
	-- owner-left reclaim from dropping a vehicle somebody else is still standing on.
	Occupied: boolean,
	-- The berth it was spawned at, or nil for a free spawn.
	BerthName: string?,
}

-- Same Success/Reason pair every admin-gated Result in this codebase already uses (Types.DevMenu*
-- Result), so the Dev Menu's existing describe/setStatus plumbing needs no new shape.
export type VehicleActionResult = {
	Success: boolean,
	Reason: string?,
}

export type VehicleSpawnResult = {
	Success: boolean,
	Reason: string?,
	InstanceId: InstanceId?,
}

export type VehicleStateResult = {
	Success: boolean,
	Reason: string?,
	Catalog: { VehicleCatalogEntry }?,
	Live: { LiveVehicleInfo }?,
	Berths: { VehicleBerthInfo }?,
	-- Where the registry actually resolved ("ServerStorage.Vehicles"), plus any entries that were
	-- rejected -- both shown in the tab so a builder never has to open the server log to find out why
	-- their model is missing.
	RegistryPath: string?,
	Rejections: { RegistryRejection }?,
}

return VehicleTypes
