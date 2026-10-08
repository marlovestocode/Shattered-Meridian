--!strict
--[[
	InventoryModel.lua

	Owns: the inventory's arithmetic, and nothing else. A State is `{ Items = { [itemId] = count },
	Order = { itemId } }`; every function here is a pure transform over one, taking the item rules as a
	Context argument. No Players, no DataStore, no remotes, no requires -- which is the whole point: the
	capacity rules are the part of an inventory that has to be right (a duplication bug lives here), so
	they are exercised headlessly by Tests/Inventory/InventoryModel.spec.lua with a fake Context.

	STACKS, NOT A GRID. An item costs ceil(count / MaxStack) slots from its section's limit. There is no
	slot index to corrupt, no positions to migrate, and no "move item to slot" exploit surface.

	PARTIAL ADDS ARE THE NORMAL ANSWER. Add returns how many units fit, which may be fewer than asked or
	zero. It never throws away the remainder silently: the caller holds the rest and decides what happens
	to it.

	UNKNOWN ITEMS ARE KEPT, NOT DELETED (Decode). A saved id the Context cannot resolve (an item whose
	catalog entry or weapon model was later removed) is an ORPHAN: retained in the record, ignored by
	every capacity and listing function. Deleting a player's data because content was renamed cannot be
	undone; hiding it can.

	Does not own: what an item is (ItemCatalog), where a State is stored (PlayerDataSystem), or who may
	change it (InventorySystem).
]]

export type ItemId = string

export type State = {
	Items: { [ItemId]: number },
	Order: { ItemId },
}

-- The part of an item definition the arithmetic needs. ItemCatalog.ItemDef satisfies it structurally.
export type ItemInfo = {
	Section: string,
	MaxStack: number,
	MaxCarry: number?,
}

export type Context = {
	-- nil for an id that is not (or is no longer) a real item.
	Resolve: (itemId: ItemId) -> ItemInfo?,
	SlotLimit: (section: string) -> number,
}

local InventoryModel = {}

-- Defaults for Decode, overridable so the module needs no constants require. InventoryConstants'
-- MaxItemIdLength / MaxStoredCount are passed by PlayerDataSystem.
local DEFAULT_MAX_ID_LENGTH = 64
local DEFAULT_MAX_COUNT = 1000000

function InventoryModel.New(): State
	return { Items = {}, Order = {} }
end

function InventoryModel.Copy(state: State): State
	return { Items = table.clone(state.Items), Order = table.clone(state.Order) }
end

-- The persisted shape. A copy, so a caller can never mutate the live State through it.
function InventoryModel.Encode(state: State): { [string]: any }
	return { Items = table.clone(state.Items), Order = table.clone(state.Order) }
end

local function isWholePositive(value: unknown): boolean
	return typeof(value) == "number"
		and value == value
		and value >= 1
		and value < math.huge
		and value == math.floor(value)
end

-- Defensive decode of an untrusted record (a DataStore read). Always returns a valid State: bad entries
-- are dropped, counts are floored and clamped, and Order is rebuilt so it names exactly the items held,
-- once each. Never errors.
function InventoryModel.Decode(raw: unknown, maxIdLength: number?, maxCount: number?): State
	local idLimit = maxIdLength or DEFAULT_MAX_ID_LENGTH
	local countLimit = maxCount or DEFAULT_MAX_COUNT
	local state = InventoryModel.New()
	if typeof(raw) ~= "table" then
		return state
	end
	local record = raw :: { [string]: any }

	if typeof(record.Items) == "table" then
		for id, count in record.Items :: { [unknown]: unknown } do
			if typeof(id) == "string" and #id >= 1 and #id <= idLimit and typeof(count) == "number" then
				local whole = math.floor(count :: number)
				if whole == whole and whole >= 1 then
					state.Items[id] = math.min(whole, countLimit)
				end
			end
		end
	end

	local seen: { [string]: boolean } = {}
	if typeof(record.Order) == "table" then
		for _, id in ipairs(record.Order :: { unknown }) do
			if typeof(id) == "string" and state.Items[id] ~= nil and not seen[id] then
				seen[id] = true
				table.insert(state.Order, id)
			end
		end
	end

	-- Anything held but missing from Order is appended in sorted order, so a repaired record is the same
	-- on every server.
	local missing: { string } = {}
	for id in state.Items do
		if not seen[id] then
			table.insert(missing, id)
		end
	end
	table.sort(missing)
	for _, id in missing do
		table.insert(state.Order, id)
	end

	return state
end

function InventoryModel.Count(state: State, itemId: ItemId): number
	return state.Items[itemId] or 0
end

-- Slots spent in `section` by the items the Context recognises. Orphans cost nothing.
function InventoryModel.SlotsUsed(state: State, ctx: Context, section: string): number
	local used = 0
	for id, count in state.Items do
		local info = ctx.Resolve(id)
		if info and info.Section == section then
			used += math.ceil(count / math.max(1, info.MaxStack))
		end
	end
	return used
end

-- How many MORE units of `itemId` this State could take: bounded by the item's own carry cap and by the
-- room left in its section (the unfilled tail of its last stack plus every free slot).
function InventoryModel.RoomFor(state: State, ctx: Context, itemId: ItemId): number
	local info = ctx.Resolve(itemId)
	if not info then
		return 0
	end
	local maxStack = math.max(1, info.MaxStack)
	local current = state.Items[itemId] or 0
	local freeSlots = math.max(0, ctx.SlotLimit(info.Section) - InventoryModel.SlotsUsed(state, ctx, info.Section))
	local ownSlots = math.ceil(current / maxStack)
	local slotRoom = (ownSlots + freeSlots) * maxStack - current
	local carryRoom = if info.MaxCarry ~= nil then info.MaxCarry - current else math.huge
	return math.max(0, math.min(slotRoom, carryRoom))
end

-- Adds up to `count` units. Returns (added, reason): `added` is how many actually went in (0..count);
-- `reason` is nil on a full add, otherwise "Partial", "NoRoom", "UnknownItem" or "BadCount".
function InventoryModel.Add(state: State, ctx: Context, itemId: ItemId, count: number): (number, string?)
	if not isWholePositive(count) then
		return 0, "BadCount"
	end
	if not ctx.Resolve(itemId) then
		return 0, "UnknownItem"
	end
	local room = InventoryModel.RoomFor(state, ctx, itemId)
	if room <= 0 then
		return 0, "NoRoom"
	end
	local added = math.min(count, room)
	local current = state.Items[itemId] or 0
	if current == 0 then
		table.insert(state.Order, itemId)
	end
	state.Items[itemId] = current + added
	return added, if added < count then "Partial" else nil
end

-- Removes up to `count` units; returns how many were actually removed (0 if none are held or the count
-- is not a whole positive number). Works on orphans too -- an admin must be able to clear one.
function InventoryModel.Remove(state: State, itemId: ItemId, count: number): number
	if not isWholePositive(count) then
		return 0
	end
	local current = state.Items[itemId]
	if current == nil then
		return 0
	end
	local removed = math.min(current, count)
	local left = current - removed
	if left <= 0 then
		state.Items[itemId] = nil
		local index = table.find(state.Order, itemId)
		if index then
			table.remove(state.Order, index)
		end
	else
		state.Items[itemId] = left
	end
	return removed
end

-- Item ids the Context recognises, in acquisition order, optionally limited to one section.
function InventoryModel.OwnedIds(state: State, ctx: Context, section: string?): { ItemId }
	local result: { ItemId } = {}
	for _, id in state.Order do
		local info = ctx.Resolve(id)
		if info and (section == nil or info.Section == section) then
			table.insert(result, id)
		end
	end
	return result
end

return InventoryModel
