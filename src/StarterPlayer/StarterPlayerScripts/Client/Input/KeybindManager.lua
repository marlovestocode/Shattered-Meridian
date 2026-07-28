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

local logger = Logger.scope("KeybindManager")

local KeybindManager = {}

-- Cloned from Constants.Keybinds.Defaults/GamepadDefaults at module load so neither Rebind ever
-- mutates those shared tables (Constants.lua is read-only tunable data per its own header). The
-- gamepad map's value type is Keybind?, not Keybind, matching GamepadDefaults' own honestly-partial
-- typing (DevMenuToggle has no gamepad entry -- see file header).
local currentBindings: { [Types.KeybindAction]: Types.Keybind } = table.clone(Constants.Keybinds.Defaults)
local currentGamepadBindings: { [Types.KeybindAction]: Types.Keybind? } =
	table.clone(Constants.Keybinds.GamepadDefaults)

local function isSameKeybind(a: Types.Keybind, b: Types.Keybind): boolean
	return a.KeyCode == b.KeyCode and a.UserInputType == b.UserInputType
end

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

-- The KEYBOARD/mouse keybind currently assigned to `action`. Every action has one (Defaults is a
-- complete map) -- for the possibly-absent gamepad side, see GetGamepad below.
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
function KeybindManager.IsJumpKeyDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.ButtonA)
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
	return true
end

-- Resets every action back to Constants.Keybinds.Defaults -- the "restore defaults" a future
-- settings screen will want, free to build now since currentBindings already starts as a clone of
-- that same table.
function KeybindManager.ResetToDefaults(): ()
	currentBindings = table.clone(Constants.Keybinds.Defaults)
	logger:info("Keybinds reset to defaults")
end

-- Same as ResetToDefaults above, for the gamepad map.
function KeybindManager.ResetGamepadToDefaults(): ()
	currentGamepadBindings = table.clone(Constants.Keybinds.GamepadDefaults)
	logger:info("Gamepad keybinds reset to defaults")
end

return KeybindManager
