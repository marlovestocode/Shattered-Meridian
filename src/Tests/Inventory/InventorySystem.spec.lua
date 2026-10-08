--!strict
-- Covers Server/Systems/InventorySystem.lua -- the one writer of a player's inventory -- through the real
-- PlayerDataSystem.Transform path, with a stand-in Player holding a genuinely loaded profile
-- (PlayerDataSystem.InstallProfileForSpec, the seam Tests/Progression/ProgressionSpine.spec.lua uses).
--
-- NOT COVERED HERE: the remote round trip and the snapshot push. Both need a real Player (a bare
-- Instance.new("Player") errors in this headless harness -- the gap Combat/Weapon/WeaponInventorySystem.spec
-- documents), so the remote handler's rate limit and the client's receipt are checked in Studio. What IS
-- covered is every rule the handler delegates to: Add, Remove, Discard and the snapshot's contents.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)
local ItemCatalog = require(ReplicatedStorage.Shared.Inventory.ItemCatalog)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local InventorySystem = require(ServerScriptService.Server.Systems.InventorySystem)
local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local ROSTER = WeaponFixture.Install()
local BLADE = ItemCatalog.WeaponItemId(ROSTER[1])

local COAL_CAP = (ItemCatalog.Resolve("Coal") :: ItemCatalog.ItemDef).MaxCarry :: number

local nextId = 0
local installed: { any } = {}

local function fakePlayer(loaded: boolean?): any
	nextId += 1
	local player = { Name = `InvSpec{nextId}`, UserId = 8000 + nextId }
	if loaded ~= false then
		PlayerDataSystem.InstallProfileForSpec(player :: any, PlayerDataSystem.CreateDefaultProfile(player.UserId))
	end
	table.insert(installed, player)
	return player
end

return function()
	afterEach(function()
		InventorySystem.Reset()
		for _, player in installed do
			PlayerDataSystem.EvictProfileForSpec(player)
		end
		table.clear(installed)
	end)

	describe("InventorySystem.Add", function()
		it("stores an item and reports the new count", function()
			local player = fakePlayer()
			expect(InventorySystem.Add(player, "Coal", 40)).to.equal(40)
			expect(InventorySystem.Count(player, "Coal")).to.equal(40)
			expect(InventorySystem.Has(player, "Coal")).to.equal(true)
			expect(InventorySystem.Has(player, "Water")).to.equal(false)
		end)

		it("stops at the item's carry cap and reports the partial add", function()
			local player = fakePlayer()
			local added, reason = InventorySystem.Add(player, "Coal", COAL_CAP + 100)
			expect(added).to.equal(COAL_CAP)
			expect(reason).to.equal("Partial")
			expect(InventorySystem.RoomFor(player, "Coal")).to.equal(0)
			expect(InventorySystem.Add(player, "Coal", 1)).to.equal(0)
		end)

		it("refuses an item the catalog does not know", function()
			local player = fakePlayer()
			local added, reason = InventorySystem.Add(player, "Bogus", 1)
			expect(added).to.equal(0)
			expect(reason).to.equal("UnknownItem")
		end)

		it("refuses when the profile is not loaded, and writes nothing", function()
			local player = fakePlayer(false)
			local added, reason = InventorySystem.Add(player, "Coal", 5)
			expect(added).to.equal(0)
			expect(reason).to.equal("ProfileNotLoaded")
			expect(InventorySystem.IsLoaded(player)).to.equal(false)
			expect(InventorySystem.Count(player, "Coal")).to.equal(0)
		end)

		it("fires OnChanged with the player, item and NEW total", function()
			local player = fakePlayer()
			local seen: { { any } } = {}
			InventorySystem.OnChanged:Connect(function(who, itemId, count)
				table.insert(seen, { who, itemId, count })
			end)
			InventorySystem.Add(player, "Water", 10)
			InventorySystem.Add(player, "Water", 5)
			expect(#seen).to.equal(2)
			expect(seen[1][1]).to.equal(player)
			expect(seen[1][2]).to.equal("Water")
			expect(seen[1][3]).to.equal(10)
			expect(seen[2][3]).to.equal(15)
		end)

		it("does not fire OnChanged for an add that stored nothing", function()
			local player = fakePlayer()
			local fired = 0
			InventorySystem.OnChanged:Connect(function()
				fired += 1
			end)
			InventorySystem.Add(player, "Bogus", 1)
			InventorySystem.Add(player, "Coal", 0)
			expect(fired).to.equal(0)
		end)

		it("keeps one player's items out of another's", function()
			local first = fakePlayer()
			local second = fakePlayer()
			InventorySystem.Add(first, "Coal", 9)
			expect(InventorySystem.Count(second, "Coal")).to.equal(0)
		end)
	end)

	describe("InventorySystem -- weapons", function()
		it("accepts a rostered weapon as a single Armaments item", function()
			local player = fakePlayer()
			expect(InventorySystem.Add(player, BLADE, 1)).to.equal(1)
			expect(InventorySystem.Add(player, BLADE, 1)).to.equal(0)
			local owned = InventorySystem.OwnedIds(player, "Armaments")
			expect(#owned).to.equal(1)
			expect(owned[1]).to.equal(BLADE)
		end)

		it("refuses a weapon the roster does not have", function()
			local player = fakePlayer()
			local added, reason = InventorySystem.Add(player, "Weapon/NoSuchBlade", 1)
			expect(added).to.equal(0)
			expect(reason).to.equal("UnknownItem")
		end)

		it("refuses the fists, which are never an item", function()
			local player = fakePlayer()
			expect(InventorySystem.Add(player, ItemCatalog.WeaponItemId(WeaponRoster.FISTS_ID), 1)).to.equal(0)
		end)
	end)

	describe("InventorySystem.Remove", function()
		it("removes up to the amount held", function()
			local player = fakePlayer()
			InventorySystem.Add(player, "Coal", 30)
			expect(InventorySystem.Remove(player, "Coal", 10)).to.equal(10)
			expect(InventorySystem.Remove(player, "Coal", 100)).to.equal(20)
			expect(InventorySystem.Count(player, "Coal")).to.equal(0)
		end)

		it("fires OnChanged with the remaining count", function()
			local player = fakePlayer()
			InventorySystem.Add(player, "Coal", 30)
			local remaining = -1
			InventorySystem.OnChanged:Connect(function(_, _, count)
				remaining = count
			end)
			InventorySystem.Remove(player, "Coal", 12)
			expect(remaining).to.equal(18)
		end)

		it("does nothing for an item not held", function()
			local player = fakePlayer()
			local fired = 0
			InventorySystem.OnChanged:Connect(function()
				fired += 1
			end)
			expect(InventorySystem.Remove(player, "Coal", 5)).to.equal(0)
			expect(fired).to.equal(0)
		end)
	end)

	describe("InventorySystem.Discard", function()
		it("destroys the stated amount", function()
			local player = fakePlayer()
			InventorySystem.Add(player, "Coal", 50)
			local result = InventorySystem.Discard(player, "Coal", 20)
			expect(result.Success).to.equal(true)
			expect(result.Removed).to.equal(20)
			expect(InventorySystem.Count(player, "Coal")).to.equal(30)
		end)

		it("discards what is held when asked for more, rather than failing", function()
			local player = fakePlayer()
			InventorySystem.Add(player, "Coal", 5)
			local result = InventorySystem.Discard(player, "Coal", 999)
			expect(result.Success).to.equal(true)
			expect(result.Removed).to.equal(5)
			expect(InventorySystem.Count(player, "Coal")).to.equal(0)
		end)

		it("refuses a weapon -- it is never discardable", function()
			local player = fakePlayer()
			InventorySystem.Add(player, BLADE, 1)
			local result = InventorySystem.Discard(player, BLADE, 1)
			expect(result.Success).to.equal(false)
			expect(result.Reason).to.equal("NotDiscardable")
			expect(InventorySystem.Has(player, BLADE)).to.equal(true)
		end)

		it("refuses an item that is not held", function()
			local player = fakePlayer()
			local result = InventorySystem.Discard(player, "Coal", 1)
			expect(result.Success).to.equal(false)
			expect(result.Reason).to.equal("NotOwned")
		end)

		it("refuses an unknown item", function()
			local player = fakePlayer()
			expect(InventorySystem.Discard(player, "Bogus", 1).Reason).to.equal("UnknownItem")
		end)

		it("refuses a bad count or id without touching anything", function()
			local player = fakePlayer()
			InventorySystem.Add(player, "Coal", 10)
			for _, bad in { 0, -4, 2.5, 0 / 0, math.huge } do
				expect(InventorySystem.Discard(player, "Coal", bad).Reason).to.equal("BadRequest")
			end
			expect(InventorySystem.Discard(player, "", 1).Reason).to.equal("BadRequest")
			expect(InventorySystem.Discard(player, string.rep("x", 200), 1).Reason).to.equal("BadRequest")
			expect(InventorySystem.Discard(player, (5 :: any) :: string, 1).Reason).to.equal("BadRequest")
			expect(InventorySystem.Count(player, "Coal")).to.equal(10)
		end)

		it("refuses when the profile is not loaded", function()
			local player = fakePlayer(false)
			expect(InventorySystem.Discard(player, "Coal", 1).Reason).to.equal("ProfileNotLoaded")
		end)
	end)

	describe("InventorySystem.BuildSnapshot", function()
		it("is nil for a player with no loaded profile", function()
			expect(InventorySystem.BuildSnapshot(fakePlayer(false))).to.equal(nil)
		end)

		it("lists every section in order with its slot use and limit", function()
			local player = fakePlayer()
			InventorySystem.Add(player, "Coal", 10)
			InventorySystem.Add(player, BLADE, 1)

			local snapshot = InventorySystem.BuildSnapshot(player)
			assert(snapshot, "a loaded player must have a snapshot")
			expect(#snapshot.Sections).to.equal(#InventoryConstants.Sections)
			for index, def in InventoryConstants.Sections do
				expect(snapshot.Sections[index].Id).to.equal(def.Id)
				expect(snapshot.Sections[index].Limit).to.equal(def.Slots)
			end

			local armaments = snapshot.Sections[1]
			expect(armaments.Id).to.equal("Armaments")
			expect(armaments.Used).to.equal(1)
			expect(#armaments.Entries).to.equal(1)
			expect(armaments.Entries[1].ItemId).to.equal(BLADE)
			expect(armaments.Entries[1].Count).to.equal(1)

			local resources = snapshot.Sections[2]
			expect(resources.Id).to.equal("Resources")
			expect(resources.Entries[1].ItemId).to.equal("Coal")
			expect(resources.Entries[1].Count).to.equal(10)
		end)

		it("leaves an unrecognised saved item out of the listing and the slot count", function()
			local player = fakePlayer()
			-- Straight onto the profile, as a loaded save carrying a since-removed item would.
			PlayerDataSystem.Transform(player, function(profile)
				profile.inventory.Items["Retired/Thing"] = 7
				table.insert(profile.inventory.Order, "Retired/Thing")
			end)
			local snapshot = InventorySystem.BuildSnapshot(player)
			assert(snapshot, "snapshot expected")
			for _, section in snapshot.Sections do
				expect(section.Used).to.equal(0)
				expect(#section.Entries).to.equal(0)
			end
			-- Hidden, not deleted.
			expect(InventorySystem.Count(player, "Retired/Thing")).to.equal(7)
		end)

		it("does not advance the revision, so building one has no side effects", function()
			local player = fakePlayer()
			local first = InventorySystem.BuildSnapshot(player)
			local second = InventorySystem.BuildSnapshot(player)
			assert(first and second, "snapshots expected")
			expect(first.Revision).to.equal(second.Revision)
		end)
	end)
end
