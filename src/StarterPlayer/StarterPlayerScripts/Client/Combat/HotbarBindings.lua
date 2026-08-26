--!strict
--[[
	HotbarBindings.lua

	Owns: a READ-ONLY local mirror of the server's slot(1-5) -> ArtId map (Types.PlayerProfile.
	equippedArts, via ArtConstants.RemoteNames.ArtStateUpdated) for the HUD hotbar
	(Client/UI/Screens/HUD/init.lua's five AbilitySlots) and the Move Editor toolbar's "which
	slot(s) is this move already on" row (PropertyEditor.lua) to read.

	IT MIRRORS THE ART'S NAME AND COST TOO, as of 2026-08-25 -- GetInfo below. An ArtId is a move-
	registry key and the registry is server-side, so a client holding only the id has an identifier it
	cannot render: the hotbar could tell that a slot was FULL but not what was in it, and drew
	AbilitySlot's empty-slot reticle over every equipped art. Types.ArtStatePayload.EquippedInfo now
	travels on the same push (see that field on why it is keyed by art while this module keys by
	slot), so the same "one push, one mirror, one authority" shape covers what a slot IS as well as
	which slot it is in. This is still not an authority on either -- see the last paragraph.

	USED TO BE A SECOND, WRITABLE SLOT MAP -- the Move Editor's own "Bind to slot" control wrote
	here directly, independent of the server's equippedArts, and CharacterMenuClient.lua mirrored
	equippedArts into the SAME five slots on top of it. An art IS a move (see ArtTreeManager.lua's
	own header -- an art's ArtId is its MoveId), so there was only ever one thing to store, and two
	writers meant an art equip silently erased an editor binding (CharacterMenuClient's mirror
	fires on every RegisterUse, i.e. every art use) while an editor binding silently shadowed an
	equipped art in the UI without changing what the server actually fired. See ArtSystem.lua's own
	header on the server-side half of that fix: the Move Editor's slot button now calls
	ArtSystem.DevGrantAndEquip (through Constants.MoveEditor.RemoteNames.EquipArtSlot), which writes
	the SAME equippedArts this module only ever mirrors. There is no longer a second writer.

	Written to by exactly one place (CharacterMenuClient.lua's mirrorToHotbar, via SyncFromServer
	below, on every Art_StateUpdated push) and read from two (Client/Combat/AttackInputClient.lua to
	resolve what a keybind/click press should fire, and Client/UI/Screens/HUD/init.lua to reflect
	Locked/Available/Cooldown per slot) -- the same "plain Luau module, no Fusion dependency, a
	changed-callback list for the one reactive consumer that needs one" shape Client/Input/
	KeybindManager.lua already established, rather than threading Fusion.Value through call sites
	that don't otherwise need Fusion.

	Does not own: firing the bound move (AttackInputClient.lua), rendering the hotbar (HUD/init.lua),
	or deciding what's equipped (ArtSystem.lua, server-side) -- this is a convenience cache, never an
	authority. Server/Combat/Attack/AttackRequestSystem.lua's resolveRequest ignores whatever a
	client sends and re-resolves the pressed slot against ArtSystem.GetEquipped on every throw, so a
	stale or hand-crafted local value here gains nothing and costs nothing -- it can only make the
	HUD's own read of a slot momentarily wrong, never what actually fires.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local HotbarBindings = {}

export type Slot = number
export type SlotInfo = Types.ArtDisplayInfo

-- ArtConstants' own number, not a third copy of "5". This module mirrors equippedArts exactly, so
-- a mirror with its own independent bound would silently truncate (or leave stale entries past the
-- end of) the map it is supposed to be a copy of the moment those two numbers disagreed.
local SLOT_COUNT = ArtConstants.EquipSlotCount

local bindings: { [number]: string? } = {}
-- The presentation half of each slot, mirrored from the same push (Types.ArtStatePayload's
-- EquippedInfo). Kept per SLOT rather than per art -- the payload keys it by art because that is the
-- drift-free way to SEND it, but every consumer here asks "what is in slot N", and re-joining the two
-- tables at each call site would be the same lookup written four times.
local slotInfo: { [number]: SlotInfo? } = {}
local changedListeners: { (slot: number, moveId: string?, info: SlotInfo?) -> () } = {}

local function isValidSlot(slot: number): boolean
	return slot == math.floor(slot) and slot >= 1 and slot <= SLOT_COUNT
end

-- Whether two slot-info rows say the same thing. Compared field by field rather than by identity
-- because every push deserialises into fresh tables, so `==` is false on every single one of them --
-- which would turn the no-op guard below into "always changed" and hand HUD/init.lua a spurious
-- rebuild for all five slots on every art use (sendArtState fires on RegisterUse).
local function sameInfo(left: SlotInfo?, right: SlotInfo?): boolean
	if left == nil or right == nil then
		return left == right
	end
	return left.DisplayName == right.DisplayName and left.QiCost == right.QiCost
end

local function setSlot(slot: number, moveId: string?, info: SlotInfo?): ()
	-- The INFO is part of the comparison, not just the id: an art renamed or re-priced in the Move
	-- Editor keeps its ArtId, so an id-only guard would leave the hotbar showing the old name until
	-- something unrelated changed the binding.
	if bindings[slot] == moveId and sameInfo(slotInfo[slot], info) then
		return
	end
	bindings[slot] = moveId
	slotInfo[slot] = info
	for _, listener in ipairs(changedListeners) do
		listener(slot, moveId, info)
	end
end

-- The ArtId currently equipped in `slot`, or nil if that slot is empty. Never errors on an
-- out-of-range slot -- just reports "nothing bound," the same permissive contract
-- KeybindManager.GetGamepad extends to a missing gamepad binding.
function HotbarBindings.Get(slot: number): string?
	if not isValidSlot(slot) then
		return nil
	end
	return bindings[slot]
end

-- What the art in `slot` is CALLED and what it costs, or nil when the slot is empty (or when the
-- server sent no row for it -- see ArtSystem.buildStatePayload on the one case that produces that).
-- The id alone is not renderable: an ArtId is a move-registry key, and the registry is server-side.
function HotbarBindings.GetInfo(slot: number): SlotInfo?
	if not isValidSlot(slot) then
		return nil
	end
	return slotInfo[slot]
end

-- Shallow copy of every current binding, keyed by slot -- for HUD/init.lua's initial render and
-- MoveEditorClient.lua's PropertyEditor "which slot(s) is this move already on" reflection. Never
-- for a caller to mutate directly (mutating the returned table has no effect on the real bindings).
function HotbarBindings.GetAll(): { [number]: string? }
	return table.clone(bindings)
end

-- Rewrites every slot from `equipped` (Types.ArtStatePayload's Equipped, ArtConstants.EquipSlotCount
-- of them), including the ones it does NOT mention: a slot the server no longer lists is a slot the
-- player cleared, and leaving the old ArtId there would keep showing an art they unequipped.
-- CharacterMenuClient.lua's own mirrorToHotbar is the only caller -- see this file's header on why
-- that is the only legitimate writer left. No-ops per-slot when the value isn't actually changing,
-- so a redundant push doesn't cause HUD/init.lua to needlessly recompute its per-slot State.
--
-- `info` is EquippedInfo from the same payload, keyed by ArtId -- see that field's own comment on why
-- it arrives keyed by art rather than by slot. Optional so a caller mirroring an older payload (or a
-- test driving only the bindings) still works; a slot with no matching row simply has no info, which
-- is the same state an empty slot is in and which the HUD already renders as its empty-slot chrome.
function HotbarBindings.SyncFromServer(equipped: { [number]: string }, info: { [string]: SlotInfo }?): ()
	for slot = 1, SLOT_COUNT do
		local artId = equipped[slot]
		setSlot(slot, artId, if artId and info then info[artId] else nil)
	end
end

-- Registers `listener` to run on every future SyncFromServer call that actually changes a slot's
-- value. Returns an unsubscribe function; nothing in this codebase's own two consumers (HUD/init.lua,
-- MoveEditorClient.lua) ever needs to call it today -- both subscribe once for the life of the
-- client session, the same "never disconnected" shape ClientState.Bootstrap's own remote listeners
-- already use -- but it's returned anyway rather than assumed away, the cheap-and-correct default
-- for any listener-registration API.
function HotbarBindings.OnChanged(listener: (slot: number, moveId: string?, info: SlotInfo?) -> ()): () -> ()
	table.insert(changedListeners, listener)
	return function()
		local index = table.find(changedListeners, listener)
		if index then
			table.remove(changedListeners, index)
		end
	end
end

return HotbarBindings
