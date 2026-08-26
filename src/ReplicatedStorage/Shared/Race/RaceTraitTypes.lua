--!strict
--[[
	RaceTraitTypes.lua

	Owns: RaceTraitDefinition -- the authored shape Server/Managers/RaceManager.lua's registry holds
	and Server/Systems/RaceSystem.lua grants from, once both exist (not this phase). A trait is the
	baseline, always-available kit every player of a race can hold once they reach RequiredTier --
	the rarer, awakened Bloodline layer (Shared/Bloodline/BloodlineTypes.lua) is a separate content
	type with its own definition shape, sharing only KitAbilityDefinition (Shared/Kit/KitTypes.lua)
	-- see that module's own header for why the two layers share an ability shape but not a content
	shape.

	Does not own: eligibility computation (RaceSystem derives it from profile.raceId +
	TierSystem.GetTier(player) >= RequiredTier, no new PlayerProfile field), persistence (a trait
	grant has none of its own to persist -- see the Race Traits + Bloodline Abilities plan's
	Persistence section), or the editor that authors these (Server/Systems/KitEditorSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)

local RaceTraitTypes = {}

export type RaceTraitDefinition = {
	TraitId: string,
	RaceId: Types.RaceId,
	-- Minimum TierSystem tier before this trait's Ability is granted. RaceSystem re-evaluates on
	-- PlayerDataSystem.OnProfileLoaded and GameplayEvents.OnTierChanged -- never on a schedule, and
	-- never needs a tier-DOWN case since TierSystem's own tier is never-demote.
	RequiredTier: Types.Tier,
	Ability: KitTypes.KitAbilityDefinition,
}

-- RemoteFunction result shapes for Server/Systems/KitEditorSystem.lua's Race Trait remotes -- kept
-- here rather than in Types.lua for the same "large, self-contained, additive schema, no consumer
-- outside this feature" reason MoveTypes.lua's own header gives for MoveEditorListResult/
-- MoveEditorMoveResult/MoveEditorActionResult.
export type RaceTraitEditorListResult = {
	Success: boolean,
	Reason: string?,
	Traits: { RaceTraitDefinition }?,
}

export type RaceTraitEditorTraitResult = {
	Success: boolean,
	Reason: string?,
	Trait: RaceTraitDefinition?,
}

export type RaceTraitEditorActionResult = {
	Success: boolean,
	Reason: string?,
}

return RaceTraitTypes
