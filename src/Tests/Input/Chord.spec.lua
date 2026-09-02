--!strict
-- Covers Client/Input/Chord.lua -- the gamepad's alternate binding layer, reached by holding
-- Constants.Keybinds.GamepadModifier.
--
-- InputObject HAS NO PUBLIC CONSTRUCTOR, so every "input" below is a plain table cast to InputObject
-- with `:: any` -- Resolve/ConsumePress/ReleasePress only ever read .KeyCode/.UserInputType off it,
-- and Lua does not runtime-check the annotation, so this drives the exact same path a real press
-- does. This is the same standing convention Tests/Input/InputRouter.spec.lua documents.
--
-- Resolve TAKES modifierHeld AS AN ARGUMENT, which is what makes the interesting half of this module
-- testable at all -- UserInputService cannot be made to report a held button from a spec. The one
-- test that needs the LIVE read (IsHeld, which InputRouter calls) goes through SetHeldForTesting.
--
-- CHORD IS A SINGLETON, so every test that consumes a press or forces the held state restores both
-- in afterEach -- leftover state here would leak into whichever spec runs next in the same process.

local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chord = require(StarterPlayer.StarterPlayerScripts.Client.Input.Chord)
local Constants = require(ReplicatedStorage.Shared.Constants)

return function()
	-- The collision pair the whole layer is written around: ButtonR1 is BasicAttack plainly and
	-- Feint under the modifier.
	local CHORDED_KEY = Enum.KeyCode.ButtonR1
	local CHORD_ACTION = "Feint"

	local function padInput(keyCode: Enum.KeyCode): InputObject
		return { KeyCode = keyCode, UserInputType = Enum.UserInputType.Gamepad1 } :: any
	end

	afterEach(function()
		Chord.ClearPressesForTesting()
		Chord.SetHeldForTesting(nil)
		Chord.ResetModifier()
	end)

	-- scripts/run-tests.lua require-loads this module on the SERVER, where Players.LocalPlayer is
	-- nil. Asserting that here makes the require itself the first thing that can fail, per the
	-- standing rule for every module under Client/Input.
	describe("construction", function()
		it("loads and answers with no LocalPlayer", function()
			expect(Chord.Modifier()).to.be.ok()
			expect(Chord.Modifier().KeyCode).to.equal(Constants.Keybinds.GamepadModifier.KeyCode)
		end)
	end)

	describe("Resolve", function()
		it("returns Plain for a chorded button when the modifier is not held", function()
			local resolution = Chord.Resolve(padInput(CHORDED_KEY), false)
			expect(resolution.Kind).to.equal("Plain")
		end)

		it("returns the chorded action when the modifier is held", function()
			local resolution = Chord.Resolve(padInput(CHORDED_KEY), true)
			expect(resolution.Kind).to.equal("Chord")
			expect(resolution.Action).to.equal(CHORD_ACTION)
		end)

		it("returns Modifier for the modifier's own press, which is never an action", function()
			local modifier = Constants.Keybinds.GamepadModifier
			local resolution = Chord.Resolve(padInput(modifier.KeyCode :: Enum.KeyCode), true)
			expect(resolution.Kind).to.equal("Modifier")
		end)

		-- A held modifier must not silently swallow every unrelated button -- that would read as a
		-- broken controller rather than a layer. See this module's own note on the fallthrough.
		it("falls through to Plain for a button with no chord binding, even with the modifier held", function()
			local resolution = Chord.Resolve(padInput(Enum.KeyCode.ButtonSelect), true)
			expect(resolution.Kind).to.equal("Plain")
		end)

		it("is pure -- resolving records nothing for a later release to find", function()
			Chord.Resolve(padInput(CHORDED_KEY), true)
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(nil)
		end)
	end)

	-- The sampling rule, which is the whole reason this module holds state instead of polling.
	describe("press sampling", function()
		it("remembers a chorded press so its release routes to the same action", function()
			Chord.ConsumePress(padInput(CHORDED_KEY), true)
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(CHORD_ACTION)
		end)

		it("keeps a press chorded even if the modifier is released first", function()
			Chord.ConsumePress(padInput(CHORDED_KEY), true)
			-- The modifier is now up, but the press was already sampled as a chord.
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(CHORD_ACTION)
		end)

		it("records nothing for a press made with the modifier already released", function()
			local resolution = Chord.ConsumePress(padInput(CHORDED_KEY), false)
			expect(resolution.Kind).to.equal("Plain")
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(nil)
		end)

		it("answers exactly once per press -- a release is the end of that press", function()
			Chord.ConsumePress(padInput(CHORDED_KEY), true)
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(CHORD_ACTION)
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(nil)
		end)

		it("tracks two chorded buttons independently", function()
			local second = Constants.Keybinds.GamepadChords.Leap
			assert(second ~= nil and second.KeyCode ~= nil, "Leap is expected to hold a chord KeyCode")

			Chord.ConsumePress(padInput(CHORDED_KEY), true)
			Chord.ConsumePress(padInput(second.KeyCode :: Enum.KeyCode), true)

			expect(Chord.ReleasePress(padInput(second.KeyCode :: Enum.KeyCode))).to.equal("Leap")
			expect(Chord.ReleasePress(padInput(CHORDED_KEY))).to.equal(CHORD_ACTION)
		end)
	end)

	describe("the modifier", function()
		it("reports a rebound modifier and resolves through it", function()
			Chord.SetModifier({ KeyCode = Enum.KeyCode.ButtonL3 })

			expect(Chord.Modifier().KeyCode).to.equal(Enum.KeyCode.ButtonL3)
			expect(Chord.IsModifier(padInput(Enum.KeyCode.ButtonL3))).to.equal(true)
			-- The old modifier is now an ordinary button.
			expect(Chord.IsModifier(padInput(Enum.KeyCode.ButtonL2))).to.equal(false)
		end)

		it("leaves the chord map untouched when the modifier moves -- only the door changes", function()
			Chord.SetModifier({ KeyCode = Enum.KeyCode.ButtonL3 })
			local resolution = Chord.Resolve(padInput(CHORDED_KEY), true)
			expect(resolution.Kind).to.equal("Chord")
			expect(resolution.Action).to.equal(CHORD_ACTION)
		end)

		it("restores the default modifier on reset", function()
			Chord.SetModifier({ KeyCode = Enum.KeyCode.ButtonL3 })
			Chord.ResetModifier()
			expect(Chord.Modifier().KeyCode).to.equal(Constants.Keybinds.GamepadModifier.KeyCode)
		end)

		it("reports the forced held state through IsHeld, the live read InputRouter calls", function()
			Chord.SetHeldForTesting(true)
			expect(Chord.IsHeld()).to.equal(true)
			Chord.SetHeldForTesting(false)
			expect(Chord.IsHeld()).to.equal(false)
		end)
	end)

	describe("Chords", function()
		it("returns a copy a caller cannot use to mutate the real map", function()
			local copy = Chord.Chords()
			copy[CHORD_ACTION :: any] = nil

			expect(Chord.Get(CHORD_ACTION :: any)).to.be.ok()
		end)

		it("covers every action Constants.Keybinds.GamepadChords declares", function()
			for action, keybind in pairs(Constants.Keybinds.GamepadChords) do
				local bound = Chord.Get(action :: any)
				expect(bound).to.be.ok()
				expect((bound :: any).KeyCode).to.equal((keybind :: any).KeyCode)
			end
		end)

		-- The four actions the layer exists to rescue -- Constants' own header names them as live
		-- gameplay actions that had no gamepad binding at all before this map.
		it("binds the actions that had no plain gamepad button left", function()
			for _, action in { "Leap", "Interact", "GrabThrow", "Feint" } do
				expect(Chord.Get(action :: any)).to.be.ok()
			end
		end)
	end)
end
