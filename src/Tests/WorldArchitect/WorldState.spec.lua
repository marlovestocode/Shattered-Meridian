--!strict
-- WorldState and ArchitectHistory together: every world rule, atomicity, revisions, and undo/redo with conflict
-- detection -- all headless, no Instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectHistory = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectHistory)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local WorldState = require(ServerScriptService.Server.WorldArchitect.WorldState)

type NodeRecord = ArchitectRecord.NodeRecord

local Limits = ArchitectConstants.Limits

local function part(state: WorldState.State, position: Vector3?, parent: string?): NodeRecord
	local record = ArchitectRecord.Default("Part", "Structure", WorldState.AllocateId(state))
	record.Position = position or Vector3.new(0, 5, 0)
	record.Parent = parent
	return record
end

local function group(state: WorldState.State, parent: string?): NodeRecord
	local record = ArchitectRecord.Default("Group", nil, WorldState.AllocateId(state))
	record.Parent = parent
	return record
end

local function create(state: WorldState.State, records: { NodeRecord }): { NodeRecord }
	local applied, _, reason = WorldState.Apply(state, { { Kind = "Create", Records = records } })
	assert(applied, `create refused: {tostring(reason)}`)
	return applied[1].Records :: { NodeRecord }
end

local function update(state: WorldState.State, current: NodeRecord, patch: { [string]: any }): (any, string?)
	local applied, _, reason = WorldState.Apply(state, {
		{ Kind = "Update", Before = { current }, After = { ArchitectRecord.Apply(current, patch) } },
	})
	return applied, reason
end

return function()
	describe("Apply", function()
		it("creates, bumps the revision once and stamps every touched record with it", function()
			local state = WorldState.New()
			local created = create(state, { part(state), part(state) })
			expect(state.Revision).to.equal(1)
			expect(state.Count).to.equal(2)
			expect(created[1].Rev).to.equal(1)
			expect(created[2].Rev).to.equal(1)
		end)

		it("refuses a stale update and leaves the world untouched", function()
			local state = WorldState.New()
			local record = create(state, { part(state) })[1]
			assert(update(state, record, { Name = "First" }), "first update")
			local applied, reason = update(state, record, { Name = "Second" })
			expect(applied).to.equal(nil)
			expect(reason).to.equal("StaleNode")
			expect((WorldState.Get(state, record.Id) :: NodeRecord).Name).to.equal("First")
		end)

		it("is atomic: one bad record in a batch refuses all of it", function()
			local state = WorldState.New()
			local good = part(state)
			local bad = part(state, Vector3.new(Limits.WorldExtent + 50, 0, 0))
			local applied, _, reason = WorldState.Apply(state, { { Kind = "Create", Records = { good, bad } } })
			expect(applied).to.equal(nil)
			expect(reason).to.equal("OutOfBounds")
			expect(state.Count).to.equal(0)
			expect(state.Revision).to.equal(0)
			expect(WorldState.Get(state, good.Id)).to.equal(nil)
		end)

		it("refuses parts inside a protected zone", function()
			local state = WorldState.New()
			WorldState.SetZones(
				state,
				{ { Name = "Spawn", Min = Vector3.new(-5, 0, -5), Max = Vector3.new(5, 10, 5) } }
			)
			local _, _, reason =
				WorldState.Apply(state, { { Kind = "Create", Records = { part(state, Vector3.new(0, 2, 0)) } } })
			expect(reason).to.equal("ProtectedArea")
			local outside = create(state, { part(state, Vector3.new(50, 2, 0)) })[1]
			local _, moveReason = update(state, outside, { Position = Vector3.new(1, 2, 1) })
			expect(moveReason).to.equal("ProtectedArea")
		end)

		it("refuses edits to locked nodes but allows the unlock itself", function()
			local state = WorldState.New()
			local record = create(state, { part(state) })[1]
			local locked = (update(state, record, { Locked = true }) :: any)[1].After[1]
			local _, reason = update(state, locked, { Name = "Nope" })
			expect(reason).to.equal("Locked")
			local deleted, _, deleteReason = WorldState.Apply(state, { { Kind = "Delete", Records = { locked } } })
			expect(deleted).to.equal(nil)
			expect(deleteReason).to.equal("Locked")
			expect(WorldState.Get(state, locked.Id) ~= nil).to.equal(true)
			local unlocked = update(state, locked, { Locked = false })
			expect(unlocked ~= nil).to.equal(true)
		end)

		it("refuses deleting a group without its children", function()
			local state = WorldState.New()
			local g = group(state)
			local child = part(state, nil, g.Id)
			local created = create(state, { g, child })
			local _, _, reason = WorldState.Apply(state, { { Kind = "Delete", Records = { created[1] } } })
			expect(reason).to.equal("OrphanedChildren")
			local applied = WorldState.Apply(state, { { Kind = "Delete", Records = WorldState.Subtree(state, g.Id) } })
			expect(applied ~= nil).to.equal(true)
			expect(state.Count).to.equal(0)
		end)

		it("refuses parenting to a part, to a missing node, or into a cycle", function()
			local state = WorldState.New()
			local p = create(state, { part(state) })[1]
			local _, _, toPart = WorldState.Apply(state, { { Kind = "Create", Records = { part(state, nil, p.Id) } } })
			expect(toPart).to.equal("InvalidParent")
			local _, _, toMissing =
				WorldState.Apply(state, { { Kind = "Create", Records = { part(state, nil, "nzzzz") } } })
			expect(toMissing).to.equal("InvalidParent")
			local a = group(state)
			local b = group(state, a.Id)
			local created = create(state, { a, b })
			local looped = ArchitectRecord.Clone(created[1])
			looped.Parent = created[2].Id
			local _, _, cycle =
				WorldState.Apply(state, { { Kind = "Update", Before = { created[1] }, After = { looped } } })
			expect(cycle).to.equal("InvalidParent")
		end)

		it("refuses nesting past the depth limit", function()
			local state = WorldState.New()
			local parent: string? = nil
			local chain: { NodeRecord } = {}
			for _ = 1, Limits.MaxDepth do
				local g = group(state, parent)
				table.insert(chain, g)
				parent = g.Id
			end
			create(state, chain)
			local _, _, reason =
				WorldState.Apply(state, { { Kind = "Create", Records = { part(state, nil, parent) } } })
			expect(reason).to.equal("TooDeep")
		end)

		it("refuses growing past the node budget", function()
			local state = WorldState.New()
			state.Count = Limits.MaxNodes
			local _, _, reason = WorldState.Apply(state, { { Kind = "Create", Records = { part(state) } } })
			expect(reason).to.equal("WorldFull")
		end)

		it("Number resolves pending refs and refuses unknown parent refs", function()
			local state = WorldState.New()
			local records = WorldState.Number(state, {
				{ Ref = "g", ParentRef = nil, Record = ArchitectRecord.Default("Group") },
				{ Ref = "p", ParentRef = "g", Record = ArchitectRecord.Default("Part") },
			})
			assert(records, "numbered")
			expect(records[2].Parent).to.equal(records[1].Id)
			local _, reason = WorldState.Number(
				state,
				{ { Ref = "p", ParentRef = "missing", Record = ArchitectRecord.Default("Part") } }
			)
			expect(reason).to.equal("InvalidParent")
		end)
	end)

	describe("undo and redo through ArchitectHistory", function()
		it("undoes and redoes a create exactly", function()
			local state = WorldState.New()
			local history = ArchitectHistory.New()
			local applied = WorldState.Apply(state, { { Kind = "Create", Records = { part(state) } } })
			assert(applied, "applied")
			ArchitectHistory.Record(history, { Label = "Create", Ops = applied })

			local undo = ArchitectHistory.TakeUndo(history) :: ArchitectHistory.Transaction
			local undone = WorldState.Apply(state, ArchitectHistory.Invert(undo).Ops)
			assert(undone, "undone")
			expect(state.Count).to.equal(0)
			ArchitectHistory.PushRedo(history, { Label = undo.Label, Ops = undone })

			local redo = ArchitectHistory.TakeRedo(history) :: ArchitectHistory.Transaction
			local redone = WorldState.Apply(state, ArchitectHistory.Invert(redo).Ops)
			assert(redone, "redone")
			expect(state.Count).to.equal(1)
		end)

		it("refuses an undo when another admin has changed the node since", function()
			local state = WorldState.New()
			local history = ArchitectHistory.New()
			local applied = WorldState.Apply(state, { { Kind = "Create", Records = { part(state) } } }) :: any
			ArchitectHistory.Record(history, { Label = "Create", Ops = applied })
			local created = applied[1].Records[1]
			assert(update(state, created, { Name = "Someone else's" }), "other admin's edit")

			local undo = ArchitectHistory.TakeUndo(history) :: ArchitectHistory.Transaction
			local undone, _, reason = WorldState.Apply(state, ArchitectHistory.Invert(undo).Ops)
			expect(undone).to.equal(nil)
			expect(reason).to.equal("StaleNode")
			expect(state.Count).to.equal(1)
		end)

		it("undo of an update restores the previous values; delete undo restores the same ids", function()
			local state = WorldState.New()
			local record = create(state, { part(state) })[1]
			local applied = update(state, record, { Name = "Moved", Position = Vector3.new(20, 5, 0) })
			local inverse = ArchitectHistory.Invert({ Label = "Edit", Ops = applied })
			assert(WorldState.Apply(state, inverse.Ops), "undo update")
			local restored = WorldState.Get(state, record.Id) :: NodeRecord
			expect(restored.Name).to.equal("Part")
			expect(restored.Position).to.equal(record.Position)

			local deleted = WorldState.Apply(state, { { Kind = "Delete", Records = { restored } } })
			assert(deleted, "delete")
			assert(
				WorldState.Apply(state, ArchitectHistory.Invert({ Label = "Delete", Ops = deleted }).Ops),
				"undo delete"
			)
			expect(WorldState.Get(state, record.Id) ~= nil).to.equal(true)
		end)

		it("a new edit clears redo, and history stays within its bounds", function()
			local history = ArchitectHistory.New()
			ArchitectHistory.PushRedo(history, { Label = "x", Ops = {} })
			ArchitectHistory.Record(history, { Label = "y", Ops = {} })
			expect(#history.Redo).to.equal(0)
			for _ = 1, Limits.HistoryDepth + 10 do
				ArchitectHistory.Record(history, { Label = "z", Ops = {} })
			end
			expect(#history.Undo).to.equal(Limits.HistoryDepth)
			local big = {}
			for index = 1, Limits.HistoryNodeBudget + 1 do
				big[index] = ArchitectRecord.Default("Part")
			end
			ArchitectHistory.Record(history, { Label = "huge", Ops = { { Kind = "Create", Records = big } } })
			expect(history.Cost <= Limits.HistoryNodeBudget).to.equal(true)
		end)
	end)
end
