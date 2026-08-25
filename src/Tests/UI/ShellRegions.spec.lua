--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Screens = UI.Screens

local Announcement = require(Screens.Announcement)
local BlimpFuel = require(Screens.BlimpFuel)
local BlimpHelm = require(Screens.BlimpHelm)
local CarriedResources = require(Screens.CarriedResources)
local DeathFeed = require(Screens.DeathFeed)
local WeaponInventory = require(Screens.WeaponInventory)

-- THE REGION CONTRACT, AS A TEST. Written in Phase 0 of docs/architecture/2026-08-25-hud-shell-plan.md
-- deliberately FAILING, before UI/Shell/ existed: it states the target state Phase 1 then moves the
-- tree onto, so the invariant is written down by something that runs rather than by a comment.
--
-- The invariant is one sentence: A REGION-HOSTED SCREEN CONTRIBUTES A TILE, AND A TILE DOES NOT KNOW
-- WHERE IT IS. Concretely, the tile each of these six screens builds must leave BOTH Position and
-- AnchorPoint at their defaults, because in the region world the region's UIListLayout assigns
-- Position and the region's own anchoring decides which screen edge the stack grows from (plan 3.2:
-- "Growth direction is the region's, not the tile's").
--
-- WHY THIS ASSERTION AND NOT A COLLISION CHECK. The bug it exists to stop (2.1) is two panels at
-- byte-identical corner coordinates, and the tempting spec is one that mounts everything and looks
-- for overlapping rectangles. That spec cannot be written here: a headless place never resolves
-- AbsoluteSize or AbsolutePosition, so every panel measures 0x0 at 0,0 and they ALL "overlap".
-- Asserting the absence of self-placement is the same guarantee reached from the other side, and it
-- is answerable without a render pipeline.
--
-- WHY IT CATCHES THE NEXT ONE, WHICH IS THE POINT. Both files in 2.1 carry a prose comment claiming
-- their corner is free -- BlimpHelm's "the hotbar owns bottom-centre and Screens/BlimpFuel owns
-- top-right, so this is the corner a console-sized panel can grow downward-anchored in without ever
-- colliding with either", and WeaponInventory's "CarriedResources holds top-left and BlimpFuel
-- top-right, so the three corner tiles never collide". Both authors checked. Both checked against a
-- prose list nothing keeps current, and both were already wrong when written. A seventh panel that
-- hand-places itself now fails here instead of being approved by a reviewer reading the same stale
-- comments.
--
-- BY TILE NAME, NOT BY WALKING WHAT THE SCREEN BUILT. Found while writing this: a screen is allowed
-- to contribute something that is NOT a tile, and DeathFeed does. Its ScreenGui holds the top-right
-- KillFeedList *and* Components/DeathOverlay -- a centred 360x168 card at UDim2.fromScale(0.5, 0.4)
-- which is not a region tile at all and must keep placing itself. A spec that walked every root
-- would demand the death overlay stop centring itself, which would be wrong. Naming the tile is
-- also the more honest assertion: the migration's claim is about one specific Frame per screen, so
-- that is what gets checked.
--
-- STRUCTURE ONLY, like ScreenFrameScreens.spec.lua beside it. That the tiles LOOK right at 1366x768
-- is not answerable in this place and is checked by screenshot instead.

type Case = {
	Name: string,
	-- The one Frame this screen contributes to a region, by name.
	Tile: string,
	Mount: (any, PlayerGui) -> any,
	-- DeathFeed only -- see the exemption note on the second describe block below.
	OwnsASurface: boolean?,
}

local CASES: { Case } = {
	{ Name = "CarriedResources", Tile = "CarriedResourcesPanel", Mount = CarriedResources.Mount },
	{ Name = "Announcement", Tile = "AnnouncementBanner", Mount = Announcement.Mount },
	{ Name = "DeathFeed", Tile = "KillFeedList", Mount = DeathFeed.Mount, OwnsASurface = true },
	{ Name = "BlimpFuel", Tile = "BlimpFuelPanel", Mount = BlimpFuel.Mount },
	{ Name = "WeaponInventory", Tile = "WeaponInventoryPanel", Mount = WeaponInventory.Mount },
	{ Name = "BlimpHelm", Tile = "BlimpHelmPanel", Mount = BlimpHelm.Mount },
}

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

return function()
	-- Declared inside the returned function, not beside fakePlayerGui above it: TestEZ injects
	-- `expect` into the environment of THIS function only, so a helper at module scope sees it as nil
	-- and fails pointing at its own declaration line. Same note ScreenFrameScreens.spec.lua carries.
	local function expectPlacedByItsRegion(parent: Instance, case: Case): ()
		-- Recursive, so this keeps working across the migration without being rewritten: today the
		-- tile sits under the screen's own ScreenGui, afterwards it is a direct child of the region
		-- frame it was handed.
		local tile = parent:FindFirstChild(case.Tile, true)
		if tile == nil then
			error(string.format("%s: expected a tile named %q, found none", case.Name, case.Tile))
		end
		local gui = tile :: GuiObject

		-- Compared against a constructed default rather than four spelled-out numbers, so a Roblox
		-- default change cannot leave this quietly asserting the wrong thing.
		if gui.Position ~= UDim2.new() then
			error(
				string.format(
					"%s: tile %q sets Position = %s. A region-hosted tile is positioned by its "
						.. "region's UIListLayout and must leave Position at its default (plan 3.2).",
					case.Name,
					case.Tile,
					tostring(gui.Position)
				)
			)
		end
		if gui.AnchorPoint ~= Vector2.zero then
			error(
				string.format(
					"%s: tile %q sets AnchorPoint = %s. Growth direction belongs to the region, not "
						.. "the tile (plan 3.2).",
					case.Name,
					case.Tile,
					tostring(gui.AnchorPoint)
				)
			)
		end
	end

	describe("region-hosted screens contribute tiles, not placed panels", function()
		for _, case in CASES do
			it(string.format("%s leaves placement to its region", case.Name), function()
				local scope = Fusion.scoped(Fusion)
				local parent = fakePlayerGui()
				case.Mount(scope, parent)
				expectPlacedByItsRegion(parent, case)
			end)
		end
	end)

	describe("region-hosted screens do not own a render layer", function()
		-- The other half of 3.2, and the half that actually resolves 2.1. Two tiles in two different
		-- ScreenGuis would still overlap however the bands are ordered -- a z-order ladder alone only
		-- makes the overlap DETERMINISTIC. One host, one top-right stack, and the two queue. Also
		-- worth six fewer render layers, per 11 rule 6.
		--
		-- DeathFeed is the documented exception and keeps exactly one. It contributes a region tile
		-- AND a centred death overlay, and only the tile belongs to a region; the overlay is a
		-- surface in its own right and moves to Layers.Overlay in Phase 2, not here. Written as a
		-- flag on the case rather than by omitting DeathFeed from the loop, so the exemption is one
		-- grep away instead of being an absence.
		for _, case in CASES do
			local expectation = if case.OwnsASurface
				then "owns exactly one surface, for content that is not a tile"
				else "creates no ScreenGui of its own"

			it(string.format("%s %s", case.Name, expectation), function()
				local scope = Fusion.scoped(Fusion)
				local parent = fakePlayerGui()
				case.Mount(scope, parent)

				local screenGuis = 0
				for _, child in parent:GetChildren() do
					if child:IsA("ScreenGui") then
						screenGuis += 1
					end
				end
				expect(screenGuis).to.equal(if case.OwnsASurface then 1 else 0)
			end)
		end
	end)
end
