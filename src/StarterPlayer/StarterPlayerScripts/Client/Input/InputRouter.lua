--!strict
--[[
	InputRouter.lua

	Owns: the ONE UserInputService.InputBegan/InputEnded connection for action dispatch. Before this
	module, roughly twenty client files each opened their own connection and each hand-rolled the same
	two checks -- `if gameProcessed then return end`, and some hand-copied shape of "is a modal UI
	panel open right now" -- independently, at every call site. This is the shared owner of both.

	local unbind = InputRouter.Bind("Block", {
	    Layer = "Gameplay",
	    Began = function() ... end,
	    Ended = function() ... end,
	})

	Every Bind call is matched through KeybindManager.Matches(action, input) -- nothing here ever
	hardcodes a KeyCode/UserInputType, which is what makes a bound action work identically on
	keyboard and gamepad with no per-caller device branching, exactly like every existing hand-rolled
	handler already relies on Matches for.

	THE GAMEPAD CHORD LAYER IS RESOLVED HERE, AHEAD OF Matches, AND ITS ANSWER IS EXCLUSIVE.
	Client/Input/Chord.lua owns what a button means while the held modifier (ButtonL2) is down; this
	module owns dispatching that answer. A caller never learns which layer its press came from -- an
	action bound once fires whether it was reached plainly or through a chord, which is what lets Leap,
	Interact, GrabThrow and HotbarSlot1-5 exist on a pad at all without a single consumer knowing.
	Three rules, all of them about what must NOT also happen, and all three enforced in one place here
	rather than at ~20 call sites:
	  * A chorded press never ALSO fires the unmodified action (L2+R1 is Feint, never also BasicAttack).
	  * The modifier's own press/release is never an action in its own right.
	  * A chorded press's RELEASE routes to the action the PRESS was consumed as, never to the plain
	    action that shares its button -- see HandleInputEnded.
	Chord matching is by KeyCode, so a keyboard press can never resolve to a chord (the map holds only
	gamepad KeyCodes) and no device branch is needed here either.

	FOUR LAYERS, AND WHAT EACH ONE MEANS FOR THE MODAL GATE (AttributeConstants.UiModalOpen,
	published by Components/ModalScreen.lua):
	  * "Gameplay" -- ordinary world input (combat, movement). Began does NOT fire while a modal panel
	    is open. Ended ALWAYS fires, regardless of the modal Attribute -- see the next paragraph.
	  * "Menu"/"Modal" -- input meant for a panel. Began fires ONLY while a modal panel is open.
	    "Modal" outranks "Menu" in the precedence order below; Phase 1 has no concrete "Modal"-layer
	    consumer yet, but the distinction exists for a future screen's own hotkey to take priority over
	    a general "any modal is open" reaction without the two being registered as the same layer.
	  * "System" -- a panel's own open/close toggle (SettingsToggle, CharacterMenuToggle,
	    DevMenuToggle, ...). Neither modal-gated direction fits a toggle that must open when nothing is
	    open AND close when its own panel (which IS a modal) is open -- "Menu" semantics would make it
	    unable to ever open, "Gameplay" semantics would make it unable to ever close. System is
	    therefore the one layer this router does NOT auto-drop on gameProcessed for either -- a caller
	    that still wants that check (SettingsClient.lua's toggle does, to avoid firing on a keystroke a
	    focused chat TextBox is consuming) makes it itself, off the `gameProcessed` argument Began is
	    always called with; see that migration's own comment for why.

	Began RECEIVES (gameProcessed, input) AND Ended RECEIVES (input), EVEN THOUGH EVERY EXAMPLE ABOVE
	IGNORES THEM. Every layer but "System" already has gameProcessed/the modal Attribute applied before
	Began is ever called, so a typical caller (DefenseClient.lua, ParkourInput.lua) declares a zero-
	argument closure and never looks -- Lua does not error when a caller passes more arguments than a
	function declares. The arguments exist for the one layer that opts out of the automatic
	gameProcessed drop, so it is not ALSO opting out of ever being able to check it.

	Ended IS NEVER GATED, BY ANYTHING, FOR ANY LAYER -- not gameProcessed, not the modal Attribute, not
	layer precedence. This generalizes what DefenseClient.lua's own onInputEnded already did by hand
	("a guard already raised when a menu opened over it must still be releasable, or the character is
	left stuck blocking") to every layer: a release is a cleanup signal, and every registered Ended for
	a matching action fires, not just the highest-precedence one. Firing an extra release is always
	safe (every real Ended callback in this codebase already treats a redundant release as a no-op);
	dropping one is not.

	LAYER PRECEDENCE ON Began, Modal > Menu > Gameplay > System, applies only when more than one
	CURRENTLY RELEVANT layer is bound to the same action -- "Gameplay" and "Menu"/"Modal" can never
	both be relevant at once (the modal Attribute can only be one thing), so the only real collisions
	are Modal-vs-Menu while a panel is open, and any relevant layer against "System", which is relevant
	unconditionally. Only the single winning layer's Began fires.

	HandleInputBegan/HandleInputEnded ARE PUBLIC, NOT PRIVATE, for the same reason Shell/Chrome.lua
	exposes HandleEscape instead of trusting a spec to press a key --
	InputObject has no public constructor, so a spec drives dispatch through the exact function the
	real UserInputService connection calls, with a plain duck-typed table standing in for the
	InputObject (Lua does not runtime-check the InputObject annotation, and Matches only ever reads
	.KeyCode/.UserInputType off it).

	SetModalOpenPredicateForTesting IS THE ONE OTHER TEST-ONLY SEAM, and it exists for a narrower
	reason than the above: the modal gate reads Players.LocalPlayer:GetAttribute(...), guarded the
	same way Shell/Chrome.lua's ObserveModalGate guards it, and scripts/run-tests.lua require-loads
	this module on the server, where LocalPlayer is nil and the real predicate can only ever answer
	false. Without this seam, the "Menu"/"Modal" half of the gate -- and the precedence order that
	depends on it -- would be structurally untestable in this codebase's suite. No production caller
	touches it; the real predicate is wired in for free.

	Does NOT own what an action DOES (the feature module's own Began/Ended closures do) or Escape --
	Escape is not a Types.KeybindAction and stays exactly where it already lives, Shell/Chrome.lua's
	own stack.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Analog = require(script.Parent.Analog)
local Chord = require(script.Parent.Chord)
local KeybindManager = require(script.Parent.KeybindManager)

local logger = Logger.scope("InputRouter")

export type Layer = "Gameplay" | "Menu" | "Modal" | "System"

export type BindConfig = {
	Layer: Layer,
	Began: ((gameProcessed: boolean, input: InputObject) -> ())?,
	Ended: ((input: InputObject) -> ())?,
}

type Binding = {
	Layer: Layer,
	Began: ((gameProcessed: boolean, input: InputObject) -> ())?,
	Ended: ((input: InputObject) -> ())?,
}

local InputRouter = {}

-- Higher wins. See file header for when this actually matters -- "Gameplay" and "Menu"/"Modal" are
-- never simultaneously relevant, so the real collisions are Modal-vs-Menu and anything-vs-System.
local LAYER_RANK: { [Layer]: number } = {
	Modal = 4,
	Menu = 3,
	Gameplay = 2,
	System = 1,
}

-- Keyed by action so dispatch only ever iterates actions that actually have a live binding, not
-- every Types.KeybindAction that exists -- this router costs nothing for the (large majority of)
-- actions nothing has bound yet.
local bindings: { [Types.KeybindAction]: { Binding } } = {}

-- The real modal-open predicate -- guarded for a nil LocalPlayer exactly the way Shell/Chrome.lua's
-- ObserveModalGate is, and for the identical reason (this module is require-loaded on the server by
-- scripts/run-tests.lua, where there is no LocalPlayer to read an Attribute off).
local function isModalOpenFromAttribute(): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player:GetAttribute(AttributeConstants.UiModalOpen) == true
end

local isModalOpen: () -> boolean = isModalOpenFromAttribute

local function isLayerRelevant(layer: Layer, modalOpen: boolean): boolean
	if layer == "Gameplay" then
		return not modalOpen
	end
	if layer == "Menu" or layer == "Modal" then
		return modalOpen
	end
	return true -- System: relevant unconditionally, see file header.
end

-- Registers a binding for `action` under `config.Layer`. Returns an unbind function -- idempotent,
-- calling it more than once is a no-op rather than an error, the same contract every OnChanged
-- unsubscribe in this codebase already has.
function InputRouter.Bind(action: Types.KeybindAction, config: BindConfig): () -> ()
	local entry: Binding = { Layer = config.Layer, Began = config.Began, Ended = config.Ended }

	local list = bindings[action]
	if not list then
		list = {}
		bindings[action] = list
	end
	table.insert(list, entry)
	logger:debug("Bound action", { action = action, layer = config.Layer })

	local removed = false
	return function()
		if removed then
			return
		end
		removed = true
		local at = table.find(list, entry)
		if at ~= nil then
			table.remove(list, at)
		end
	end
end

-- True if `action` is currently physically held, on either device -- the same raw poll
-- KeybindManager.IsJumpKeyDown does for Roblox's own non-rebindable jump, generalized to any
-- rebindable action via KeybindManager.Get/GetGamepad.
local function isKeybindDown(keybind: Types.Keybind): boolean
	if keybind.KeyCode then
		-- Both reads, for the reason KeybindManager.IsJumpKeyDown documents at length: IsKeyDown resolves
		-- KEYBOARD keys only and silently answers false for a gamepad KeyCode. This function's own header
		-- claims it works "on either device" -- via KeybindManager.GetGamepad, whose keybinds are gamepad
		-- KeyCodes -- so with IsKeyDown alone that claim was false for exactly the half it was written for.
		return UserInputService:IsKeyDown(keybind.KeyCode) or Analog.IsButtonDown(keybind.KeyCode)
	end
	if keybind.UserInputType then
		return UserInputService:IsMouseButtonPressed(keybind.UserInputType)
	end
	return false
end

function InputRouter.IsActionDown(action: Types.KeybindAction): boolean
	if isKeybindDown(KeybindManager.Get(action)) then
		return true
	end
	local gamepad = KeybindManager.GetGamepad(action)
	return gamepad ~= nil and isKeybindDown(gamepad)
end

-- Fires the single highest-precedence relevant Began among `entries` -- the per-action half of
-- dispatch, split out so a chord can drive it for ONE action directly. The plain path below reaches
-- it through KeybindManager.Matches; the chord path reaches it with an action Chord.lua named, which
-- is precisely the difference between the two (a chord is not a binding KeybindManager knows about,
-- by that module's own design note).
local function dispatchBegan(entries: { Binding }, gameProcessed: boolean, input: InputObject, modalOpen: boolean): ()
	local best: Binding? = nil
	local bestRank = 0
	for _, entry in entries do
		if entry.Began == nil then
			continue
		end
		if gameProcessed and entry.Layer ~= "System" then
			continue
		end
		if not isLayerRelevant(entry.Layer, modalOpen) then
			continue
		end
		local rank = LAYER_RANK[entry.Layer]
		if rank > bestRank then
			bestRank = rank
			best = entry
		end
	end

	if best and best.Began then
		best.Began(gameProcessed, input)
	end
end

-- The InputBegan dispatch, exposed publicly -- see file header. `input` only ever needs to answer
-- .KeyCode/.UserInputType (everything KeybindManager.Matches reads), so a spec can pass a plain
-- table cast to InputObject instead of a real one.
function InputRouter.HandleInputBegan(input: InputObject, gameProcessed: boolean): ()
	local modalOpen = isModalOpen()

	-- THE CHORD LAYER GETS FIRST REFUSAL, AND ITS ANSWER IS EXCLUSIVE. Client/Input/Chord.lua's
	-- header states the two rules this branch exists to enforce, and both are about what must NOT
	-- also happen: a chorded press never additionally fires the unmodified action (so a Chord
	-- resolution returns instead of falling through to the Matches loop), and the modifier's own
	-- press is never an action (so it returns having dispatched nothing at all). ConsumePress rather
	-- than Resolve because the matching RELEASE has to reach the same action -- see HandleInputEnded.
	local resolution = Chord.ConsumePress(input, Chord.IsHeld())
	if resolution.Kind == "Modifier" then
		return
	end
	if resolution.Kind == "Chord" then
		local action = resolution.Action
		local entries = action ~= nil and bindings[action] or nil
		if entries then
			dispatchBegan(entries, gameProcessed, input, modalOpen)
		end
		return
	end

	for action, entries in pairs(bindings) do
		if not KeybindManager.Matches(action, input) then
			continue
		end
		dispatchBegan(entries, gameProcessed, input, modalOpen)
	end
end

-- The InputEnded dispatch. Every registered Ended for a matching action fires -- see file header for
-- why this is never gated, by layer relevance or otherwise.
function InputRouter.HandleInputEnded(input: InputObject): ()
	-- A press CONSUMED as a chord releases to the action it was consumed as, and to nothing else --
	-- the mirror of HandleInputBegan's exclusive chord branch, and the reason Chord.lua remembers
	-- presses at all. Without this, releasing R1 after an L2+R1 Feint would fire BasicAttack's Ended:
	-- a release with no matching Began, which is the shape of the "stuck blocking" bug
	-- Defense/DefenseClient.lua's own release handling exists to avoid. Note this is asked FIRST and
	-- unconditionally, so it also clears the record when the released action happens to have no
	-- binding at all.
	local chordAction = Chord.ReleasePress(input)
	if chordAction ~= nil then
		local entries = bindings[chordAction]
		if entries then
			for _, entry in entries do
				if entry.Ended then
					entry.Ended(input)
				end
			end
		end
		return
	end

	-- The modifier's own release is not an action, exactly as its press was not -- see
	-- HandleInputBegan. Asked after ReleasePress above so that a modifier rebound onto a button that
	-- also carries a chord still clears that chord's record.
	if Chord.IsModifier(input) then
		return
	end

	for action, entries in pairs(bindings) do
		if not KeybindManager.Matches(action, input) then
			continue
		end
		for _, entry in entries do
			if entry.Ended then
				entry.Ended(input)
			end
		end
	end
end

-- TEST-ONLY. Overrides the predicate HandleInputBegan treats as "a modal panel is open" -- see file
-- header for why the real one is structurally undrivable in this codebase's suite. Pass nil to
-- restore the real, Attribute-backed predicate. No production caller uses this.
function InputRouter.SetModalOpenPredicateForTesting(predicate: (() -> boolean)?): ()
	isModalOpen = predicate or isModalOpenFromAttribute
end

UserInputService.InputBegan:Connect(InputRouter.HandleInputBegan)
UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
	InputRouter.HandleInputEnded(input)
end)

return InputRouter
