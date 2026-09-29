--!strict
--[[
	KitConstants.lua

	Owns: the Race Traits + Bloodline Abilities kit layer's shared runtime config -- the ONE remote
	pair both content layers' Active abilities use, the request rate limit that guards it, and the
	per-field authoring bounds RaceManager.Validate/BloodlineManager.Validate check content against.

	Lifted out of Constants.Kit, which re-exports this module, so existing Constants.Kit.X call sites
	keep working; new code should require this module directly.

	Here rather than in Shared/Authoring/EditorConstants.lua alongside the two editors, even though
	Limits is read by the Kit editor: RemoteNames and RequestMaxCallsPerSecond are runtime wire
	concerns, not authoring ones, and this file sits next to KitTypes.lua and KitValidation.lua --
	the shapes those Limits bound and the code that enforces them. Same rule QiConstants.RemoteNames
	follows: the module that owns a feature's tuning owns its wire names too.

	Does not own: the ability definitions themselves (RaceManager/BloodlineManager hold the authored
	content, hydrated from DataStore at boot by KitEditorSystem.Init), the KitAbilityDefinition/
	ActiveModifierSpec shapes (Shared/Kit/KitTypes.lua), or the trigger/resolution path that spends
	them (Server/Systems/KitAbilitySystem.lua, not built yet).
]]

local KitConstants = {}

-- Race Traits + Bloodline Abilities plan -- KitAbilitySystem's own shared trigger/resolution path
-- (Server/Systems/KitAbilitySystem.lua, not built yet). ONE remote pair for both content layers'
-- Active abilities, not two -- the same anti-duplication reasoning Shared/Kit/KitTypes.lua's own
-- header gives for sharing KitAbilityDefinition itself.
KitConstants.RemoteNames = {
	-- RemoteFunction, not a RemoteEvent -- "the panel has to say why" a use was refused, the same
	-- request/response contract ArtSystem.UnlockArt/EquipArt already use. A utility press is
	-- low-frequency (unlike a combat swing), so there's no client-side prediction/input buffer to
	-- keep in sync the way Combat_RequestBasicAttack's fire-and-forget shape needs.
	RequestAbility = "Kit_RequestAbility",
	-- Server -> owning client only, fired on a successful UseAbility -- the post-success FX echo.
	-- Payload: Types.KitAbilityUsedPayload.
	AbilityUsed = "Kit_AbilityUsed",
}
-- Same per-player budget ArtConstants.RequestMaxCallsPerSecond already uses for its own
-- low-frequency gated-action remotes (unlock/equip) -- a genuine player mashing this button still
-- can't press faster than a few times a second, so anything beyond this is a modified client.
KitConstants.RequestMaxCallsPerSecond = 4

-- Per-field authoring bounds for KitAbilityDefinition/ActiveModifierSpec (Shared/Kit/KitTypes.lua,
-- Types.lua) -- ONE table read by both RaceManager.Validate/BloodlineManager.Validate and, once it
-- exists, KitEditorSystem's own client field bounds, the same "one place the editor's own bounds
-- and the server's own clamp agree on a range" reasoning Constants.MoveEditor.Limits' own header
-- establishes for moves. First-pass ranges, wide enough to cover any
-- real authored ability -- not a balance opinion, same as MoveRegistryManager's own clamp
-- constants, just a floor against a value that would read as broken.
KitConstants.Limits = {
	-- 1-9, matching TierConstants.MaxTier's own count -- hand-written rather than required from
	-- TierConstants (Constants.lua stays a leaf the same way QiConstants.MaxTierDefined's own
	-- hand-written 9 does, per that constant's own header on why).
	RequiredTier = { Min = 1, Max = 9 },
	-- Scaled against QiConstants.MaxQiByTier's own top entry (560 at tier 9) -- a single ability
	-- should never be able to cost or restore more Qi than a player could ever hold.
	QiCost = { Min = 0, Max = 500 },
	QiRestoreAmount = { Min = 0, Max = 500 },
	-- Up to five minutes -- generous enough for a signature ultimate-style ability, still closed
	-- enough that a mis-typed value can't leave an ability permanently on cooldown.
	CooldownSeconds = { Min = 0, Max = 300 },
	-- Up to ten minutes -- long enough for a genuinely long-lasting Bound-adjacent buff authored as
	-- Timed instead, still finite.
	DurationSeconds = { Min = 0.1, Max = 600 },
	-- Symmetric: a trait/stage may buff OR debuff an attribute.
	Delta = { Min = -50, Max = 50 },
	-- Open-ended per-tag semantic (EffectSystem never interprets what a Tag means) -- a generic
	-- 0-100 scale is wide enough for a stacking count or a percentage-style strength either way.
	Magnitude = { Min = 0, Max = 100 },
	-- A bloodline's stage ladder (BloodlineStageDefinition.StageIndex) -- 20 is generous headroom
	-- above any authored bloodline this pass ships (v1 authors none), matching TierSystem's own
	-- nine-tier ladder being a much shorter, separately-owned progression.
	StageIndex = { Min = 1, Max = 20 },
}

return KitConstants
