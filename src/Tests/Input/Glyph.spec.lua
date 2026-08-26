--!strict
-- Covers Client/Input/Glyph.lua -- turning a Types.KeybindAction into what a key legend should draw
-- for the current device.
--
-- KeybindManager AND InputDevice ARE BOTH SINGLETONS, so every test that rebinds an action or forces
-- a device restores both in afterEach -- leftover state here would leak into whichever spec runs next
-- in the same process.

local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Glyph = require(StarterPlayer.StarterPlayerScripts.Client.Input.Glyph)
local InputDevice = require(StarterPlayer.StarterPlayerScripts.Client.Input.InputDevice)
local KeybindManager = require(StarterPlayer.StarterPlayerScripts.Client.Input.KeybindManager)

return function()
	afterEach(function()
		InputDevice.SetCurrentForTesting("KeyboardMouse")
		KeybindManager.ResetToDefaults()
		KeybindManager.ResetGamepadToDefaults()
		Glyph.SetImageResolverForTesting(nil)
	end)

	describe("Resolve", function()
		it("returns the keyboard binding's text on KeyboardMouse", function()
			local glyph = Glyph.Resolve("Dash", "KeyboardMouse")
			expect(glyph.Kind).to.equal("Text")
			expect(glyph.Value).to.equal(KeybindManager.Describe(KeybindManager.Get("Dash")))
		end)

		it(
			"falls back to the keyboard binding's text on Touch too -- there is no separate touch device category",
			function()
				local glyph = Glyph.Resolve("Dash", "Touch")
				expect(glyph.Kind).to.equal("Text")
				expect(glyph.Value).to.equal(KeybindManager.Describe(KeybindManager.Get("Dash")))
			end
		)

		it("prefers the engine's image for a bound gamepad KeyCode", function()
			Glyph.SetImageResolverForTesting(function()
				return "rbxasset://textures/ui/Controls/DesignSystem/ButtonB.png"
			end)
			local glyph = Glyph.Resolve("Dash", "Gamepad")
			expect(glyph.Kind).to.equal("Image")
			expect(glyph.Value).to.equal("rbxasset://textures/ui/Controls/DesignSystem/ButtonB.png")
		end)

		it("falls back to text on Gamepad when no image exists for the bound KeyCode", function()
			-- Driven through the resolver seam rather than assumed off the environment. An earlier
			-- version of this test assumed the headless suite had no glyph atlas and so would return
			-- "" for every KeyCode; it does not -- GetImageForKeyCode answers with a real asset here,
			-- so that version asserted Text and got Image. The empty answer is a real case for a pad
			-- Roblox has no art for, and the seam is the only way to reach it deterministically.
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			local glyph = Glyph.Resolve("Dash", "Gamepad")
			expect(glyph.Kind).to.equal("Text")
			expect(glyph.Value).to.equal(KeybindManager.Describe(KeybindManager.GetGamepad("Dash")))
		end)

		it("returns Unbound for an action with no gamepad binding at all", function()
			-- DevMenuToggle is deliberately gamepad-less -- see KeybindManager.lua's own header.
			local glyph = Glyph.Resolve("DevMenuToggle", "Gamepad")
			expect(glyph.Kind).to.equal("Text")
			expect(glyph.Value).to.equal("Unbound")
		end)
	end)

	describe("For", function()
		it("recomputes when the device changes", function()
			-- Forced to the text fallback so this test asserts the DEVICE switch and nothing else --
			-- without the seam the Gamepad branch resolves to an engine image and the comparison
			-- below would be against an asset id rather than the binding's name.
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			InputDevice.SetCurrentForTesting("KeyboardMouse")
			local scope = Fusion.scoped(Fusion)
			local glyph = Glyph.For(scope, "Dash")

			expect(Fusion.peek(glyph).Value).to.equal(KeybindManager.Describe(KeybindManager.Get("Dash")))

			InputDevice.SetCurrentForTesting("Gamepad")
			expect(Fusion.peek(glyph).Value).to.equal(KeybindManager.Describe(KeybindManager.GetGamepad("Dash")))
		end)

		it("recomputes when a binding is rebound", function()
			InputDevice.SetCurrentForTesting("KeyboardMouse")
			local scope = Fusion.scoped(Fusion)
			local glyph = Glyph.For(scope, "Dash")

			expect(Fusion.peek(glyph).Value).to.equal("Q")

			-- Semicolon is not part of any Constants.Keybinds.Defaults entry -- Tests/UI/Hotbar.spec.lua
			-- already rebinds a different action to it on that same assumption -- but the return value
			-- is asserted anyway rather than assumed, so a future Defaults change that DID collide would
			-- fail loudly here instead of leaving this test silently asserting the OLD binding never
			-- changed.
			local rebound = KeybindManager.Rebind("Dash", { KeyCode = Enum.KeyCode.Semicolon })
			expect(rebound).to.equal(true)
			expect(Fusion.peek(glyph).Value).to.equal("Semicolon")
		end)
	end)
end
