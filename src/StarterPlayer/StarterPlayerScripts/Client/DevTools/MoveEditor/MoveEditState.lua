--!strict
--[[
	MoveEditState.lua

	Owns: the per-move bookkeeping one Move Editor session accumulates and nothing else needs -- each
	move's undo/redo history, the baseline the next undo entry is taken from, and which moves have
	been edited but not saved.

	All of it is keyed by MoveId, and that is the point. An admin edits several moves in one session,
	so every one of these questions is per-move: undo has to walk back THIS move's edits, and "is
	there unsaved work" is about a set of moves rather than about the one currently on screen (which
	is what MoveEditorHandle.IsDirty already answers, and why it was not enough on its own).

	Pure tables. No Fusion, no remotes, no handle -- MoveEditorClient.lua reads the results and
	publishes them; this module never sees a Value or a Player. That split is what makes it testable
	at all: undo/redo is a small state machine whose bugs (a redo branch that survives a fresh edit,
	a stack that grows without bound, a deleted move whose history can resurrect it) are exactly the
	kind that never surface in a manual pass, and none of them need a mounted screen to find.

	WHOLE RECORDS, not diffs or command objects. A draft is a small flat table that MoveTypes.Clone
	already deep-copies on every single edit, so "the state before" costs nothing extra to keep --
	while a command log would need an inverse for each of the editor's ~50 controls and would rot the
	moment one gained a side effect (Projectile's toggle already writes MaxTargets too).

	Entries are stored BY REFERENCE and never mutated: every edit path in this feature produces a
	fresh table (PropertyEditor's applyChange deep-clones; DraftBinding.Apply shallow-clones plus the
	panel's own sub-table clone), and a server reconcile REPLACES the draft rather than writing
	through it. If either of those ever stops being true, this module has to start cloning on the way
	in -- which is the whole reason that invariant is written down here rather than assumed.

	Does not own: what an edit IS (the draft itself), when one happens (the screen's own signals), or
	getting one to the server (MoveEditorClient's debounce). It is told.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

type MoveDefinition = MoveTypes.MoveDefinition

local MoveEditState = {}
MoveEditState.__index = MoveEditState

export type MoveEditStateInstance = typeof(setmetatable(
	{} :: {
		Depth: number,
		UndoStacks: { [string]: { MoveDefinition } },
		RedoStacks: { [string]: { MoveDefinition } },
		Baselines: { [string]: MoveDefinition },
		Unsaved: { [string]: true },
	},
	MoveEditState
))

-- 50 steps per move. Deep enough that an admin can walk back a whole tuning pass, shallow enough
-- that fifty drafts per move is a bounded amount of memory for a session that may touch dozens.
local DEFAULT_DEPTH = 50

function MoveEditState.New(depth: number?): MoveEditStateInstance
	return setmetatable({
		Depth = depth or DEFAULT_DEPTH,
		UndoStacks = {},
		RedoStacks = {},
		Baselines = {},
		Unsaved = {},
	}, MoveEditState) :: MoveEditStateInstance
end

local function pushBounded(stack: { MoveDefinition }, entry: MoveDefinition, depth: number): ()
	table.insert(stack, entry)
	if #stack > depth then
		-- Oldest first: the entry fifty edits ago is the one nobody is coming back for.
		-- table.remove(1) is O(n) on a 50-element array, which is nothing next to the clone that
		-- produced the entry in the first place.
		table.remove(stack, 1)
	end
end

-- What a move's next undo entry will be taken from: whatever was last on screen for it. Set every
-- time the draft is written from ANY source -- a fresh load, a server reconcile, a save, an undo --
-- because "the state before this edit" has to have been kept from the edit before, and an edit
-- arrives already applied (the screen updates optimistically, then reports).
function MoveEditState.SetBaseline(self: MoveEditStateInstance, moveId: string, draft: MoveDefinition): ()
	self.Baselines[moveId] = draft
end

function MoveEditState.Baseline(self: MoveEditStateInstance, moveId: string): MoveDefinition?
	return self.Baselines[moveId]
end

-- Files one edit: the previous state goes onto the undo stack, the redo branch ends, and the new
-- state becomes the baseline. The move is marked unsaved, because it now differs from storage.
--
-- No baseline yet means this is the first thing that ever happened to this move, so there is nothing
-- to walk back TO -- the edit still registers as unsaved and still becomes the baseline. Through the
-- UI that cannot happen (a move is selected or created, which sets a baseline, before it can be
-- edited), but a caller that forgets to seed one should get a working editor rather than a nil index.
function MoveEditState.Record(self: MoveEditStateInstance, newDraft: MoveDefinition): ()
	local moveId = newDraft.MoveId
	local previous = self.Baselines[moveId]
	if previous then
		local stack = self.UndoStacks[moveId]
		if not stack then
			stack = {}
			self.UndoStacks[moveId] = stack
		end
		pushBounded(stack :: { MoveDefinition }, previous, self.Depth)
	end
	-- A fresh edit ends the redo branch, the same as every other undo stack anywhere: the states
	-- ahead of the cursor described a future this edit just replaced.
	self.RedoStacks[moveId] = nil
	self.Baselines[moveId] = newDraft
	self.Unsaved[moveId] = true
end

-- Undo and redo are the SAME operation in opposite directions -- pop one side, push what is
-- currently on screen onto the other -- so they share this body rather than being two near-copies
-- whose stack bookkeeping could drift.
--
-- `current` is what is on screen right now, not the baseline: after a server reconcile those differ
-- only by a stamped UpdatedAt, but the thing an admin can want back is the thing they were looking
-- at. Returns nil when there is nothing to step to, which the caller reports; it is not an error.
local function step(
	self: MoveEditStateInstance,
	from: { [string]: { MoveDefinition } },
	into: { [string]: { MoveDefinition } },
	current: MoveDefinition
): MoveDefinition?
	local moveId = current.MoveId
	local source = from[moveId]
	if not source or #source == 0 then
		return nil
	end

	local restored = table.remove(source) :: MoveDefinition
	local destination = into[moveId]
	if not destination then
		destination = {}
		into[moveId] = destination
	end
	pushBounded(destination :: { MoveDefinition }, current, self.Depth)

	self.Baselines[moveId] = restored
	-- Stepping through history is still divergence from storage: undoing back to the loaded state
	-- does NOT clear the unsaved mark, because the server's live registry has meanwhile been written
	-- with every intermediate edit and only a real Save reconciles that.
	self.Unsaved[moveId] = true
	return restored
end

function MoveEditState.Undo(self: MoveEditStateInstance, current: MoveDefinition): MoveDefinition?
	return step(self, self.UndoStacks, self.RedoStacks, current)
end

function MoveEditState.Redo(self: MoveEditStateInstance, current: MoveDefinition): MoveDefinition?
	return step(self, self.RedoStacks, self.UndoStacks, current)
end

-- The move now matches storage: a successful Save, or a Reset that restored it to its defaults.
-- Deliberately NOT called on an UpdateDraft reconcile -- that only touched the server's in-memory
-- registry, and the gap between that and the DataStore is precisely what "unsaved" reports.
function MoveEditState.MarkSaved(self: MoveEditStateInstance, moveId: string): ()
	self.Unsaved[moveId] = nil
end

-- Everything about one move, dropped. Called on DELETE, and the history part is not incidental: an
-- undo stack for a move the server no longer has would let one Ctrl+Z push it back through
-- UpdateDraft, whose unknown-MoveId branch mints a fresh id -- resurrecting the deleted move under a
-- new identity, which is the same hazard the pending-edit cancel exists to close, by another route.
function MoveEditState.Forget(self: MoveEditStateInstance, moveId: string): ()
	self.UndoStacks[moveId] = nil
	self.RedoStacks[moveId] = nil
	self.Baselines[moveId] = nil
	self.Unsaved[moveId] = nil
end

function MoveEditState.UnsavedCount(self: MoveEditStateInstance): number
	local total = 0
	for _ in pairs(self.Unsaved) do
		total += 1
	end
	return total
end

return MoveEditState
