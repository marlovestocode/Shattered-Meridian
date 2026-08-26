--!strict
--[[
	KitTypes.lua

	Owns: KitAbilityDefinition, the one ability shape Race Traits (Shared/Race/RaceTraitTypes.lua)
	and Bloodline stage grants (Shared/Bloodline/BloodlineTypes.lua) both author onto -- kept as its
	own module rather than duplicated per content layer, the same "an art IS a move, no second
	identity" lesson this codebase already learned from the Arts/Hotbar unification: two content
	types that are conceptually the same ability shape share ONE definition, not two independently
	drifting copies.

	Does not own: the generic modifier engine an ability's Effects list is applied through
	(Types.ActiveModifierSpec / Server/Systems/EffectSystem.lua -- not built yet, a later phase of
	the Race Traits + Bloodline Abilities plan), the trigger/remote path that resolves a player
	request into a CanUseAbility/UseAbility call (Server/Systems/KitAbilitySystem.lua -- also later),
	or either content layer's own eligibility rules (Server/Systems/RaceSystem.lua,
	Server/Systems/BloodlineSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local KitTypes = {}

-- "Passive" -- held for as long as its grant is true (a race trait at a qualifying tier, a reached
-- bloodline stage), applied/removed via EffectSystem.SetBoundModifiers, never fired by a player
-- action. "Active" -- fired on demand through KitAbilitySystem, gated by CooldownSeconds/QiCost the
-- same way ArtSystem.CanUse gates a cast -- see ArtConstants.lua for that precedent.
export type KitAbilityKind = "Passive" | "Active"

-- The one ability shape both Race Traits and Bloodline stage grants author onto. CooldownSeconds/
-- QiCost are meaningful only for Kind == "Active" -- a Passive ability fires nothing a cooldown or a
-- Qi cost could gate, since nothing ever calls UseAbility for it; RaceSystem/BloodlineSystem simply
-- ignore both fields for a Passive entry rather than requiring them to be authored as 0.
export type KitAbilityDefinition = {
	Id: string,
	DisplayName: string,
	Description: string,
	Kind: KitAbilityKind,
	CooldownSeconds: number,
	QiCost: number,
	-- What this ability grants/does, expressed as the same modifier specs EffectSystem.Apply/
	-- SetBoundModifiers consume -- see Types.ActiveModifierSpec's own header for the three lifetimes
	-- and three effect kinds v1 supports. A Passive ability's Effects are Lifetime == "Bound" (held
	-- for as long as the grant holds); an Active ability's are typically "Timed" (a temporary buff)
	-- or "Instant" (e.g. a Qi restore, v1's only Instant target).
	Effects: { Types.ActiveModifierSpec },
}

return KitTypes
