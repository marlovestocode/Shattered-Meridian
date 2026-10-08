--!strict
--[[
	CandidateGatherer.lua

	Owns: the BROADPHASE. Given a region a hitbox or a shot could touch, it produces the small set of parts
	worth testing exactly. Nothing else in the engine decides which parts are candidates.

	A HURTBOX INDEX, NOT A WORKSPACE QUERY (2026-10-08). This file used to ask Workspace for every part of
	every registered model overlapping the volume (GetPartBoundsInBox with an Include filter). Three things
	were wrong with that, and all three go away when the engine indexes the bodies it already knows:

	  * IT WAS MOSTLY REDUNDANT WORK. The narrow phase (HitboxGeometry) only ever tests a candidate part's
	    CENTRE. All the spatial query was buying was "whose parts are near here" -- which, for a registry of
	    a few dozen fighters, a distance check over their roots answers without touching the engine, without
	    the result array every query allocated, and without an IsA per returned part.
	  * IT GATHERED EQUIPMENT AS BODY. An Include filter of whole character Models returns accessory Handles
	    and the held weapon's parts (WeaponVisualSystem parents the weapon model under the character), and
	    each resolved to its owner -- so striking someone's sword was a hit on them, and a hat on a tall
	    character reached further than their head.
	  * EQUIPMENT CROWDED THE CAP. Those extra parts counted against MaxCandidatesPerSample; three or four
	    armed, accessorised fighters inside one generous hitbox could saturate it, and a saturated query
	    drops candidates silently -- real hits, in exactly the brawl where they matter most.

	THE HURTBOX of a body is its own BaseParts: the root, plus every BasePart that is a DIRECT child of the
	character Model (the limbs of an R6 or R15 rig). Accessories and tools are children of their own
	containers, never direct BaseParts, so they are excluded by construction rather than by a name list.
	The set is kept live from the model's ChildAdded/ChildRemoved, because a character's limbs can replicate
	after its root does -- registration happens on the root.

	A BODY IS GATHERED IN TWO STEPS. A coarse reject on its root against the query sphere padded by the body's
	REACH (how far its farthest part sits from the root, re-measured at most every REACH_REFRESH_SECONDS,
	plus HurtboxReachPadStuds for a limb mid-swing since then); then each of its parts whose own bound
	touches the sphere. The result is the same over-reporting superset the bounds query gave, minus the
	equipment, which the narrow phase then makes exact. The same cap still bounds the worst case.

	Does not own: whether a returned part belongs to a legal target (HitboxEngine resolves ownership and
	skips the attacker's own body), or whether it is genuinely inside the volume -- the broadphase over-
	reports by design, and HitboxGeometry's narrow phase is what makes the answer exact.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Trove = require(ReplicatedStorage.Shared.Trove)

type ShapeKind = HitboxTypes.ShapeKind
type Dimensions = HitboxTypes.Dimensions

-- What the engine hands over per registered body. HitboxEngine's own Combatant records satisfy it.
export type Body = { Model: Model, RootPart: BasePart }

type Entry = {
	Model: Model,
	Root: BasePart,
	Parts: { BasePart },
	-- Farthest any part's bound has been measured from the root, and when.
	Reach: number,
	ReachMeasuredAt: number,
	Trove: Trove.TroveInstance,
}

local CandidateGatherer = {}

-- How stale a body's measured reach may get before a gather re-measures it. A body's shape barely changes
-- frame to frame; HurtboxReachPadStuds covers what changes inside this window.
local REACH_REFRESH_SECONDS = 0.5

local entries: { Entry } = {}
local entryByModel: { [Model]: Entry } = {}

local function isHurtboxPart(model: Model, child: Instance): boolean
	return child.Parent == model and child:IsA("BasePart")
end

local function rebuildParts(entry: Entry): ()
	table.clear(entry.Parts)
	table.insert(entry.Parts, entry.Root)
	for _, child in entry.Model:GetChildren() do
		if child ~= entry.Root and isHurtboxPart(entry.Model, child) then
			table.insert(entry.Parts, child :: BasePart)
		end
	end
	entry.ReachMeasuredAt = -math.huge
end

local function measureReach(entry: Entry, now: number): number
	if now - entry.ReachMeasuredAt < REACH_REFRESH_SECONDS then
		return entry.Reach
	end
	local rootPosition = entry.Root.Position
	local reach = 0
	for _, part in entry.Parts do
		local distance = (part.Position - rootPosition).Magnitude + part.Size.Magnitude / 2
		if distance > reach then
			reach = distance
		end
	end
	entry.Reach = reach + HitboxEngineConstants.HurtboxReachPadStuds
	entry.ReachMeasuredAt = now
	return entry.Reach
end

local function track(body: Body): Entry
	local entry: Entry = {
		Model = body.Model,
		Root = body.RootPart,
		Parts = {},
		Reach = 0,
		ReachMeasuredAt = -math.huge,
		Trove = Trove.New(),
	}
	rebuildParts(entry)
	-- A limb arriving or leaving rebuilds the list wholesale -- rare (spawn, a limb lost), and a list rebuilt
	-- from the model cannot drift the way an incrementally patched one can.
	entry.Trove:Connect(body.Model.ChildAdded, function(child: Instance)
		if child:IsA("BasePart") then
			rebuildParts(entry)
		end
	end)
	entry.Trove:Connect(body.Model.ChildRemoved, function(child: Instance)
		if child:IsA("BasePart") then
			rebuildParts(entry)
		end
	end)
	entryByModel[body.Model] = entry
	return entry
end

-- Re-syncs the index with the engine's registry. Called by HitboxEngine on every registration change
-- (a spawn or a death, never per frame); bodies already indexed keep their entry and its connections.
function CandidateGatherer.SetBodies(bodies: { Body }): ()
	local keep: { [Model]: boolean } = {}
	table.clear(entries)
	for _, body in bodies do
		keep[body.Model] = true
		local entry = entryByModel[body.Model]
		if entry == nil or entry.Root ~= body.RootPart then
			if entry then
				entry.Trove:Clean()
			end
			entry = track(body)
		end
		table.insert(entries, entry :: Entry)
	end
	for model, entry in entryByModel do
		if not keep[model] then
			entry.Trove:Clean()
			entryByModel[model] = nil
		end
	end
end

-- Fills `out` with every hurtbox part whose bound touches the sphere and returns how many were written.
-- `out` is a caller-owned buffer, cleared and refilled: the call allocates nothing.
function CandidateGatherer.GatherSphere(centre: Vector3, radius: number, out: { BasePart }): number
	table.clear(out)
	local cap = HitboxEngineConstants.MaxCandidatesPerSample
	local now = os.clock()
	local count = 0
	radius = math.max(radius, 0)
	for _, entry in entries do
		local root = entry.Root
		if root.Parent == nil then
			continue
		end
		if (root.Position - centre).Magnitude > radius + measureReach(entry, now) then
			continue
		end
		for _, part in entry.Parts do
			if part.Parent == nil then
				continue
			end
			if (part.Position - centre).Magnitude <= radius + part.Size.Magnitude / 2 then
				count += 1
				out[count] = part
				if count >= cap then
					return count
				end
			end
		end
	end
	return count
end

-- The bound of a hitbox at one pose, as a sphere query: the shape's bounding box's circumsphere, widened
-- by the broadphase margin (so the swept test's interval is covered) and by `extraMarginStuds` for a swing
-- whose targets are also tested where they WERE (HitboxEngineConstants.LagCompensation). What a shot's
-- per-step capsule asks for (ProjectileSimulator.sweepBodies).
function CandidateGatherer.Gather(
	shape: ShapeKind,
	dimensions: Dimensions,
	worldPose: CFrame,
	out: { BasePart },
	extraMarginStuds: number?
): number
	local extra = if extraMarginStuds and extraMarginStuds > 0 then extraMarginStuds else 0
	local size, localCentre = HitboxGeometry.BoundingBox(shape, dimensions)
	local radius = size.Magnitude / 2 + HitboxEngineConstants.BroadphaseMarginStuds + extra
	return CandidateGatherer.GatherSphere(worldPose * localCentre, radius, out)
end

-- True when a gather filled its result budget, meaning candidates may have been dropped. Read by the engine
-- only for its debug logging -- there is no correct recovery at sample time.
function CandidateGatherer.WasSaturated(count: number): boolean
	return count >= HitboxEngineConstants.MaxCandidatesPerSample
end

-- Drops every indexed body and its connections. Spec-only, through HitboxEngine.Reset.
function CandidateGatherer.Reset(): ()
	for _, entry in entryByModel do
		entry.Trove:Clean()
	end
	table.clear(entryByModel)
	table.clear(entries)
end

return CandidateGatherer
