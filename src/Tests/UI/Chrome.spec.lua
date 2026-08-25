--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UI = StarterPlayer.StarterPlayerScripts.Client.UI
local Chrome = require(UI.Shell.Chrome)
local DeathFeed = require(UI.Screens.DeathFeed)

-- THE UI MODE, AND THE ONE PROPERTY THAT MAKES IT WORTH HAVING: nothing can set it.
--
-- Phase 3 of docs/architecture/2026-08-25-hud-shell-plan.md. The gap it closes (2.5) is that the dock
-- renders at full opacity behind every modal because there is no one to ask it to step back. The risk
-- in closing it is the classic one for a shared UI flag -- two screens each raising "menu mode" on
-- their open edge, one of them missing the close edge, and the HUD dimmed for the rest of the session
-- with nothing in the log. A mode DERIVED from a count and a nil check cannot get stuck, and the last
-- describe block in this file is the assertion that it stays derived.
--
-- NO RENDER PASS IS NEEDED HERE, deliberately. The tween that carries the dim lives in
-- Shell/Regions.lua next to the pixels; what Chrome hands over is a goal (0 or 1) that changes only
-- on mode edges. So every assertion below is about logic and reads its answer with Fusion.peek --
-- which is also the reason splitting the tween out of this module was worth doing.

type Scope = Fusion.Scope<typeof(Fusion)>

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

return function()
	-- Inside the returned function, per this suite's usual note: TestEZ injects `expect` into the
	-- environment of THIS function only.
	local function build(): (Scope, Fusion.Value<boolean>, Fusion.Value<boolean>, Chrome.ChromeHandle)
		local scope = Fusion.scoped(Fusion)
		local modalOpen: Fusion.Value<boolean> = scope:Value(false)
		local dead: Fusion.Value<boolean> = scope:Value(false)
		-- Plain Values rather than the real sources, which is what the ChromeProps split is FOR: the
		-- real modal fact arrives through Constants.Attributes.UiModalOpen and there is no LocalPlayer
		-- in this place to publish it, so a Chrome that read the Attribute internally would have an
		-- undrivable Menu branch. The real wiring is asserted separately, at the bottom of this file.
		return scope, modalOpen, dead, Chrome.New(scope, { ModalOpen = modalOpen, Dead = dead })
	end

	describe("the mode", function()
		it("is Playing when nothing is asked of the screen", function()
			local _, _, _, chrome = build()
			expect(Fusion.peek(chrome.Mode)).to.equal("Playing")
		end)

		it("is Menu while a panel is open, and back to Playing when it closes", function()
			local _, modalOpen, _, chrome = build()

			modalOpen:set(true)
			expect(Fusion.peek(chrome.Mode)).to.equal("Menu")
			-- The half that actually matters. A flag that raises correctly and never lowers is the
			-- failure this whole module is shaped to make impossible, so the close edge is asserted
			-- every time the open edge is.
			modalOpen:set(false)
			expect(Fusion.peek(chrome.Mode)).to.equal("Playing")
		end)

		it("is Dead while the player is down, and back to Playing on respawn", function()
			local _, _, dead, chrome = build()

			dead:set(true)
			expect(Fusion.peek(chrome.Mode)).to.equal("Dead")
			dead:set(false)
			expect(Fusion.peek(chrome.Mode)).to.equal("Playing")
		end)

		it("puts Dead ahead of Menu when both are true", function()
			-- Reachable by ordinary play: combat input is gated while a panel is open, but another
			-- player's is not, so being killed with the character menu up is a real state. The
			-- precedence is documented in Chrome.lua's header along with what it costs -- the scrim
			-- goes with Menu, so the panel spends the respawn countdown over an undimmed screen.
			local _, modalOpen, dead, chrome = build()

			modalOpen:set(true)
			dead:set(true)
			expect(Fusion.peek(chrome.Mode)).to.equal("Dead")

			-- And it un-stacks in either order.
			dead:set(false)
			expect(Fusion.peek(chrome.Mode)).to.equal("Menu")
			modalOpen:set(false)
			expect(Fusion.peek(chrome.Mode)).to.equal("Playing")
		end)
	end)

	describe("what the ambient layer reads off the mode", function()
		it("dims only in Menu", function()
			local _, modalOpen, dead, chrome = build()

			expect(Fusion.peek(chrome.Dim)).to.equal(0)
			modalOpen:set(true)
			expect(Fusion.peek(chrome.Dim)).to.equal(1)
			-- Dead outranks Menu, so the scrim lifts even though a panel is still open. Asserted
			-- rather than left implicit because it is the ONE consequence of the precedence choice
			-- that a player can see, and a future change to it should have to come through here.
			dead:set(true)
			expect(Fusion.peek(chrome.Dim)).to.equal(0)
		end)

		it("keeps the corner tiles up in every mode except Dead", function()
			local _, modalOpen, dead, chrome = build()

			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(true)
			-- A panel dims the corners; it does not take them away. The helm console is still telling
			-- a pilot which way the ship is pointing while they read their character sheet.
			modalOpen:set(true)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(true)

			dead:set(true)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(false)
			dead:set(false)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(true)
		end)
	end)

	describe("the mode is derived, not set", function()
		it("exposes no way to write it", function()
			local _, _, _, chrome = build()

			-- A Fusion Value has :set; a Computed does not. This is the difference between "the mode
			-- reflects what is happening" and "the mode is whatever the last screen to touch it said",
			-- and it is one property lookup to keep it that way.
			for _, field in { "Mode", "Dim", "AmbientVisible" } do
				local object = (chrome :: any)[field]
				expect(object).to.be.ok()
				if object.set ~= nil then
					error(
						string.format(
							"Chrome.%s is settable. Every value this module hands out is derived from "
								.. "facts their own owners publish -- a settable one is a flag a screen "
								.. "can leave raised (Chrome.lua's header).",
							field
						)
					)
				end
			end
		end)

		it("reads a real death off DeathFeed rather than off a flag of its own", function()
			-- The wiring UI/init.lua does, exercised end to end. Chrome's Dead input is DeathFeed's
			-- own handle field, so this drives the SCREEN and asserts the MODE -- if the two ever stop
			-- being the same fact, this is what says so.
			local scope = Fusion.scoped(Fusion)
			local deathFeed = DeathFeed.Mount(scope, fakePlayerGui(), 1)
			local chrome = Chrome.New(scope, { ModalOpen = scope:Value(false), Dead = deathFeed.Dead })

			expect(Fusion.peek(chrome.Mode)).to.equal("Playing")
			deathFeed.ShowDeath("someone")
			expect(Fusion.peek(chrome.Mode)).to.equal("Dead")
			deathFeed.ClearDeath()
			expect(Fusion.peek(chrome.Mode)).to.equal("Playing")
		end)

		it("survives having no LocalPlayer to read the modal gate from", function()
			-- This place has none, which is the point: Chrome.lua is require()d on the server by
			-- scripts/run-tests.lua's client load-check, and the adapter has to come back with a
			-- usable Value there rather than erroring. Same window ModalScreen's own publishModalGate
			-- guards for.
			local scope = Fusion.scoped(Fusion)
			local gate = Chrome.ObserveModalGate(scope)

			expect(gate).to.be.ok()
			expect(Fusion.peek(gate)).to.equal(false)
		end)
	end)
end
