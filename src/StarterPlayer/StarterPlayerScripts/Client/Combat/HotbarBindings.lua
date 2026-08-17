--!strict
--[[
	HotbarBindings.lua

	Owns: the local admin's session-scoped slot(1-5) -> MoveId binding for the HUD hotbar
	(Client/UI/Screens/HUD/init.lua's five AbilitySlots) -- which Move-Editor-authored move each
	slot fires when pressed/clicked. In-memory only, never persisted across sessions -- the same
	accepted limitation Client/Input/KeybindManager.lua's own header documents for keybind
	remapping, and for the identical reason: no settings/preferences System exists yet to persist
	to, and this is a purely client-side, admin-local convenience with nothing server-authoritative
	riding on it (CombatSystem.lua's handleFireHotbarMoveRequest re-validates the admin and the
	move itself independently of whatever this module happens to hold).

	Written to by exactly one place today (Client/MoveEditor/MoveEditorClient.lua's
	BindHotbarSlotRequested handler, itself driven by a "Bind to slot" control in
	Client/UI/Screens/MoveEditor/PropertyEditor.lua's toolbar) and read from two
	(Client/Combat/AttackInputClient.lua to resolve what a keybind/click press should fire, and
	Client/UI/Screens/HUD/init.lua to reflect Locked/Available/Cooldown per slot) -- a genuine multi-writer-
	unnecessary, multi-reader shared module, the same shape Client/Input/KeybindManager.lua already
	established for "plain Luau module, no Fusion dependency, a changed-callback list for the one
	reactive consumer that needs one" rather than threading Fusion.Value through three unrelated
	call sites that don't otherwise need Fusion.

	Does not own: firing the bound move (AttackInputClient.lua), rendering the hotbar
	(HUD/init.lua), or admin authorization -- nothing here checks whether the local player is
	actually an admin. That's fine, and the rebuilt attack layer keeps the same contract this header
	always described: the only way a MoveId ever reaches Set() is through the Move Editor's own
	admin-gated UI (which never even starts for a non-admin -- see MoveEditorClient.lua's
	requestServerAuthorization), and firing a bound move still round-trips through the server's own
	AdminConfig re-check regardless of what this module holds (Server/Combat/Attack/
	AttackRequestSystem.lua's resolveRequest, and AttackTypes.AttackRequest.MoveId's own header) --
	so a non-admin client with a hand-crafted binding here gains nothing.
]]

local HotbarBindings = {}

export type Slot = number

local SLOT_COUNT = 5

local bindings: { [number]: string? } = {}
local changedListeners: { (slot: number, moveId: string?) -> () } = {}

local function isValidSlot(slot: number): boolean
	return slot == math.floor(slot) and slot >= 1 and slot <= SLOT_COUNT
end

-- The MoveId currently bound to `slot`, or nil if that slot is empty. Never errors on an
-- out-of-range slot -- just reports "nothing bound," the same permissive contract
-- KeybindManager.GetGamepad extends to a missing gamepad binding.
function HotbarBindings.Get(slot: number): string?
	if not isValidSlot(slot) then
		return nil
	end
	return bindings[slot]
end

-- Shallow copy of every current binding, keyed by slot -- for HUD/init.lua's initial render and
-- MoveEditorClient.lua's PropertyEditor "which slot(s) is this move already on" reflection. Never
-- for a caller to mutate directly (mutating the returned table has no effect on the real bindings).
function HotbarBindings.GetAll(): { [number]: string? }
	return table.clone(bindings)
end

-- Binds `slot` to `moveId` (or clears it, if moveId is nil) -- always overwrites whatever was
-- previously bound there, the same "last write wins, no conflict rejection" contract a hotbar slot
-- assignment needs (unlike KeybindManager.Rebind, there is no cross-slot collision to guard: two
-- slots holding the same MoveId is harmless, just a redundant bind). No-ops (fires no listener) if
-- the value isn't actually changing, so a redundant Set doesn't cause HUD/init.lua to needlessly
-- recompute its per-slot State.
function HotbarBindings.Set(slot: number, moveId: string?): ()
	assert(isValidSlot(slot), `HotbarBindings.Set: slot must be an integer 1-{SLOT_COUNT}, got {tostring(slot)}`)
	if bindings[slot] == moveId then
		return
	end
	bindings[slot] = moveId
	for _, listener in ipairs(changedListeners) do
		listener(slot, moveId)
	end
end

-- Convenience wrapper for HotbarBindings.Set(slot, nil) -- reads more clearly at PropertyEditor.lua's
-- own "unbind" call site than a bare nil literal would.
function HotbarBindings.Clear(slot: number): ()
	HotbarBindings.Set(slot, nil)
end

-- Registers `listener` to run on every future Set/Clear that actually changes a slot's value.
-- Returns an unsubscribe function; nothing in this codebase's own two consumers (HUD/init.lua,
-- MoveEditorClient.lua) ever needs to call it today -- both subscribe once for the life of the
-- client session, the same "never disconnected" shape ClientState.Bootstrap's own remote listeners
-- already use -- but it's returned anyway rather than assumed away, the cheap-and-correct default
-- for any listener-registration API.
function HotbarBindings.OnChanged(listener: (slot: number, moveId: string?) -> ()): () -> ()
	table.insert(changedListeners, listener)
	return function()
		local index = table.find(changedListeners, listener)
		if index then
			table.remove(changedListeners, index)
		end
	end
end

return HotbarBindings
