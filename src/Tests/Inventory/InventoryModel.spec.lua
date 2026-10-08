--!strict
-- Covers Shared/Inventory/InventoryModel.lua -- the pure arithmetic every inventory write goes through.
-- Driven with a FAKE Context so the rules (stack size, slot limits, carry caps, partial adds, orphans)
-- are checked on their own, with no catalog, roster or player involved. A duplication or overflow bug
-- lives here, which is why this is the file with the most cases.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryModel = require(ReplicatedStorage.Shared.Inventory.InventoryModel)

type Info = InventoryModel.ItemInfo

-- Two sections: "Bag" holds 4 slots, "Tiny" holds 1.
local ITEMS: { [string]: Info } = {
	Ore = { Section = "Bag", MaxStack = 10 },
	Gem = { Section = "Bag", MaxStack = 1 },
	Fuel = { Section = "Bag", MaxStack = 100, MaxCarry = 100 },
	Charm = { Section = "Tiny", MaxStack = 5 },
}
local LIMITS: { [string]: number } = { Bag = 4, Tiny = 1 }

local ctx: InventoryModel.Context = {
	Resolve = function(itemId: string): Info?
		return ITEMS[itemId]
	end,
	SlotLimit = function(section: string): number
		return LIMITS[section] or 0
	end,
}

return function()
	describe("InventoryModel.Add", function()
		it("adds a whole stack and records first-acquired order", function()
			local state = InventoryModel.New()
			expect(InventoryModel.Add(state, ctx, "Ore", 7)).to.equal(7)
			expect(InventoryModel.Add(state, ctx, "Gem", 1)).to.equal(1)
			expect(InventoryModel.Count(state, "Ore")).to.equal(7)
			expect(state.Order[1]).to.equal("Ore")
			expect(state.Order[2]).to.equal("Gem")
		end)

		it("does not duplicate an item in the order when it is added twice", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 3)
			InventoryModel.Add(state, ctx, "Ore", 3)
			expect(#state.Order).to.equal(1)
			expect(InventoryModel.Count(state, "Ore")).to.equal(6)
		end)

		it("spends ceil(count / MaxStack) slots", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 11)
			expect(InventoryModel.SlotsUsed(state, ctx, "Bag")).to.equal(2)
			InventoryModel.Add(state, ctx, "Ore", 9)
			expect(InventoryModel.SlotsUsed(state, ctx, "Bag")).to.equal(2)
			InventoryModel.Add(state, ctx, "Ore", 1)
			expect(InventoryModel.SlotsUsed(state, ctx, "Bag")).to.equal(3)
		end)

		it("takes only what fits when the section is nearly full, and says so", function()
			local state = InventoryModel.New()
			-- 3 slots of gems leaves one slot: 10 ore fit, the 11th does not.
			InventoryModel.Add(state, ctx, "Gem", 3)
			local added, reason = InventoryModel.Add(state, ctx, "Ore", 25)
			expect(added).to.equal(10)
			expect(reason).to.equal("Partial")
			expect(InventoryModel.Count(state, "Ore")).to.equal(10)
		end)

		it("fills the unused tail of an existing stack before spending a new slot", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Gem", 3)
			InventoryModel.Add(state, ctx, "Ore", 4)
			-- The last slot is spent on Ore, but its stack has 6 spare units.
			expect(InventoryModel.RoomFor(state, ctx, "Ore")).to.equal(6)
			expect(InventoryModel.Add(state, ctx, "Ore", 6)).to.equal(6)
			expect(InventoryModel.Add(state, ctx, "Ore", 1)).to.equal(0)
		end)

		it("reports NoRoom when the section is full", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Gem", 4)
			local added, reason = InventoryModel.Add(state, ctx, "Ore", 1)
			expect(added).to.equal(0)
			expect(reason).to.equal("NoRoom")
		end)

		it("honours a per-item carry cap that is lower than the slots allow", function()
			local state = InventoryModel.New()
			local added, reason = InventoryModel.Add(state, ctx, "Fuel", 250)
			expect(added).to.equal(100)
			expect(reason).to.equal("Partial")
			expect(InventoryModel.RoomFor(state, ctx, "Fuel")).to.equal(0)
		end)

		it("refuses an unknown item", function()
			local state = InventoryModel.New()
			local added, reason = InventoryModel.Add(state, ctx, "Nope", 1)
			expect(added).to.equal(0)
			expect(reason).to.equal("UnknownItem")
			expect(next(state.Items)).to.equal(nil)
		end)

		it("refuses zero, negative, fractional and NaN counts", function()
			local state = InventoryModel.New()
			for _, bad in { 0, -3, 1.5, 0 / 0, math.huge } do
				local added, reason = InventoryModel.Add(state, ctx, "Ore", bad)
				expect(added).to.equal(0)
				expect(reason).to.equal("BadCount")
			end
			expect(next(state.Items)).to.equal(nil)
		end)

		it("keeps each section's slots separate", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Gem", 4)
			expect(InventoryModel.Add(state, ctx, "Charm", 5)).to.equal(5)
			expect(InventoryModel.SlotsUsed(state, ctx, "Tiny")).to.equal(1)
		end)
	end)

	describe("InventoryModel.Remove", function()
		it("removes part of a stack", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 8)
			expect(InventoryModel.Remove(state, "Ore", 3)).to.equal(3)
			expect(InventoryModel.Count(state, "Ore")).to.equal(5)
		end)

		it("clears the entry and its order slot when the stack empties", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 2)
			InventoryModel.Add(state, ctx, "Gem", 1)
			expect(InventoryModel.Remove(state, "Ore", 2)).to.equal(2)
			expect(state.Items.Ore).to.equal(nil)
			expect(#state.Order).to.equal(1)
			expect(state.Order[1]).to.equal("Gem")
		end)

		it("removes only what is held when asked for more", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 2)
			expect(InventoryModel.Remove(state, "Ore", 50)).to.equal(2)
			expect(InventoryModel.Count(state, "Ore")).to.equal(0)
		end)

		it("removes nothing for an item not held or a bad count", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 2)
			expect(InventoryModel.Remove(state, "Gem", 1)).to.equal(0)
			expect(InventoryModel.Remove(state, "Ore", -1)).to.equal(0)
			expect(InventoryModel.Remove(state, "Ore", 0.5)).to.equal(0)
			expect(InventoryModel.Count(state, "Ore")).to.equal(2)
		end)

		it("frees the slots it released", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Gem", 4)
			InventoryModel.Remove(state, "Gem", 2)
			expect(InventoryModel.Add(state, ctx, "Ore", 10)).to.equal(10)
		end)
	end)

	describe("InventoryModel.Decode", function()
		it("returns an empty state for anything that is not a table", function()
			for _, raw in { false, 5, "x" } do
				local state = InventoryModel.Decode(raw)
				expect(next(state.Items)).to.equal(nil)
				expect(#state.Order).to.equal(0)
			end
			expect(#InventoryModel.Decode(nil).Order).to.equal(0)
		end)

		it("round-trips an encoded state", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 7)
			InventoryModel.Add(state, ctx, "Gem", 2)
			local decoded = InventoryModel.Decode(InventoryModel.Encode(state))
			expect(decoded.Items.Ore).to.equal(7)
			expect(decoded.Items.Gem).to.equal(2)
			expect(decoded.Order[1]).to.equal("Ore")
			expect(decoded.Order[2]).to.equal("Gem")
		end)

		it("drops negative, zero, non-numeric and non-string entries and floors fractions", function()
			local decoded = InventoryModel.Decode({
				Items = { Ore = 3.9, Gem = -2, Fuel = 0, Charm = "many", [5] = 4 },
				Order = { "Ore", "Gem" },
			})
			expect(decoded.Items.Ore).to.equal(3)
			expect(decoded.Items.Gem).to.equal(nil)
			expect(decoded.Items.Fuel).to.equal(nil)
			expect(decoded.Items.Charm).to.equal(nil)
			expect(#decoded.Order).to.equal(1)
		end)

		it("clamps an absurd count and an over-long id", function()
			local longId = string.rep("x", 200)
			local decoded = InventoryModel.Decode({ Items = { Ore = 9e12, [longId] = 1 }, Order = {} }, 64, 1000)
			expect(decoded.Items.Ore).to.equal(1000)
			expect(decoded.Items[longId]).to.equal(nil)
		end)

		it("rebuilds an Order that omits, repeats or invents ids", function()
			local decoded = InventoryModel.Decode({
				Items = { Ore = 1, Gem = 1, Charm = 1 },
				Order = { "Gem", "Gem", "Ghost" },
			})
			expect(#decoded.Order).to.equal(3)
			expect(decoded.Order[1]).to.equal("Gem")
			-- The ones it was missing are appended in sorted order, so every server repairs it the same way.
			expect(decoded.Order[2]).to.equal("Charm")
			expect(decoded.Order[3]).to.equal("Ore")
		end)

		it("keeps an unknown id as an orphan that costs no slots and is not listed", function()
			local decoded = InventoryModel.Decode({ Items = { Relic = 40, Ore = 1 }, Order = { "Relic", "Ore" } })
			expect(decoded.Items.Relic).to.equal(40)
			expect(InventoryModel.SlotsUsed(decoded, ctx, "Bag")).to.equal(1)
			local owned = InventoryModel.OwnedIds(decoded, ctx)
			expect(#owned).to.equal(1)
			expect(owned[1]).to.equal("Ore")
			-- And an admin can still clear it.
			expect(InventoryModel.Remove(decoded, "Relic", 40)).to.equal(40)
		end)
	end)

	describe("InventoryModel.OwnedIds", function()
		it("lists by section in acquisition order", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Gem", 1)
			InventoryModel.Add(state, ctx, "Charm", 1)
			InventoryModel.Add(state, ctx, "Ore", 1)
			local bag = InventoryModel.OwnedIds(state, ctx, "Bag")
			expect(#bag).to.equal(2)
			expect(bag[1]).to.equal("Gem")
			expect(bag[2]).to.equal("Ore")
			expect(#InventoryModel.OwnedIds(state, ctx)).to.equal(3)
		end)
	end)

	describe("InventoryModel.Copy", function()
		it("is independent of the original", function()
			local state = InventoryModel.New()
			InventoryModel.Add(state, ctx, "Ore", 5)
			local copy = InventoryModel.Copy(state)
			InventoryModel.Remove(copy, "Ore", 5)
			InventoryModel.Add(copy, ctx, "Gem", 1)
			expect(InventoryModel.Count(state, "Ore")).to.equal(5)
			expect(InventoryModel.Count(state, "Gem")).to.equal(0)
			expect(#state.Order).to.equal(1)
		end)
	end)
end
