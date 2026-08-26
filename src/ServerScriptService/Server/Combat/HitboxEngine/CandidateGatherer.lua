--!strict
--[[
	CandidateGatherer.lua

	Owns: the BROADPHASE. Given a hitbox's shape, live dimensions and live world pose, it produces the
	small set of parts worth testing exactly. Nothing else in the engine talks to Workspace.

	AN INCLUDE FILTER, NOT AN EXCLUDE FILTER, which is the whole design of this file.

	The obvious way to gather hitbox candidates -- the way the deleted HitboxResolver did it -- is an
	Exclude filter listing the attacker, and then discarding everything that comes back which isn't a
	character. That query asks the engine for EVERY part whose bounds overlap the volume: the floor,
	the building the fight is happening inside, every prop, every piece of debris. In a dense scene a
	generous hitbox can pull back hundreds of parts, and the cost lands on the busiest possible frame
	-- someone is mid-swing, in a crowd, in the most detailed part of the map.

	Restricting FilterDescendantsInstances to the registered combatant models and setting FilterType to
	Include inverts that. The engine can only ever hit a registered combatant anyway -- that is what
	registration MEANS -- so the terrain and the scenery are not candidates that need discarding, they
	are candidates that were never gathered. The query's cost then scales with how many fighters are
	nearby rather than with how detailed the level is, which is the only one of those two numbers the
	engine has any business paying for.

	It is also the structural fix for the bug class this project has hit before, where a probe treated
	other players' bodies as terrain because its filter only ever named the local character. An Include
	list of exactly the registered models cannot make that mistake in either direction: an unregistered
	instance is not a candidate, and a registered one cannot be missed.

	RespectCanCollide is deliberately LEFT OFF, unlike ObjectStunResolver's probes. That flag is right
	when the question is "would this physically stop a flying body" -- a banner should not. Here the
	query is already restricted to fighters' bodies, so it buys no filtering worth having, and it
	carries a real hazard: a Humanoid manages HumanoidRootPart's collision state itself, so a
	CanCollide-respecting query can silently stop returning the one part most reliably at a target's
	centre. A hitbox that intermittently ignores torsos would be a miserable bug to track down, and
	nothing here needs the flag to avoid it.

	Does not own: whether a returned part belongs to a legal target (HitboxEngine resolves ownership
	and skips the attacker's own body), or whether it is genuinely inside the volume -- the broadphase
	answers with bounding boxes and is expected to over-report. HitboxGeometry's narrow phase is what
	makes the answer exact.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

type ShapeKind = HitboxTypes.ShapeKind
type Dimensions = HitboxTypes.Dimensions

local CandidateGatherer = {}

-- The box broadphase grows its bounds by the margin on BOTH sides of every axis, so the expansion is
-- a constant Vector3 -- not something to rebuild per sample. `Vector3.one * (margin * 2)` was
-- evaluated inside the gather call, which runs once per active hitbox per frame: a multiply and a
-- Vector3 allocation for a value that is fixed at require time.
local BROADPHASE_MARGIN_EXPANSION = Vector3.one * (HitboxEngineConstants.BroadphaseMarginStuds * 2)

-- One shared OverlapParams for every query the engine makes. Rebuilt only when the set of registered
-- combatants changes -- which is a spawn or a death, not something that happens per frame -- so the
-- sampling loop never allocates one. An empty include list correctly matches nothing, which is the
-- right answer before anyone has registered.
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
overlapParams.FilterDescendantsInstances = {}
overlapParams.RespectCanCollide = false
-- A ceiling on one query's result set, so an implausible pile-up degrades this hitbox rather than the
-- frame. Reaching it is not silently ignored: the engine logs it when debugging is on.
overlapParams.MaxParts = HitboxEngineConstants.MaxCandidatesPerSample

-- Replaces the include list wholesale. Called by HitboxEngine on every registration change; there is
-- no incremental add/remove because the list is small, the churn is rare, and a filter rebuilt from
-- the authoritative registry cannot drift out of sync with it the way an incrementally-patched one can.
function CandidateGatherer.SetRegisteredModels(models: { Model }): ()
	overlapParams.FilterDescendantsInstances = models
end

-- Fills `out` with the parts whose bounds overlap the hitbox's broadphase volume and returns how many
-- were written. `out` is a caller-owned buffer reused across samples -- the engine keeps exactly one
-- and passes it every time, so a sample costs no allocation beyond whatever the Roblox API itself
-- returns.
--
-- `worldPose` is the hitbox's live pose, already composed from the attachment part's current CFrame
-- and the definition's Offset. It is passed in rather than derived here because resolving an
-- attachment is a question about a combatant, and this module has never heard of one.
function CandidateGatherer.Gather(
	shape: ShapeKind,
	dimensions: Dimensions,
	worldPose: CFrame,
	out: { BasePart }
): number
	table.clear(out)

	-- The margin widens the query so it also covers the region the volume swept since the previous
	-- sample. A candidate that was only inside the hitbox at some midpoint of that interval still has
	-- to be GATHERED here to be swept-tested at all -- without the margin the narrow phase's continuity
	-- fix would be handed a candidate list that had already lost the contact.
	local margin = HitboxEngineConstants.BroadphaseMarginStuds

	local found: { Instance }
	if shape == "Sphere" then
		found = Workspace:GetPartBoundsInRadius(worldPose.Position, dimensions.Radius + margin, overlapParams)
	else
		local size, localCentre = HitboxGeometry.BoundingBox(shape, dimensions)
		found = Workspace:GetPartBoundsInBox(worldPose * localCentre, size + BROADPHASE_MARGIN_EXPANSION, overlapParams)
	end

	local count = 0
	for _, instance in ipairs(found) do
		if instance:IsA("BasePart") then
			count += 1
			out[count] = instance
		end
	end
	return count
end

-- True when the last Gather saturated its result budget, meaning the broadphase may have dropped
-- candidates. Read by the engine only for its debug logging: there is no correct recovery from it at
-- sample time (re-querying without a cap is exactly the cost the cap exists to avoid), so it is
-- reported rather than handled.
function CandidateGatherer.WasSaturated(count: number): boolean
	return count >= HitboxEngineConstants.MaxCandidatesPerSample
end

return CandidateGatherer
