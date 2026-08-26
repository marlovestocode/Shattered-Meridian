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
	ObserveModalGate uses for Constants.Attributes.UiModalOpen.

	DELIBERATELY NOT BUILT ON InputDevice.Observe, even though that adapter exists for exactly this
	kind of consumer. Observe guards a nil Players.LocalPlayer by returning a value that never updates
	again (see its own header) -- correct for an adapter that exists to survive being require()d with
	no player, but wrong for THIS module: Glyph.For has to keep recomputing off InputDevice.OnChanged
	regardless of LocalPlayer, because OnChanged itself has no such guard and no such reason to need
	one (it never touches Player state). Routing through Observe here would silently stop this Computed
	from ever seeing a device change in exactly the environment scripts/run-tests.lua exercises it in.
	Reading InputDevice.Current() directly inside the Computed, gated on the same OnChanged this file
	already bridges for KeybindManager, sidesteps that guard entirely.

	Does NOT own: rendering (KeyCap.lua's job, once it migrates), or resolving which of a player's TWO
	device categories (keyboard vs gamepad, see KeybindManager.lua's own header) is "current" --
	InputDevice.lua's job, read here as a black box.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local InputDevice = require(script.Parent.InputDevice)
local KeybindManager = require(script.Parent.KeybindManager)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type GlyphKind = "Image" | "Text"

export type Glyph = {
	Kind: GlyphKind,
	Value: string,
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

-- TEST-ONLY. Overrides the engine glyph lookup Resolve consults -- see defaultImageForKeyCode above
-- for why this branch is otherwise undrivable. Pass nil to restore the real one.
function Glyph.SetImageResolverForTesting(resolver: ((Enum.KeyCode) -> string)?): ()
	imageForKeyCode = resolver or defaultImageForKeyCode
end

return Glyph
