--!strict
-- Covers Client/UI/Screens/Inventory -- the sectioned inventory panel -- mounted for real and driven through
-- SetSnapshot, the one door the server's state comes in by.
--
-- STRUCTURE AND TEXT ONLY, like ScreenFrameScreens.spec.lua beside it: what exists, what is visible, what a
-- Computed resolved to. Roblox property names are unchecked until the code RUNS, and a screen this reactive
-- leaves most of itself unexecuted if it is only constructed -- so these cases push real snapshots through
-- every Computed. How it LOOKS is a Studio question; this checks it is not empty, wrong or throwing.
--
-- The armed Discard button is not clicked here: a GuiButton's Activated cannot be fired from a script, so
-- that edge (press, confirm, DiscardRequested) is covered by the ArmedButton component's own contract and
-- checked in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)

local InventoryScreen = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.Inventory)

type Payload = InventoryConstants.SnapshotPayload

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

-- A snapshot with every section present (as the server always sends), holding `entries` by section id.
local function snapshot(
	revision: number,
	entries: { [string]: { { ItemId: string, Count: number } } },
	used: { [string]: number }?
): Payload
	local sections: { InventoryConstants.SnapshotSection } = {}
	for _, def in InventoryConstants.Sections do
		table.insert(sections, {
			Id = def.Id,
			Used = if used then (used[def.Id] or 0) else 0,
			Limit = def.Slots,
			Entries = entries[def.Id] or {},
		})
	end
	return { Revision = revision, Sections = sections }
end

local function allTexts(root: Instance): { string }
	local result: { string } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			if descendant.Text ~= "" then
				table.insert(result, descendant.Text)
			end
		end
	end
	return result
end

local function hasText(root: Instance, wanted: string): boolean
	return table.find(allTexts(root), wanted) ~= nil
end

-- Visible AND every ancestor up to `stop` visible: a page that is toggled off hides its cards by hiding
-- itself, not them.
local function isShown(gui: Instance, stop: Instance): boolean
	local current: Instance? = gui
	while current and current ~= stop do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return true
end

local function mount(): (InventoryScreen.InventoryHandle, ScreenGui)
	local scope = Fusion.scoped(Fusion)
	local parent = fakePlayerGui()
	local handle = InventoryScreen.Mount(scope, parent)
	local gui = parent:FindFirstChild("Inventory")
	assert(gui and gui:IsA("ScreenGui"), "the Inventory ScreenGui must be mounted")
	return handle, gui
end

return function()
	describe("Inventory screen -- structure", function()
		it("mounts the banded frame with one page per section", function()
			local _, gui = mount()
			expect(gui:FindFirstChild("TabStrip", true)).to.be.ok()
			expect(gui:FindFirstChild("Body", true)).to.be.ok()
			expect(gui:FindFirstChild("Footer", true)).to.be.ok()
			for _, def in InventoryConstants.Sections do
				expect(gui:FindFirstChild("Page_" .. def.Id, true)).to.be.ok()
			end
		end)

		it("opens on the first section, and starts closed", function()
			local handle, gui = mount()
			expect(Fusion.peek(handle.IsOpen)).to.equal(false)
			local first = gui:FindFirstChild("Page_" .. InventoryConstants.Sections[1].Id, true) :: GuiObject
			expect(first.Visible).to.equal(true)
			local second = gui:FindFirstChild("Page_" .. InventoryConstants.Sections[2].Id, true) :: GuiObject
			expect(second.Visible).to.equal(false)
		end)

		it("shows the empty-state guidance before any snapshot arrives", function()
			local _, gui = mount()
			local armaments = gui:FindFirstChild("Page_Armaments", true) :: Instance
			expect(hasText(armaments, "0 / 24 slots")).to.equal(true)
			expect(hasText(armaments, "No weapons yet. Find one in the world and hold E to take it up.")).to.equal(true)
			expect(hasText(gui, "Select an item to see it here.")).to.equal(true)
		end)
	end)

	describe("Inventory screen -- snapshots", function()
		it("builds a card per entry, with its name, rarity and count", function()
			local handle, gui = mount()
			handle.SetSnapshot(snapshot(1, { Resources = { { ItemId = "Coal", Count = 120 } } }, { Resources = 1 }))

			local resources = gui:FindFirstChild("Page_Resources", true) :: Instance
			local card = resources:FindFirstChild("Item_Coal", true)
			expect(card).to.be.ok()
			expect(hasText(card :: Instance, "Coal")).to.equal(true)
			expect(hasText(card :: Instance, "MORTAL")).to.equal(true)
			expect(hasText(card :: Instance, "120")).to.equal(true)
			expect(hasText(resources, "1 / 12 slots")).to.equal(true)
		end)

		it("hides the section's empty guidance once it holds something", function()
			local handle, gui = mount()
			handle.SetSnapshot(snapshot(1, { Resources = { { ItemId = "Water", Count = 3 } } }, { Resources = 1 }))
			local resources = gui:FindFirstChild("Page_Resources", true) :: Instance
			for _, descendant in resources:GetDescendants() do
				if descendant:IsA("TextLabel") and string.find(descendant.Text, "Nothing gathered", 1, true) ~= nil then
					expect(isShown(descendant, resources)).to.equal(false)
				end
			end
		end)

		it("updates a count in place when a later snapshot changes it", function()
			local handle, gui = mount()
			handle.SetSnapshot(snapshot(1, { Resources = { { ItemId = "Coal", Count = 10 } } }, { Resources = 1 }))
			handle.SetSnapshot(snapshot(2, { Resources = { { ItemId = "Coal", Count = 75 } } }, { Resources = 1 }))
			local card = gui:FindFirstChild("Item_Coal", true) :: Instance
			expect(hasText(card, "75")).to.equal(true)
			expect(hasText(card, "10")).to.equal(false)
		end)

		it("removes a card whose item has left the inventory", function()
			local handle, gui = mount()
			handle.SetSnapshot(snapshot(1, { Resources = { { ItemId = "Coal", Count = 10 } } }, { Resources = 1 }))
			expect(gui:FindFirstChild("Item_Coal", true)).to.be.ok()
			handle.SetSnapshot(snapshot(2, {}))
			expect(gui:FindFirstChild("Item_Coal", true)).to.equal(nil)
		end)

		it("leaves out an item the catalog does not know, rather than drawing a nameless card", function()
			local handle, gui = mount()
			handle.SetSnapshot(
				snapshot(1, { Resources = { { ItemId = "Retired/Thing", Count = 4 } } }, { Resources = 1 })
			)
			expect(gui:FindFirstChild("Item_Retired/Thing", true)).to.equal(nil)
		end)

		it("lists a weapon in Armaments without a quantity", function()
			local handle, gui = mount()
			handle.SetSnapshot(
				snapshot(1, { Armaments = { { ItemId = "Weapon/Cutlass", Count = 1 } } }, { Armaments = 1 })
			)
			local card = gui:FindFirstChild("Item_Weapon/Cutlass", true) :: Instance
			expect(card).to.be.ok()
			expect(hasText(card, "Cutlass")).to.equal(true)
			expect(hasText(card, "1")).to.equal(false)
			expect(hasText(gui:FindFirstChild("Page_Armaments", true) :: Instance, "1 / 24 slots")).to.equal(true)
		end)

		it("flags a full section in words as well as colour", function()
			local handle, gui = mount()
			handle.SetSnapshot(
				snapshot(1, { Armaments = { { ItemId = "Weapon/Cutlass", Count = 1 } } }, { Armaments = 24 })
			)
			expect(hasText(gui:FindFirstChild("Page_Armaments", true) :: Instance, "24 / 24 slots - FULL")).to.equal(
				true
			)
		end)

		it("orders a section by rarity, then name", function()
			local handle, gui = mount()
			handle.SetSnapshot(snapshot(1, {
				Resources = { { ItemId = "Water", Count = 1 }, { ItemId = "Coal", Count = 1 } },
			}, { Resources = 2 }))
			local coal = gui:FindFirstChild("Item_Coal", true) :: GuiObject
			local water = gui:FindFirstChild("Item_Water", true) :: GuiObject
			-- Both Mortal: by name, Coal first.
			expect(coal.LayoutOrder < water.LayoutOrder).to.equal(true)
		end)
	end)

	describe("Inventory screen -- the detail pane", function()
		it("describes the first item of the showing section by default", function()
			local handle, gui = mount()
			handle.SetSnapshot(
				snapshot(1, { Armaments = { { ItemId = "Weapon/Cutlass", Count = 1 } } }, { Armaments = 1 })
			)
			local detail = gui:FindFirstChild("Detail", true) :: Instance
			expect(hasText(detail, "Cutlass")).to.equal(true)
			expect(hasText(detail, "Select an item to see it here.")).to.equal(false)
		end)

		it("explains why a weapon has no discard", function()
			local handle, gui = mount()
			handle.SetSnapshot(
				snapshot(1, { Armaments = { { ItemId = "Weapon/Cutlass", Count = 1 } } }, { Armaments = 1 })
			)
			local detail = gui:FindFirstChild("Detail", true) :: Instance
			local note: TextLabel? = nil
			local discard: Instance? = nil
			for _, descendant in detail:GetDescendants() do
				if descendant:IsA("TextLabel") and string.find(descendant.Text, "cannot be discarded", 1, true) then
					note = descendant
				end
				if descendant.Name == "ArmedButton" then
					discard = descendant
				end
			end
			assert(note and discard, "the note and the discard control must both exist")
			expect(isShown(note, detail)).to.equal(true)
			expect((discard :: GuiObject).Visible).to.equal(false)
		end)

		it("follows the showing section, not the whole inventory", function()
			local handle, gui = mount()
			-- Coal is held, but Armaments is the showing tab and is empty: the pane is on its empty state.
			handle.SetSnapshot(snapshot(1, { Resources = { { ItemId = "Coal", Count = 40 } } }, { Resources = 1 }))
			local detail = gui:FindFirstChild("Detail", true) :: Instance
			expect(hasText(detail, "Select an item to see it here.")).to.equal(true)
		end)
	end)
end
