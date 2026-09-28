--!strict
--[[
	WeaponConstants.lua

	Owns: the weapon inventory layer's tunables and its wire contract -- the pickup prompt's text and
	reach, the remote names, the per-player rate bound, and the InventoryChanged payload shape.

	A STANDALONE MODULE rather than a Constants.Weapons section, for the reason Constants.lua's own
	header gives and AttackConstants/DefenseConstants/BlimpConstants each already took: this is one
	layer's tuning surface, read by one Server System and one Client controller, neither of which
	should have to pull in the whole cross-system registry to learn how far away a sword can be grabbed
	from.

	Deliberately NOT here: what a weapon hits for, or which weapons exist -- both are
	Shared/Combat/WeaponRoster.lua's, read off the models in Workspace.Weapons rather than authored
	anywhere in Lua. This file is only about the act of picking one up and getting it out.
]]

local WeaponConstants = {}

export type InventoryPayload = {
	-- Every weapon id this player has picked up, in pickup order.
	Owned: { string },
	-- Which of them the draw key will pull out. nil for an empty inventory.
	Selected: string?,
	-- Whether Selected is in hand right now.
	Drawn: boolean,
}

WeaponConstants.Prompt = {
	-- Named so WeaponModelRegistry's own stripPrompts and this System's "already prompted" guard both
	-- have something stable to look for.
	Name = "WeaponPickupPrompt",
	ActionText = "Take",
	-- Reach. Shorter than the Blimp's own station prompts (which are on a large moving vehicle a player
	-- approaches from anywhere) -- a weapon on a rack is a thing you walk right up to, and a generous
	-- radius here would mean two swords side by side both offering their prompt at once.
	MaxActivationDistance = 8,
	-- A HOLD, not a tap. Picking a weapon up is not reversible from the UI (there is no drop yet), and
	-- a hold is the established affordance for "this commits you to something" -- the same reason the
	-- Blimp's mount prompts hold and its furnace deposit does not.
	HoldDuration = 0.6,
	-- Weapons sit on racks, tables and walls, often part-embedded in them. Line of sight would make a
	-- sword lying in a display case unreachable for reasons the player cannot see or fix.
	RequiresLineOfSight = false,
}

-- The two names Server/Combat/Weapon/WeaponVisualSystem.lua stamps on the Tool it puts in a
-- combatant's hand. Promoted out of that System's own private constants and into Shared for one
-- reason: this pair is the ONLY replicated statement of "which weapon is this character holding right
-- now" that a client can read about ANOTHER player. Weapon_InventoryChanged is owner-only by design
-- (see RemoteNames.InventoryChanged below), so a client watching someone else block a swing has no
-- other source for the weapon whose block sound should play -- see Client/FX/CombatAudio.lua's own
-- drawnWeaponIdOf.
--
-- Constants rather than a helper function: reading them is two lines at the one call site that needs
-- it, and putting an Instance-walking helper in a constants module would be the start of a second,
-- competing weapon-state API alongside WeaponRoster's.
WeaponConstants.Visual = {
	-- The Tool's Name. Present on the character exactly while a weapon is DRAWN -- a sheath destroys
	-- it (WeaponVisualSystem.EquipVisual's nil-weaponId case), so its absence is itself the answer
	-- "nothing drawn", not a lookup failure.
	ToolName = "EquippedWeaponVisual",
	-- The Attribute on that Tool carrying the weapon id it was built from.
	WeaponIdAttribute = "WeaponId",
}

WeaponConstants.Network = {
	RemoteNames = {
		-- Client -> server, the draw/sheath key. No payload at all: the server owns which weapon is
		-- selected, so there is nothing for the client to name and nothing to validate.
		ToggleDraw = "Weapon_ToggleDraw",
		-- Client -> server, the cycle-selection key. Also payload-free, same reasoning.
		SelectNext = "Weapon_SelectNext",
		-- Server -> owner only, on every pickup/draw/sheath/select and on every character bind.
		InventoryChanged = "Weapon_InventoryChanged",
	},

	-- Both client->server remotes here are one-shot key presses that mutate nothing a spammer could
	-- profit from (a draw is free and instant either way), so this only has to bound the traffic, not
	-- the gameplay. Sized like DefenseConstants' own per-player bound: comfortably above what a human
	-- can press, comfortably below what an automated client would try.
	MaxTogglesPerSecondPerPlayer = 8,

	-- A ProximityPrompt.Triggered signal, not a remote, but the same trust boundary applies -- an
	-- exploited client can fire it with no real proximity or hold duration at all (a known Roblox
	-- surface, not specific to this System). Bounded far below MaxTogglesPerSecondPerPlayer: a
	-- legitimate pickup is a single hold-then-release per weapon, ever, per this file's own
	-- "grows, never shrinks" Owned contract.
	MaxPickupsPerSecondPerPlayer = 4,
}

return WeaponConstants
