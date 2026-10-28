--!strict
--[[
	ArchitectHistory.lua

	Owns: the World Architect's undo/redo bookkeeping -- what a transaction is, its exact inverse, and one admin's
	bounded undo and redo stacks.

	OPERATIONS, NOT SNAPSHOTS. A transaction is the list of node operations one edit made (Create, Delete, Update), each
	carrying the full records it touched AS THEY WERE (Delete, Update's Before) and AS THEY ARE NOW (Create, Update's
	After). Undo applies the inverse; nothing ever copies the whole world. A terrain stroke is its own op kind, carried
	by id, whose recovery data (the voxel snapshot) the server keeps beside it.

	THE REVISIONS ARE THE CONFLICT CHECK. Every record in a transaction carries the Rev it was left at. Applying an
	inverse requires the world to still hold exactly those Revs (WorldState.Apply checks): if another admin has edited a
	node since, the undo is refused rather than silently overwriting their newer change, and the entry is dropped.

	BOUNDED TWO WAYS: at most Limits.HistoryDepth transactions, and at most Limits.HistoryNodeBudget node copies across
	both stacks -- a generation commit of a thousand nodes costs a thousand, so a few of those push older entries out.

	Pure. The server owns one of these per admin (PlayerScoped) and applies what it returns.
]]

local ArchitectConstants = require(script.Parent.ArchitectConstants)
local ArchitectRecord = require(script.Parent.ArchitectRecord)

type NodeRecord = ArchitectRecord.NodeRecord

local Limits = ArchitectConstants.Limits

local ArchitectHistory = {}

export type Op = {
	Kind: "Create" | "Delete" | "Update" | "Terrain",
	-- Create: the records as created. Delete: the records as they were just before deletion.
	Records: { NodeRecord }?,
	-- Update: every touched record before and after, index-aligned.
	Before: { NodeRecord }?,
	After: { NodeRecord }?,
	-- Terrain: the stroke's id and whether this op applies (true) or reverts (false) it.
	StrokeId: number?,
	Apply: boolean?,
}

export type Transaction = {
	Label: string,
	Ops: { Op },
}

export type History = {
	Undo: { Transaction },
	Redo: { Transaction },
	Cost: number,
}

function ArchitectHistory.New(): History
	return { Undo = {}, Redo = {}, Cost = 0 }
end

function ArchitectHistory.CostOf(transaction: Transaction): number
	local cost = 0
	for _, op in transaction.Ops do
		local records = op.Records or {} :: { NodeRecord }
		local before = op.Before or {} :: { NodeRecord }
		local after = op.After or {} :: { NodeRecord }
		cost += #records + #before + #after + (if op.Kind == "Terrain" then 1 else 0)
	end
	return math.max(cost, 1)
end

function ArchitectHistory.Invert(transaction: Transaction): Transaction
	local ops: { Op } = {}
	for index = #transaction.Ops, 1, -1 do
		local op = transaction.Ops[index]
		if op.Kind == "Create" then
			table.insert(ops, { Kind = "Delete", Records = op.Records })
		elseif op.Kind == "Delete" then
			table.insert(ops, { Kind = "Create", Records = op.Records })
		elseif op.Kind == "Update" then
			table.insert(ops, { Kind = "Update", Before = op.After, After = op.Before })
		else
			table.insert(ops, { Kind = "Terrain", StrokeId = op.StrokeId, Apply = not op.Apply })
		end
	end
	return { Label = transaction.Label, Ops = ops }
end

local function recount(history: History): ()
	local cost = 0
	for _, stack in { history.Undo, history.Redo } do
		for _, transaction in stack do
			cost += ArchitectHistory.CostOf(transaction)
		end
	end
	history.Cost = cost
end

-- Drops the oldest entries (undo first, then redo) until both bounds hold.
local function trim(history: History): ()
	while #history.Undo > Limits.HistoryDepth do
		table.remove(history.Undo, 1)
	end
	while #history.Redo > Limits.HistoryDepth do
		table.remove(history.Redo, 1)
	end
	recount(history)
	while history.Cost > Limits.HistoryNodeBudget and (#history.Undo > 0 or #history.Redo > 0) do
		if #history.Undo > 0 then
			table.remove(history.Undo, 1)
		else
			table.remove(history.Redo, 1)
		end
		recount(history)
	end
end

-- A new edit: onto the undo stack, and the redo stack is cleared (a new edit forks history).
function ArchitectHistory.Record(history: History, transaction: Transaction): ()
	table.insert(history.Undo, transaction)
	table.clear(history.Redo)
	trim(history)
end

function ArchitectHistory.TakeUndo(history: History): Transaction?
	local transaction = table.remove(history.Undo)
	recount(history)
	return transaction
end

function ArchitectHistory.TakeRedo(history: History): Transaction?
	local transaction = table.remove(history.Redo)
	recount(history)
	return transaction
end

-- After a successful undo: the transaction as re-applied, so Redo can invert it again.
function ArchitectHistory.PushRedo(history: History, transaction: Transaction): ()
	table.insert(history.Redo, transaction)
	trim(history)
end

-- After a successful redo: back onto undo WITHOUT clearing redo (it is not a new edit).
function ArchitectHistory.PushUndo(history: History, transaction: Transaction): ()
	table.insert(history.Undo, transaction)
	trim(history)
end

-- The revision each node was left at by `ops` (as applied): what a later inverse would have to find.
function ArchitectHistory.RevsOf(ops: { Op }): { [string]: number }
	local revs: { [string]: number } = {}
	for _, op in ops do
		for _, record in (op.Records or {}) :: { NodeRecord } do
			if op.Kind == "Create" then
				revs[record.Id] = record.Rev
			end
		end
		for _, record in (op.After or {}) :: { NodeRecord } do
			revs[record.Id] = record.Rev
		end
	end
	return revs
end

-- An undo (or redo) re-stamps every node it touches with a new revision even though it restores exactly the state the
-- next entry down expects. Without this, the second undo of a chain (create, edit, undo, undo) would read as a
-- conflict. For each node `revs` names, the NEAREST entry of `stack` that checks that node's revision is moved to the
-- new one -- only the nearest, because it is the only entry that can be applied next; deeper entries are rebased in
-- turn as the ones above them are applied. A node another admin edits still fails the check, as it must.
function ArchitectHistory.Rebase(stack: { Transaction }, revs: { [string]: number }): ()
	local pending = table.clone(revs)
	for index = #stack, 1, -1 do
		if next(pending) == nil then
			return
		end
		local matched: { string } = {}
		for _, op in stack[index].Ops do
			-- What this entry's inverse checks: a Create's records (undone by deleting them) and an Update's After.
			local checked = if op.Kind == "Create" then op.Records elseif op.Kind == "Update" then op.After else nil
			for position, record in (checked or {}) :: { NodeRecord } do
				local rev = pending[record.Id]
				if rev then
					local rebased = table.clone(record)
					rebased.Rev = rev;
					(checked :: { NodeRecord })[position] = rebased
					table.insert(matched, record.Id)
				end
			end
		end
		for _, id in matched do
			pending[id] = nil
		end
	end
end

function ArchitectHistory.Clear(history: History): ()
	table.clear(history.Undo)
	table.clear(history.Redo)
	history.Cost = 0
end

-- The labels shown on the Undo / Redo buttons.
function ArchitectHistory.Peek(history: History): (string?, string?)
	local undo = history.Undo[#history.Undo]
	local redo = history.Redo[#history.Redo]
	return if undo then undo.Label else nil, if redo then redo.Label else nil
end

return ArchitectHistory
