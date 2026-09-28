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

		it("keeps the corner tiles up only while Playing", function()
			local _, modalOpen, dead, chrome = build()

			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(true)
			-- Out-of-focus UI disappears: a panel takes the corners away rather than dimming them
			-- (a design change from the original "dim, never hide" rule, made on request).
			modalOpen:set(true)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(false)
			modalOpen:set(false)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(true)

			dead:set(true)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(false)
			dead:set(false)
			expect(Fusion.peek(chrome.AmbientVisible)).to.equal(true)
		end)

		it("takes the dock away behind a panel, but keeps it through a death", function()
			local _, modalOpen, dead, chrome = build()

			expect(Fusion.peek(chrome.DockVisible)).to.equal(true)
			modalOpen:set(true)
			expect(Fusion.peek(chrome.DockVisible)).to.equal(false)
			modalOpen:set(false)
			expect(Fusion.peek(chrome.DockVisible)).to.equal(true)

			-- An empty health bar is what a dead player is meant to be looking at.
			dead:set(true)
			expect(Fusion.peek(chrome.DockVisible)).to.equal(true)
		end)
	end)

	describe("the Escape stack", function()
		-- Phase 4, plan section 8. The gap it closes (2.6) is that Escape was handled unconditionally
		-- by four screens and not at all by five, so Escape with two panels stacked closed both and
		-- Escape with the character menu up closed nothing.
		--
		-- DRIVEN THROUGH HandleEscape RATHER THAN THROUGH A KEYPRESS, because a headless place has no
		-- way to press a key. That is the whole reason HandleEscape is on the handle at all: the
		-- InputBegan connection in Chrome.New does nothing but call it, so a test that drives it is
		-- testing the same code path the key does rather than a parallel one.
		it("closes the topmost entry and only the topmost", function()
			local _, _, _, chrome = build()
			local closed: { string } = {}

			chrome:PushEscape("Under", function()
				table.insert(closed, "Under")
			end)
			chrome:PushEscape("Over", function()
				table.insert(closed, "Over")
			end)

			expect(chrome:HandleEscape()).to.equal(true)
			expect(#closed).to.equal(1)
			expect(closed[1]).to.equal("Over")

			expect(chrome:HandleEscape()).to.equal(true)
			expect(#closed).to.equal(2)
			expect(closed[2]).to.equal("Under")
		end)

		it("does not consume Escape once the stack is empty", function()
			-- The other half of the same guarantee, and the one a player notices: with nothing open,
			-- Escape has to reach Roblox's own menu untouched. See Chrome.lua's header on why "does
			-- not consume" is the honest claim here rather than "sinks or does not sink" -- Escape is
			-- not sinkable from a game script at all.
			local _, _, _, chrome = build()

			expect(chrome:HandleEscape()).to.equal(false)

			local handle = chrome:PushEscape("Only", function() end)
			handle:Pop()
			expect(chrome:HandleEscape()).to.equal(false)
		end)

		it("pops an entry out of the middle of the stack", function()
			-- The order-independence requirement. A screen closed by its own toggle key while another
			-- panel sits above it must come out cleanly, and the panel above must still be the one
			-- Escape closes next.
			local _, _, _, chrome = build()
			local closed: { string } = {}

			local under = chrome:PushEscape("Under", function()
				table.insert(closed, "Under")
			end)
			chrome:PushEscape("Over", function()
				table.insert(closed, "Over")
			end)

			under:Pop()
			expect(chrome:EscapeStack()[1]).to.equal("Over")
			expect(#chrome:EscapeStack()).to.equal(1)

			chrome:HandleEscape()
			expect(closed[1]).to.equal("Over")
			expect(chrome:HandleEscape()).to.equal(false)
		end)

		it("treats a second Pop as a no-op rather than an error", function()
			-- Not defensive coding: it is the NORMAL path. BindEscape pops on its screen's close
			-- edge, and Escape closing that screen fires exactly that edge -- so the entry Chrome
			-- just removed gets popped again a moment later, every single time.
			local _, _, _, chrome = build()

			local handle = chrome:PushEscape("Once", function() end)
			chrome:PushEscape("Keep", function() end)

			handle:Pop()
			handle:Pop()

			expect(#chrome:EscapeStack()).to.equal(1)
			expect(chrome:EscapeStack()[1]).to.equal("Keep")
		end)

		it("pops before it closes, so a re-entrant Pop cannot take the entry underneath", function()
			-- The specific bug this ordering exists to stop. Close flips the screen's IsOpen, which
			-- fires BindEscape's Observer, which pops -- and if HandleEscape had not already removed
			-- its own entry, that re-entrant pop would remove it and HandleEscape's own remove would
			-- then take the panel below with it.
			local _, _, _, chrome = build()
			local closed: { string } = {}

			chrome:PushEscape("Under", function()
				table.insert(closed, "Under")
			end)
			local over: Chrome.EscapeHandle
			over = chrome:PushEscape("Over", function()
				table.insert(closed, "Over")
				over:Pop()
			end)

			chrome:HandleEscape()

			expect(#closed).to.equal(1)
			expect(#chrome:EscapeStack()).to.equal(1)
			expect(chrome:EscapeStack()[1]).to.equal("Under")
		end)

		it("hands back a copy of the stack, not the stack", function()
			local _, _, _, chrome = build()
			chrome:PushEscape("Real", function() end)

			local names = chrome:EscapeStack()
			table.clear(names)

			expect(#chrome:EscapeStack()).to.equal(1)
		end)
	end)

	describe("BindEscape", function()
		it("pushes when the screen opens and pops when it closes", function()
			local scope, _, _, chrome = build()
			local isOpen: Fusion.Value<boolean> = scope:Value(false)
			local closes = 0

			chrome:BindEscape("Panel", isOpen, function()
				closes += 1
				isOpen:set(false)
			end)

			expect(#chrome:EscapeStack()).to.equal(0)

			isOpen:set(true)
			expect(#chrome:EscapeStack()).to.equal(1)

			-- Closed by its OWN toggle, not by Escape. The pop still has to happen, and this is the
			-- edge a hand-written push/pop pair forgets.
			isOpen:set(false)
			expect(#chrome:EscapeStack()).to.equal(0)
			expect(closes).to.equal(0)

			isOpen:set(true)
			chrome:HandleEscape()
			expect(closes).to.equal(1)
			expect(#chrome:EscapeStack()).to.equal(0)
		end)

		it("pushes immediately for a screen that is already open when it binds", function()
			-- A Lazy screen resolves its handle on first open, so LiveConsole and Storybook bind at a
			-- moment the panel may already be up. Waiting for the next change would leave that first
			-- opening unclosable.
			local scope, _, _, chrome = build()
			local isOpen: Fusion.Value<boolean> = scope:Value(true)

			chrome:BindEscape("AlreadyOpen", isOpen, function() end)

			expect(#chrome:EscapeStack()).to.equal(1)
			expect(chrome:EscapeStack()[1]).to.equal("AlreadyOpen")
		end)

		it("never puts one screen on the stack twice", function()
			-- An Observer can fire on a set that did not change the value. Two entries for one panel
			-- would mean two Escapes to close it, which is the sort of thing that only shows up in
			-- play.
			local scope, _, _, chrome = build()
			local isOpen: Fusion.Value<boolean> = scope:Value(false)

			chrome:BindEscape("Panel", isOpen, function() end)

			isOpen:set(true)
			isOpen:set(true)
			isOpen:set(true)

			expect(#chrome:EscapeStack()).to.equal(1)
		end)

		it("stacks a layer above its own screen and closes them outermost first", function()
			-- The move editor's F1 overlay, and Settings' keybind capture, are both this shape: a
			-- second entry pushed while the first is still open. Before Phase 4 each was a branch in
			-- an if-chain inside one screen's private handler.
			local scope, _, _, chrome = build()
			local editorOpen: Fusion.Value<boolean> = scope:Value(false)
			local overlayOpen: Fusion.Value<boolean> = scope:Value(false)
			local closed: { string } = {}

			chrome:BindEscape("Editor", editorOpen, function()
				table.insert(closed, "Editor")
				editorOpen:set(false)
			end)
			chrome:BindEscape("Overlay", overlayOpen, function()
				table.insert(closed, "Overlay")
				overlayOpen:set(false)
			end)

			editorOpen:set(true)
			overlayOpen:set(true)
			expect(#chrome:EscapeStack()).to.equal(2)

			chrome:HandleEscape()
			expect(closed[1]).to.equal("Overlay")
			-- The editor is still up, which is the whole point -- dismissing the shortcut list used
			-- to close the editor underneath it.
			expect(#chrome:EscapeStack()).to.equal(1)

			chrome:HandleEscape()
			expect(closed[2]).to.equal("Editor")
			expect(#chrome:EscapeStack()).to.equal(0)
		end)

		it("closes the last-opened panel first when two unrelated screens are up", function()
			-- Plan 2.6 in one gesture: open Settings, then the character menu, press Escape once.
			-- Before this phase, either both closed or neither did.
			local scope, _, _, chrome = build()
			local settingsOpen: Fusion.Value<boolean> = scope:Value(false)
			local menuOpen: Fusion.Value<boolean> = scope:Value(false)

			chrome:BindEscape("Settings", settingsOpen, function()
				settingsOpen:set(false)
			end)
			chrome:BindEscape("CharacterMenu", menuOpen, function()
				menuOpen:set(false)
			end)

			settingsOpen:set(true)
			menuOpen:set(true)

			chrome:HandleEscape()
			expect(Fusion.peek(menuOpen)).to.equal(false)
			expect(Fusion.peek(settingsOpen)).to.equal(true)

			chrome:HandleEscape()
			expect(Fusion.peek(settingsOpen)).to.equal(false)
			expect(chrome:HandleEscape()).to.equal(false)
		end)
	end)

	describe("the mode is derived, not set", function()
		it("exposes no way to write it", function()
			local _, _, _, chrome = build()

			-- A Fusion Value has :set; a Computed does not. This is the difference between "the mode
			-- reflects what is happening" and "the mode is whatever the last screen to touch it said",
			-- and it is one property lookup to keep it that way.
			for _, field in { "Mode", "Dim", "AmbientVisible", "DockVisible" } do
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
