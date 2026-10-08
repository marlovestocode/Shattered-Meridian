--!strict
-- Covers the pure edges of Client/Inventory/InventoryClient.lua: what it will accept off the wire, and
-- the words a refusal is shown in. The listener, key and Escape wiring need a live client and are checked
-- in Studio.

local StarterPlayer = game:GetService("StarterPlayer")

local InventoryClient = require(StarterPlayer.StarterPlayerScripts.Client.Inventory.InventoryClient)

local function validPayload(): any
	return {
		Revision = 3,
		Sections = {
			{
				Id = "Resources",
				Used = 1,
				Limit = 12,
				Entries = { { ItemId = "Coal", Count = 10 } },
			},
		},
	}
end

return function()
	describe("InventoryClient.IsValidSnapshot", function()
		it("accepts a well-formed snapshot, including an empty one", function()
			expect(InventoryClient.IsValidSnapshot(validPayload())).to.equal(true)
			expect(InventoryClient.IsValidSnapshot({ Revision = 0, Sections = {} })).to.equal(true)
		end)

		it("rejects anything that is not a table", function()
			for _, bad in { false, 4, "snapshot" } do
				expect(InventoryClient.IsValidSnapshot(bad)).to.equal(false)
			end
			expect(InventoryClient.IsValidSnapshot(nil)).to.equal(false)
		end)

		it("rejects a missing or mistyped revision or section list", function()
			expect(InventoryClient.IsValidSnapshot({ Sections = {} })).to.equal(false)
			expect(InventoryClient.IsValidSnapshot({ Revision = "1", Sections = {} })).to.equal(false)
			expect(InventoryClient.IsValidSnapshot({ Revision = 1 })).to.equal(false)
		end)

		it("rejects a section or entry with a wrong-typed field", function()
			local noId = validPayload()
			noId.Sections[1].Id = 5
			expect(InventoryClient.IsValidSnapshot(noId)).to.equal(false)

			local noLimit = validPayload()
			noLimit.Sections[1].Limit = nil
			expect(InventoryClient.IsValidSnapshot(noLimit)).to.equal(false)

			local badEntry = validPayload()
			badEntry.Sections[1].Entries[1].Count = "ten"
			expect(InventoryClient.IsValidSnapshot(badEntry)).to.equal(false)

			local nonTableEntry = validPayload()
			nonTableEntry.Sections[1].Entries[1] = "Coal"
			expect(InventoryClient.IsValidSnapshot(nonTableEntry)).to.equal(false)
		end)
	end)

	describe("InventoryClient.DescribeFailure", function()
		it("words every reason the server can return", function()
			for _, reason in { "NotDiscardable", "NotOwned", "UnknownItem", "ProfileNotLoaded", "RateLimited" } do
				local text = InventoryClient.DescribeFailure(reason)
				expect(text ~= reason).to.equal(true)
				expect(#text > 0).to.equal(true)
			end
		end)

		it("shows an unrecognised reason rather than a blank line", function()
			expect(InventoryClient.DescribeFailure("SomethingNew")).to.equal("Failed: SomethingNew")
			expect(InventoryClient.DescribeFailure(nil)).to.equal("Failed: Unknown")
		end)
	end)
end
