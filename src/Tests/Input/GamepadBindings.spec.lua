--!strict
-- Covers Constants.Keybinds.GamepadDefaults/GamepadChords as a MAP -- the properties the whole
-- gamepad scheme depends on, rather than any one module's behaviour.
--
-- WHY A SPEC ON A CONSTANTS TABLE AT ALL. Most of that table is taste, and taste does not get a test.
-- What is asserted here is the small set of rules that are NOT taste: a reflex action must be
-- reachable without letting go of the movement stick, no two actions may claim one button, and the
-- chord layer must actually cover the actions that have no plain button. Each of these was violated
-- at some point by a change that looked locally reasonable, and none of them fails loudly at runtime
-- -- a mis-scheme is only discovered by a person holding a controller.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)

-- The D-pad. Reaching any of these on a gamepad means taking the LEFT THUMB off Thumbstick1, which
-- is the stick that steers -- so a binding here is unusable at any moment the player is also moving.
local DPAD: { [Enum.KeyCode]: true } = {
	[Enum.KeyCode.DPadUp] = true,
	[Enum.KeyCode.DPadDown] = true,
	[Enum.KeyCode.DPadLeft] = true,
	[Enum.KeyCode.DPadRight] = true,
}

return function()
	local gamepadDefaults = Constants.Keybinds.GamepadDefaults :: { [string]: any }
	local gamepadChords = Constants.Keybinds.GamepadChords :: { [string]: any }

	-- Actions a player performs WHILE MOVING, on a reflex, where the input either lands in a narrow
	-- window or is wasted. These are the ones that cannot live on the D-pad.
	local REFLEX_ACTIONS = { "Slide", "Dash" }

	describe("the movement-critical actions", function()
		-- The regression this file exists for. The dodge once sat on DPadLeft, and it is pressed WHILE
		-- steering -- the left thumb on Thumbstick1 cannot also be on the D-pad -- so on a pad the binding
		-- did not make it hard, it made it impossible.
		it("keeps every reflex action off the D-pad, so it can be pressed while steering", function()
			for _, action in REFLEX_ACTIONS do
				local keybind = gamepadDefaults[action]
				expect(keybind).to.be.ok()
				expect(DPAD[keybind.KeyCode]).to.equal(nil)
			end
		end)

		it("leaves the evade unbound by default -- the Dash button is its ground half", function()
			expect(gamepadDefaults.Evade).to.equal(nil)
		end)
	end)

	describe("the plain gamepad map", function()
		-- Two actions on one button is the failure mode this genre's convention family makes easy:
		-- every face and shoulder button already has a conventional owner, so a new binding is always
		-- tempted onto one that "seems free".
		it("never binds two actions to the same button", function()
			local seen: { [Enum.KeyCode]: string } = {}
			for action, keybind in pairs(gamepadDefaults) do
				local keyCode = keybind.KeyCode
				if keyCode == nil then
					continue
				end
				local existing = seen[keyCode]
				expect(existing == nil or existing == action).to.equal(true)
				seen[keyCode] = action
			end
		end)

		-- ButtonA is Roblox's own native Jump on every gamepad. Binding an action there double-fires
		-- on every jump, and nothing in this codebase can stop it -- see KeybindManager.IsJumpKeyDown.
		it("leaves ButtonA alone, since the engine owns it", function()
			for _, keybind in pairs(gamepadDefaults) do
				expect(keybind.KeyCode).never.to.equal(Enum.KeyCode.ButtonA)
			end
		end)

		it("does not bind the chord modifier to a plain action of its own", function()
			local modifier = Constants.Keybinds.GamepadModifier.KeyCode
			for _, keybind in pairs(gamepadDefaults) do
				expect(keybind.KeyCode).never.to.equal(modifier)
			end
		end)
	end)

	describe("the chord layer", function()
		-- These four are live gameplay actions with no plain gamepad button at all -- the chord map is
		-- the only thing making them reachable on a pad, so its coverage of them is load-bearing rather
		-- than incidental. Client/Input/Glyph.lua depends on the same fact to draw them.
		it("covers every action the plain map deliberately leaves unbound", function()
			for _, action in { "Leap", "Interact", "GrabThrow" } do
				expect(gamepadDefaults[action]).to.equal(nil)
				expect(gamepadChords[action]).to.be.ok()
			end
		end)

		it("never binds two chords to the same button", function()
			local seen: { [Enum.KeyCode]: string } = {}
			for action, keybind in pairs(gamepadChords) do
				local keyCode = keybind.KeyCode
				if keyCode == nil then
					continue
				end
				local existing = seen[keyCode]
				expect(existing == nil or existing == action).to.equal(true)
				seen[keyCode] = action
			end
		end)

		-- A chord ON the modifier is unpressable: the modifier is consumed as the modifier, so the
		-- press never reaches the chord map at all (Chord.Resolve returns "Modifier" first).
		it("never puts a chord on the modifier button itself", function()
			local modifier = Constants.Keybinds.GamepadModifier.KeyCode
			for _, keybind in pairs(gamepadChords) do
				expect(keybind.KeyCode).never.to.equal(modifier)
			end
		end)
	end)
end
