--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Shell = UI.Shell

local Layers = require(Shell.Layers)
local Regions = require(Shell.Regions)

-- THE Z-ORDER LADDER, AND THE ONE SURFACE THAT WEARS IT SO FAR.
--
-- Phase 1 of docs/architecture/2026-08-25-hud-shell-plan.md builds the ladder and puts exactly one
-- ScreenGui on it: the region host. The other sixteen surfaces still sit at the default 0 and are
-- migrated in Phase 2, which is when this file grows the assertion the plan describes as "every
-- mounted ScreenGui's DisplayOrder is a known band" -- it cannot be written yet without failing on
-- surfaces nobody has touched.
--
-- WHAT IS WORTH ASSERTING NOW is the ladder's own shape, because it is arithmetic that is easy to
-- get wrong and impossible to notice: bands that overlap, or a gap too small to hold the modal
-- counter that Phase 2 puts in it, would both look completely fine in the source and produce
-- z-fighting months later in a session nobody can reproduce.

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

return function()
	describe("the band ladder", function()
		local BAND_NAMES = { "World", "Regions", "Overlay", "Modal", "Debug", "Boot" }

		it("orders the bands the way the plan lists them", function()
			expect(Layers.World < Layers.Regions).to.equal(true)
			expect(Layers.Regions < Layers.Overlay).to.equal(true)
			expect(Layers.Overlay < Layers.Modal).to.equal(true)
			expect(Layers.Modal < Layers.Debug).to.equal(true)
			expect(Layers.Debug < Layers.Boot).to.equal(true)
		end)

		it("leaves a full band of headroom between neighbours", function()
			-- The gap IS the feature. ModalScreen takes Layers.Modal + n from a monotonic counter so
			-- the last-opened modal renders on top; if any two bands were closer together than
			-- Spacing, a player with enough panels open would silently promote a modal into the debug
			-- band. Asserted as an invariant over the whole ladder rather than spot-checked on Modal,
			-- because the next band added is the one that will get this wrong.
			local previous: number? = nil
			for _, name in BAND_NAMES do
				local base = (Layers :: any)[name] :: number
				expect(type(base)).to.equal("number")
				if previous ~= nil then
					expect(base - previous >= Layers.Spacing).to.equal(true)
				end
				previous = base
			end
		end)

		it("recognises each band base as a band", function()
			for _, name in BAND_NAMES do
				local base = (Layers :: any)[name] :: number
				expect(Layers.IsBand(base)).to.equal(true)
				expect(Layers.BandOf(base)).to.equal(name)
			end
		end)

		it("places a nudge in its own band and not the next one", function()
			-- The two shapes a real DisplayOrder takes: a bare band, and a band plus a small nudge.
			expect(Layers.BandOf(Layers.Boot + 20)).to.equal("Boot")
			expect(Layers.BandOf(Layers.Modal + Layers.Spacing - 1)).to.equal("Modal")
			-- One past the end of a band is the NEXT band, never still the old one. This is the
			-- assertion that would catch a nudge counter allowed to run unbounded.
			expect(Layers.BandOf(Layers.Modal + Layers.Spacing)).to.equal("Debug")
		end)

		it("rejects an order that predates the ladder", function()
			-- 0 is where all thirteen unmigrated surfaces still sit, and the literals the four
			-- self-ordering screens set (10, 20, 30) are all below the lowest band. Phase 2 turns this
			-- into a positive assertion over every mounted ScreenGui; for now it just has to be true
			-- that a raw literal is not mistaken for a band.
			expect(Layers.BandOf(0)).to.equal(nil)
			expect(Layers.BandOf(10)).to.equal(nil)
			expect(Layers.IsBand(0)).to.equal(false)
		end)
	end)

	describe("the region host", function()
		it("mounts on the Regions band with all six regions", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local host = Regions.Mount(scope, parent)

			expect(host.Gui).to.be.ok()
			expect(host.Gui.DisplayOrder).to.equal(Layers.Regions)
			expect(Layers.BandOf(host.Gui.DisplayOrder)).to.equal("Regions")

			-- By name, and all six: a region that silently does not exist would surface as a tile
			-- that never appears, which is exactly the failure mode the Add error below prevents
			-- from being silent.
			for _, region in { "TopLeft", "TopCentre", "TopRight", "BottomLeft", "BottomCentre", "BottomRight" } do
				expect(host.Gui:FindFirstChild(region)).to.be.ok()
			end
		end)

		it("is ONE ScreenGui, not one per region", function()
			-- The whole reason the corner collisions actually go away rather than merely becoming
			-- deterministic. Two top-right stacks in two ScreenGuis would still overlap.
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			Regions.Mount(scope, parent)

			local screenGuis = 0
			for _, child in parent:GetChildren() do
				if child:IsA("ScreenGui") then
					screenGuis += 1
				end
			end
			expect(screenGuis).to.equal(1)
		end)

		it("does not survive its scope's teardown", function()
			-- THE HOT-RELOAD TRAP, asserted rather than commented. UI/init.lua exposes its root Scope
			-- so a re-Mount can :doCleanup() and build a fresh tree. If Regions ever memoized the host
			-- in a module-level upvalue, the second Mount would parent every tile into a destroyed
			-- Instance -- a blank screen with nothing in the log. Two mounts on two scopes must
			-- therefore produce two different hosts, and the first must be gone after cleanup.
			local firstScope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local first = Regions.Mount(firstScope, parent)
			firstScope:doCleanup()

			local secondScope = Fusion.scoped(Fusion)
			local second = Regions.Mount(secondScope, parent)

			expect(second.Gui).never.to.equal(first.Gui)
			expect(second.Gui.Parent).to.equal(parent)
		end)

		it("stacks tiles instead of overlapping them, nearest edge first", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local host = Regions.Mount(scope, parent)

			local feed = Instance.new("Frame")
			local fuel = Instance.new("Frame")
			host:Add("TopRight", 10, feed)
			host:Add("TopRight", 20, fuel)

			local topRight = host.Gui:FindFirstChild("TopRight")
			expect(feed.Parent).to.equal(topRight)
			expect(fuel.Parent).to.equal(topRight)
			-- Top-anchored: ascending LayoutOrder already runs away from the anchored edge.
			expect(feed.LayoutOrder < fuel.LayoutOrder).to.equal(true)
		end)

		it("reverses LayoutOrder for a bottom-anchored region", function()
			-- Contract 2 in Regions.lua's header, and the one piece of that file with a real chance of
			-- being "simplified" back out by someone who has not hit it. A UIListLayout always runs
			-- top-to-bottom by ascending LayoutOrder, so in a bottom-anchored region the caller's
			-- "10 is nearest the edge" only holds if the order is negated. Callers pass 10/20 at both
			-- ends of the screen and must never have to know which end they are at.
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local host = Regions.Mount(scope, parent)

			local rack = Instance.new("Frame")
			local helm = Instance.new("Frame")
			host:Add("BottomLeft", 10, rack)
			host:Add("BottomLeft", 20, helm)

			-- The rack asked to be nearest the bottom edge, so it must lay out LAST.
			expect(rack.LayoutOrder > helm.LayoutOrder).to.equal(true)
		end)

		it("errors on a region that does not exist", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local host = Regions.Mount(scope, parent)

			-- A typo'd region name must not be a silently unparented tile. That failure looks
			-- identical to "the panel is broken" from a playtest and gives nobody a place to start.
			expect(function()
				host:Add("TopMiddle" :: any, 10, Instance.new("Frame"))
			end).to.throw()
		end)
	end)
end
