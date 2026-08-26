--!strict
-- Covers Client/Input/InputDevice.lua -- which physical device the local player is currently using.
--
-- ResolveDevice IS THE FOCUS HERE, not the live UserInputService connections: InputObject has no
-- public constructor, so there is no way for this spec to synthesize a real button press or stick
-- nudge to drive them. ResolveDevice is the exact decision every live connection reduces its own
-- InputObject down to before calling (see the module's own header), so asserting it directly is
-- asserting the real behaviour, not a parallel copy of it.

local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local InputDevice = require(StarterPlayer.StarterPlayerScripts.Client.Input.InputDevice)

return function()
	describe("ResolveDevice", function()
		it("resolves button-class UserInputTypes immediately, with no magnitude needed", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Keyboard, nil, nil)).to.equal("KeyboardMouse")
			expect(InputDevice.ResolveDevice(Enum.UserInputType.MouseButton1, nil, nil)).to.equal("KeyboardMouse")
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Touch, nil, nil)).to.equal("Touch")
		end)

		it("does not switch on a small MouseMovement delta", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.MouseMovement, nil, 0.5)).to.equal(nil)
		end)

		it("switches on a MouseMovement delta past the threshold", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.MouseMovement, nil, 25)).to.equal("KeyboardMouse")
		end)

		it("treats a Gamepad face-button press as immediate, unlike a thumbstick", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA, nil)).to.equal(
				"Gamepad"
			)
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Gamepad1, Enum.KeyCode.DPadUp, nil)).to.equal("Gamepad")
		end)

		it("does not switch on a small thumbstick nudge", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Gamepad1, Enum.KeyCode.Thumbstick1, 0.05)).to.equal(nil)
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Gamepad1, Enum.KeyCode.Thumbstick2, 0.05)).to.equal(nil)
		end)

		it("switches on a thumbstick nudge past the deadzone", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.Gamepad1, Enum.KeyCode.Thumbstick1, 0.9)).to.equal(
				"Gamepad"
			)
		end)

		it("has no opinion about a UserInputType it does not recognize", function()
			expect(InputDevice.ResolveDevice(Enum.UserInputType.TextInput, nil, nil)).to.equal(nil)
		end)
	end)

	describe("Current/OnChanged", function()
		-- InputDevice is a singleton -- SetCurrentForTesting below mutates the same Current() every
		-- other spec in this process reads, so every test that calls it restores KeyboardMouse
		-- afterward rather than leaving whichever device it left off on for the next spec file.
		afterEach(function()
			InputDevice.SetCurrentForTesting("KeyboardMouse")
		end)

		it("starts at a real Device value and never errors just from being read", function()
			local current = InputDevice.Current()
			expect(current == "KeyboardMouse" or current == "Gamepad" or current == "Touch").to.equal(true)
		end)

		it("returns an unsubscribe function that is safe to call more than once", function()
			local unsubscribe = InputDevice.OnChanged(function() end)
			unsubscribe()
			unsubscribe()
		end)

		it("fires OnChanged when the device actually changes", function()
			InputDevice.SetCurrentForTesting("KeyboardMouse")
			local fired = 0
			local unsubscribe = InputDevice.OnChanged(function()
				fired += 1
			end)

			InputDevice.SetCurrentForTesting("Gamepad")
			expect(fired).to.equal(1)
			expect(InputDevice.Current()).to.equal("Gamepad")

			unsubscribe()
		end)

		it("does not fire OnChanged when set to the device it already is", function()
			InputDevice.SetCurrentForTesting("Touch")
			local fired = 0
			local unsubscribe = InputDevice.OnChanged(function()
				fired += 1
			end)

			InputDevice.SetCurrentForTesting("Touch")
			expect(fired).to.equal(0)

			unsubscribe()
		end)
	end)

	describe("Observe", function()
		it("survives having no LocalPlayer, the same window Shell/Chrome.lua's ObserveModalGate guards for", function()
			-- This place has none, which is the point -- scripts/run-tests.lua require-loads this
			-- module on the server, and Observe has to come back with a usable Value there rather than
			-- erroring, per the module's own header.
			local scope = Fusion.scoped(Fusion)
			local device = InputDevice.Observe(scope)

			expect(device).to.be.ok()
			expect(Fusion.peek(device)).to.equal(InputDevice.Current())
		end)
	end)
end
