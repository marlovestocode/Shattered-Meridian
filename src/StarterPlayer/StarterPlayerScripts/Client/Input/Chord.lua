--!strict
--[[
	Chord.lua

	Owns: the gamepad's ALTERNATE binding layer -- what each button means while a held modifier
	(Constants.Keybinds.GamepadModifier, ButtonL2 by default) is down, per
	Constants.Keybinds.GamepadChords.

	WHY A LAYER AT ALL. Read Constants.Keybinds.GamepadDefaults: Roll's comment and Leap's comment
	independently reached the same wall -- every face button, shoulder, stick click and D-pad
	direction in this genre's convention family is already bound -- and Leap, Interact and GrabThrow
	are live gameplay actions with no gamepad binding as a result. The two ways out were doubling two
	distinct mechanics onto one button (which makes them indistinguishable to the player) or adding a
	layer. This is the layer. It is also what makes the NEXT action to need a gamepad binding cheap:
	one row in GamepadChords, no re-litigation of the budget.

	THE MODIFIER IS SAMPLED AT THE MOMENT OF THE PRESS, NOT CONTINUOUSLY, and that sentence is the
	whole reason this module tracks state instead of just polling IsKeyDown at every read. The two
	failures it forecloses are the classic pair:
	  * A chorded press must not ALSO fire the unmodified action. Pressing R1 with L2 held is Feint
	    and is NEVER also BasicAttack -- Client/Input/InputRouter.lua asks Resolve below what a press
	    means and dispatches exactly one answer.
	  * The modifier released BEFORE the button fires the PLAIN action. Holding L2, letting go, then
	    pressing R1 is BasicAttack -- because the sample happens on R1's own InputBegan, not on some
	    running "we are in chord mode" flag that outlives the hold.
	The second half of that is why ConsumePressed/Release exist: a press CONSUMED as a chord has to
	be remembered until its own release, so InputRouter can route the release to the same action it
	routed the press to. Without that memory, releasing R1 after a Feint would fire BasicAttack's
	Ended -- a release with no matching Began, which is exactly the "stuck blocking" class of bug
	DefenseClient.lua's own release handling exists to avoid.

	Resolve BELOW TAKES modifierHeld AS AN ARGUMENT RATHER THAN READING IT, for the same reason
	InputDevice.ResolveDevice takes a pre-computed magnitude: InputObject has no public constructor
	and UserInputService cannot be driven from a spec, so the one decision every live press funnels
	through has to be callable with plain values. IsHeld() below is the live read that fills that
	argument in production.

	REBINDING. The modifier itself is rebindable (Types.GamepadSettings.ChordModifier, Phase 4's
	settings group) via SetModifier; the chord map is not yet, and deliberately so -- a rebind UI for
	a two-part binding is its own design problem, and shipping the layer does not depend on solving
	it. Chords() is exposed so that UI, when it exists, has something to list.

	Does NOT own: dispatch (InputRouter.lua asks; this module only answers), what any action does, or
	the PLAIN gamepad map (Client/Input/KeybindManager.lua). It deliberately does not go through
	KeybindManager at all -- that module's two maps are keyed one-binding-per-action-per-device and a
	chord is a second gamepad binding for the same action, which is a shape its Rebind collision
	checks are not written for.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local Chord = {}

-- What a press resolved to. "Plain" means the chord layer has no opinion and the caller should
-- dispatch normally; "Chord" carries the action the modifier turned it into; "Modifier" means the
-- press WAS the modifier, which is never itself an action.
export type Resolution = {
	Kind: "Plain" | "Chord" | "Modifier",
	Action: Types.KeybindAction?,
}

local PLAIN: Resolution = { Kind = "Plain" }
local MODIFIER: Resolution = { Kind = "Modifier" }

local currentModifier: Types.Keybind = Constants.Keybinds.GamepadModifier
local chords: { [Types.KeybindAction]: Types.Keybind? } = table.clone(Constants.Keybinds.GamepadChords)

-- KeyCodes whose CURRENT press was consumed as a chord, so the matching release routes to the same
-- action -- see the sampling note in this file's header. Keyed by KeyCode rather than by action
-- because a release only ever knows its own input.
local consumedPresses: { [Enum.KeyCode]: Types.KeybindAction } = {}

local function matchesKeybind(keybind: Types.Keybind?, input: InputObject): boolean
	if not keybind then
		return false
	end
	if keybind.KeyCode then
		return input.KeyCode == keybind.KeyCode
	end
	if keybind.UserInputType then
		return input.UserInputType == keybind.UserInputType
	end
	return false
end

-- The chord binding currently assigned to `action`, or nil if it has none.
function Chord.Get(action: Types.KeybindAction): Types.Keybind?
	return chords[action]
end

-- Shallow copy of the whole chord map -- for a legend or a future rebind screen to list, never for a
-- caller to mutate.
function Chord.Chords(): { [Types.KeybindAction]: Types.Keybind? }
	return table.clone(chords)
end

-- The held button that switches the pad onto the chord layer.
function Chord.Modifier(): Types.Keybind
	return currentModifier
end

-- Overrides the modifier for the rest of this client session. The chord map is unaffected -- what
-- changes is only which button opens it.
function Chord.SetModifier(keybind: Types.Keybind): ()
	currentModifier = keybind
end

-- Restores Constants.Keybinds.GamepadModifier, for a settings "restore defaults".
function Chord.ResetModifier(): ()
	currentModifier = Constants.Keybinds.GamepadModifier
end

-- True if `input` IS the modifier -- a press the caller must not treat as an action of its own.
function Chord.IsModifier(input: InputObject): boolean
	return matchesKeybind(currentModifier, input)
end

-- Whether the modifier is physically held RIGHT NOW. The live read that fills Resolve's
-- `modifierHeld` argument in production -- and what Client/Input/Glyph.lua reads to swap every
-- on-screen legend onto the alternate set while the modifier is down, which is what makes this
-- layer discoverable rather than secret.
function Chord.IsHeld(): boolean
	if currentModifier.KeyCode then
		return UserInputService:IsKeyDown(currentModifier.KeyCode)
	end
	if currentModifier.UserInputType then
		return UserInputService:IsMouseButtonPressed(currentModifier.UserInputType)
	end
	return false
end

-- The one decision every gamepad press funnels through -- see file header for why `modifierHeld` is
-- an argument. Pure: it reads no live input and records nothing.
function Chord.Resolve(input: InputObject, modifierHeld: boolean): Resolution
	if Chord.IsModifier(input) then
		return MODIFIER
	end

	if not modifierHeld then
		return PLAIN
	end

	for action, keybind in pairs(chords) do
		if matchesKeybind(keybind, input) then
			return { Kind = "Chord", Action = action }
		end
	end

	-- The modifier is held but this button has no chord binding. Falls through to the plain action
	-- deliberately: a held L2 must not silently swallow every unrelated button, which would make the
	-- modifier feel like a broken controller rather than a layer.
	return PLAIN
end

-- Resolves `input` AND records the outcome so the matching release can be routed to the same action.
-- InputRouter calls this on InputBegan; Resolve above is the pure form for anyone who only wants the
-- answer.
function Chord.ConsumePress(input: InputObject, modifierHeld: boolean): Resolution
	local resolution = Chord.Resolve(input, modifierHeld)
	if resolution.Kind == "Chord" and resolution.Action and input.KeyCode then
		consumedPresses[input.KeyCode] = resolution.Action
	end
	return resolution
end

-- The action this input's still-open press was consumed as, or nil if that press was a plain one.
-- Clears the record, so it answers exactly once per press -- a release is the end of that press.
function Chord.ReleasePress(input: InputObject): Types.KeybindAction?
	local keyCode = input.KeyCode
	if keyCode == nil then
		return nil
	end
	local action = consumedPresses[keyCode]
	consumedPresses[keyCode] = nil
	return action
end

-- TEST-ONLY. Drops every open chord press. The module is a singleton for the life of the client, so
-- a spec that consumed a press without releasing it would leak that record into whichever spec runs
-- next in the same process -- the same restore-in-afterEach contract Tests/Input/Glyph.spec.lua
-- already documents for KeybindManager and InputDevice.
function Chord.ClearPressesForTesting(): ()
	table.clear(consumedPresses)
end

return Chord
