--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Shell = UI.Shell

local Layers = require(Shell.Layers)
local Regions = require(Shell.Regions)
local ModalScreen = require(UI.Components.ModalScreen)

-- THE Z-ORDER LADDER: its arithmetic, the region host, and the one band with an order INSIDE it.
--
-- Phase 1 of docs/architecture/2026-08-25-hud-shell-plan.md built the ladder and put exactly one
-- ScreenGui on it. Phase 2 moved the rest; "every surface is in a known band" lives next door in
-- ShellSurface.spec.lua, alongside the factory that now enforces it.
--
-- WHAT IS ASSERTED HERE is the ladder's own shape, because it is arithmetic that is easy to get
-- wrong and impossible to notice: bands that overlap, or a gap too small to hold the modal counter
-- that sits inside one of them, would both look completely fine in the source and produce z-fighting
-- months later in a session nobody can reproduce.

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
			-- 0 is where thirteen surfaces sat before Phase 2 migrated them, and the literals the four
			-- self-ordering screens set (10, 20, 30) are all below the lowest band. Surface.New now
			-- refuses each of these outright (ShellSurface.spec.lua); this is the predicate that lets
			-- it, and it has to keep being true that a raw literal is not mistaken for a band.
			expect(Layers.BandOf(0)).to.equal(nil)
			expect(Layers.BandOf(10)).to.equal(nil)
			expect(Layers.IsBand(0)).to.equal(false)
		end)
	end)

	describe("modal ordering inside the band", function()
		-- WHY A COUNTER AT ALL. Two modals open at once is documented behaviour, not a hypothetical --
		-- Constants.Attributes.UiModalOpen's own comment cites the Move Editor over the character
		-- menu. If every modal took the bare Layers.Modal they would z-fight, and the winner would be
		-- PlayerGui insertion order: for the five Lazy-deferred screens that is FIRST-OPEN order, so
		-- which panel covered which would vary between sessions depending on what the player happened
		-- to open first that day.
		--
		-- Asserted through the rendered DisplayOrder rather than by reading the counter, because the
		-- counter is a module-scope local and the property is what a player actually sees.
		--
		-- EVERY EDGE NEEDS A FLUSH. ModalScreen drives its count and its nudge off the ScreenGui's own
		-- Enabled property -- deliberately, since that is the rendered truth rather than a prop a
		-- caller might have lied about -- and a GetPropertyChangedSignal handler is DEFERRED in this
		-- engine. Setting the Value and asserting on the next line would read the state before the
		-- edge was ever processed, and would do it intermittently rather than always.
		local function flush(): ()
			task.wait()
		end

		local function mountModal(
			scope: Fusion.Scope<typeof(Fusion)>,
			parent: PlayerGui,
			name: string
		): (ScreenGui, Fusion.Value<boolean>)
			local isOpen: Fusion.Value<boolean> = scope:Value(false)
			ModalScreen(scope, parent, {
				Name = name,
				Size = UDim2.fromOffset(200, 200),
				IsOpen = isOpen,
			})
			local gui = parent:FindFirstChild(name) :: ScreenGui
			expect(gui).to.be.ok()
			return gui, isOpen
		end

		it("puts the last-opened modal on top, and keeps both inside the band", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()

			local first, firstOpen = mountModal(scope, parent, "FirstModal")
			local second, secondOpen = mountModal(scope, parent, "SecondModal")

			-- Never opened: the base of its own band, not an arbitrary point in it.
			expect(first.DisplayOrder).to.equal(Layers.Modal)

			firstOpen:set(true)
			flush()
			secondOpen:set(true)
			flush()

			expect(second.DisplayOrder > first.DisplayOrder).to.equal(true)
			expect(Layers.BandOf(first.DisplayOrder)).to.equal("Modal")
			expect(Layers.BandOf(second.DisplayOrder)).to.equal("Modal")

			scope:doCleanup()
		end)

		it("starts the nudge again once everything is closed", function()
			-- THE BOUND. Without a reset the nudge climbs for the whole session, and a player who
			-- opened and closed a hundred panels would eventually promote a modal into Layers.Debug --
			-- a debug overlay a panel can cover, which is the one thing the band spacing exists to
			-- prevent. Reset when the OPEN COUNT returns to zero, which is the same edge the
			-- UiModalOpen Attribute is published on, in the same function.
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()

			local gui, isOpen = mountModal(scope, parent, "CyclingModal")

			isOpen:set(true)
			flush()
			local firstOpenOrder = gui.DisplayOrder
			expect(firstOpenOrder > Layers.Modal).to.equal(true)

			isOpen:set(false)
			flush()
			isOpen:set(true)
			flush()
			expect(gui.DisplayOrder).to.equal(firstOpenOrder)

			scope:doCleanup()
		end)

		it("cannot climb out of its band however many modals are opened", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()

			-- Held open TOGETHER, so the count never returns to zero and the reset never fires. That is
			-- the only path by which the nudge can actually accumulate, and the clamp is what makes it
			-- safe -- "reset when nothing is open" is only a bound if the player ever closes everything.
			local guis: { ScreenGui } = {}
			for index = 1, 40 do
				local gui, isOpen = mountModal(scope, parent, string.format("Stacked%d", index))
				isOpen:set(true)
				table.insert(guis, gui)
			end
			flush()

			for _, gui in guis do
				expect(Layers.BandOf(gui.DisplayOrder)).to.equal("Modal")
			end

			scope:doCleanup()
		end)
	end)

	describe("the region host", function()
		-- The trailing 1 is the viewport multiplier UI/init.lua computes once on the root scope and
		-- hands down (plan §2.4). Passed as a plain number rather than a Fusion Value because nothing
		-- in this block is about scaling -- ShellSurface.spec.lua measures that against a real render
		-- pass. Here it just has to be present: Surface.New refuses a scaled surface without one.
		it("mounts on the Regions band with all six regions", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local host = Regions.Mount(scope, parent, 1)

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
			Regions.Mount(scope, parent, 1)

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
			local first = Regions.Mount(firstScope, parent, 1)
			firstScope:doCleanup()

			local secondScope = Fusion.scoped(Fusion)
			local second = Regions.Mount(secondScope, parent, 1)

			expect(second.Gui).never.to.equal(first.Gui)
			expect(second.Gui.Parent).to.equal(parent)
		end)

		it("stacks tiles instead of overlapping them, nearest edge first", function()
			local scope = Fusion.scoped(Fusion)
			local parent = fakePlayerGui()
			local host = Regions.Mount(scope, parent, 1)

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
			local host = Regions.Mount(scope, parent, 1)

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
			local host = Regions.Mount(scope, parent, 1)

			-- A typo'd region name must not be a silently unparented tile. That failure looks
			-- identical to "the panel is broken" from a playtest and gives nobody a place to start.
			expect(function()
				host:Add("TopMiddle" :: any, 10, Instance.new("Frame"))
			end).to.throw()
		end)
	end)
end
