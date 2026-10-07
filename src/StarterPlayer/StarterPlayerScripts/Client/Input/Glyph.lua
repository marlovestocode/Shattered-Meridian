--!strict
--[[
	Glyph.lua

	Owns: turning a Types.KeybindAction into what a key legend should DRAW for the CURRENT device --
	an image asset id when one exists (a gamepad button glyph), or text otherwise (a keyboard/mouse
	label, or a gamepad button with no known image). Components/KeyCap.lua is the intended consumer,
	but that migration is Phase 3 -- this module is built now so that screen has something real to
	call once it lands, per Constants.lua's own note at Keybinds.GamepadDefaults' header that
	UserInputService:GetImageForKeyCode already exists and nothing calls it yet.

	A DISCRIMINATED RESULT, NOT A BARE STRING. KeyCap.lua has to know whether to mount an ImageLabel
	or a text Label -- a bare string cannot say which, and guessing from the string's shape (does it
	look like a content id?) is exactly the kind of implicit contract this codebase's shared
	components (Stack, KeyCap, ScreenFrame) exist to avoid. Glyph is `{ Kind: "Image" | "Text", Value:
	string }` so the eventual caller branches on Kind, never on Value's shape.

	RECOMPUTES ON TWO INDEPENDENT SIGNALS, NEITHER OF WHICH IS NATIVELY FUSION: InputDevice.OnChanged
	(the device switched) and KeybindManager.OnChanged (a binding was rebound, on either device, or
	reset to defaults). Both are plain callback lists, so both get bridged into one epoch Value a
	Computed can `use()` -- the same bridge-into-a-Fusion-Value shape Shell/Chrome.lua's
	ObserveModalGate uses for AttributeConstants.UiModalOpen.

	DELIBERATELY NOT BUILT ON InputDevice.Observe, even though that adapter exists for exactly this
	kind of consumer. Observe guards a nil Players.LocalPlayer by returning a value that never updates
	again (see its own header) -- correct for an adapter that exists to survive being require()d with
	no player, but wrong for THIS module: Glyph.For has to keep recomputing off InputDevice.OnChanged
	regardless of LocalPlayer, because OnChanged itself has no such guard and no such reason to need
	one (it never touches Player state). Routing through Observe here would silently stop this Computed
	from ever seeing a device change in exactly the environment scripts/run-tests.lua exercises it in.
	Reading InputDevice.Current() directly inside the Computed, gated on the same OnChanged this file
	already bridges for KeybindManager, sidesteps that guard entirely.

	READS THE CHORD LAYER, NOT JUST KeybindManager's TWO MAPS. An action with no plain gamepad button
	is not necessarily unbound on a pad -- Constants.Keybinds.GamepadChords is where Leap, Interact,
	GrabThrow and HotbarSlot1-5 actually live -- so Resolve falls back to Client/Input/Chord.lua before
	answering "Unbound". See describeChord below for why a chord draws as one cap rather than two.

	WHAT IS STILL MISSING, AND IT IS A DISCOVERABILITY GAP RATHER THAN A CORRECTNESS ONE: legends do
	not yet swap to the alternate set the INSTANT the modifier goes down. Chord.IsHeld() is a live
	poll with no changed-signal behind it, so there is nothing for the epoch Value below to subscribe
	to; making it reactive means either driving it from InputRouter (which already sees the modifier's
	press and release) or polling, and that choice belongs with the rest of the analog/settings work
	rather than being guessed at here. A chord-bound action still names its chord correctly at rest,
	which is what keeps the layer honest in the meantime.

	Does NOT own: rendering (KeyCap.lua's job), or resolving which of a player's TWO device categories
	(keyboard vs gamepad, see KeybindManager.lua's own header) is "current" -- InputDevice.lua's job,
	read here as a black box.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Chord = require(script.Parent.Chord)
local InputDevice = require(script.Parent.InputDevice)
local KeybindManager = require(script.Parent.KeybindManager)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type GlyphKind = "Image" | "Text"

export type Glyph = {
	Kind: GlyphKind,
	Value: string,
}

-- ONE CONTROL, NAMED FOR BOTH DEVICES -- and the shape that lets a legend draw something honest for a
-- control that is NOT a Types.KeybindAction.
--
-- Every consumer of this module until now named a rebindable action and got a per-device answer for
-- free, because KeybindManager already holds two maps. A CONTEXTUAL control has no entry in either:
-- the blimp helm's throttle and rudder (BlimpConstants.Controls) and the furnace's unload key are
-- read only while a player is standing somewhere specific, and are deliberately not rebindable -- see
-- Client/Blimp/BlimpController.lua's header for that argument. They still have to be DRAWN, and drawn
-- for the right device, which is what this exists for.
--
-- `Action` IS NOT AN ALTERNATIVE TO THE TWO KeyCodes, IT IS A PER-DEVICE FALLBACK, and that is what
-- makes the shape earn its keep instead of being two types wearing one name. A control can genuinely
-- be a bound action on one device and a contextual key on the other: the helm's release is the live
-- Interact bind on a keyboard (it shares that bind with the prompt that started the mount, and must
-- follow a rebind) and a plain contextual ButtonX on a pad (Interact's real gamepad reach is the
-- ButtonL2+ButtonX chord, which is the wrong instruction to give a pilot). Resolve below takes the
-- explicit KeyCode for the current device when there is one and falls back to the action when there
-- is not, so that row is expressible as one binding rather than as a device branch at the call site.
export type Binding = {
	Keyboard: Enum.KeyCode?,
	Gamepad: Enum.KeyCode?,
	Action: Types.KeybindAction?,
}

local Glyph = {}

-- The engine's own glyph lookup, behind a swappable reference -- the ONE test-only seam in this
-- file, and the same shape Client/Input/InputDevice.lua's SetCurrentForTesting and
-- InputRouter.lua's SetModalOpenPredicateForTesting already take. It exists because
-- GetImageForKeyCode is a live engine call whose answer this module cannot influence: it returns a
-- real asset for every gamepad KeyCode in the headless suite (an earlier spec here asserted the
-- opposite and failed), so the "no image for this KeyCode" fallback below -- a branch a real
-- keyboard-only or partially-mapped pad DOES reach -- is otherwise unreachable from a test. Nothing
-- in production replaces it.
local function defaultImageForKeyCode(keyCode: Enum.KeyCode): string
	return UserInputService:GetImageForKeyCode(keyCode)
end

local imageForKeyCode: (Enum.KeyCode) -> string = defaultImageForKeyCode

-- A chord drawn as ONE cap, "L2+X", rather than as two. Components/KeyHint.lua's header draws the
-- opposite conclusion for the keys it lists ("they are two keys, and a legend that draws them as one
-- is telling the player to press something that does not exist") and both are right, because they
-- are about different things: that rule is about two ALTERNATIVE keys, where drawing "W/S" invents a
-- key nobody can press. A chord is not two alternatives -- it is a single gesture that happens to
-- need two fingers, and the player must press both AT ONCE, so one cap naming both is exactly what
-- the instruction is. Components/KeyCap.lua already grows past its minimum width via AutomaticSize.X
-- for the multi-character glyphs ("SPACE", "SHIFT") this is no longer than.
--
-- STRIPS THE "Button" PREFIX Enum.KeyCode.Name carries, because "ButtonL2+ButtonX" is four times the
-- width of the thing it names and reads as jargon rather than as a button. KeybindManager.Describe is
-- deliberately not changed to do this: its answers appear in the rebind UI, where the full enum name
-- is the honest label for a row the player is editing.
local function shortGamepadLabel(keyCode: Enum.KeyCode): string
	local name = keyCode.Name
	local stripped = name:match("^Button(.+)$")
	return stripped or name
end

local function describeChord(chordKeyCode: Enum.KeyCode): string
	local modifier = Chord.Modifier()
	local modifierLabel = if modifier.KeyCode
		then shortGamepadLabel(modifier.KeyCode :: Enum.KeyCode)
		else KeybindManager.Describe(modifier)
	return `{modifierLabel}+{shortGamepadLabel(chordKeyCode)}`
end

-- Resolves the glyph for `action` on `device`, with no Fusion involved -- the pure decision Glyph.For
-- below wraps in a Computed. Exposed so a spec can assert the fallback/Unbound rules directly against
-- whatever KeybindManager currently has bound, without needing a scope at all.
function Glyph.Resolve(action: Types.KeybindAction, device: InputDevice.Device): Glyph
	if device == "Gamepad" then
		local gamepadKeybind = KeybindManager.GetGamepad(action)
		if gamepadKeybind and gamepadKeybind.KeyCode then
			local image = imageForKeyCode(gamepadKeybind.KeyCode)
			if image ~= "" then
				return { Kind = "Image", Value = image }
			end
			return { Kind = "Text", Value = KeybindManager.Describe(gamepadKeybind) }
		end

		-- NO PLAIN GAMEPAD BUTTON -- SO ASK THE CHORD LAYER BEFORE GIVING UP. Without this branch,
		-- Leap, Interact, GrabThrow and HotbarSlot1-5 would every one of them draw "Unbound" on a
		-- pad, which is worse than the keyboard key they used to draw: it tells the player a live
		-- gameplay action cannot be reached at all, when in fact it is one held button away. That
		-- would also be a self-inflicted wound -- those actions have no plain binding precisely
		-- BECAUSE Constants.Keybinds.GamepadChords gave them a home, so the map that moved them is
		-- the map that has to be consulted for them.
		local chordKeybind = Chord.Get(action)
		if chordKeybind and chordKeybind.KeyCode then
			return { Kind = "Text", Value = describeChord(chordKeybind.KeyCode) }
		end

		return { Kind = "Text", Value = KeybindManager.Describe(gamepadKeybind) }
	end

	-- KeyboardMouse and Touch both fall back to the keyboard/mouse binding's text -- there is no
	-- separate Types.KeybindDevice for touch (only "Keyboard" | "Gamepad"), and a touch UI is
	-- expected to render its own on-screen control rather than a key glyph at all; Phase 3's KeyCap
	-- migration is where that distinction, if it turns out to matter, gets made.
	return { Kind = "Text", Value = KeybindManager.Describe(KeybindManager.Get(action)) }
end

-- The Fusion-reactive form. Recomputes when InputDevice.OnChanged OR KeybindManager.OnChanged fires.
function Glyph.For(scope: Scope, action: Types.KeybindAction): Fusion.Computed<Glyph>
	-- ONE epoch Value for BOTH signals, and InputDevice.Current() read directly inside the Computed
	-- rather than through InputDevice.Observe -- see file header for why routing the device half
	-- through that adapter would silently freeze this Computed in exactly the environment
	-- scripts/run-tests.lua exercises it in. The count itself carries no meaning; it exists purely so
	-- this Value changes at all, which is what makes the Computed recompute.
	local epoch: Fusion.Value<number> = scope:Value(0)

	local function bump(): ()
		epoch:set(peek(epoch) + 1)
	end

	table.insert(scope, KeybindManager.OnChanged(bump))
	table.insert(scope, InputDevice.OnChanged(bump))

	return scope:Computed(function(use): Glyph
		use(epoch)
		return Glyph.Resolve(action, InputDevice.Current())
	end)
end

-- The glyph for ONE raw KeyCode, with no binding lookup of any kind -- the branch Resolve above
-- reaches once it has turned an action into a KeyCode, exposed so a contextual control can reach it
-- without inventing an action to hold its key. Same image-then-text fallback and the same
-- "Button" prefix strip, so a contextual cap and a bound cap on the same panel are drawn identically.
function Glyph.ResolveKeyCode(keyCode: Enum.KeyCode): Glyph
	local image = imageForKeyCode(keyCode)
	if image ~= "" then
		return { Kind = "Image", Value = image }
	end
	-- shortGamepadLabel is a no-op on a keyboard KeyCode (nothing matches the "Button" prefix), which
	-- is why one call covers both devices here rather than a branch on which one this is.
	return { Kind = "Text", Value = shortGamepadLabel(keyCode) }
end

-- Resolves a Binding for `device` -- the contextual sibling of Resolve above, and pure for the same
-- reason: a spec drives it with a plain device value rather than by making UserInputService lie.
--
-- The fallback order is the whole contract: this device's own KeyCode if the binding names one, then
-- the action if it carries one, then EMPTY.
--
-- EMPTY, NOT "Unbound", AND THE DIFFERENCE IS NOT COSMETIC. "Unbound" is what Glyph.Resolve says
-- about an ACTION with no binding on this device, and it is the right word there: the action exists,
-- a rebind screen lists it, and the player is being told they cannot currently reach it. A binding
-- that names neither a KeyCode nor an action for this device is saying something else entirely --
-- that this control has no separate input here at all, because the device folds it into one it has
-- already named. The blimp helm's rudder is exactly that: two keys on a keyboard, and on a pad one
-- half of a stick the row's other cap is already drawing. "Unbound" would be a false alarm about a
-- control the player is holding in their hand, so the honest answer is to draw nothing, and
-- Components/KeyCap.lua hides a cap whose glyph comes back empty rather than leaving a blank well.
function Glyph.ResolveBinding(binding: Binding, device: InputDevice.Device): Glyph
	local keyCode = if device == "Gamepad" then binding.Gamepad else binding.Keyboard
	if keyCode then
		return Glyph.ResolveKeyCode(keyCode)
	end
	local action = binding.Action
	if action then
		return Glyph.Resolve(action, device)
	end
	return { Kind = "Text", Value = "" }
end

-- The Fusion-reactive form of ResolveBinding, and the exact shape Glyph.For has -- same one epoch
-- Value bridging the same two callback lists. KeybindManager.OnChanged matters here too, and not
-- only for tidiness: a binding carrying an `Action` fallback (the helm's release) redraws on a rebind
-- of that action, on whichever device is currently using the fallback.
function Glyph.ForBinding(scope: Scope, binding: Binding): Fusion.Computed<Glyph>
	local epoch: Fusion.Value<number> = scope:Value(0)

	local function bump(): ()
		epoch:set(peek(epoch) + 1)
	end

	table.insert(scope, KeybindManager.OnChanged(bump))
	table.insert(scope, InputDevice.OnChanged(bump))

	return scope:Computed(function(use): Glyph
		use(epoch)
		return Glyph.ResolveBinding(binding, InputDevice.Current())
	end)
end

-- TEST-ONLY. Overrides the engine glyph lookup Resolve consults -- see defaultImageForKeyCode above
-- for why this branch is otherwise undrivable. Pass nil to restore the real one.
function Glyph.SetImageResolverForTesting(resolver: ((Enum.KeyCode) -> string)?): ()
	imageForKeyCode = resolver or defaultImageForKeyCode
end

return Glyph
