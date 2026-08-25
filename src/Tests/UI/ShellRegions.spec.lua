--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Screens = UI.Screens

local ClientStateModule = require(UI.State.ClientState)
local Regions = require(UI.Shell.Regions)
local Announcement = require(Screens.Announcement)
local BlimpFuel = require(Screens.BlimpFuel)
local BlimpHelm = require(Screens.BlimpHelm)
local CarriedResources = require(Screens.CarriedResources)
local DeathFeed = require(Screens.DeathFeed)
local HUD = require(Screens.HUD)
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
-- AGAINST THE RETURNED TILE, NOT AGAINST EVERYTHING THE SCREEN BUILT. Found while writing the
-- Phase 0 version of this file: a screen is allowed to contribute something that is NOT a tile, and
-- DeathFeed does. It still owns a ScreenGui for Components/DeathOverlay -- a centred 360x168 card at
-- UDim2.fromScale(0.5, 0.4) which is not a region tile and must keep placing itself. A spec that
-- walked every root would have demanded the death overlay stop centring itself, which would be
-- wrong. Checking the value Mount actually hands to Shell/Regions.lua is both narrower and more
-- honest: that one Frame is the whole of the migration's claim. The name is asserted too, so a
-- screen cannot rename what it returns without this noticing.
--
-- STRUCTURE ONLY, like ScreenFrameScreens.spec.lua beside it. That the tiles LOOK right at 1366x768
-- is not answerable in this place and is checked by screenshot instead.

type Scope = Fusion.Scope<typeof(Fusion)>

type Case = {
	Name: string,
	-- The one Frame this screen contributes to a region, by name. Asserted as well as the returned
	-- tile so a screen cannot quietly rename what it hands over.
	Tile: string,
	-- Uniform here even though the real signatures are not: five screens take only a scope, and
	-- DeathFeed also takes a PlayerGui for the one surface it still owns. Wrapping the five is what
	-- lets every assertion below run over one list instead of special-casing the odd one out twice.
	Mount: (Scope, PlayerGui) -> (any, GuiObject),
	-- DeathFeed only -- see the exemption note on the second describe block below.
	OwnsASurface: boolean?,
}

local CASES: { Case } = {
	{
		Name = "CarriedResources",
		Tile = "CarriedResourcesPanel",
		Mount = function(scope, _parent)
			return CarriedResources.Mount(scope)
		end,
	},
	{
		Name = "Announcement",
		Tile = "AnnouncementBanner",
		Mount = function(scope, _parent)
			return Announcement.Mount(scope)
		end,
	},
	{
		Name = "DeathFeed",
		Tile = "KillFeedList",
		-- The 1 is the viewport scale the root scope computes and hands to every scaled surface
		-- (UI/init.lua). DeathFeed is the only case here that takes one, because it is the only one
		-- that still owns a ScreenGui -- the other six contribute a tile and nothing else, and the
		-- region host wears the scale on their behalf.
		Mount = function(scope, parent)
			return DeathFeed.Mount(scope, parent, 1)
		end,
		OwnsASurface = true,
	},
	{
		Name = "BlimpFuel",
		Tile = "BlimpFuelPanel",
		Mount = function(scope, _parent)
			return BlimpFuel.Mount(scope)
		end,
	},
	-- WeaponInventory IS NO LONGER IN THIS LIST, and its absence is the point rather than an omission.
	-- It was BottomLeft/10 from Phase 1 until the island rework, when it moved out of Shell/Regions
	-- entirely: it is now an outrigger laid out by Screens/HUD against the dock's left edge, so it
	-- returns a { Content, Width } island instead of a tile and the region contract this file states
	-- simply does not apply to it. Tests/UI/WeaponInventory.spec.lua covers it in its new shape.
	--
	-- Worth recording because it CHANGES 2.1a: BottomLeft now holds one stack (the helm console)
	-- rather than two, so the left edge cannot oversubscribe itself against the top-left tile the way
	-- that section describes.
	{
		Name = "BlimpHelm",
		Tile = "BlimpHelmPanel",
		Mount = function(scope, _parent)
			return BlimpHelm.Mount(scope)
		end,
	},
	-- THE DOCK JOINED THIS LIST IN PHASE 2. It was the seventh always-on panel and the only one still
	-- placing itself: an AnchorPoint of (0.5, 1) and a Position whose bottom margin was Tokens.Space.L
	-- multiplied by the viewport scale in a Computed, because the UIScale it carried sat below the
	-- thing being positioned. It is BottomCentre's tile now, so the same two assertions every other
	-- ambient panel answers here apply to it, and the margin is the region's.
	{
		Name = "HUD",
		Tile = "Hotbar",
		Mount = function(scope, _parent)
			return nil, HUD.Mount(scope, ClientStateModule.new(scope))
		end,
	},
}

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

return function()
	-- Declared inside the returned function, not beside fakePlayerGui above it: TestEZ injects
	-- `expect` into the environment of THIS function only, so a helper at module scope sees it as nil
	-- and fails pointing at its own declaration line. Same note ScreenFrameScreens.spec.lua carries.
	local function expectPlacedByItsRegion(case: Case, gui: GuiObject): ()
		expect(gui.Name).to.equal(case.Tile)

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
				local _handle, tile = case.Mount(scope, parent)

				-- Asserted before anything else: a screen that returned nothing would make every
				-- check below vacuous, which is the one way this spec could go green on a broken tree.
				expect(tile).to.be.ok()
				-- Unparented. The region it belongs to is UI/init.lua's call to make, not the
				-- screen's, and a tile that arrived already parented would mean the screen had found
				-- somewhere to put itself after all.
				expect(tile.Parent).to.equal(nil)

				expectPlacedByItsRegion(case, tile)
			end)
		end
	end)

	describe("the bottom corners clear what the dock band draws", function()
		-- THE COLLISION THIS EXISTS TO STOP HAPPENED, AND IT IS THE THIRD OF ITS KIND. The armament
		-- island (Screens/HUD/ArmamentIsland.lua) is pinned at x = -224 inside the dock band,
		-- deliberately outside the BottomCentre tile's own bounds so the dock cannot be shoved sideways
		-- by it. At this UI's authoring resolution -- 1366x768, where ViewportScale is exactly 1.0 --
		-- that puts its left edge 24px from the screen edge, straight through BottomLeft's column and
		-- straight through the helm console standing in it. Shell/Regions.lua answers it by starting
		-- both bottom CORNERS above the dock band; this is the assertion that they still do.
		--
		-- MEASURED, NOT COMPARED TO A COPY OF THE CONSTANT. Asserting DOCK_BAND_REACH against itself
		-- would pass forever. What is measured here is the dock band's REAL top edge off a real layout
		-- pass, so retuning the key legend beneath the dock, or the dock's own height, fails this test
		-- naming the number it has become -- which is exactly what COMBAT_BANNER_BAND_BOTTOM's own
		-- note in that file says nothing does for it.
		--
		-- Mounts into StarterGui because AbsoluteSize is zero for a tree hanging off a bare Folder,
		-- and cleans up after itself. Same harness as Tests/UI/Hotbar.spec.lua's sizing test.
		local function measureDockBandReach(): number
			local scope = Fusion.scoped(Fusion)
			local holder = Instance.new("ScreenGui")
			holder.Parent = StarterGui

			-- WITH the armament state, because the DockBand frame only exists when there is an island
			-- to pin -- and the island is the whole reason the corners have to keep clear.
			local _handle, armament = WeaponInventory.Mount(scope)
			local tile = HUD.Mount(scope, ClientStateModule.new(scope), armament)
			tile.Parent = holder

			for _ = 1, 8 do
				RunService.Heartbeat:Wait()
			end

			local band = tile:FindFirstChild("DockBand", true) :: Frame
			expect(band).to.be.ok()
			-- Asserted rather than tolerated: a harness that stopped resolving layout would otherwise
			-- let this pass on a pair of zeroes.
			expect(tile.AbsoluteSize.Y > 0).to.equal(true)
			expect(band.AbsoluteSize.Y > 0).to.equal(true)

			-- From the tile's own BOTTOM edge up to the top of the band -- the band's height plus
			-- everything below it (the key legend). Independent of where the tile itself sits.
			local reach = tile.AbsoluteSize.Y - (band.AbsolutePosition.Y - tile.AbsolutePosition.Y)
			-- The reach contains the band, by construction. Asserted anyway, because the one way this
			-- whole test could go green while proving nothing is a reach that came back near zero and
			-- made the comparison below trivially true.
			expect(reach >= band.AbsoluteSize.Y).to.equal(true)

			holder:Destroy()
			return reach
		end

		-- A bottom-anchored region's inset is a NEGATIVE offset from the bottom edge; this reads it
		-- back as a positive distance so the comparison below says what it means.
		local function insetAboveBottom(host: Regions.RegionHost, region: string): number
			local frame = host.Gui:FindFirstChild(region) :: Frame
			expect(frame).to.be.ok()
			return -frame.Position.Y.Offset
		end

		for _, corner in { "BottomLeft", "BottomRight" } do
			it(string.format("%s starts above the dock band's top edge", corner), function()
				local reach = measureDockBandReach()

				local scope = Fusion.scoped(Fusion)
				local host = Regions.Mount(scope, fakePlayerGui(), 1)

				local dockBandTop = insetAboveBottom(host, "BottomCentre") + reach
				local cornerInset = insetAboveBottom(host, corner)

				if cornerInset < dockBandTop then
					error(
						string.format(
							"%s starts %dpx above the bottom edge, but the dock band's top is at %dpx "
								.. "(BottomCentre's %dpx inset plus a measured %dpx of reach). A tile in "
								.. "this corner renders into whatever is bolted to the dock's edge -- "
								.. "raise DOCK_BAND_REACH in Shell/Regions.lua to %d.",
							corner,
							cornerInset,
							dockBandTop,
							insetAboveBottom(host, "BottomCentre"),
							reach,
							reach
						)
					)
				end
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
