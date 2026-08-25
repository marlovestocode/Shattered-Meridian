--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Screens = StarterPlayer.StarterPlayerScripts.Client.UI.Screens
local WeaponInventory = require(Screens.WeaponInventory)

-- The armament HUD tile, mounted and then driven through the payload shapes a player actually
-- reaches. Same argument as Storybook.spec.lua and ScreenFrameScreens.spec.lua beside it (Roblox
-- property names are unchecked until the code RUNS -- see this repo's own
-- `roblox-property-names-are-unchecked` note), with one thing those two cannot cover: this screen's
-- whole job is to look different depending on what it was told, so construction alone would leave
-- every reactive path in it unexecuted. Each `SetInventory` below walks a different one.
--
-- STRUCTURE AND TEXT ONLY, never geometry. A headless place has no render pipeline, so nothing here
-- can answer whether the scabbard visually covers the blade -- that is what the panel itself and a
-- pair of eyes are for. What it CAN answer is whether the rack cap holds and whether the tile
-- collapses the parts that have nothing to say.
--
-- NO MORE STATE-WORD ASSERTIONS (SHRUNK 2026-08-20). The old panel answered "is it drawn?" partly
-- through a DRAWN/SHEATHED StatusTag -- a synchronous Computed(drawn), trivial to assert here -- and
-- that badge is gone, along with the leading-edge rail that briefly replaced it and was itself cut
-- the same day (WeaponInventory/init.lua's own SHRUNK note). What answers the question now is purely
-- the glyph's spring-driven scabbard/blade animation, which this file's own "never geometry" rule
-- already puts out of a headless spec's reach: a scope:Spring needs real elapsed time to settle
-- toward its target, and this suite does not step RunService.Heartbeat to simulate that. So this spec
-- can still prove the two cue elements EXIST (WeaponGlyph/Blade/Scabbard/Throat) and that toggling
-- `Drawn` back and forth doesn't error, but not what value they animate to.

-- Mirrors the screen's own Constants lookup rather than hardcoding "T"/"Y" -- if a default bind is
-- retuned, this spec should follow it to the new key, not start failing.
local function defaultKey(action: string): string
	local keyCode = (Constants.Keybinds.Defaults :: any)[action].KeyCode
	return if keyCode then keyCode.Name else "--"
end

return function()
	-- Declared inside the returned function, not at module scope: TestEZ injects `expect` into the
	-- environment of THIS function only, so a helper declared beside the requires above sees it as
	-- nil (the same note ScreenFrameScreens.spec.lua carries for its own band helper).
	-- MOUNTS A TILE, NOT A SCREEN. This screen used to build its own ScreenGui and place itself in
	-- the bottom-left corner, and this helper used to go and find the panel inside it by name. It now
	-- returns its panel directly as an unparented tile for Shell/Regions.lua to place -- so the
	-- lookup is gone and the tile IS the return value. Every assertion below is unchanged: they were
	-- always about the panel's contents, never about where it sat.
	local function mount(): (WeaponInventory.WeaponInventoryHandle, Frame)
		local scope = Fusion.scoped(Fusion)
		local handle, panel = WeaponInventory.Mount(scope)
		expect(panel).to.be.ok()
		return handle, panel
	end

	local function rackRowCount(panel: Frame): number
		local rows = panel:FindFirstChild("RackRows", true)
		expect(rows).to.be.ok()
		local count = 0
		for _, child in ipairs((rows :: Instance):GetChildren()) do
			if string.sub(child.Name, 1, 5) == "Rack_" then
				count += 1
			end
		end
		return count
	end

	describe("the armament tile", function()
		it("constructs without erroring and stays off screen until something is picked up", function()
			local handle, panel = mount()
			expect(handle.SetInventory).to.be.a("function")
			-- The same rule CarriedResources holds: a player who never touches a weapon rack carries
			-- no empty tile for the whole session.
			expect(panel.Visible).to.equal(false)
		end)

		it("builds the drawn/sheathed glyph cues", function()
			local _handle, panel = mount()
			-- Both cues live on the glyph. Searched recursively: Panel wraps whatever it is handed in
			-- a "Content" frame of its own, so nothing a caller passes is ever a direct child of the
			-- panel root.
			local glyph = panel:FindFirstChild("WeaponGlyph", true)
			expect(glyph).to.be.ok()
			expect((glyph :: Instance):FindFirstChild("Blade")).to.be.ok()
			local scabbard = (glyph :: Instance):FindFirstChild("Scabbard")
			expect(scabbard).to.be.ok()
			expect((scabbard :: Instance):FindFirstChild("Throat")).to.be.ok()
		end)

		it("toggles Drawn back and forth without erroring", function()
			local handle, panel = mount()
			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = true })
			expect(panel.Visible).to.equal(true)
			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })
			expect(panel.Visible).to.equal(true)
		end)

		it("shows one weapon with no rack and no cycle hint", function()
			local handle, panel = mount()
			handle.SetInventory({ Owned = { "Cutlass" }, Selected = "Cutlass", Drawn = false })

			expect(panel.Visible).to.equal(true)

			local rack = panel:FindFirstChild("Rack", true)
			expect(rack).to.be.ok()
			-- Collapsed rather than empty: a UIListLayout skips a non-visible child, so the rule and
			-- the rows cost no vertical space at all with a single weapon held.
			expect((rack :: Frame).Visible).to.equal(false)

			local cycleHint = panel:FindFirstChild(`KeyHint_{defaultKey("SelectNextWeapon")}`, true)
			expect(cycleHint).to.be.ok()
			expect((cycleHint :: Frame).Visible).to.equal(false)
		end)

		it("lists the rest of the rack, minus whatever the hero row is showing", function()
			local handle, panel = mount()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert" }, Selected = "Cutlass", Drawn = false })

			local rack = panel:FindFirstChild("Rack", true)
			expect((rack :: Frame).Visible).to.equal(true)
			expect(rackRowCount(panel)).to.equal(1)
			-- The selected weapon is the hero, never also a rack row.
			expect(panel:FindFirstChild("Rack_Cutlass", true)).to.never.be.ok()
			expect(panel:FindFirstChild("Rack_Flambert", true)).to.be.ok()

			local cycleHint = panel:FindFirstChild(`KeyHint_{defaultKey("SelectNextWeapon")}`, true)
			expect((cycleHint :: Frame).Visible).to.equal(true)
		end)

		it("caps the rack and says how many it left out", function()
			local handle, panel = mount()
			-- Six owned: one in the hero row, two listed (MAX_RACK_ROWS, see WeaponInventory/init.lua's
			-- SHRUNK note), three over. Workspace.Weapons is unbounded, so this is the case the old
			-- panel grew off the top of the screen on.
			handle.SetInventory({
				Owned = { "Cutlass", "Flambert", "Kris", "Falchion", "Estoc", "Sabre" },
				Selected = "Cutlass",
				Drawn = true,
			})

			expect(rackRowCount(panel)).to.equal(2)

			-- The Rack container's own direct children are its chrome (UICorner/UIStroke/UIPadding),
			-- the rows frame, and the overflow line; the overflow line is the only TextLabel among
			-- them, which is what makes a non-recursive class lookup a stable handle on a Label that
			-- carries no Name of its own.
			local rack = panel:FindFirstChild("Rack", true) :: Frame
			local overflow = rack:FindFirstChildOfClass("TextLabel")
			expect(overflow).to.be.ok()
			expect((overflow :: TextLabel).Visible).to.equal(true)
			expect((overflow :: TextLabel).Text).to.equal("+3 MORE")
		end)

		it("hides the overflow line when the rack fits", function()
			local handle, panel = mount()
			handle.SetInventory({
				Owned = { "Cutlass", "Flambert", "Kris" },
				Selected = "Cutlass",
				Drawn = false,
			})

			expect(rackRowCount(panel)).to.equal(2)
			local rack = panel:FindFirstChild("Rack", true) :: Frame
			local overflow = rack:FindFirstChildOfClass("TextLabel")
			expect((overflow :: TextLabel).Visible).to.equal(false)
		end)

		it("swaps the hero and the rack round when the selection moves", function()
			local handle, panel = mount()
			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Cutlass", Drawn = false })
			expect(panel:FindFirstChild("Rack_Flambert", true)).to.be.ok()
			expect(panel:FindFirstChild("Rack_Kris", true)).to.be.ok()

			handle.SetInventory({ Owned = { "Cutlass", "Flambert", "Kris" }, Selected = "Kris", Drawn = false })
			expect(rackRowCount(panel)).to.equal(2)
			-- Whatever the hero row holds leaves the rack, and whatever it stopped holding rejoins it.
			expect(panel:FindFirstChild("Rack_Kris", true)).to.never.be.ok()
			expect(panel:FindFirstChild("Rack_Cutlass", true)).to.be.ok()
			expect(panel:FindFirstChild("Rack_Flambert", true)).to.be.ok()

			-- MEMBERSHIP, NOT INSTANCE IDENTITY, and that is a statement about Fusion rather than a
			-- weaker test written for convenience. For's Disassembly reuses a sub-object whose own
			-- input key survived, but when a key DOES disappear it hands that orphan some other
			-- pending pair, chosen by iterating an unordered set -- so a departing row can take a
			-- surviving row's pair and rebuild it. Asserting identity here would be asserting a hash
			-- iteration order. The screen's rackOrder map is shaped to maximise reuse anyway; it just
			-- does not promise it, and neither does this.
		end)
	end)
end
