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
local Chord = require(StarterPlayer.StarterPlayerScripts.Client.Input.Chord)

return function()
	afterEach(function()
		InputDevice.SetCurrentForTesting("KeyboardMouse")
		KeybindManager.ResetToDefaults()
		KeybindManager.ResetGamepadToDefaults()
		Glyph.SetImageResolverForTesting(nil)
		Chord.ResetModifier()
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
	-- Constants.Keybinds.GamepadChords is a THIRD map, and an action living only there is not
	-- unbound on a pad. Before Resolve consulted it, every one of these drew "Unbound" on a
	-- controller -- see this module's header.
	describe("the chord layer", function()
		it("names an action's chord when it has no plain gamepad button", function()
			-- Interact is chord-only by construction: Constants gives it no GamepadDefaults entry.
			expect(KeybindManager.GetGamepad("Interact")).to.equal(nil)

			local glyph = Glyph.Resolve("Interact", "Gamepad")
			expect(glyph.Kind).to.equal("Text")
			expect(glyph.Value).to.equal("L2+X")
		end)

		it("names the chord for every chord-only action rather than reporting it unbound", function()
			for _, action in { "Leap", "Interact", "GrabThrow" } do
				local glyph = Glyph.Resolve(action :: any, "Gamepad")
				expect(glyph.Value).never.to.equal("Unbound")
				expect(string.find(glyph.Value, "+", 1, true)).to.be.ok()
			end
		end)

		it("follows the modifier when it is rebound", function()
			Chord.SetModifier({ KeyCode = Enum.KeyCode.ButtonL3 })
			expect(Glyph.Resolve("Interact", "Gamepad").Value).to.equal("L3+X")
		end)

		it("still prefers a plain gamepad binding when the action has one", function()
			-- Dash has a plain ButtonB binding, so the chord layer is never consulted for it.
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			expect(Glyph.Resolve("Dash", "Gamepad").Value).to.equal("ButtonB")
		end)

		it("leaves the keyboard answer alone -- a chord is a gamepad concept", function()
			local glyph = Glyph.Resolve("Interact", "KeyboardMouse")
			expect(glyph.Kind).to.equal("Text")
			expect(glyph.Value).to.equal(KeybindManager.Describe(KeybindManager.Get("Interact")))
		end)
	end)
	-- A CONTEXTUAL control -- one that is deliberately not a Types.KeybindAction, so KeybindManager has
	-- no entry for it in either map. The blimp helm's whole legend is these (BlimpConstants.Controls),
	-- and before Binding existed the only way to draw one was a literal string, which is a KEYBOARD
	-- key shown to every player regardless of what is in their hands.
	describe("bindings", function()
		it("draws this device's own key, not the other one's", function()
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			local binding = { Keyboard = Enum.KeyCode.W, Gamepad = Enum.KeyCode.ButtonY }

			expect(Glyph.ResolveBinding(binding, "KeyboardMouse").Value).to.equal("W")
			-- Stripped of the "Button" prefix, exactly as a chord's halves are -- a cap reading
			-- "ButtonY" is four times the width of the thing it names.
			expect(Glyph.ResolveBinding(binding, "Gamepad").Value).to.equal("Y")
		end)

		it("prefers the engine's button image over text when there is one", function()
			Glyph.SetImageResolverForTesting(function()
				return "rbxasset://glyph"
			end)
			local glyph = Glyph.ResolveBinding({ Gamepad = Enum.KeyCode.ButtonY }, "Gamepad")
			expect(glyph.Kind).to.equal("Image")
			expect(glyph.Value).to.equal("rbxasset://glyph")
		end)

		-- The helm's release row: a real rebindable action on a keyboard (it shares Interact with the
		-- prompt that started the mount) and a plain contextual button on a pad. Resolving the action on
		-- BOTH devices would draw Interact's chord, "L2+X", which is not what a pilot presses.
		it("falls back to the action only on the device with no explicit key", function()
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			local release = { Action = "Interact" :: any, Gamepad = Enum.KeyCode.ButtonX }

			expect(Glyph.ResolveBinding(release, "KeyboardMouse").Value).to.equal(
				KeybindManager.Describe(KeybindManager.Get("Interact"))
			)
			expect(Glyph.ResolveBinding(release, "Gamepad").Value).to.equal("X")
		end)

		it("follows a rebind of the action it falls back to", function()
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			local rebound = KeybindManager.Rebind("Interact", { KeyCode = Enum.KeyCode.Semicolon })
			expect(rebound).to.equal(true)
			expect(Glyph.ResolveBinding({ Action = "Interact" :: any }, "KeyboardMouse").Value).to.equal("Semicolon")
		end)

		-- EMPTY, NOT "Unbound", and the difference is what stops a false alarm. A binding with nothing
		-- for this device is saying the device folds this control into an input another cap already
		-- names -- the helm's rudder is two keys on a keyboard and one thumbstick on a pad, so its
		-- second cap has no gamepad half at all. "Unbound" would tell a player holding a controller
		-- that a control they can reach is unreachable; Components/KeyCap.lua hides an empty cap.
		it("draws nothing for a control this device has no separate input for", function()
			local glyph = Glyph.ResolveBinding({ Keyboard = Enum.KeyCode.D }, "Gamepad")
			expect(glyph.Kind).to.equal("Text")
			expect(glyph.Value).to.equal("")
		end)

		-- An ACTION with no binding on this device is a different statement, and still says so.
		it("still reports a genuinely unbound action as unbound", function()
			-- DevMenuToggle is keyboard-only by construction and has no chord either.
			expect(KeybindManager.GetGamepad("DevMenuToggle")).to.equal(nil)
			expect(Glyph.ResolveBinding({ Action = "DevMenuToggle" :: any }, "Gamepad").Value).to.equal("Unbound")
		end)

		it("recomputes when the device changes", function()
			Glyph.SetImageResolverForTesting(function()
				return ""
			end)
			local scope = Fusion.scoped(Fusion)
			local glyph = Glyph.ForBinding(scope, { Keyboard = Enum.KeyCode.W, Gamepad = Enum.KeyCode.ButtonY })

			expect(Fusion.peek(glyph).Value).to.equal("W")
			InputDevice.SetCurrentForTesting("Gamepad")
			expect(Fusion.peek(glyph).Value).to.equal("Y")

			scope:doCleanup()
		end)
	end)
end
