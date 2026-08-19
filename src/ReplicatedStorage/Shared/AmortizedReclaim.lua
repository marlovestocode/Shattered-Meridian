--!strict
--[[
	AmortizedReclaim.lua

	Owns: the round-robin cursor that reclaims dead-Model keys from a per-model table WITHOUT walking
	the whole table every frame.

	The pattern is HitboxEngine's, generalised. That module's own sweepLiveness already states the
	reasoning this file exists to share: "walking the whole registry every frame to find them would be
	a full scan on the overwhelming majority of frames where nobody has despawned, so the sweep is
	amortised over frames instead -- pay one comparison per tick, do the walk only when it can pay
	off." Three other per-frame sweeps in the combat stack (AttackRequestSystem's cooldownUntil and
	combatantIds, SwingSequencer's records, DamageSystem's hitstunUntil) were doing the full scan,
	each purely to stop the OUTER table holding a reference to a destroyed character forever.

	ONLY FOR RECLAIM-ONLY SWEEPS. A loop that also does per-entry WORK -- DamageSystem.Step's
	lungeUntil (it calls Humanoid:Move on every live entry, every frame) and GrabSystem.Step's
	holds/flights (they release holds and advance flight physics) -- must keep its full walk: skipping
	entries there is not a delayed cleanup, it is a dropped frame of gameplay. Those tables are also
	naturally tiny, holding only the handful of combatants mid-lunge or mid-grab, which is why the
	full walk was never the cost in the first place. Reaching for this module there would be a
	correctness bug wearing a performance fix's clothes.

	HASH TABLES, NOT ARRAYS, which is the one real difference from HitboxEngine's integer cursor. The
	resume point is a KEY, and `next(map, key)` is only defined while that key is still present -- so
	the cursor is validated against the map on entry and restarts from the top if the key has been
	removed since (by unbindCharacter, by PlayerRemoving, by a Reset). Within a step, the following
	key is read BEFORE the current one is removed, which is the one ordering that makes removal during
	traversal well-defined.

	WORST-CASE STALENESS is `#map / ChecksPerStep` frames before a given dead entry is noticed, which
	is the trade being made deliberately: every one of these tables is read through a live lookup that
	already tolerates a stale entry (an expired cooldown compares against `now`, a hitstun window
	compares against `now`, a combatant id is re-resolved through HitboxEngine when missing), so a
	late reclaim costs memory for a few frames and costs correctness nothing. A table whose ENTRIES
	change meaning when stale does not belong here -- see the paragraph above.

	Does NOT own: what the table holds, when Step is called (the owning System's Heartbeat), or
	eviction on any basis other than "the key Instance has left the DataModel". Expiry-by-timestamp
	stays the owning System's business, because only it knows what its timestamps mean.
]]

local AmortizedReclaim = {}
AmortizedReclaim.__index = AmortizedReclaim

-- Matches HitboxEngine's own LIVENESS_CHECKS_PER_FRAME. Four is enough that a full server's worth of
-- entries is covered within a handful of frames, and small enough that the per-frame cost is a fixed
-- constant rather than a function of how many combatants exist -- which is the entire point.
local DEFAULT_CHECKS_PER_STEP = 4

export type ReclaimInstance = typeof(setmetatable(
	{} :: {
		checksPerStep: number,
		-- The NEXT key to examine, not the last one examined -- so a removal mid-step (which has to
		-- read the following key before nil-ing the current one) needs no second piece of state to
		-- express "resume AT this key rather than after it".
		pending: Model?,
	},
	AmortizedReclaim
))

-- One independent cursor. A System sweeping two tables wants TWO of these: sharing one would make
-- each table's progress depend on the other's size, and a key from table A is meaningless as a resume
-- point in table B.
function AmortizedReclaim.New(checksPerStep: number?): ReclaimInstance
	return setmetatable({
		checksPerStep = math.max(1, math.floor(checksPerStep or DEFAULT_CHECKS_PER_STEP)),
		pending = nil,
	}, AmortizedReclaim) :: any
end

-- Examines up to ChecksPerStep entries and drops any whose Model has left the DataModel. Returns how
-- many were reclaimed -- zero on the overwhelming majority of calls, which is the shape this is built
-- for. Safe to call on an empty table, on a table the caller mutated since the last call, and on one
-- whose previous resume key has since been removed by some other path.
function AmortizedReclaim.Step<V>(self: ReclaimInstance, map: { [Model]: V }): number
	local key = self.pending
	-- Removed since the last Step (unbindCharacter, PlayerRemoving, Reset). `next(map, key)` would
	-- error on it, so the sweep restarts from the top -- costing at most one extra pass over entries
	-- that were already checked, and never skipping one.
	if key ~= nil and map[key] == nil then
		key = nil
	end
	if key == nil then
		key = (next(map))
	end

	local reclaimed = 0
	for _ = 1, self.checksPerStep do
		if key == nil then
			break
		end
		-- Read BEFORE the removal below: `next` past a key that has just been nil-ed is undefined.
		local following = (next(map, key))
		if key.Parent == nil then
			map[key] = nil
			reclaimed += 1
		end
		key = following
	end

	-- nil here means "walked off the end" -- the next Step restarts from the top, which is what makes
	-- this round-robin rather than a one-shot pass.
	self.pending = key
	return reclaimed
end

-- Drops the resume point. Call alongside a table.clear() of the map it sweeps -- a cursor pointing
-- into a table that no longer holds it is already handled by Step's own guard above, so this is about
-- saying so at the call site rather than about correctness.
function AmortizedReclaim.Reset(self: ReclaimInstance): ()
	self.pending = nil
end

return AmortizedReclaim
