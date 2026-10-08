--!strict
--[[
	InventoryConstants.lua

	Owns: the inventory's structure and tuning -- the section list (what the screen's tab strip is made
	of, and how many slots each holds), the rarity grades, the remote names and payload shapes, and the
	rate limits. docs/design/inventory.md is the blueprint these numbers belong to.

	SLOT LIMITS ARE PLACEHOLDERS TO TUNE IN PLAYTEST, not derived figures. They live here, in one table,
	so tuning one is a one-line change that touches no logic.

	A SECTION WITH HideWhenEmpty HAS NO TAB UNTIL IT HOLDS SOMETHING. The structure (Materials,
	Consumables, Relics) exists so adding the first item of that kind is a catalog entry and nothing
	else, without the screen shipping three empty tabs in the meantime.

	Does not own: what any item IS (Shared/Inventory/ItemCatalog.lua), the arithmetic (InventoryModel.lua,
	pure), or the per-player state (Server/Systems/InventorySystem.lua).
]]

local InventoryConstants = {}

export type SectionId = "Armaments" | "Resources" | "Materials" | "Consumables" | "Relics"

-- Cultivation grading, lowest to highest. Shown as a text label AS WELL AS a colour
-- (ui-ux-philosophy.md: colour is never the only signal).
export type Rarity = "Mortal" | "Spirit" | "Earth" | "Heaven" | "Immortal"

export type SectionDef = {
	Id: SectionId,
	DisplayName: string,
	-- One line under the section's name on the screen.
	Blurb: string,
	-- Stack slots this section holds. An item occupies ceil(count / MaxStack) of them.
	Slots: number,
	HideWhenEmpty: boolean,
}

local sections: { SectionDef } = {
	{
		Id = "Armaments",
		DisplayName = "Armaments",
		Blurb = "Weapons you have taken up.",
		Slots = 24,
		HideWhenEmpty = false,
	},
	{
		Id = "Resources",
		DisplayName = "Resources",
		Blurb = "Gathered goods, carried until you put them to use.",
		Slots = 12,
		HideWhenEmpty = false,
	},
	{
		Id = "Materials",
		DisplayName = "Materials",
		Blurb = "Inputs for making and refining.",
		Slots = 40,
		HideWhenEmpty = true,
	},
	{
		Id = "Consumables",
		DisplayName = "Consumables",
		Blurb = "Pills, elixirs and talismans.",
		Slots = 20,
		HideWhenEmpty = true,
	},
	{
		Id = "Relics",
		DisplayName = "Relics",
		Blurb = "Key items and artefacts of consequence.",
		Slots = 12,
		HideWhenEmpty = true,
	},
}

InventoryConstants.Sections = sections

local sectionById: { [string]: SectionDef } = {}
for _, section in sections do
	sectionById[section.Id] = section
end
InventoryConstants.SectionById = sectionById

-- Lowest to highest. The index is the rank (a sort key and a "brighter than" test).
local rarityOrder: { Rarity } = { "Mortal", "Spirit", "Earth", "Heaven", "Immortal" }
InventoryConstants.RarityOrder = rarityOrder

local rarityRank: { [string]: number } = {}
for index, rarity in rarityOrder do
	rarityRank[rarity] = index
end
InventoryConstants.RarityRank = rarityRank

-- Server -> owning client: the whole inventory, every time. It is a few dozen short entries at most, and
-- a client that missed one push (joined late, dropped packet) is corrected by the next with no delta
-- bookkeeping to get wrong. Client -> server: one RemoteFunction carrying INTENTS only.
InventoryConstants.RemoteNames = {
	Snapshot = "Inventory_Snapshot",
	Action = "Inventory_Action",
}

InventoryConstants.Network = {
	-- Bounds the Action remote. A discard is a deliberate click, so this is generous.
	MaxActionsPerSecondPerPlayer = 6,
}

-- An item id is a short ASCII-ish key. Longer than this is not an id, it is an attack on the decoder or
-- the wire.
InventoryConstants.MaxItemIdLength = 64

-- The most of one item a decoded record may hold. A hand-edited or corrupted record claiming a billion
-- is clamped rather than trusted.
InventoryConstants.MaxStoredCount = 1000000

-- Weapons are not authored in the catalog: every weapon in WeaponRoster is the item "Weapon/<WeaponId>".
InventoryConstants.WeaponItemPrefix = "Weapon/"

export type SnapshotEntry = {
	ItemId: string,
	Count: number,
}

export type SnapshotSection = {
	Id: SectionId,
	-- Slots in use / slots the section holds, computed by the SERVER so a client never re-derives capacity
	-- with a resolver that might disagree.
	Used: number,
	Limit: number,
	-- In the player's acquisition order.
	Entries: { SnapshotEntry },
}

export type SnapshotPayload = {
	-- Monotonic per player per session; lets a client drop an out-of-order snapshot.
	Revision: number,
	Sections: { SnapshotSection },
}

-- "Discard" destroys held items; "Sync" asks the server to push this player's snapshot again, which is how
-- a client that connected after the profile loaded (and so missed the first push) catches up. Sync changes
-- nothing server-side.
export type ActionKind = "Discard" | "Sync"

export type ActionResult = {
	Success: boolean,
	-- Reason CODE, not a sentence: "RateLimited", "BadRequest", "UnknownItem", "NotOwned", "NotDiscardable",
	-- "ProfileNotLoaded", "InternalError".
	Reason: string?,
	Removed: number?,
}

return InventoryConstants
