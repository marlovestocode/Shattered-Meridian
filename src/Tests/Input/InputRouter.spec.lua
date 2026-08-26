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
			bind("Roll", {
				Layer = "Menu",
				Began = function()
					began += 1
				end,
			})

			press(keyCodeFor("Roll"))
			expect(began).to.equal(0)

			InputRouter.SetModalOpenPredicateForTesting(function()
				return true
			end)
			press(keyCodeFor("Roll"))
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
			bind("Roll", {
				Layer = "Menu",
				Began = function()
					table.insert(fired, "Menu")
				end,
			})
			bind("Roll", {
				Layer = "Modal",
				Began = function()
					table.insert(fired, "Modal")
				end,
			})

			press(keyCodeFor("Roll"))

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
end
