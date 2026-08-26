--!strict
--[[
	WeaponInventory/init.lua

	Owns: the client's picture of what the server says this player is carrying -- which weapons have
	been picked up, which one the draw key acts on, and whether it is in hand -- as three Fusion
	Values, plus the handle that writes them.

	Client/Combat/WeaponInventoryClient.lua drives that handle on every Weapon_InventoryChanged push;
	this file itself sends and receives nothing, the same "screen exposes state, client module drives
	it" split Screens/CarriedResources/init.lua and Screens/BlimpFuel/init.lua both follow.

	IT RENDERS NOTHING NOW, AND THAT IS THE POINT OF THE 2026-08-25 REBUILD. What used to be here was
	a 212-wide corner panel: a hero row, a bordered rack sub-container listing two weapon NAMES and a
	"+N MORE" line, its own chrome, and its own entrance. The brief was to attach that readout to the
	hotbar dock's left edge, and the previous attempt did it by reskinning this panel -- same shell,
	same rows, the dock's Panel props swapped in, and Tokens.Space.L of gap left between the two. It
	read as two panels near each other, because that is what it was.

	The readout is now Screens/HUD/ArmamentIsland.lua, and it lives THERE rather than here because it
	is one half of a JOINT with the dock -- a shared seam, a shared edge rule, a shared height and a
	shared content baseline -- and a joint has exactly one owner. Screens/HUD/init.lua owns the dock's
	plate; it now owns the surface bolted to it.

	WHICH DIRECTION THE DEPENDENCY RUNS WAS ALREADY DECIDED, and this is the version that honours it.
	The old file carried the note that "a require would be the wrong direction anyway: HUD lays this
	island out, so a dependency from here to there would make the content module depend on its own
	container" -- and then declared a duplicate of HUD's island type to avoid one. That reasoning was
	right; what it implied was that the CONTAINER should own the rendering and this file should own
	the state. So it does: nothing here requires Screens/HUD, nothing in Screens/HUD requires this,
	and the ArmamentState below matches HUD/ArmamentIsland's own exported type structurally (Luau
	types are structural, so the two agree without either import).

	Does not own: the inventory itself (Server/Combat/Weapon/WeaponInventorySystem.lua is the
	authority; this only ever mirrors what it is told), the keys that change it (Client/Combat/
	AttackInputClient.lua owns both binds), or the pickup prompt.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type WeaponInventoryHandle = {
	SetInventory: (payload: WeaponConstants.InventoryPayload) -> (),
}

-- Structurally identical to Screens/HUD/ArmamentIsland's own ArmamentState, and DECLARED HERE rather
-- than imported from it -- see this file's header on why the require would run the wrong way.
export type ArmamentState = {
	Owned: UsedAs<{ string }>,
	Selected: UsedAs<string?>,
	Drawn: UsedAs<boolean>,
}

local WeaponInventory = {}

-- Returns the handle Client/Combat/WeaponInventoryClient.lua drives, and the state Screens/HUD hands
-- to the armament island it builds against the dock's left edge. UI/init.lua mounts this BEFORE the
-- HUD for that reason and no other.
function WeaponInventory.Mount(scope: Scope): (WeaponInventoryHandle, ArmamentState)
	local owned: Fusion.Value<{ string }> = scope:Value({})
	local selected: Fusion.Value<string?> = scope:Value(nil)
	local drawn: Fusion.Value<boolean> = scope:Value(false)

	-- Written verbatim, with no local derivation, guarding or reordering. The island decides what to
	-- SHOW -- whether it is on screen at all, how many rack beads fit, which one is lit -- and every
	-- one of those is a presentation question this file would be guessing at. The payload's own
	-- contract (WeaponConstants.InventoryPayload) is the whole interface.
	local function setInventory(payload: WeaponConstants.InventoryPayload): ()
		owned:set(payload.Owned)
		selected:set(payload.Selected)
		drawn:set(payload.Drawn)
	end

	return {
		SetInventory = setInventory,
	}, {
		Owned = owned,
		Selected = selected,
		Drawn = drawn,
	}
end

return WeaponInventory
