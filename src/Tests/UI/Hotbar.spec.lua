--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)

local Client = StarterPlayer.StarterPlayerScripts.Client
local HUD = require(Client.UI.Screens.HUD)
local ClientStateModule = require(Client.UI.State.ClientState)
local KeybindManager = require(Client.Input.KeybindManager)
local HotbarBindings = require(Client.Combat.HotbarBindings)

-- The hotbar dock, mounted and then driven through the states a player actually reaches. Same
-- argument as WeaponInventory.spec.lua and Storybook.spec.lua beside it: Roblox property names are
-- unchecked until the code RUNS (see this repo's own `roblox-property-names-are-unchecked` note), and
-- a screen this reactive leaves most of itself unexecuted if it is only ever constructed. Every
-- assertion below walks a path a mount alone would not.
--
-- STRUCTURE, NAMES AND TEXT ONLY -- never geometry, and never an animated value. A headless place has
-- no render pipeline, and every cue this rebuild added (VitalIcon's damage flare, AbilitySlot's ready
-- flash, EngagementLine's transition) is a scope:Spring, which needs real elapsed frames to travel
-- and this suite does not step RunService.Heartbeat. So what is provable here is that each element
-- EXISTS, that the reactive switches flip the right way, and that nothing errors when they do --
-- whether the dock LOOKS right is what the panel itself and a pair of eyes are for.
--
-- The three bands that can vanish are the point of half of this file. The bounty pill collapses to
-- zero height, the engagement line swaps which of its two label runs is visible, and an ability slot
-- moves between three states -- each of those is a place a regression hides silently, because a
-- collapsed or wrong-state element still renders as *something*.

-- Mirrors the legend's own KeybindManager lookup rather than hardcoding "M"/"K"/"B" -- if a default
-- bind is retuned, this spec should follow it to the new key, not start failing.
local function currentKey(action: string): string
	return KeybindManager.Describe(KeybindManager.Get(action :: any))
end

return function()
	-- Declared inside the returned function, not at module scope: TestEZ injects `expect` into the
	-- environment of THIS function only, so a helper declared outside sees it as nil (the same note
	-- WeaponInventory.spec.lua carries for its own mount helper).
	-- RETURNS A TILE, NOT A SURFACE, as of Phase 2 of the hud-shell plan. The dock has no ScreenGui of
	-- its own any more -- UI/init.lua hands what Mount returns to Shell/Regions.lua's BottomCentre --
	-- so there is no PlayerGui to mount into and nothing to look up by name. Every assertion below was
	-- already about the dock's contents rather than about its surface, so only this helper changed.
	local function mount(): (Fusion.Scope<typeof(Fusion)>, ClientStateModule.ClientState, Frame)
		local scope = Fusion.scoped(Fusion)
		local clientState = ClientStateModule.new(scope)
		local hotbar = HUD.Mount(scope, clientState)

		expect(hotbar).to.be.ok()
		expect(hotbar.Name).to.equal("Hotbar")
		return scope, clientState, hotbar
	end

	local function find(root: Instance, name: string): Instance
		local found = root:FindFirstChild(name, true)
		expect(found).to.be.ok()
		return found :: Instance
	end

	describe("the hotbar dock", function()
		it("mounts every band, in order, bottom-centred", function()
			local _, _, hotbar = mount()

			-- NO AnchorPoint, where this used to assert one of (_, 1). "The dock grows upward as bands
			-- appear rather than creeping down off the screen" is still true and is still the point --
			-- it is BottomCentre's anchoring that says so now, not the dock's, because a region tile
			-- that set its own would have it overwritten by the region's UIListLayout every pass
			-- (Shell/Regions.lua, contract 1). Tests/UI/ShellRegions.spec.lua asserts the absence.
			expect(hotbar.AnchorPoint).to.equal(Vector2.zero)

			expect(find(hotbar, "EngagementLine")).to.be.ok()
			expect(find(hotbar, "BountyMarkedBadgeSlot")).to.be.ok()
			expect(find(hotbar, "HotbarDock")).to.be.ok()
			expect(find(hotbar, "LegendBand")).to.be.ok()
		end)

		it("carries the band gaps on the bands, not on the layout", function()
			local _, _, hotbar = mount()
			local layout = hotbar:FindFirstChildOfClass("UIListLayout")
			expect(layout).to.be.ok()

			-- A nonzero Padding here would leave a permanent sliver of dead space above the dock even
			-- while the bounty pill is fully collapsed -- the bug both EngagementLine's GAP_TO_NEXT and
			-- BountyMarkedBadge's exist to avoid. If this ever goes nonzero, those two constants are
			-- now double-counting.
			expect((layout :: UIListLayout).Padding.Offset).to.equal(0)
		end)

		it("groups the three modules with a seam between each", function()
			local _, _, hotbar = mount()
			local modules = find(hotbar, "Modules")

			expect(find(modules, "TierBadge")).to.be.ok()
			expect(find(modules, "Vitals")).to.be.ok()
			expect(find(modules, "Abilities")).to.be.ok()

			local seams = 0
			for _, child in ipairs(modules:GetChildren()) do
				if child.Name == "Divider" then
					seams += 1
				end
			end
			expect(seams).to.equal(2)
		end)

		it("sizes itself to its content, not to whatever it is sitting in", function()
			-- THE ONE TEST HERE THAT NEEDS A REAL LAYOUT PASS, and the reason it earns the cost: on
			-- 2026-08-25 this dock shipped rendering at full screen height, and NOTHING structural
			-- caught it -- every element existed, in the right place, with the right name. Roblox's
			-- AutomaticSize measures a child's whole SUBTREE, so a Scale-sized decoration layer that
			-- itself contains Scale-sized children (Components/MeridianField.lua is exactly that)
			-- makes an auto-sized panel latch onto its host's size instead of its own content.
			-- ClipsDescendants does not stop it. Only a measured AbsoluteSize can see that.
			--
			-- Unlike the rest of this file it mounts into StarterGui, because AbsoluteSize is zero
			-- for a tree hanging off a bare Folder, and cleans up after itself so the next spec does
			-- not inherit a stray ScreenGui.
			local scope = Fusion.scoped(Fusion)
			local holder = Instance.new("ScreenGui")
			holder.Parent = StarterGui
			HUD.Mount(scope, ClientStateModule.new(scope)).Parent = holder

			for _ = 1, 8 do
				RunService.Heartbeat:Wait()
			end

			local dock = holder:FindFirstChild("HotbarDock", true) :: Frame
			expect(dock).to.be.ok()
			local content = dock:FindFirstChild("Content") :: Frame
			expect(content).to.be.ok()

			-- Asserted rather than tolerated: if layout ever stops resolving in this harness, this
			-- test must fail loudly instead of quietly passing on a pair of zeroes.
			expect(content.AbsoluteSize.Y > 0).to.equal(true)
			-- The dock is its content plus its own padding, and nothing else. The failure this
			-- catches inflates it to the viewport, so any generous ceiling separates the two.
			expect(dock.AbsoluteSize.Y).to.equal(content.AbsoluteSize.Y)
			expect(dock.AbsoluteSize.Y < 200).to.equal(true)
			expect(dock.AbsoluteSize.X).to.equal(content.AbsoluteSize.X)

			holder:Destroy()
		end)

		it("gives the tier module a numeral plate and a readout", function()
			local _, _, hotbar = mount()
			local badge = find(hotbar, "TierBadge")
			expect(find(badge, "TierPlate")).to.be.ok()
			expect(find(badge, "TierReadout")).to.be.ok()
		end)
	end)

	describe("the vitals module", function()
		it("renders all three vitals, each as a tile over its own track", function()
			local _, _, hotbar = mount()
			local vitals = find(hotbar, "Vitals")

			for _, caption in ipairs({ "Health", "Qi", "Posture" }) do
				local gauge = find(vitals, caption .. "VitalIcon")
				-- The two-surface split VitalIcon.lua's header is about: lose either one and the gauge
				-- silently goes back to being a single ambiguous surface.
				expect(find(gauge, "Tile")).to.be.ok()
				expect(find(gauge, "Track")).to.be.ok()
			end
		end)

		it("survives a vital being driven down to zero and back", function()
			local _, clientState, hotbar = mount()
			local gauge = find(hotbar, "HealthVitalIcon")

			-- Walks the critical threshold in both directions, which is what recomputes the stroke
			-- colour/weight and (in chamfered mode) swaps the baked border texture.
			clientState.Health:set(0)
			clientState.Health:set(100)
			clientState.Health:set(12)
			expect(gauge.Parent).to.be.ok()
		end)
	end)

	describe("the ability module", function()
		it("renders exactly one slot per server-validated hotbar slot", function()
			local _, _, hotbar = mount()
			local abilities = find(hotbar, "Abilities")

			-- The HUD names its five slots with digit literals (see that file's header on why those
			-- are NOT read from KeybindManager), and AttackConstants.Hotbar.SlotCount is what the
			-- server actually validates an incoming slot index against. Nothing links the two at
			-- compile time, so this is the link: a sixth tile the server would reject, or a fifth
			-- keybind with no tile behind it, fails here rather than in a playtest.
			local rendered = 0
			for _, child in ipairs(abilities:GetChildren()) do
				if string.sub(child.Name, 1, 11) == "AbilitySlot" then
					rendered += 1
				end
			end
			expect(rendered).to.equal(AttackConstants.Hotbar.SlotCount)

			for slot = 1, AttackConstants.Hotbar.SlotCount do
				local button = find(abilities, "AbilitySlot" .. tostring(slot))
				expect(button:IsA("TextButton")).to.equal(true)
				-- The visuals live on an inner frame so the hover lift has something to move that is
				-- not the button's own hit rect -- AbilitySlot.lua's header. If this disappears, the
				-- lift is silently moving the hit target instead.
				expect(find(button, "Tile")).to.be.ok()
			end
		end)

		it("starts every slot Locked, because nothing is bound at mount", function()
			local _, _, hotbar = mount()
			local button = find(hotbar, "AbilitySlot1")
			-- A Locked slot has no lit edge. Asserting the bar EXISTS but is fully transparent is the
			-- one non-geometric way to prove the state actually reached the visuals.
			local edge = find(button, "EdgeBar") :: Frame
			expect(edge.BackgroundTransparency).to.equal(1)
		end)
	end)

	describe("an equipped slot", function()
		-- Components/Label.lua sets no Name, so all four text runs on a tile arrive as "TextLabel" and
		-- none of them is findable by name. Matching on the TEXT is the assertion anyway: what is
		-- being proved is that the art's own data reached the tile, not where in the tree it landed.
		local function hasText(root: Instance, text: string): boolean
			for _, descendant in ipairs(root:GetDescendants()) do
				if descendant:IsA("TextLabel") and descendant.Text == text then
					return true
				end
			end
			return false
		end

		-- HotbarBindings is a VM-wide singleton (a plain Luau module, not per-mount state), so each
		-- case here has to hand it back empty or the Locked case above starts failing the moment one
		-- of these leaves an art in slot 1. afterEach rather than a tail call per case, so a failed
		-- assertion still cleans up after itself.
		afterEach(function()
			HotbarBindings.SyncFromServer({})
		end)

		it("replaces the empty-slot reticle with the art's monogram", function()
			local _, _, hotbar = mount()
			local button = find(hotbar, "AbilitySlot1")
			-- The reticle is EMPTY-slot chrome (AbilitySlot.lua's header). Until 2026-08-25 nothing
			-- ever turned it off, so an equipped art rendered the "nothing here" mark -- which is
			-- exactly the kind of regression that still looks like *something* on screen and so goes
			-- unnoticed. Both halves are asserted: showing when empty, gone when filled.
			local reticle = find(button, "Reticle") :: Frame
			expect(reticle.Visible).to.equal(true)

			HotbarBindings.SyncFromServer(
				{ [1] = "art_ascendant_palm" },
				{ art_ascendant_palm = { DisplayName = "Ascendant Palm", QiCost = 20 } }
			)

			expect(reticle.Visible).to.equal(false)
			-- Two words -> two initials. The abbreviation is AbilitySlot's own call (a 56px tile fits
			-- about two characters), so this is where the rule is pinned down.
			expect(hasText(button, "AP")).to.equal(true)
			expect(hasText(button, "20 Qi")).to.equal(true)
		end)

		it("abbreviates a single-word art to two letters, title-cased", function()
			local _, _, hotbar = mount()
			local button = find(hotbar, "AbilitySlot2")

			HotbarBindings.SyncFromServer(
				{ [2] = "art_thunderclap" },
				{ art_thunderclap = { DisplayName = "Thunderclap", QiCost = 0 } }
			)

			expect(hasText(button, "Th")).to.equal(true)
			-- A free art shows no cost line at all rather than "0 Qi" -- HUD/init.lua's applySlotInfo.
			expect(hasText(button, "0 Qi")).to.equal(false)
		end)

		it("goes back to empty chrome when the slot is cleared", function()
			local _, _, hotbar = mount()
			local button = find(hotbar, "AbilitySlot1")
			local reticle = find(button, "Reticle") :: Frame

			HotbarBindings.SyncFromServer(
				{ [1] = "art_ascendant_palm" },
				{ art_ascendant_palm = { DisplayName = "Ascendant Palm", QiCost = 20 } }
			)
			expect(reticle.Visible).to.equal(false)

			-- A slot the server no longer lists is a slot the player cleared -- HotbarBindings.
			-- SyncFromServer rewrites every slot, including the ones the payload omits.
			HotbarBindings.SyncFromServer({})
			expect(reticle.Visible).to.equal(true)
			expect(hasText(button, "AP")).to.equal(false)
		end)

		it("re-renders a renamed art that kept its id", function()
			local _, _, hotbar = mount()
			local button = find(hotbar, "AbilitySlot3")

			HotbarBindings.SyncFromServer(
				{ [3] = "art_ascendant_palm" },
				{ art_ascendant_palm = { DisplayName = "Ascendant Palm", QiCost = 20 } }
			)
			HotbarBindings.SyncFromServer(
				{ [3] = "art_ascendant_palm" },
				{ art_ascendant_palm = { DisplayName = "Falling Palm", QiCost = 35 } }
			)

			-- The id never changed, so an id-only no-op guard would have swallowed this push and left
			-- the tile spelling the old name and the old price forever.
			expect(hasText(button, "FP")).to.equal(true)
			expect(hasText(button, "35 Qi")).to.equal(true)
			expect(hasText(button, "20 Qi")).to.equal(false)
		end)
	end)

	describe("the engagement line", function()
		it("shows the resting readout and hides the engaged one while out of combat", function()
			local _, _, hotbar = mount()
			local resting = find(hotbar, "RestingRun") :: Frame
			local engaged = find(hotbar, "EngagedRun") :: Frame

			-- Nothing in the rebuilt combat stack drives InCombat today (EngagementLine.lua's header),
			-- so this is the state every real session sits in.
			expect(resting.Visible).to.equal(true)
			expect(engaged.Visible).to.equal(false)
		end)

		it("swaps which readout is showing when combat state flips", function()
			local _, clientState, hotbar = mount()
			local resting = find(hotbar, "RestingRun") :: Frame
			local engaged = find(hotbar, "EngagedRun") :: Frame

			clientState.InCombat:set(true)
			expect(resting.Visible).to.equal(false)
			expect(engaged.Visible).to.equal(true)

			clientState.InCombat:set(false)
			expect(resting.Visible).to.equal(true)
			expect(engaged.Visible).to.equal(false)
		end)
	end)

	describe("the key legend", function()
		it("spells each cap from the binding that action currently has", function()
			local _, _, hotbar = mount()
			local legend = find(hotbar, "KeyLegend")

			for index, action in ipairs({ "CharacterMenuToggle", "SettingsToggle", "EmoteWheel" }) do
				local entry = find(legend, "LegendEntry" .. tostring(index))
				local cap = find(entry, "Cap")
				local label = cap:FindFirstChildOfClass("TextLabel")
				expect(label).to.be.ok()
				expect((label :: TextLabel).Text).to.equal(currentKey(action))
			end
		end)

		it("re-letters a cap when its action is rebound", function()
			local _, _, hotbar = mount()
			local label = find(find(find(hotbar, "KeyLegend"), "LegendEntry2"), "Cap"):FindFirstChildOfClass(
				"TextLabel"
			) :: TextLabel

			-- KeybindManager's bindings are shared VM-wide state, so this MUST be put back before the
			-- spec ends -- the same trap WeaponFixture's own "install once, never Remove" note is
			-- about. Semicolon is unbound in Constants.Keybinds.Defaults, so the rebind cannot be
			-- refused for colliding with another action.
			local original = label.Text
			local rebound = KeybindManager.Rebind("SettingsToggle", { KeyCode = Enum.KeyCode.Semicolon })
			expect(rebound).to.equal(true)
			expect(label.Text).to.equal("Semicolon")

			KeybindManager.ResetToDefaults()
			expect(label.Text).to.equal(original)
		end)
	end)
end
