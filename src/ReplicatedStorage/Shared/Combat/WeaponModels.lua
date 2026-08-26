--!strict
--[[
	WeaponModels.lua

	Owns: turning a WeaponId into a real, equippable Tool -- a fresh Clone() of the template
	WeaponModelRegistry cached for that weapon, per equip. Nothing here decides WHEN a weapon is
	equipped, WHO is holding it, or what happens to whatever they were holding before -- see
	Server/Combat/Weapon/WeaponVisualSystem.lua for all three.

	A THIN SEAM, and deliberately almost nothing. This module used to hold a hardcoded
	WeaponId -> { ModelId, DisplayName } map back when there were exactly two weapons; a WeaponId IS
	the model's Name now (see Shared/Combat/WeaponRoster.lua), so the lookup that map existed to
	perform has no work left to do. What remains is the one thing that is genuinely this module's:
	clone-per-equip, so no two characters ever share a Tool instance.

	Does not own: which weapons exist (WeaponRoster), which template is cached for one
	(WeaponModelRegistry), when a character's held weapon changes (AttackRequestSystem.
	OnWeaponChanged), or attaching the built Tool to a character (WeaponVisualSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local WeaponModelRegistry = require(ReplicatedStorage.Shared.Combat.WeaponModelRegistry)

type WeaponId = Types.WeaponId

local WeaponModels = {}

-- The whole module's contract: a WeaponId in, an equippable Tool out -- or nil when nothing is
-- registered under that id (an empty Workspace.Weapons, or a model that failed the registry's own
-- Handle check). nil is a real answer, not a failure: WeaponVisualSystem reads it as "unequip, this
-- weapon draws nothing" rather than equipping an empty Tool.
function WeaponModels.Build(weaponId: WeaponId): Tool?
	local template = WeaponModelRegistry.GetTemplate(weaponId)
	if not template then
		return nil
	end

	-- Cloned here (not inside the registry) so every equip gets its own Instance --
	-- WeaponModelRegistry.GetTemplate hands back the cached master itself, and cloning it per character
	-- is this function's job.
	local tool = template:Clone()
	-- The weapon's own name is what a player sees on the Tool; the roster keys off the same string, so
	-- there is no separate display name to look up or keep in sync.
	tool.ToolTip = weaponId
	return tool
end

return WeaponModels
