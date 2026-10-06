--!strict
--[[
	Types.lua

	Owns: every shared type definition used across server Systems, client modules, and the
	network boundary. Does not own runtime values -- see Constants.lua for tunables and
	NetworkBridge.lua for remote payload wiring built on top of these types.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- LogTypes.lua is a leaf module (no requires of its own), so pulling its types in here cannot create a
-- require cycle. NOT Shared/Logger.lua directly: Logger requires Constants, and Constants
-- requires this very file, so requiring Logger here would close a three-module cycle
-- (Types -> Logger -> Constants -> Types) -- see LogTypes.lua's own header.
local LogTypes = require(ReplicatedStorage.Shared.LogTypes)

local Types = {}

export type Faction = "Celestial" | "Demonic" | "Unbound"

export type Region = "TheVoid" | "TheMedianParadise" | "TheDemonicDisastrousLandscape"

-- 1-9. Tier names/thresholds are a technical-design decision owned by TierSystem, not yet
-- finalized -- see progression-systems.md. Kept numeric until that design lands.
export type Tier = number

-- world-bible.md's four fixed races, named now that CharacterCreationSystem.lua (chargen) needs a
-- closed set to validate a client-submitted race choice against -- supersedes this field's former
-- "stays opaque, no named roster yet" comment. BloodlineId/ArtId stay opaque strings below: unlike
-- races, progression-systems.md's 13 bloodlines and ArtSystem's arts have no fixed, chargen-facing
-- roster yet for anything to validate against.
export type RaceId = "Human" | "Firmborn" | "Rivenkin" | "Hollowborn"
export type BloodlineId = string
export type ArtId = string
-- Same "opaque string, content-driven roster" reasoning as BloodlineId/ArtId above -- see
-- Shared/Emotes/EmoteDefinitions.lua for the actual (open-ended, always-growing) roster this keys
-- into.
export type EmoteId = string

-- The six chargen attributes (Constants.CharacterCreation), a named record rather than a
-- `{ [string]: number }` dict -- every consumer (validation, the Attributes screen, Confirmation's
-- summary) works with exactly these six known fields, never an arbitrary/open set, so a typo'd key
-- is a compile-time error instead of a silently-missing stat. See Constants.CharacterCreation's own
-- header for what each attribute drives.
export type AttributeBlock = {
	Vitality: number,
	Fortitude: number,
	MeridianFlow: number,
	Might: number,
	Pressure: number,
	Fleetness: number,
}

export type PlayerProfile = {
	userId: number,
	faction: Faction?,
	raceId: RaceId?,
	-- In-game character name, chosen at chargen (CharacterCreationSystem.lua) -- distinct from the
	-- Roblox username (Player.Name/DisplayName), not globally unique, no reservation table. nil
	-- exactly when raceId is nil (a player who hasn't been through chargen yet) -- the two fields are
	-- written together in one Transform (CharacterCreationSystem.handleFinalize), never independently.
	displayName: string?,
	-- Chargen attribute allocation (CharacterCreationSystem.lua). nil exactly when raceId is nil, same
	-- "written together, one Transform" contract as displayName above. Additive by construction (a
	-- future Attunement/tier-up points-per-tier screen, explicitly out of scope for chargen itself,
	-- adds to these fields rather than replacing them) -- nothing here assumes attributes are only
	-- ever set once.
	attributes: AttributeBlock?,
	tier: Tier,
	bloodlineIds: { BloodlineId },
	-- Race Traits + Bloodline Abilities plan -- current stage reached per awakened bloodline. A key
	-- present in this map implies the same BloodlineId is present in bloodlineIds (BloodlineSystem.
	-- Awaken writes both in one Transform, never one without the other); the reverse is never true
	-- for a profile written by that path. Race Traits need no equivalent field of their own --
	-- RaceSystem derives eligibility entirely from raceId + TierSystem.GetTier, nothing persisted.
	bloodlineStageProgress: { [BloodlineId]: number },
	-- Bloodline spin (Shared/Bloodline/BloodlineConstants.lua) -- how many REROLLS remain, on top
	-- of the one free roll every player gets during onboarding. Decremented server-side by
	-- BloodlineSystem.Spin and never incremented by anything today: nothing grants more rerolls
	-- yet, which is a deliberate stub rather than an oversight -- there is no currency, shop or
	-- reward path anywhere in this codebase to earn one from (see this file's own note on why
	-- there is no currency). Whatever grants them later increments this field and nothing else.
	--
	-- "Has this player had their free roll yet" is NOT a second flag: it is `#bloodlineIds > 0`,
	-- the same "presence IS the fact" reasoning artMastery uses for unlocked-ness. A player with
	-- no bloodline has never spun.
	bloodlineRerolls: number,
	artMastery: { [ArtId]: number },
	-- Art System (Server/Systems/ArtSystem.lua) -- which art is bound to each of the
	-- ArtConstants.EquipSlotCount hotbar slots. A DICT keyed by slot index, not an ordered array like
	-- emoteLoadout above, and the difference is deliberate: emote slots are filled left to right from
	-- a starter loadout, where art slots are filled one at a time as arts are earned, so slot 4 being
	-- bound while 2 and 3 are empty is the NORMAL early-game state -- an array would have to express
	-- that as a hole, and `#` over a holed array is undefined in Luau.
	--
	-- Only ever written with an art the player has already unlocked (ArtSystem.Equip re-checks
	-- IsUnlocked server-side regardless of what the client sends). An entry can still go stale if an
	-- art is later retired from the registry, which costs exactly a slot that does nothing when
	-- pressed -- ArtSystem.CanUse re-resolves the art at fire time, so a stale slot degrades to
	-- silence, never to a free cast, the same contract emoteLoadout's own header describes.
	equippedArts: { [number]: ArtId },
	corruption: number,
	qiDeviationRisk: number,
	factionStanding: number,
	hasAscended: boolean,
	-- Meridian XP (MeridianSystem.lua) -- the core progression currency, "Tier gates are earned
	-- through Meridian XP from PvP wins" (progression-systems.md). Unlike Qi (QiSystem.lua),
	-- deliberately persisted here: Meridian XP is permanent progression, not a per-session/per-fight
	-- resource that resets on rejoin the way Qi does.
	meridianXp: number,
	-- Emote System (Server/Systems/EmoteUnlockService.lua) -- every EmoteId this player has ever
	-- unlocked, a SET (value always `true`) rather than an array for O(1) HasUnlocked lookups on the
	-- request-play hot path. A brand-new profile starts with every Shared/Emotes/EmoteDefinitions.lua
	-- entry whose Unlock.Type == "Default" already present (PlayerDataSystem.CreateDefaultProfile) --
	-- EmoteUnlockService additionally backfills this set on every profile load so an OLDER save that
	-- predates a newly-authored Default emote still ends up with it, without needing its own
	-- migration entry per new emote.
	unlockedEmoteIds: { [EmoteId]: true },
	-- Emote System (Server/Systems/EmoteSystem.lua) -- an ORDERED array (unlike unlockedEmoteIds
	-- above), one EmoteId per wheel slot. Length is driven by EmoteConstants.LoadoutSize, never
	-- hardcoded elsewhere. RequestSetLoadoutSlot only ever writes an EmoteId the player has already
	-- unlocked (EmoteUnlockService.HasUnlocked), so a stale/locked entry can only appear here through
	-- an edge case outside this pass's scope (EmoteConstants.LoadoutSize shrinking, or an emote being
	-- retired) -- EmoteSystem.handleRequestPlay's own HasUnlocked check is what makes such an entry
	-- unplayable regardless, so a stale slot degrades to "does nothing when pressed," never a way to
	-- play an emote the player doesn't actually own.
	emoteLoadout: { EmoteId },
	-- Blimp Fuel System (Server/Systems/ResourceGatheringSystem.lua mines/collects into this,
	-- Server/Systems/BlimpSystem.lua's depositFuel debits out of it) -- how much coal/water THIS
	-- PLAYER is currently carrying, not yet loaded into any blimp's own tank (that pool is
	-- BlimpTypes.FuelState, and lives on the blimp, never here). A record, not two top-level fields,
	-- so the two always travel and default together -- see CreateDefaultProfile/Migrations[8].
	blimpFuel: { Coal: number, Water: number },
	-- Settings System (Server/Systems/SettingsSystem.lua, Client/Input/KeybindManager.lua) -- see
	-- PlayerSettings' own header below for why this is a SPARSE override map, not a full snapshot.
	settings: PlayerSettings,
}

-- Cross-server ownership claim on one player's DataStore record (PlayerDataSystem.lua's loadProfile/
-- saveProfile) -- guards the "server hop lands inside the other server's autosave window" race
-- (2026-08 performance audit): without this, server A's PlayerRemoving-triggered save and server B's
-- load for the SAME player can overlap, and whichever SetAsync lands last silently wins regardless of
-- which one actually has the more recent data. JobId is game.JobId (globally unique per real Roblox
-- server; empty string in Studio outside a published place, which makes this check ineffective for
-- purely-local Studio testing -- see loadProfile's own header). LockedAt is os.time() (Unix seconds,
-- comparable across different server PROCESSES, unlike os.clock() which is per-process monotonic and
-- meaningless compared across servers) -- read by PlayerDataSystem.IsLockHeldByOther against
-- Constants.PlayerData.LockStaleAfterSeconds so a server that crashed without releasing its lock
-- (never ran PlayerRemoving/BindToClose) doesn't block a rejoin forever.
export type PlayerDataLock = {
	JobId: string,
	LockedAt: number,
}

-- Persisted wrapper around PlayerProfile (PlayerDataSystem.lua, software-architecture.md's
-- "Canonical player data read/write, DataStore integration" ownership row). SchemaVersion is a
-- DataStore-record concern only -- it lets PlayerDataSystem.MigrateRecord detect and upgrade an
-- older on-disk shape before ever handing a live PlayerProfile to another System -- and
-- deliberately does NOT appear on PlayerProfile itself, since every other System's public API
-- already types against the bare in-memory shape and has no reason to know or care what schema
-- version it was loaded from.
--
-- WriteGeneration/Lock are likewise record-level concerns, not part of the versioned PlayerProfile
-- payload -- deliberately NOT threaded through PlayerDataSystem.MigrateRecord/the Migrations table
-- (which only ever transforms raw.Profile, see Migrations[1]/[2]'s own bodies): an older record
-- simply lacks both fields, and every reader already treats a missing WriteGeneration as 0 and a
-- missing Lock as unlocked, the same "a field this file's own decode step doesn't recognize yet just
-- defaults safely" contract DecodeProfile already applies to every PlayerProfile field. WriteGeneration
-- is a monotonic counter bumped on every successful saveProfile -- PlayerDataSystem.ComputeSaveWrite
-- compares the generation this server loaded against whatever is CURRENTLY stored at save time and
-- refuses the write (rather than silently overwriting) if a newer generation already exists, the
-- second, independent line of defense against the same cross-server race Lock above guards against
-- (Lock should prevent this from ever actually triggering in practice; this is the backstop for the
-- rare case a lock went stale while its holder was still legitimately alive).
export type StoredPlayerProfile = {
	SchemaVersion: number,
	Profile: PlayerProfile,
	WriteGeneration: number,
	Lock: PlayerDataLock?,
}

-- Every server System/Manager conforms to this lifecycle so Main.server.lua can boot them
-- uniformly and so no module reaches into another's internals directly (software-architecture.md).
export type SystemModule = {
	Init: () -> (),
}

-- Combat (CombatSystem, software-architecture.md's ownership row; combat-philosophy.md for the
-- Lock-on/Block/Parry/Posture feel these shapes carry state for). Defined here, not locally in
-- CombatSystem.lua, because each of these genuinely crosses a boundary this file's header reserves
-- for shared types: CombatVitalsPayload/CombatFeedbackPayload cross the client/server network
-- boundary over NetworkBridge remotes; CombatSnapshot crosses the CombatSystem-to-future-System
-- module boundary via CombatSystem.GetCombatState. CombatSystem's own internal, mutable
-- per-player state is NOT here -- that never leaves CombatSystem.lua, per software-architecture.md's
-- "no system reaches into another system's internals directly."

-- "GroundSlam" is distinct from "Hit" specifically so it never re-triggers the once-per-swing Hit
-- reaction machinery (damage number, hit-flash, hit-stop, PredictionMirror) a SECOND time for the
-- same landed swing -- see CombatFeedbackPayload.FinisherVariant's own header for what it exists to
-- carry and why the ordinary "Hit" event for that same swing can't carry it itself.
export type CombatFeedbackKind = "Hit" | "Blocked" | "Parried" | "PostureBreak" | "Death" | "Disarmed" | "GroundSlam"

export type CombatVitalsPayload = {
	Health: number,
	MaxHealth: number,
	Posture: number,
	MaxPosture: number,
}

-- Server (QiSystem.lua) -> owning client only, mirrors CombatVitalsPayload's shape for the same
-- reason: a resource bar with a current/max pair. See QiSystem.lua's own header for the
-- immediate-on-Spend/throttled-on-passive-regen replication rule this payload rides on.
export type QiUpdatePayload = {
	Qi: number,
	MaxQi: number,
}

-- Server (MeridianSystem.lua) -> owning client only. A single running total, not a current/max
-- pair -- Meridian XP has no cap the way Qi/Health/Posture do (progression-systems.md: it's the
-- resource TierSystem's tier-up checks read against a threshold, not a per-fight resource that
-- depletes and refills).
export type MeridianXPUpdatePayload = {
	MeridianXP: number,
	-- Set only on a grant, never on the profile-load sync: how much this update added and why
	-- (MeridianSystem.AwardMeridianXP's `reason` -- "PvPKill", "BountyClaim"). What the HUD's "+N" cue
	-- reads, so it can tell a gain from a login without diffing totals across two remotes.
	Gained: number?,
	Reason: string?,
}

-- Server (TierSystem.lua) -> owning client only. Carries the tier's IDENTITY plus the XP window it
-- occupies, deliberately NOT a progress fraction: MeridianXPUpdatePayload above already replicates
-- the running XP total on every grant, so a client holding both can compute its own progress bar
-- fill from two numbers it already has, and that bar moves on every kill instead of only when a tier
-- changes. Sending a precomputed fraction here would mean either a second remote fired per kill or a
-- bar that visibly sticks between promotions.
--
-- This is not a violation of ClientState.lua's "never computed here" rule, and the split is the
-- point: the server stays authoritative over tier IDENTITY (Tier/TierName are persisted profile
-- state, and TierSystem's never-demote rule means they are genuinely not derivable from XP alone),
-- while the fill percentage is pure presentation arithmetic over values the server already sent.
export type TierUpdatePayload = {
	Tier: number,
	TierName: string,
	-- Cumulative XP at which this tier began, and at which the next one begins. TierNextXP is nil at
	-- the top of the ladder -- see TierSystem.GetTierWindow's header on why nil rather than a
	-- repeated or fabricated number.
	TierFloorXP: number,
	TierNextXP: number?,
	-- Set ONLY on a real promotion, nil on the initial post-load sync. A client uses its presence to
	-- tell "this is your tier" apart from "you just earned this" without tracking its own previous
	-- value; a promotion crossing two thresholds at once reports the tier actually left behind, not
	-- Tier minus one (TierSystem.Evaluate's header).
	PreviousTier: number?,
}

-- One row of the Notoriety bounty board (BountySystem.lua). Carries the target's name and UserId,
-- never the Player instance -- a remote can't usefully hand an instance to a client that may not
-- have it, and nothing client-side should hold a reference it could retain past the player leaving.
-- Reward is Meridian XP, the only progression resource a bounty pays (see BountyConstants.lua's
-- header on why there is no currency here).
export type BountyBoardEntry = {
	BountyId: string,
	TargetName: string,
	TargetUserId: number,
	TargetTier: number,
	Streak: number,
	Reward: number,
}

-- Server (BountySystem.lua) -> ALL clients, fired only when the board actually changes. The bounty
-- board is deliberately global information -- the whole point of a Notoriety bounty is that everyone
-- can see who is running away with the server.
export type BountyBoardUpdatePayload = {
	Entries: { BountyBoardEntry },
}

-- Server (BountySystem.lua) -> the marked player ONLY. Sent on being marked, on the reward growing
-- as the streak continues, and once more with Marked = false when the mark ends (claimed, expired,
-- or an unattributed death). Reward/Streak are nil exactly when Marked is false.
export type BountyMarkedPayload = {
	Marked: boolean,
	Reward: number?,
	Streak: number?,
}

-- Art system wire shapes (ArtSystem.lua / ArtTreeManager.lua). An art IS a Move Creation System
-- move that carries a MoveTypes.MoveArtBinding, so these carry only what a catalogue UI needs --
-- never the move's hitbox geometry, timing or animation data, which no client menu has any use for
-- and which would make this payload an order of magnitude larger.
export type ArtCatalogueEntry = {
	-- An art's ArtId is its MoveId; there is no second identity (ArtConstants.lua's header).
	ArtId: ArtId,
	DisplayName: string,
	Node: number,
	QiCost: number,
	RequiredTier: number,
	Prerequisite: ArtId?,
	Unlocked: boolean,
	-- nil when the player can unlock this right now. Otherwise the SAME reason string
	-- ArtSystem.CanUnlock produced server-side, so the UI renders the real gate rather than
	-- re-deriving the rules and risking a drift between what it shows and what the server enforces.
	LockedReason: string?,
}

export type ArtCatalogueTree = {
	TreeId: string,
	DisplayName: string,
	-- nil = open to every player, which is what makes a starting tree possible while FactionManager
	-- is still a stub.
	Faction: Faction?,
	Description: string,
	Arts: { ArtCatalogueEntry },
}

export type ArtCatalogueResult = {
	Success: boolean,
	Reason: string?,
	Trees: { ArtCatalogueTree }?,
}

export type ArtActionResult = {
	Success: boolean,
	Reason: string?,
}

-- Server (ArtSystem.lua) -> owning client only. Mastery doubles as the unlocked set: a key present
-- means unlocked, its value is mastery earned (see ArtSystem.lua's header on why that avoids a
-- second profile field and a schema migration).
export type ArtStatePayload = {
	Mastery: { [ArtId]: number },
	-- Types.PlayerProfile.equippedArts, replicated (this IS that field) -- slot index -> ArtId, sparse
	-- by design. Travels on the SAME payload as Mastery rather than earning a second remote: an
	-- unlock and an equip both change what the Arts panel and the hotbar should show, and splitting
	-- them would let a client render an equipped art it doesn't yet believe is unlocked.
	Equipped: { [number]: ArtId },
	-- What the hotbar needs in order to RENDER each art in Equipped, keyed by ArtId.
	--
	-- Keyed by art rather than by slot on purpose. Equipped is the one authority on which art is in
	-- which slot -- it IS the profile field -- and a second slot-keyed table would be a second answer
	-- to that same question, free to drift from the first the moment one of them is rebuilt and the
	-- other isn't. This one answers a DIFFERENT question ("what does this art look like"), which
	-- Equipped structurally cannot: an art's DisplayName and QiCost live in the move registry, which
	-- is server-side and DataStore-backed, so an ArtId on its own is an identifier the client has no
	-- way to resolve.
	--
	-- It travels here rather than being read off the Arts catalogue because the catalogue is fetched
	-- on panel open (ArtSystem.lua's handleGetCatalogue, and CharacterMenuClient.lua's header on why
	-- that is the right cadence for it). The hotbar has to render an equipped art from the moment the
	-- profile loads, which for a returning player is long before they ever open that panel -- and
	-- without this the slot could only fall back to its empty-slot chrome, which is exactly what it
	-- did until 2026-08-25.
	EquippedInfo: { [ArtId]: ArtDisplayInfo },
}

-- The presentation half of an equipped art -- see ArtStatePayload.EquippedInfo. Deliberately NOT a
-- trimmed ArtCatalogueEntry: every gate field on that type (Node, RequiredTier, Prerequisite,
-- Unlocked, LockedReason) answers "may I have this yet", which is settled by the time an art is in a
-- slot. Reusing it would ship five fields per slot that nothing on the hotbar can act on.
export type ArtDisplayInfo = {
	DisplayName: string,
	QiCost: number,
}

-- Server (CharacterSheetSystem.lua) -> owning client only. The identity and standing half of a
-- PlayerProfile -- deliberately ONLY the fields no other System already replicates. Tier/TierName
-- come over Progression_TierUpdated, Meridian XP over Progression_MeridianXPUpdated, Qi over
-- Progression_QiUpdated, art mastery over Art_StateUpdated; restating any of those here would give
-- the client two sources for one fact that update on different schedules (tier moves on every kill,
-- this sheet only on a profile-level change), and the staler one would win whenever it happened to
-- arrive last.
--
-- Every field is nullable exactly where PlayerProfile's own is: DisplayName/RaceId/Attributes are
-- nil together for a player who hasn't been through chargen, and Faction is nil while FactionManager
-- remains a stub.
export type CharacterSheetPayload = {
	DisplayName: string?,
	RaceId: RaceId?,
	Faction: Faction?,
	Attributes: AttributeBlock?,
	BloodlineIds: { BloodlineId },
	-- Types.PlayerProfile.bloodlineStageProgress, replicated (this IS that field) -- see that field's
	-- own header for the "a key here implies the matching id is in BloodlineIds" contract.
	BloodlineStageProgress: { [BloodlineId]: number },
	-- Types.PlayerProfile.bloodlineRerolls, replicated (this IS that field) -- read by the Character
	-- menu's own reroll control so the count on screen is the profile's, never a client tally that
	-- could drift from what the server would actually charge.
	BloodlineRerolls: number,
	Corruption: number,
	QiDeviationRisk: number,
	FactionStanding: number,
	HasAscended: boolean,
}

export type CombatFeedbackPayload = {
	Kind: CombatFeedbackKind,
	AttackerUserId: number?,
	TargetUserId: number?,
	-- Authoritative world position of the target at the moment of resolution. Optional and
	-- additive -- existing player-vs-player feedback doesn't set it (CombatClient.lua already
	-- resolves position from TargetUserId for those). Populated for targets that have no
	-- TargetUserId to resolve from, e.g. a training dummy, which is not a Player.
	TargetPosition: Vector3?,
	DamageAmount: number?,
	PostureAmount: number?,
	IsHeavy: boolean?,
	-- The landing attack's DebugName (e.g. "Basic2"), set only for Kind == "Hit"/"Blocked" --
	-- lets the DEFENDER's own client pick a matching hit-reaction animation (CombatAnimator.
	-- PlayHitReaction reuses the same trailing-digit stage extraction PlaySwing already uses for
	-- the attacker's own swing animation). Not consumed for any gameplay/hit decision.
	AttackDebugName: string?,
	-- True only for Kind == "Parried" when the parried hit was a CONTINUATION hit against an already-
	-- tracked air-combo target (never the opening DashPunch itself, which stays a plain punish with no
	-- launch -- see AirCombo.SwitchPriority's own header, Server/Combat/AirCombo.lua, for the full
	-- mechanic this flags): the parrier (TargetUserId) seizes attacker priority and starts juggling
	-- whoever they just parried (AttackerUserId), who becomes the new held victim, with a guaranteed
	-- extra Constants.Combat.AirCombo.ParryHoldExtensionSeconds added to the hold. Additive/read-only,
	-- like BlockStartedPayload's own ParryWindowOpened -- consumed client-side by
	-- PredictionMirror.OnMyParrySeizedAirComboPriority (the new attacker's own mirrored air-combo
	-- window) and OnMyAttackParried's own priority-loss clear (the old attacker's) -- see
	-- CombatClient.lua's Parried feedback handler.
	AirComboPriorityShift: boolean?,
	-- Non-nil in two cases, both meaning "watch TargetUserId for a ground-impact payoff"
	-- (Client/FX/SlamImpactVFX.lua):
	--   - Kind == "Hit", when the landing attack actually was a finisher AND its knockback actually
	--     applied (i.e. the same conditions HitResolution.ApplyFinisherPhysics/CombatSystem.lua's own
	--     finisher block already gate on: not blocked, and the target survived the hit -- a lethal
	--     finisher never launches, see ApplyFinisherPhysics's own "Health <= 0" guard). Read-only echo
	--     of the same already-server-authoritative variant AttackStartedPayload.FinisherVariant
	--     carries at throw time, just threaded onto the RESOLVED hit instead. Covers the M1 combo's
	--     own Downslam/Uppercut and the standalone AirSlam attack (always "Downslam").
	--   - Kind == "GroundSlam", sent by AirCombo.lua's own MaxHits slam finisher (always "Downslam")
	--     via a SECOND, separate event -- the landed swing's own "Hit" event was already sent before
	--     AirCombo.Apply ever runs (reaching that code path at all requires the swing's own
	--     finisherVariant to be nil), so it structurally cannot carry this. See AirComboTarget.
	--     onGroundSlam's own header (in the since-deleted CombatTypes.lua) for the full mechanism.
	-- Not consumed for any gameplay/hit decision -- purely presentation, like AirComboPriorityShift
	-- above.
	FinisherVariant: FinisherVariant?,
	-- Set only alongside FinisherVariant == "Downslam" (both origins above). True when
	-- RagdollController.SlamToGround's own clearance math (Constants.Combat.Ragdoll.
	-- SlamImmediateImpactDropStuds) determined the target had essentially no room to fall -- the
	-- common "already standing on the ground" case. Client/FX/SlamImpactVFX.BeginWatch uses this to
	-- skip its own fall-then-arrest velocity poll entirely and fire the impact directly instead: that
	-- poll is Heartbeat-rate (~60Hz) over REPLICATED physics state, and a clamped-to-near-zero slam can
	-- fall and fully arrest within a single physics step -- often faster than the poll can sample it,
	-- sometimes faster than the network even sends the transient velocity at all. The server already
	-- knows definitively via this exact calculation, so it says so instead of leaving the client to
	-- guess at something it may structurally be unable to observe. False (or nil) means a genuine,
	-- observable fall -- the existing poll-based detection, which already works reliably for that case.
	ImmediateGroundImpact: boolean?,
}

-- Which weapon a player currently fights with -- ONE at a time, always. The id is the Name of a
-- model in Workspace.Weapons (Shared/Combat/WeaponRoster.lua reads that folder and is the authority
-- on which ids exist); a player picks weapons up into an inventory and draws one at a time --
-- Server/Combat/Weapon/WeaponInventorySystem.lua.
--
-- AN OPEN STRING, deliberately, and this used to be the closed union "Primary" | "Secondary" -- back
-- when a "weapon" meant one of two hardcoded move sets rather than a real, named, artist-built object
-- a player equips. The roster is discovered from the DataModel at runtime, so the set of valid ids is
-- not knowable here at all: a new sword is a model dropped in a folder, not an edit to this line.
-- Nothing validates a WeaponId by its type any more -- WeaponRoster.Has is the check, and
-- SwingSequencer.SetWeapon already refuses an id the roster doesn't know.
export type WeaponId = string

-- Sent to the attacking player only, the moment CombatSystem accepts their attack request (after
-- every validation and cooldown/commitment commit -- never optimistic). Carries just enough
-- timing/identity for the client-side animation/FX layer (Client/FX/CombatAnimator.lua) to sync a
-- swing's telegraph and active window to what the server actually scheduled -- not damage-relevant,
-- and CombatClient.lua does not use it for any hit/damage decision. WeaponId is additive (which
-- weapon's stage threw this swing), also not consumed for any gameplay decision. FinisherVariant is
-- non-nil only when this throw is the M1 combo's 4th hit -- already decided server-side at throw
-- time (HitResolution.SelectFinisherVariant), included here purely so CombatAnimator can pick the
-- Uppercut animation over a routine swing; it is NOT how the server decides the finisher's actual
-- knockback (that's threaded through the hit-resolution pipeline separately, this is a read-only
-- echo of the same already-server-authoritative decision).
export type AttackStartedPayload = {
	IsHeavy: boolean,
	DebugName: string,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	-- The thrown stage's own Cooldown (Constants' per-stage value, echoed so PredictionMirror can
	-- mirror basicAttackReadyAt/heavyAttackReadyAt without a client-side reverse lookup of
	-- WeaponId+DebugName back into the Constants stage tables). Additive and read-only like the rest
	-- of this payload -- the server's own cooldown commit in commitAndThrowAttack is the authority.
	CooldownSeconds: number?,
	WeaponId: WeaponId?,
	FinisherVariant: FinisherVariant?,
	-- Additive, both nil for every weapon-stage/standalone throw AND for a CombatSystem.
	-- ThrowCustomMove throw (see Animations below, which now owns that case). Still set by the ONE
	-- remaining caller that hasn't moved onto Animations: CombatSystem's Object Stun follow-up throw
	-- (scheduleObjectStunFollowUp), whose own single AnimationId field has no multi-clip timeline
	-- counterpart to project through -- see CombatAnimator.PlayExplicitAnimation, which this pair of
	-- fields lets the client play directly instead of inferring a clip from DebugName's trailing
	-- digit. AnimationTrackName is a stable Animator track key, distinct from AnimationId (the
	-- rbxassetid:// itself) so PlayExplicitAnimation can cache and reuse one loaded AnimationTrack
	-- rather than reloading it every throw.
	AnimationId: string?,
	AnimationTrackName: string?,
}

-- Sent to the acting player only, the moment CombatSystem accepts a Dash (after every validation
-- and the commitment/cooldown commit -- never optimistic). The movement counterpart of
-- AttackStartedPayload: carries just enough for the animation/FX layer (Client/FX/
-- CombatAnimator.lua) to time a dash-step to the server-scheduled window. Not damage-relevant and
-- not consumed for any gameplay decision. DurationSeconds is the committed action window (the
-- attackEndsAt lock this action set) -- Sprint is deliberately absent from this payload entirely --
-- it's a sustained WalkSpeed state reflected by Roblox's default run cycle, not a one-shot action
-- needing a synced animation cue.
export type MovementPerformedPayload = {
	DurationSeconds: number,
	-- The Dash cooldown the deleted Movement.ApplyDash committed (Constants.Combat.
	-- DashCooldownSeconds normally, DashBackCooldownSeconds for a backward dash) -- echoed so
	-- PredictionMirror.OnMovementPerformed can mirror the REAL cooldown rather than always assuming
	-- the plain constant regardless of direction. Additive and read-only like AttackStartedPayload's
	-- own CooldownSeconds field, same reasoning. Optional so a nil falls back to the old plain-
	-- constant behavior (defensive, should always be sent by the current server).
	CooldownSeconds: number?,
}

-- Sent to the acting player only, the moment CombatSystem accepts a Slide (after every validation,
-- including the Slide-specific sprinting/moving preconditions -- see CombatSystem.lua's
-- handleSlideRequest). Kept as its OWN payload/remote rather than reusing MovementPerformedPayload:
-- that one is already disambiguated between plain-Dash and DashPunch by comparing its
-- DurationSeconds against a known constant (PredictionMirror.OnMovementPerformed) -- stacking a
-- third meaning onto the same numeric-comparison trick would only compound an already-fragile
-- pattern, and Slide has its own real precondition (state.sprinting) Dash doesn't, which is cleaner
-- to confirm through a dedicated echo.
export type SlidePerformedPayload = {
	DurationSeconds: number,
}

-- SUPERSEDED, AND ORPHANED SINCE THE COMBAT TEARDOWN. Nothing produces or consumes this: its writer
-- (CombatSystem.lua's handleBlockStart) and its reader (CombatAnimator's parry flash) are both
-- deleted, and the constant its second field mirrored (Constants.Combat.ParryWindowSeconds) has been
-- retired with the rest of that system's parry config.
--
-- The replacement is Shared/Defense/DefenseConstants.Network.RemoteNames.StateChanged, which carries
-- the live DefenseState and guard rather than a one-shot "did a window open" boolean -- and the
-- window length is no longer a number anyone sends, because it now comes from markers authored on
-- the animation asset (Shared/Defense/ParryWindows.lua).
--
-- Kept rather than deleted only because it is one member of a dead FAMILY (AttackStartedPayload/
-- MovementPerformedPayload/SlidePerformedPayload are equally orphaned), and retiring one of four
-- would leave the set less coherent than it is now. They should go together, with whatever rebuilds
-- the attack layer.
export type BlockStartedPayload = {
	ParryWindowOpened: boolean,
	ParryWindowSeconds: number,
}

-- Which client-predictable request a Combat_ActionRejected event refers to -- six of these seven
-- actions are the ones CombatClient plays optimistic local feedback for at press time (Basic/Heavy
-- share one prediction slot, "Swing" -- see Constants.Combat.Prediction), matching the prediction/
-- feedback the client recorded at press time so it knows what to roll back. Sprint's entry is the
-- visual-only kind: CombatSystem.lua's handleSprintStart plays no PredictionMirror slot (WalkSpeed's
-- own server-authoritative gate is what actually decides whether sprinting takes effect), but the
-- client still optimistically plays a running animation/VFX/FOV zoom on keydown, so a genuine
-- reject (e.g. Ragdolled) still needs a rollback signal the same as every other predicted action --
-- see CombatClient's Combat_ActionRejected handler. "CustomMove" is the odd one out -- the admin-only
-- hotbar live-fire request (CombatSystem.lua's handleFireHotbarMoveRequest) has no client-side
-- prediction at all (the swing only ever plays off the server-confirmed Combat_AttackStarted echo,
-- same as MoveEditorSystem.TestFireMove), so there is nothing to roll back -- this entry exists
-- purely so a genuine reject (NotAuthorized/CooldownActive/MoveNotFound/...) reaches the requesting
-- admin at all instead of being swallowed silently, reusing this existing channel rather than
-- inventing a second one.
export type RejectedActionKind = "Basic" | "Heavy" | "Dash" | "BlockStart" | "Slide" | "Sprint" | "CustomMove"

-- Sent to the acting player only, when a Basic/Heavy/Dash/BlockStart/Slide/Sprint/CustomMove request
-- is genuinely rejected -- the rollback counterpart of the AttackStartedPayload/
-- MovementPerformedPayload/BlockStartedPayload/SlidePerformedPayload confirm echoes (Sprint has no
-- confirm echo of its own -- see RemoteNames.MovementPerformed's header -- so its rollback is the
-- ONLY server->client signal tied to a SprintStart request at all; CustomMove is the same way, see
-- RejectedActionKind's own header). NEVER fired for the too-early-but-buffered attack pseudo-reject
-- (the buffered press still produces its confirm echo when it flushes) and never for Stop actions
-- (always honored). Reason is the same reject-reason string logRejected records server-side
-- ("Stunned", "DashCooldownActive", ...) -- diagnostic only: the client's rollback needs only Action
-- and logs Reason for debugging. PredictionMirror does NOT parse it -- it self-corrects from the
-- feedback stream plus the OnPredictionPending horizon (see CombatClient's Combat_ActionRejected
-- handler).
export type ActionRejectedPayload = {
	Action: RejectedActionKind,
	Reason: string,
}

-- The knockback variant a clean (non-blocked, non-parried) hit applies, via
-- HitResolution.ApplyFinisherPhysics/Server/Combat/RagdollController.lua. Two distinct sources
-- produce these today:
--   * The M1 combo finisher (Constants.Combat.BasicComboLength, always grounded -- see
--     HitResolution.SelectFinisherVariant's own header) chooses Uppercut when the attacker is
--     holding jump (launch the target up + ragdoll), Normal otherwise (a grounded heavier final
--     hit, no launch).
--   * The standalone AirSlam attack (Constants.Combat.AirSlam, jump + M1 at any time -- see
--     CombatSystem.lua's throwAirSlam) always throws with Downslam (slam the target to the
--     ground) -- the M1 finisher itself can no longer produce Downslam, since an airborne
--     Basic-attack press is intercepted into AirSlam before the finisher logic ever runs.
-- Not a network payload on its own -- it's threaded through the server-side hit pipeline
-- (startAttackSwing/throwAirSlam -> onSwingHitCandidate -> resolveHit*), the same way isHeavy is.
export type FinisherVariant = "Uppercut" | "Downslam" | "Normal"

-- Sent to the owning player only, when the M1 combo's finisher becomes ready or unready (i.e. when 3
-- basic hits have landed in a row, or the combo resets/lapses). The client uses FinisherReady to
-- suppress its own jump on the 4th hit so pressing Space fires the Uppercut instead of jumping -- see
-- CombatSystem.lua's syncFinisherReady and CombatClient.lua. Not damage-relevant and never trusted
-- back: it's a one-way server->client reflection of server-authoritative combo state.
export type ComboStatePayload = {
	FinisherReady: boolean,
}

-- Server -> owning client, on every meaningful change to THEIR OWN engagement -- Server/Combat/
-- Engagement/EngagementSystem.lua is the sole producer. Replaces the old InCombatPayload, which
-- carried only the boolean edge for a HUD badge; the engagement panel needs the opponent and the
-- damage traded alongside it, and two remotes describing one fact is exactly what DamageConstants.
-- Network's own header rules out.
--
-- FIRED ON CHANGE, NEVER PER FRAME: once per resolved exchange (bounded by hit rate) and once on the
-- expiry edge. Everything in between is a client-side decay of SecondsRemaining.
--
-- SecondsRemaining RATHER THAN AN ABSOLUTE DEADLINE, and that is not a style choice. The server
-- stamps this state in os.clock(), whose epoch is process-local -- a client comparing a raw server
-- deadline against its own os.clock() would be wrong by an arbitrary constant, silently and
-- differently on every machine. A duration crossing the wire is epoch-free; the client decays it
-- from the moment of receipt, paying only the one-way latency (single-digit ms against a 5s tag).
export type EngagementPayload = {
	InCombat: boolean,
	SecondsRemaining: number,
	-- The most recent opponent, nil while InCombat is false. UserId is nil for a combatant that is not
	-- a Player, in which case OpponentName falls back to the Model's own name -- an admin-spawned
	-- "DebugDummy" today, and a bot or NPC boss later. See EngagementConstants.DummyTag on which
	-- non-players tag at all (all of them, currently).
	OpponentName: string?,
	OpponentUserId: number?,
	-- Health damage traded during THIS engagement only -- both reset when a lapsed tag starts a fresh
	-- one, so the panel reads as "this fight", not "this session".
	DamageDealt: number,
	DamageTaken: number,
	-- DefenseTypes.OutcomeKind of the last resolved exchange, as a plain string -- Types.lua is a leaf
	-- that requires nothing (see this file's header), so it cannot name that union directly. The same
	-- deliberate two-copies arrangement HitboxAttackShape already documents.
	LastOutcomeKind: string?,
}

-- Read-only projection of a player's combat state for future systems (RewardSystem,
-- RivalrySystem, BountySystem, etc.) via CombatSystem.GetCombatState -- never the live mutable
-- state table itself.
export type CombatSnapshot = {
	Alive: boolean,
	Health: number,
	MaxHealth: number,
	Posture: number,
	MaxPosture: number,
	Blocking: boolean,
	Stunned: boolean,
	PostureBroken: boolean,
	-- True while CombatState.disarmedUntil/BotState.disarmedUntil (see that field's own comment) is
	-- active -- cannot throw a Basic or Heavy attack, but every other action (Block/Parry/Dash/
	-- Sprint/LockOn) still works.
	Disarmed: boolean,
	-- Committed to an action -- see CombatState.attackEndsAt in CombatSystem.lua. Despite the name,
	-- this covers more than a swing's windup/active/recovery: a dash's brief post-window recovery
	-- also sets attackEndsAt (the same shared commitment lock every action already respects), so
	-- this reads true during that recovery too. Cannot attack, block, or dash again while true.
	Attacking: boolean,
	-- True while the player is holding Sprint (CombatState.sprinting) -- intent, not effect: a raised
	-- WalkSpeed only actually applies when combat state permits it (see onHeartbeat). Always false for
	-- a training bot's snapshot; bots have no sprint/dash movement state (BotState) yet, which was the
	-- Reposition no-op the deleted TrainingBotSystem's weights documented as awaiting movement AI.
	Sprinting: boolean,
	-- General-purpose "still fighting" signal (CombatState.inCombatUntil) -- refreshed on throwing/
	-- landing/receiving an attack, blocking, or an air-tech escape, independent of which specific
	-- action caused it. Not itself a legality gate for anything today; a pure read-only signal any
	-- current or future system can consult (unlike Attacking above, which is narrowly scoped to a
	-- single swing/dash's own commitment window).
	InCombat: boolean,
	-- True while CombatState.Vitals.ragdollExpiry is still in the future -- the same field
	-- ACTION_GATES.Ragdoll already gates Basic/Heavy/Dash/etc. on privately (CombatSystem.lua).
	-- Added for EmoteSystem (Server/Systems/EmoteSystem.lua), which needs to reject/interrupt an
	-- emote while a player is physically ragdolled without reaching into CombatState directly.
	Ragdolled: boolean,
	-- True while CombatState.AirCombo.airComboHeldExpiry is still in the future -- the same field
	-- ACTION_GATES.HeldAloft already gates most actions on privately. Same EmoteSystem consumer as
	-- Ragdolled above.
	HeldAloft: boolean,
}

-- One stage of a hand-authored swing -- the shape CombatConstants' weapon stages (Weapons.Baseline
-- .Stages.*) and standalone attacks (DashPunch/DashHit) are written in, and what Shared/Combat/
-- WeaponRoster.lua builds each weapon's own copy of. Read by exactly one thing at runtime:
-- Server/Combat/DefaultMoveRegistry.lua, which projects it into a MoveTypes.MoveDefinition (a Box of this
-- Size) for AttackCatalog. It is authoring data, never mutated after the roster builds it -- the Move
-- Editor tunes a Default move through DefaultMoveRegistry's override layer, not by writing here.
--
-- Deliberately narrow (2026-09-29): the twelve-shape Dimensions bag, Knockback/Slam/Projectile/
-- ObjectStun and ArcDegrees that used to hang off this type were never set by any stage and had no
-- runtime reading them; they went with the Move Editor rebuild.
export type HitboxAttackDefinition = {
	DebugName: string,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	-- The box, in studs (Width, Height, Length). In the shipped BodyBox mode this IS the swing; in Blade
	-- mode the engine sizes the swing off the weapon's own Blade part and this is only what the Move
	-- Editor shows (see CombatConstants.Weapons.SwingHitbox).
	Size: Vector3,
	-- Root-relative (or weapon-relative, in Blade mode) translation of the box's centre. Forward is -Z.
	Offset: CFrame,
	Damage: number,
	PostureDamage: number,
	-- Minimum seconds between two throws of this stage. Authored at or under the stage's own
	-- Windup + Active + Recovery so the swing's end, not the cooldown, is the gate a player feels.
	Cooldown: number,
	-- nil = every target the box contains, once each.
	MaxTargets: number?,
	-- nil (1) unless WeaponRoster's WeaponReach scaled it. Carried onto the engine definition, where it
	-- scales a blade-sized swing (HitboxTypes.AttackDefinition.SizeMultiplier).
	SizeMultiplier: number?,
}

-- Result of DevMenu_SpawnDummy (a RemoteFunction, not a RemoteEvent -- the client needs to know
-- immediately whether its request was accepted, matching a request/response shape better than
-- combat's fire-and-forget remotes). Reason is populated only when Success is false, e.g.
-- "NotAuthorized" -- see DevMenuSystem.lua for the full set of reasons it can return.
export type DevMenuSpawnDummyResult = {
	Success: boolean,
	Reason: string?,
}

-- Client-only input remapping (Client/Input/KeybindManager.lua). Crosses no network boundary --
-- the server never needs to know what key was pressed, only the resulting request remote -- but
-- lives here per this file's own header ("shared types... imported, never redefined locally")
-- since both Constants.lua (Constants.Keybinds.Defaults) and every input-consuming client module
-- (CombatClient.lua, DevMenuClient.lua) need the same shape.
-- "Block" covers both blocking and parrying -- CombatSystem.lua's handleBlockStart treats every
-- accepted press as a timed block (a short parry window opens at press, holding past it is a plain
-- block), so there is no separate "Parry" action to bind. "Dash" fires the neutral-game
-- positioning burst (see CombatSystem.lua's handleDashRequest) -- a forward-resolved Dash can also
-- throw its own DashPunch/DashHit attack (CombatClient.lua's double-tap-W trigger fires the same
-- request with a flag set). "ShiftLock" toggles the custom shift-lock camera mode (Client/Camera/
-- ShiftLockCamera.lua) -- a camera behavior, not a combat request; it's the one action here that
-- never fires a remote. "Sprint" is a held neutral-game movement state (start/stop, like Block).
-- "ToggleWeapon" fires Weapon_ToggleDraw (Server/Combat/Weapon/WeaponInventorySystem.lua) -- draws
-- the selected weapon, or sheathes it if already out, the same fire-and-forget shape as Dash/Sprint.
-- "SelectNextWeapon" fires Weapon_SelectNext, cycling which owned weapon ToggleWeapon will draw. "Slide" fires RequestSlide
-- (CombatSystem.lua's handleSlideRequest) -- chained off Sprint, not a standalone press like Dash:
-- the client only even fires it while its own Sprint key is currently held, and the server
-- independently re-checks CombatState.sprinting regardless of what the client believes. "Feint"
-- fires Attack_Feint (Server/Combat/Attack/AttackRequestSystem.lua's Feint) -- cancels the player's
-- own feintable swing (a Heavy, by default) in the first part of its windup; the server answers with
-- Attack_Cancelled (AttackTypes.AttackCancelledPayload) and the client stops the clip on that.
export type KeybindAction =
	"BasicAttack"
	| "Block"
	| "HeavyAttack"
	| "LockOn"
	| "Dash"
	| "Sprint"
	| "ShiftLock"
	| "DevMenuToggle"
	| "ToggleWeapon"
	| "SelectNextWeapon"
	| "Slide"
	| "Feint"
	-- Opens the player-facing bug report form (Client/UI/Screens/BugReport/init.lua via
	-- Client/BugReport/BugReportClient.lua) -- unlike every action above, this fires no combat
	-- remote and has no server-side legality check of its own; it's a pure client-side panel
	-- toggle, the same "never fires a remote" carve-out this file already documents for
	-- "ShiftLock".
	| "OpenBugReport"
	-- Opens the Move Creation System's editor screen (Client/DevTools/MoveEditor/MoveEditorClient.lua via
	-- Client/UI/Screens/DevTools/MoveEditor/init.lua) -- admin-only, same "client-side convenience toggle,
	-- server re-checks authorization regardless" contract as "DevMenuToggle" above. Fires no combat
	-- remote of its own (opening the screen is free; every actual action inside it goes through
	-- MoveEditorSystem's own gated RemoteFunctions).
	| "OpenMoveEditor"
	-- Opens the Kit Editor screen (Client/DevTools/KitEditor/KitEditorClient.lua via Client/UI/Screens/
	-- KitEditor/init.lua) -- the shared Race Trait / Bloodline stage authoring tool from the Race
	-- Traits + Bloodline Abilities plan, not built yet. Same "client-side convenience toggle,
	-- admin-only, server re-checks regardless" contract as "OpenMoveEditor" immediately above.
	| "OpenKitEditor"
	-- Opens the Live Admin Console (Client/DevTools/LiveConsole/LiveConsoleClient.lua via
	-- Client/UI/Screens/DevTools/LiveConsole/init.lua) -- a bespoke live log stream, not Roblox's own native
	-- Developer Console. Binding this key toggles the panel locally for every client (harmless --
	-- an empty panel pre-authorization); the real gate is server-side, on the
	-- Constants.LiveConsole.RemoteNames.Subscribe RemoteFunction the panel calls the moment it
	-- opens, same "client-side toggle is UX only, server re-checks regardless" contract as
	-- "DevMenuToggle"/"OpenMoveEditor" above.
	--
	-- Used to open Roblox's own native console via StarterGui:SetCore("DevConsoleVisible") instead
	-- (bound from Client/DevTools/DevMenu/DevMenuClient.lua) -- replaced because that panel only ever showed
	-- anything in Studio: Shared/Logger.lua never calls print()/warn() outside RunService:IsStudio()
	-- by design, so on a live server -- the one place a whitelisted admin actually needs this, since
	-- Roblox's own F9 shortcut only binds for accounts with edit access to the place -- the native
	-- console opened empty. The Live Admin Console reads Logger.lua's always-on capture buffer
	-- instead, which works regardless of IsStudio; see that module's own header.
	| "OpenDevConsole"
	-- The 5 hotbar slots (Client/UI/Screens/HUD/init.lua's Panel "Hotbar") -- fire whatever MoveId is
	-- currently bound to that slot (Client/Combat/HotbarBindings.lua, admin-local, no persistence)
	-- via Combat_RequestFireHotbarMove. Unlike every other action above, these have no server-side
	-- gameplay meaning of their own -- CombatSystem.lua's handleFireHotbarMoveRequest re-checks
	-- AdminConfig.AuthorizedUserIds regardless of what a client fires, so a non-admin pressing 1-5
	-- (or a client with nothing bound to that slot) simply does nothing. Named per-slot rather than
	-- one "HotbarSlot" action carrying a slot number -- Types.Keybind has no payload slot, and this
	-- keeps Rebind/Matches working identically to every other single-key action in this union.
	| "HotbarSlot1"
	| "HotbarSlot2"
	| "HotbarSlot3"
	| "HotbarSlot4"
	| "HotbarSlot5"
	-- Held to open the radial emote wheel (Client/Emotes/EmoteWheelClient.lua via Client/UI/Screens/
	-- EmoteWheel/init.lua) -- releasing confirms whichever segment the mouse is nearest to, Escape/
	-- right-click cancels without confirming. Fires no combat remote of its own -- Client/Emotes/
	-- EmoteController.RequestPlay (this feature's Phase 1 client entry point) is what actually sends
	-- the play request once EmoteWheelClient resolves a confirmed segment.
	| "EmoteWheel"
	-- Opens the player-facing Settings panel (Client/UI/Screens/Settings/init.lua via
	-- Client/Settings/SettingsClient.lua) -- same "client-side convenience toggle, fires no combat
	-- remote of its own" shape as "OpenBugReport" above, and unlike "DevMenuToggle"/"OpenMoveEditor"
	-- there is no authorization check at all, admin or otherwise: every player gets this panel.
	| "SettingsToggle"
	-- Opens the player's own character menu (Client/UI/Screens/Menus/init.lua via
	-- Client/CharacterMenu/CharacterMenuClient.lua) -- the sheet/arts/emotes/bounty hub. Same
	-- "client-side panel toggle, fires no combat remote of its own, no authorization gate" shape as
	-- "SettingsToggle" above. This screen used to toggle off a raw UserInputService listener hard-coded
	-- to M, which is why it alone among the panels couldn't be rebound; it routes through
	-- KeybindManager like every other action now.
	| "CharacterMenuToggle"
	-- The combat evade (Client/Parkour/States/Evading.lua via Client/Parkour/
	-- ParkourInput.lua). Fires no combat remote of its own -- the parkour framework reports the action
	-- to Server/Systems/ParkourSystem.lua through its own remote once the evade actually starts, the
	-- same "the input records an intent, the state machine decides whether it becomes an action" split
	-- Client/Parkour/InputBuffer.lua's own header describes. Sprint, Slide and jump are deliberately
	-- NOT new actions here: sprint and slide already have entries above (the parkour framework reads
	-- the same bindings), and jump has never been a rebindable action at all -- see KeybindManager.lua's
	-- IsJumpKeyDown carve-out.
	| "Evade"
	-- The Parkour System's committed long jump (Client/Parkour/States/Leaping.lua via Client/Parkour/
	-- ParkourInput.lua). Used to be a double-tap of jump rather than a KeybindAction of its own -- see
	-- InputBuffer.lua's own header on why that meant it could never be independently rebound. A
	-- dedicated key the same way Evade is, for the same reason: reachable without leaving the movement
	-- keys, and no risk of a stray double-jump accidentally firing it.
	| "Leap"
	-- The Grab layer's follow-up throw (Client/Combat/GrabInputClient.lua via
	-- Server/Combat/Grab/GrabSystem.lua). Fires Grab_Throw only while the local player's own Grabbing
	-- Attribute is true -- see Constants.Attributes.Grabbing's own header -- the same "the client
	-- declines to send what it can already see is illegal" convention ParkourOwnership.OwnsBody's
	-- consumers already use.
	| "GrabThrow"
	-- Board or leave a blimp station (Client/Blimp/BlimpController.lua via Server/Systems/BlimpSystem.lua).
	-- Two consumers, unlike every action above: this module both MATCHES the press (to leave a station)
	-- and writes the bound KeyCode onto each blimp ProximityPrompt's KeyboardKeyCode, so the prompt that
	-- STARTS a mount and the key that ends one can never drift apart. Shares E with "Leap" -- see
	-- Constants.Keybinds.Defaults.Interact for why that is deliberate and what makes it safe.
	| "Interact"

-- Exactly one of KeyCode/UserInputType is populated -- KeyCode for ordinary keyboard keys,
-- UserInputType for inputs with no KeyCode equivalent (Roblox only reports mouse buttons via
-- UserInputType, e.g. Enum.UserInputType.MouseButton1, never a KeyCode).
export type Keybind = {
	KeyCode: Enum.KeyCode?,
	UserInputType: Enum.UserInputType?,
}

-- Which input category a Keybind override applies to (Settings System) -- a keyboard bind and a
-- gamepad bind for the same KeybindAction are independent, see KeybindManager.lua's own header.
export type KeybindDevice = "Keyboard" | "Gamepad"

-- Persisted player preferences (Server/Systems/SettingsSystem.lua, Client/Settings/
-- SettingsClient.lua, Client/Input/KeybindManager.lua). Keybinds/GamepadKeybinds are deliberately
-- SPARSE override maps, not a full snapshot of every KeybindAction -- an action absent from either
-- map simply stays at its Constants.Keybinds.Defaults/GamepadDefaults value, the same "only store
-- what actually differs" contract that keeps a stale/renamed/retired KeybindAction from ever
-- corrupting a saved profile (PlayerDataSystem.DecodeSettings drops any key that isn't a live,
-- rebindable KeybindAction rather than trusting the stored shape). Flat and open to new keys by
-- construction -- a future toggle (e.g. a camera-shake or gore-filter preference) is just one more
-- field here, never a reason to introduce a second settings table.
export type PlayerSettings = {
	Keybinds: { [KeybindAction]: Keybind },
	GamepadKeybinds: { [KeybindAction]: Keybind },
	Autorun: boolean,
	-- Movement/parkour preferences. A nested table rather than eight more flat fields, unlike Autorun
	-- above -- these belong to one feature, are surfaced as one Settings section, and are pushed to
	-- one consumer (Client/Parkour/ParkourController.lua), so grouping them keeps the whole set
	-- addable/removable in one place. That is a different situation from Autorun, which is a single
	-- preference belonging to sprint, and this file's own "a future toggle is just one more field
	-- here" note still governs anything that isn't part of a group like this one.
	Parkour: ParkourSettings,
	-- Visual-comfort / accessibility preferences. A nested group for the same reason Parkour above is
	-- one: these belong to a single concern, are surfaced as a single Settings section, and are pushed
	-- to a single pair of consumers.
	--
	-- Deliberately NOT folded into Parkour, even though ParkourSettings already carries a CameraEffects
	-- toggle. That field gates Client/Parkour/ParkourCamera.lua specifically -- speed zoom, slide
	-- framing, wall-run lean, landing dips -- and switching parkour itself off is a reasonable thing to
	-- want to do without also giving up on combat being readable, or vice versa. A player who gets
	-- motion sick is not asking about parkour; they are asking about the camera, everywhere. Keeping
	-- this its own group is also what makes it the obvious home for every accessibility toggle added
	-- after this one, rather than each finding a different existing group to hide in.
	Comfort: ComfortSettings,
	-- Gamepad device preferences. A nested group for the same reason Parkour and Comfort above are:
	-- one concern, one Settings section (the Controller tab), one consumer
	-- (Client/Input/Analog.lua, through Client/Settings/SettingsClient.lua).
	--
	-- DELIBERATELY NOT FOLDED INTO Comfort, even though look sensitivity and invert-Y are the kind of
	-- thing a player adjusts for comfort. Comfort is the ACCESSIBILITY group -- things that hurt to
	-- look at, where the answer is "turn the effect off" and the default is always on. Stick
	-- sensitivity is a DEVICE preference: it has no correct default, every controller player expects
	-- to set it, and it does nothing at all for the keyboard players Comfort's toggles all serve
	-- equally. Putting it in Comfort would make that section mean two different things at once.
	Gamepad: GamepadSettings,
	-- Interface preferences -- a nested group for the same reason Parkour/Comfort/Gamepad above are:
	-- one concern, one Settings section, one consumer (Client/UI/init.lua, which owns the single
	-- UIScale this drives). NOT Comfort: Comfort is specifically the "this hurts to look at, default
	-- always on" accessibility group, where UI size has no such default and is a legibility/preference
	-- knob every player might reach for regardless of any accessibility need.
	UI: UISettings,
}

-- Gamepad device preferences (Server/Systems/SettingsSystem.lua persists them,
-- Client/Settings/SettingsClient.lua pushes them into Client/Input/Analog.lua). These configure how
-- the STICKS are read; which BUTTON does what is GamepadKeybinds above, and the two are independent.
--
-- Every default here mirrors Analog.lua's own DEFAULT_CONFIG rather than stating a second opinion --
-- the same rule ParkourSettings follows against ParkourConstants, and for the same reason: retuning
-- what the game does out of the box stays a one-file change.
export type GamepadSettings = {
	-- Multiplier on the RIGHT stick only. The left stick has no sensitivity knob and should not grow
	-- one: it feeds Humanoid.MoveDirection, where the magnitude IS the walk/run request, so scaling it
	-- would silently retune movement speed rather than aim feel.
	LookSensitivity: number,
	-- Radial, not per-axis -- see Analog.lua's header for why per-axis makes diagonals unreachable.
	-- Split into two knobs because the two sticks fail differently: a worn left stick that drifts
	-- walks the character on its own, while a worn right stick merely turns the camera, and a player
	-- should not have to blunt their aim to stop drifting.
	MoveDeadzone: number,
	LookDeadzone: number,
	-- Y only. Inverted X is vanishingly rare as a preference and is not offered, which keeps the
	-- Controller tab one row shorter for every player who would never have wanted it.
	InvertLookY: boolean,
	-- For haptics. Persisted and validated, and plumbed into the Controller settings tab
	-- (Analog.lua, ControllerTab.lua) as a user-facing toggle -- but no rumble/motor call reads it
	-- yet, so today it is a stored preference with no effect. Update this comment when one lands.
	Vibration: boolean,
}

-- Camera-comfort preferences (Server/Systems/SettingsSystem.lua persists them,
-- Client/Settings/SettingsClient.lua applies them). Both default to true -- the game ships with its
-- effects on, and this is an opt-OUT for players who need one, never a feature gated behind a setting
-- most players will never open.
--
-- These are the two camera effects with no player-facing switch of any kind before this: combat hit
-- shake and the FOV punches that ride along with it. Parkour's own camera work was already opt-out
-- via ParkourSettings.CameraEffects, so a player sensitive to camera motion could disable every
-- traversal effect in the game and still be shaken by every hit they took, with nothing in the menu
-- to explain why or turn it off.
export type ComfortSettings = {
	-- Client/FX/CameraShake.lua -- the rotational shake played on hits, parries and posture breaks.
	-- Off means the shake is never applied; it does not mean the events stop firing, so nothing about
	-- hit registration, feedback text or audio changes.
	CameraShake: boolean,
	-- Client/FX/FOVOffset.lua's Punch path -- the short field-of-view kicks layered onto impacts.
	-- Continuous FOV slots (the run's speed zoom) are NOT affected: those are a legible readout of how
	-- fast the player is going, they ease rather than snap, and they are the part of the FOV system
	-- that is information rather than punctuation.
	FieldOfViewEffects: boolean,
	-- Client/Camera/BlimpCamera.lua -- the roll, sway and pitch the view takes on while riding a blimp.
	-- Off does NOT flatten that camera entirely: the POSITIONAL channels (the pull-back with speed, the
	-- surge under acceleration, the idle bob) keep running, and only the three ROTATIONAL ones are
	-- driven to zero. That split is the point rather than a half-measure -- rotating the horizon under
	-- somebody is what actually provokes simulator sickness, because it disagrees with their inner ear
	-- about which way is down; sliding the view a couple of studs does not, and taking it away too
	-- would cost a player who needed this toggle every cue that the ship is moving at all.
	--
	-- Named for the VEHICLE rather than for the blimp, deliberately: the second rideable thing this
	-- game grows will want the same answer from the same player, and a "BlimpCamera" field would either
	-- have to be joined by a near-duplicate or quietly start meaning something wider than its name.
	VehicleCameraMotion: boolean,
}

-- Interface preferences (Server/Systems/SettingsSystem.lua persists them, Client/UI/init.lua applies
-- them). One field today -- a global scale on the whole UI tree, driven through a single UIScale on
-- the root ScreenGui rather than each screen sizing itself independently, which is what makes "make
-- the hotbar/menus/everything bigger or smaller" a single number instead of a knob per surface.
export type UISettings = {
	-- Multiplies the built layout, same convention as a Roblox UIScale.Scale: 1 is today's authored
	-- size (every existing player's unchanged default -- see PlayerDataConstants.SchemaVersion's own
	-- migration note), below 1 shrinks, above 1 grows. Bounds enforced server-side
	-- (SettingsConstants.UI.MinScale/MaxScale) so a tampered client value can neither vanish the UI
	-- (0 or negative) nor blow it past the screen.
	Scale: number,
}

-- The player's own movement preferences (Server/Systems/SettingsSystem.lua persists them,
-- Client/Settings/SettingsClient.lua applies them). Every one of these defaults to whatever
-- Shared/Parkour/ParkourConstants.lua currently ships as the default, never to a hardcoded second
-- opinion -- so retuning what the game does out of the box is still a one-file change.
--
-- Enabled is a genuine master switch, not a cosmetic one: switching it off releases the character
-- back to Roblox's stock controller and returns Slide to Client/Combat/CombatClient.lua's own legacy
-- path. That fallback is exercised rather than theoretical, which is why CombatClient asks
-- ParkourController.HandlesSlide() rather than assuming either system owns the key.
--
-- SprintMode lives here rather than beside Autorun because hold-versus-toggle is a movement-feel
-- preference of the same family as the assists, even though the sprint mechanic it configures is
-- owned by CombatClient -- see that module's own sprint section.
export type ParkourSettings = {
	Enabled: boolean,
	CameraEffects: boolean,
	CoyoteTime: boolean,
	JumpBuffer: boolean,
	AutoVault: boolean,
	LedgeAssist: boolean,
	StepAssist: boolean,
	SprintMode: SprintMode,
}

export type SprintMode = "Hold" | "Toggle"

-- Training bots (Server/Combat/TrainingBot/TrainingBotSystem.lua) -- AI-controlled sparring partners,
-- distinct from the static debug dummy (which never acts). Their style and difficulty names, and every
-- tunable behind them, live in Shared/TrainingBot/TrainingBotConstants.lua (StyleName/DifficultyName)
-- rather than here: that module is the one both the server and the Admin Menu's pickers read, and a
-- second copy of the names in this file would drift the first time a style was added.

-- Result of DevMenu_SpawnTrainingBot / DevMenu_DespawnTrainingBots (RemoteFunctions -- same
-- request/response reasoning as DevMenuSpawnDummyResult above). ActiveCount is advisory only, the same
-- way DevMenuDebugDummyStateResult's is: how many bots exist right after the action took effect.
export type DevMenuSpawnBotResult = {
	Success: boolean,
	Reason: string?,
	ActiveCount: number?,
}

-- Result of DevMenu_SetTargetHealth / DevMenu_SetTargetGodmode / DevMenu_SetTargetFlight
-- (RemoteFunctions -- same request/response reasoning as DevMenuSpawnDummyResult above). One
-- shared shape for all three admin actions -- they succeed/fail identically (NotAuthorized/
-- RateLimited/NoTarget/InternalError), nothing about the result differs enough to warrant three
-- near-identical types.
export type DevMenuActionResult = {
	Success: boolean,
	Reason: string?,
}

-- Result of DevMenu_GetHitboxDebug / DevMenu_SetHitboxDebug (Server/Combat/HitboxEngine/
-- HitboxEngine.lua's SetDebugVolumesEnabled/IsDebugVolumesEnabled) -- same request/response
-- reasoning as DevMenuActionResult above, carrying back the current/updated Enabled value so the
-- client can refresh its Toggle without a second round trip.
export type DevMenuHitboxDebugResult = {
	Success: boolean,
	Enabled: boolean?,
	Reason: string?,
}

-- Result of DevMenu_GetDebugDummyState / DevMenu_SetDummyGuard (Server/Systems/DebugDummySystem.lua)
-- -- same "carry back the current/updated value so the client can refresh without a second round
-- trip" reasoning as DevMenuHitboxDebugResult above. GuardEnabled is SERVER-WIDE (applies to every
-- active debug dummy at once, not a per-dummy setting -- see DebugDummySystem.SetGuard's own header),
-- the same "one toggle, no per-instance picker" shape HitboxDebugActive already uses for its own
-- server-wide visualiser. ActiveCount is advisory only (how many dummies currently exist), never a
-- gameplay-relevant number -- purely so the Spawn tab can show "3 active" without a second remote.
export type DevMenuDebugDummyStateResult = {
	Success: boolean,
	GuardEnabled: boolean?,
	ActiveCount: number?,
	Reason: string?,
}

-- Result of DevMenu_RollEmote (Server/Systems/EmoteUnlockService.lua's RollEmote, always against the
-- "RareEmotes" pool -- see DevMenuSystem.handleRollEmote) -- a whitelist-gated one-shot test trigger
-- for the Emote System's roll path, not a general-purpose "roll any pool" remote; there is still no
-- client-facing way to roll an arbitrary pool. EmoteId is populated only on a genuine grant, mirroring
-- RollEmote's own (boolean, string?, string?) return -- never set for "AllOwned"/"PoolEmpty"/etc.
export type DevMenuRollEmoteResult = {
	Success: boolean,
	EmoteId: string?,
	Reason: string?,
}

-- Result of DevMenu_GrantBloodlineRerolls (Server/Systems/BloodlineSystem.lua's GrantRerolls).
-- Carries the new total back for the same reason DevMenuHitboxDebugResult carries Enabled: the
-- number is the whole point of the press, and reporting it saves the admin a second round trip (or a
-- guess) to find out whether the grant hit BloodlineConstants.MaxHeldRerolls.
export type DevMenuGrantRerollsResult = {
	Success: boolean,
	RerollsRemaining: number?,
	Reason: string?,
}

-- Live hitbox timing/full-field tuning for hand-authored attacks (every weapon Basic/Heavy/Finisher
-- stage, plus DashPunch/DashHit/AirSlam) moved out of DevMenu entirely -- it's now the Move Editor's
-- "Default" moves section (Server/Combat/DefaultMoveRegistry.lua, projected as a
-- Shared/MoveTypes.MoveDefinition with Category == "Default"; see that module's own header). No
-- dedicated Types.lua shapes remain for it -- MoveEditorListResult/MoveEditorMoveResult
-- (Shared/MoveTypes.lua) already cover the request/response shape.

-- Live flight-tuning field names (Server/DevMenu/FlightTuning.lua, DevMenu_ListFlightTuning/
-- DevMenu_SetFlightTuning/DevMenu_ResetFlightTuning) -- a CURATED subset of Constants.Flight's own
-- fields worth exposing to hands-on playtesting, a deliberately scoped-down editor rather than a
-- general Constants one (unlike Server/Combat/DefaultMoveRegistry.lua's now-full-field Default-move
-- editor, movement feel has no MoveRegistryManager.Validate-style clamp table to reuse). Deliberately
-- excludes fields with no "feel" ambiguity to dial in (e.g. DefaultCollideMode, the AnimationIds/
-- Sound tables).
export type FlightTuningFieldName =
	"CruiseSpeed"
	| "BoostSpeedMultiplier"
	| "Acceleration"
	| "BoostAcceleration"
	| "Deceleration"
	| "VerticalSpeedFraction"
	| "MaxBankAngleDegrees"
	| "MaxPitchAngleDegrees"
	| "BankTurnRateSensitivity"
	| "TakeoffBurstUpSpeed"
	| "TakeoffBurstForwardSpeed"
	| "HoverBobAmplitudeStuds"
	| "SoftLandingSpeedThreshold"
	| "HardLandingSpeedThreshold"
	| "SonicBoomSpeedThreshold"

export type FlightTuningInfo = {
	Field: FlightTuningFieldName,
	DisplayName: string,
	Value: number,
	-- FlightTuning's per-field clamp, and the value the file shipped with (what Reset restores).
	Min: number,
	Max: number,
	Default: number,
}

-- Result of DevMenu_ListFlightTuning -- every tunable field, fetched ONCE by DevMenuClient.lua and
-- cached client-side, same "fetch once, cache, patch from Adjust/Reset responses" shape as
-- DevMenuListBugReportsResult below.
export type DevMenuListFlightTuningResult = {
	Success: boolean,
	Fields: { FlightTuningInfo }?,
	Reason: string?,
}

-- Result of DevMenu_SetFlightTuning / DevMenu_ResetFlightTuning.
export type DevMenuFlightTuningResult = {
	Success: boolean,
	Field: FlightTuningInfo?,
	Reason: string?,
}

-- Bug Report feature (Server/Systems/BugReportSystem.lua owns Category/Status/Record and the
-- public submit remote; DevMenuSystem.lua owns the two admin-facing Result wrappers below and
-- the "Reports" tab that consumes them -- same ownership split every other admin action in this
-- file already follows). ReporterUserId/ReporterName/CreatedAt/PlaceId/JobId/Position are always
-- derived server-side in BugReportSystem.Submit -- never accepted as client-sent values, even
-- though they're not gameplay-critical, because "server owns truth" applies here too.
export type BugReportCategory = "Bug" | "Exploit" | "Suggestion" | "Other"
-- "InProgress" sits between Open and the two terminal states so an admin can flag "someone is
-- actively working this" distinct from the untouched backlog -- BugReportSystem.GetOpenCount's
-- Open-vs-not-Open counting (ComputeOpenCountDelta) already generalizes to any non-Open status
-- without needing its own change.
export type BugReportStatus = "Open" | "InProgress" | "Resolved" | "Dismissed"
-- Admin-settable severity, lowest to highest -- never set by the reporter (BugReportSystem.Submit
-- always starts a new record at Constants.BugReport.DefaultPriority), only ever re-triaged by an
-- admin via BugReportSystem.SetPriority.
export type BugReportPriority = "Low" | "Normal" | "High" | "Urgent"

-- One internal triage note on a report (BugReportSystem.AddNote) -- admin-to-admin coordination
-- ("assigning to X", "confirmed on live, escalating"), never shown to the reporter. There is no
-- reply-to-reporter delivery path anywhere in this codebase (no mailbox/notification system a
-- since-logged-off player could read later), so this is deliberately scoped to internal use only,
-- not a first half of a two-way conversation. Text is filtered the same way Description is at
-- Submit time.
export type BugReportNote = {
	Id: string,
	AuthorUserId: number,
	AuthorName: string,
	Text: string,
	CreatedAt: number,
}

export type BugReportRecord = {
	Id: string, -- HttpService:GenerateGUID(false); also the DataStore key in both stores
	ReporterUserId: number,
	ReporterName: string,
	Category: BugReportCategory,
	-- Already run through TextService:FilterStringAsync/GetNonChatStringForBroadcastAsync at
	-- submit time -- BugReportSystem never stores the raw client-typed text.
	Description: string,
	CreatedAt: number, -- os.time(), server clock
	PlaceId: number,
	JobId: string,
	-- nil if the reporter had no Character/HumanoidRootPart at submit time -- a missing position
	-- never rejects the report itself, see BugReportSystem.Submit.
	Position: Vector3?,
	Status: BugReportStatus,
	StatusUpdatedAt: number?,
	StatusUpdatedByUserId: number?,
	-- Admin-settable triage fields, added alongside the original Submit-time fields above. All three
	-- default to "no admin has touched this yet" (Priority = Constants.BugReport.DefaultPriority,
	-- AssignedAdminUserId/Name nil, Notes {}) both for a freshly Submitted record and for
	-- decodeRecord reading an OLDER record written before these fields existed -- see that
	-- function's own comment in BugReportSystem.lua.
	Priority: BugReportPriority,
	AssignedAdminUserId: number?,
	AssignedAdminName: string?,
	Notes: { BugReportNote },
}

-- Result of BugReport_Submit (RemoteFunction -- same "client needs an immediate answer" shape as
-- DevMenuSpawnDummyResult). ReportId lets the client show a confirmation/reference id on success.
export type BugReportSubmitResult = {
	Success: boolean,
	Reason: string?,
	ReportId: string?,
}

-- Which page BugReportSystem.ListReports should return. "First" (re)starts this admin's
-- server-held DataStorePages session; "Next" advances it -- see BugReportSystem's own header for
-- why the DataStorePages object itself can never cross this remote.
export type BugReportListCursorMode = "First" | "Next"

-- Result of DevMenu_ListBugReports (RemoteFunction). HasMore is meaningful only when Success is
-- true -- it reflects whether calling again with "Next" is worth doing.
export type DevMenuListBugReportsResult = {
	Success: boolean,
	Reason: string?,
	Reports: { BugReportRecord }?,
	HasMore: boolean?,
}

-- Result of DevMenu_UpdateBugReportStatus (RemoteFunction) -- carries back the one updated
-- record, same "return just what changed" shape as DevMenuHitboxStageResult.
export type DevMenuUpdateBugReportStatusResult = {
	Success: boolean,
	Reason: string?,
	Report: BugReportRecord?,
}

-- Shared result shape for every OTHER bug-report triage mutation (DevMenu_AddBugReportNote/
-- SetBugReportPriority/AssignBugReport) -- same {Success, Reason, Report} contract as
-- DevMenuUpdateBugReportStatusResult above, factored out once a third and fourth near-identical
-- Result type would otherwise exist for no functional difference.
export type DevMenuBugReportMutationResult = {
	Success: boolean,
	Reason: string?,
	Report: BugReportRecord?,
}

-- Teleportation / character-utility / server-wide admin actions -- every one of these reuses
-- DevMenuActionResult (defined above) for its RemoteFunction result, the same "nothing about the
-- result differs enough to warrant a near-identical type" reasoning that comment already gives for
-- SetTargetHealth/Godmode/Flight/FlightCollide. ShutdownServer's first (arming) press also returns
-- DevMenuActionResult with Reason = "ConfirmationRequired" -- not a distinct type, just another
-- Reason string for DevMenuClient.lua to special-case in its own describeX function.

-- Broadcast Announcement (DevMenu_Announcement, a RemoteEvent fired to EVERY client -- see that
-- remote's own header in Constants.lua). "Warning" is used for the Shutdown Server countdown;
-- "Info" for a plain admin broadcast.
export type DevMenuAnnouncementKind = "Info" | "Warning"

-- Payload of the DevMenu_Announcement RemoteEvent (broadcast to every client) --
-- Client/Announcement/AnnouncementClient.lua renders it as a banner (Kind picks the accent color).
export type DevMenuAnnouncementPayload = {
	Kind: DevMenuAnnouncementKind,
	Message: string,
}

-- Suspected-cheater manual flagging (Server/Systems/ModerationSystem.lua, DevMenu_SetSuspectedCheater)
-- -- a REVERSIBLE toggle (mirrors Mute's reversibility, unlike Ban's one-way permanence) backed by
-- its own DataStore record per UserId, overwritten on re-flag rather than accumulating history.
-- "Manual" is an admin acting from the "Players" tab roster row (the only source this pass wires up);
-- "System" is reserved for a future automated-detection pipeline that doesn't exist yet -- see
-- Confidence/ReasonCode below, both of which stay nil until that pipeline is designed.
export type SuspicionSource = "Manual" | "System"

export type SuspicionRecord = {
	UserId: number,
	FlaggedAt: number,
	-- The flagging admin's UserId for a "Manual" flag; nil for a "System" flag with no individual
	-- admin behind it.
	FlaggedByUserId: number?,
	Reason: string,
	Source: SuspicionSource,
	-- Always nil this pass -- reserved for a future automated-detection pipeline's confidence score.
	Confidence: number?,
	-- Always nil this pass -- reserved for that same future pipeline's machine-readable reason code.
	ReasonCode: string?,
}

-- Result of LiveConsole_Subscribe (RemoteFunction, Server/Systems/LiveConsoleSystem.lua) -- fired
-- by Client/DevTools/LiveConsole/LiveConsoleClient.lua the moment the admin's console panel actually opens,
-- doubling as both the authorization check (a rejection here IS the "not admin" answer, same
-- "first remote call is the real gate" idiom DevMenu_GetOverview/MoveEditor_ListMoves already
-- use) and the fetch that populates the panel with whatever Shared/Logger.lua's capture buffer
-- already holds at that exact moment, oldest first.
export type LiveConsoleSubscribeResult = {
	Success: boolean,
	Reason: string?,
	Snapshot: { LogTypes.LogEntry }?,
}

-- First-time-player onboarding / character creation (Server/Systems/CharacterCreationSystem.lua,
-- Client/Onboarding/OnboardingClient.lua, Client/Intro/IntroClient.lua). A first-time player is
-- detected purely by `profile.raceId == nil` -- no new boolean flag on PlayerProfile -- so these
-- three types cover every REQUEST/RESPONSE this feature needs. CharacterCreation_AwakeningComplete
-- (Constants.CharacterCreation.RemoteNames.AwakeningComplete) is the one additional remote this
-- feature uses and deliberately has no type here -- it's a payload-less, fire-and-forget
-- RemoteEvent (see CharacterCreationSystem.lua's own header for the trust reasoning), so there's
-- nothing for a type to describe.

-- Result of CharacterCreation_GetOnboardingState (RemoteFunction, no payload). Client/Intro/
-- IntroClient.lua calls this (via OnboardingClient.FetchOnboardingState) before UI.Mount() -- see
-- Main.client.lua's own header for the boot-order reasoning. This is also the request that triggers
-- this SESSION's first Player:LoadCharacter() call (StarterPlayer.CharacterAutoLoads = false,
-- default.project.json) for every player, onboarding or not; see CharacterCreationSystem.lua's
-- header for the full contract.
export type CharacterCreationOnboardingStateResult = {
	NeedsOnboarding: boolean,
}

-- Payload of CharacterCreation_Finalize (RemoteFunction) -- every field stays `unknown` here
-- deliberately (not RaceId/string/AttributeBlock) since this crosses the client/server trust
-- boundary and hasn't been validated yet; CharacterCreationSystem.ValidateRaceId/
-- ValidateAttributeBlock/ValidateDisplayName are what narrow these into real types, server-side,
-- regardless of what the client's own Confirmation screen already checked.
export type CharacterCreationFinalizePayload = {
	RaceId: unknown,
	DisplayName: unknown,
	Attributes: unknown,
}

-- Result of CharacterCreation_Finalize. Reason is populated only when Success is false (e.g.
-- "InvalidRaceId", "AttributeBudgetInvalid", "InvalidDisplayName", "TransformFailed") -- see
-- CharacterCreationSystem.lua's handleFinalize for the full set. The client's Confirmation screen
-- loops/retries on Success = false rather than stranding the player (OnboardingClient.lua), the same
-- reject-and-retry UX BugReportClient.lua already establishes for BugReport_Submit.
export type CharacterCreationFinalizeResult = {
	Success: boolean,
	Reason: string?,
}

-- Emote System (Shared/Emotes/EmoteDefinitions.lua + EmoteRegistry.lua, Server/Systems/
-- EmoteUnlockService.lua + EmoteSystem.lua, Client/FX/EmoteAnimator.lua + Client/Emotes/
-- EmoteController.lua). Phase 1 of 2 -- this is the full data/server/client backend; the radial
-- wheel UI (a later session) is pure presentation on top of it, per this pass's own binding
-- requirement that the system underneath work with zero UI.
--
-- An open-ended, always-growing content roster (EmoteId stays an opaque string, like BloodlineId/
-- ArtId above) rather than a small fixed set like RaceId -- a live game keeps authoring new emotes
-- for years, the same reasoning EmoteConstants.lua's own header gives for staying out of
-- Constants.lua.
export type EmoteCategory = "Social" | "Greeting" | "Reaction" | "Dance" | "Sitting" | "Rare"

-- How a player comes to own a given emote. "Default" is granted to every profile at creation (and
-- backfilled onto older profiles -- see EmoteUnlockService.lua); every other value is granted only
-- through EmoteUnlockService.GrantEmote/RollEmote, called by whatever future system owns that
-- condition (AchievementSystem for "Achievement", a quest system for "Quest", a live-ops system for
-- "Event", a store for "Purchase") -- EmoteUnlockService itself stays agnostic to which caller fires
-- which type, per its own header.
export type EmoteUnlockType = "Default" | "Achievement" | "Roll" | "Quest" | "Event" | "Purchase"

-- Carried on both EmoteDefinition.Unlock (what's required to earn this emote) and as GrantEmote's
-- own `source` argument (what actually granted it, for logging/auditing) -- the same shape serves
-- both directions since a grant should always be traceable back to a requirement it satisfied.
-- Id names a specific achievement/quest/event id (meaningful only for "Achievement"/"Quest"/
-- "Event"); Pool names a EmoteConstants.RollPools key (meaningful only for "Roll"). Both stay nil
-- for "Default"/"Purchase", which need neither.
export type EmoteUnlockRequirement = {
	Type: EmoteUnlockType,
	Id: string?,
	Pool: string?,
}

-- One emote's full authored data (Shared/Emotes/EmoteDefinitions.lua's `{ [EmoteId]: EmoteDefinition
-- }` table) -- pure content, no Instance/Player coupling, so it's requirable and testable from a
-- plain TestEZ spec (Shared/Emotes/EmoteRegistry.lua's own header). AnimationId/Icon follow
-- CombatConstants.AnimationIds' own "wired but unauthored" convention: an empty string means no
-- real asset exists yet, never a guessed/placeholder id (this codebase never fabricates one -- see
-- that constant's own header). Duration is nil for a Loop == true emote (Sit/Dance -- stopped only
-- by RequestPlay/death/interruption, never on a timer); a positive number for a one-shot (Wave,
-- Bow, ...). Shared/Emotes/EmoteRegistry.lua's Validate enforces both directions.
--
-- Duration is NOT the length of the animation, and does not end an emote that has one. A clip-bearing
-- one-shot is ended by its own AnimationTrack reaching its natural end, reported by the acting client
-- through Emote_NotifyFinished -- AnimationTrack.Length is client-only, so an authored number here can
-- never be more than a guess about a separately-uploaded asset, and the two silently disagreeing is
-- exactly what used to truncate emotes mid-motion. Duration still ends a one-shot with AnimationId ==
-- "" (no track exists to finish), and remains authored design intent everywhere else. See Server/
-- Systems/EmoteSystem.lua's WHAT ENDS A ONE-SHOT EMOTE header for the full lifecycle.
export type EmoteDefinition = {
	Id: EmoteId,
	DisplayName: string,
	Description: string?,
	AnimationId: string,
	Icon: string,
	Category: EmoteCategory,
	Loop: boolean,
	Duration: number?,
	-- True if playing this emote should zero the player's WalkSpeed for its duration (Constants.
	-- Attributes.EmoteMovementLocked, read by Server/Systems/RunSystem.lua's resolver) --
	-- a seated/dancing pose reads as broken if the player can still slide around mid-animation.
	MovementLocked: boolean,
	-- False rejects RequestPlay outright while Types.CombatSnapshot.InCombat is true (EmoteSystem.lua)
	-- -- a seated/dancing pose has no place mid-skirmish; a quick social gesture (Wave, Taunt) is
	-- allowed to carry into a lingering in-combat window.
	CombatAllowed: boolean,
	-- True interrupts an in-progress emote the instant the player's Health drops below what it was
	-- when the emote started (EmoteSystem's own OnHeartbeatTick subscriber) -- taking a hit should
	-- break a vulnerable pose like Sit/Dance; a passing Wave/Point has nothing to protect and stays
	-- false.
	CancelOnDamage: boolean,
	Unlock: EmoteUnlockRequirement,
}

-- Sent to the acting player only, the moment EmoteSystem accepts Emote_RequestPlay (RemoteEvent).
export type EmoteStartedPayload = {
	EmoteId: EmoteId,
}

-- Sent to the acting player only, whenever EmoteSystem.StopEmote actually ends a currently-playing
-- emote (natural duration expiry, a new RequestPlay superseding it, death, or the heartbeat
-- interruption guard) -- the one authoritative stop signal, mirroring EmoteStartedPayload's shape.
export type EmoteStoppedPayload = {
	EmoteId: EmoteId,
}

-- Payload of Emote_UnlockedUpdated (RemoteEvent, server -> owning client only) -- fired once on join
-- (EmoteUnlockService's own PlayerDataSystem.OnProfileLoaded hook) and again on every successful
-- GrantEmote/RollEmote for that player. An array, not the profile's own `{ [EmoteId]: true }` set
-- shape -- ClientState.Bootstrap is what turns this into the set shape the wheel UI actually wants
-- to query (O(1) "is this unlocked"), the same "wire format vs. client-state shape can differ"
-- latitude CombatVitalsPayload's own current/max pair already takes versus how NumberFormatting.lua
-- might render it.
export type EmoteUnlockedUpdatePayload = {
	EmoteIds: { EmoteId },
}

-- Payload of Emote_LoadoutUpdated (RemoteEvent, server -> owning client only) -- fired once on join
-- and again on every successful RequestSetLoadoutSlot. Ordered array, length == EmoteConstants.
-- LoadoutSize, mirroring Types.PlayerProfile.emoteLoadout's own shape exactly (this IS that field,
-- replicated).
export type EmoteLoadoutUpdatePayload = {
	Loadout: { EmoteId },
}

-- Race Traits + Bloodline Abilities plan -- the generic modifier engine's own wire/domain shapes
-- (Server/Systems/EffectSystem.lua, not built yet -- these types are landed ahead of it so
-- Shared/Kit/KitTypes.lua's KitAbilityDefinition.Effects has something real to author against).
-- Live here rather than in KitTypes.lua because EffectSystem is content-agnostic (no notion of
-- "race" or "bloodline") and every consumer of a live ActiveModifier -- a future combat-side
-- Might/Pressure damage read, a future buff-bar HUD -- reaches it through Types the same way it
-- reaches CombatSnapshot, not through a Kit-specific module it would have no other reason to
-- require.

-- Which content layer granted a modifier or is asking to fire an ability -- shared by ActiveModifier
-- below and KitAbilityRequest, so a Race trait and a Bloodline stage can never collide on Id alone:
-- every seam that traces an effect or a request back to what produced it disambiguates by this pair
-- (Kind, Id), never Id by itself. Exactly two values because those are the only two content layers
-- this plan builds -- a third kit-shaped content type would extend this union, not invent a parallel
-- one.
export type ActiveModifierSource = "RaceTrait" | "BloodlineStage"

-- How long an applied modifier survives, the three lifetimes EffectSystem's own header documents:
--   * "Instant" -- applied once, never tracked afterward (v1's only target is a Qi restore via
--     QiSystem.Restore -- see that function's own header on why it's a new primitive, not a reuse
--     of QiSystem.Refund).
--   * "Timed" -- a standing modifier with an expiry, reclaimed by EffectSystem's own tick sweep on
--     GameplayEvents.OnHeartbeatTick. What an Active ability's buff uses.
--   * "Bound" -- a standing modifier with no timer, lasting exactly as long as its grant is true.
--     Applied/removed only via EffectSystem.SetBoundModifiers (an atomic diffed replace), never by
--     the tick sweep. What a Passive ability uses.
export type ActiveModifierLifetime = "Instant" | "Timed" | "Bound"

-- Which of the three effect shapes v1 supports a given ActiveModifierSpec carries. Only the fields
-- meaningful for the chosen Kind are populated -- the same "Kind selects which of several nilable
-- fields matter" convention CombatFeedbackKind/CombatFeedbackPayload already use in this file, rather
-- than a Luau discriminated union (which the language doesn't have).
--   * "AttributeDelta" -- shifts one AttributeBlock field by Delta for as long as the modifier is
--     active. EffectSystem.GetAttributeDelta(player, key) is the seam a future derivation point
--     (e.g. QiSystem.ComputeMaxQi-style math for Fortitude/Might/Pressure/Fleetness) sums these
--     against -- not wired to any gameplay math this phase, per the plan's own non-goals.
--   * "Tag" -- an opaque marker other systems can query via EffectSystem.HasTag/GetTagMagnitude,
--     with no attribute or resource attached. The escape hatch for "this player currently has X"
--     checks a future combat/status system reads without EffectSystem needing to know what X means.
--   * "QiRestore" -- grants Qi through QiSystem.Restore. Only meaningful alongside Lifetime ==
--     "Instant" -- a standing Qi restore would just mean "restore once more on every tick sweep,"
--     which is never the intent of a one-shot grant.
export type ActiveModifierKind = "AttributeDelta" | "Tag" | "QiRestore"

-- Mirrors AttributeBlock's own six field names exactly, by construction -- a deliberate two-copies
-- arrangement, because this file is a leaf (see its own header) and has no business depending on a module that
-- isn't. AttributeBlock is the RUNTIME authority; this union is its compile-time mirror.
export type ActiveModifierAttributeKey = "Vitality" | "Fortitude" | "MeridianFlow" | "Might" | "Pressure" | "Fleetness"

-- The AUTHORED half of a modifier -- what a KitAbilityDefinition.Effects entry or a
-- BloodlineStageDefinition.PassiveEffects entry actually says, before it's ever applied to a real
-- player. EffectSystem.Apply/SetBoundModifiers turn one of these into a live ActiveModifier below.
export type ActiveModifierSpec = {
	Kind: ActiveModifierKind,
	Lifetime: ActiveModifierLifetime,
	-- Meaningful only for Kind == "AttributeDelta".
	AttributeKey: ActiveModifierAttributeKey?,
	Delta: number?,
	-- Meaningful only for Kind == "Tag". Magnitude lets one tag express strength (e.g. a stacking
	-- resistance) rather than every tag being purely boolean-present.
	Tag: string?,
	Magnitude: number?,
	-- Meaningful only for Kind == "QiRestore".
	QiRestoreAmount: number?,
	-- Meaningful only for Lifetime == "Timed" -- how long the modifier lasts once applied, seconds.
	DurationSeconds: number?,
}

-- The LIVE half -- one modifier instance EffectSystem is currently tracking for a specific player,
-- returned read-only by EffectSystem.GetActiveModifiers for replication/inspection. Id is unique per
-- applied instance (not per Spec -- the same Spec can be applied to the same player more than once,
-- e.g. two stacking Tag grants from different sources), which is what Clear/ClearAllFromSource key
-- against.
export type ActiveModifier = {
	Id: string,
	Spec: ActiveModifierSpec,
	SourceKind: ActiveModifierSource,
	-- TraitId for "RaceTrait", BloodlineId for "BloodlineStage" -- opaque to EffectSystem itself,
	-- which never interprets this beyond using it as ClearAllFromSource's own grouping key.
	SourceId: string,
	AppliedAt: number,
	-- Non-nil exactly when Spec.Lifetime == "Timed" -- what EffectSystem's own tick sweep on
	-- GameplayEvents.OnHeartbeatTick compares against to reclaim an expired modifier.
	ExpiresAt: number?,
}

-- Client -> server, KitAbilitySystem's own RemoteFunction (Constants.Kit.RemoteNames.RequestAbility,
-- not built yet). Disambiguated by the full (SourceKind, SourceId, AbilityId) triple rather than
-- AbilityId alone -- see ActiveModifierSource's own header -- so a Race trait and a Bloodline stage
-- can reuse the same AbilityId string with no collision.
export type KitAbilityRequest = {
	SourceKind: ActiveModifierSource,
	SourceId: string,
	AbilityId: string,
}

-- Result of KitAbilitySystem's RequestAbility RemoteFunction -- mirrors ArtActionResult's
-- {Success, Reason?} shape exactly, the same request/response contract every other gated action
-- remote in this file already uses (ArtActionResult, MoveEditorActionResult).
export type KitActionResult = {
	Success: boolean,
	Reason: string?,
}

-- Server (KitAbilitySystem) -> owning client only, fired on a successful UseAbility -- the post-
-- success FX echo, same "just enough for FX" shape AttackStartedPayload already carries for a
-- combat swing. Not itself a legality signal; RequestAbility's own KitActionResult already told the
-- caller whether the use was accepted.
export type KitAbilityUsedPayload = {
	SourceKind: ActiveModifierSource,
	SourceId: string,
	AbilityId: string,
}

return Types
