--!strict
--[[
	Constants.lua

	Owns: every tunable/fixed number and named lookup table referenced by more than one system --
	single source of truth per engineering-standards.md. If a system needs a shared number, it
	imports it from here rather than hardcoding it locally.

	Most balance numbers (tier XP thresholds, bloodline/art costs) are still NOT populated -- those
	remain a technical-design pass owned by each system's own design work (TierSystem, ArtSystem,
	etc.), not invented here as placeholders. Everything here is canon that's already settled: fixed
	content counts, approved budgets, and cross-system registries (Attributes, Keybinds, RemoteNames)
	that more than one system needs to agree on by name.

	NOT a dumping ground for a single system's own tuning surface. Combat (Shared/Combat/
	CombatConstants.lua) and Flight (Shared/Flight/FlightConstants.lua) both used to live here as
	Constants.Combat/Constants.Flight and were split out to their own standalone modules -- see
	either file's own header for the two reasons: they're the Move Creation System's/FlightTuning's
	own LIVE, runtime-mutated data (a live admin remote rewrites them by reference, mid-server), and
	they match the precedent AttackConstants.lua/DamageConstants.lua/DefenseConstants.lua/
	HitboxEngineConstants.lua already set. A section here that grows into a real, actively-tuned
	single-system surface -- especially one anything ever mutates at runtime -- should follow them
	out rather than staying "the one exception."
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local Constants = {}

-- Shape shared by Constants.Combat.Sound/Constants.Flight.Sound's one-shot entries and consumed by
-- Client/FX/SoundManager.lua's Register() -- declared here, not in SoundManager.lua, because this
-- module is Shared (client+server-safe) while SoundManager.lua is client-only; a client-only module
-- can depend on Shared, never the other way around. PoolSize is optional (Register() defaults it to
-- 1) -- only sounds prone to overlapping replays during play (fast combat combos) need to name one.
-- PlaybackRegion is optional and, when supplied, restricts playback to that [start, stop] slice of
-- the asset in seconds (SoundManager applies it via Sound.PlaybackRegion + PlaybackRegionsEnabled).
-- It exists so ONE asset containing several distinct sounds -- Constants.Run's stage-2 file, which
-- opens with a speed whoosh and continues into footsteps -- can be registered as two independent
-- named sounds instead of needing the audio split into two uploads, and so trimming is done by the
-- engine rather than by a task.delay stop (which would be both audibly imprecise and one more timer
-- per play to keep track of).
export type SoundDefinition = {
	SoundId: string,
	Volume: number,
	PoolSize: number?,
	PlaybackRegion: NumberRange?,
}
-- The one deliberate exception to SoundDefinition's shape -- a continuous loop (Constants.Flight.
-- Sound.WindLoop, played via SoundManager.PlayLooped) has no single Volume, only a ramped range the
-- caller eases across every frame (Client/FX/FlightAudio.lua's SetWindIntensity) -- see that
-- function for how MaxVolume/MinPlaybackSpeed/MaxPlaybackSpeed get used.
export type LoopSoundDefinition = {
	SoundId: string,
	MaxVolume: number,
	MinPlaybackSpeed: number,
	MaxPlaybackSpeed: number,
}

-- Studio-only diagnostics config -- lifted out to Shared/DebugConstants.lua, which carries the
-- Logger production-safety contract and the note on why it stays in Shared/ rather than following
-- the dev tools out of the live build. Re-exported here so every existing Constants.Debug.X call
-- site keeps working; new code should require that module directly.
Constants.Debug = require(ReplicatedStorage.Shared.DebugConstants)

-- Fixed by canon (world-bible.md / progression-systems.md).
--
-- BloodlineCount is the only one of these left, and it is the only one anything read. Four siblings
-- went with it -- TierCount, RaceCount, Constants.Factions and Constants.Regions -- each of which
-- had zero readers AND restated a canon fact that IS read, from somewhere else:
--   * TierCount = 9        -> Shared/TierConstants.MaxTier, which DERIVES it as #TierConstants.Tiers
--   * RaceCount = 4        -> Types.RaceId, the string-literal union every race-facing signature uses
--   * Constants.Factions   -> Types.Faction ("Celestial" | "Demonic" | "Unbound")
--   * Constants.Regions    -> Types.Region ("TheVoid" | "TheMedianParadise" | ...)
-- A second, hand-written copy of a canon count is not documentation, it is a place for canon to
-- disagree with itself -- and an unread one cannot even be caught by a failing test. The versions
-- kept are the ones a compiler or a length operator checks.
Constants.BloodlineCount = 13

-- Approved design-time budget, not yet a measured production ceiling (performance-optimization.md).
Constants.NetworkBudget = {
	MaxRemoteCallsPerSecondPerPlayer = 4,
	-- Attack (Basic + Heavy) gets its own, more generous budget, separate from
	-- MaxRemoteCallsPerSecondPerPlayer above -- see CombatSystem.lua's attackRateLimiter/
	-- defensiveRateLimiter split for why. With Basic1's Cooldown now ~0.44s, a player clicking
	-- faster than the server will actually accept (mashing while there's no animation to show
	-- "still on cooldown," or just an eager double-click) can easily exceed 4 calls/sec on Attack
	-- alone -- every one of those extra clicks still consumed a slot in the OLD shared budget even
	-- though the server rejected the swing itself, which could silently eat the next real input
	-- (e.g. the actual finisher press, or a Dash sharing that same bucket) with zero feedback.
	MaxAttackCallsPerSecondPerPlayer = 10,
	-- Defensive/mobility actions get their own budget for exactly the reason the Attack split above
	-- describes, which was applied to Attack and then never followed through to the other bucket.
	-- CombatSystem.lua's defensiveRateLimiter gates FOUR distinct actions off one counter -- Feint,
	-- BlockStart (which is also the parry), Dash and Slide -- and four of those inside one second is
	-- ordinary defensive play, not abuse: block-tap for a parry, dash out, block again, feint. At 4
	-- the fifth input was rejected outright rather than buffered (checkCommonPreconditions runs the
	-- limiter before any buffering), and because CombatClient has already predicted the block stance
	-- and the dash locally, that rejection rolls the prediction back as a VISIBLE flinch -- strictly
	-- worse than the "silently eat the next real input with zero feedback" case cited above. Every
	-- one of the four is independently cooldown-gated server-side, so this budget only ever needs to
	-- stop a packet flood, never legitimate play.
	MaxDefensiveCallsPerSecondPerPlayer = 12,
}

-- Persistence-infrastructure tunables. Deliberately domain-agnostic: what gets stored belongs to the
-- System storing it, but HOW HARD to try belongs here, once.
--
-- This table exists because the identical pair of numbers was declared FIVE times in this file --
-- Constants.PlayerData, .BugReport, .Moderation, .MoveEditor and .KitEditor each carried
-- StorageRetryMaxAttempts = 3 / StorageRetryBaseBackoffSeconds = 1, each under a comment observing
-- that it was "the same shape as every other StorageRetry* pair in this file". Five places to change
-- a retry policy is five places for it to disagree, and the comments proved everybody already knew.
--
-- Declared HERE, above every domain table below, because those tables are assigned in file order and
-- a reference from one of them to a table declared later would read nil.
Constants.Storage = {
	-- The one retry policy every DataStore call in this codebase goes through, handed straight to
	-- Shared/DataStoreRetry.Scoped by each persisting System. Three attempts with 1s exponential
	-- backoff (1s, then 2s) rides out an ordinary DataStore blip without making a player wait through
	-- a long stall for a service that is genuinely down.
	RetryPolicy = {
		MaxAttempts = 3,
		BaseBackoffSeconds = 1,
	},
}

-- Networking-infrastructure tunables -- distinct from NetworkBudget above (that table is about
-- *how often* a remote can fire; this one is about *how long to wait* for one to exist at all).
Constants.Network = {
	-- WaitForChild timeout (seconds) for the handful of lookups that can't just trust an Instance is
	-- already there the instant it's asked for. Was SEVEN independently hand-typed literal `10`s with
	-- no shared name: Shared/NetworkBridge.lua's GetRemoteEvent/GetRemoteFunction (a client module
	-- requiring this before the server's own remote-creating System has necessarily finished booting
	-- on a slow server start), Server/Systems/CombatSystem.lua's onCharacterAdded loading a fresh
	-- Humanoid/HumanoidRootPart, and four client CharacterAdded handlers waiting on that same pair of
	-- parts (Client/Camera/FlightCamera.lua, Client/Camera/ShiftLockCamera.lua, Client/DevTools/DevMenu/
	-- FlightController.lua, Client/DevTools/DevMenu/DevMenuClient.lua). All seven were tuned to agree on 10s by
	-- coincidence, not by reference to a shared source -- a future "give slow connections more slack"
	-- pass would otherwise have had to hunt down and edit every call site instead of one number. Not
	-- every WaitForChild in the codebase reads this: Client/Combat/CombatClient.lua's own Humanoid wait
	-- uses a deliberately SHORTER 5s (a distinct tuning choice for that one call site, not a candidate
	-- for merging into this shared value).
	WaitForChildTimeoutSeconds = 10,
}

-- Humanoid/Player Attribute names shared across systems -- lifted out to
-- Shared/AttributeConstants.lua, which carries the per-name contracts. Re-exported here so every
-- existing Constants.Attributes.X call site keeps working; new code should require that module
-- directly. See its header, and this file's own header above, for why sections leave.
Constants.Attributes = require(ReplicatedStorage.Shared.AttributeConstants)

-- Default keybinds for both devices -- lifted out to Shared/Input/KeybindConstants.lua, which
-- carries the rationale (chiefly that these are DEFAULTS, cloned by KeybindManager at boot and
-- never mutated). Re-exported here so every existing Constants.Keybinds.X call site keeps
-- working; new code should require that module directly.
Constants.Keybinds = require(ReplicatedStorage.Shared.Input.KeybindConstants)

-- The player-preferences remote surface -- lifted out to Shared/SettingsConstants.lua. Re-exported
-- here so every existing Constants.Settings.X call site keeps working; new code should require
-- that module directly.
Constants.Settings = require(ReplicatedStorage.Shared.SettingsConstants)

-- Canonical player-progression persistence (Server/Systems/PlayerDataSystem.lua) -- the single
-- DataStore-backed owner every other System's player-state reads/writes eventually route through
-- (engineering-standards.md's "one serialized entry point per player's data"). Mirrors
-- Constants.BugReport's own shape/naming below (retry/backoff pair, tuning surface) -- this table
-- existing separately from Constants.BugReport, despite both being DataStore config, is
-- deliberate: BugReportSystem is a fire-and-forget public feature with its own unrelated tuning
-- (cooldowns, page size), where PlayerDataSystem is the load-bearing progression spine every
-- other gameplay System depends on, with its own distinct tuning surface (autosave cadence,
-- schema version, load-failure messaging) that has nothing to do with bug reports.
--
-- Does NOT own the DataStore name itself -- that identifier lives solely in the server-only
-- Server/Config/StorageConfig.lua (StorageConfig.PlayerDataStoreName), never here, so it can
-- never replicate to clients (pure reconnaissance otherwise -- see StorageConfig.lua's own
-- header). This table used to carry its own DataStoreName field alongside StorageConfig's; that
-- was a leftover twin from the move to StorageConfig.lua that nothing ever read, and it was
-- deleted rather than kept "just in case" -- a dead field with a header comment that reads as
-- authoritative is a trap, not a convenience.
Constants.PlayerData = {
	-- Current on-disk schema version (Types.StoredPlayerProfile.SchemaVersion) -- PlayerDataSystem.
	-- MigrateRecord walks a stored record forward from whatever version it was saved at toward this
	-- number. Bumped 1 -> 2 for the Emote System's unlockedEmoteIds/emoteLoadout fields
	-- (Types.PlayerProfile) -- PlayerDataSystem.lua's Migrations[1] is the first real entry that
	-- table has ever needed, backfilling both fields onto any record saved before this pass. Bumped
	-- 2 -> 3 for the Settings System's `settings` field (Types.PlayerProfile) --
	-- PlayerDataSystem.lua's Migrations[2] backfills it onto any record saved before this pass.
	-- Bumped 3 -> 4 for the Art System's `equippedArts` field (Types.PlayerProfile), which is what
	-- makes an unlocked art reachable from the hotbar across sessions -- PlayerDataSystem.lua's
	-- Migrations[3] backfills an empty slot map onto any record saved before this pass. Bumped 4 -> 5
	-- for the Parkour System's `settings.Parkour` sub-table (Types.ParkourSettings) --
	-- PlayerDataSystem.lua's Migrations[4] backfills the shipped defaults onto any record saved before
	-- this pass, so an existing player's first login after the update has parkour on with every assist
	-- enabled rather than a half-populated settings table. Bumped 5 -> 6 for the camera-comfort
	-- accessibility block (`settings.Comfort`, Types.ComfortSettings) -- PlayerDataSystem.lua's
	-- Migrations[5] backfills it with both effects ENABLED, matching what every player already
	-- experiences today, so the migration changes nobody's game and only gives them a switch. Bumped
	-- 6 -> 7 for the Race Traits + Bloodline Abilities plan's `bloodlineStageProgress` field
	-- (Types.PlayerProfile) -- PlayerDataSystem.lua's Migrations[6] backfills an empty table onto any
	-- record saved before this pass, the same "empty is honest" shape Migrations[3] already used for
	-- equippedArts. Bumped 7 -> 8 for the bloodline spin's `bloodlineRerolls` field, and 8 -> 9 for the
	-- Blimp Fuel System's `blimpFuel` field (Types.PlayerProfile) -- PlayerDataSystem.lua's
	-- Migrations[8] backfills { Coal = 0, Water = 0 } onto any record saved before this pass, the same
	-- "empty is honest" shape as every migration before it.
	SchemaVersion = 9,

	-- A brand-new profile's starting Tier -- Tier 1 is the bottom of TierSystem's nine-tier ladder
	-- (progression-systems.md), the correct starting point for a player who has never played before.
	DefaultTier = 1,

	-- Periodic autosave interval, seconds -- a crash/server-death safety net on top of the
	-- PlayerRemoving/BindToClose save paths (PlayerDataSystem.lua), which only fire on a clean
	-- leave/shutdown. Only DIRTY profiles (mutated since their last save, see PlayerDataSystem.
	-- Transform) are actually written each pass, not every loaded profile -- so this budget is
	-- "at most (population / this interval) writes per second," not a flat per-player-per-interval
	-- cost. Roblox's DataStore write budget scales with player count (roughly
	-- 60 + 10/player/minute per key) -- 180s means even a server where every single player mutates
	-- their profile every single autosave window writes at (population / 3) calls/min, comfortably
	-- inside that scaling budget for any population size this uses; a much shorter interval would
	-- start eating into budget headroom other DataStore-backed Systems (BugReportSystem,
	-- ModerationSystem) also draw from.
	AutosaveIntervalSeconds = 180,

	-- Default timeout for PlayerDataSystem.WaitForProfile when a caller doesn't pass its own --
	-- long enough to absorb a slow DataStore GetAsync + full retry/backoff exhaustion
	-- (worst case: BaseBackoffSeconds * (1+2+4) = 7s for 3 attempts) with real margin, short enough
	-- that a caller gating a gameplay action on a player's data isn't left hanging indefinitely.
	WaitForProfileDefaultTimeoutSeconds = 15,

	-- Upper bound (seconds) PlayerDataSystem's game:BindToClose handler waits for in-flight saves
	-- to finish before returning -- Roblox's own outer BindToClose budget varies by server
	-- population and isn't a fixed constant this codebase can rely on, so this is deliberately
	-- generous while still finite: better to return promptly once every save has actually
	-- completed than to hold the callback open needlessly, and a hard ceiling here still protects
	-- against a single stuck retry loop hanging the whole shutdown indefinitely.
	ShutdownSaveTimeoutSeconds = 25,

	-- Cross-server session lock (Types.PlayerDataLock, PlayerDataSystem.lua's loadProfile/saveProfile)
	-- -- see that type's own header for the race it closes. A foreign lock older than this is treated
	-- as abandoned (its holding server crashed/died without ever running PlayerRemoving/BindToClose,
	-- so it will never release it itself) rather than blocking a rejoin forever. Sized for the
	-- crash-recovery case specifically, not routine dirty-mutation frequency: the lock is claimed
	-- once at load and released once at the final save, never refreshed mid-session (see
	-- loadProfile's own header for why periodic refresh isn't needed -- Roblox never routes a second
	-- PlayerAdded for an already-connected player to a different server, so a live server's lock is
	-- never actually contended; only a genuine crash leaves one dangling). 300s is generous enough to
	-- absorb the ordinary "hop lands before the leaving server's save completes" race (which the
	-- retry loop below resolves in low single-digit seconds) while not punishing a post-crash rejoin
	-- with an excessive wait.
	LockStaleAfterSeconds = 300,

	-- How many times loadProfile retries a REFUSED lock claim (a live foreign lock, not a DataStore
	-- call failure -- DataStoreRetry's own retry already covers that separately, inside each attempt
	-- here) before giving up and kicking with LockHeldKickMessage, backed off by
	-- LockClaimRetryBackoffSeconds between attempts. Sized to comfortably outlast the ordinary "hop
	-- lands before the leaving server's own PlayerRemoving save completes" race -- a leave-triggered
	-- save is one DataStore round trip, typically well under either backoff window.
	LockClaimMaxAttempts = 3,
	LockClaimRetryBackoffSeconds = 2,

	-- Player-facing kick messages for the load-failure modes PlayerDataSystem.lua distinguishes
	-- (engineering-standards.md: DataStore failures are "expected-but-rare... not edge cases to
	-- ignore," and the safe fallback for any of them is "never fabricate a profile that could
	-- overwrite real save data on next write," not a generic message that hides which one happened).
	LoadFailureKickMessage = "Failed to load your character data. Please rejoin in a moment.",
	CorruptDataKickMessage = "Your save data could not be read. Please contact support if this persists.",
	-- Every retry in the claim loop above still found a live foreign lock -- almost always means the
	-- OTHER server hasn't finished this player's own leave-save yet (a slow hop), rarely a genuinely
	-- stuck lock; either way the correct move is asking the player to wait a moment and rejoin, not
	-- risking two servers writing the same profile at once.
	LockHeldKickMessage = "Your character data is still finishing up on another server. Please wait a moment and rejoin.",
	-- The WriteGeneration backstop (Types.StoredPlayerProfile's own header) tripped during a session
	-- that had already passed the lock claim -- this server's copy of the profile can no longer be
	-- trusted to save safely, so it kicks rather than let further play accumulate on data that will
	-- never reach disk.
	StaleSessionKickMessage = "Your data was saved from another server session. Please rejoin.",
}

-- RivalrySystem (Server/Systems/RivalrySystem.lua) -- the query remotes are what make rivalry
-- standing actually reachable by a client rather than an internal-only leaderboard
-- (docs/architecture/2026-08-audit.md section 7.3).
Constants.Rivalry = {
	RemoteNames = {
		GetTopRivals = "Rivalry_GetTopRivals",
		GetStandingAgainst = "Rivalry_GetStandingAgainst",
	},
	-- Default page size for GetTopRivals when the caller doesn't request a specific limit -- small
	-- enough for a HUD/menu leaderboard panel to render without its own pagination.
	DefaultLeaderboardLimit = 10,
	-- Read-only query remotes, but still rate-limited for the same reason every other public remote
	-- in this codebase is (performance-optimization.md's call-budget rule) -- a modified client
	-- looping either remote costs nothing gameplay-wise but is still free spam otherwise.
	QueryMaxCallsPerSecond = 4,
}

-- Qi (Server/Systems/QiSystem.lua) -- the remote name joined every actual Qi tuning number in
-- Shared/QiConstants.lua, which now owns its feature's wire names as well as its numbers, per the
-- convention TierConstants.lua's header settled. Re-exported here so every existing
-- Constants.Qi.RemoteNames call site keeps working; new code should require that module directly.
Constants.Qi = require(ReplicatedStorage.Shared.QiConstants)

-- Meridian XP (Server/Systems/MeridianSystem.lua) -- the core progression currency
-- (project-vision.md/progression-systems.md: "Tier gates are earned through Meridian XP from PvP
-- wins"). MeridianSystem is the one system in this table whose balance number lives here rather
-- than a dedicated tuning module -- it's a single scalar, not a growing data surface the way Qi's
-- tuning is (see Shared/QiConstants.lua's own header for why that one earned its own file).
Constants.Meridian = {
	RemoteNames = {
		XPUpdated = "Progression_MeridianXPUpdated",
	},
	-- Flat Meridian XP awarded to the killer on every confirmed PvP kill (GameplayEvents.
	-- OnPlayerKilled). Still deliberately NOT scaled by the victim's tier -- but the reason has
	-- changed now that TierSystem exists and TierSystem.GetTier makes a live tier gap readable
	-- (docs/architecture/2026-08-audit.md section 7.2's underdog-scaling proposal is no longer
	-- gated on anything). It stays flat because scaling it is a BALANCE decision that wants the
	-- ladder's real pacing observed first: TierConstants.Tiers is priced in kills against this exact
	-- number (see that table's own pacing note), so changing this and the scaling rule in the same
	-- pass would retune the whole ladder blind. Scale it deliberately, against playtest data, not as
	-- a side effect of the tier gap becoming available.
	BaseXPPerKill = 25,
}

-- Character sheet (Server/Systems/CharacterSheetSystem.lua) -- the read-only replication of the
-- identity/standing half of a player's own profile to their own client, for the character menu's
-- Character tab (Client/UI/Screens/Menus/CharacterTab.lua). Remote names only, same as
-- Constants.Qi above: this feature has no balance surface of its own to tune. It owns no numbers
-- because it computes nothing -- every value it sends is a field PlayerDataSystem already holds.
--
-- Both a push AND a pull, for the same reason BountyMenu needs both: the push keeps an open panel
-- honest as corruption/standing/faction change, and the pull covers a client that opens the menu
-- long after its own profile-load push already fired and was dropped on the floor (nothing caches
-- an unheard RemoteEvent).
Constants.CharacterSheet = {
	RemoteNames = {
		-- Server -> owning client, on profile load and on any later change. Payload:
		-- Types.CharacterSheetPayload.
		SheetUpdated = "Character_SheetUpdated",
		-- Client -> server, no payload, returns Types.CharacterSheetPayload (or nil if the caller's
		-- profile genuinely isn't loaded yet -- never a fabricated blank sheet, which the panel would
		-- have no way to tell apart from a real one).
		GetSheet = "Character_GetSheet",
	},
	-- Same per-player query budget Constants.Rivalry/ArtConstants already use for their own read-only
	-- request remotes, and for the identical reason: a menu open costs one call, so anything beyond a
	-- few per second is a modified client spinning on it.
	RequestMaxCallsPerSecond = 4,
}

-- Start Menu / server-hop (Server/Systems/ServerHopSystem.lua, Client/StartMenu/StartMenuClient.lua
-- + UI/Screens/StartMenu/*). The very first client boot gate, ahead of onboarding -- Play requests a
-- fresh server via TeleportService:TeleportAsync back into this SAME game.PlaceId (Roblox always
-- resolves that to a different running server), not a separate Place -- see StartMenuClient.lua's
-- own header for how a player who just arrived via a Play click is told apart from one who joined
-- this server directly.
Constants.StartMenu = {
	RemoteNames = {
		RequestTeleport = "StartMenu_RequestTeleport",
	},
	-- ServerHopSystem's own `pendingByPlayer` guard only rejects a concurrent duplicate invoke (a
	-- second call racing one already in flight) -- it does nothing about a client that waits for
	-- each TeleportAsync to fail/return and immediately fires another, which a rate limiter closes
	-- the same way every other public remote in this codebase (BugReportSystem's
	-- SubmitMaxCallsPerSecond, Constants.Settings.MaxCallsPerSecondPerPlayer) already does for its
	-- own handler.
	RequestTeleportMaxCallsPerSecond = 1,
	-- Studio-only dev convenience, gated by RunService:IsStudio() at the call site (StartMenuClient.
	-- lua) -- ordinary Play Solo has nothing for TeleportAsync to actually teleport INTO (there's no
	-- second server), so leaving the real Start Menu up would strand every Studio playtest on a
	-- button that can never succeed. True skips the Start Menu entirely when testing in Studio;
	-- flip to false to test the Start Menu screen itself (its layout/hover/error states) without
	-- needing a real teleport to succeed. Never consulted outside RunService:IsStudio() == true, so
	-- this can never affect a live server regardless of its value.
	SkipInStudio = true,
}

-- First-time-player onboarding / character creation -- lifted out to Shared/
-- CharacterCreationConstants.lua, which carries the full rationale (including why the derived
-- AttributeFloors block had to travel with the table it is derived from). Re-exported here so
-- every existing Constants.CharacterCreation.X call site keeps working; new code should require
-- that module directly.
Constants.CharacterCreation = require(ReplicatedStorage.Shared.CharacterCreationConstants)

-- Cinematic intro / awakening sequence (Client/Intro/IntroClient.lua + IntroCamera.lua +
-- VisionEffects.lua + BlackScreen.lua). A DISTINCT table from Constants.CharacterCreation despite
-- sharing one player flow -- CharacterCreation owns race/attribute/name validation and the
-- Threshold<->arrival teleport, this table owns purely the CAMERA/FX/animation staging wrapped
-- around it (ground pose -> cinematic pan -> [character creation] -> black screen -> teleport ->
-- first-person reveal -> get-up -> greeting), the same "distinct tuning surface, distinct table"
-- split Constants.BugReport/Constants.CharacterCreation's own headers already establish for each
-- other.
Constants.Intro = {
	-- Placeholder ids -- no lying-down/get-up clips have been authored yet (explicitly deferred by
	-- the user this pass). Reuses the SAME already-user-supplied placeholder Constants.Flight.
	-- AnimationIds shares across its own six unauthored slots, rather than fabricating a new id --
	-- this codebase never guesses an asset id (see CombatAudio.lua/VitalIcon.lua's headers). Swap
	-- either line to a real id later with no code change.
	AnimationIds = {
		LyingDown = "rbxassetid://125167812303491",
		GetUp = "rbxassetid://125167812303491",
	} :: { [string]: string },

	-- Camera staging (IntroCamera.lua). Every angle is in DEGREES (converted to radians at the one
	-- call site that needs it) -- easier to eyeball/retune than raw radians, matching this table's
	-- role as the thing a later in-Studio pass will actually adjust by feel.
	Camera = {
		-- Ground-level lying POV the cinematic opens on (and the first-person anchor after teleport
		-- returns to) -- a shallow height above the character's own root position (roughly chest/eye
		-- height while prone) looking steeply up, the same "point the camera at the sky" framing the
		-- pre-rework OnboardingClient.pointCameraAtSky established (now owned here instead).
		GroundHeightOffset = 1.5,
		GroundLookAngleDegrees = -78,
		-- The held overhead composition the cinematic pans up INTO, timed against the cinematic's
		-- own elapsed/duration fraction (Constants.CharacterCreation.CinematicDurationSeconds) --
		-- see IntroCamera.UpdateCinematicProgress. Held through character creation once reached.
		OverheadHeightOffset = 22,
		OverheadLookAngleDegrees = 80,
		-- Slow ambient yaw drift, held for the WHOLE cinematic + overhead-hold window -- same
		-- "a static shot reads as frozen/broken, not deliberate" reasoning pointCameraAtSky's own
		-- comment gave for its identical drift.
		OverheadYawDriftDegreesPerSecond = 2,
		-- Symmetric ease-in-out exponent for the ground->overhead position/pitch lerp (2 = a
		-- standard smoothstep-shaped ease, not linear).
		PanEasingPower = 2,
		-- First-person eye anchor height above the character's root once teleported into the arrival
		-- world, still lying down -- deliberately close to GroundHeightOffset (same lying pose) but
		-- its own number since the two moments aren't guaranteed to want an identical height once a
		-- real LyingDown clip exists.
		FirstPersonEyeHeightOffset = 1,
		-- Get-up camera follow: eases from the first-person lying anchor (still looking up) to a
		-- level, standing eye-height view over this many seconds -- tuned against the placeholder
		-- clip's own arbitrary length for now; retune once GetUp is a real authored animation with a
		-- real length to match.
		GetUpFollowDurationSeconds = 1.8,
		GetUpFollowStandingHeightOffset = 5,
	},

	-- First-person blur/blink reveal (VisionEffects.lua) -- a Lighting.ColorCorrectionEffect +
	-- BlurEffect pair, same asset-free approach and DipBrightness/DipSaturation/*Seconds shape as
	-- Constants.FX.Stun/Death, extended into a multi-stage sequence: an instant blackout snap (timed
	-- under BlackScreen's own opaque UI cover, so the snap itself is never seen), two partial
	-- "eyes cracking open" reveals each followed by a quick re-dip ("blink") back toward the
	-- blackout values, then one final ease to fully neutral.
	Vision = {
		BlackoutBrightness = -0.75,
		BlackoutSaturation = -0.9,
		BlackoutBlurSize = 48,
		-- How long the blackout holds (BlackScreen still opaque) before the reveal begins.
		BlackHoldSeconds = 1,

		Reveal1Brightness = -0.35,
		Reveal1Saturation = -0.5,
		Reveal1BlurSize = 18,
		Reveal1DurationSeconds = 0.9,
		Blink1DurationSeconds = 0.16,

		Reveal2Brightness = -0.12,
		Reveal2Saturation = -0.2,
		Reveal2BlurSize = 5,
		Reveal2DurationSeconds = 0.8,
		Blink2DurationSeconds = 0.16,

		FinalClearDurationSeconds = 0.6,
	},

	-- Greeting banner (reuses UI/Components/PostureBreakBanner.lua's generic StatusBanner directly --
	-- no new banner component). How long it holds before IntroClient.lua clears it.
	Greeting = {
		HoldSeconds = 3.5,
	},
}

-- Player respawn after death (Server/Systems/RespawnSystem.lua). Players.CharacterAutoLoads is
-- false (default.project.json), so Roblox never re-spawns anyone on its own -- CharacterCreation
-- System.lua owns only this SESSION'S FIRST Player:LoadCharacter() call, and every death after that
-- needs an explicit respawn or the player is stuck as a corpse for the rest of the session. These
-- are that path's tunables; see RespawnSystem.lua's own header for the ownership reasoning.
Constants.Respawn = {
	-- Seconds between a confirmed death (CombatSystem.OnPlayerKilled) and the replacement character
	-- being loaded. Long enough for the death feedback beat to land -- the killcam/death feedback
	-- CombatClient.lua already renders off the "Death" Combat_FeedbackEvent -- without turning a
	-- heavy-PvP death into a punitive wait, per combat-philosophy.md's "death is a setback, not a
	-- session-ender" framing. Matches the 3s Constants.Debug.TrainingDummy/TrainingBot.RespawnDelay
	-- already use for their own defeat-to-replacement gap, deliberately: a player and a sparring
	-- partner returning on the same cadence keeps duel pacing consistent.
	DelaySeconds = 3,
}

-- Player-facing bug report feature (Server/Systems/BugReportSystem.lua,
-- Client/BugReport/BugReportClient.lua, Client/UI/Screens/BugReport/init.lua). Unlike
-- Constants.Debug.DevMenu, this is NOT whitelist-gated -- every player can submit. The two ADMIN
-- remote names (list/triage) live in Constants.Debug.DevMenu.RemoteNames instead, since
-- DevMenuSystem is what creates/handles those -- see that table's own comment.
Constants.BugReport = {
	Categories = { "Bug", "Exploit", "Suggestion", "Other" } :: { Types.BugReportCategory },

	-- Every valid Status value, in triage order -- BugReportSystem derives its STATUS_SET
	-- validation table from this the same way it already derives CATEGORY_SET from Categories
	-- above, and the admin Reports tab's status filter/selector both iterate this instead of
	-- hand-listing the four strings a second time.
	Statuses = { "Open", "InProgress", "Resolved", "Dismissed" } :: { Types.BugReportStatus },

	-- Admin-settable severity, lowest to highest -- BugReportSystem.SetPriority validates against
	-- this set; the Reports tab's priority selector iterates it the same way it iterates Statuses
	-- above.
	Priorities = { "Low", "Normal", "High", "Urgent" } :: { Types.BugReportPriority },

	-- Default Priority for a freshly Submitted report -- an admin re-triages from here. Nothing
	-- about the reporter's chosen Category auto-escalates this (an Exploit report isn't assumed
	-- more urgent than a Suggestion just by category); that judgment call stays with the admin.
	DefaultPriority = "Normal" :: Types.BugReportPriority,

	DescriptionMinLength = 10,
	DescriptionMaxLength = 1000,

	-- Internal triage note length cap (BugReportSystem.AddNote) -- short by design, a coordination
	-- breadcrumb, not a second description field.
	NoteMaxLength = 300,

	-- Anti-spam: a player may only successfully submit once per this many seconds
	-- (BugReportSystem's own per-player cooldown tracking, distinct from the generic
	-- per-second RateLimiter bucket below -- that one catches a client hammering the remote
	-- itself, e.g. a modified client retrying in a tight loop, before the cooldown check even runs).
	SubmitCooldownSeconds = 60,
	SubmitMaxCallsPerSecond = 2,

	-- Admin list pagination page size (BugReportSystem.ListReports / GetSortedAsync pageSize).
	ListPageSize = 20,

	-- DataStore names moved to ServerScriptService/Server/Config/StorageConfig.lua (they replicated
	-- to clients from here, where they are useless to legitimate code and pure reconnaissance
	-- otherwise). The version-suffix convention this table established lives on there. Retry/backoff
	-- tuning above stays here -- only the store identifiers moved.

	-- Seconds a submission confirmation/error message stays visible before the form auto-clears its
	-- status line -- same idea as Constants.Debug.DevMenu.StatusClearDelaySeconds.
	ConfirmationClearDelaySeconds = 3,

	-- Public remote BugReportSystem itself creates/handles (any player may call this -- no admin
	-- check).
	RemoteNames = {
		Submit = "BugReport_Submit",
	},
}

-- THERE IS NO Constants.Moderation. Player moderation (Server/Systems/ModerationSystem.lua) has no
-- tunable of its own left in this file: its two DataStore names moved to
-- Server/Config/StorageConfig.lua (they replicated to clients from here, where they are useless to
-- legitimate code and pure reconnaissance otherwise), its remote names live in
-- Constants.Debug.DevMenu.RemoteNames, and its retry policy is now the shared
-- Constants.Storage.RetryPolicy above. What was left behind was a table containing two comments and
-- no fields, still being read into a `local Config` that nothing indexed.

-- The two admin content editors' own tuning (Move Creation System + the shared Race Traits /
-- Bloodline editor) was lifted out to Shared/Authoring/EditorConstants.lua, which carries the
-- rationale -- chiefly that KitEditor is deliberately kept parallel to MoveEditor field-for-field,
-- and parallel tables are cheaper to keep parallel side by side. Each name re-exports its own
-- sub-table, so neither widened; new code should require that module directly.
local EditorConstants = require(ReplicatedStorage.Shared.Authoring.EditorConstants)
Constants.MoveEditor = EditorConstants.MoveEditor
Constants.KitEditor = EditorConstants.KitEditor

-- The kit layer's shared runtime config (the one Active-ability remote pair, its rate limit, and
-- the authoring bounds both content managers validate against) moved to Shared/Kit/KitConstants
-- .lua, beside the KitTypes it bounds and the KitValidation that enforces them -- NOT in with the
-- two editors above, since a runtime wire name does not belong in a file called EditorConstants.
-- Re-exported here so every existing Constants.Kit.X call site keeps working.
Constants.Kit = require(ReplicatedStorage.Shared.Kit.KitConstants)

-- Live Admin Console (F5) -- whitelist-gated, same trust model as Constants.Debug.DevMenu/
-- Constants.MoveEditor above: every remote below is gated by LiveConsoleSystem.lua's own
-- checkLiveConsolePreconditions (AdminConfig.AuthorizedUserIds + a dedicated rate-limit bucket),
-- mirroring DevMenuSystem.lua's checkDevMenuPreconditions exactly. Unlike DevMenu/MoveEditor this
-- is NOT Studio-only tooling wrapped around Studio-only data -- it exists specifically to work in a
-- live server, where Shared/Logger.lua's own Output gate (RunService:IsStudio()) correctly stays
-- silent. See Logger.lua's own header for how its always-on capture buffer makes that safe.
Constants.LiveConsole = {
	RemoteNames = {
		-- RemoteFunction, fired when the panel actually opens (not eagerly at boot) -- doubles as the
		-- authorization check AND fetches a fresh Logger.GetBufferSnapshot() at that exact moment, so
		-- the console never opens on a snapshot that went stale while the panel sat closed.
		Subscribe = "LiveConsole_Subscribe",
		-- Fire-and-forget (RemoteEvent, no response needed) -- tells the server the admin's console
		-- just closed, so the flush loop stops pushing to them. Same "SetEditorOpen" idiom
		-- Constants.MoveEditor.RemoteNames uses for its own open/close signal above; no
		-- precondition/rate-limit check on this one, matching RateLimiter.lua's own guidance that a
		-- "stop" action should never be blocked.
		Unsubscribe = "LiveConsole_Unsubscribe",
		-- Server -> subscribed clients only (never FireAllClients -- see LiveConsoleSystem.lua's own
		-- header for why a live log stream must never broadcast to non-admins). Payload: a batched
		-- array of Types.LogEntry, flushed on the interval below rather than once per captured entry.
		Stream = "LiveConsole_Stream",
	},
	-- How often LiveConsoleSystem.lua's flush loop pushes newly-captured entries to subscribers,
	-- regardless of how fast logs are actually arriving -- caps this feature at 4 pushes/sec/admin
	-- no matter the log volume, independent of Logger.lua's own per-message Output rate limit.
	StreamFlushIntervalSeconds = 0.25,
	-- Client-side render cap (Client/DevTools/LiveConsole/LiveConsoleClient.lua) -- oldest rendered lines are
	-- trimmed past this so a long-open console can't grow its own UI list unbounded. Kept small
	-- (not the server capture buffer's size) because appendEntries clones this many entries on every
	-- single log line while the panel is open, and nobody reads 1000 lines in a scrolling panel.
	ClientRenderCap = 200,
	-- Hard ceiling on how many entries a single Stream push may carry (LiveConsoleSystem.lua's
	-- pendingBatch). StreamFlushIntervalSeconds above caps how OFTEN this feature sends; nothing
	-- capped how BIG a send was, and the two are not the same protection. Log volume inside one
	-- 0.25s window is bounded only by how many distinct (scope, level, message) triples exist --
	-- Logger's own MaxRepeatsPerSecond is per-triple, and there are hundreds of them -- so a genuine
	-- incident (the exact moment an admin has the console open) is when the batch is largest, and an
	-- unbounded batch would make the one remote meant to help diagnose a struggling server the
	-- largest payload it sends. Past this count the oldest pending entries are dropped and the push
	-- carries a synthetic "N entries dropped" line, so the admin is told the feed is lossy rather
	-- than quietly shown a gap. Sized above ClientRenderCap so a full batch still fills the panel.
	StreamBatchCap = 300,
}

-- Custom shift-lock camera tunables (Client/Camera/ShiftLockCamera.lua) -- combat-philosophy.md's
-- "Established systems" list names combat camera behavior as bespoke, not default Roblox behavior.
-- Client-only data living in Constants.lua for the same reason Keybinds above does: static tunable
-- defaults every client module should agree on, never authoritative state, never crosses
-- NetworkBridge.
Constants.Camera = {
	ShiftLock = {
		-- Over-the-right-shoulder framing while shift-locked (applied via Humanoid.CameraOffset,
		-- so default-camera zoom/collision keep working). X is the sideways shoulder distance
		-- (positive = right, matching the engine's own 1.75); the small Y lift keeps the
		-- character's head from sitting dead-center in front of the aim point.
		ShoulderOffset = Vector3.new(1.75, 0.5, 0),
		-- Exponential ease rate for CameraOffset toward/away from ShoulderOffset -- higher =
		-- snappier engage/release. Applied framerate-independently (alpha = 1 - e^(-rate * dt)).
		OffsetLerpSpeed = 10,
		-- Camera-to-root-part distance below which the shoulder offset backs off to zero -- at
		-- near-first-person zoom an off-center offset just shoves the camera into the character's
		-- own head/shoulder geometry. First person itself already locks the mouse and steers the
		-- character natively, so shift lock has nothing to add there.
		FirstPersonDistanceThreshold = 2,
	},

	-- Flight camera feel (Client/Camera/FlightCamera.lua) -- FOV scaling and CameraOffset chase
	-- pull-back with flight speed, plus an optional bank-matched roll. Lives beside ShiftLock above
	-- since both are camera-domain presentation tunables, not gameplay.
	Flight = {
		-- Max FOV increase (degrees) at full boosted speed, eased from whatever the camera's own FOV
		-- was when flight started (never assumes a hardcoded base FOV).
		FOVMaxDeltaAtBoost = 12,
		FOVEaseSpeed = 6,
		-- Extra backward CameraOffset (studs) at max speed -- a chase pull-back so fast flight reads
		-- as fast without needing to touch actual Camera.CFrame math.
		ChasePullBackMaxStuds = 4,
		ChaseEaseSpeed = 8,
		-- Fraction of the character's OWN bank angle (Constants.Flight.MaxBankAngleDegrees) mirrored
		-- onto camera roll -- 0 disables it outright without touching call sites.
		BankRollFraction = 0.4,
	},

	-- Sprint/Slide FOV feel (Client/FX/FOVOffset.lua, driven from CombatClient.lua's Sprint
	-- input/predictSlide) -- both write through FOVOffset's named-slot composition rather than
	-- camera.FieldOfView directly, the same primitive SwingEffect's combat punch and Flight's zoom
	-- now also go through, so none of the three fight each other for the property.
	Sprint = {
		-- Continuous zoom-in while sprinting, eased in/out (FOVOffset.SetContinuous). Negative =
		-- narrower FOV (a focused "picking up speed" read) -- deliberately the opposite sign from
		-- Flight.FOVMaxDeltaAtBoost's widening convention, since flight and sprint are different
		-- feelings (soaring vs. sprinting).
		FOVDelta = -3,
		FOVEaseSpeed = 6,
	},
	Slide = {
		-- One-shot FOV kick at slide-start (FOVOffset.Punch), same punch-and-recover shape as
		-- SwingEffect's combat punch.
		FOVPunchDelta = -4,
		FOVPunchOutSeconds = 0.08,
		FOVPunchBackSeconds = 0.3,
	},

	-- Combat swing camera "punch" (Client/FX/SwingEffect.lua) -- a tiny asset-free FOV dip-and-recover
	-- that plays the instant the local player's OWN attack is confirmed accepted (Combat_AttackStarted),
	-- well before any hit-resolution feedback (damage number/sound, or nothing at all on a whiff) could
	-- possibly arrive. Routed through FOVOffset.lua's named "SwingPunch" slot (see that module's header)
	-- rather than tweening camera.FieldOfView directly, the same composition primitive Sprint/Slide
	-- above and Flight's own zoom now share so none of the three fight each other for the property. Were
	-- four module-local constants in SwingEffect.lua (BASIC_FOV_DELTA/HEAVY_FOV_DELTA/PUNCH_OUT_SECONDS/
	-- PUNCH_BACK_SECONDS) -- moved here as a sibling to Sprint/Slide since all three are camera-domain
	-- FOV presentation tunables living under Constants.Camera, not gameplay. Heavy gets a slightly
	-- larger punch than Basic so a Heavy throw reads as weightier through this one asset-free cue, tuned
	-- soft enough not to be disorienting on its own per docs/ui-ux-philosophy.md's Critical States rule
	-- ("controlled... not excessive"). Both legs use InOut easing (ramps up AND down smoothly, no
	-- instant-velocity snap at the start of either tween) rather than Out/In, which is what made the
	-- original punch read as a jolt rather than a dip.
	SwingPunch = {
		BasicFOVDelta = -0.6,
		HeavyFOVDelta = -1.2,
		PunchOutSeconds = 0.09,
		PunchBackSeconds = 0.22,
	},
}

-- Admin/dev-menu "Superman flight" tunables moved to Shared/Flight/FlightConstants.lua -- see that
-- file's own header for why. Server/DevMenu/FlightTuning.lua mutates that table live, at
-- runtime, from a live admin remote, which is exactly the kind of thing a module named "Constants"
-- should never be surprised to be doing (docs/architecture/2026-08-audit.md section 5, finding 3.4).

-- UI texture ids, kept HERE rather than inline at the one component that renders them, for exactly
-- one reason: Client/Loading/AssetPreloader.lua has to be able to read them at BOOT. The HUD's own
-- module is required before the preload gate, but its ids used to be literals inside HUD.new's body,
-- and HUD.new isn't called until UI.Mount() -- which runs AFTER the gate. So the three most
-- player-visible textures in the game were the ones cold-loading at the exact frame the loading
-- screen cleared. Lifting them to a table the preloader can sweep (the same raw-content-id path
-- Constants.Intro.AnimationIds already uses) is what makes them preloadable at all.
--
-- Not merged into Constants.FX below: these are UI chrome, not impact-feel tunables, and nothing
-- here is a tunable at all -- it's an asset manifest.
Constants.UI = {
	-- Vital gauge icons (Client/UI/Screens/HUD/init.lua, passed to Components/VitalIcon.lua's
	-- IconAssetId). Each was uploaded from the matching docs/design/icons/*.svg PNG export. Health
	-- was re-uploaded 2026-07-24 after the left-tilt + bolder-outline pass.
	--
	-- These are the TEXTURE ids. Each icon also has a wrapping Decal id, which is NOT usable as an
	-- ImageLabel.Image and must never be pasted here: health 108335358703553, qi 125861176852006,
	-- posture 71612968745315. Keeping the rejected ids named in this comment is deliberate -- it's
	-- the third time someone has had to rediscover which of the two ids Roblox hands back is the
	-- one an ImageLabel accepts.
	VitalIconIds = {
		Health = "rbxassetid://102020098775440",
		Qi = "rbxassetid://139165261554498",
		Posture = "rbxassetid://137723815865371",
	} :: { [string]: string },
}

-- Client-side presentation tuning -- lifted out to Shared/FXConstants.lua. Re-exported here so
-- every existing Constants.FX.X call site keeps working; new code should require that module
-- directly.
Constants.FX = require(ReplicatedStorage.Shared.FXConstants)

-- The run system's presentation tables (Footsteps/StageOnset/Animation) were absorbed into
-- Shared/Run/RunConstants.lua, which already owned the Stages ladder they are keyed by -- see
-- that file for why, and for the one type annotation the move had to give up. Re-exported here
-- so every existing Constants.Run.X call site keeps working; new code should require that module
-- directly.
Constants.Run = require(ReplicatedStorage.Shared.Run.RunConstants)

-- Hand-authored combat content and physics-feel numbers (weapon move catalog, DashPunch/DashHit/
-- AirSlam, AirCombo, Finisher/Ragdoll physics, AnimationIds, Sound) moved to
-- Shared/Combat/CombatConstants.lua -- see that file's own header for why. Server/Combat/
-- DefaultMoveRegistry.lua mutates that table live, at runtime, from the Move Editor's admin
-- remotes, which is exactly the kind of thing a module named "Constants" should never be surprised
-- to be doing (docs/architecture/2026-08-audit.md section 5, finding 3.4).

return Constants
