--!strict
--[[
	DraftHistory.lua

	Owns: the Move Editor's undo/redo -- a bounded stack of earlier drafts per move, and the rule that
	turns a burst of edits (a stepper held down, a gizmo dragged) into ONE step.

	PER MOVE. Each MoveId has its own undo and redo stacks, so switching to another move and pressing
	Ctrl+Z never reaches back into the move you left. Switching back finds that move's history intact.

	COALESCING IS A SLIDING WINDOW. A Record that arrives within `coalesceSeconds` of the previous Record
	for the same move is dropped -- the state from before the burst is already on the stack -- and the
	window slides forward with it, so a drag of any length is one step. Undo and Redo close the window:
	the first edit after either always records, or it would silently merge into a step that is no longer
	on top.

	COPIES, NEVER THE LIVE DRAFT. Every stored move is a MoveTypes.Clone, and so is every move handed back:
	the screen's draft is also what the plots, the browser and the dirty check read, and a stack holding a
	reference to it would change under them.

	Pure: no Instances, no clock (the caller passes `now`), no Fusion. The screen wraps it in a Value to
	make CanUndo/CanRedo reactive.

	Does not own: what an edit is (MoveEditor/init.lua's context.Edit), when history must be forgotten
	(the driver calls Clear after a revert, a reset, a restore or a delete), or the keys.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

type Move = MoveTypes.MoveDefinition

type Stacks = {
	Undo: { Move },
	Redo: { Move },
	-- When the last Record for this move arrived (recorded or coalesced), or nil when the window is closed.
	LastRecordAt: number?,
}

local DraftHistory = {}
DraftHistory.__index = DraftHistory

export type History = typeof(setmetatable(
	{} :: {
		_capacity: number,
		_coalesceSeconds: number,
		_byMove: { [string]: Stacks },
	},
	DraftHistory
))

function DraftHistory.new(capacity: number, coalesceSeconds: number): History
	return setmetatable({
		_capacity = math.max(1, math.floor(capacity)),
		_coalesceSeconds = math.max(0, coalesceSeconds),
		_byMove = {},
	}, DraftHistory) :: any
end

local function stacksFor(self: History, moveId: string): Stacks
	local existing = self._byMove[moveId]
	if existing then
		return existing
	end
	local created: Stacks = { Undo = {}, Redo = {}, LastRecordAt = nil }
	self._byMove[moveId] = created
	return created
end

local function push(self: History, stack: { Move }, move: Move): ()
	table.insert(stack, MoveTypes.Clone(move))
	while #stack > self._capacity do
		table.remove(stack, 1)
	end
end

-- Notes that `moveId` is about to change away from `before`. Pushes a copy of it and clears the redo
-- stack -- unless this lands inside the coalescing window, in which case the burst's first state is
-- already on the stack and this is dropped (but still slides the window).
function DraftHistory.Record(self: History, moveId: string, before: Move, now: number): ()
	local stacks = stacksFor(self, moveId)
	local last = stacks.LastRecordAt
	stacks.LastRecordAt = now
	if last ~= nil and now - last <= self._coalesceSeconds then
		return
	end
	push(self, stacks.Undo, before)
	table.clear(stacks.Redo)
end

-- The draft to go back to, or nil when there is none. `current` goes onto the redo stack.
function DraftHistory.Undo(self: History, moveId: string, current: Move): Move?
	local stacks = self._byMove[moveId]
	if not stacks or #stacks.Undo == 0 then
		return nil
	end
	local previous = table.remove(stacks.Undo) :: Move
	push(self, stacks.Redo, current)
	stacks.LastRecordAt = nil
	return MoveTypes.Clone(previous)
end

-- The draft an Undo stepped back from, or nil. `current` goes back onto the undo stack.
function DraftHistory.Redo(self: History, moveId: string, current: Move): Move?
	local stacks = self._byMove[moveId]
	if not stacks or #stacks.Redo == 0 then
		return nil
	end
	local following = table.remove(stacks.Redo) :: Move
	push(self, stacks.Undo, current)
	stacks.LastRecordAt = nil
	return MoveTypes.Clone(following)
end

function DraftHistory.CanUndo(self: History, moveId: string): boolean
	local stacks = self._byMove[moveId]
	return stacks ~= nil and #stacks.Undo > 0
end

function DraftHistory.CanRedo(self: History, moveId: string): boolean
	local stacks = self._byMove[moveId]
	return stacks ~= nil and #stacks.Redo > 0
end

-- Forgets one move's history -- after anything that replaces the draft with a server state the stack
-- knows nothing about (a revert, a reset to default, a restored version, a delete).
function DraftHistory.Clear(self: History, moveId: string): ()
	self._byMove[moveId] = nil
end

return DraftHistory
