--!strict
--[[
	ParkourTagging.lua

	Owns: resolving a piece of world geometry into the set of parkour behaviors it permits --
	"can this be vaulted / wall-run / mantled / grabbed, and does it modify slide friction or
	wall-jump bounce?" -- from CollectionService tags and Instance Attributes, with no hardcoded part
	names anywhere (the design's explicit requirement: "using tags, attributes, collision groups, or
	another scalable system rather than hardcoding specific object names").

	TWO authoring mechanisms, both supported, because they suit genuinely different workflows and
	forcing one would make the other painful:
	  * CollectionService tags -- for bulk authoring (a plugin tagging every railing in a region at
	    once) and for anything driven by a build pipeline.
	  * Boolean/number Attributes of the same name -- for one-off tweaks straight from the
	    Properties panel while a designer is standing in front of the offending object in Studio.
	A tag and an attribute of the same name mean exactly the same thing; presence of either is
	enough. Nothing has to be set up for the system to work -- an untagged world is fully playable,
	and every geometric check runs normally. Tags exist to override the geometry, in both directions.

	PRECEDENCE, resolved here once so no caller has to reason about it:
	  1. A blanket ignore (ParkourIgnore) beats everything -- the object is invisible to parkour.
	  2. A specific deny (ParkourNoVault, ...) beats a force-allow for that same behavior. A designer
	     who has said "never here" outranks one who said "always here"; the alternative (allow wins)
	     makes an accidental blanket allow-tag impossible to carve exceptions out of.
	  3. A force-allow (ParkourVaultable, ...) overrides the geometric checks the classifier would
	     otherwise apply -- this is how a decorative railing thinner than the classifier's minimums,
	     or a slightly-tilted surface, becomes usable without retuning global thresholds.
	  4. Nothing set -> allowed, and the geometry decides.

	ANCESTOR INHERITANCE: tags/attributes are looked up on the part itself and then walked up its
	ancestry (bounded by MAX_ANCESTOR_DEPTH), so tagging one Model marks every part inside it. Without
	this, marking a building non-wall-runnable would mean tagging hundreds of parts individually,
	which is exactly the kind of authoring burden that gets skipped and then reported as a bug.

	Does not own: the geometric checks themselves (Shared/Parkour/ObstacleClassifier.lua and the
	State modules own those -- this only supplies the allow/deny booleans they read), or any
	raycasting (Client/Parkour/EnvironmentProbe.lua).
]]

local CollectionService = game:GetService("CollectionService")

local ParkourConstants = require(script.Parent.ParkourConstants)

local ParkourTagging = {}

local TAGS = ParkourConstants.Tags

-- How far up the ancestry chain to look for a tag/attribute before giving up. Deep enough for the
-- realistic nesting (Part -> Model -> Model -> Folder -> Workspace) and shallow enough that the walk
-- is never a meaningful cost in a per-frame probe. A tag placed above this depth simply doesn't
-- apply, which is a far better failure than an unbounded walk to the DataModel on every raycast hit.
local MAX_ANCESTOR_DEPTH = 6

-- Resolved permissions for one instance. Reused via the cache below rather than reallocated -- see
-- the cache's own comment.
export type SurfacePermissions = {
	Ignored: boolean,
	Vaultable: boolean,
	WallRunnable: boolean,
	Mantleable: boolean,
	LedgeGrabbable: boolean,
	-- True when a designer explicitly FORCED the behavior on, so the caller knows it may skip its
	-- own geometric refusal rather than merely being permitted to run the check.
	ForcedVault: boolean,
	ForcedWallRun: boolean,
	ForcedMantle: boolean,
	ForcedLedge: boolean,
	FrictionScale: number,
	BounceScale: number,
}

-- Neutral permissions for "no instance" (a probe that hit nothing, or hit terrain with no
-- Instance). Returned by reference and never mutated -- callers read fields immediately, same
-- contract as ObstacleClassifier's shared results.
local DEFAULT_PERMISSIONS: SurfacePermissions = {
	Ignored = false,
	Vaultable = true,
	WallRunnable = true,
	Mantleable = true,
	LedgeGrabbable = true,
	ForcedVault = false,
	ForcedWallRun = false,
	ForcedMantle = false,
	ForcedLedge = false,
	FrictionScale = 1,
	BounceScale = 1,
}

-- Weak-keyed memo: a probe can hit the same wall on every frame of a two-second wall-run, and
-- re-walking six ancestors through six tag lookups each time would be ~200 CollectionService calls
-- per second for an answer that essentially never changes. Weak keys (__mode = "k") mean a
-- destroyed/streamed-out part's entry is collected automatically -- no invalidation bookkeeping, no
-- leak.
--
-- Entries carry their own expiry rather than living forever, so retagging an object live in Studio
-- takes effect within CACHE_TTL_SECONDS instead of requiring a rejoin. That staleness is acceptable
-- for authoring (a designer tweaking tags is not frame-sensitive) and is the reason this is a TTL
-- cache rather than a signal-invalidated one: subscribing to GetInstanceAddedSignal/RemovedSignal
-- for eight tags, and to AttributeChanged on every part ever probed, would cost more than it saves.
local CACHE_TTL_SECONDS = 5
type CacheEntry = { Permissions: SurfacePermissions, ExpiresAt: number }
local cache: { [Instance]: CacheEntry } = setmetatable({}, { __mode = "k" }) :: any

-- True if `instance` or any ancestor within MAX_ANCESTOR_DEPTH carries `name` as a tag or as a
-- truthy Attribute. The two mechanisms are checked together at each level rather than in two
-- separate passes, so a tag on the part and an attribute on its parent Model behave identically to
-- both being on the part.
local function hasMarker(instance: Instance, name: string): boolean
	local current: Instance? = instance
	local depth = 0
	while current and depth < MAX_ANCESTOR_DEPTH do
		if CollectionService:HasTag(current, name) then
			return true
		end
		if current:GetAttribute(name) == true then
			return true
		end
		current = current.Parent
		depth += 1
	end
	return false
end

-- First finite, positive number found for `name` on the instance or an ancestor, or `fallback`.
-- Numeric counterpart of hasMarker for the two scalar modifiers (friction, bounce). Non-positive
-- and non-finite values are skipped rather than honored -- a friction scale of 0 or NaN would
-- produce a slide that never decays or a NaN velocity, and an authoring typo must not be able to
-- do that.
local function findScale(instance: Instance, name: string, fallback: number): number
	local current: Instance? = instance
	local depth = 0
	while current and depth < MAX_ANCESTOR_DEPTH do
		local value = current:GetAttribute(name)
		if typeof(value) == "number" then
			local number = value :: number
			if number == number and number > 0 and number ~= math.huge then
				return number
			end
		end
		current = current.Parent
		depth += 1
	end
	return fallback
end

local function resolve(instance: Instance): SurfacePermissions
	if hasMarker(instance, TAGS.NoParkour) then
		return {
			Ignored = true,
			Vaultable = false,
			WallRunnable = false,
			Mantleable = false,
			LedgeGrabbable = false,
			ForcedVault = false,
			ForcedWallRun = false,
			ForcedMantle = false,
			ForcedLedge = false,
			FrictionScale = 1,
			BounceScale = 1,
		}
	end

	local deniedVault = hasMarker(instance, TAGS.NoVault)
	local deniedWallRun = hasMarker(instance, TAGS.NoWallRun)
	local deniedMantle = hasMarker(instance, TAGS.NoMantle)
	local deniedLedge = hasMarker(instance, TAGS.NoLedge)

	-- Force-allow is only consulted when the matching deny is absent -- precedence rule 2 in the
	-- file header, applied here once rather than at four call sites.
	local forcedVault = not deniedVault and hasMarker(instance, TAGS.ForceVaultable)
	local forcedWallRun = not deniedWallRun and hasMarker(instance, TAGS.ForceWallRunnable)
	local forcedMantle = not deniedMantle and hasMarker(instance, TAGS.ForceMantleable)
	local forcedLedge = not deniedLedge and hasMarker(instance, TAGS.ForceLedge)

	return {
		Ignored = false,
		Vaultable = not deniedVault,
		WallRunnable = not deniedWallRun,
		Mantleable = not deniedMantle,
		LedgeGrabbable = not deniedLedge,
		ForcedVault = forcedVault,
		ForcedWallRun = forcedWallRun,
		ForcedMantle = forcedMantle,
		ForcedLedge = forcedLedge,
		FrictionScale = findScale(instance, TAGS.SurfaceFrictionAttribute, 1),
		BounceScale = findScale(instance, TAGS.WallBounceAttribute, 1),
	}
end

-- The one entry point. Safe to call with nil (a probe that hit terrain, or nothing at all) --
-- returns the permissive default rather than erroring, so no caller needs its own nil branch.
--
-- CALLER CONTRACT: the returned table is cached and shared. Read it immediately; never retain or
-- mutate it.
function ParkourTagging.GetPermissions(instance: Instance?, now: number): SurfacePermissions
	if not instance then
		return DEFAULT_PERMISSIONS
	end
	local entry = cache[instance]
	if entry and now < entry.ExpiresAt then
		return entry.Permissions
	end
	local permissions = resolve(instance)
	cache[instance] = { Permissions = permissions, ExpiresAt = now + CACHE_TTL_SECONDS }
	return permissions
end

-- Drops every cached entry. Not needed in normal operation (the TTL and weak keys handle both
-- staleness and lifetime), but a Studio session that retags heavily can call this to see changes
-- immediately instead of waiting out the TTL -- Client/Parkour/ParkourDebug.lua exposes it on the
-- debug overlay's own toggle for exactly that.
function ParkourTagging.ClearCache(): ()
	cache = setmetatable({}, { __mode = "k" }) :: any
end

return ParkourTagging
