--!strict
--[[
	ItemCatalog.lua

	Owns: what every item IS -- its id, name, section, rarity, how it stacks and how much of it a player
	may carry. The single table behind both the server's capacity maths and the client's cards, so the two
	can never describe an item differently.

	ADDING AN ITEM IS ONE `define` BELOW. Pick the section, the rarity and the stack size; nothing else in
	the inventory changes. An item with no source in the game yet does not belong here -- a catalog entry
	with nothing that can grant it is dead content wearing a finished-looking header.

	WEAPONS ARE DERIVED, NOT AUTHORED. Every weapon in Shared/Combat/WeaponRoster is the item
	"Weapon/<WeaponId>" (ItemCatalog.WeaponItemId), synthesised on demand, so adding a weapon stays what
	WeaponRoster's header says it is -- a Studio action, not a code change. Whether a given weapon id
	actually exists in the roster is the SERVER's question (InventorySystem), not this module's: this file
	is shared with clients that never read Workspace.Weapons.

	Does not own: capacity arithmetic (InventoryModel), section structure and rarity grades
	(InventoryConstants), or who may hold what (InventorySystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)

export type ItemDef = {
	Id: string,
	DisplayName: string,
	Section: InventoryConstants.SectionId,
	Rarity: InventoryConstants.Rarity,
	Description: string,
	-- Units per slot. A section's slot limit is spent in ceil(count / MaxStack) per item.
	MaxStack: number,
	-- A hard cap on the TOTAL carried, across all stacks. nil: limited only by slots.
	MaxCarry: number?,
	-- Whether the owner may destroy it from the inventory screen.
	Discardable: boolean,
	-- Set only for the item a weapon id maps to.
	WeaponId: string?,
}

local ItemCatalog = {}

local items: { [string]: ItemDef } = {}
local definitionOrder: { string } = {}

local function define(def: ItemDef): ()
	assert(items[def.Id] == nil, `ItemCatalog: duplicate item id {def.Id}`)
	assert(InventoryConstants.SectionById[def.Section] ~= nil, `ItemCatalog: {def.Id} names an unknown section`)
	assert(InventoryConstants.RarityRank[def.Rarity] ~= nil, `ItemCatalog: {def.Id} names an unknown rarity`)
	assert(
		def.MaxStack >= 1 and def.MaxStack == math.floor(def.MaxStack),
		`ItemCatalog: {def.Id} needs a whole MaxStack`
	)
	assert(#def.Id <= InventoryConstants.MaxItemIdLength, `ItemCatalog: {def.Id} is longer than a valid id`)
	items[def.Id] = def
	table.insert(definitionOrder, def.Id)
end

-- The two carried resources. Their cap is the blimp tank's own carry cap (BlimpConstants.Carry), read
-- here rather than restated, so pocket size and tank size are still retuned together -- that coupling is
-- the whole reason BlimpConstants.Carry's header gives for living where it does. One stack holds the
-- whole cap, so each takes a single Resources slot.
define({
	Id = "Coal",
	DisplayName = "Coal",
	Section = "Resources",
	Rarity = "Mortal",
	Description = "Fuel for a blimp's engines. Mined from coal deposits and loaded at a furnace.",
	MaxStack = BlimpConstants.Carry.CoalCap,
	MaxCarry = BlimpConstants.Carry.CoalCap,
	Discardable = true,
})

define({
	Id = "Water",
	DisplayName = "Water",
	Section = "Resources",
	Rarity = "Mortal",
	Description = "Fills a blimp's water tank. Collected at water sources.",
	MaxStack = BlimpConstants.Carry.WaterCap,
	MaxCarry = BlimpConstants.Carry.WaterCap,
	Discardable = true,
})

-- Weapon defs are cheap but not free (a table per call) and are asked for once per card per snapshot, so
-- they are memoised. Bounded by the number of weapons that exist.
local weaponDefs: { [string]: ItemDef } = {}

function ItemCatalog.WeaponItemId(weaponId: string): string
	return InventoryConstants.WeaponItemPrefix .. weaponId
end

-- The weapon id behind an item id, or nil if it is not a weapon item.
function ItemCatalog.WeaponIdOf(itemId: string): string?
	local prefix = InventoryConstants.WeaponItemPrefix
	if string.sub(itemId, 1, #prefix) ~= prefix then
		return nil
	end
	local weaponId = string.sub(itemId, #prefix + 1)
	if weaponId == "" then
		return nil
	end
	return weaponId
end

local function weaponDef(itemId: string, weaponId: string): ItemDef
	local cached = weaponDefs[itemId]
	if cached then
		return cached
	end
	local def: ItemDef = {
		Id = itemId,
		DisplayName = weaponId,
		Section = "Armaments",
		Rarity = "Mortal",
		Description = "A weapon you have taken up. Draw it with the weapon key.",
		MaxStack = 1,
		MaxCarry = 1,
		-- A weapon is never destroyed from the screen: owning one only ever grows, and losing one by a
		-- misclick is not a risk worth a button.
		Discardable = false,
		WeaponId = weaponId,
	}
	weaponDefs[itemId] = def
	return def
end

-- The definition behind an item id, or nil for an id the catalog does not know. A weapon id resolves for
-- ANY name after the prefix; the server separately checks it against the roster.
function ItemCatalog.Resolve(itemId: string): ItemDef?
	if typeof(itemId) ~= "string" or #itemId == 0 or #itemId > InventoryConstants.MaxItemIdLength then
		return nil
	end
	local authored = items[itemId]
	if authored then
		return authored
	end
	local weaponId = ItemCatalog.WeaponIdOf(itemId)
	if weaponId then
		return weaponDef(itemId, weaponId)
	end
	return nil
end

-- Every authored (non-weapon) item, in definition order.
function ItemCatalog.Authored(): { ItemDef }
	local result: { ItemDef } = {}
	for _, id in definitionOrder do
		table.insert(result, items[id])
	end
	return result
end

-- Display order within a section: highest rarity first, then name. Stable for equal keys by id, so two
-- clients always draw the same list.
function ItemCatalog.Compare(a: ItemDef, b: ItemDef): boolean
	local rankA = InventoryConstants.RarityRank[a.Rarity]
	local rankB = InventoryConstants.RarityRank[b.Rarity]
	if rankA ~= rankB then
		return rankA > rankB
	end
	if a.DisplayName ~= b.DisplayName then
		return a.DisplayName < b.DisplayName
	end
	return a.Id < b.Id
end

return ItemCatalog
