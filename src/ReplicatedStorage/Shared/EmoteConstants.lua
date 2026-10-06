--!strict
--[[
	EmoteConstants.lua

	Owns: every Emote-system tunable number, lookup table, and Remote name -- deliberately its own
	dedicated Shared module rather than a Constants.Emote sub-table, the same reasoning QiConstants.
	lua's own header gives for Qi: Emote content (per-emote definitions live alongside this in
	Shared/Emotes/, unlock pools, loadout sizing) is a growing data surface a live game keeps adding
	to for years, and folding it into Constants.lua would only grow that file's already-flagged
	"holds content, not tunables" problem (docs/architecture/2026-08-audit.md section 5) further.

	Does not own: any individual emote's own authored data (Id/DisplayName/AnimationId/Category/
	Unlock/...) -- that's Shared/Emotes/EmoteDefinitions.lua. This file owns only the numbers/lookups
	every consumer of that data needs alongside it (loadout sizing, roll pools, remote names,
	animation fade timing, network budget, and the two runtime allow-lists -- Categories/UnlockTypes
	-- Shared/Emotes/EmoteRegistry.lua's Validate checks an EmoteDefinition against, since Types.
	EmoteCategory/EmoteUnlockType are compile-time-only unions with no runtime membership check of
	their own, the same "a Types.lua union needs a matching runtime array somewhere" gap Constants.
	CharacterCreation.RaceIds already fills for Types.RaceId).
]]

local EmoteConstants = {}

-- Number of slots in a player's emoteLoadout (Types.PlayerProfile.emoteLoadout) -- the radial wheel
-- UI (a later session) is required to read this length rather than hardcoding 8 anywhere, so
-- retuning the wheel's size is a single-number change here, not a UI + data migration.
EmoteConstants.LoadoutSize = 8

-- Server-owned RemoteEvent names (Server/Systems/EmoteSystem.lua creates every one of these via
-- NetworkBridge.CreateRemoteEvent at boot) -- same per-subsystem RemoteNames sub-table convention as
-- Constants.Meridian/Constants.Rivalry/Constants.Qi, and the same "Emote_" prefix style those use
-- ("Combat_", "Progression_", ...).
EmoteConstants.RemoteNames = {
	-- Client -> server. Payload: emoteId (string). See EmoteSystem.lua's handleRequestPlay for the
	-- full validation order.
	RequestPlay = "Emote_RequestPlay",
	-- Server -> the ACTING player's own client only (never FireAllClients) -- Roblox replicates the
	-- played AnimationTrack to every OTHER client for free the instant that one client's own
	-- Animator plays it, the same contract Combat_AttackStarted already relies on; see
	-- Client/FX/EmoteAnimator.lua's own header. Payload: Types.EmoteStartedPayload/
	-- EmoteStoppedPayload.
	Started = "Emote_Started",
	Stopped = "Emote_Stopped",
	-- Client -> server. Payload: emoteId (string). Fired by Client/Emotes/EmoteController.lua the
	-- moment the LOCAL AnimationTrack for a one-shot emote reaches its own natural end -- the client
	-- is the only side that knows a clip's real length (AnimationTrack.Length exists nowhere on the
	-- server), so it is the only side that can tell the server when the animation is actually over.
	-- See EmoteSystem.lua's own STOP SCHEDULING header for why this, and not the authored Duration,
	-- is the primary stop for a clip-bearing emote.
	NotifyFinished = "Emote_NotifyFinished",
	-- Client -> server. No payload. The player asking to end their OWN current emote, whatever it is
	-- -- the only way out of a Loop emote (Sit, Dance) that exists, since a loop has no EndsAt of its
	-- own and no track whose end could be reported through NotifyFinished.
	--
	-- WITHOUT THIS A SEATED PLAYER IS STUCK. Sit and Dance are both Loop AND MovementLocked, so
	-- EmoteSystem zeroes their WalkSpeed (via AttributeConstants.EmoteMovementLocked, which
	-- Server/Systems/RunSystem.lua's resolver reads at its top tier) and then nothing in the system
	-- ever clears it: the heartbeat expiry only fires for a non-Loop
	-- emote's EndsAt, and the InCombat interruption needs an attacker. Dying was the only exit.
	--
	-- Deliberately NOT validated against WHICH emote is running -- unlike NotifyFinished (a report
	-- about a specific track, which must match the active emote or be discarded), this is a command
	-- about the player themselves, and the worst a client can do by firing it is end its own pose.
	RequestStop = "Emote_RequestStop",
	-- Client -> server. Payload: slotIndex (number, 1-based), emoteId (string).
	RequestSetLoadoutSlot = "Emote_RequestSetLoadoutSlot",
	-- Server -> owning client only, fired once on join and again on every successful mutation.
	-- Payload: Types.EmoteLoadoutUpdatePayload / Types.EmoteUnlockedUpdatePayload.
	LoadoutUpdated = "Emote_LoadoutUpdated",
	UnlockedUpdated = "Emote_UnlockedUpdated",
}

-- Per-player-per-second call budget for EmoteSystem's two client-originated remotes (RequestPlay/
-- RequestSetLoadoutSlot) -- EACH gets its OWN independent RateLimiter.New() instance built from this
-- same number (CombatSystem.lua's attackRateLimiter/defensiveRateLimiter/utilityRateLimiter
-- precedent: independent buckets from one shared constant, so a burst against one action can never
-- starve the other), rather than sharing Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer --
-- an emote press is a cosmetic/social action, not combat-critical, and earns its own named budget
-- the same reasoning Constants.Rivalry.QueryMaxCallsPerSecond already documents for a different
-- non-combat-critical remote pair.
EmoteConstants.MaxRequestsPerSecondPerPlayer = 4

-- Hard ceiling on how long a CLIP-BEARING one-shot emote may stay active server-side before
-- EmoteSystem force-stops it regardless of what the client reported. NOT a gameplay number and NOT a
-- per-emote duration -- it is purely the safety valve behind Emote_NotifyFinished (see that remote's
-- own header): the client owns the real stop because only it can read AnimationTrack.Length, so the
-- server needs SOME bound in case that notification never arrives (a client that disconnects
-- mid-emote, an exploiter who simply never fires it, a track that stops being reported).
--
-- Deliberately far above any plausible authored clip rather than derived from the emote's own
-- authored Duration: deriving it from Duration would reintroduce the exact truncation bug this whole
-- mechanism exists to remove (a stale 2-second Duration on a real 5-second clip would still guillotine
-- the animation, just 2 seconds later). The only thing a player can do by withholding the
-- notification is hold their OWN cosmetic pose (and, for a MovementLocked emote, their own zeroed
-- WalkSpeed) -- self-inflicted, interruptible by damage/combat/death through the same heartbeat guard
-- every other emote uses, and bounded here.
EmoteConstants.MaxOneShotSeconds = 15

-- Client/FX/EmoteAnimator.lua's fade timing -- mirrors Constants.FX.Animation.Combat/Flight's own
-- OneShot/Loop split: a one-shot gesture (Wave, Bow, ...) fades in snappy; a looping sustained pose
-- (Sit, Dance) crossfades a little softer, since it's a held state, not a discrete beat.
EmoteConstants.AnimationFade = {
	OneShotFadeSeconds = 0.1,
	LoopFadeSeconds = 0.25,
	-- Applied when an emote is cut short (a new RequestPlay superseding it, death, the heartbeat
	-- interruption guard, or a duration-expiry stop) rather than fading in -- softer than either
	-- play-side fade above so an interrupted emote melts toward idle instead of popping, the same
	-- reasoning Constants.Combat.Prediction.RollbackFadeSeconds documents for a mispredicted combat
	-- swing.
	StopFadeSeconds = 0.15,
}

-- The runtime allow-list Shared/Emotes/EmoteRegistry.lua's Validate checks Types.EmoteCategory
-- against -- see this file's own header for why a compile-time union alone can't gate an untrusted
-- table at runtime.
EmoteConstants.Categories = { "Social", "Greeting", "Reaction", "Dance", "Sitting", "Rare" }

-- Same reasoning as Categories above, for Types.EmoteUnlockType.
EmoteConstants.UnlockTypes = { "Default", "Achievement", "Roll", "Quest", "Event", "Purchase" }

-- A brand-new profile's starting emoteLoadout (PlayerDataSystem.CreateDefaultProfile) -- the 8
-- starter Default-unlock emotes (Shared/Emotes/EmoteDefinitions.lua), in the order a new player
-- should see them on the wheel. Deliberately a plain literal, not "every Default emote in whatever
-- order pairs() happens to iterate" -- loadout order is a real UX choice, and pairs() over a dict
-- has no defined order to begin with.
EmoteConstants.DefaultLoadout = { "Wave", "Bow", "Laugh", "Taunt", "Sit", "Cheer", "Point", "Dance" }

-- Named unlock pools -- EmoteUnlockService.RollEmote reads these by poolId. Each entry is a list of
-- EmoteIds a roll draws uniformly from, excluding whatever the rolling player already owns. Kept
-- here (not alongside the emote's own data in EmoteDefinitions.lua) since a pool is a GROUPING of
-- emotes, not a property of any single one -- an emote can be named in more than one pool without
-- EmoteDefinitions.lua itself needing to know which pools include it.
EmoteConstants.RollPools = {
	RareEmotes = { "CelestialBow" },
} :: { [string]: { string } }

return EmoteConstants
