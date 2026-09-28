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
-- No Types require any more: every section that cast through one (Keybinds, CharacterCreation,
-- BugReport) now lives in its own module and carries that require itself. What is left here is
-- plain data and re-exports.

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
	-- HISTORICAL: neither number here has a reader since the deleted CombatSystem.lua; the live
	-- buckets are per System (AttackConstants.Network, DefenseConstants.Network -- Feint has its own,
	-- AttackConstants.Network.MaxFeintsPerSecondPerPlayer). The reasoning below still holds for them.
	-- CombatSystem.lua's defensiveRateLimiter gated FOUR distinct actions off one counter -- Feint,
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

-- PlayerData -- lifted out to Shared/PlayerDataConstants.lua; see that file's header. Re-exported here so every
-- existing Constants.PlayerData.X call site keeps working; new code should require it directly.
Constants.PlayerData = require(ReplicatedStorage.Shared.PlayerDataConstants)

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
	-- Flat Meridian XP awarded to the killer on every confirmed, attributed PvP kill (PlayerDeathSystem
	-- -> PlayerKilled -> RewardSystem -> ProgressionSystem -> MeridianSystem.AwardKillXP, the one
	-- reader). Still deliberately NOT scaled by the victim's tier -- but the reason has
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

-- StartMenu -- lifted out to Shared/StartMenuConstants.lua; see that file's header. Re-exported here so every
-- existing Constants.StartMenu.X call site keeps working; new code should require it directly.
Constants.StartMenu = require(ReplicatedStorage.Shared.StartMenuConstants)

-- First-time-player onboarding / character creation -- lifted out to Shared/
-- CharacterCreationConstants.lua, which carries the full rationale (including why the derived
-- AttributeFloors block had to travel with the table it is derived from). Re-exported here so
-- every existing Constants.CharacterCreation.X call site keeps working; new code should require
-- that module directly.
Constants.CharacterCreation = require(ReplicatedStorage.Shared.CharacterCreationConstants)

-- Intro -- lifted out to Shared/IntroConstants.lua; see that file's header. Re-exported here so every
-- existing Constants.Intro.X call site keeps working; new code should require it directly.
Constants.Intro = require(ReplicatedStorage.Shared.IntroConstants)

-- Player respawn after death (Server/Systems/RespawnSystem.lua). Players.CharacterAutoLoads is
-- false (default.project.json), so Roblox never re-spawns anyone on its own -- CharacterCreation
-- System.lua owns only this SESSION'S FIRST Player:LoadCharacter() call, and every death after that
-- needs an explicit respawn or the player is stuck as a corpse for the rest of the session. These
-- are that path's tunables; see RespawnSystem.lua's own header for the ownership reasoning.
Constants.Respawn = {
	-- Seconds between a confirmed death (GameplayEvents.PlayerKilled, published by PlayerDeathSystem)
	-- and the replacement character being loaded. Long enough for a death to register as a beat
	-- without turning a heavy-PvP death into a punitive wait, per combat-philosophy.md's "death is a setback, not a
	-- session-ender" framing. Matches the 3s Constants.Debug.TrainingDummy/TrainingBot.RespawnDelay
	-- already use for their own defeat-to-replacement gap, deliberately: a player and a sparring
	-- partner returning on the same cadence keeps duel pacing consistent.
	DelaySeconds = 3,
}

-- BugReport -- lifted out to Shared/BugReportConstants.lua; see that file's header. Re-exported here so every
-- existing Constants.BugReport.X call site keeps working; new code should require it directly.
Constants.BugReport = require(ReplicatedStorage.Shared.BugReportConstants)

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

-- LiveConsole -- lifted out to Shared/LiveConsoleConstants.lua; see that file's header. Re-exported here so every
-- existing Constants.LiveConsole.X call site keeps working; new code should require it directly.
Constants.LiveConsole = require(ReplicatedStorage.Shared.LiveConsoleConstants)

-- Camera -- lifted out to Shared/CameraConstants.lua; see that file's header. Re-exported here so every
-- existing Constants.Camera.X call site keeps working; new code should require it directly.
Constants.Camera = require(ReplicatedStorage.Shared.CameraConstants)

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
