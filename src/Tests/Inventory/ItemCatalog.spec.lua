--!strict
-- Covers Shared/Inventory/ItemCatalog.lua and the structure it validates against in InventoryConstants.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)
local ItemCatalog = require(ReplicatedStorage.Shared.Inventory.ItemCatalog)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)

return function()
	describe("ItemCatalog -- authored items", function()
		it("defines every item against a real section and rarity", function()
			for _, def in ItemCatalog.Authored() do
				expect(InventoryConstants.SectionById[def.Section]).to.be.ok()
				expect(InventoryConstants.RarityRank[def.Rarity]).to.be.ok()
				expect(def.MaxStack >= 1).to.equal(true)
				expect(def.MaxStack == math.floor(def.MaxStack)).to.equal(true)
				expect(#def.Id <= InventoryConstants.MaxItemIdLength).to.equal(true)
				expect(def.DisplayName ~= "").to.equal(true)
			end
		end)

		it("takes the coal and water carry caps from the blimp's own constants", function()
			local coal = ItemCatalog.Resolve("Coal")
			local water = ItemCatalog.Resolve("Water")
			assert(coal and water, "coal and water must be authored items")
			expect(coal.MaxCarry).to.equal(BlimpConstants.Carry.CoalCap)
			expect(water.MaxCarry).to.equal(BlimpConstants.Carry.WaterCap)
			expect(coal.Section).to.equal("Resources")
		end)

		it("resolves nothing for an unknown, empty or over-long id", function()
			expect(ItemCatalog.Resolve("NotAThing")).to.equal(nil)
			expect(ItemCatalog.Resolve("")).to.equal(nil)
			expect(ItemCatalog.Resolve(string.rep("a", InventoryConstants.MaxItemIdLength + 1))).to.equal(nil)
		end)
	end)

	describe("ItemCatalog -- weapons are derived", function()
		it("maps a weapon id to an item id and back", function()
			local itemId = ItemCatalog.WeaponItemId("Cutlass")
			expect(itemId).to.equal("Weapon/Cutlass")
			expect(ItemCatalog.WeaponIdOf(itemId)).to.equal("Cutlass")
			expect(ItemCatalog.WeaponIdOf("Coal")).to.equal(nil)
			expect(ItemCatalog.WeaponIdOf("Weapon/")).to.equal(nil)
		end)

		it("synthesises a one-of, undiscardable Armaments item for any weapon id", function()
			local def = ItemCatalog.Resolve("Weapon/Anything")
			assert(def, "a weapon item id must resolve")
			expect(def.Section).to.equal("Armaments")
			expect(def.MaxStack).to.equal(1)
			expect(def.MaxCarry).to.equal(1)
			expect(def.Discardable).to.equal(false)
			expect(def.WeaponId).to.equal("Anything")
		end)
	end)

	describe("ItemCatalog.Compare", function()
		it("orders higher rarity first, then name, then id", function()
			local function def(id: string, name: string, rarity: InventoryConstants.Rarity): ItemCatalog.ItemDef
				return {
					Id = id,
					DisplayName = name,
					Section = "Resources",
					Rarity = rarity,
					Description = "",
					MaxStack = 1,
					Discardable = true,
				}
			end
			local common = def("a", "Zinc", "Mortal")
			local rare = def("b", "Amber", "Heaven")
			local alsoCommon = def("c", "Ash", "Mortal")
			local sameName = def("d", "Ash", "Mortal")

			expect(ItemCatalog.Compare(rare, common)).to.equal(true)
			expect(ItemCatalog.Compare(common, rare)).to.equal(false)
			expect(ItemCatalog.Compare(alsoCommon, common)).to.equal(true)
			expect(ItemCatalog.Compare(alsoCommon, sameName)).to.equal(true)
			expect(ItemCatalog.Compare(sameName, alsoCommon)).to.equal(false)
		end)
	end)

	describe("InventoryConstants", function()
		it("ranks the rarities in their listed order", function()
			for index, rarity in InventoryConstants.RarityOrder do
				expect(InventoryConstants.RarityRank[rarity]).to.equal(index)
			end
		end)

		it("indexes every section by id with a positive slot limit", function()
			for _, section in InventoryConstants.Sections do
				expect(InventoryConstants.SectionById[section.Id]).to.equal(section)
				expect(section.Slots >= 1).to.equal(true)
			end
		end)

		it("always shows Armaments and Resources", function()
			expect(InventoryConstants.SectionById.Armaments.HideWhenEmpty).to.equal(false)
			expect(InventoryConstants.SectionById.Resources.HideWhenEmpty).to.equal(false)
		end)
	end)
end
