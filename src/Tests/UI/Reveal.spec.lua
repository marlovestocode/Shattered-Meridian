--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Reveal = require(UI.Components.Reveal)

-- THE SHARED AMBIENT-TILE ENTRANCE. Phase 5 of docs/architecture/2026-08-25-hud-shell-plan.md, and
-- Tier 3 of the velocity plan before it. What it replaces is section 2.7's table: two hand-rolled
-- springs at two different presets, one fade with no arrival, and two tiles that popped.
--
-- THIS SPEC STEPS REAL FRAMES, and it has to. A spring's whole behaviour is what it does over time,
-- so the assertions that matter here -- that a leaving tile stays mounted until it has finished
-- leaving, and that a settled spring lands exactly on its goal rather than near it -- are not
-- readable from one peek. Tests/UI/Hotbar.spec.lua established that this place resolves layout and
-- advances Fusion's own scheduler once a GuiObject is parented into StarterGui; springs advance for
-- the same reason.

type Scope = Fusion.Scope<typeof(Fusion)>

-- SETTLING IS WAITED FOR BY CONDITION, NOT BY A FRAME COUNT, and the first draft of this file got
-- that wrong in a way worth recording. A Fusion 0.3 Spring does not ease onto its goal and stop -- it
-- integrates every frame and SNAPS to the goal exactly, but only once both the remaining offset and
-- the remaining velocity are under its own EPSILON of 1e-5 (Animation/Spring.luau, the "sleep and
-- snap" branch). For a 22/1 spring that is roughly 0.8 seconds, and a flat 40-frame wait read 0.0063
-- instead of 0 -- converged to three decimal places, which is exactly the near-miss that would have
-- made an "approximately equal" assertion pass while proving nothing.
--
-- So this waits for the exact value and fails loudly if it never arrives, which asserts the real
-- contract (it lands on its goal) rather than a proxy for it (it gets close within N frames).
local SETTLE_TIMEOUT_FRAMES = 400

local function step(frames: number): ()
	for _ = 1, frames do
		RunService.Heartbeat:Wait()
	end
end

local function settle(progress: Fusion.UsedAs<number>, goal: number): ()
	for _ = 1, SETTLE_TIMEOUT_FRAMES do
		if Fusion.peek(progress) == goal then
			return
		end
		RunService.Heartbeat:Wait()
	end
	error(
		string.format(
			"Reveal.Progress never reached %d -- it is at %s after %d frames. A spring that does not "
				.. "land on its goal keeps every Computed downstream of it recomputing forever, which "
				.. "is the idle cost plan section 11 rule 5 forbids.",
			goal,
			tostring(Fusion.peek(progress)),
			SETTLE_TIMEOUT_FRAMES
		),
		0
	)
end

return function()
	-- A live tree, because a Fusion spring parked in a Folder is never stepped. Everything built here
	-- is torn down by the caller.
	local function mount(
		visible: boolean,
		depth: number?
	): (Scope, Fusion.Value<boolean>, Reveal.RevealHandle, ScreenGui)
		local scope = Fusion.scoped(Fusion)
		local holder = Instance.new("ScreenGui")
		holder.Parent = StarterGui

		local isVisible: Fusion.Value<boolean> = scope:Value(visible)
		local reveal = Reveal(scope, { Visible = isVisible, Depth = depth })

		local frame = scope:New "Frame" {
			Name = "RevealTile",
			Size = UDim2.fromOffset(120, 40),
			Visible = reveal.Mounted,
			Parent = holder,
			[Fusion.Children] = { reveal.Scale },
		}
		-- Asserted rather than assumed: the UIScale has to actually be in the tree for any of the
		-- below to mean anything about a real tile.
		expect(frame:FindFirstChildOfClass("UIScale")).to.be.ok()

		return scope, isVisible, reveal, holder
	end

	describe("the arrival", function()
		it("starts hidden and settles at exactly 1", function()
			local _scope, isVisible, reveal, holder = mount(false)

			expect(Fusion.peek(reveal.Progress)).to.equal(0)
			expect(Fusion.peek(reveal.Mounted)).to.equal(false)

			isVisible:set(true)
			settle(reveal.Progress, 1)

			-- EXACTLY 1, not "close to 1". Plan section 11 rule 5: a value that never quite arrives
			-- keeps everything downstream of it recomputing forever, which is the idle cost this
			-- whole layer is supposed to have none of. Fusion stops stepping a settled spring, and
			-- this is the assertion that it really does.
			expect(Fusion.peek(reveal.Progress)).to.equal(1)
			expect(Fusion.peek(reveal.Transparency)).to.equal(0)
			expect(Fusion.peek(reveal.Mounted)).to.equal(true)

			holder:Destroy()
		end)

		it("is mounted on the first frame of an arrival, before the spring has moved", function()
			-- The order in Reveal's Mounted Computed is `Visible or travelling`, not the other way
			-- round, and this is why: at the instant a tile is asked to appear the spring is still at
			-- 0, so reading the spring alone would drop the first frame of every entrance.
			local _scope, isVisible, reveal, holder = mount(false)

			isVisible:set(true)
			expect(Fusion.peek(reveal.Progress)).to.equal(0)
			expect(Fusion.peek(reveal.Mounted)).to.equal(true)

			holder:Destroy()
		end)

		it("scales the content up to exactly 1 and never past it", function()
			local _scope, isVisible, reveal, holder = mount(false, 0.2)

			-- A big depth so the difference is unmistakable rather than sub-pixel. Compared with a
			-- tolerance, unlike Progress above, and the reason is not spring convergence: UIScale.Scale
			-- is a float32 PROPERTY, so 0.8 written from a Luau double reads back as 0.800000011920929.
			-- 1 survives the round trip exactly, which is why the settled assertion below can still be
			-- an equality.
			expect(math.abs(reveal.Scale.Scale - 0.8) < 1e-5).to.equal(true)

			isVisible:set(true)
			settle(reveal.Progress, 1)

			-- Exactly 1 at rest, and the reason it cannot overshoot is the damping: Reveal is
			-- critically damped on purpose (its header quotes the philosophy doc's "never bouncy"),
			-- so a panel arriving cannot sail past its own size and come back.
			expect(reveal.Scale.Scale).to.equal(1)

			holder:Destroy()
		end)
	end)

	describe("the exit", function()
		it("stays mounted while it is still leaving, and only then goes", function()
			-- The guard that makes an exit an exit rather than a cut. BlimpHelm hand-wrote this as
			-- `visible or entrance < 0.99`; every other ambient tile went without it and simply
			-- vanished.
			local _scope, isVisible, reveal, holder = mount(true)
			settle(reveal.Progress, 1)

			isVisible:set(false)
			-- Still drawn, one frame after being told to go.
			expect(Fusion.peek(reveal.Mounted)).to.equal(true)

			settle(reveal.Progress, 0)
			expect(Fusion.peek(reveal.Mounted)).to.equal(false)

			holder:Destroy()
		end)

		it("comes back cleanly when it is re-shown mid-exit", function()
			-- The refuelling case, which Screens/CarriedResources hits for real: that tile's
			-- visibility is derived from a quantity, so a player picking up, spending and picking up
			-- again drives this edge repeatedly and quickly.
			local _scope, isVisible, reveal, holder = mount(true)
			settle(reveal.Progress, 1)

			isVisible:set(false)
			step(3)
			isVisible:set(true)
			settle(reveal.Progress, 1)
			expect(Fusion.peek(reveal.Mounted)).to.equal(true)

			holder:Destroy()
		end)
	end)

	describe("what it does NOT do", function()
		it("hands back no position and touches none", function()
			-- THE CONSTRAINT THE WHOLE COMPONENT IS SHAPED AROUND, asserted so a future contributor
			-- adding an offset finds out here rather than in Studio. A region's UIListLayout writes
			-- Position on every child on every layout pass, so a Reveal that animated Position would
			-- be silently overwritten -- Phase 1 of the shell plan lost two hand-rolled entrances
			-- exactly that way.
			local _scope, _isVisible, reveal, holder = mount(true)

			expect((reveal :: any).Position).to.equal(nil)
			expect((reveal :: any).Offset).to.equal(nil)

			holder:Destroy()
		end)

		it("does not write the visibility fact it was given", function()
			-- Same posture as Shell/Chrome.lua's mode: the screen owns whether its tile belongs on
			-- screen, and this component owns only how long it takes to get there and back.
			local _scope, _isVisible, reveal, holder = mount(false)

			for _, field in { "Mounted", "Transparency" } do
				local object = (reveal :: any)[field]
				expect(object).to.be.ok()
				if object.set ~= nil then
					error(
						string.format(
							"Reveal.%s is settable. Everything this component hands out is derived "
								.. "from the caller's own Visible -- see its header.",
							field
						)
					)
				end
			end

			holder:Destroy()
		end)
	end)

	describe("every ambient tile wears it", function()
		-- The migration half. Section 2.7 listed five screens with four different answers; the real
		-- list is THREE, and both departures left for the same reason -- they stopped being tiles and
		-- became plates BOLTED to another surface, which wants a drawer rather than a reveal:
		--
		--   WeaponInventory  -> Screens/HUD/ArmamentIsland, out of the dock'"'"'s left edge
		--   BlimpFuel        -> Screens/BlimpHelm/FurnacePlate, out of the console'"'"'s top edge
		--
		-- Both spring a SIZE on Tokens.Motion.IslandSpring instead. That is the correct distinction
		-- rather than an exemption: Reveal scales a tile in place, which is what a surface arriving on
		-- its own should do, and a thing being pushed out of another thing should not.
		--
		-- A source scan rather than a mount, because what is being asserted is that nobody hand-rolled
		-- a fourth answer -- a fact about the files, not about any one render.
		local TILES = {
			"CarriedResources",
			"Announcement",
			"BlimpHelm",
		}

		for _, name in TILES do
			it(string.format("%s reveals through the shared component", name), function()
				-- Each of these is a folder-with-init.lua, so Rojo lands it as one ModuleScript named
				-- for the folder rather than as a folder containing `init`.
				local source = (UI.Screens :: any)[name] :: ModuleScript
				expect(source).to.be.ok()
				expect(source:IsA("ModuleScript")).to.equal(true)
				expect(string.find(source.Source, "Components.Reveal", 1, true) ~= nil).to.equal(true)
				expect(string.find(source.Source, "reveal.Mounted", 1, true) ~= nil).to.equal(true)
			end)
		end
	end)
end
