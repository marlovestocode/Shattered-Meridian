--!strict
--[[
	PoseHistory.lua

	Owns: where one combatant's body WAS over the last fraction of a second -- a fixed ring of (time, root
	position) samples, and the interpolated position at any time inside it. What lag-compensated hits read
	(HitboxEngine, HitboxEngineConstants.LagCompensation): a swing is tested against the target where the
	attacker saw it, which is this history rewound by the attacker's one-way latency plus the replication
	buffer, rather than where it stands on the server this frame.

	A RING OF PLAIN NUMBERS AND VECTORS, NOT A TABLE PER SAMPLE. Every registered combatant records one
	sample per engine frame for as long as it exists; a table per sample would be the per-frame allocation
	performance-optimization.md forbids, for state that is overwritten a third of a second later. So the ring
	is two preallocated arrays and a head index, sized once (Capacity) and written in place.

	THE ROOT, NOT EVERY PART. The engine judges a contact at a part's centre, and every part of a body moves
	with its root over a fraction of a second -- an arm swinging relative to the torso is the target's OWN
	animation, which the attacker sees replicated at the same delay. So a rewound part is its live position
	shifted by how far the ROOT has moved since the rewind time: one sample per body, not one per limb.

	Pure: no Instances, no clock of its own (the caller passes time), so it is specced without a DataModel.

	Does not own: when to record (HitboxEngine.Step, once per frame per combatant), how far back to look
	(HitboxEngine, per swing, from NetworkLatency), or whether to look at all (LagCompensation.Enabled).
]]

local PoseHistory = {}

export type History = {
	Capacity: number,
	Times: { number },
	Positions: { Vector3 },
	-- Index of the newest sample; 0 while empty.
	Head: number,
	Count: number,
}

function PoseHistory.New(capacity: number): History
	assert(capacity >= 2, "PoseHistory needs room for at least two samples")
	local times = table.create(capacity, 0)
	local positions = table.create(capacity, Vector3.zero)
	return { Capacity = capacity, Times = times, Positions = positions, Head = 0, Count = 0 }
end

-- Appends a sample. A time no later than the newest replaces it (two records in one frame keep the last),
-- so the ring is always strictly increasing in time.
function PoseHistory.Record(history: History, time: number, position: Vector3): ()
	if history.Count > 0 and time <= history.Times[history.Head] then
		history.Positions[history.Head] = position
		history.Times[history.Head] = time
		return
	end
	local head = history.Head % history.Capacity + 1
	history.Head = head
	history.Times[head] = time
	history.Positions[head] = position
	if history.Count < history.Capacity then
		history.Count += 1
	end
end

-- The sample `offset` steps older than the newest (0 = newest).
local function indexAt(history: History, offset: number): number
	return (history.Head - 1 - offset) % history.Capacity + 1
end

-- Where the body was at `time`: interpolated between the two samples around it, the oldest sample for a
-- time before the history begins, the newest for a time after it ends. nil while the history is empty.
function PoseHistory.At(history: History, time: number): Vector3?
	local count = history.Count
	if count == 0 then
		return nil
	end
	local newest = history.Head
	if time >= history.Times[newest] then
		return history.Positions[newest]
	end
	-- Newest to oldest: the first sample at or before `time` brackets it with the one after.
	local later = newest
	for offset = 1, count - 1 do
		local index = indexAt(history, offset)
		local at = history.Times[index]
		if at <= time then
			local span = history.Times[later] - at
			local alpha = if span > 0 then (time - at) / span else 1
			return history.Positions[index]:Lerp(history.Positions[later], alpha)
		end
		later = index
	end
	return history.Positions[indexAt(history, count - 1)]
end

-- How far the body has moved from `time` until its newest sample -- what a part's live position is shifted
-- BACK by to test it where it was then. Zero for an empty history.
function PoseHistory.DisplacementSince(history: History, time: number): Vector3
	if history.Count == 0 then
		return Vector3.zero
	end
	local past = PoseHistory.At(history, time) :: Vector3
	return history.Positions[history.Head] - past
end

function PoseHistory.Clear(history: History): ()
	history.Head = 0
	history.Count = 0
end

return PoseHistory
