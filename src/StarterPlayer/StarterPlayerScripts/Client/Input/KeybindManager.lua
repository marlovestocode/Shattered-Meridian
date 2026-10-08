--!strict
--[[
	KeybindManager.lua

	Owns: the local player's current keybind for every Types.KeybindAction, across TWO independent
	device categories -- keyboard/mouse (starts from Constants.Keybinds.Defaults) and gamepad
	(starts from Constants.Keybinds.GamepadDefaults) -- and Rebind()/RebindGamepad() let a caller
	override either one for the rest of this client session, independently. An action can have a
	live binding in BOTH categories at once (e.g. Dash is both Q and gamepad ButtonB) --
	Matches() checks both, so every input-consuming client module (CombatClient.lua,
	DevMenuClient.lua) reads through Matches()/Get() instead of a hardcoded Enum.KeyCode/
	UserInputType and transparently supports whichever device the player is actually using, with no
	per-module device branching. A real rebind UI can be wired later just by calling
	Rebind()/RebindGamepad() from a new screen for the category it's editing -- no input-handling
	module needs to change.

	The gamepad category is deliberately partial (Constants.Keybinds.GamepadDefaults has no
	DevMenuToggle entry -- admin-only, keyboard already covers it) -- Get/GetAll/Matches all treat a
	missing gamepad binding as "no gamepad input bound to this action," not an error.

	Backend only for now: no settings screen calls either Rebind yet (per the task this module was
	built for), and it's in-memory only, not persisted across sessions -- no settings/preferences
	System exists yet to persist to. This is a purely client-side concern to begin with (the server
	never needs to know what key OR what device a player used, only the resulting request, so
	nothing here ever crosses NetworkBridge); wiring cross-session persistence is a future
	PlayerDataSystem-adjacent concern, not this module's job.

	ALSO OWNS HOW A BINDING IS SPELLED (Describe) AND WHEN ONE CHANGES (OnChanged), because a legend
	that names a rebindable key is only correct if both exist. Describe was a private formatKeybind in
	Screens/Settings/KeybindsTab.lua, along with the mouse-button label map it needs -- fine while the
	rebind screen was the only surface that ever printed a key, and wrong the moment a second one did
	(Components/KeyLegend.lua under the hotbar). The map in particular has no business living in a tab
	file: "MouseButton1 is spelled Mouse 1" is a fact about this module's data, not about that screen.
	OnChanged closes the other half -- without it, a legend built at mount silently keeps naming the
	key the player just rebound away from, which is worse than no legend at all. Both Rebind entry
	points and both reset entry points fire it.

	Does not own: what an action DOES once its key is pressed (CombatClient.lua/DevMenuClient.lua
	own that), or any gameplay validation -- this module only tracks key-to-action assignment.

	Also owns IsJumpKeyDown() -- Roblox's own default jump input (Space / gamepad ButtonA) is
	deliberately NOT a Types.KeybindAction (Constants.Keybinds has no Jump entry, so it can't be
	rebound), but CombatClient.lua's finisher jump-suppression and holdingJump-hint logic still needs
	that KeyCode pair checked in several places. IsJumpKeyDown gives that raw, non-rebindable check
	one home instead of CombatClient hardcoding Enum.KeyCode.Space/ButtonA at every call site -- it
	does not make jump rebindable; that would need a real Constants.Keybinds.Jump entry plus a
	Rebind path, which is future settings-UI scope, not this pass's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Analog = require(script.Parent.Analog)

local logger = Logger.scope("KeybindManager")

local KeybindManager = {}

-- Cloned from Constants.Keybinds.Defaults/GamepadDefaults at module load so neither Rebind ever
-- mutates those shared tables (Constants.lua is read-only tunable data per its own header). The
-- gamepad map's value type is Keybind?, not Keybind, matching GamepadDefaults' own honestly-partial
-- typing (DevMenuToggle has no gamepad entry -- see file header).
local currentBindings: { [Types.KeybindAction]: Types.Keybind } = table.clone(Constants.Keybinds.Defaults)
local currentGamepadBindings: { [Types.KeybindAction]: Types.Keybind? } =
	table.clone(Constants.Keybinds.GamepadDefaults)

-- Subscribers to any binding change, in either device category -- see file header.
local changedListeners: { () -> () } = {}

local function notifyChanged(): ()
	for _, listener in ipairs(changedListeners) do
		listener()
	end
end

local function isSameKeybind(a: Types.Keybind, b: Types.Keybind): boolean
	return a.KeyCode == b.KeyCode and a.UserInputType == b.UserInputType
end

-- Enum.UserInputType names that read as machine identifiers rather than as something a player would
-- call the button. Everything not listed falls through to its own Name, which is already right
-- (KeyCode.Name gives "Q", "LeftShift", "F5").
local INPUT_TYPE_LABELS: { [string]: string } = {
	MouseButton1 = "Mouse 1",
	MouseButton2 = "Mouse 2",
	MouseButton3 = "Mouse 3",
}

-- Whether `input` matches `keybind` -- shared by Matches() below for both device categories. Safe
-- to call with keybind = nil (an action with no binding in that category never matches).
local function keybindMatchesInput(keybind: Types.Keybind?, input: InputObject): boolean
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

-- The KEYBOARD/mouse keybind currently assigned to `action`. Every action has an entry (Defaults is a
-- complete map), though an action with no default key (Evade) holds the EMPTY keybind until the player
-- assigns one -- it never matches and Describe spells it "Unbound". For the possibly-absent gamepad
-- side, see GetGamepad below.
function KeybindManager.Get(action: Types.KeybindAction): Types.Keybind
	return currentBindings[action]
end

-- Shallow copy of every current keyboard binding -- for a future settings screen to list, never
-- for a caller to mutate directly (mutating the returned table has no effect on currentBindings).
function KeybindManager.GetAll(): { [Types.KeybindAction]: Types.Keybind }
	return table.clone(currentBindings)
end

-- The GAMEPAD keybind currently assigned to `action`, or nil if this action has no gamepad
-- binding (DevMenuToggle, deliberately -- see file header).
function KeybindManager.GetGamepad(action: Types.KeybindAction): Types.Keybind?
	return currentGamepadBindings[action]
end

-- Shallow copy of every current gamepad binding -- same "list only, never mutate" contract as
-- GetAll above.
function KeybindManager.GetAllGamepad(): { [Types.KeybindAction]: Types.Keybind? }
	return table.clone(currentGamepadBindings)
end

-- True if `input` matches whatever is currently bound to `action`, in EITHER device category --
-- the one function every input-consuming module should call instead of comparing
-- input.KeyCode/input.UserInputType against a hardcoded constant. An action bound on both keyboard
-- and gamepad (the common case for combat actions) matches a press from either device -- a
-- physical InputObject can only ever match one of the two anyway (it has exactly one real
-- KeyCode/UserInputType), so checking both maps here is always safe, never a double-fire.
function KeybindManager.Matches(action: Types.KeybindAction, input: InputObject): boolean
	return keybindMatchesInput(currentBindings[action], input)
		or keybindMatchesInput(currentGamepadBindings[action], input)
end

-- True if EITHER of Roblox's own default jump bindings is currently physically held: Space
-- (keyboard) or ButtonA (gamepad -- Roblox's stock jump binding on every gamepad regardless of
-- manufacturer, DualSense included). Unlike Matches/Get above, this is NOT a per-action lookup
-- against currentBindings/currentGamepadBindings -- jump has no Types.KeybindAction entry to look
-- up (see file header) -- so this is a direct UserInputService poll of a fixed KeyCode pair, the one
-- place that pair is allowed to appear instead of scattered across every caller.
--
-- THE GAMEPAD HALF WENT THROUGH Analog.IsButtonDown, and the reason is a silent-failure trap worth
-- naming: this function used to ask UserInputService:IsKeyDown(Enum.KeyCode.ButtonA). IsKeyDown
-- resolves KEYBOARD keys only. Handed a gamepad KeyCode it does not error and does not warn -- it
-- returns false, every frame, forever. Nothing in the toolchain can catch that (a KeyCode is a
-- KeyCode to the typechecker, and selene has no opinion), and the read is a poll rather than a
-- routed binding, so there was no InputRouter dispatch log to miss either.
--
-- What it cost: Client/Parkour/ParkourInput.lua polls this once per Heartbeat and is the ONLY thing
-- that ever stamps InputBuffer.PressJump. On a controller that stamp never happened, so
-- StateSupport.JumpQueued was false for the whole session and every jump-driven parkour action was
-- unreachable -- wall-jumps, ledge climb-ups, ledge leaps, slide-jumps and the wall launch. Ordinary
-- jumping still worked throughout, which is what made it read as "only parkour is broken": Roblox's
-- own control module binds ButtonA through its own path and never consults this function.
function KeybindManager.IsJumpKeyDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.Space) or Analog.IsButtonDown(Enum.KeyCode.ButtonA)
end

-- Backend-only entry point for rebinding the KEYBOARD/mouse binding -- see file header for why
-- nothing calls this yet. Every input module already reads through Matches()/Get(), so this is
-- the one function a future settings screen's keyboard row needs to call. Returns false (and does
-- not apply the change) if newKeybind is already bound to a different action WITHIN THIS SAME
-- category, so two actions can never silently collide on one keyboard input -- a keyboard bind and
-- a gamepad bind are different categories and never collide with each other (Dash being both Q
-- and gamepad ButtonB at once is the whole point, not a conflict).
function KeybindManager.Rebind(action: Types.KeybindAction, newKeybind: Types.Keybind): boolean
	for existingAction, existingKeybind in pairs(currentBindings) do
		if existingAction ~= action and isSameKeybind(existingKeybind, newKeybind) then
			logger:warn(
				"Rebind rejected: input already bound to another action",
				{ action = action, conflictingAction = existingAction }
			)
			return false
		end
	end

	currentBindings[action] = newKeybind
	logger:info("Keybind rebound", { action = action })
	notifyChanged()
	return true
end

-- Same as Rebind above, for the GAMEPAD binding -- a future settings screen's gamepad row would
-- call this one instead. Collision-checked against other GAMEPAD bindings only, same "separate
-- category" reasoning as Rebind's own header.
function KeybindManager.RebindGamepad(action: Types.KeybindAction, newKeybind: Types.Keybind): boolean
	for existingAction, existingKeybind in pairs(currentGamepadBindings) do
		if existingAction ~= action and existingKeybind and isSameKeybind(existingKeybind, newKeybind) then
			logger:warn(
				"Gamepad rebind rejected: input already bound to another action",
				{ action = action, conflictingAction = existingAction }
			)
			return false
		end
	end

	currentGamepadBindings[action] = newKeybind
	logger:info("Gamepad keybind rebound", { action = action })
	notifyChanged()
	return true
end

-- Resets every action back to Constants.Keybinds.Defaults -- the "restore defaults" a future
-- settings screen will want, free to build now since currentBindings already starts as a clone of
-- that same table.
function KeybindManager.ResetToDefaults(): ()
	currentBindings = table.clone(Constants.Keybinds.Defaults)
	logger:info("Keybinds reset to defaults")
	notifyChanged()
end

-- Same as ResetToDefaults above, for the gamepad map.
function KeybindManager.ResetGamepadToDefaults(): ()
	currentGamepadBindings = table.clone(Constants.Keybinds.GamepadDefaults)
	logger:info("Gamepad keybinds reset to defaults")
	notifyChanged()
end

-- How a binding is SPELLED for a player to read -- on a rebind row, a key cap, a control legend.
-- Safe to call with nil (an action with no binding in the requested category), which is the whole
-- reason it takes a Keybind? rather than an action: the gamepad map is honestly partial.
function KeybindManager.Describe(keybind: Types.Keybind?): string
	if not keybind then
		return "Unbound"
	end
	if keybind.KeyCode then
		return keybind.KeyCode.Name
	end
	if keybind.UserInputType then
		local name = keybind.UserInputType.Name
		return INPUT_TYPE_LABELS[name] or name
	end
	return "Unbound"
end

-- Registers `listener` to run after any binding changes, in either device category. Fires once per
-- change, with no arguments: every consumer so far re-reads whichever bindings it cares about rather
-- than diffing one, and passing an action would tempt a listener into tracking a subset and missing
-- ResetToDefaults, which changes all of them at once.
--
-- Returns an unsubscribe function. Same shape and same reasoning as Client/Combat/HotbarBindings.lua's
-- own OnChanged: today's consumers subscribe once for the life of the client session and never
-- disconnect, but it is returned anyway rather than assumed away.
function KeybindManager.OnChanged(listener: () -> ()): () -> ()
	table.insert(changedListeners, listener)
	return function()
		local index = table.find(changedListeners, listener)
		if index then
			table.remove(changedListeners, index)
		end
	end
end

return KeybindManager
