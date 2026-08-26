--!strict
--[[
	BloodlineTypes.lua

	Owns: BloodlineDefinition / BloodlineStageDefinition / BloodlineAwakeningCondition -- the
	authored shape Server/Managers/BloodlineManager.lua's registry holds and
	Server/Systems/BloodlineSystem.lua grants from. Both are real now; this file's own header used
	to say they were still Init(): () end stubs "not this phase", which stopped being true and was
	not updated. A bloodline is the rarer, awakened layer on top of a race's baseline traits
	(Shared/Race/RaceTraitTypes.lua) -- a separate content type with its own definition shape,
	sharing only KitAbilityDefinition (Shared/Kit/KitTypes.lua).

	Does not own: awakening/stage-advancement triggering (BloodlineSystem's own interim on-kill
	dispatch, mirroring MeridianSystem.lua's existing GameplayEvents.OnPlayerKilled pattern -- see
	the Race Traits + Bloodline Abilities plan's section 4), persistence
	(Types.PlayerProfile.bloodlineIds already exists; this plan adds bloodlineStageProgress alongside
	it), or the editor that authors these (Server/Systems/KitEditorSystem.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local KitTypes = require(ReplicatedStorage.Shared.Kit.KitTypes)

local BloodlineTypes = {}

-- Open string Kind (not a closed union) because a bloodline's awakening/stage-advancement trigger is
-- a per-content decision, not a fixed roster this file can enumerate ahead of time -- v1 ships
-- exactly one, "OnPlayerKilled", reusing GameplayEvents.OnPlayerKilled the same interim way
-- MeridianSystem.lua already does. Params carries whatever numbers that Kind needs to interpret --
-- e.g. a kill-count threshold for a first awakening, additional-kills-since-this-stage for
-- advancement, or a harder threshold for the Human-Ascension case world-bible.md's "contested
-- authority" framing describes -- so a new Kind never needs a new top-level field on this struct.
export type BloodlineAwakeningCondition = {
	Kind: string,
	Params: { [string]: number },
}

export type BloodlineStageDefinition = {
	StageIndex: number,
	DisplayName: string,
	-- Held for as long as this is the player's current stage -- applied via
	-- EffectSystem.SetBoundModifiers on awaken/advance and re-applied on profile load, the same
	-- "Bound" lifetime a Race Trait's own passive uses (Types.ActiveModifierSpec's own header).
	PassiveEffects: { Types.ActiveModifierSpec },
	-- nil = this stage grants no Active ability of its own (a pure stat-passive stage). Present =
	-- reachable through KitAbilitySystem the moment this becomes the player's current stage.
	GrantedAbility: KitTypes.KitAbilityDefinition?,
}

export type BloodlineDefinition = {
	BloodlineId: Types.BloodlineId,
	DisplayName: string,
	-- Free-form authoring tag ("Common", "Rare", "Ascendant", ...) -- no closed taxonomy yet, the
	-- same "purely a list-UI grouping aid, never read by resolution logic" reasoning
	-- MoveDefinition.Category's own header gives for that field.
	RarityTier: string,
	FlavorText: string,
	-- nil = obtainable by a player of any race. Present = only players of this race can awaken it --
	-- world-bible.md's per-race bloodline affinities.
	NativeRaceId: Types.RaceId?,
	AwakeningCondition: BloodlineAwakeningCondition,
	-- Ordered by StageIndex, stage 1 first. BloodlineManager.AuditStages flags a non-contiguous
	-- authored list as a non-fatal boot-time warning rather than rejecting it outright, mirroring
	-- ArtTreeManager.AuditPrerequisites' own reasoning for the identical authoring-problem class.
	Stages: { BloodlineStageDefinition },
}

-- RemoteFunction result shapes for Server/Systems/KitEditorSystem.lua's Bloodline remotes -- same
-- "kept with the content type, not in Types.lua" reasoning RaceTraitTypes.lua's own
-- RaceTraitEditor*Result trio gives.
export type BloodlineEditorListResult = {
	Success: boolean,
	Reason: string?,
	Bloodlines: { BloodlineDefinition }?,
}

export type BloodlineEditorBloodlineResult = {
	Success: boolean,
	Reason: string?,
	Bloodline: BloodlineDefinition?,
}

-- What BloodlineSystem's Spin remote answers with. RerollsRemaining rides along on SUCCESS AND
-- FAILURE alike, so the creator's own "3 rerolls left" readout is corrected by every response --
-- including a refusal it was not expecting -- rather than being tracked independently client-side
-- and drifting from the profile that actually owns the number.
export type BloodlineSpinResult = {
	Success: boolean,
	Reason: string?,
	BloodlineId: string?,
	-- The three display fields of whatever was rolled, sent alongside the id rather than leaving the
	-- client to look them up. The client has no bloodline registry of its own -- BloodlineManager is
	-- server-only -- so without these a reveal could show an opaque BloodlineId and nothing else.
	-- Three strings rather than the whole BloodlineDefinition: Stages carry every ability and effect
	-- spec in the bloodline, none of which a reveal card renders.
	DisplayName: string?,
	RarityTier: string?,
	FlavorText: string?,
	RerollsRemaining: number,
}

export type BloodlineEditorActionResult = {
	Success: boolean,
	Reason: string?,
}

return BloodlineTypes
