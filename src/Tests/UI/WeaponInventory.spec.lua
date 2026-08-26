--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Client = StarterPlayer.StarterPlayerScripts.Client
local Screens = Client.UI.Screens
local WeaponInventory = require(Screens.WeaponInventory)
local HUD = require(Screens.HUD)
local ClientStateModule = require(Client.UI.State.ClientState)
local ChamferedSurface = require(Client.UI.ChamferedSurface)
local Tokens = require(Client.UI.Tokens)

-- BackgroundTransparency is a float32 PROPERTY, so a Tokens value of 0.2 reads back as
-- 0.20000000298023224. Same trap Tests/UI/Reveal.spec.lua hit on UIScale.Scale.
local function near(actual: number, expected: number): boolean
	return math.abs(actual - expected) < 1e-5
end

-- The armament island -- the plate bolted to the hotbar dock's left edge -- mounted through the dock
-- that owns the joint, and driven through the payload shapes a player actually reaches.
--
-- MOUNTED THROUGH HUD, NOT ON ITS OWN, and that is the point of this file rather than a convenience.
-- Screens/WeaponInventory renders nothing now: it owns three Fusion Values and the SetInventory
-- handle Client/Combat/WeaponInventoryClient.lua drives, and Screens/HUD/ArmamentIsland.lua builds
-- the surface from them, because the island shares an EDGE with the dock and a joint has one owner.
-- Testing the island in isolation would test half of a joint.
--
-- TWO KINDS OF ASSERTION HERE, kept deliberately separate:
--   * STRUCTURE AND TEXT, which need no render pipeline -- what exists, what is visible, what a
--     Computed resolved to. Roblox property names are unchecked until the code RUNS (this repo's own
--     `roblox-property-names-are-unchecked` note), and a surface this reactive leaves most of itself
--     unexecuted if it is only ever constructed.
--   * GEOMETRY, which needs a real layout pass, so those cases mount into StarterGui and step
--     RunService.Heartbeat (the technique Tests/UI/Hotbar.spec.lua's own sizing case established).
--     This is where the seam lives: "attached" is a claim about coordinates, and the only honest way
--     to check a coordinate is to measure it.
--
-- What still cannot be asserted is the glyph's drawn/sheathed ANIMATION -- a scope:Spring needs real
-- elapsed time to travel, and its endpoints are colours and a height rather than a structure. What
-- CAN be asserted about that state, and is below, is the caption beside the draw key: it is a plain
-- Computed off the same boolean, so it resolves synchronously and proves the state reached the
-- island at all.

-- Mirrors the island's own Constants lookup rather than hardcoding "T"/"Y" -- if a default bind is
-- retuned, this spec should follow it to the new key, not start failing.
local function defaultKey(action: string): string
	local keyCode = (Constants.Keybinds.Defaults :: any)[action].KeyCode
	return if keyCode then keyCode.Name else "--"
end

local DRAW_KEY = defaultKey("ToggleWeapon")
local CYCLE_KEY = defaultKey("SelectNextWeapon")

-- The rack strip's cap, restated. Not imported: ArmamentIsland keeps it private, and a spec that
-- reached in for it would pass no matter what the cap became, which is the opposite of what these
-- two overflow cases are for.
local MAX_BEADS = 6

return function()
	-- Declared inside the returned function, not at module scope: TestEZ injects `expect` into the
	-- environment of THIS function only, so a helper declared beside the requires above sees it as
	-- nil (the same note Tests/UI/Hotbar.spec.lua carries for its own mount helper).
	local function mount(): (WeaponInventory.WeaponInventoryHandle, Frame, Frame)
		local scope = Fusion.scoped(Fusion)
		local handle, armament = WeaponInventory.Mount(scope)
		local hotbar = HUD.Mount(scope, ClientStateModule.new(scope), armament)

		local island = hotbar:FindFirstChild("ArmamentIsland", true)
		expect(island).to.be.ok()
		local plate = (island :: Instance):FindFirstChild("ArmamentPlate")
		expect(plate).to.be.ok()
		return handle, island :: Frame, plate :: Frame
	end

	local function find(root: Instance, name: string): Instance
		local found = root:FindFirstChild(name, true)
		expect(found).to.be.ok()
		return found :: Instance
	end

	-- Mounts into StarterGui so AbsoluteSize/AbsolutePosition actually resolve -- they are zero for a
	-- tree hanging off a bare Folder -- and hands back the holder so each case can clean up after
	-- itself rather than leaving a stray ScreenGui for the next spec to inherit.
	local function mountLive(): (WeaponInventory.WeaponInventoryHandle, ScreenGui)
		local scope = Fusion.scoped(Fusion)
		local handle, armament = WeaponInventory.Mount(scope)
		local holder = Instance.new("ScreenGui")
		holder.Parent = StarterGui
		HUD.Mount(scope, ClientStateModule.new(scope), armament).Parent = holder
		return handle, holder
	end

	local function step(frames: number): ()
		for _ = 1, frames do
			RunService.Heartbeat:Wait()
		end
	end

	local function captionOf(plate: Frame, key: string): string
		local hint = find(plate, `KeyHint_{key}`)
		-- The hint's direct children are its layout, its KeyCap frame and the caption -- so a
		-- NON-recursive class lookup is a stable handle on a Label that carries no Name of its own,
		-- while a recursive one would find the glyph inside the cap first.
		local caption = hint:FindFirstChildOfClass("TextLabel")
		expect(caption).to.be.ok()
		return (caption :: TextLabel).Text
	end

	local function visibleBeadCount(plate: Frame): number
		local strip = find(plate, "RackStrip")
		local count = 0
		for index = 1, MAX_BEADS do
			local bead = strip:FindFirstChild(`Bead{index}`)
			expect(bead).to.be.ok()
			if (bead :: Frame).Visible then
				count += 1
			end
		end
		return count
	end

	describe("the armament island", function()
		it("stays off screen until something is picked up", function()
			local handle, island, _plate = mount()
			expect(handle.SetInventory).to.be.a("function")
			-- The same rule Screens/CarriedResources holds: a player who never touches a weapon rack
			-- carries no empty surface for the whole session.
			expect(island.Visible).to.equal(false)
		end)

		it("arrives on the first pickup and carries the weapon's name", function()
			local handle, island, plate = mount()
			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })

			expect(island.Visible).to.equal(true)
			local column = find(plate, "Column")
			local name = column:FindFirstChildOfClass("TextLabel")
			expect(name).to.be.ok()
			expect((name :: TextLabel).Text).to.equal("Cutlass")
		end)

		it("builds the drawn/sheathed glyph cues", function()
			local _handle, _island, plate = mount()
			-- Both cues live on the glyph. Searched recursively: Panel wraps whatever it is handed in
			-- a "Content" frame of its own, so nothing a caller passes is ever a direct child of the
			-- plate root.
			local glyph = find(plate, "WeaponGlyph")
			expect(glyph:FindFirstChild("Blade")).to.be.ok()
			local scabbard = glyph:FindFirstChild("Scabbard")
			expect(scabbard).to.be.ok()
			expect((scabbard :: Instance):FindFirstChild("Throat")).to.be.ok()
			-- The glyph sits in the dock's own module-well treatment rather than loose beside the
			-- text -- one of the things that makes the island read as a module of the same instrument.
			expect(glyph.Parent).to.be.ok()
			expect(find(plate, "ScabbardWell")).to.be.ok()
		end)

		it("says which way the draw key goes, in both states", function()
			local handle, island, plate = mount()

			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })
			expect(captionOf(plate, DRAW_KEY)).to.equal("Draw")

			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = true })
			-- The one drawn/sheathed fact a headless spec can reach: the glyph's own answer is a
			-- spring, but this caption is a plain Computed off the same boolean.
			expect(captionOf(plate, DRAW_KEY)).to.equal("Sheathe")
			expect(island.Visible).to.equal(true)
		end)

		it("collapses the rack strip and the cycle hint with a single weapon held", function()
			local handle, _island, plate = mount()
			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })

			-- Collapsed rather than empty: a UIListLayout skips a non-visible child, so a player with
			-- one sword pays no vertical space for a fact they do not have yet.
			expect((find(plate, "RackStrip") :: Frame).Visible).to.equal(false)
			-- Hidden rather than shown disabled -- a key hint is an instruction, and an instruction
			-- that does nothing is worse than no instruction.
			expect((find(plate, `KeyHint_{CYCLE_KEY}`) :: Frame).Visible).to.equal(false)
		end)

		it("shows one bead per owned weapon, with the held one lit", function()
			local handle, _island, plate = mount()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Flambert", Drawn = false })

			expect((find(plate, "RackStrip") :: Frame).Visible).to.equal(true)
			expect((find(plate, `KeyHint_{CYCLE_KEY}`) :: Frame).Visible).to.equal(true)
			expect(visibleBeadCount(plate)).to.equal(3)

			-- Lit is fully opaque and quiet is not. Asserting the transparency rather than the size
			-- because it is the cue that survives at a glance; both are Computeds off the same slot.
			expect((find(plate, "Bead2") :: Frame).BackgroundTransparency).to.equal(0)
			expect((find(plate, "Bead1") :: Frame).BackgroundTransparency > 0).to.equal(true)
			expect((find(plate, "Bead3") :: Frame).BackgroundTransparency > 0).to.equal(true)
		end)

		it("moves the lit bead when the selection moves", function()
			local handle, _island, plate = mount()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Cutlass", Drawn = false })
			expect((find(plate, "Bead1") :: Frame).BackgroundTransparency).to.equal(0)

			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Kris", Drawn = false })
			expect((find(plate, "Bead3") :: Frame).BackgroundTransparency).to.equal(0)
			expect((find(plate, "Bead1") :: Frame).BackgroundTransparency > 0).to.equal(true)
		end)

		it("caps the strip and counts what it left out", function()
			local handle, _island, plate = mount()
			-- Eight owned against a six-bead strip. Workspace.Weapons is unbounded -- a builder adding
			-- models grows this list with no code change -- which is the case the panel this replaced
			-- grew off the top of the screen on.
			handle.SetInventory({
				Owned = { "Cutlass", "Flambert", "Kris", "Falchion", "Estoc", "Sabre", "Dao", "Jian" },
				Selected = "Cutlass",
				Drawn = true,
			})

			expect(visibleBeadCount(plate)).to.equal(MAX_BEADS)
			local strip = find(plate, "RackStrip")
			local overflow = strip:FindFirstChildOfClass("TextLabel")
			expect(overflow).to.be.ok()
			expect((overflow :: TextLabel).Visible).to.equal(true)
			expect((overflow :: TextLabel).Text).to.equal("+2")
		end)

		it("windows the strip so the held weapon always has a bead", function()
			local handle, _island, plate = mount()
			-- The eighth of eight. A strip that always showed the first six would have nothing lit
			-- here, which is the one thing it exists to say.
			handle.SetInventory({
				Owned = { "Cutlass", "Flambert", "Kris", "Falchion", "Estoc", "Sabre", "Dao", "Jian" },
				Selected = "Jian",
				Drawn = false,
			})

			expect(visibleBeadCount(plate)).to.equal(MAX_BEADS)
			expect((find(plate, `Bead{MAX_BEADS}`) :: Frame).BackgroundTransparency).to.equal(0)
		end)

		it("hides the overflow count when the whole rack fits", function()
			local handle, _island, plate = mount()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert" }, Selected = "Cutlass", Drawn = false })

			local strip = find(plate, "RackStrip")
			local overflow = strip:FindFirstChildOfClass("TextLabel")
			expect((overflow :: TextLabel).Visible).to.equal(false)
		end)
	end)

	describe("the seam with the dock", function()
		it("puts the island's right edge exactly on the dock's left edge", function()
			local handle, holder = mountLive()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert" }, Selected = "Cutlass", Drawn = true })
			-- Long enough for the entrance spring to settle -- it is under-damped and peaks about a
			-- quarter of a second in (Tokens.Motion.IslandSpring's own comment).
			step(120)

			local dock = holder:FindFirstChild("HotbarDock", true) :: Frame
			local island = holder:FindFirstChild("ArmamentIsland", true) :: Frame
			expect(dock).to.be.ok()
			expect(island).to.be.ok()

			-- Asserted rather than tolerated: if layout ever stops resolving in this harness, this
			-- must fail loudly instead of quietly passing on a pair of zeroes.
			expect(dock.AbsoluteSize.Y > 0).to.equal(true)
			expect(island.AbsoluteSize.X > 0).to.equal(true)

			-- ATTACHED MEANS OVERLAPPING, as of 2026-08-25. This asserted the same coordinate -- a butt
			-- joint at gap zero -- and that turned out to be wrong for a joint whose two halves are
			-- BOTH chamfered: the island ends its full height at the seam while the dock's left edge
			-- exists only between its own two cut corners, so the dock's cut voids went unfilled and
			-- the assembly's top and bottom edges each carried an 8px triangular notch at the join.
			--
			-- The island now sinks the chamfer depth into the dock, which covers both voids. Asserted
			-- as a bounded overlap rather than an equality for the same reason the equality was worth
			-- having: one pixel more and the island starts covering dock CONTENT rather than dock
			-- chrome. The furnace/console joint keeps the identical contract -- see
			-- Tests/UI/BlimpFuelPanel.spec.lua's own seam block.
			local islandRight = island.AbsolutePosition.X + island.AbsoluteSize.X
			local sink = islandRight - dock.AbsolutePosition.X
			expect(sink > 0).to.equal(true)
			expect(sink <= ChamferedSurface.CHAMFER_PX + 1).to.equal(true)

			-- ONE HEIGHT, so the two top edges are one line and the two bottom edges are another.
			-- This is what fails if a module inside the dock grows and ArmamentIsland's ISLAND_HEIGHT
			-- is left behind -- see that constant's own comment, which points here.
			expect(island.AbsoluteSize.Y).to.equal(dock.AbsoluteSize.Y)
			expect(island.AbsolutePosition.Y).to.equal(dock.AbsolutePosition.Y)

			holder:Destroy()
		end)

		it("cuts the plate's own right-hand chrome off at the seam", function()
			local handle, holder = mountLive()
			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })
			step(120)

			local island = holder:FindFirstChild("ArmamentIsland", true) :: Frame
			local plate = island:FindFirstChild("ArmamentPlate") :: Frame

			-- The bleed, measured. The plate is wider than the slot that shows it and overhangs to the
			-- RIGHT, so its stroke, its two right chamfer cuts and its two right corner brackets are
			-- all outside the clip and never render -- which is what leaves the dock's own left edge
			-- as the single rule at the join. Without this the two panels each keep a border there and
			-- the join reads as two panels touching, however small the gap.
			expect(island.ClipsDescendants).to.equal(true)
			expect(plate.AbsoluteSize.X > island.AbsoluteSize.X).to.equal(true)
			local plateRight = plate.AbsolutePosition.X + plate.AbsoluteSize.X
			local islandRight = island.AbsolutePosition.X + island.AbsoluteSize.X
			expect(plateRight > islandRight).to.equal(true)

			holder:Destroy()
		end)

		it("fastens the joint with a bead the island's own spring fades in", function()
			local handle, holder = mountLive()
			local bolt = holder:FindFirstChild("SeamBolt", true) :: Frame
			expect(bolt).to.be.ok()
			-- Fully transparent before there is an island to fasten -- a bronze bead sitting on the
			-- dock's edge with nothing attached to it would be an unexplained mark.
			expect(bolt.BackgroundTransparency).to.equal(1)

			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })
			step(120)
			expect(bolt.BackgroundTransparency < 0.05).to.equal(true)

			-- Straddling: its centre is on the seam, so half of it sits on each plate. The seam is the
			-- ISLAND'S CLIPPED EDGE, not the dock's nominal left edge -- since the sink those are eight
			-- pixels apart, and the bead belongs on the line it is fastening rather than on the edge
			-- that line used to coincide with.
			local island = holder:FindFirstChild("ArmamentIsland", true) :: Frame
			local junction = island.AbsolutePosition.X + island.AbsoluteSize.X
			local boltCentre = bolt.AbsolutePosition.X + bolt.AbsoluteSize.X / 2
			expect(math.abs(boltCentre - junction) <= 1).to.equal(true)

			holder:Destroy()
		end)
	end)

	describe("the dock, while the island springs out", function()
		it("does not move by a single pixel, on either axis, on any frame", function()
			-- THE ONE REQUIREMENT THE WHOLE PINNED LAYOUT EXISTS FOR. The hotbar's position is muscle
			-- memory, and the island's width is an UNDER-DAMPED spring, so a version that reserved the
			-- island's width in a centred row would slide the dock sideways on every pickup unless a
			-- mirror spacer cancelled it exactly, in local pixels, on every one of these frames. The
			-- island is pinned instead: it is in no layout at all, so there is no arithmetic here to
			-- get wrong. This samples the whole flight to prove it.
			local handle, holder = mountLive()
			step(10)

			local dock = holder:FindFirstChild("HotbarDock", true) :: Frame
			expect(dock).to.be.ok()
			expect(dock.AbsoluteSize.X > 0).to.equal(true)

			local baselineCentre = dock.AbsolutePosition.X + dock.AbsoluteSize.X / 2
			local baselineBottom = dock.AbsolutePosition.Y + dock.AbsoluteSize.Y
			local baselineWidth = dock.AbsoluteSize.X

			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Cutlass", Drawn = true })

			local worstCentre = 0
			local worstBottom = 0
			local sawIslandGrow = false
			local island = holder:FindFirstChild("ArmamentIsland", true) :: Frame
			for _ = 1, 90 do
				RunService.Heartbeat:Wait()
				worstCentre = math.max(
					worstCentre,
					math.abs((dock.AbsolutePosition.X + dock.AbsoluteSize.X / 2) - baselineCentre)
				)
				worstBottom =
					math.max(worstBottom, math.abs((dock.AbsolutePosition.Y + dock.AbsoluteSize.Y) - baselineBottom))
				if island.AbsoluteSize.X > 0 then
					sawIslandGrow = true
				end
			end

			-- Proves the sampling window actually covered a moving island rather than 90 frames of
			-- nothing happening, which would make the two assertions below pass for free.
			expect(sawIslandGrow).to.equal(true)
			expect(worstCentre).to.equal(0)
			expect(worstBottom).to.equal(0)
			expect(dock.AbsoluteSize.X).to.equal(baselineWidth)

			holder:Destroy()
		end)
	end)

	describe("the island's text", function()
		it("fits inside the box it is given", function()
			local handle, holder = mountLive()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Cutlass", Drawn = true })
			step(120)

			local plate = holder:FindFirstChild("ArmamentPlate", true) :: Frame
			local column = plate:FindFirstChild("Column", true) :: Frame
			expect(column.AbsoluteSize.X > 0).to.equal(true)

			-- Every run of text on the island, against the box it was actually laid out in. The name
			-- is the one that can genuinely outgrow its column (a weapon id is a Workspace model's
			-- Name, so it is as long as whoever built the sword felt like typing) and Label truncates
			-- it -- but an ordinary name must not be truncated, and the two key captions and the
			-- overflow count must never be.
			local function fits(label: TextLabel): boolean
				return label.TextBounds.X <= label.AbsoluteSize.X + 1
			end

			local name = column:FindFirstChildOfClass("TextLabel")
			expect(name).to.be.ok()
			expect(fits(name :: TextLabel)).to.equal(true)

			for _, key in ipairs({ DRAW_KEY, CYCLE_KEY }) do
				local hint = plate:FindFirstChild(`KeyHint_{key}`, true) :: Frame
				local caption = hint:FindFirstChildOfClass("TextLabel")
				expect(fits(caption :: TextLabel)).to.equal(true)
			end

			-- The whole readout column, against the plate's real content box. This is what catches a
			-- fourth row being added to a column that only has room for three.
			local content = plate:FindFirstChild("Content") :: Frame
			expect(column.AbsoluteSize.Y <= content.AbsoluteSize.Y).to.equal(true)

			holder:Destroy()
		end)
	end)

	describe("the seam", function()
		-- The dock/island joint, held to the same contract as the console/furnace one next door
		-- (Tests/UI/BlimpFuelPanel.spec.lua's own "the seam" block). Both were butt joints at gap zero
		-- until 2026-08-25; both are chamfered on both halves, which is what makes gap zero wrong.
		local function mountJoint(): (Frame, Frame, Frame, ScreenGui)
			local handle, holder = mountLive()
			handle.SetInventory({ Owned = { "TestBlade" }, Selected = "TestBlade", Drawn = false })
			-- 120, matching the other island cases: Tokens.Motion.IslandSpring is deliberately
			-- under-damped, so 60 frames still catches it a pixel past its rest width.
			step(120)

			local band = holder:FindFirstChild("DockBand", true) :: Frame
			expect(band).to.be.ok()
			local slot = band:FindFirstChild("ArmamentIsland", true) :: Frame
			expect(slot).to.be.ok()

			-- The dock is the only child of the band that is neither the island nor the fastener, and
			-- it is what sizes the band -- see Screens/HUD's dock band note.
			local dock: Frame? = nil
			for _, child in band:GetChildren() do
				if
					child:IsA("GuiObject")
					and child.Name ~= "ArmamentIsland"
					and child.Name ~= "SeamBolt"
					and child.Name ~= "SeamRule"
				then
					dock = child :: Frame
				end
			end
			expect(dock).to.be.ok()

			return band, slot, dock :: Frame, holder
		end

		it("sinks the island into the dock by exactly the chamfer depth", function()
			-- Both halves are chamfered, so an island clipped flat at the seam ends its full 98 tall
			-- while the dock's left edge exists only between its own two cut corners -- 16 shorter.
			-- At gap zero the dock's two cut voids went unfilled and the assembly's top and bottom
			-- edges each carried an 8px triangular notch at the join.
			local _band, slot, dock, holder = mountJoint()

			local sink = (slot.AbsolutePosition.X + slot.AbsoluteSize.X) - dock.AbsolutePosition.X
			expect(sink > 0).to.equal(true)
			expect(sink <= ChamferedSurface.CHAMFER_PX + 1).to.equal(true)

			holder:Destroy()
		end)

		it("keeps the island's outer edge exactly where it always was", function()
			-- The sink is paid for out of the slot's TRAVEL, not out of the island's own margin: the
			-- slot grew by the same 8 it moved right, so the plate's left edge has not budged. Getting
			-- this wrong would quietly narrow the island and shift every readout on it.
			local _band, slot, dock, holder = mountJoint()

			-- Within a pixel, not exactly: the slot width is a rounded product of an under-damped
			-- spring, so the resting value can land a pixel either side of 232 on the frame this
			-- happens to sample. What is being asserted is that the sink came out of the TRAVEL and
			-- not out of the island'"'"'s own margin -- an error there would be eight pixels, not one.
			local outerEdge = dock.AbsolutePosition.X - slot.AbsolutePosition.X
			expect(math.abs(outerEdge - 224) <= 1).to.equal(true)

			holder:Destroy()
		end)

		it("clips the island's right-hand chrome away at the seam", function()
			local _band, slot, _dock, holder = mountJoint()

			local plate = slot:FindFirstChild("ArmamentPlate") :: Frame
			expect(slot.ClipsDescendants).to.equal(true)
			expect(plate.AbsoluteSize.X > slot.AbsoluteSize.X).to.equal(true)

			holder:Destroy()
		end)

		it("fastens the joint with one bronze bead sitting on the shared rule", function()
			-- The rule has to be DRAWN once the island sinks: its fill covers the dock's own left
			-- stroke, which used to be the line at the seam, so without one the two faces merge and
			-- the bead is left floating in an unbroken surface.
			local band, slot, _dock, holder = mountJoint()

			local rule = band:FindFirstChild("SeamRule", true) :: Frame
			local bolt = band:FindFirstChild("SeamBolt", true) :: Frame
			expect(rule).to.be.ok()
			expect(bolt).to.be.ok()
			expect(bolt.BackgroundColor3).to.equal(Tokens.Color.AccentSecondary)
			-- THE DIVISION OUT-READS THE OUTER EDGE, and that inversion is the assertion. A joined
			-- assembly whose internal line is quieter than its own border merges back into one object,
			-- which is what this looked like at the panels' own AccentPrimary/0.3 before the owner
			-- asked for "a much more prominent divider". Pinned against the token rather than a
			-- literal, and against the panel border it has to beat rather than against a number.
			expect(rule.BackgroundColor3).to.equal(Tokens.Border.Seam.Color)
			-- Against the PANEL EDGE it has to beat, not against a literal: 0.3 is what both of these
			-- surfaces carry on their own borders, and a division at or above that is the state this
			-- rule was tuned out of twice.
			expect(Tokens.Border.Seam.Transparency < 0.3).to.equal(true)
			-- Waited on rather than sampled: the rule fades in on the island's own under-damped spring,
			-- and this place does not run at 60Hz, so a frame count is a bet on pacing.
			for _ = 1, 400 do
				if near(rule.BackgroundTransparency, Tokens.Border.Seam.Transparency) then
					break
				end
				RunService.Heartbeat:Wait()
			end
			expect(near(rule.BackgroundTransparency, Tokens.Border.Seam.Transparency)).to.equal(true)

			-- Both on the junction, which is the island's clipped edge. A bead eight pixels off the
			-- line it fastens is the defect this arrangement replaced on the other joint.
			local junction = slot.AbsolutePosition.X + slot.AbsoluteSize.X
			local ruleCentre = rule.AbsolutePosition.X + rule.AbsoluteSize.X / 2
			local boltCentre = bolt.AbsolutePosition.X + bolt.AbsoluteSize.X / 2
			expect(math.abs(ruleCentre - junction) <= 1).to.equal(true)
			expect(math.abs(boltCentre - junction) <= 1).to.equal(true)
			-- Full height, because the dock is already past its chamfer at this X.
			expect(rule.AbsoluteSize.Y).to.equal(slot.AbsoluteSize.Y)
			expect(rule.AbsoluteSize.X).to.equal(Tokens.Control.SeamRuleThickness)

			holder:Destroy()
		end)

		it("keeps the dock's left elbows clear of the join", function()
			-- The rule both joints keep: an elbow sits BracketInset from the VISIBLE join, not from
			-- its panel's nominal edge. Without BracketLeftInset the sink would walk the join right
			-- into these two and leave them sitting on the line.
			local _band, slot, dock, holder = mountJoint()

			local junction = slot.AbsolutePosition.X + slot.AbsoluteSize.X
			local nearest = math.huge
			for _, d in dock:GetDescendants() do
				if d.Name == "BracketArmVertical" then
					local offset = (d :: Frame).AbsolutePosition.X - junction
					if offset >= 0 and offset < nearest then
						nearest = offset
					end
				end
			end

			expect(nearest).to.equal(ChamferedSurface.CHAMFER_PX)

			holder:Destroy()
		end)
	end)
end
