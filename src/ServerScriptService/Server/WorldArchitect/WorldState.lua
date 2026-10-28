--!strict
--[[
	WorldState.lua

	Owns: the authoritative record store behind the World Architect -- every node the managed world holds, the global
	revision, id allocation, the protected areas nothing may be built into, and the ONE way the world changes: applying a
	list of operations as an atomic transaction.

	NO INSTANCES. This module never touches Workspace; WorldMaterializer turns what it holds into Parts. That split is
	what lets Tests/WorldArchitect/WorldState.spec.lua drive every rule (limits, protected areas, locks, parents,
	revisions, atomicity) headlessly.

	ATOMIC. Apply checks every operation against an overlay of the world-as-it-would-be and commits only when all of them
	pass; a refusal anywhere leaves the world exactly as it was. There is no half-applied transaction to clean up.

	REVISIONS. Every Apply that changes anything advances `Revision` once, and every record it touched takes that number
	as its `Rev`. An Update must name the Rev it was made against (its Before), a Delete must name the Rev of what it
	deletes: a mismatch is `StaleNode`. Undo goes through exactly the same check, which is how a stale undo is caught
	(ArchitectHistory's header).

	WHAT EVERY CHANGE IS HELD TO, whoever proposed it (a client request, a template expansion, a generator, a load):
	  * inside the world bounds, sizes inside the part limits (ArchitectRecord's shapes re-run here);
	  * a part's bounds never intersect a protected area (spawn pads -- ProtectedZones);
	  * a parent exists, is a Group, and the chain stays acyclic and within Limits.MaxDepth;
	  * deleting a Group deletes its whole subtree in the same operation, so nothing is ever orphaned;
	  * a locked node refuses every change except the one that unlocks it;
	  * the world never holds more than Limits.MaxNodes nodes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectHistory = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectHistory)
local ArchitectTemplates = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTemplates)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)

type NodeRecord = ArchitectRecord.NodeRecord
type Op = ArchitectHistory.Op

local Limits = ArchitectConstants.Limits

local WorldState = {}

export type Zone = { Name: string, Min: Vector3, Max: Vector3 }

export type State = {
	Records: { [string]: NodeRecord },
	-- Parent id ("" for the root) -> its children's ids.
	Children: { [string]: { [string]: boolean } },
	Count: number,
	NextId: number,
	Revision: number,
	Zones: { Zone },
}

export type Delta = {
	Revision: number,
	Upserts: { NodeRecord },
	Removes: { string },
}

local ROOT = ""

function WorldState.New(): State
	return { Records = {}, Children = { [ROOT] = {} }, Count = 0, NextId = 1, Revision = 0, Zones = {} }
end

function WorldState.SetZones(state: State, zones: { Zone }): ()
	state.Zones = zones
end

local function link(state: State, id: string, parent: string?): ()
	local key = parent or ROOT
	local set = state.Children[key]
	if set == nil then
		set = {}
		state.Children[key] = set
	end
	set[id] = true
end

local function unlink(state: State, id: string, parent: string?): ()
	local set = state.Children[parent or ROOT]
	if set then
		set[id] = nil
	end
end

local function toBase36(n: number): string
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	local out = ""
	local value = math.floor(n)
	repeat
		local d = value % 36
		out = string.sub(digits, d + 1, d + 1) .. out
		value //= 36
	until value == 0
	return out
end

function WorldState.AllocateId(state: State): string
	local id = "n" .. toBase36(state.NextId)
	state.NextId += 1
	return id
end

function WorldState.Get(state: State, id: string): NodeRecord?
	return state.Records[id]
end

-- Every record, ordered by id so pages are stable between calls.
function WorldState.List(state: State): { NodeRecord }
	local out: { NodeRecord } = {}
	for _, record in state.Records do
		table.insert(out, record)
	end
	table.sort(out, function(a, b)
		return a.Id < b.Id
	end)
	return out
end

-- `id` and everything under it, parents before children.
function WorldState.Subtree(state: State, id: string): { NodeRecord }
	local out: { NodeRecord } = {}
	local function visit(nodeId: string)
		local record = state.Records[nodeId]
		if record == nil then
			return
		end
		table.insert(out, record)
		local children = state.Children[nodeId]
		if children then
			local ids: { string } = {}
			for childId in children do
				table.insert(ids, childId)
			end
			table.sort(ids)
			for _, childId in ids do
				visit(childId)
			end
		end
	end
	visit(id)
	return out
end

-- The union of several subtrees with no record twice (a selection may name a group AND one of its parts).
function WorldState.Subtrees(state: State, ids: { string }): { NodeRecord }
	local seen: { [string]: boolean } = {}
	local out: { NodeRecord } = {}
	for _, id in ids do
		for _, record in WorldState.Subtree(state, id) do
			if not seen[record.Id] then
				seen[record.Id] = true
				table.insert(out, record)
			end
		end
	end
	return out
end

-- The protected area a part would intersect, or nil.
function WorldState.ZoneHit(state: State, record: NodeRecord): string?
	if record.Kind ~= "Part" then
		return nil
	end
	local low, high = ArchitectTransform.BoxBounds(ArchitectRecord.CFrameOf(record), record.Size)
	for _, zone in state.Zones do
		if
			low.X < zone.Max.X
			and high.X > zone.Min.X
			and low.Y < zone.Max.Y
			and high.Y > zone.Min.Y
			and low.Z < zone.Max.Z
			and high.Z > zone.Min.Z
		then
			return zone.Name
		end
	end
	return nil
end

local function placementReason(state: State, record: NodeRecord): string?
	local p = record.Position
	if
		math.abs(p.X) > Limits.WorldExtent
		or math.abs(p.Z) > Limits.WorldExtent
		or p.Y < Limits.MinY
		or p.Y > Limits.MaxY
	then
		return "OutOfBounds"
	end
	if record.Kind == "Part" then
		local s = record.Size
		if math.min(s.X, s.Y, s.Z) < Limits.MinPartSize or math.max(s.X, s.Y, s.Z) > Limits.MaxPartSize then
			return "InvalidSize"
		end
		if WorldState.ZoneHit(state, record) then
			return "ProtectedArea"
		end
	end
	return nil
end

type Overlay = { [string]: NodeRecord | false }

local function lookup(state: State, overlay: Overlay, id: string): NodeRecord?
	local value = overlay[id]
	if value == false then
		return nil
	elseif value ~= nil then
		return value :: NodeRecord
	end
	return state.Records[id]
end

local function depthOf(state: State, overlay: Overlay, id: string?): number
	local depth = 0
	local current = id
	while current do
		depth += 1
		if depth > Limits.MaxDepth + 1 then
			return depth
		end
		local record = lookup(state, overlay, current)
		current = if record then record.Parent else nil
	end
	return depth
end

local function parentReason(state: State, overlay: Overlay, record: NodeRecord): string?
	if record.Parent == nil then
		return nil
	end
	if record.Parent == record.Id then
		return "InvalidParent"
	end
	local parent = lookup(state, overlay, record.Parent :: string)
	if parent == nil or parent.Kind ~= "Group" then
		return "InvalidParent"
	end
	-- Walk up from the parent: meeting this node again is a cycle.
	local current: string? = record.Parent
	local steps = 0
	while current do
		if current == record.Id then
			return "InvalidParent"
		end
		steps += 1
		if steps > Limits.MaxDepth + 1 then
			return "TooDeep"
		end
		local node = lookup(state, overlay, current)
		current = if node then node.Parent else nil
	end
	if depthOf(state, overlay, record.Parent) + 1 > Limits.MaxDepth then
		return "TooDeep"
	end
	return nil
end

local function isPureUnlock(current: NodeRecord, after: NodeRecord): boolean
	if after.Locked then
		return false
	end
	local probe = table.clone(after)
	probe.Locked = true
	probe.Rev = current.Rev
	for key, value in current :: any do
		if (probe :: any)[key] ~= value then
			return false
		end
	end
	return true
end

-- Applies `ops` atomically. Returns the ops AS APPLIED (every touched record carrying its new Rev -- what history
-- keeps) and the delta to push, or nil and a reason with the world untouched.
function WorldState.Apply(state: State, ops: { Op }): ({ Op }?, Delta?, string?)
	local overlay: Overlay = {}
	local count = state.Count
	local revision = state.Revision + 1
	local applied: { Op } = {}
	local deleted: { [string]: boolean } = {}

	for _, op in ops do
		if op.Kind == "Create" then
			local created: { NodeRecord } = {}
			for _, source in (op.Records or {}) :: { NodeRecord } do
				if source.Id == "" or lookup(state, overlay, source.Id) ~= nil then
					return nil, nil, "DuplicateId"
				end
				local record = ArchitectRecord.Clone(source)
				record.Rev = revision
				local reason = placementReason(state, record) or parentReason(state, overlay, record)
				if reason then
					return nil, nil, reason
				end
				overlay[record.Id] = record
				deleted[record.Id] = nil
				count += 1
				table.insert(created, record)
			end
			table.insert(applied, { Kind = "Create", Records = created })
		elseif op.Kind == "Delete" then
			local removed: { NodeRecord } = {}
			for _, expected in (op.Records or {}) :: { NodeRecord } do
				local current = lookup(state, overlay, expected.Id)
				if current == nil then
					return nil, nil, "MissingNode"
				end
				if current.Rev ~= expected.Rev then
					return nil, nil, "StaleNode"
				end
				if current.Locked then
					return nil, nil, "Locked"
				end
				overlay[current.Id] = false
				deleted[current.Id] = true
				count -= 1
				table.insert(removed, current)
			end
			table.insert(applied, { Kind = "Delete", Records = removed })
		elseif op.Kind == "Update" then
			local before = (op.Before or {}) :: { NodeRecord }
			local after = (op.After or {}) :: { NodeRecord }
			if #before ~= #after then
				return nil, nil, "MalformedOp"
			end
			local newBefore: { NodeRecord } = {}
			local newAfter: { NodeRecord } = {}
			for index, target in after do
				local expected = before[index]
				if expected.Id ~= target.Id then
					return nil, nil, "MalformedOp"
				end
				local current = lookup(state, overlay, target.Id)
				if current == nil then
					return nil, nil, "MissingNode"
				end
				if current.Rev ~= expected.Rev then
					return nil, nil, "StaleNode"
				end
				if current.Kind ~= target.Kind then
					return nil, nil, "MalformedOp"
				end
				if current.Locked and not isPureUnlock(current, target) then
					return nil, nil, "Locked"
				end
				local record = ArchitectRecord.Clone(target)
				record.Rev = revision
				local reason = placementReason(state, record)
				if reason then
					return nil, nil, reason
				end
				overlay[record.Id] = record
				table.insert(newBefore, current)
				table.insert(newAfter, record)
			end
			-- Parents are checked after the whole op, so a group and its children can be re-parented together.
			for _, record in newAfter do
				local reason = parentReason(state, overlay, record)
				if reason then
					return nil, nil, reason
				end
			end
			table.insert(applied, { Kind = "Update", Before = newBefore, After = newAfter })
		else
			return nil, nil, "MalformedOp"
		end
	end

	if count > Limits.MaxNodes then
		return nil, nil, "WorldFull"
	end
	-- Nothing may be left pointing at a deleted parent: not an existing child, not one this transaction wrote.
	local referenced: { [string]: boolean } = {}
	for _, value in overlay do
		if value and (value :: NodeRecord).Parent then
			referenced[(value :: NodeRecord).Parent :: string] = true
		end
	end
	for id in deleted do
		if referenced[id] then
			return nil, nil, "OrphanedChildren"
		end
		local children = state.Children[id]
		if children then
			for childId in children do
				local child = lookup(state, overlay, childId)
				if child and child.Parent == id then
					return nil, nil, "OrphanedChildren"
				end
			end
		end
	end

	-- Commit.
	local delta: Delta = { Revision = revision, Upserts = {}, Removes = {} }
	for id, value in overlay do
		local previous = state.Records[id]
		if previous then
			unlink(state, id, previous.Parent)
		end
		if value == false then
			state.Records[id] = nil
			state.Children[id] = nil
			table.insert(delta.Removes, id)
		else
			local record = value :: NodeRecord
			state.Records[id] = record
			link(state, id, record.Parent)
			table.insert(delta.Upserts, record)
		end
	end
	state.Count = count
	state.Revision = revision
	return applied, delta, nil
end

-- Resolves pending nodes (refs and parent refs) into numbered records ready for a Create op. A ParentRef names an
-- earlier pending Ref or an existing node id; anything else is refused.
function WorldState.Number(state: State, pending: { ArchitectTemplates.PendingNode }): ({ NodeRecord }?, string?)
	if #pending > Limits.MaxNodesPerTransaction then
		return nil, "TooManyNodes"
	end
	local idOfRef: { [string]: string } = {}
	local out: { NodeRecord } = {}
	for _, node in pending do
		if idOfRef[node.Ref] then
			return nil, "DuplicateRef"
		end
		local record = ArchitectRecord.Clone(node.Record)
		record.Id = WorldState.AllocateId(state)
		record.Rev = 0
		if node.ParentRef then
			local parentId = idOfRef[node.ParentRef :: string]
			if parentId == nil then
				local existing = state.Records[node.ParentRef :: string]
				if existing == nil then
					return nil, "InvalidParent"
				end
				parentId = existing.Id
			end
			record.Parent = parentId
		else
			record.Parent = nil
		end
		idOfRef[node.Ref] = record.Id
		table.insert(out, record)
	end
	return out, nil
end

-- Replaces the whole world with `records` (a load). Revs restart at the new revision; ids continue from `nextId`.
function WorldState.Replace(state: State, records: { NodeRecord }, nextId: number): Delta
	local removes: { string } = {}
	for id in state.Records do
		table.insert(removes, id)
	end
	state.Records = {}
	state.Children = { [ROOT] = {} }
	state.Count = 0
	state.Revision += 1
	state.NextId = math.max(nextId, 1)
	local upserts: { NodeRecord } = {}
	for _, source in records do
		local record = ArchitectRecord.Clone(source)
		record.Rev = state.Revision
		state.Records[record.Id] = record
		state.Count += 1
		table.insert(upserts, record)
	end
	for _, record in upserts do
		link(state, record.Id, record.Parent)
	end
	return { Revision = state.Revision, Upserts = upserts, Removes = removes }
end

return WorldState
