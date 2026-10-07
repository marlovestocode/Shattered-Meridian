--!strict
--[[
	Shell/Chrome.lua

	Owns: what the client's UI is currently DOING -- playing, in a menu, or dead -- as one derived
	value, plus the two presentation facts the ambient layer reads off it.

	Does NOT own: any of the underlying facts. Every input here is published by whoever already owns
	it -- Components/ModalScreen.lua owns the modal count, Screens/DeathFeed owns whether the local
	player is down -- and this file only names the combination. Nothing sets the mode; if a mode ever
	needs a fact nobody publishes, the answer is to publish that fact at its owner, not to let a
	screen assert a mode.

	THE MODE IS A Computed, AND THAT IS THE POINT rather than a style rule. The failure it forecloses
	is the one every hand-rolled UI-state flag reaches eventually: two screens each setting "menu
	mode" on their own open edge, one of them forgetting the close edge, and the HUD staying dimmed
	for the rest of the session with nothing in the log. A value derived from a count and a nil check
	cannot get stuck, because there is no edge to miss -- it is the count and the nil check.

	THREE MODES, NOT THE FIVE THIS PHASE WAS SPECCED WITH, and the two that are gone were not dropped
	for being unused -- they are unreachable. docs/architecture/2026-08-25-hud-shell-plan.md 3.4 lists
	Playing | Menu | Cinematic | Dead | Boot, with Cinematic and Boot coming off Onboarding and Intro.
	Client/Main.client.lua runs StartMenuClient.Run(), then LoadingClient.Run(), then IntroClient.Run()
	-- which BLOCKS through the entire cinematic and character creator -- and only then calls
	UI.Mount(). So by the time this module exists, every surface those two modes describe has already
	been torn down, and the dock they would have hidden was never built. The plan's own 2.5 says the
	dock "renders at full opacity ... during the intro cinematic"; it does not, because there is no
	dock yet.

	Declaring them anyway would have meant two branches no session can enter and no spec can drive.
	The day something runs a cinematic AFTER boot -- a cutscene, a scripted set piece -- it publishes
	that fact at its own owner and this file grows a fourth mode, one Computed branch and one line in
	Tests/UI/Chrome.spec.lua. That is a smaller change than the two dead branches would have been to
	keep honest in the meantime.

	DEAD OUTRANKS MENU, and the cost of that is worth stating rather than discovering. The mode is one
	value, so a player killed with the character menu open reads as Dead: the ambient corner tiles
	drop (right -- they describe a world that player is no longer standing in) and the scrim goes with
	Menu (wrong -- the panel is still up, now over an undimmed screen, until it is closed or the
	respawn lands). The alternative -- deriving each binding from the raw facts instead of from the
	mode -- composes correctly and was rejected because it leaves the mode with no consumer at all,
	which is how a value that Phase 4's Escape stack depends on quietly rots before Phase 4 arrives.
	A few seconds of an undimmed menu during a respawn countdown is the cheaper wrong.

	WHY THE MODAL GATE IS READ FROM AN Attribute RATHER THAN FROM ModalScreen DIRECTLY. The count is
	module-scope state inside a Component, published to AttributeConstants.UiModalOpen -- which is
	already the seam Client/Combat/AttackInputClient.lua, GrabInputClient.lua, DefenseClient.lua and
	Client/Blimp/BlimpController.lua all read as a hard input gate. This codebase's rule is that
	cross-system influence travels through an Attribute seam rather than a require, and adding a
	parallel Fusion counter here would be a second answer to a question that already has one. So
	ObserveModalGate below is an ADAPTER over that seam and nothing more: it is the only thing in this
	file that touches an Instance, it is a separate function so a spec can hand New a plain Value
	instead, and it is the only place a LocalPlayer is looked up.

	NO RunService CONNECTION, per plan 11 rule 1. Both inputs change on edges that already exist (an
	Attribute write, a Fusion Value set), so the mode recomputes when something happens and costs
	exactly nothing when nothing does. The motion that carries the dim is a tween, and it lives in
	Shell/Regions.lua next to the pixels rather than here -- which is also what leaves this file
	testable without a render pass.

	================================================================================================
	THE ESCAPE STACK (Phase 4, plan section 8)
	================================================================================================

	ONE UserInputService.InputBegan FOR Escape, IN THIS FILE AND NOWHERE ELSE. Before this there were
	four independent Escape handlers (Settings' keybind capture, MoveEditor, KitEditor, EmoteWheel)
	and nine panels, five of which -- the character menu, the dev menu, the bug report form, the live
	console and the storybook -- could not be dismissed with Escape at all. Each of the four handled
	it unconditionally, so Escape with two panels stacked closed both. There was no shared ordering
	because there was no shared owner.

	THE STACK IS THE ARBITER, NOT THE MODE. An earlier draft of this header said the Escape stack
	would read Mode "to decide whether Escape belongs to a panel or to Roblox's own menu" -- it does
	not, and it should not. Mode is one value with a precedence (Dead outranks Menu), and a player
	killed with a panel open still wants Escape to close the panel. Whether anything is listening is
	answered by whether the stack is empty, which is the fact the question was actually about.

	ESCAPE IS NOT SINKABLE HERE, AND THAT IS PRE-EXISTING RATHER THAN A THING THIS INTRODUCES. Roblox
	opens its own menu on Escape at the CoreGui level, above every game script -- Shared/Constants.lua
	says so at SettingsToggle's own comment ("this repo never disables Roblox's own native Escape/Menu
	overlay"), which is why the settings toggle is K and not Escape. So "Escape closes the topmost
	panel" has always meant "and the Roblox menu opens on top of the result", for all four handlers
	that predate this one. What an EMPTY stack guarantees is narrower and is still worth stating: with
	nothing pushed, this connection does nothing at all, so Escape is the Roblox menu and only that.

	PUSH/POP IS THE PRIMITIVE; BindEscape IS HOW EVERY PANEL ACTUALLY USES IT. A raw PushEscape needs
	a matching Pop on every close path a screen has -- its own toggle key, its "X" button, a guarded
	close that sometimes declines -- and a screen with three close paths and two pops is the same
	forgotten-edge failure the mode Computed above exists to foreclose. BindEscape drives both edges
	off the screen's own IsOpen Value instead, so there is no edge to forget: the stack is derived
	from the same fact the panel's visibility is, which is the posture the rest of this file takes
	about modes.

	THE ONE CALLER OF THE RAW PRIMITIVE IS NOT A PANEL. Settings' keybind-capture mode pushes its own
	entry so that Escape abandons a mis-clicked "Rebind" without also closing the panel underneath it
	-- and what says "a capture is running" there is a nilable ListeningFor table, not a boolean, in a
	module with no Fusion scope to make one from. Its beginCapture/cancelCapture are already an
	exactly-matched pair, which is the bar for reaching past BindEscape.

	LAYERS AS WELL AS PANELS. Settings' key capture pushes above Settings itself; it used to be a
	branch of an if-chain inside that screen's own Escape handler, and it is the same shape as the
	panel-over-panel case -- which is the argument for a stack rather than a registry.

	POP IS IDEMPOTENT AND ORDER-INDEPENDENT. A screen closed by its own toggle while a second panel
	sits above it pops out of the middle of the stack, and popping twice is a no-op rather than an
	error -- both because BindEscape's own close edge fires on a screen this file just closed, so the
	second pop is the NORMAL case rather than a defensive one.

	ButtonB IS A SECOND KEY INTO THIS SAME STACK, NOT A SECOND STACK. A gamepad's "back" is the same
	sentence Escape already is -- dismiss the topmost thing -- so it is one more KeyCode on this
	file's own connection rather than a parallel arbiter registered in Shell/Focus.lua. A separate
	gamepad Back stack would reproduce, exactly, the four-independent-handlers bug the paragraphs
	above describe, only with the two stacks now also able to disagree about ORDER.

	ButtonB IS ALSO Dash, AND THE TWO DO NOT COLLIDE, because they are never both live. Dash is bound
	on the "Gameplay" layer, which Client/Input/InputRouter.lua drops entirely while
	AttributeConstants.UiModalOpen is set; and an empty stack makes HandleEscape a no-op (see the
	sinkability note above). So ButtonB with a panel open is Back and only Back, ButtonB with nothing
	open is Dash and only Dash, and neither needs to know about the other. Unlike Escape, ButtonB is
	NOT sunk by Roblox at the CoreGui level, so this really is the whole arbitration for it.

	A FOCUSED TextBox WINS, AND IT WINS HERE RATHER THAN IN THE BUG REPORT FORM. Escape while a field
	has focus means "give up on this field", and Roblox's own TextBox already does that. The plan put
	the check in BugReportClient because that is the screen with the obvious multi-line field; it is
	one rule about what Escape means, so it belongs in the one place that owns what Escape means.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- The two keys that mean "dismiss the topmost thing" -- see the ButtonB note in this file's header.
local DISMISS_KEYCODES: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Escape] = true,
	[Enum.KeyCode.ButtonB] = true,
}

-- One entry on the Escape stack. Not exported: the identity of the table is what Pop finds, so
-- handing one out would let a caller hold something that looks like a handle and is not one.
type EscapeEntry = {
	Name: string,
	Close: () -> (),
}

-- Playing: the ordinary state, and the only one in which every surface is at full strength.
-- Menu:    at least one ModalScreen is open. Combat input is already hard-gated here.
-- Dead:    the local player is down and the respawn overlay is up.
export type Mode = "Playing" | "Menu" | "Dead"

-- What PushEscape hands back. One method, and holding it is optional: a caller that used BindEscape
-- never sees one, and a caller that did push can drop it if the entry is meant to live as long as
-- the session.
export type EscapeHandle = {
	-- Removes this entry from the stack, wherever in it the entry currently sits. Safe to call more
	-- than once and safe to call on an entry Escape has already closed -- see the idempotence note in
	-- this file's header for why that is the ordinary case rather than a guard.
	Pop: (self: EscapeHandle) -> (),
}

export type ChromeHandle = {
	-- What the UI is doing. Derived; nothing writes it.
	Mode: Fusion.Computed<Mode>,
	-- 0..1, a GOAL rather than an animated value -- see the tween note in this file's header.
	Dim: Fusion.Computed<number>,
	-- Whether the ambient corner tiles are on screen at all. Playing only.
	AmbientVisible: Fusion.Computed<boolean>,
	-- Whether the hotbar dock is on screen. Everything but Menu.
	DockVisible: Fusion.Computed<boolean>,

	-- Puts `close` on top of the Escape stack. `name` is for the log and for the specs; it is not a
	-- key, and two entries may share one. Use BindEscape below unless the screen's open state is not
	-- a Fusion value.
	PushEscape: (self: ChromeHandle, name: string, close: () -> ()) -> EscapeHandle,
	-- The shape nearly every caller wants: pushes while `isOpen` is true and pops when it goes false,
	-- for as long as Chrome's scope lives. Pushes immediately if the screen is already open.
	BindEscape: (self: ChromeHandle, name: string, isOpen: UsedAs<boolean>, close: () -> ()) -> (),
	-- Closes the topmost entry, and returns whether there was one. The InputBegan connection calls
	-- this; it is exposed because a headless spec has no way to press a key, and asserting the stack
	-- through the same function the keypress goes through is the only way the two cannot drift.
	HandleEscape: (self: ChromeHandle) -> boolean,
	-- The stack top-last, as names. For specs and for the log -- a copy, so a caller cannot reorder
	-- the real thing.
	EscapeStack: (self: ChromeHandle) -> { string },
}

export type ChromeProps = {
	-- Whether any ModalScreen is open. In the client this is ObserveModalGate's Value; a spec passes
	-- its own so the Menu branch is drivable without a LocalPlayer.
	ModalOpen: UsedAs<boolean>,
	-- Whether the local player is dead. Screens/DeathFeed's handle exposes this off the same Value
	-- that drives the respawn overlay, so the two can never disagree about it.
	Dead: UsedAs<boolean>,
}

local Chrome = {}

-- The one adapter between AttributeConstants.UiModalOpen and Fusion. Returns a Value that mirrors
-- the Attribute for as long as the scope lives.
--
-- RETURNS A PERMANENTLY-false VALUE WHEN THERE IS NO LocalPlayer, rather than erroring. That is not
-- defensive coding for its own sake: this module is require()d on the server by
-- scripts/run-tests.lua's client load-check, where Players.LocalPlayer is nil -- the same window
-- Components/ModalScreen.lua's own publishModalGate guards for, and for the same reason (the
-- Attribute exists to gate a local player's input, and there is no local player).
function Chrome.ObserveModalGate(scope: Scope): Fusion.Value<boolean>
	local open: Fusion.Value<boolean> = scope:Value(false)

	local player = Players.LocalPlayer
	if player == nil then
		return open
	end

	local function read(): ()
		open:set(player:GetAttribute(AttributeConstants.UiModalOpen) == true)
	end

	-- Read once before connecting, not only on the next change. A modal open at the moment this is
	-- constructed would otherwise leave the mode reading Playing until the player closed it -- and
	-- while UI.Mount() is not a window in which a modal can already be open today, "the first value
	-- arrives on the first edge" is exactly the assumption that breaks the day one can be.
	read()
	table.insert(scope, player:GetAttributeChangedSignal(AttributeConstants.UiModalOpen):Connect(read))

	return open
end

-- Builds the mode and the two bindings that read off it. Takes its facts as arguments and holds
-- nothing globally, the same posture Shell/Surface.lua and Shell/Regions.lua take -- see the
-- memoization note in Regions' header for the hot-reload failure a module-level cache causes here.
function Chrome.New(scope: Scope, props: ChromeProps): ChromeHandle
	local mode = scope:Computed(function(use): Mode
		-- Order is the precedence, and it is the whole of the arbitration -- see the DEAD OUTRANKS
		-- MENU note in this file's header for what it costs.
		if use(props.Dead) then
			return "Dead"
		end
		if use(props.ModalOpen) then
			return "Menu"
		end
		return "Playing"
	end)

	-- Top is the END of the array, so a push is an insert and a pop of the top is a remove -- both
	-- O(1) -- and popping out of the middle (the order-independence requirement) is the only linear
	-- case. There are nine possible entries in the whole client, so the scan costs nothing.
	local escapeStack: { EscapeEntry } = {}

	local handle: ChromeHandle

	handle = {
		Mode = mode,
		-- Full dim behind a panel, none otherwise. How dark "full" actually is belongs to
		-- Shell/Regions.lua (SCRIM_TRANSPARENCY), not here: this file says WHEN the layer steps back,
		-- never how far.
		Dim = scope:Computed(function(use): number
			return if use(mode) == "Menu" then 1 else 0
		end),
		-- The corner readouts describe the world around the player, and they are only worth screen
		-- space while the player is IN it: a dead player is not, and a player reading a panel has taken
		-- their eyes off it. So they leave in both -- out-of-focus UI disappears rather than sitting
		-- dimmed behind the panel (the scrim still dims the WORLD behind a panel; there is just no HUD
		-- left under it to dim).
		AmbientVisible = scope:Computed(function(use): boolean
			return use(mode) == "Playing"
		end),
		-- The hotbar dock is the player's own controls, so it follows a different rule from the corners:
		-- it survives Dead (an empty health bar is what a dead player is meant to be looking at -- see
		-- Shell/Regions.lua's BottomCentre note) but leaves behind a panel, where it would only compete
		-- with the thing the player opened. Read by Screens/HUD, which carries the exit on
		-- Components/Reveal.lua rather than a bare Visible binding, so it recedes instead of blinking out.
		DockVisible = scope:Computed(function(use): boolean
			return use(mode) ~= "Menu"
		end),

		PushEscape = function(_self, name: string, close: () -> ()): EscapeHandle
			local entry: EscapeEntry = { Name = name, Close = close }
			table.insert(escapeStack, entry)

			return {
				Pop = function(): ()
					local at = table.find(escapeStack, entry)
					if at ~= nil then
						table.remove(escapeStack, at)
					end
				end,
			} :: EscapeHandle
		end,

		BindEscape = function(self, name: string, isOpen: UsedAs<boolean>, close: () -> ()): ()
			local pushed: EscapeHandle? = nil

			local function sync(): ()
				if peek(isOpen) then
					-- Already on the stack: an Observer can fire on a set that did not change the
					-- value, and pushing a second entry for one panel would need two Escapes to close
					-- it.
					if pushed == nil then
						pushed = self:PushEscape(name, close)
					end
				elseif pushed ~= nil then
					pushed:Pop()
					pushed = nil
				end
			end

			-- Before the Observer, not only after it. A Lazy screen resolves its handle on first open,
			-- so BindEscape is frequently called with the panel ALREADY open -- waiting for the next
			-- change would leave that first opening unclosable.
			sync()
			scope:Observer(isOpen):onChange(sync)
		end,

		HandleEscape = function(_self): boolean
			local top = escapeStack[#escapeStack]
			if top == nil then
				return false
			end

			-- Popped BEFORE Close runs, not after. Close is what flips the screen's IsOpen, which is
			-- what fires BindEscape's Observer, which pops -- so an entry still on the stack here
			-- would be popped by that re-entrant call and then popped AGAIN by this one, taking the
			-- panel underneath with it.
			table.remove(escapeStack, #escapeStack)
			top.Close()
			return true
		end,

		EscapeStack = function(_self): { string }
			local names = table.create(#escapeStack)
			for _, entry in escapeStack do
				table.insert(names, entry.Name)
			end
			return names
		end,
	}

	-- gameProcessed guards a chat entry or a focused CoreGui field, the same check all four handlers
	-- this replaces already made. The focused-TextBox check is this file's own -- see the header.
	table.insert(
		scope,
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed or not DISMISS_KEYCODES[input.KeyCode] then
				return
			end
			if UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			handle:HandleEscape()
		end)
	)

	return handle
end

return Chrome
