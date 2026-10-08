--!strict
--[[
	GatheringConstants.lua

	Owns: the authoring contract and tuning for world resource nodes -- coal deposits and water sources
	-- that feed the Blimp Fuel System's carried coal/water (items "Coal"/"Water" in the player's inventory,
	Server/Systems/InventorySystem.lua). One config
	table per resource, read entirely by Server/Systems/ResourceGatheringSystem.lua, which is
	deliberately one System over both tags rather than two near-identical Systems -- see that module's
	own header for why.

	THE AUTHORING CONTRACT, in full: tag a BasePart "CoalDeposit" for a mineable coal vein, or
	"WaterSource" for a fillable water source (a riverbank, a well, a fountain -- any BasePart a
	builder places). Nothing else is required -- no companion Attachment, no per-model Attribute
	override the way Shared/Blimp/BlimpConstants.lua's stations have, because a gathering node has no
	orientation or arm pose to get right, only a position and which resource it grants.

	Also owns the RemoteNames.CarriedFuelUpdated name -- the server -> owning-player push that tells a
	tester's client what they're actually carrying (see that field's own comment).

	Does not own: how the tags are resolved or the prompts wired (ResourceGatheringSystem.lua), how
	much a player may carry at once (Shared/Blimp/BlimpConstants.Carry -- read there rather than
	duplicated here, since the cap exists to serve the blimp tank a carried resource is eventually
	deposited into, and the two must be retuned together), or what a deposit into an actual blimp does
	with a carried resource (Server/Systems/BlimpSystem.depositFuel).
]]

local GatheringConstants = {}

GatheringConstants.Tags = {
	CoalDeposit = "CoalDeposit",
	WaterSource = "WaterSource",
}

export type ResourceKind = "Coal" | "Water"

export type ResourceConfig = {
	Tag: string,
	-- How much a single successful gather grants, before ResourceGatheringSystem clamps it against the
	-- player's remaining room under BlimpConstants.Carry's own cap.
	Yield: number,
	-- ProximityPrompt.HoldDuration, in seconds -- long enough to read as "mining"/"filling" rather than
	-- an instant tap, short enough that a real gathering trip isn't spent standing still.
	HoldDuration: number,
	-- Seconds a node is disabled after a successful gather, or nil for a node that never depletes at
	-- all. Water sources never deplete -- a river does not run dry. Coal deposits DO: finite ore, and
	-- the respawn window is what turns "mine it once" into "come back later," which is the loop this
	-- feature exists to create in the first place.
	RespawnSeconds: number?,
	ActionText: string,
	ObjectText: string,
	MaxActivationDistance: number,
}

local resources: { [ResourceKind]: ResourceConfig } = {
	Coal = {
		Tag = GatheringConstants.Tags.CoalDeposit,
		Yield = 50,
		HoldDuration = 2.5,
		RespawnSeconds = 90,
		ActionText = "Mine Coal",
		ObjectText = "Coal Deposit",
		MaxActivationDistance = 10,
	},
	Water = {
		Tag = GatheringConstants.Tags.WaterSource,
		Yield = 100,
		HoldDuration = 1.5,
		RespawnSeconds = nil,
		ActionText = "Collect Water",
		ObjectText = "Water Source",
		MaxActivationDistance = 10,
	},
}

GatheringConstants.Resources = resources

-- Per-resource-kind, not per-node -- a player hopping between three coal deposits to route around a
-- single node's own respawn timer still spends the same overall budget. Generous relative to
-- HoldDuration (a gather can never complete faster than the hold anyway) -- this exists purely as the
-- same "every server-mutating trigger gets a bucket" defense-in-depth every other prompt/remote
-- handler in this codebase already carries.
GatheringConstants.MaxGathersPerSecond = 4

-- Server -> the OWNING player only. Fired by Server/Systems/ResourceGatheringSystem.
-- PushCarriedFuelUpdate -- on a successful gather, on profile load (so a rejoining player sees their
-- real carried total immediately, not just after their next gather), and by Server/Systems/
-- BlimpSystem.depositFuel (the one narrow seam that System calls back into this one for, the same
-- "call the owning System's own public function" shape DamageSystem.DrainGuard already uses for
-- DefenseSystem's guard pool). Carries CarriedFuelUpdatePayload below.
GatheringConstants.RemoteNames = {
	CarriedFuelUpdated = "BlimpFuel_CarriedUpdated",
}

export type CarriedFuelUpdatePayload = {
	Coal: number,
	Water: number,
}

return GatheringConstants
