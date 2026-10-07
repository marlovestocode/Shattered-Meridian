--!strict
--[[
	ProgressionTypes.lua

	Owns: the shapes the fight-to-grow spine is written in -- the confirmed fact a reward is composed
	from (ProgressionEvent), the immutable reward manifest RewardSystem composes (RewardManifest), and
	what ProgressionSystem reports back after routing it (ProgressionOutcome).

	    PlayerKilled (GameplayEvents, PlayerDeathSystem)
	      -> RewardSystem       what is this event eligible for          -> RewardManifest
	      -> ProgressionSystem  is it legitimate, and who owns each part -> ProgressionOutcome
	      -> the owners         how much, and the write (Meridian, Bloodline, Bounty)

	Deliberately NOT a section of Shared/Types.lua, for the reason DamageTypes.lua gives for itself: a
	domain whose types live in the shared hub cannot be moved or removed without unpicking the hub.
	It sits under Shared/ only because that is where domain type modules live; nothing here crosses the
	network today -- every one of these values is server-internal by construction (the spine has no
	remote), and a client that required this module would learn only field names.

	Everything is data. The Players it carries are carried, not interpreted.

	Does not own: any policy (RewardSystem's taxonomy, ProgressionSystem's legitimacy gate and routes),
	any magnitude (MeridianSystem), or the PlayerKilled payload itself (GameplayEvents).
]]

local ProgressionTypes = {}

-- Where a reward came from. One source today, and it is the only one the game's first pillar allows
-- to grant progression at all: a real, attributed PvP kill. A new source (a boss, a quest) is a new
-- member here AND a deliberate entry in ProgressionSystem's legitimacy table -- the type alone grants
-- nothing.
export type RewardSource = "PvPKill"

-- One kind of reward a manifest may carry. Each is owned, computed and applied by exactly one System;
-- the manifest only says the event is eligible for it. Absorb, loot, currencies and faction standing
-- are not here because no System owns them yet -- adding a kind without an owner would be a component
-- ProgressionSystem can only refuse.
--   MeridianXP      MeridianSystem.AwardKillXP -- every counted kill.
--   BloodlineStage  BloodlineSystem.CountKill -- a weighted kill toward the killer's next stage.
--   BountyClaim     BountySystem.PayClaim -- the victim's mark, if they carried one.
-- A component whose owner has nothing to do for this kill (no bloodline, no mark) reports false in
-- ProgressionOutcome.Granted; that is a normal answer, not a fault.
export type RewardComponentKind = "MeridianXP" | "BloodlineStage" | "BountyClaim"

-- The confirmed fact a manifest is composed from. Frozen by RewardSystem.
export type ProgressionEvent = {
	Source: RewardSource,
	-- PlayerKilled's deathId -- the fact's identity, and what makes a replay detectable.
	EventId: number,
	-- The player being rewarded, and the player whose death earned it. Always two different Players.
	Recipient: Player,
	Victim: Player,
}

-- What RewardSystem hands ProgressionSystem. Frozen, Components included: nothing downstream can add a
-- reward to a manifest, only decline one.
export type RewardManifest = {
	Event: ProgressionEvent,
	Components: { RewardComponentKind },
}

-- Why ProgressionSystem declined a manifest outright. Per-component failures are reported in Granted,
-- not here.
-- RepeatVictim: the repeat-victim rule weighted this kill to zero (ProgressionConstants.RepeatVictim).
export type ProgressionRefusal = "IllegitimateSource" | "SelfReward" | "NoComponents" | "RepeatVictim"

-- What routing a manifest did. Granted maps each component the manifest carried to whether its owner
-- actually applied it -- false covers both "no route" and "the owner refused" (an unloaded profile,
-- say), which the owner has already logged in its own terms.
export type ProgressionOutcome = {
	Accepted: boolean,
	Refusal: ProgressionRefusal?,
	-- How much of the event counted as legitimate progression, 0..1 -- 1 for an honest kill, less for
	-- a repeat of the same victim, 0 when refused. Handed to every owner, which scales its OWN amount.
	Weight: number,
	Granted: { [RewardComponentKind]: boolean },
}

return ProgressionTypes
