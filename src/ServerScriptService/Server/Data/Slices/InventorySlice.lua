--!strict
--[[
	InventorySlice.lua

	Owns: the `inventory` profile field -- what a player carries -- as persisted. The record is Shared/Inventory/InventoryModel's
	`{ Items, Order }`; this slice is only the profile's door to that model's own Copy/Encode/Decode (InventoryModel was the one
	domain that always owned its codec, which is why it never drifted), plus the two legacy migrations that feed it. Moved here
	out of PlayerDataSystem (coworking plan W5, 2026-10-25) unchanged; the round-trip corpus pins it to the byte.

	DEFAULTS. A brand-new player is carrying nothing.

	DECODE is InventoryModel.Decode's whole defensive posture (counts floored and clamped, junk keys dropped, Order rebuilt). It
	does NOT consult the item catalog: an id the catalog no longer knows is an orphan and is kept, because deleting a player's data
	over a content rename cannot be undone. A legacy `blimpFuel` field on a record that somehow skipped the v10 -> v11 migration is
	ignored.

	MIGRATIONS. v8 -> v9 backfilled `blimpFuel` (the Blimp Fuel System's carried coal/water, empty is honest) onto older records.
	v10 -> v11 is the Inventory System: a carried `blimpFuel` pair becomes two entries in the new `inventory` record and the old
	field is removed, since a carried resource is an item like any other now. Counts are floored and any non-number or non-positive
	value dropped. A record that already has an `inventory` keeps it and only loses the stale `blimpFuel`; nothing is summed into an
	existing inventory, so running this twice (or on a record a rollback half-migrated) cannot duplicate coal.

	Does not own: what an item is or what a cap is (Shared/Inventory), or who may add one (InventorySystem -- the only writer).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)
local InventoryModel = require(ReplicatedStorage.Shared.Inventory.InventoryModel)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

return ProfileSlice.Define({
	Name = "Inventory",
	Fields = { "inventory" },

	Default = function(_userId: number)
		return { inventory = InventoryModel.New() }
	end,

	Copy = function(profile: any)
		return { inventory = InventoryModel.Copy(profile.inventory) }
	end,

	Encode = function(profile: any)
		return { inventory = InventoryModel.Encode(profile.inventory) }
	end,

	Decode = function(raw: { [string]: any }, _userId: number)
		return {
			inventory = InventoryModel.Decode(
				raw.inventory,
				InventoryConstants.MaxItemIdLength,
				InventoryConstants.MaxStoredCount
			),
		}
	end,

	Migrations = {
		-- v8 -> v9: backfills `blimpFuel` onto any record saved before it existed ("empty is honest").
		[8] = function(record: { [string]: any }): { [string]: any }
			local profile = record.Profile
			if Schema.IsTable(profile) then
				local profileTable = profile :: { [string]: any }
				if profileTable.blimpFuel == nil then
					profileTable.blimpFuel = { Coal = 0, Water = 0 }
				end
			end
			return record
		end,

		-- v10 -> v11: `blimpFuel` becomes inventory entries and the old field is removed.
		[10] = function(record: { [string]: any }): { [string]: any }
			local profile = record.Profile
			if Schema.IsTable(profile) then
				local profileTable = profile :: { [string]: any }
				if profileTable.inventory == nil then
					local items: { [string]: number } = {}
					local order: { string } = {}
					local legacy = profileTable.blimpFuel
					if Schema.IsTable(legacy) then
						local legacyTable = legacy :: { [string]: any }
						for _, resource in { "Coal", "Water" } do
							local amount = legacyTable[resource]
							if Schema.IsNumber(amount) then
								local whole = math.floor(amount :: number)
								if whole == whole and whole >= 1 then
									items[resource] = whole
									table.insert(order, resource)
								end
							end
						end
					end
					profileTable.inventory = { Items = items, Order = order }
				end
				profileTable.blimpFuel = nil
			end
			return record
		end,
	},
})
