--!strict
-- Covers Client/Input/InputRouter.lua -- the shared UserInputService.InputBegan/InputEnded dispatch.
--
-- InputObject HAS NO PUBLIC CONSTRUCTOR, so every "input" below is a plain table cast to InputObject
-- with `:: any` -- HandleInputBegan/HandleInputEnded only ever read .KeyCode/.UserInputType off it
-- (via KeybindManager.Matches), and Lua does not runtime-check the annotation, so this drives the
-- exact same code path a real keypress does.
--
-- InputRouter IS A SINGLETON, so every test unbinds everything it registers and restores the real
-- modal predicate in afterEach -- leftover state here would leak into whichever spec the suite runs
-- next in the same process.

local StarterPlayer = game:GetService("StarterPlayer")

local InputRouter = require(StarterPlayer.StarterPlayerScripts.Client.Input.InputRouter)
local KeybindManager = require(StarterPlayer.StarterPlayerScripts.Client.Input.KeybindManager)
local Chord = require(StarterPlayer.StarterPlayerScripts.Client.Input.Chord)

return function()
	local unbinds: { () -> () } = {}

	local function bind(action: string, config: InputRouter.BindConfig): () -> ()
		local unbind = InputRouter.Bind(action :: any, config)
		table.insert(unbinds, unbind)
		return unbind
	end

	local function keyCodeFor(action: string): Enum.KeyCode
		local keybind = KeybindManager.Get(action :: any)
		assert(keybind.KeyCode ~= nil, `{action} has no keyboard KeyCode -- pick a different fixture action`)
		return keybind.KeyCode :: Enum.KeyCode
	end

	local function press(keyCode: Enum.KeyCode, gameProcessed: boolean?): ()
		InputRouter.HandleInputBegan(
			{ KeyCode = keyCode, UserInputType = Enum.UserInputType.Keyboard } :: any,
			gameProcessed == true
		)
	end

	local function release(keyCode: Enum.KeyCode): ()
		InputRouter.HandleInputEnded({ KeyCode = keyCode, UserInputType = Enum.UserInputType.Keyboard } :: any)
	end

	afterEach(function()
		for _, unbind in unbinds do
			unbind()
		end
		table.clear(unbinds)
		InputRouter.SetModalOpenPredicateForTesting(nil)
		-- Chord.lua is a singleton too, and a consumed-but-unreleased press would leak into the next
		-- spec in this process exactly the way a leftover binding would.
		Chord.SetHeldForTesting(nil)
		Chord.ClearPressesForTesting()
	end)

	describe("the modal gate", function()
		it("does not fire a Gameplay binding's Began while a modal panel is open", function()
			local began = 0
			bind("Dash", {
				Layer = "Gameplay",
				Began = function()
					began += 1
				end,
			})

			InputRouter.SetModalOpenPredicateForTesting(function()
				return true
			end)
			press(keyCodeFor("Dash"))

			expect(began).to.equal(0)
		end)

		it("fires a Gameplay binding's Ended regardless of the modal Attribute", function()
			local ended = 0
			bind("Slide", {
				Layer = "Gameplay",
				Ended = function()
					ended += 1
				end,
			})

			InputRouter.SetModalOpenPredicateForTesting(function()
				return true
			end)
			release(keyCodeFor("Slide"))

			expect(ended).to.equal(1)
		end)

		it("only fires a Menu binding's Began while a modal panel is open", function()
			local began = 0
			bind("Leap", {
				Layer = "Menu",
				Began = function()
					began += 1
				end,
			})

			press(keyCodeFor("Leap"))
			expect(began).to.equal(0)

			InputRouter.SetModalOpenPredicateForTesting(function()
				return true
			end)
			press(keyCodeFor("Leap"))
			expect(began).to.equal(1)
		end)
	end)

	describe("gameProcessed", function()
		it("drops a Gameplay Began when gameProcessed is true", function()
			local began = 0
			bind("Leap", {
				Layer = "Gameplay",
				Began = function()
					began += 1
				end,
			})

			press(keyCodeFor("Leap"), true)
			expect(began).to.equal(0)
		end)

		it("does not auto-drop a System Began when gameProcessed is true, unlike every other layer", function()
			local sawGameProcessed: boolean? = nil
			bind("SettingsToggle", {
				Layer = "System",
				Began = function(gameProcessed: boolean)
					sawGameProcessed = gameProcessed
				end,
			})

			press(keyCodeFor("SettingsToggle"), true)
			expect(sawGameProcessed).to.equal(true)
		end)
	end)

	describe("layer precedence", function()
		it("prefers Gameplay over System for the same action when both are relevant", function()
			local fired: { string } = {}
			bind("Dash", {
				Layer = "System",
				Began = function()
					table.insert(fired, "System")
				end,
			})
			bind("Dash", {
				Layer = "Gameplay",
				Began = function()
					table.insert(fired, "Gameplay")
				end,
			})

			press(keyCodeFor("Dash"))

			expect(#fired).to.equal(1)
			expect(fired[1]).to.equal("Gameplay")
		end)

		it("prefers Modal over Menu for the same action while a modal panel is open", function()
			InputRouter.SetModalOpenPredicateForTesting(function()
				return true
			end)

			local fired: { string } = {}
			bind("Leap", {
				Layer = "Menu",
				Began = function()
					table.insert(fired, "Menu")
				end,
			})
			bind("Leap", {
				Layer = "Modal",
				Began = function()
					table.insert(fired, "Modal")
				end,
			})

			press(keyCodeFor("Leap"))

			expect(#fired).to.equal(1)
			expect(fired[1]).to.equal("Modal")
		end)
	end)

	describe("Bind", function()
		it("returns an unbind function that is idempotent", function()
			local began = 0
			local unbind = bind("Dash", {
				Layer = "Gameplay",
				Began = function()
					began += 1
				end,
			})

			unbind()
			unbind()

			press(keyCodeFor("Dash"))
			expect(began).to.equal(0)
		end)
	end)

	describe("IsActionDown", function()
		it("returns false with nothing physically held", function()
			expect(InputRouter.IsActionDown("Dash" :: any)).to.equal(false)
		end)
	end)

	-- The router half of the chord layer. Chord.lua's own spec covers the resolution rules in
	-- isolation; what these assert is that DISPATCH honours them -- that the exclusivity is real at
	-- the point where a feature module's callback actually gets called, which is the only place it
	-- can bite a player. ButtonR1 carries BasicAttack plainly and Feint under the modifier, which is
	-- the collision pair Constants.Keybinds.GamepadChords was written around.
	describe("the gamepad chord layer", function()
		local CHORDED_KEY = Enum.KeyCode.ButtonR1
		local PLAIN_ACTION = "BasicAttack"
		local CHORD_ACTION = "Feint"

		local function padPress(keyCode: Enum.KeyCode): ()
			InputRouter.HandleInputBegan(
				{ KeyCode = keyCode, UserInputType = Enum.UserInputType.Gamepad1 } :: any,
				false
			)
		end

		local function padRelease(keyCode: Enum.KeyCode): ()
			InputRouter.HandleInputEnded({ KeyCode = keyCode, UserInputType = Enum.UserInputType.Gamepad1 } :: any)
		end

		-- Counts Began/Ended for the plain and chorded action sharing CHORDED_KEY.
		local function bindPair(): { plainBegan: number, plainEnded: number, chordBegan: number, chordEnded: number }
			local counts = { plainBegan = 0, plainEnded = 0, chordBegan = 0, chordEnded = 0 }
			bind(PLAIN_ACTION, {
				Layer = "Gameplay",
				Began = function()
					counts.plainBegan += 1
				end,
				Ended = function()
					counts.plainEnded += 1
				end,
			})
			bind(CHORD_ACTION, {
				Layer = "Gameplay",
				Began = function()
					counts.chordBegan += 1
				end,
				Ended = function()
					counts.chordEnded += 1
				end,
			})
			return counts
		end

		it("fires only the chorded action, never the button's plain action, with the modifier held", function()
			local counts = bindPair()

			Chord.SetHeldForTesting(true)
			padPress(CHORDED_KEY)

			expect(counts.chordBegan).to.equal(1)
			expect(counts.plainBegan).to.equal(0)
		end)

		it("fires the plain action when the modifier is not held", function()
			local counts = bindPair()

			Chord.SetHeldForTesting(false)
			padPress(CHORDED_KEY)

			expect(counts.plainBegan).to.equal(1)
			expect(counts.chordBegan).to.equal(0)
		end)

		-- The half that needs Chord.lua to REMEMBER the press: releasing after a chord must not fire
		-- the plain action's Ended, which would be a release with no matching Began.
		it("routes a chorded press's release to the chorded action alone", function()
			local counts = bindPair()

			Chord.SetHeldForTesting(true)
			padPress(CHORDED_KEY)
			-- Released the modifier before the button -- the press is still a chord, because the
			-- modifier is sampled at press time and remembered until this release.
			Chord.SetHeldForTesting(false)
			padRelease(CHORDED_KEY)

			expect(counts.chordEnded).to.equal(1)
			expect(counts.plainEnded).to.equal(0)
		end)

		it("dispatches nothing for the modifier's own press", function()
			local began = 0
			for action in pairs(Chord.Chords()) do
				bind(action :: any, {
					Layer = "Gameplay",
					Began = function()
						began += 1
					end,
				})
			end

			local modifier = Chord.Modifier()
			assert(modifier.KeyCode ~= nil, "the default chord modifier is expected to be a KeyCode")
			Chord.SetHeldForTesting(true)
			padPress(modifier.KeyCode :: Enum.KeyCode)

			expect(began).to.equal(0)
		end)
	end)
end
