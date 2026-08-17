--!strict
--[[
	Constants.lua

	Owns: every tunable/fixed number and named lookup table referenced by more than one system --
	single source of truth per engineering-standards.md. If a system needs a shared number, it
	imports it from here rather than hardcoding it locally.

	Most balance numbers (tier XP thresholds, bloodline/art costs) are still NOT populated -- those
	remain a technical-design pass owned by each system's own design work (TierSystem, ArtSystem,
	etc.), not invented here as placeholders. Constants.Combat is the one exception: CombatSystem's
	first-pass technical tunables are populated below (see that table's own header comment for why
	first-pass engineering defaults are populated while other systems' balance numbers aren't).
	Everything else here is canon that's already settled: fixed content counts and approved budgets.
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

-- Studio-only diagnostics config for Logger.lua -- NOT gameplay logic, NOT a balance/tunable
-- table like Constants.Combat below, and read by nothing except that one module. See Logger.lua's
-- header for the exact production-safety contract: a log only ever prints when
-- RunService:IsStudio() AND Enabled are both true, so shipping this with Enabled = true is safe --
-- it does nothing outside Studio regardless of this table's contents.
Constants.Debug = {
	Logging = {
		-- Master switch. Required in addition to RunService:IsStudio() -- see Logger.lua's header
		-- for why this isn't a live-server override.
		Enabled = true,
		-- Minimum level that actually prints: "Trace" | "Debug" | "Info" | "Warn" | "Error" | "Off".
		-- "Off" silences everything regardless of Enabled/Scopes.
		Level = "Debug",
		-- Allowlist: a scope only prints if its name is a key here mapped to `true`. Add a scope
		-- name here (matching the string passed to Logger.scope(...) at each module's call site)
		-- to see its logs; remove/flip false to silence it without touching that module's code.
		Scopes = {
			CombatClient = true,
			CombatSystem = true,
			NetworkBridge = true,
			ClientState = true,
			UI = true,
			Main = true,
			DevMenuSystem = true,
			DevMenuClient = true,
			KeybindManager = true,
			SoundManager = true,
			StunEffect = true,
			SwingEffect = true,
			CombatAnimator = true,
			TrainingBotSystem = true,
			FlightController = true,
			BugReportSystem = true,
			BugReportClient = true,
			ModerationSystem = true,
			AnnouncementClient = true,
			SpectateController = true,
			CharacterCreationSystem = true,
			OnboardingClient = true,
			ChamferedSurface = true,
			HotbarMoveClient = true,
			SettingsClient = true,
			SettingsSystem = true,
			-- Parkour System. ParkourController/ParkourSystem log transitions and rejections; the other
			-- three are quiet by design (a warning on a failed animation load, a dropped report, a
			-- kinematic frame with no path) and are listed so those warnings are visible when they do
			-- fire rather than needing this table edited mid-debugging.
			ParkourController = true,
			ParkourSystem = true,
			ParkourNetwork = true,
			ParkourAnimator = true,
			ParkourMotor = true,
			ParkourInput = true,
			ParkourDebug = true,
			-- Standalone hitbox engine. Quiet by default at the module's own level
			-- (HitboxEngineConstants.Debug.Enabled gates its per-swing logging, because anything logged
			-- per sample at 120Hz is a performance problem of its own), so this entry exists so its
			-- warnings -- a broadphase saturating, a consumer's OnHit callback erroring, a definition
			-- the sanitiser had to correct -- are visible when they do fire.
			HitboxEngine = true,
			-- Defense System (block/parry/guard). Same reasoning as HitboxEngine above -- its own
			-- DefenseConstants.Debug.Enabled gates the high-frequency per-contact logging, so this entry
			-- is what makes its ordinary Init/lifecycle lines and state-transition logs visible at all.
			DefenseSystem = true,
			DefenseClient = true,
			-- Damage System (health, guard pressure, hitstun). Was MISSING from this table since it was
			-- built, which meant every line it logged -- including its Init line and its "resolved a
			-- contact for an attack with no catalogue entry" diagnostic, the single most useful thing to
			-- see when hits land and nobody takes damage -- was silently swallowed by Logger.lua's own
			-- scope filter regardless of Level. The same gap the Run System entries below were added to
			-- close, found the same way: a whole layer being invisible in Output while debugging it.
			DamageSystem = true,
			-- Parry window resolution. Quiet in the ordinary case and FAIL-CLOSED in the interesting
			-- one: a parry animation missing its ParryStart/ParryClose markers arms nothing, and the
			-- warning saying so is the only signal that a parry key is being pressed and doing nothing.
			ParryWindows = true,
			-- The shared animation claim/layer arbitrator, now that both DefenseClient and
			-- AttackInputClient drive their clips through it. Its warnings (a clip that would not load,
			-- a rig whose repair budget ran out) are how "my swing plays no animation" is told apart
			-- from "my swing has no animation authored" -- see Shared/Attack/AttackAnimations.lua.
			AnimationManager = true,
			-- Attack layer (the request/gating/buffering half, and its client input half). Same
			-- reasoning as HitboxEngine/DefenseSystem above: AttackConstants.Debug.Enabled gates the
			-- per-press logging on its own, so these entries exist so the Init/lifecycle lines and the
			-- genuine warnings (a press arriving before the remote resolved, a move that vanished from
			-- the registry between resolution and throw) are visible at all. Replaces the
			-- TestAttackHarness/TestAttackHarnessClient pair, both deleted with the real layer's
			-- arrival.
			AttackRequestSystem = true,
			AttackInputClient = true,
			CombatFeedbackClient = true,
			-- The catalogue's own "move projected with corrections" warning is production-loud by
			-- design (see AttackCatalog.lua's own note on why it is deduped rather than debug-gated),
			-- and this is the entry that lets it through the scope filter at all.
			AttackCatalog = true,
			-- The Basic-string marker-driven windup override (Shared/Attack/AttackWindows.lua) --
			-- without this, its boot-time "M1 windup is marker-driven" / "...using the hardcoded
			-- Constants.lua value" pair (AttackRequestSystem.Init's own warm pass) would be the exact
			-- same silent-swallow gap DamageSystem/ParryWindows/AnimationManager/the Run System trio
			-- below each hit before being found and added here.
			AttackWindows = true,
			-- Run System. All three had a Logger.scope(...) call from the moment they were written but
			-- were never added here -- every logger:info/debug/warn call from RunController, RunSystem
			-- and RunAudio has been silently swallowed by Logger.lua's own scope filter since the run
			-- system was built, regardless of Constants.Debug.Logging.Level. Found only because the
			-- run/ledge system was otherwise completely invisible in Studio Output while debugging it.
			RunController = true,
			RunSystem = true,
			RunAudio = true,
			-- LedgeHanging is the one individual movement state with its own logger scope (every other
			-- state relies on ParkourController's own transition trace) -- see that module's own header
			-- for why the shimmy and the ledge-leap earned one.
			LedgeHanging = true,

			-- EVERY OTHER Logger.scope(...) call site in the codebase, added in one exhaustive sweep
			-- (grep every Logger.scope("...") in src/ against this table's own keys) rather than one
			-- gap at a time -- the same discovery method that found DamageSystem/ParryWindows/
			-- AnimationManager/the Run System trio above, just run to completion instead of stopping at
			-- the first few. Every one of these modules' logger:info/debug/warn/error calls were
			-- silently swallowed regardless of Level until now, with no error anywhere to say so --
			-- Logger.lua's own scope filter fails silent by design, which is exactly what makes a gap
			-- here invisible until someone goes looking for a specific module's missing Output lines.
			--
			-- Progression/meta systems.
			QiSystem = true,
			TierSystem = true,
			ArtSystem = true,
			ArtTreeManager = true,
			MeridianSystem = true,
			RivalrySystem = true,
			BountySystem = true,
			BountyMenu = true,
			PlayerDataSystem = true,
			CharacterSheetSystem = true,
			RespawnSystem = true,
			PlayerDeathSystem = true,
			ServerHopSystem = true,
			VersionWatchSystem = true,
			AdminActionSystem = true,
			ObjectStunResolver = true,
			-- Emotes.
			EmoteSystem = true,
			EmoteUnlockService = true,
			EmoteController = true,
			EmoteWheelClient = true,
			EmoteAnimator = true,
			-- Move Creation System.
			MoveEditorSystem = true,
			MoveEditorClient = true,
			-- Live Admin Console (F7). These two entries only gate their own Init/lifecycle lines
			-- printing to Studio Output -- the console's actual log FEED comes from Logger.lua's
			-- always-on capture buffer below, which is deliberately NOT gated by this table (or by
			-- Enabled/IsStudio at all) so it works in a live server too.
			LiveConsoleSystem = true,
			LiveConsoleClient = true,
			-- Shared/EngineLogCapture.lua's own lifecycle lines (connected/seeded from LogService).
			EngineLogCapture = true,
			-- Camera/FX (client).
			ShiftLockCamera = true,
			FlightCamera = true,
			CameraShake = true,
			CameraOffsetComposer = true,
			FOVOffset = true,
			HitStop = true,
			MovementVFX = true,
			DeathEffect = true,
			FlightVFX = true,
			FlightAnimator = true,
			-- Intro/onboarding/menus (client).
			IntroClient = true,
			IntroCamera = true,
			VisionEffects = true,
			LoadingClient = true,
			AssetPreloader = true,
			StartMenuClient = true,
			CharacterMenuClient = true,
			-- Spec-only, for the retry-logging cases in Tests/Shared/DataStoreRetry.spec.lua -- included
			-- for the same "every Logger.scope(...) in src/, no exceptions" completeness this sweep is
			-- for, not because a passing spec depends on its own Output being visible.
			DataStoreRetryTest = true,
		},
		-- Per (scope, level, message) cap, keyed off the static message text so a log site that
		-- fires every frame can't flood Output even at Trace -- see Logger.lua's rate limiter. Also
		-- gates the always-on console capture buffer below (same key, same window) for the identical
		-- flood-protection reason, independent of Enabled/IsStudio.
		MaxRepeatsPerSecond = 20,
		-- Fixed capacity of Logger.lua's always-on capture buffer (one per VM -- the server has its
		-- own, each client has its own), read once at require-time. Feeds
		-- Server/Systems/LiveConsoleSystem.lua's Subscribe snapshot and Client/LiveConsole/
		-- LiveConsoleClient.lua's local "My Client" tab -- NOT gated by Enabled/IsStudio/Level/Scope
		-- above (see Logger.lua's own header for why that split is safe). Oldest entries are evicted
		-- past this count; 1000 is generous enough to cover a genuine investigation window without
		-- an unbounded per-VM memory cost.
		ConsoleBufferSize = 1000,
	},

	-- Whitelist-gated developer tooling -- unlike Logging above, this is NOT Studio-only; it's
	-- meant to work in live servers too, since that's often exactly when a developer needs it.
	-- Safety comes entirely from the whitelist below plus DevMenuSystem.lua re-checking every
	-- request's Player.UserId server-side -- never from being hidden or from Studio-gating. See
	-- DevMenuSystem.lua's header for the full authorization contract.
	DevMenu = {
		-- AuthorizedUserIds moved to ServerScriptService/Server/Config/AdminConfig.lua. Everything in
		-- this file replicates to every client, so the roster of privileged accounts was readable by
		-- anyone with an instance explorer. Authorization never rested on that list being secret
		-- (DevMenuSystem re-checks server-side and always has), but publishing it bought nothing.
		-- DevMenuClient now asks the server whether to start instead of reading a local list.

		-- Seconds a dev-menu status message (DevMenuClient.lua) stays visible before auto-clearing.
		StatusClearDelaySeconds = 3,

		-- Roblox's own factory-default Humanoid.JumpPower -- the fallback CombatSystem.SetPlayerFrozen
		-- restores to on unfreeze if a player was somehow never actually frozen this life (defensive;
		-- the normal path restores the JumpPower captured at freeze-time instead, see
		-- CombatState.savedJumpPower's own header).
		DefaultJumpPower = 50,

		-- Speed Multiplier admin action (SetTargetSpeedMultiplier) -- preset buttons in the Admin tab's
		-- Character Utility section, rather than a free-typed number, so an admin can't accidentally
		-- set an absurd/negative value through a typo.
		SpeedMultiplierPresets = { 0.5, 1, 1.5, 2, 3 },

		-- Broadcast Announcement admin action -- an admin-authored message shown to every player
		-- (Client/Announcement/AnnouncementClient.lua). Deliberately NOT run through
		-- TextService:FilterStringAsync the way BugReportSystem.Submit's player-typed text is --
		-- this is trusted-staff-authored content (whitelist-gated same as every other admin action),
		-- not arbitrary player input, so the trust boundary that requires filtering doesn't apply here.
		AnnouncementMaxLength = 200,

		-- Seconds Client/Announcement/AnnouncementClient.lua's banner stays visible before
		-- auto-dismissing -- same "named duration, not a magic number at the call site" convention as
		-- StatusClearDelaySeconds above.
		AnnouncementDisplayDurationSeconds = 6,

		-- Tuning tab's Ability Slot Preview harness (ContentArea.lua) -- how long the "Run Cooldown
		-- Demo" button's fake countdown takes to drain from full to empty. Purely a local client-side
		-- animation duration for verifying AbilitySlot's cooldown-overlay/timer rendering ahead of
		-- ArtSystem; not tied to any real ability's actual cooldown length.
		AbilityPreviewCooldownDemoSeconds = 4,

		-- Shutdown Server admin action -- a second confirming press within this window (server-side
		-- armed state, not just a client UI flag) actually triggers the kick-all; the first press only
		-- arms it. SHUTDOWN_DELAY_SECONDS below is how long every player sees the warning banner
		-- before actually being kicked.
		ShutdownConfirmWindowSeconds = 10,
		ShutdownDelaySeconds = 10,

		-- Instant Restart Server admin action -- same two-press server-armed confirm SHAPE as
		-- ShutdownConfirmWindowSeconds above (DevMenuSystem.handleInstantRestartServer), but a
		-- DISTINCT, independently-tunable window (same "own constant even where two happen to
		-- match today" convention BanConfirmWindowSeconds/ResetPlayerDataConfirmWindowSeconds
		-- already establish): unlike Shutdown Server's ShutdownDelaySeconds countdown-warned kick,
		-- the second press here kicks immediately, no delay -- for an admin who just published a
		-- place update and wants THIS server cycled onto it right away rather than waiting out a
		-- countdown.
		InstantRestartConfirmWindowSeconds = 10,

		-- Ban Player admin action (Players tab roster row) -- UNLIKE ShutdownConfirmWindowSeconds
		-- above, this arm/confirm window is enforced ENTIRELY client-side (DevMenu/init.lua's
		-- playerRosterRow): a first press just shows "press again to confirm" and starts this local
		-- timer, a second press within the window is what actually fires BanPlayerRequested. Ban is
		-- permanent and DataStore-backed (survives rejoin) where Kick is cheap and reversible (a kicked
		-- player can just rejoin), so it earns the extra friction Kick doesn't need. No server-side
		-- state backs this window -- the server still authorizes/executes every Ban request on its own
		-- merits regardless of how the client arrived at sending it.
		BanConfirmWindowSeconds = 4,

		-- Reset Player Data admin action (Players tab roster row) -- same permanent/DataStore-backed
		-- reasoning as BanConfirmWindowSeconds above (arguably more severe: a wipe has no reversal
		-- path at all, where an admin can still un-ban or let a ban expire), so it gets the same
		-- two-press arm/confirm treatment. Kept as its own independently-tunable constant even though
		-- it starts equal to BanConfirmWindowSeconds -- same reasoning Constants.Combat.AirCombo's
		-- own tunables stay separate numbers even where two of them happen to match today.
		ResetPlayerDataConfirmWindowSeconds = 4,

		RemoteNames = {
			SpawnDummy = "DevMenu_SpawnDummy",
			SpawnTrainingBot = "DevMenu_SpawnTrainingBot",
			-- Admin actions -- all three target whichever player the requesting admin currently has
			-- locked on (CombatState.lockOnTarget), falling back to themselves if nothing's locked --
			-- reuses the existing lock-on system as the "who am I targeting" picker instead of a new
			-- player-select UI. See DevMenuSystem.lua's handleSetHealth/handleSetGodmode/
			-- handleSetFlight for the resolution.
			SetTargetHealth = "DevMenu_SetTargetHealth",
			SetTargetGodmode = "DevMenu_SetTargetGodmode",
			SetTargetFlight = "DevMenu_SetTargetFlight",
			-- Toggles Collide mode for an already-flying target (Client/DevMenu/FlightPhysics.lua) --
			-- see AdminActionSystem.SetFlightCollide's own header.
			SetTargetFlightCollide = "DevMenu_SetTargetFlightCollide",
			-- Live flight-feel tuner (Server/DevMenu/FlightTuning.lua) -- fetch-once/adjust/reset
			-- shape, scoped to Constants.Flight's own tunables. The equivalent live-tuner remotes for
			-- hand-authored attack timing/hitbox fields moved out of DevMenu entirely -- see the
			-- comment just below this block.
			ListFlightTuning = "DevMenu_ListFlightTuning",
			AdjustFlightTuning = "DevMenu_AdjustFlightTuning",
			ResetFlightTuning = "DevMenu_ResetFlightTuning",
			-- Live hitbox timing/full-field tuning for hand-authored (Basic/Heavy/Finisher weapon
			-- stages, DashPunch/DashHit/AirSlam) attacks moved out of DevMenu entirely -- it's now the
			-- Move Editor's "Default" moves section (Server/Combat/DefaultMoveRegistry.lua,
			-- Constants.MoveEditor.RemoteNames.ListDefaultMoves/UpdateDefaultMoveDraft/
			-- ResetDefaultMove below).
			-- Bug report triage (DevMenu/init.lua's "Reports" tab) -- handlers live in
			-- DevMenuSystem.lua but call straight into BugReportSystem.ListReports/UpdateStatus, the
			-- same "gate here, compute there" split as every other admin action above. The PUBLIC
			-- submit remote is a separate name, Constants.BugReport.RemoteNames.Submit, since
			-- BugReportSystem itself (not DevMenuSystem) creates/handles that one -- any player may
			-- call it, no whitelist check.
			ListBugReports = "DevMenu_ListBugReports",
			UpdateBugReportStatus = "DevMenu_UpdateBugReportStatus",
			-- Triage mutations added alongside UpdateBugReportStatus above -- same "gate here,
			-- compute in BugReportSystem" split, same admin-only home rather than
			-- Constants.BugReport.RemoteNames (that table is reserved for the PUBLIC submit remote
			-- only).
			AddBugReportNote = "DevMenu_AddBugReportNote",
			SetBugReportPriority = "DevMenu_SetBugReportPriority",
			AssignBugReport = "DevMenu_AssignBugReport",
			-- Teleports the requesting admin to wherever the report's reporter currently is IN THIS
			-- SERVER -- see DevMenuSystem.handleJumpToReporter's own header for why this doesn't
			-- reuse TeleportToTarget's lock-on resolution.
			JumpToReporter = "DevMenu_JumpToReporter",
			-- Teleportation -- all three apply to the requesting admin's own position/the resolved
			-- lock-on target's position (see resolveActionTarget), no player-select UI, same
			-- reasoning as every other admin action above.
			TeleportToTarget = "DevMenu_TeleportToTarget",
			BringTarget = "DevMenu_BringTarget",
			TeleportToCoordinates = "DevMenu_TeleportToCoordinates",
			-- Character utility.
			SetTargetFrozen = "DevMenu_SetTargetFrozen",
			SetTargetInvisible = "DevMenu_SetTargetInvisible",
			SetTargetSpeedMultiplier = "DevMenu_SetTargetSpeedMultiplier",
			ForceRespawnTarget = "DevMenu_ForceRespawnTarget",
			-- Server-wide tools. Announcement is a RemoteEvent (fired to EVERY client, not just the
			-- requesting admin), unlike every other name in this table -- see
			-- Client/Announcement/AnnouncementClient.lua, which (unlike DevMenuClient.lua) runs
			-- unconditionally for every player since the banner it drives isn't admin-only.
			BroadcastAnnouncement = "DevMenu_BroadcastAnnouncement",
			ShutdownServer = "DevMenu_ShutdownServer",
			-- Same two-press server-armed shape as ShutdownServer above, no countdown delay on
			-- confirm -- see InstantRestartConfirmWindowSeconds's own comment above.
			InstantRestartServer = "DevMenu_InstantRestartServer",
			-- Passive "a newer version has been published" fetch (Server/Systems/
			-- VersionWatchSystem.lua) -- fetch-once-on-open, same shape as GetHitboxDebug/
			-- GetSidebarStats below.
			GetServerVersionInfo = "DevMenu_GetServerVersionInfo",
			Announcement = "DevMenu_Announcement",
			-- Player roster ("Players" tab) -- fetch-on-open (the admin presses Refresh/opens the tab),
			-- not pushed on a timer/change, same trade-off ListBugReports already accepts: a stale
			-- roster snapshot a few seconds old is fine for triage, and a per-tick or per-join/leave
			-- push would be one more always-on remote for a panel most players never open.
			ListPlayers = "DevMenu_ListPlayers",
			-- Wipes cooldowns/combo/vitals-timers/air-combo state on a still-ALIVE target (no respawn)
			-- -- see CombatSystem.ResetCombatState's own header.
			ResetTargetCombatState = "DevMenu_ResetTargetCombatState",
			-- Moderation (Server/Systems/ModerationSystem.lua) -- targets an explicit UserId from a
			-- "Players" tab roster row, never the lock-on target (see DevMenuSystem.lua's
			-- resolveOptionalExplicitTarget/resolveTargetUserId for why these three don't go through
			-- resolveActionTarget the way every action above does).
			KickPlayer = "DevMenu_KickPlayer",
			BanPlayer = "DevMenu_BanPlayer",
			MutePlayer = "DevMenu_MutePlayer",
			-- Wipes a target's SAVED progression data back to a fresh profile
			-- (PlayerDataSystem.ResetProfile) -- deliberately grouped here with Kick/Ban/Mute above,
			-- not owned by ModerationSystem, but sharing their exact "explicit UserId from a roster
			-- row, never the lock-on target" reasoning: a data wipe is irreversible, at least as
			-- severe as Ban. See DevMenuSystem.lua's handleResetTargetPlayerData.
			ResetTargetPlayerData = "DevMenu_ResetTargetPlayerData",
			-- Reversible manual cheater-flag toggle (see ModerationSystem.lua's FlagSuspectedCheater/
			-- UnflagSuspectedCheater) -- same explicit-UserId-from-a-roster-row targeting as
			-- KickPlayer/BanPlayer/MutePlayer above, never the lock-on target.
			SetSuspectedCheater = "DevMenu_SetSuspectedCheater",
			-- Sidebar header stats (persistent Sidebar, Screens/DevMenu/Sidebar.lua) -- one combined
			-- RemoteFunction rather than folding into ListPlayers/ListBugReports, since neither of
			-- those two remotes' existing callers need the other's count.
			GetSidebarStats = "DevMenu_GetSidebarStats",
			-- Runtime hitbox-visualization toggle (Server/Combat/HitboxDebugState.lua) -- server-wide,
			-- not per-player (a rendered debug Part is a real Workspace object every nearby player
			-- already sees), works in Studio AND a published server. Get is fetched once on DevMenu
			-- open (Admin tab) the same "fetch-once, cache client-side" shape as GetSidebarStats.
			GetHitboxDebug = "DevMenu_GetHitboxDebug",
			SetHitboxDebug = "DevMenu_SetHitboxDebug",
			-- One-shot test trigger for the Emote System's roll path (Server/Systems/
			-- EmoteUnlockService.lua's RollEmote, "RareEmotes" pool only) -- see DevMenuSystem.
			-- handleRollEmote. Not a general-purpose "roll any pool" remote; this exists purely so a
			-- human tester can exercise GrantEmote/RollEmote end to end before AchievementSystem/a
			-- future quest or live-ops system calls RollEmote for real.
			RollEmote = "DevMenu_RollEmote",
		},
	},
}

-- Server publish-version watchdog (Server/Systems/VersionWatchSystem.lua) -- grouped under Debug
-- the same way TrainingDummy/TrainingBot below are: this is dev/ops-facing tooling (the Admin tab's
-- passive version-mismatch banner), not a gameplay tunable. Just the one number: how often a live
-- server re-bumps/re-reads the shared "highest booted version" DataStore key, so a long-lived server
-- eventually learns about a publish that happened after it started without needing a restart of its
-- own to find out. Minutes, not seconds -- this is advisory information for an admin deciding
-- whether to restart, not anything time-critical, so there's no reason to spend DataStore budget
-- polling it aggressively.
Constants.Debug.VersionWatch = {
	RefreshIntervalSeconds = 300,
}

-- Training dummy tunables -- CombatSystem.lua owns the dummy's actual combat behavior (it's a
-- real, hittable combat participant, not a static prop: swings resolve against it exactly like a
-- player, including posture break and death/respawn); these are just the first-pass numbers,
-- same spirit as Constants.Combat's own header. Grouped under Debug because the dummy itself is
-- dev-only tooling (only DevMenuSystem.lua can spawn one), not because these specific fields are
-- diagnostic flags.
Constants.Debug.TrainingDummy = {
	MaxHealth = 500,
	MaxPosture = 100,
	-- Seconds after a dummy is defeated before it's replaced with a fresh one at the same spawn
	-- point. A dead Humanoid can't be revived in place (Roblox's Dead HumanoidStateType is
	-- terminal), so "respawn" here means destroy-and-recreate, not heal-back-up -- see
	-- CombatSystem.lua's confirmDummyDeath.
	RespawnDelay = 3,
	-- Studs in front of the requesting player's HumanoidRootPart to spawn a new dummy.
	SpawnDistance = 8,
	-- Oldest active dummy is despawned to make room once this many exist at once -- keeps repeated
	-- dev menu use from growing Workspace unbounded without needing a separate despawn action.
	MaxActive = 5,
	-- After a finisher launches/ragdolls a dummy, how many seconds AFTER the ragdoll has recovered
	-- before the dummy is returned to its spawn point and its posture restored -- so it's a clean,
	-- repeatable target for practicing the combo/finisher (you see the full launch + ragdoll + get-up,
	-- then it comes back to you). See onHeartbeat's dummy loop.
	LaunchResetBufferSeconds = 1.5,
	-- Floating nameplate color (CombatSystem.lua's shared attachCombatantLabel, called from
	-- createDummy) -- amber/burnished-gold, the same swatch as Tokens.Color.Warning/the Posture vital,
	-- reading as a passive, non-threatening practice target rather than a live opponent (contrast
	-- Constants.Debug.TrainingBot.LabelColor's crimson below). Was an inline Color3.fromRGB literal
	-- right at the attachCombatantLabel call site in CombatSystem.lua with no cross-reference to its
	-- sibling TrainingBot color a few hundred lines below in that same file -- moved here alongside
	-- every other TrainingDummy tunable so the two colors live next to their respective "kind" data
	-- instead of as two unrelated-looking literals in the middle of spawn logic.
	LabelColor = Color3.fromRGB(199, 149, 34),
}

-- Training bot tunables -- AI-controlled practice opponents, distinct from the static dummy above
-- (see TrainingBotSystem.lua's header for the full design). Grouped under Debug for the same
-- reason as TrainingDummy: dev-only tooling, only spawnable via the whitelist-gated dev menu.
-- Bot vitals deliberately reuse Constants.Combat.MaxHealth/MaxPosture directly (not listed again
-- here) -- a training bot should feel like a real opponent, not an inflated punching bag like the
-- dummy.
Constants.Debug.TrainingBot = {
	-- Seconds after a bot is defeated before TrainingBotSystem.lua decides whether to respawn it --
	-- CombatSystem.lua does not auto-respawn bots the way it does dummies (see
	-- CombatSystem.OnTrainingBotKilled), since preset/weight bookkeeping lives in TrainingBotSystem,
	-- not here.
	RespawnDelay = 3,
	-- Studs in front of the requesting player's HumanoidRootPart to spawn a new bot.
	SpawnDistance = 8,
	-- A bot is a private sparring partner, not a squad -- one active bot per owning player, and it
	-- only ever targets its owner (see CombatSystem.lua's botsByOwner).
	MaxActivePerOwner = 1,
	-- How often (seconds) a bot's AI re-rolls its next weighted action (Attack/Block). Short enough
	-- to feel responsive, long enough to stay cheap across CombatSystem's existing Heartbeat tick.
	DecisionIntervalSeconds = 0.15,
	-- Delay (seconds) between a bot detecting its owner has entered an attack (Attacking flips true
	-- on the owner's CombatSnapshot) and the bot acting on that read -- the documented
	-- ai-design.md "reaction-time parameter" difficulty knob, and also what keeps a Parry-preset
	-- bot's timing beatable rather than superhuman (instant reaction would make most swings free
	-- parries given the authored parry window vs typical windup+active timing).
	ReactionTimeSeconds = 0.1,
	-- Server-side clamp ceiling for any single Custom weight component submitted by a client --
	-- relative weights only, not probabilities, so this just needs to be finite and reasonable.
	-- Never trust a submitted weight without clamping into [0, MaxCustomWeight] first (ai-design.md:
	-- "must not become a backdoor for client-authoritative combat state").
	MaxCustomWeight = 10,

	-- First-pass behavioral data, not a balance pass -- see combat-philosophy.md's Tuning process
	-- (free to move without design ceremony, same spirit as every other Constants.Combat number).
	-- Relative weights, not probabilities -- don't need to sum to 1. "Custom" deliberately has no
	-- entry here -- there's no sensible default custom weight set; see
	-- TrainingBotSystem.ValidatePresetRequest. Were module-local constants in TrainingBotSystem.lua;
	-- moved here per luau-coding-standards.md's "no magic numbers in system logic" alongside their
	-- siblings above.
	PresetWeights = {
		AttackOnly = { Attack = 1, Block = 0, Parry = 0, Reposition = 0 },
		BlockOnly = { Attack = 0, Block = 1, Parry = 0, Reposition = 0 },
		ParryOnly = { Attack = 0, Block = 0, Parry = 1, Reposition = 0 },
		FullFight = { Attack = 0.5, Block = 0.25, Parry = 0.15, Reposition = 0 },
		Aggressor = { Attack = 0.75, Block = 0.1, Parry = 0.15, Reposition = 0 },
		Turtle = { Attack = 0.1, Block = 0.6, Parry = 0.3, Reposition = 0 },
	},
	-- Fraction of accepted attacks that go Heavy rather than Basic -- a bot commits to the
	-- longer-telegraphed, more punishable option a minority of the time, same as a sensible player
	-- would, rather than an even split.
	HeavyAttackChance = 0.2,
	-- How much longer than the parry window itself a reactive Parry-preset press stays held before
	-- releasing again -- long enough that a hit landing right at the window's edge still resolves
	-- against a held block, short enough that the bot goes back to "exposed, hunting the next read"
	-- promptly rather than degrading into BlockOnly behavior.
	ParryHoldBufferSeconds = 0.05,
	-- Floating nameplate color (CombatSystem.lua's shared attachCombatantLabel, called from
	-- createTrainingBot) -- crimson, the same swatch as Tokens.VitalColor.Health, reading as a live, active
	-- opponent rather than the passive TrainingDummy above (Constants.Debug.TrainingDummy.LabelColor).
	-- Was an inline Color3.fromRGB literal right at the attachCombatantLabel call site -- moved here
	-- alongside every other TrainingBot tunable, same reasoning as TrainingDummy.LabelColor's own
	-- header.
	LabelColor = Color3.fromRGB(196, 48, 56),
}

-- Shared nameplate cosmetics for both TrainingDummy and TrainingBot labels (CombatSystem.lua's
-- attachCombatantLabel) -- LabelColor stays per-kind above; everything else about the billboard is
-- identical between the two.
Constants.Debug.CombatantLabel = {
	Size = UDim2.fromOffset(160, 36),
	StudsOffset = Vector3.new(0, 1, 0),
	TextSize = 18,
	TextStrokeTransparency = 0.4,
	Font = Enum.Font.GothamBold,
}

-- Fixed by canon (world-bible.md / progression-systems.md).
Constants.TierCount = 9
Constants.RaceCount = 4
Constants.BloodlineCount = 13

Constants.Factions = {
	Celestial = "Celestial",
	Demonic = "Demonic",
	Unbound = "Unbound",
}

Constants.Regions = {
	TheVoid = "TheVoid",
	TheMedianParadise = "TheMedianParadise",
	TheDemonicDisastrousLandscape = "TheDemonicDisastrousLandscape",
}

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

-- Networking-infrastructure tunables -- distinct from NetworkBudget above (that table is about
-- *how often* a remote can fire; this one is about *how long to wait* for one to exist at all).
Constants.Network = {
	-- WaitForChild timeout (seconds) for the handful of lookups that can't just trust an Instance is
	-- already there the instant it's asked for. Was SEVEN independently hand-typed literal `10`s with
	-- no shared name: Shared/NetworkBridge.lua's GetRemoteEvent/GetRemoteFunction (a client module
	-- requiring this before the server's own remote-creating System has necessarily finished booting
	-- on a slow server start), Server/Systems/CombatSystem.lua's onCharacterAdded loading a fresh
	-- Humanoid/HumanoidRootPart, and four client CharacterAdded handlers waiting on that same pair of
	-- parts (Client/Camera/FlightCamera.lua, Client/Camera/ShiftLockCamera.lua, Client/DevMenu/
	-- FlightController.lua, Client/DevMenu/DevMenuClient.lua). All seven were tuned to agree on 10s by
	-- coincidence, not by reference to a shared source -- a future "give slow connections more slack"
	-- pass would otherwise have had to hunt down and edit every call site instead of one number. Not
	-- every WaitForChild in the codebase reads this: Client/Combat/CombatClient.lua's own Humanoid wait
	-- uses a deliberately SHORTER 5s (a distinct tuning choice for that one call site, not a candidate
	-- for merging into this shared value).
	WaitForChildTimeoutSeconds = 10,
}

-- Humanoid Attribute names read/written by more than one system (server and client both need to
-- agree on the exact string for replication to carry the intended meaning) -- named once here
-- instead of independently retyped at every SetAttribute/GetAttribute call site.
Constants.Attributes = {
	Flying = "Flying",
	Godmode = "Godmode",
	FlyCollide = "FlyCollide",
	RootControlLocked = "RootControlLocked",
	BonusWalkSpeed = "BonusWalkSpeed",
	-- Admin-only movement lock (DevMenuSystem.lua's SetTargetFrozen) -- Movement.
	-- ComputeDesiredWalkSpeed reads this directly (same "external override, read as an Attribute"
	-- shape as Flying above), pinned to top priority, above even Flying.
	Frozen = "Frozen",
	-- Admin-only WalkSpeed scale (DevMenuSystem.lua's SetTargetSpeedMultiplier) -- read by Movement.
	-- ComputeDesiredWalkSpeed as a multiplier on `base`, same "per-player Humanoid Attribute" shape
	-- BonusWalkSpeed already uses, defaulting to 1 (no change) when unset.
	SpeedMultiplier = "SpeedMultiplier",
	-- Admin-only invisibility (DevMenuSystem.lua's SetTargetInvisible) -- mirrored here purely so
	-- DevMenuClient.lua can reflect live state in the Admin tab UI, same as Godmode; the actual
	-- effect is a direct Transparency write on every BasePart/Decal (CombatSystem.
	-- SetPlayerInvisible), not something Movement.lua or any per-frame resolver reads.
	Invisible = "Invisible",
	-- Emote System (Server/Systems/EmoteSystem.lua) -- set/cleared directly on the emoting
	-- character's Humanoid while a MovementLocked emote (Types.EmoteDefinition.MovementLocked) is
	-- playing/stopping/cancelled. Same "external system freezes movement without touching
	-- CombatState" shape as Frozen/Flying above -- Movement.ComputeDesiredWalkSpeed reads this
	-- directly, at the same top priority tier, rather than EmoteSystem writing into CombatState
	-- (which it has no ownership of).
	EmoteMovementLocked = "EmoteMovementLocked",
	-- Whether this player is currently IN COMBAT (CombatState.inCombatUntil still live) -- written by
	-- CombatSystem's inCombatNotifier on each true/false edge, alongside the Combat_InCombatChanged
	-- remote it already fires for the HUD badge. Same "one Attribute the server publishes, read
	-- directly by whoever needs it" shape as RootControlLocked above.
	--
	-- Exists because Client/Parkour needs it and the remote does not suit that consumer: the parkour
	-- context is rebuilt from Humanoid Attributes every frame (see ParkourController's own
	-- resolveCombatOwned, which reads four of them), so an Attribute costs one more read on a value
	-- that is already being maintained, where the remote would mean a second subscription and a cached
	-- mirror to keep in sync across respawns. Deliberately NOT a replacement for the remote -- the HUD
	-- badge wants the edge, parkour wants the level.
	--
	-- Note this makes InCombat gameplay-affecting in a third place (passive health regen and the
	-- parkour combat gate now both hang off inCombatUntil), so tuning InCombatDurationSeconds or
	-- CombatEngagementRange reaches further than it used to. See syncInCombat's own header.
	InCombat = "InCombat",
	-- Parkour System (Server/Systems/ParkourSystem.lua, Client/Parkour/*). Set on a player's own
	-- Humanoid while the client-side movement framework legitimately owns that character's velocity --
	-- a slide, wall-run, vault, mantle, ledge climb, roll or wall-jump the server has accepted and not
	-- yet expired. Movement.ComputeDesiredWalkSpeed reads it directly and pins WalkSpeed to 0 for the
	-- duration, at the same tier as Flying/Frozen/EmoteMovementLocked and for the identical reason:
	-- something other than the ordinary ground controller is driving this body, and a raised WalkSpeed
	-- underneath it fights the drive instead of riding along with it. Same "external system, read as
	-- an Attribute rather than written into CombatState" shape those three already use, which is what
	-- lets ParkourSystem stay entirely outside CombatSystem's private state.
	ParkourVelocityOwned = "ParkourVelocityOwned",
	-- The ROTATION counterpart to ParkourVelocityOwned above, and unlike every other Attribute in this
	-- table it is written by the CLIENT, not the server: Client/Parkour/ParkourMotor.lua raises it for
	-- exactly the window in which it owns the character's facing (the AlignOrientation drive in Velocity
	-- mode, the anchored CFrame write in Kinematic mode), and Client/Camera/ShiftLockCamera.lua reads it
	-- to stand its own per-frame yaw write down for the duration. Both ends are on the same client and
	-- nothing on the server reads it, so client-set (which does not replicate) is exactly right --
	-- this is one client-side presentation module coordinating with another, which is why it is an
	-- Attribute rather than a NetworkBridge remote.
	--
	-- It exists as an Attribute rather than a direct ParkourMotor -> ShiftLockCamera function call to
	-- keep the require graph one-directional: the camera folder is not mounted in test.project.json, so
	-- requiring it from the motor would drag Fusion and the whole camera stack into the parkour state
	-- registry's load chain and break Tests/Parkour/StateRegistry.spec. Same reactive
	-- GetAttributeChangedSignal shape ShiftLockCamera already uses for Flying/RootControlLocked, so it
	-- costs that module a cached boolean and no new dependency in either direction.
	ParkourFacingOwned = "ParkourFacingOwned",
	-- The momentum a just-finished parkour action handed back, as an absolute WalkSpeed floor, plus the
	-- timestamp it decays to nothing at. Together these are how a slide's or a vault's earned speed
	-- survives into ordinary running instead of being erased the instant the action ends -- see
	-- Movement.ComputeParkourSpeedFloor. Deliberately a FLOOR under the normal tiers rather than a
	-- replacement for them, so it can only ever preserve speed a player earned and never slow anyone
	-- down, and deliberately below the hit-slow/stun tiers so it can never be used to outrun a hit.
	ParkourSpeedFloor = "ParkourSpeedFloor",
	ParkourSpeedFloorExpiry = "ParkourSpeedFloorExpiry",
	-- The movement state that player's client last reported (a Types.ParkourActionReport Kind, or the
	-- empty string for ordinary locomotion). Purely informational: nothing gates on it. It exists
	-- because Humanoid Attributes replicate to every client for free, so this gives other players'
	-- clients -- and any future spectator/replay tooling -- a way to know what a remote character is
	-- doing without this feature adding a broadcast remote of its own.
	ParkourState = "ParkourState",
	-- Run System (Server/Systems/RunSystem.lua, Client/Movement/RunController.lua). The sustained-run
	-- STAGE this player's server-side state currently resolves to: 0 = not running (or running but
	-- not actually being granted the tier), 1/2/3 = the ladder Shared/Run/RunConstants.lua's Stages
	-- array defines -- that file, not this one, is the single source of truth for the thresholds and
	-- speeds behind each stage.
	--
	-- Server-written, exactly like every other Attribute in this table except ParkourFacingOwned, and
	-- for the reason that makes this feature safe: the stage decides a WalkSpeed multiplier, so the
	-- client must never be the one that decides it. The client only READS this to pick which run clip,
	-- which footstep sound and which FOV offset to present -- if a client lies to itself about the
	-- stage it gets a wrong animation and no extra speed at all.
	--
	-- An Attribute rather than a remote for the same reason ParkourState above is one: Humanoid
	-- Attributes replicate to every client for free, so a remote player's own client can pick the
	-- matching run animation for them with no per-stage broadcast of our own.
	SprintStage = "SprintStage",
}

-- Default keybind per Types.KeybindAction -- Client/Input/KeybindManager.lua clones this into its
-- own mutable table at load, so KeybindManager.Rebind() never mutates this shared table itself
-- (Constants.lua is read-only tunable data per this file's header). Purely client-side data: the
-- server never needs to know what key a player pressed, only the resulting request remote, so
-- nothing here crosses NetworkBridge -- it lives in Constants.lua rather than a client-only module
-- only because it's static default data every input-consuming client module needs to agree on.
-- UserInputType (not KeyCode) is used for MouseButton1/MouseButton2 -- Roblox's InputObject has no
-- KeyCode for mouse buttons, only a UserInputType.
Constants.Keybinds = {
	Defaults = {
		BasicAttack = { UserInputType = Enum.UserInputType.MouseButton1 },
		-- Block and Parry share this one input -- see Constants.Combat's Parry* fields' header for
		-- why (timed block: a press opens a short parry window, holding past it is a plain block).
		Block = { KeyCode = Enum.KeyCode.F },
		HeavyAttack = { KeyCode = Enum.KeyCode.R },
		LockOn = { KeyCode = Enum.KeyCode.CapsLock },
		-- Space is Roblox's default jump key, already spoken for, and LeftControl belongs to
		-- ShiftLock below -- Q is the conventional dodge/evade key this genre has left. Fires the
		-- neutral-game Dash (Types KeybindAction and CombatSystem.lua's handleDashRequest); the
		-- double-tap-W trigger below fires the same request as an alternate input.
		Dash = { KeyCode = Enum.KeyCode.Q },
		-- Sprint is a hold (press = sprint on, release = off, like Block). LeftShift is the
		-- conventional "run" key this genre already trains players to expect.
		Sprint = { KeyCode = Enum.KeyCode.LeftShift },
		-- Slide only fires while Sprint is held (CombatClient.lua gates the press client-side, and
		-- CombatSystem.lua's handleSlideRequest independently re-checks state.sprinting server-side)
		-- -- C is the conventional slide key in this genre, and unbound elsewhere in this table.
		Slide = { KeyCode = Enum.KeyCode.C },
		-- LeftControl stands in for shift lock here since LeftShift is already Sprint above. The
		-- engine's own mouse-lock switch is disabled in default.project.json
		-- (StarterPlayer.EnableMouseLockOption = false) so only the bespoke camera mode
		-- (Client/Camera/ShiftLockCamera.lua) responds to it -- two systems toggling on one key press
		-- would fight over MouseBehavior every frame.
		ShiftLock = { KeyCode = Enum.KeyCode.LeftControl },
		DevMenuToggle = { KeyCode = Enum.KeyCode.Equals },
		-- T is unbound elsewhere in this table and is a conventional "swap/loadout" key in the
		-- genre -- fires RequestSwapWeapon (Constants.Combat.Weapons), a one-shot toggle like Dash.
		SwapWeapon = { KeyCode = Enum.KeyCode.T },
		-- Right-click is otherwise unbound in this table (MouseButton1 is BasicAttack, Block/Parry
		-- already lives on F) -- fires RequestFeint (CombatSystem.lua's handleFeintRequest), the
		-- conventional "cancel/reposition" slot this genre leaves free next to the primary attack
		-- button.
		Feint = { UserInputType = Enum.UserInputType.MouseButton2 },
		-- Opens the player-facing bug report form (Client/BugReport/BugReportClient.lua). F8 reads
		-- as a "system/meta" function-row key rather than a gameplay key -- unlike the letter/mouse
		-- binds above, there's low risk of an accidental press mid-combat, and it's unclaimed
		-- elsewhere in this table.
		OpenBugReport = { KeyCode = Enum.KeyCode.F8 },
		-- Move Creation System editor toggle -- unbound elsewhere in this table, sits next to
		-- DevMenuToggle's Equals key in the same "secondary system action" row of the keyboard.
		-- Admin-only (MoveEditorClient.lua's own authorization round-trip, same as DevMenuToggle).
		OpenMoveEditor = { KeyCode = Enum.KeyCode.Minus },
		-- Opens the Live Admin Console (Client/LiveConsole/LiveConsoleClient.lua,
		-- Client/UI/Screens/LiveConsole/init.lua) for an authorized admin -- a bespoke live log
		-- stream, not Roblox's own native Developer Console. It used to open the native one via
		-- StarterGui:SetCore("DevConsoleVisible") until it was replaced: that panel only ever showed
		-- anything in Studio, since Shared/Logger.lua never calls print()/warn() outside
		-- RunService:IsStudio() by design, so on a live server the one key meant to surface logs
		-- opened an empty panel. The Live Admin Console reads Logger.lua's always-on capture buffer
		-- instead, which works regardless of IsStudio -- see that module's own header.
		--
		-- F7 rather than the engine's own F9: F9 is bound by Roblox itself only for accounts with
		-- edit access to the place and does nothing for anyone else, so reusing it would leave a key
		-- that works for some admins and silently not for others.
		--
		-- And NOT F6, which is where this first went: F6 is already the parkour debug overlay's raw
		-- toggle (ParkourConstants.Debug.ToggleKeyCode). That binding is not in this table -- it is
		-- deliberately raw so it never shows up in the player-facing rebind list -- so nothing here
		-- flagged the collision, and the two handlers simply both fired on the same press. If another
		-- "developer tooling" key is ever added, check ParkourConstants.Debug as well as this table.
		OpenDevConsole = { KeyCode = Enum.KeyCode.F7 },
		-- The 5 hotbar slots (see Types.KeybindAction's own header) -- the obvious number-row keys,
		-- unclaimed elsewhere in this table (BasicAttack/HeavyAttack/Block/etc. all live on letters or
		-- the mouse).
		HotbarSlot1 = { KeyCode = Enum.KeyCode.One },
		HotbarSlot2 = { KeyCode = Enum.KeyCode.Two },
		HotbarSlot3 = { KeyCode = Enum.KeyCode.Three },
		HotbarSlot4 = { KeyCode = Enum.KeyCode.Four },
		HotbarSlot5 = { KeyCode = Enum.KeyCode.Five },
		-- Held to open the radial emote wheel (Client/Emotes/EmoteWheelClient.lua) -- B is unclaimed
		-- elsewhere in this table and sits comfortably under the same hand already on WASD, away from
		-- the mouse-driven combat cluster (BasicAttack/Feint on the mouse buttons, Block/HeavyAttack on
		-- F/R) the wheel's own mouse-steered selection needs to stay clear of.
		EmoteWheel = { KeyCode = Enum.KeyCode.B },
		-- Opens the Settings panel (Client/Settings/SettingsClient.lua). Deliberately NOT Escape: this
		-- repo never disables Roblox's own native Escape/Menu overlay, and layering a persistent panel
		-- toggle onto that same key would open both at once every press -- see OpenBugReport's
		-- ButtonSelect comment below for the same conflict already avoided on the gamepad side. Was
		-- O ("Options", the obvious mnemonic) until a Studio playtest showed the I/O/P cluster never
		-- reaching UserInputService at all on at least one dev machine -- not consumed with
		-- gameProcessed=true, simply absent -- so the toggle was unreachable with no in-game way to
		-- rebind it (the rebind UI lives behind this very key). K is unclaimed elsewhere in this
		-- table, sits on the home row, and is verified to register; players who prefer O can rebind
		-- it in the panel itself.
		SettingsToggle = { KeyCode = Enum.KeyCode.K },
		-- Opens the character menu (Client/CharacterMenu/CharacterMenuClient.lua). M is the key this
		-- screen has always opened on -- it was a hard-coded UserInputService check inside the screen
		-- itself until the panel became the real character hub -- so this entry keeps the key players
		-- already know while finally making it rebindable like every other action in this table.
		-- Unclaimed elsewhere here, and far enough from the WASD/mouse combat cluster that an
		-- accidental mid-fight press is unlikely.
		CharacterMenuToggle = { KeyCode = Enum.KeyCode.M },
		-- Parkour dodge/roll (Client/Parkour/States/Rolling.lua). LeftAlt is unclaimed elsewhere in
		-- this table, sits under the same hand already on WASD (a roll has to be reachable without
		-- leaving the movement keys, unlike the panel toggles above), and -- unlike every letter key
		-- left -- carries no risk of colliding with Roblox's own chat-focus behavior on a stray press.
		Roll = { KeyCode = Enum.KeyCode.LeftAlt },
		-- Parkour committed leap (Client/Parkour/States/Leaping.lua). Used to fire on a double-tap of
		-- jump; E is unclaimed elsewhere in this table, sits under the same hand already on WASD (same
		-- reachability requirement as Roll's own comment above), and is the conventional "interact/use"
		-- key this genre trains players to reach for on a deliberate single press.
		Leap = { KeyCode = Enum.KeyCode.E },
	} :: { [Types.KeybindAction]: Types.Keybind },

	-- Gamepad defaults -- a SEPARATE table, not a wider Keybind, so a player can have a keyboard
	-- bind AND a gamepad bind live for the same action at once (Client/Input/KeybindManager.lua's
	-- Matches() checks both). Roblox has no PlayStation-specific input API -- every gamepad's
	-- buttons (DualSense included) come through as the same Enum.KeyCode.ButtonA/B/X/Y/L1/R1/L2/
	-- R2/L3/R3/DPad* regardless of manufacturer, and UserInputService:GetImageForKeyCode already
	-- swaps in PlayStation-style glyphs at the engine level once it detects a DualSense -- nothing
	-- to build for that part. Mapped to this genre's own Souls-like convention family, the same
	-- reasoning the keyboard Defaults above already use per-key:
	GamepadDefaults = {
		-- R1/R2 light/heavy attack is the standard split in this genre (Elden Ring/Dark Souls).
		BasicAttack = { KeyCode = Enum.KeyCode.ButtonR1 },
		HeavyAttack = { KeyCode = Enum.KeyCode.ButtonR2 },
		-- L1 guard, same genre convention.
		Block = { KeyCode = Enum.KeyCode.ButtonL1 },
		-- B (Circle on a DualSense) is the near-universal roll/dash button in this genre.
		Dash = { KeyCode = Enum.KeyCode.ButtonB },
		-- R3 (click right stick) is the standard lock-on button (Souls, Zelda).
		LockOn = { KeyCode = Enum.KeyCode.ButtonL2 },
		-- L3 (click left stick) is a common third-person sprint convention.
		Sprint = { KeyCode = Enum.KeyCode.ButtonL3 },
		-- X (Square) -- a free face button, pressed while already holding L3 for Sprint.
		Slide = { KeyCode = Enum.KeyCode.ButtonX },
		-- Y (Triangle) -- a free face button, toggles the camera-facing-lock mode.
		ShiftLock = { KeyCode = Enum.KeyCode.ButtonY },
		-- D-pad item/weapon-swap is a standard convention in this genre.
		SwapWeapon = { KeyCode = Enum.KeyCode.DPadRight },
		-- R3 (click right stick) is otherwise unused among the actual KeyCode values in this table
		-- (unlike LockOn's comment above, which names R3 but binds ButtonL2 -- a separate, pre-
		-- existing doc/code mismatch this change doesn't touch) -- free for Feint.
		Feint = { KeyCode = Enum.KeyCode.ButtonR3 },
		-- Bug report form, gamepad side -- ButtonA is Roblox's own native Jump (would double-fire on
		-- every jump), ButtonStart is the engine's native Escape/Menu button (would fight this
		-- panel), D-pad is already this game's "quick select" semantic (SwapWeapon owns DPadRight).
		-- ButtonSelect (Share/View/Touchpad-click depending on controller family) is unclaimed, has
		-- no competing engine-level binding, and reads as the same "secondary system action"
		-- category DevMenuToggle's own comment below reserves for admin tooling -- just applied to a
		-- player-facing feature here. Needs a real controller playtest: Share/View/Touchpad-click
		-- behavior varies slightly by controller family.
		OpenBugReport = { KeyCode = Enum.KeyCode.ButtonSelect },
		-- DPadDown -- this genre's conventional "hold for a quick-select wheel" gamepad slot.
		-- DPadRight is already SwapWeapon above; DPadUp/DPadLeft are the only other unclaimed D-pad
		-- directions among the KeyCode values in this table, so DPadDown is free with no live
		-- conflict to check for.
		EmoteWheel = { KeyCode = Enum.KeyCode.DPadDown },
		-- DPadUp -- the last unclaimed D-pad direction (DPadRight is SwapWeapon, DPadDown is
		-- EmoteWheel above) and a natural "open a menu" convention on its own. Unlike DevMenuToggle/
		-- HotbarSlot1-5 below, Settings is NOT admin-only, so it earns a real gamepad default rather
		-- than staying keyboard-only.
		SettingsToggle = { KeyCode = Enum.KeyCode.DPadUp },
		-- Parkour dodge/roll, gamepad side. DPadLeft is the last unclaimed D-pad direction (DPadRight
		-- is SwapWeapon, DPadDown is EmoteWheel, DPadUp is SettingsToggle above), and every face/
		-- shoulder button in this genre's convention family is already spoken for above. Not ideal -- a
		-- roll deserves a face button -- but the alternative is doubling up on Dash's ButtonB, which
		-- would make two distinct mechanics indistinguishable on a controller. Flagged for a real
		-- controller playtest, same as OpenBugReport's ButtonSelect note.
		Roll = { KeyCode = Enum.KeyCode.DPadLeft },
		-- Leap deliberately has NO gamepad default either, but for a different reason than
		-- DevMenuToggle below: every face/shoulder/stick-click/D-pad value in this genre's own
		-- convention family is already claimed above (see Roll's own comment, which hit the identical
		-- wall) -- there is genuinely nowhere left to put it without doubling up two distinct
		-- mechanics on one button. Value type is Keybind? for exactly this case; KeybindManager.Matches
		-- simply never matches for an action with no bound gamepad input. Flagged for a real controller
		-- pass if a button ever frees up.
		--
		-- DevMenuToggle deliberately has NO gamepad default -- admin-only, keyboard already covers
		-- it, and exposing a stray always-live single-button dev-menu toggle to every controller
		-- user isn't something to do by default. KeybindManager.Matches simply never matches for an
		-- action with no bound gamepad input. Value type is Keybind? (unlike Defaults' Keybind
		-- above), honestly reflecting that this map is deliberately partial -- every consumer that
		-- reads it must nil-check. HotbarSlot1-5 are absent for the same admin-only reasoning -- there
		-- are no unclaimed face/shoulder/D-pad buttons left in this genre's own convention family
		-- (see every KeyCode above) to spare for a five-way admin-only picker, and keyboard already
		-- covers the one audience (admins running the Move Editor) that needs it.
	} :: { [Types.KeybindAction]: Types.Keybind? },

	-- Double-tapping W (Roblox's own built-in forward-movement key, not a rebindable
	-- KeybindAction/Defaults entry above -- movement itself is the engine's default character
	-- controller, this only listens for the key) fires the same Dash request as the Dash keybind --
	-- an alternate, more intuitive trigger for the same move (CombatSystem.lua's
	-- handleDashRequest), flagged so a forward-resolved Dash off THIS trigger can also throw
	-- DashPunch. Client-only timing window: how long between the first and second W press still
	-- counts as a double-tap (CombatClient.lua's InputBegan).
	DoubleTapDashWindowSeconds = 0.3,
}

-- Settings System (Server/Systems/SettingsSystem.lua, Client/Settings/SettingsClient.lua) --
-- persists Types.PlayerSettings (rebound keybind overrides + Autorun) through PlayerDataSystem and
-- restores them into Client/Input/KeybindManager.lua on join. Kept as its own table rather than
-- folded into Constants.Keybinds above -- that table is static DEFAULT-binding content this file
-- already owns per its own header; this one is remote-name/networking config for a feature built
-- on top of it, the same "distinct feature, distinct table" split Constants.PlayerData's own header
-- draws against Constants.BugReport.
Constants.Settings = {
	RemoteNames = {
		-- RemoteFunction, no payload -- fetched once by SettingsClient.Start() (same "client needs an
		-- immediate, race-free answer at boot" reasoning as CharacterCreation_GetOnboardingState)
		-- rather than a server push on PlayerDataSystem.OnProfileLoaded: a push fired before this
		-- client has connected its own listener (a real risk here -- IntroClient/LoadingClient both
		-- block Main.client.lua well past the moment a profile can finish loading server-side) would
		-- be silently lost with no corrective resync, unlike Combat_VitalsUpdated's own continuously-
		-- refreshed value. A request/response round trip has no such window: it always reflects
		-- whatever PlayerDataSystem already has loaded by the time this client asks.
		GetSettings = "Settings_GetSettings",
		-- Fire-and-forget persistence writes -- the client has already applied each of these locally
		-- (KeybindManager.Rebind/RebindGamepad/ResetToDefaults/ResetGamepadToDefaults, or its own
		-- Autorun toggle) before firing, so there is nothing for the server to echo back; these exist
		-- purely to make the change durable across sessions.
		UpdateKeybind = "Settings_UpdateKeybind",
		ResetKeybinds = "Settings_ResetKeybinds",
		UpdateAutorun = "Settings_UpdateAutorun",
		-- Parkour System preferences (Types.ParkourSettings) -- one remote carrying a field name plus a
		-- value, rather than eight single-purpose remotes. That is the opposite of the choice made for
		-- Autorun above (its own remote, no payload beyond the boolean), and deliberately so: Autorun
		-- is one settled preference, where the Parkour block is a group expected to grow and shrink as
		-- that feature is tuned, and a remote per assist would mean a NetworkBridge registration, a
		-- handler and a client call site for every one. The cost is that the field name becomes
		-- untrusted input -- handled by SettingsSystem validating it against a closed set, exactly as
		-- isRebindableAction already does for keybind actions.
		UpdateParkour = "Settings_UpdateParkour",
	},
	-- Same call-budget reasoning as Constants.Rivalry.QueryMaxCallsPerSecond -- a rebind/toggle write
	-- costs nothing gameplay-wise but should still never be free spam.
	MaxCallsPerSecondPerPlayer = 4,
	-- Same "named duration, not a magic number at the call site" convention as
	-- Constants.Debug.DevMenu.StatusClearDelaySeconds/Constants.BugReport.ConfirmationClearDelaySeconds
	-- -- Client/Settings/SettingsClient.lua's own status line (e.g. "Keybinds reset to defaults.").
	StatusClearDelaySeconds = 3,
}

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
	-- enabled rather than a half-populated settings table.
	SchemaVersion = 5,

	-- A brand-new profile's starting Tier -- Tier 1 is the bottom of TierSystem's nine-tier ladder
	-- (progression-systems.md), the correct starting point for a player who has never played before.
	DefaultTier = 1,

	-- DataStore retry/backoff -- same shape and same withRetry-delegates-to-DataStoreRetry pattern
	-- as Constants.BugReport.StorageRetry*/Constants.Moderation.StorageRetry* below, now actually
	-- shared (see Shared/DataStoreRetry.lua's own header for why this is the third caller that
	-- earned the extraction both of those tables' own comments already called out).
	StorageRetryMaxAttempts = 3,
	StorageRetryBaseBackoffSeconds = 1,

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

-- Qi (Server/Systems/QiSystem.lua) -- just the remote name lives here, per NetworkBridge.lua's own
-- convention that remote names live in each domain's Constants.* table. Every actual Qi tuning
-- number (Max Qi curve, regen, Qi Conflict matrix) lives in Shared/QiConstants.lua instead -- see
-- that file's own header for why Qi specifically earned a dedicated tuning module rather than a
-- table here.
Constants.Qi = {
	RemoteNames = {
		QiUpdated = "Progression_QiUpdated",
	},
}

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

-- First-time-player onboarding / character creation (Server/Systems/CharacterCreationSystem.lua,
-- Client/Onboarding/OnboardingClient.lua + UI/Screens/Onboarding/*). A first-time player is detected
-- purely by `profile.raceId == nil` (PlayerDataSystem.PlayerProfile) -- no new boolean flag, and a
-- returning player never sees this flow again. Grouped as its own top-level table (not folded into
-- Constants.PlayerData) since chargen has its own distinct tuning surface -- race/attribute
-- balance, name rules, cinematic timing -- that has nothing to do with PlayerDataSystem's own
-- DataStore/autosave concerns, the same "distinct feature, distinct table" reasoning
-- Constants.BugReport's own header gives for staying separate from Constants.PlayerData.
Constants.CharacterCreation = {
	-- The four fixed races (world-bible.md, Constants.RaceCount = 4) -- a closed set
	-- CharacterCreationSystem.ValidateRaceId checks a client-submitted race choice against. Real,
	-- final content for this pass, not a placeholder roster.
	RaceIds = ({ "Human", "Firmborn", "Rivenkin", "Hollowborn" } :: any) :: { Types.RaceId },

	-- Types.AttributeBlock's six fields, in one fixed, canonical order -- both
	-- CharacterCreationSystem.ValidateAttributeBlock (server) and the Attributes/RaceSelect screens
	-- (client, Client/UI/Screens/Onboarding/) iterate this same list rather than each independently
	-- re-typing the six field names, so the two sides can never drift out of sync on what the six
	-- attributes are called.
	AttributeFields = { "Vitality", "Fortitude", "MeridianFlow", "Might", "Pressure", "Fleetness" },

	-- Three-letter abbreviations for the Attributes screen's stat rows and the Origin card's 6-up
	-- stat grid (docs/design/intro-redesign-figma-spec.md sections 4-5) -- keyed the same way as
	-- AttributeFields immediately above so a caller iterating that list can look these up directly
	-- rather than re-deriving an abbreviation from the full name.
	AttributeAbbreviations = {
		Vitality = "VIT",
		Fortitude = "FOR",
		MeridianFlow = "MER",
		Might = "MGT",
		Pressure = "PRS",
		Fleetness = "FLT",
	} :: { [string]: string },

	-- Attribute point budget -- every one of the six attributes (Types.AttributeBlock) starts at
	-- BaseValuePerAttribute (10), and RaceIds share one BonusPoolTotal (18) between a race's own
	-- pre-committed lean (RacePrefills below, worth RacePrecommittedPoints net points -- except
	-- Human, who gets no pre-fill and keeps the full pool as free points instead) and whatever the
	-- player freely reallocates on the Attributes screen. TotalBudget (78 = 10*6 + 18) is the exact
	-- sum CharacterCreationSystem.ValidateAttributeBlock requires -- every race reaches the same
	-- total, only the starting lean differs. MaxPerAttribute is a per-attribute creation-time bound
	-- (a future Attunement/tier-up points-per-tier screen is expected to raise attributes past 20
	-- later, but that's a different budget check this pass deliberately doesn't need to anticipate).
	--
	-- MinPerAttribute raised 5 -> 10 (docs/design/intro-redesign-handoff.md Phase D, the interim
	-- point-pool rebalance -- TierSystem.lua is still an empty Init() with no point-grant mechanism,
	-- which rules out the handoff's "full" rebalance for this pass; user decision, 2026-07-25).
	-- Rationale: MeridianFlow does nothing yet (see AttributeEffects below), so under the old
	-- MinPerAttribute=5 the dominant play was dump MeridianFlow/Fortitude to the floor and pour
	-- everything into Might -- a 30% permanent stat swing the redesign's own numeric-transparency UI
	-- would have handed the player on sight. Raising the floor kills that strategy without touching
	-- BonusPoolTotal or requiring TierSystem to exist.
	--
	-- A flat floor alone would make Hollowborn's own starting block invalid (BaseValuePerAttribute +
	-- RacePrefills.Hollowborn.Vitality = 10 - 1 = 9, one below this new floor) -- AttributeFloors
	-- below is the fix: a per-race, per-field floor that's normally MinPerAttribute but never higher
	-- than that race's own prefilled starting value.
	AttributeBudget = {
		BaseValuePerAttribute = 10,
		BonusPoolTotal = 18,
		RacePrecommittedPoints = 2,
		MinPerAttribute = 10,
		MaxPerAttribute = 20,
		TotalBudget = 78,
	},

	-- Per-race starting attribute deltas from BaseValuePerAttribute above -- an empty/missing entry
	-- for a given attribute means no delta (stays at base). Human is deliberately the empty table:
	-- "no pre-fill" IS the design (flat baseline, all 18 points free) rather than a race that simply
	-- hasn't been authored yet. Hollowborn's net is +3 MeridianFlow / -1 Vitality (+2 net, same
	-- RacePrecommittedPoints worth as Firmborn/Rivenkin's flat +2), not a flat single-attribute lean
	-- -- CharacterCreationSystem/the Attributes screen both derive a race's starting block by summing
	-- BaseValuePerAttribute + these deltas per attribute, never by assuming "one attribute gets +2."
	RacePrefills = {
		Human = {},
		Firmborn = { Fortitude = 2 },
		Rivenkin = { Might = 2 },
		Hollowborn = { MeridianFlow = 3, Vitality = -1 },
	} :: { [string]: { [string]: number } },

	-- RaceHooks (deprecated) removed: it was retained only until "the Onboarding rebuild (Phase E)
	-- migrates RaceSelect.lua's last reference off it." Phase E has landed and a full-tree search
	-- finds zero remaining readers, so the table is gone rather than left as a second, staler answer
	-- to the same question the three tables below now own.

	-- Three-layer replacement for the former RaceHooks (docs/design/intro-redesign-figma-spec.md's Origin
	-- card + docs/design/intro-redesign-handoff.md Phase C/E's progressive-disclosure card). Every
	-- unselected Origin card shows Name + Epithet + WorldLine + CostLine; the selected card also
	-- expands to the real per-attribute numbers (RacePrefills), which these three deliberately never
	-- restate as hardcoded digits -- a copy string that quotes "+2 Fortitude" goes stale the moment
	-- RacePrefills changes under it, so CostLines stays qualitative and the UI reads the real number
	-- from Budget/RacePrefills directly.
	--
	-- Epithets are the Figma's own, taken verbatim -- they're good, and they're the layer the old
	-- RaceHooks lacked entirely. WorldLines and CostLines are new, written against
	-- world-bible.md's Shattering/Meridian Particle framing (Shattered Meridian Studio skill) rather
	-- than inventing unrelated lore -- the skill's current world-bible.md/progression-systems.md
	-- don't yet carry a dedicated per-race lore write-up of their own (only this game's Constants.lua
	-- did, in RaceHooks' mechanical register), so these lines stay at the same restrained altitude
	-- the old hooks held rather than asserting new binding canon (faction ties, detailed sub-history)
	-- a UI copy pass isn't positioned to author solo.
	RaceEpithets = {
		Human = "The Unwritten",
		Firmborn = "Heirs of the Stonepath",
		Rivenkin = "Born of the Fracture Lines",
		Hollowborn = "Vessels of Broken Qi",
	} :: { [string]: string },
	RaceWorldLines = {
		Human = "No fragment of the old Meridian marked you before birth. What you become is still yours to write.",
		Firmborn = "When the Shattering came, their ancestors held their ground instead of fleeing it -- and the ground held them back.",
		Rivenkin = "Their ancestors were already moving when the world cracked open, and never really stopped.",
		Hollowborn = "Their Meridian fragment burns closer to the surface than most -- already hollowing out room to hold more of it.",
	} :: { [string]: string },
	-- Honest cost layer -- Firmborn/Rivenkin are a single pre-spent lean (RacePrefills sets ONE field
	-- positive, nothing is reduced to pay for it -- the "cost" is that the point is already committed
	-- before the player gets to allocate freely); Hollowborn is the one race with a real two-sided
	-- trade (MeridianFlow up, Vitality down), and its line says so.
	RaceCostLines = {
		Human = "No starting lean -- every point is unspent, and yours to place.",
		Firmborn = "A lean toward Fortitude, already spent for you before you begin.",
		Rivenkin = "A lean toward Might, already spent for you before you begin.",
		Hollowborn = "A deep lean toward MeridianFlow, paid for out of Vitality.",
	} :: { [string]: string },

	-- Plain-language one-line effect shown under each attribute on the Attributes screen (screen 2).
	-- MeridianFlow's now reflects a live mechanic -- QiSystem.lua (Shared/QiConstants.lua's
	-- MaxQiPerMeridianFlowPoint/RegenPerSecondPerMeridianFlowPoint) actually reads this attribute,
	-- so the "(not active yet)" caveat that used to sit here would now be stale, not honest.
	-- Fleetness is deliberately scoped to movement + Dash/Sprint/Slide cooldown trim ONLY --
	-- combat-philosophy.md's attack-speed/combo-timing/parry-window feel stays attribute-invariant,
	-- so this copy never implies otherwise.
	AttributeEffects = {
		Vitality = "Max Health",
		Fortitude = "Max Posture + regen",
		MeridianFlow = "Max Qi + regen",
		Might = "Outgoing health damage",
		Pressure = "Outgoing posture damage",
		Fleetness = "Movement speed + Dash/Sprint/Slide cooldown trim",
	} :: { [string]: string },

	-- Display name rules (screen 3) -- the in-game character name, separate from the Roblox
	-- username, NOT globally unique (no reservation table -- CharacterCreationSystem.lua never checks
	-- another player's name). CharacterCreationSystem.ValidateDisplayName enforces length/charset;
	-- server-side TextService:FilterStringAsync/GetNonChatStringForBroadcastAsync (same call site
	-- pattern as BugReportSystem.Submit) runs after that, and Denylist is a final studio-authored
	-- blocklist checked in addition to the moderation filter.
	DisplayName = {
		MinLength = 3,
		MaxLength = 20,
		-- Staff/authority IMPERSONATION terms specifically -- a genuinely different concern from the
		-- profanity/harassment content TextService:FilterStringAsync above already exists to catch
		-- (and is this codebase's compliant, always-up-to-date source of truth for that). A name like
		-- "Admin" or "RobloxSupport" isn't profane, so the moderation filter has no reason to touch
		-- it, but it lets a player pose as staff to scam/mislead others in-game -- a distinct, real
		-- abuse vector this denylist exists specifically to close. ValidateDisplayName checks
		-- substring containment, case-insensitively, against `name:lower()` -- every term here is
		-- already lowercase for that reason, and deliberately spelled out in FULL (never a short
		-- fragment like "mod" or "gm") to keep false-positive collisions with legitimate names low --
		-- "mod"/"gm" alone would reject real names that merely happen to contain those letters in
		-- sequence (e.g. "Sigmund" contains "gm"), where a full word like "moderator" essentially
		-- never appears by coincidence inside an unrelated name.
		Denylist = {
			"admin",
			"administrator",
			"moderator",
			"gamemaster",
			"developer",
			"roblox",
			"official staff",
			"game staff",
			"support staff",
		} :: { string },
		-- NameEntry.lua's "Suggest" button (docs/design/intro-redesign-handoff.md's designer
		-- direction: "blank-field paralysis is the biggest drop-off point in any chargen flow").
		-- Real, curated names, not placeholder text -- every one already satisfies MinLength/MaxLength
		-- and ValidateDisplayName's charset gate, so a suggestion needs no special-cased validation
		-- path; it writes into the same DisplayName Value a typed name would and is re-validated
		-- identically at Finalize.
		SuggestedNames = {
			"Kaelen",
			"Wren",
			"Iskra",
			"Thane",
			"Marek",
			"Sable",
			"Orin",
			"Vesna",
			"Callan",
			"Ashe",
			"Doran",
			"Lyric",
			"Bren",
			"Rovena",
		} :: { string },
	},

	RemoteNames = {
		GetOnboardingState = "CharacterCreation_GetOnboardingState",
		Finalize = "CharacterCreation_Finalize",
		-- Fire-and-forget RemoteEvent (Client/Intro/IntroClient.lua -> CharacterCreationSystem.lua),
		-- sent once the local player's get-up AnimationTrack finishes playing. This is what ends the
		-- isolation (Frozen/Godmode/Invisible) handleGetOnboardingState below applies -- see
		-- CharacterCreationSystem.lua's own header for why a client-reported "I'm done" signal is an
		-- acceptable trust level here (one-shot, low-stakes, same tier as GetOnboardingState/
		-- spawnedThisSession) rather than duplicating an animation-length timer server-side too.
		AwakeningComplete = "CharacterCreation_AwakeningComplete",
	},

	-- Named Workspace instances CharacterCreationSystem.lua resolves via WaitForChild.
	-- default.project.json DOES author this Workspace tree (see its own "Onboarding" node) --
	-- ThresholdSpawn is an isolated "Waking Threshold" pocket space outside SafeZones/
	-- ContestedZones/VoidFractureZones/Territories (a first-time player is frozen there for the
	-- lying-down cinematic + creator); each entry in ArrivalSpawnPaths is a race-specific arrival
	-- point chargen teleports (PivotTo) the player to once Finalize succeeds -- "world" here means a
	-- race-keyed zone in this same place, not a separate Roblox Place (WorldSystem.lua/
	-- TerritorySystem.lua already use "world"/"region" this way; nothing in this repo has
	-- multi-place teleport infra, and CharacterCreation_Finalize picks the entry keyed by the
	-- SERVER-VALIDATED raceId, which is what keeps this server-authoritative without needing any).
	ThresholdSpawnPath = { "Onboarding", "WakingThresholdSpawn" },
	ArrivalSpawnPaths = {
		Human = { "Onboarding", "ArrivalSpawns", "Human" },
		Firmborn = { "Onboarding", "ArrivalSpawns", "Firmborn" },
		Rivenkin = { "Onboarding", "ArrivalSpawns", "Rivenkin" },
		Hollowborn = { "Onboarding", "ArrivalSpawns", "Hollowborn" },
	} :: { [string]: { string } },

	-- Cinematic timing (Client/Onboarding/OnboardingClient.lua + UI/Screens/Onboarding/Cinematic.lua).
	-- The intro plays for CinematicDurationSeconds unless held-skipped first. Cut from 19s/6 lines to
	-- 12s/4 lines (docs/design/intro-redesign-handoff.md's designer direction) -- CINEMATIC_LINE_COUNT
	-- in OnboardingClient.lua must match Cinematic.lua's own line count, the same documented coupling
	-- as before.
	--
	-- HoldToSkipSeconds and HoldToConfirmSeconds used to share one value ("held input, ~1s") despite
	-- meaning opposite things -- skipping unwatched lore vs. permanently creating a character. Now
	-- deliberately different: skip is the FASTER, lower-stakes gesture (0.6s), confirm is the
	-- SLOWER, higher-stakes one (1.6s) -- the two hold durations are now themselves part of how each
	-- gesture communicates its own weight, not just their surrounding copy.
	CinematicDurationSeconds = 12,
	HoldToSkipSeconds = 0.6,
	HoldToConfirmSeconds = 1.6,
	-- The skip affordance fades in this many seconds into the cinematic, not at t=0 (designer
	-- direction: "telling the player they may leave before giving them a reason to stay is
	-- backwards").
	SkipHintRevealSeconds = 4,

	-- Per-remote call budgets, same convention as Constants.BugReport.SubmitMaxCallsPerSecond/
	-- Constants.Settings.MaxCallsPerSecondPerPlayer -- GetOnboardingState's own WaitForProfile yield
	-- and Finalize's TextService:FilterStringAsync yield are both real server work a modified client
	-- could otherwise spam ahead of (or during, before) the existing spawnedThisSession/
	-- finalizingPlayers in-flight guards.
	GetOnboardingStateMaxCallsPerSecond = 2,
	FinalizeMaxCallsPerSecond = 2,
}

-- Precomputed per-race, per-field allocation floor -- see AttributeBudget's own comment above for
-- why this exists (the interim point-pool rebalance) and RacePrefills for the source data. A
-- separate `do` block (not part of the table literal above) because it's DERIVED from
-- AttributeBudget/RacePrefills/RaceIds/AttributeFields, all of which must already exist to compute
-- it. Computed ONCE here rather than as a function duplicated on both sides of the client/server
-- boundary -- CharacterCreationSystem.ValidateAttributeBlock (server) can't be required from client
-- code at all (ServerScriptService isn't replicated), and the Attributes screen's stepper clamp
-- (client) needs the identical numbers, so both just read this table instead of two independently
-- re-deriving the same formula.
do
	local budget = Constants.CharacterCreation.AttributeBudget
	local floors: { [string]: { [string]: number } } = {}
	for _, raceId in ipairs(Constants.CharacterCreation.RaceIds) do
		local prefill = Constants.CharacterCreation.RacePrefills[raceId] or {}
		local perField: { [string]: number } = {}
		for _, field in ipairs(Constants.CharacterCreation.AttributeFields) do
			-- min, not max: the floor is normally MinPerAttribute, but never higher than this race's
			-- OWN prefilled starting value -- a race whose prefill already sits below the flat floor
			-- (today, only Hollowborn's Vitality: 10 - 1 = 9) is grandfathered in at its own number
			-- rather than starting the Attributes screen already in violation of a rule the player
			-- had no chance to satisfy from screen 1. A POSITIVE prefill (Firmborn's Fortitude,
			-- Rivenkin's Might) never raises the floor above MinPerAttribute -- a prefill is a
			-- starting lean the player must stay free to reallocate away, not a locked-in minimum.
			perField[field] = math.min(budget.MinPerAttribute, budget.BaseValuePerAttribute + (prefill[field] or 0))
		end
		floors[raceId] = perField
	end
	Constants.CharacterCreation.AttributeFloors = floors :: { [string]: { [string]: number } }
end

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

	-- DataStore retry/backoff -- BugReportSystem's local withRetry helper now delegates to
	-- Shared/DataStoreRetry.lua (see that module's header; PlayerDataSystem.lua is the third caller
	-- that earned the extraction this table's own comment used to defer).
	StorageRetryMaxAttempts = 3,
	StorageRetryBaseBackoffSeconds = 1,

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

-- Player moderation (Server/Systems/ModerationSystem.lua) -- Kick is stateless; Ban is
-- DataStore-backed (own store, separate from BugReport's above) so it survives a rejoin/new server;
-- Mute is in-memory only (session-scoped, see ModerationSystem.lua's own header for why it's
-- deliberately not persisted -- a mute is a "settle this down right now" tool, not a standing
-- record the way a ban is). Remote names for all three live in Constants.Debug.DevMenu.RemoteNames
-- (DevMenuSystem.lua creates/handles them, same split BugReport's admin remotes already use).
Constants.Moderation = {
	-- DataStore retry/backoff -- same shape as Constants.BugReport's/Constants.PlayerData's own
	-- StorageRetry* fields; all three now feed the same Shared/DataStoreRetry.lua implementation
	-- (see that module's header).
	StorageRetryMaxAttempts = 3,
	StorageRetryBaseBackoffSeconds = 1,

	-- BanDataStoreName moved to Server/Config/StorageConfig.lua -- see the note in Constants.BugReport
	-- above for why every DataStore name left this file.

	-- SuspectedCheaterDataStoreName moved to Server/Config/StorageConfig.lua, same reasoning.
}

-- Move Creation System (Server/Combat/MoveRegistryManager.lua, Server/Systems/MoveEditorSystem.lua,
-- Client/UI/Screens/MoveEditor/) -- an in-game, admin-gated editor for authoring new combat moves
-- as data (MoveTypes.MoveDefinition) rather than hand-written Constants.lua tables + bespoke
-- server/client code per move. Same "own DataStore config, own tuning surface" split
-- Constants.BugReport/Constants.PlayerData already establish -- CustomMoveDataStoreName itself
-- lives in Server/Config/StorageConfig.lua, never here (see that file's own header).
Constants.MoveEditor = {
	-- v2 (2026-08-12) added, all additively: the twelve-shape Dimensions bag (Shared/HitboxShapes.
	-- lua) alongside the original Size/Radius, Offset rotation, the multi-clip animation timeline
	-- (Shared/AnimationTimeline.lua), and the Object Stun block (Types.ObjectStunConfig). No
	-- migration pass exists or is needed -- MoveRegistryManager.Validate reconstructs every v2 field
	-- from a v1 record's own values (Dimensions from Size/Radius, a one-clip timeline from
	-- AnimationId, no Object Stun), so a v1 record loads and behaves exactly as it always did. The
	-- version is bumped anyway, per PlayerDataSystem's own convention, so a future BREAKING change
	-- has a real boundary to branch on.
	SchemaVersion = 2,

	-- DataStore retry/backoff -- same shape/values as every other StorageRetry* pair in this file,
	-- all feeding Shared/DataStoreRetry.lua (see that module's header).
	StorageRetryMaxAttempts = 3,
	StorageRetryBaseBackoffSeconds = 1,

	-- Client-side debounce (MoveEditorClient.lua) between a PropertyEditor field edit and the
	-- UpdateDraft RemoteFunction call it triggers -- long enough that rapidly clicking a NumericField
	-- stepper doesn't fire one round trip per click, short enough that the live 3D preview and the
	-- in-memory registry both still feel instantaneous to the admin editing it.
	DraftDebounceSeconds = 0.15,

	-- Per-field authoring bounds for the Object Stun block (Types.ObjectStunConfig), and the
	-- starting values a freshly-enabled Object Stun gets. ONE table read by three consumers that
	-- must not disagree: MoveRegistryManager.Validate clamps against Limits, PropertyEditor's own
	-- ObjectStunEditor renders NumericField Min/Max from the same Limits, and both the editor and
	-- the validator build a brand-new config from Defaults -- so a value the UI lets an admin type
	-- can never be one the server silently rewrites.
	--
	-- The equivalent tables for the other two new sub-schemas deliberately live with their own
	-- modules instead (HitboxShapes.FIELD_SPECS, AnimationTimeline.Limits) because those modules own
	-- geometry/scheduling semantics that the bounds are part of. Object Stun has no such module on
	-- the shared side -- its runtime is server-only -- so its bounds live here with the rest of the
	-- editor's configuration.
	ObjectStun = {
		Limits = {
			MinSurfaceExtentStuds = { Min = 0, Max = 20 },
			ProbeDistanceStuds = { Min = 0.5, Max = 12 },
			RequiredClearanceStuds = { Min = 0, Max = 40 },
			MinTravelStuds = { Min = 0, Max = 60 },
			MinImpactSpeed = { Min = 0, Max = 200 },
			MaxImpactAngleDegrees = { Min = 5, Max = 90 },
			MaxTravelSeconds = { Min = 0.1, Max = 6 },
			StunSeconds = { Min = 0, Max = 8 },
			RagdollSeconds = { Min = 0, Max = 8 },
			BonusDamage = { Min = 0, Max = 200 },
			BonusPostureDamage = { Min = 0, Max = 200 },
			ReboundVelocity = { Min = 0, Max = 150 },
			PinSeconds = { Min = 0, Max = 6 },
			CameraShakeScale = { Min = 0, Max = 4 },
			CooldownSeconds = { Min = 0, Max = 30 },
			MaxTriggersPerMove = { Min = 1, Max = 10 },
			FollowUpDelaySeconds = { Min = 0, Max = 3 },
			FollowUpTeleportDistanceStuds = { Min = 2, Max = 20 },
			-- The follow-up's own timing/damage reuse the parent move's own clamp band rather than
			-- getting a second, subtly-different one -- see MoveRegistryManager's CLAMP_MIN/MAX_
			-- SECONDS and CLAMP_MIN/MAX_DAMAGE, which the follow-up validator calls directly.
			FollowUpMaxTargets = { Min = 1, Max = 20 },
		},

		-- What "Enable Object Stun" starts as: a wall-slam that requires a real launch (three studs
		-- of clearance behind the target at the moment of the hit, four studs actually travelled, a
		-- solid 35 studs/second on contact, within 55 degrees of head-on), pins them briefly, and
		-- deals a modest bonus. Deliberately conservative on the causation gates -- the first time
		-- an author enables this, it should fire when they slam someone into a wall and stay quiet
		-- otherwise, because a mechanic that triggers spuriously on the first try reads as broken.
		Defaults = {
			Surfaces = { Walls = true, Floors = false, Ceilings = false, Props = false },
			RequireAnchored = true,
			RequirePartTag = "",
			MinSurfaceExtentStuds = 3,
			ProbeDistanceStuds = 2.5,
			RequiredClearanceStuds = 3,
			MinTravelStuds = 4,
			MinImpactSpeed = 35,
			MaxImpactAngleDegrees = 55,
			MaxTravelSeconds = 1.5,

			StunSeconds = 1.2,
			RagdollSeconds = 0.8,
			BonusDamage = 8,
			BonusPostureDamage = 12,
			ReboundVelocity = 0,
			PinSeconds = 0.6,
			VictimAnimationId = "",
			AttackerAnimationId = "",
			SoundId = "",
			EffectColor = Color3.fromRGB(255, 180, 90),
			CameraShakeScale = 1,

			CooldownSeconds = 2,
			MaxTriggersPerMove = 1,
		},

		-- What "Enable Follow-Up" starts as: a fast, tight, close-range punish into the pinned
		-- target, thrown a quarter-second after impact. Small Box rather than the parent move's own
		-- shape for the reason Types.ObjectStunFollowUp's header gives -- a follow-up is a different
		-- attack, not a repeat of the launcher.
		FollowUpDefaults = {
			DelaySeconds = 0.25,
			AnimationId = "",
			WindupSeconds = 0.1,
			ActiveSeconds = 0.15,
			RecoverySeconds = 0.25,
			Damage = 12,
			PostureDamage = 10,
			MaxTargets = 1,
			Shape = "Box",
			OffsetX = 0,
			OffsetY = 0,
			OffsetZ = -3,
			TeleportAttacker = false,
			TeleportDistanceStuds = 5,
		},
	},

	-- Admin-only, same trust model as Constants.Debug.DevMenu -- every RemoteFunction below is
	-- gated by MoveEditorSystem's own checkMoveEditorPreconditions (AdminConfig.AuthorizedUserIds +
	-- a dedicated rate-limit bucket), mirroring DevMenuSystem.lua's own checkDevMenuPreconditions.
	RemoteNames = {
		ListMoves = "MoveEditor_ListMoves",
		GetMove = "MoveEditor_GetMove",
		UpdateDraft = "MoveEditor_UpdateDraft",
		SaveMove = "MoveEditor_SaveMove",
		DeleteMove = "MoveEditor_DeleteMove",
		TestFireMove = "MoveEditor_TestFireMove",
		SpawnPreviewDummy = "MoveEditor_SpawnPreviewDummy",
		-- "Default" moves (every hand-authored weapon Basic/Heavy/Finisher stage plus DashPunch/
		-- DashHit/AirSlam) -- Server/Combat/DefaultMoveRegistry.lua's live Constants-mutating sibling
		-- to ListMoves/UpdateDraft above, formerly DevMenu's "Hitbox Timing"/"Standalone Attacks"
		-- Tuning-tab tools. No DeleteMove/TestFireMove equivalent exists for a Default move -- see
		-- DefaultMoveRegistry.lua's own header for why (never deletable, no TestFireMove dispatch
		-- path). SaveDefaultMove DOES persist -- unlike a hand-copy-to-Constants.lua-only edit, an
		-- admin's live-tuned Default move value survives a server restart via a small
		-- DataStore-backed override record (MoveEditorSystem.lua's own header) keyed by MoveId, kept
		-- in the SAME DataStore as custom moves (StorageConfig.CustomMoveDataStoreName) under a
		-- "DefaultOverride_<MoveId>" key so it never collides with a "Move_<MoveId>" custom-move
		-- record.
		ListDefaultMoves = "MoveEditor_ListDefaultMoves",
		UpdateDefaultMoveDraft = "MoveEditor_UpdateDefaultMoveDraft",
		SaveDefaultMove = "MoveEditor_SaveDefaultMove",
		ResetDefaultMove = "MoveEditor_ResetDefaultMove",
		-- Fire-and-forget (RemoteEvent, not RemoteFunction -- no response needed): tells the server
		-- the admin's own editor screen just opened/closed, so it can freeze/unfreeze their character
		-- via the existing AdminActionSystem.SetFrozen (the same mechanism/Humanoid Attribute an
		-- admin's own "Frozen" DevMenu toggle already uses) -- editing a move's numbers shouldn't
		-- leave the admin's own character walking around or swinging mid-edit.
		SetEditorOpen = "MoveEditor_SetEditorOpen",
	},
}

-- Live Admin Console (F7) -- whitelist-gated, same trust model as Constants.Debug.DevMenu/
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
	-- Client-side render cap (Client/LiveConsole/LiveConsoleClient.lua) -- oldest rendered lines are
	-- trimmed past this so a long-open console can't grow its own UI list unbounded.
	ClientRenderCap = 1000,
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

-- Admin/dev-menu "Superman flight" tunables (Client/DevMenu/FlightController.lua/FlightPhysics.lua,
-- Client/Camera/FlightCamera.lua, Client/FX/FlightAnimator.lua/FlightAudio.lua/FlightVFX.lua).
-- Toggled via AdminActionSystem.SetFlying/SetFlightCollide, whitelist-gated by
-- DevMenuSystem.lua -- never player-facing. Movement feel only, per this feature's own scope: no
-- new attack/damage numbers live here (see Constants.Combat for those).
Constants.Flight = {
	-- Baseline cruise speed with no boost held -- same number the old bare-noclip FlightController's
	-- FLIGHT_SPEED used, so a non-boosted flight keeps its established travel-observation pace.
	CruiseSpeed = 60,
	-- Boosted top speed = CruiseSpeed * this. 1.8x reads as a genuine "kick it into high gear"
	-- without breaking Collide mode's usefulness for map-navigability testing (still controllable).
	BoostSpeedMultiplier = 1.8,
	-- Studs/s^2 ramp toward the desired velocity while NOT boosting -- reaches CruiseSpeed in 0.75s,
	-- fast enough to feel responsive, slow enough to read as momentum rather than an instant snap.
	Acceleration = 80,
	-- Studs/s^2 ramp while boosting -- snappier than base Acceleration so holding Boost reads as an
	-- active push, not just a higher ceiling.
	BoostAcceleration = 140,
	-- Studs/s^2 ramp-down when input is released/reversed -- deliberately higher than Acceleration
	-- (brakes harder than it accelerates), which is what makes flight feel steerable rather than
	-- boat-like when trying to hold position over a specific spot.
	Deceleration = 120,
	-- Vertical (Space/LeftControl) axis speed as a fraction of the CURRENT horizontal-equivalent max
	-- speed, so climbing/descending isn't as fast as forward cruise -- reads as flight, not an
	-- elevator.
	VerticalSpeedFraction = 0.7,
	-- Max roll (banking into a turn), in degrees -- Superman-style lean, not an arcade-flight-sim
	-- barrel roll.
	MaxBankAngleDegrees = 35,
	-- Max pitch (nose up/down with vertical intent or speed change), in degrees.
	MaxPitchAngleDegrees = 25,
	-- How strongly yaw turn-rate (radians/sec) maps to bank angle before MaxBankAngleDegrees clamps
	-- it -- see Shared/FlightMath.ComputeBankAngle. Higher = a gentler turn already reads as a hard
	-- lean.
	BankTurnRateSensitivity = 2.5,
	-- Ease rate (alpha = 1 - e^(-rate*dt), same idiom as Constants.Camera.ShiftLock.OffsetLerpSpeed)
	-- for the RENDERED orientation (bank/pitch/facing) chasing its target every frame -- separates
	-- "how quickly should velocity change" (Acceleration/Deceleration above) from "how quickly should
	-- the BODY visually lean into that change," which is what actually reads as inertia instead of a
	-- rigid nose always pointed exactly at the input vector.
	OrientationResponsiveness = 8,
	-- Initial upward kick (studs/s) applied the instant Flying flips true while grounded -- a real
	-- "leap into the air" launch beat rather than gently floating off the ground.
	TakeoffBurstUpSpeed = 22,
	-- Initial forward kick (studs/s), same launch beat, biased toward current facing.
	TakeoffBurstForwardSpeed = 10,
	-- Downward raycast distance (studs) used at flight-start to decide "was this character grounded"
	-- -- gates whether the takeoff burst/dust/sound play at all (skip them if flight was toggled on
	-- already mid-air).
	TakeoffGroundCheckStuds = 4,
	-- Small vertical sine-wave offset (studs) blended in only near-zero speed (see
	-- HoverSpeedThreshold) so hovering in place doesn't read as frozen in space.
	HoverBobAmplitudeStuds = 0.35,
	HoverBobPeriodSeconds = 2.2,
	-- Below this speed (studs/s) the hover bob blends fully in; above it, blends fully out -- avoids
	-- a visible seam at a hard cutoff.
	HoverSpeedThreshold = 4,
	-- Downward raycast distance (studs) used every flight frame to detect ground proximity for the
	-- IN-FLIGHT landing/graze event (Collide-mode skimming the ground) -- separate from the
	-- post-flight free-fall landing path (RecentlyFlyingGraceSeconds below), which uses the
	-- Humanoid's own native Landed state instead.
	LandingRaycastDistance = 4,
	-- Must climb back above this height (studs) after a landing event before another one can fire --
	-- debounces repeatedly re-triggering while skimming/hovering just off the ground.
	LandingRearmHeightStuds = 3,
	-- Downward speed (studs/s) below which a ground touch is ignored entirely (no soft/hard event,
	-- no FX) -- a light graze while flying low shouldn't spam a landing thump.
	LandingSpeedDeadzone = 3,
	-- Minimum seconds between landing-fire re-arms -- a live playtest showed the position-only rearm
	-- (LandingRearmHeightStuds) can fire twice within a few milliseconds (a brief touch-clear-touch
	-- flicker right at the moment of landing); this adds a time floor alongside it.
	LandingFireDebounceSeconds = 0.5,
	-- Downward speed (studs/s) below which a landing is "soft" (light thump, brief anim, no camera
	-- shake/hit-stop).
	SoftLandingSpeedThreshold = 15,
	-- Downward speed (studs/s) at/above which a landing is "hard" (full shockwave: camera shake +
	-- pooled ring VFX + brief hit-stop) -- see Constants.FX.FlightLandingRing/HitStop fields.
	HardLandingSpeedThreshold = 45,
	-- Seconds after Flying flips false during which a genuine free-fall-to-ground landing (detected
	-- via the Humanoid's native Landed state, not this module's own raycast) still counts as a
	-- flight landing for shockwave purposes -- covers "flew up high, turned flight off, fell, hit the
	-- ground," the natural way an admin actually ends a flight session from altitude.
	RecentlyFlyingGraceSeconds = 3,
	-- Horizontal speed (studs/s) at/above which crossing the threshold triggers the sonic-boom
	-- one-shot -- set just under max boosted cruise (60 * 1.8 = 108) so it's reachable only while
	-- boosting, not on a plain cruise.
	SonicBoomSpeedThreshold = 95,
	-- Minimum seconds between sonic-boom triggers while sustained above threshold -- without this a
	-- boosted straight-line flight would refire it every frame.
	SonicBoomCooldownSeconds = 4,
	-- Collide toggle's default when a character has never had it explicitly set (GetAttribute
	-- returns nil) -- false = noclip, matching this feature's locked-in default (map-observation
	-- flight bypasses collision unless an admin opts into Collide).
	DefaultCollideMode = false,
	-- Collide-mode LinearVelocity.MaxForce (Client/DevMenu/FlightPhysics.lua's EnterCollideMode) -- how
	-- hard the velocity drive is allowed to push the flying character's rootPart toward its commanded
	-- velocity every frame. Large-but-finite rather than math.huge: too low and the character's own
	-- momentum/gravity fights the drive (reads sluggish, sinks below the commanded path); too high and
	-- wall contact reads as a violent stop instead of a controlled halt. Was a module-local constant in
	-- FlightPhysics.lua, itself flagged in that file's own comment as "a Studio-tune item" -- moved here
	-- alongside every other Flight tunable so a future live-tuning pass (Server/DevMenu/FlightTuning.lua,
	-- same fetch-once/adjust/reset shape as the hitbox timing tuner) has the option to expose it without
	-- the number living somewhere that tool can't already reach.
	VelocityDriveMaxForce = 100000,

	-- One shared placeholder clip (rbxassetid://125167812303491, user-supplied) across every slot
	-- for now -- no distinct per-state animations exist yet, so every flight pose/transition reuses
	-- the same clip until real ones are authored. Loop states (Hover/CruiseLoop/BoostLoop) vs
	-- one-shots (Takeoff/LandingSoft/LandingHard) -- see FlightAnimator.lua's own header for which
	-- is which. Swap any individual slot to its own id later with no code change, same
	-- wired-but-unauthored convention as Constants.Combat.AnimationIds' Heavy1/Heavy2/etc.
	AnimationIds = {
		Takeoff = "rbxassetid://125167812303491",
		LandingSoft = "rbxassetid://125167812303491",
		LandingHard = "rbxassetid://125167812303491",
		Hover = "rbxassetid://125167812303491",
		CruiseLoop = "rbxassetid://125167812303491",
		BoostLoop = "rbxassetid://125167812303491",
	} :: { [string]: string },

	-- Sound registrations (Client/FX/FlightAudio.lua registers these with SoundManager.lua at load).
	-- Empty SoundId is the same safe placeholder SoundManager.Play already no-ops on. No PoolSize --
	-- unlike Constants.Combat.Sound's hit/block/parry trio, none of these can naturally re-trigger
	-- faster than they finish playing (you can't take off or land twice in the same second), so the
	-- single-instance default is correct here, not an oversight.
	Sound = {
		Takeoff = { SoundId = "", Volume = 0.6 } :: SoundDefinition,
		LandingSoft = { SoundId = "", Volume = 0.5 } :: SoundDefinition,
		LandingHard = { SoundId = "", Volume = 0.85 } :: SoundDefinition,
		SonicBoom = { SoundId = "", Volume = 0.9 } :: SoundDefinition,
		-- Continuous wind-rush loop (SoundManager.PlayLooped/StopLooped, new capability -- see
		-- FlightAudio.lua). LoopSoundDefinition, not SoundDefinition -- a loop has no single Volume,
		-- only a ramped range: Volume/PlaybackSpeed are eased every frame between these bounds based
		-- on current speed fraction (FlightAudio.SetWindIntensity), not fixed values like every
		-- sibling above.
		WindLoop = {
			SoundId = "",
			MaxVolume = 0.5,
			MinPlaybackSpeed = 0.9,
			MaxPlaybackSpeed = 1.3,
		} :: LoopSoundDefinition,
	},
}

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

-- Client-only impact-feel tunables (Client/FX/CameraShake.lua, HitStop.lua, HitFlash.lua). These
-- never affect a gameplay OUTCOME -- they're driven exclusively off server-validated
-- Combat_FeedbackEvent resolutions (CombatClient.lua) and only shape how a confirmed hit LOOKS on
-- the acting/receiving client, so they live here as presentation tunables (like Constants.Camera),
-- not under Constants.Combat, and are deliberately absent from validateCombatConstants -- a missing
-- preset degrades to "no shake/no freeze," never to a wrong hit. EXCEPTION: MovementDust below (and
-- CameraShake.SlideStart, Constants.Camera.Sprint/Slide) are driven off LOCAL input/held-state
-- (Sprint held, Slide predicted-press) rather than a Combat_FeedbackEvent -- the same category
-- CombatAnimator's own Running/Walking crossfade already falls into, since raised WalkSpeed itself
-- has nothing a client needs to roll back from.
Constants.FX = {
	-- Camera shake presets. Amplitude is peak rotational offset in RADIANS (0.03 ~= 1.7 deg),
	-- Frequency the noise oscillation rate (higher = jitterier), DurationSeconds the decay time --
	-- CameraShake eases each to zero over its duration (see that module). Scaled by impact weight:
	-- a light basic hit barely nudges, a posture break / finisher slam rocks the frame.
	CameraShake = {
		HitLight = { Amplitude = 0.012, Frequency = 28, DurationSeconds = 0.18 },
		HitHeavy = { Amplitude = 0.025, Frequency = 24, DurationSeconds = 0.28 },
		Parry = { Amplitude = 0.03, Frequency = 34, DurationSeconds = 0.22 },
		PostureBreak = { Amplitude = 0.045, Frequency = 20, DurationSeconds = 0.4 },
		FinisherSlam = { Amplitude = 0.05, Frequency = 18, DurationSeconds = 0.45 },
		-- One-shot kick at Slide-start (CombatClient.lua's predictSlide/Combat_SlidePerformed) --
		-- lighter than any combat preset, a movement flourish rather than an impact.
		SlideStart = { Amplitude = 0.02, Frequency = 22, DurationSeconds = 0.2 },
		-- Per-axis math.noise decorrelation offsets so pitch/yaw/roll wander independently instead of
		-- in lockstep (which would read as a single diagonal jerk rather than a shake).
		NoiseSeeds = { Pitch = 0, Yaw = 37.2, Roll = 91.7 },
	},

	-- Hit-stop (freeze-frame) durations, in seconds. Purely a client-visual pause of the involved
	-- players' OWN combat animation tracks (never the server clock -- see HitStop.lua/decision (d)):
	-- the attacker gets a crisp short contact freeze, the victim a slightly longer one on their
	-- hit-reaction, with weightier events (heavy, parry, posture break) holding longer. HeavyBonus
	-- is added to the base attacker/victim freeze on a heavy hit. MinIntervalSeconds throttles
	-- back-to-back freezes so a multi-target swing can't chain them into slow motion.
	HitStop = {
		AttackerSeconds = 0.06,
		VictimSeconds = 0.09,
		HeavyBonusSeconds = 0.03,
		ParrySeconds = 0.12,
		PostureBreakSeconds = 0.14,
		MinIntervalSeconds = 0.1,
		-- Flight landing-impact freeze (HitStop.FreezeFlightLanding, Client/FX/FlightAnimator.
		-- FreezeActiveFlightTrack) -- much lighter than a combat hit-stop since this is cosmetic
		-- feedback, not a clash beat; Hard is closer to PostureBreakSeconds' weight (a real, heavy
		-- landing), Soft barely more than a single frame.
		FlightLandingSoftSeconds = 0.05,
		FlightLandingHardSeconds = 0.16,
	},

	-- Victim hit-flash (a pooled Highlight, HitFlash.lua). DurationSeconds is how long the flash
	-- holds before fading; the color per resolution reads the same family the rest of combat
	-- feedback uses (white = a plain hit, gold = a parry deflection, red-gold = a posture break).
	HitFlash = {
		DurationSeconds = 0.12,
		-- Pool hard cap -- well under Roblox's 31-Highlight render limit (see HitFlash.lua), since
		-- this melee system only ever flashes the handful of characters in one player's view at once.
		PoolMaxSize = 6,
		HitColor = Color3.fromRGB(255, 255, 255),
		ParryColor = Color3.fromRGB(220, 180, 90),
		PostureBreakColor = Color3.fromRGB(230, 120, 70),
		-- The "parry window is OPEN right now" tell (HitFlash.FlashHold) -- a bright metal-blue
		-- highlight held for the whole window so an ATTACKER can read "they're parry-armed, be
		-- careful" and everyone (the same broadcast drives every client) sees who's about to deflect.
		-- Same BorderAccent steel-blue family as the aim/parry reticles (LockOnReticle/
		-- ShiftLockCrosshair/ParryReadyGlint) -- deflection reads as steel, distinct from the
		-- white/gold/red impact colours above so the "armed" tell can't be mistaken for a landed hit.
		ParryWindowColor = Color3.fromRGB(120, 200, 255),
		-- ONLY read by FlashHold (the ParryWindow tell) -- the one-shot Flash (Hit/Parry/PostureBreak)
		-- stays an instant pop, deliberately: those react to an impact that already happened, and a
		-- fast snap is what reads as "contact, right now" (same reasoning as Animation.Combat's
		-- SwingFadeSeconds comment). FlashHold is different: it opens on every parry-armed block press,
		-- not just a landed hit, so an instant full-opacity pop-in fired that often reads as a flicker/
		-- twitch rather than a clean reveal. Easing it in over a short window instead lets it read as a
		-- deliberate "guard tightening into a parry stance" rather than a jarring on/off snap -- part of
		-- the parry-feel pass that also retimed CombatAnimator's ParryFlashFadeSeconds for the same
		-- reason (see that constant's own comment).
		HoldFadeInSeconds = 0.08,
	},

	-- Floating combat-feedback numbers (Client/UI/Screens/CombatFeedback/init.lua).
	DamageNumbers = {
		-- How long a spawned one-off damage number (e.g. "PARRIED") stays in the list before being
		-- pruned -- comfortably longer than DamageNumberLabel's own rise-and-fade.
		LifetimeSeconds = 1.1,
		-- How long a damage stack stays open for the next hit to add onto before the next hit starts
		-- a fresh stack instead.
		StackWindowSeconds = 1,
	},

	-- Local parry-ready glint (Client/UI/Components/ParryReadyGlint.lua) -- CombatFeedback owns the
	-- one-shot drive (HoldSeconds at full intensity, then eases back out via Tokens.Motion.GlintSpring).
	ParryReadyGlint = {
		HoldSeconds = 0.12,
	},

	-- Flight VFX (Client/FX/FlightVFX.lua) -- a single pooled "ring" Part factory reused across all
	-- three presets below rather than three separate pools, keeping the instance/pool-cap budget
	-- small per performance-optimization.md (this is a single-admin debug tool, not a multi-player
	-- combat effect that needs headroom for many concurrent instances).
	FlightRingPool = {
		PoolMaxSize = 8,
		-- Ring's starting state before it tweens out to a preset's MaxRadiusStuds/full transparency.
		StartSize = Vector3.new(0.2, 0.5, 0.5),
		StartTransparency = 0.2,
	},
	FlightTakeoffDust = {
		MaxRadiusStuds = 6,
		ExpandDurationSeconds = 0.4,
		Color = Color3.fromRGB(235, 235, 245),
	},
	FlightLandingRing = {
		SoftMaxRadiusStuds = 8,
		HardMaxRadiusStuds = 16,
		ExpandDurationSeconds = 0.5,
		SoftColor = Color3.fromRGB(200, 215, 255),
		HardColor = Color3.fromRGB(255, 220, 140),
	},
	FlightSonicBoom = {
		MaxRadiusStuds = 24,
		ExpandDurationSeconds = 0.35,
		Color = Color3.fromRGB(255, 255, 255),
	},

	-- Ground dust (Client/FX/MovementVFX.lua) -- pooled ParticleEmitters kicked up under the feet
	-- while sprinting (a steady trickle) or on Slide-start (one bigger burst), colored by the
	-- standing surface's Humanoid.FloorMaterial. Placeholder Color3 values -- retune in Studio once
	-- the actual look is visible; these are first-pass guesses, not sourced from a real reference.
	MovementDust = {
		-- A real dust-puff sprite (soft round smoke/dirt cloud, NOT Roblox's default ParticleEmitter
		-- texture -- that default is a 4-point sparkle/star, which is exactly what an untextured
		-- emitter here rendered as). Sourced from the reference "Running Model.rbxm" asset the user
		-- supplied (its own Dust ParticleEmitter used this same id) -- not fabricated, per this
		-- codebase's own "never guess an asset id" rule (see CombatAudio.lua/VitalIcon.lua headers).
		Texture = "rbxassetid://122434532",
		-- Well under the same render-budget spirit as HitFlash's PoolMaxSize -- this only ever needs
		-- to cover the handful of puffs alive under one moving player's own feet at once.
		PoolMaxSize = 16,
		-- Fixed approximation of the ground point below HumanoidRootPart -- no raycast per puff (see
		-- this feature's own scope notes on why).
		FootOffsetStuds = 3,
		TrickleIntervalSeconds = 0.15,
		TrickleParticleCount = 5,
		SlideBurstParticleCount = 20,
		-- Also schedules the pooled carrier Part's own Release() back to the pool.
		ParticleLifetimeSeconds = 0.6,
		-- Fraction of ParticleLifetimeSeconds used as the jittered LOW end of the emitter's own
		-- Lifetime NumberRange (the high end is ParticleLifetimeSeconds itself).
		LifetimeJitterFraction = 0.6,
		-- The invisible carrier Part's own Size -- never rendered (Transparency = 1), just needs to
		-- exist to host the ParticleEmitter.
		CarrierPartSize = Vector3.new(0.2, 0.2, 0.2),
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(40, 40),
		SizeSequence = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.4, 0.6),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		TransparencySequence = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		-- Deliberately broader than just the "natural terrain" materials -- Studio's own default
		-- baseplate is Plastic, and a stone-family surface could plausibly be authored as any of
		-- Rock/Slate/Basalt/Cobblestone/Granite/Limestone/Sandstone/Pavement/Asphalt/Concrete, not
		-- just "Rock" -- without an entry, a material silently falls through to DefaultColor
		-- regardless of what it actually looks like, which reads as "the color never changes."
		ColorByFloorMaterial = {
			[Enum.Material.Grass] = Color3.fromRGB(90, 75, 45),
			[Enum.Material.LeafyGrass] = Color3.fromRGB(90, 75, 45),
			[Enum.Material.Sand] = Color3.fromRGB(210, 190, 140),
			[Enum.Material.Concrete] = Color3.fromRGB(175, 175, 175),
			[Enum.Material.Pavement] = Color3.fromRGB(170, 170, 170),
			[Enum.Material.Asphalt] = Color3.fromRGB(90, 90, 95),
			[Enum.Material.Rock] = Color3.fromRGB(120, 110, 100),
			[Enum.Material.Slate] = Color3.fromRGB(110, 110, 115),
			[Enum.Material.Basalt] = Color3.fromRGB(70, 70, 75),
			[Enum.Material.Cobblestone] = Color3.fromRGB(130, 125, 120),
			[Enum.Material.Granite] = Color3.fromRGB(140, 130, 130),
			[Enum.Material.Limestone] = Color3.fromRGB(190, 180, 160),
			[Enum.Material.Sandstone] = Color3.fromRGB(200, 175, 135),
			[Enum.Material.Marble] = Color3.fromRGB(210, 205, 200),
			[Enum.Material.Wood] = Color3.fromRGB(130, 95, 65),
			[Enum.Material.WoodPlanks] = Color3.fromRGB(130, 95, 65),
			[Enum.Material.Snow] = Color3.fromRGB(235, 235, 245),
			[Enum.Material.Ice] = Color3.fromRGB(210, 230, 240),
			[Enum.Material.Mud] = Color3.fromRGB(80, 60, 40),
			[Enum.Material.Ground] = Color3.fromRGB(100, 85, 60),
			-- Studio's own default baseplate material -- without this, a fresh test place with no
			-- terrain shows the flat DefaultColor below regardless of the part's own BrickColor.
			[Enum.Material.Plastic] = Color3.fromRGB(160, 150, 145),
		} :: { [Enum.Material]: Color3 },
		DefaultColor = Color3.fromRGB(150, 140, 130),
	},

	-- Ground-impact payoff for a Downslam finisher (Client/FX/SlamImpactVFX.lua) -- a particle burst +
	-- physical debris chunks + an expanding shockwave ring, fired once the client's own local watch of
	-- the replicated ragdoll (RagdollController.SlamToGround has no ground-contact event of its own --
	-- see that function's header) detects the body's downward fall actually arresting. Purely local
	-- presentation, same as every other table in Constants.FX -- see SlamImpactVFX.lua's own header
	-- for the full detection mechanism.
	SlamImpact = {
		-- A body must first be observed falling at least this fast (studs/s, downward) before an
		-- "arrest" is trusted as a real ground contact -- without this gate, the first Heartbeat tick
		-- or two after the slam lands (before the server's own -SlamDownVelocity has replicated to
		-- this client) would read as an instant, false "already landed" arrest.
		FastFallSpeedThreshold = 20,
		-- Downward speed (studs/s) at/under which a previously-fast-falling body counts as having hit
		-- the ground -- Roblox's own physics resolver stops a falling part hard on contact well before
		-- it would ever coast down to an exact zero, so this stays comfortably above 0 rather than
		-- waiting for a stop that may never exactly happen.
		ImpactArrestSpeedThreshold = 4,
		-- Upper bound (seconds) SlamImpactVFX.BeginWatch keeps polling before giving up with no VFX --
		-- covers the target dying/despawning mid-fall, falling into the void, or landing somewhere that
		-- never reads as a clean arrest. Comfortably longer than Finisher.Downslam.KnockdownSeconds
		-- (1.25) so a normal slam always has time to resolve before this fires.
		MaxWatchSeconds = 2.5,
		-- Fixed settle delay BeginWatch uses instead of polling when the server already reported the
		-- impact as immediate (Types.CombatFeedbackPayload.ImmediateGroundImpact -- see Constants.
		-- Combat.Ragdoll.SlamImmediateImpactDropStuds for why the server can know this and the client's
		-- own polling structurally can't). Not a detection window -- there's nothing left to detect --
		-- just enough of a beat for the ragdoll's own collapse to visibly begin before the ground VFX
		-- bursts, so the two don't look like they fired in the wrong order.
		ImmediateImpactDelaySeconds = 0.06,
		-- Raycast straight down from the detected impact point to find the actual ground BasePart/
		-- Terrain voxel hit -- this is the "color/mesh of what they were slammed on." StartHeightStuds
		-- lifts the origin above the body's own root position (so the ray doesn't start already inside
		-- the ground or the ragdoll's own geometry); DistanceStuds is how far down it searches.
		GroundRaycastStartHeightStuds = 3,
		GroundRaycastDistanceStuds = 12,

		-- Reuses MovementDust's own dust-puff sprite (Constants.FX.MovementDust.Texture) rather than a
		-- second copy -- see that field's own header for why THAT specific texture, not Roblox's
		-- default 4-point-sparkle ParticleEmitter texture, is the only dust sprite this codebase has
		-- actually sourced. A slam impact reuses the SAME sprite as footstep dust (both read as "kicked
		-- up ground material"), just a much bigger one-shot burst.
		Particle = {
			PoolMaxSize = 6,
			BurstCount = 45,
			Speed = NumberRange.new(8, 18),
			SpreadAngle = Vector2.new(60, 60),
			LifetimeSeconds = 0.7,
			SizeSequence = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.6),
				NumberSequenceKeypoint.new(0.35, 1.4),
				NumberSequenceKeypoint.new(1, 0.2),
			}),
			TransparencySequence = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			CarrierPartSize = Vector3.new(0.2, 0.2, 0.2),
		},

		-- Physical debris chunks -- pooled, non-anchored (real gravity + launch velocity/spin carry
		-- them outward and tumbling), but CanCollide/CanQuery/CanTouch = false like every other
		-- cosmetic Part this FX library spawns (MovementVFX's dust carrier, FlightVFX's ring): a chunk
		-- that could physically collide with players or geometry would be a gameplay-affecting side
		-- effect (a stray hitbox, a ledge to stand on) for a purely cosmetic flourish, and full
		-- rigid-body collision on client-only instances this short-lived costs more than it buys. They
		-- fade out and release well before the missing ground collision would ever read as "falling
		-- through the floor."
		Debris = {
			PoolMaxSize = 20,
			Count = 10,
			LifetimeSeconds = 0.9,
			FadeOutSeconds = 0.25,
			-- Outward horizontal speed and upward pop, randomized per chunk within these ranges.
			OutwardSpeed = NumberRange.new(10, 24),
			UpwardSpeed = NumberRange.new(6, 16),
			AngularSpeed = NumberRange.new(-8, 8),
			-- Rock-family chunk size (roughly cubic, jittered per axis for a jagged look).
			RockSize = NumberRange.new(0.5, 1.4),
			-- Wood-family chunk size -- long and thin (a splinter/plank shard); X is the long axis.
			WoodLongSize = NumberRange.new(1.2, 2.6),
			WoodThinSize = NumberRange.new(0.15, 0.35),
			-- Soft-family (dirt/sand/snow/mud) clump size -- small round clods, smaller than a rock
			-- chunk.
			SoftSize = NumberRange.new(0.35, 0.8),
		},

		-- Impact shockwave ring -- same expanding-flat-ring shape/pattern as FlightVFX's own rings
		-- (Constants.FX.FlightLandingRing), but its OWN pool: a flight landing and a slam finisher are
		-- different enough moments that sharing FlightVFX's pool would mean a flurry of one competing
		-- with the other for pool slots.
		Ring = {
			PoolMaxSize = 6,
			StartSize = Vector3.new(0.2, 0.5, 0.5),
			StartTransparency = 0.1,
			MaxRadiusStuds = 14,
			ExpandDurationSeconds = 0.45,
		},

		-- Ground-material classification, purely for debris CHUNK SHAPE (jagged blocky rubble vs.
		-- elongated plank splinters vs. round soft clumps) -- the debris' actual Material/Color always
		-- comes directly from the raycast-detected ground hit (see SlamImpactVFX.lua), never a fixed
		-- per-family value, so this table only decides silhouette, never color. Mirrors the same
		-- material roster MovementDust.ColorByFloorMaterial above already curates (this codebase's
		-- approved "natural terrain materials" list) rather than inventing a second one that can drift
		-- from it. An unlisted material falls back to DefaultDebrisKind below, same "broader than the
		-- literal list, never silently blank" reasoning ColorByFloorMaterial's own header gives.
		DebrisKindByFloorMaterial = {
			[Enum.Material.Grass] = "Soft",
			[Enum.Material.LeafyGrass] = "Soft",
			[Enum.Material.Sand] = "Soft",
			[Enum.Material.Snow] = "Soft",
			[Enum.Material.Mud] = "Soft",
			[Enum.Material.Wood] = "Wood",
			[Enum.Material.WoodPlanks] = "Wood",
			[Enum.Material.Concrete] = "Rock",
			[Enum.Material.Pavement] = "Rock",
			[Enum.Material.Asphalt] = "Rock",
			[Enum.Material.Rock] = "Rock",
			[Enum.Material.Slate] = "Rock",
			[Enum.Material.Basalt] = "Rock",
			[Enum.Material.Cobblestone] = "Rock",
			[Enum.Material.Granite] = "Rock",
			[Enum.Material.Limestone] = "Rock",
			[Enum.Material.Sandstone] = "Rock",
			[Enum.Material.Marble] = "Rock",
			[Enum.Material.Ice] = "Rock",
			[Enum.Material.Ground] = "Rock",
			[Enum.Material.Plastic] = "Rock",
		} :: { [Enum.Material]: string },
		DefaultDebrisKind = "Rock",
	},

	-- Local-only stun screen dip (Client/FX/StunEffect.lua) -- a ColorCorrectionEffect brightness/
	-- saturation tween played when the local player's OWN attack gets parried (CombatSystem.lua's
	-- resolveHitAgainstTarget sets attackerState.stunExpiry to Constants.Combat.StunDuration on a
	-- successful parry against them). Were four module-local constants in StunEffect.lua (DIP_
	-- BRIGHTNESS/DIP_SATURATION/EASE_IN_SECONDS/EASE_OUT_SECONDS) -- moved here alongside every other
	-- FX preset in this table per this file's own single-source-of-truth header, even though nothing
	-- else currently reads them, so a future companion effect (e.g. a bot/AI reaction cue, or a
	-- posture-break screen treatment) has a named place to match against instead of re-guessing the
	-- numbers from scratch. "Slight"/"smooth": a small dip eased in and back out, never a jarring
	-- flash, per docs/ui-ux-philosophy.md's Critical States rule ("controlled animation... never
	-- excessive flashing") -- timed close to Constants.Combat.StunDuration so the visual reads as
	-- "this is how long you're locked out," not an arbitrary flourish.
	Stun = {
		DipBrightness = -0.15,
		DipSaturation = -0.3,
		EaseInSeconds = 0.08,
		EaseOutSeconds = 0.35,
	},

	-- Local-only death screen dip (Client/FX/DeathEffect.lua) -- a ColorCorrectionEffect brightness/
	-- saturation pull played on the LOCAL player's own screen for the death-to-respawn window
	-- (Client/Combat/CombatClient.lua's Kind == "Death" branch, gated to payload.TargetUserId being
	-- the local player -- the killer's own client receives the identical Death feedback payload and
	-- must never see their own screen dip for a kill they threw). Same asset-free ColorCorrectionEffect
	-- approach as Stun above (no VFX/particle asset to spend on this yet -- see that table's own
	-- header), but HELD rather than a fixed-duration one-shot: DeathEffect.Play()/Clear() are two
	-- explicit calls (no internal ease-out timer here) because the real duration is "however long
	-- this life's corpse-viewing window lasts" -- CombatClient.lua clears it off the new character's
	-- own CharacterAdded, not a client-side timer, so a respawn that lands early or late never
	-- desyncs the dip from reality. Deeper than Stun's brief lockout tell (a full death beat, not a
	-- momentary one) but still restrained per docs/ui-ux-philosophy.md's Critical States rule and
	-- combat-philosophy.md's "a setback, not a session-ender" framing -- darkens and desaturates
	-- without blacking out the screen, so the ragdolled corpse (RagdollController.lua's confirmDeath
	-- deliberately leaves it limp -- see that module's header) stays visible to look at rather than
	-- obscured.
	Death = {
		DipBrightness = -0.25,
		DipSaturation = -0.55,
		EaseInSeconds = 0.35,
		EaseOutSeconds = 0.45,
	},

	-- Combat/flight animation-track fade times and the shared cross-rig priority weight -- were THREE
	-- independently maintained copies with no shared reference point: Server/Combat/BotAnimator.lua (a
	-- training bot's server-driven equivalent of the player-facing animator below, since a bot has no
	-- owning Player/client to run that module for it), Client/FX/CombatAnimator.lua (the local player's
	-- own combat tracks -- swings, block/parry, dash/slide, hit reactions, locomotion crossfade), and
	-- Client/FX/FlightAnimator.lua (flight's Hover/CruiseLoop/BoostLoop + Takeoff/LandingSoft/
	-- LandingHard one-shots) each hand-typed their own SWING_FADE_TIME/BLOCK_HOLD_FADE_TIME/etc and
	-- DOMINANT_WEIGHT locals. BotAnimator.lua's own header even says outright "Same fade times/weight as
	-- Client/FX/CombatAnimator.lua" -- a comment ADMITTING the duplication rather than pointing at a
	-- shared value, exactly the drift risk engineering-standards.md's one-source-of-truth rule exists to
	-- close (retuning a fade in one file silently leaves the other two on the stale number). Sub-tabled
	-- Combat/Flight since the two animators' fade needs only partially overlap (BotAnimator has no
	-- locomotion crossfade or dash/slide clips; FlightAnimator has no swing/block/hit-reaction clips) --
	-- DominantWeight is the one number genuinely shared by all three files (see CombatAnimator.lua's own
	-- DOMINANT_WEIGHT header for why a value this far above Roblox's default character rig's own
	-- implicit walk/run weight is necessary at all: same-priority tracks BLEND by Weight rather than
	-- either cleanly winning, so this needs to be dominant enough to reliably override the rig's own
	-- baked-in Animate script). NOTE: CombatAnimator.lua's ROLLBACK_FADE_TIME is deliberately NOT
	-- duplicated in here -- it already reads Constants.Combat.Prediction.RollbackFadeSeconds directly, a
	-- single existing source, so there was nothing to centralize for that one.
	Animation = {
		-- CombatAnimator.lua/BotAnimator.lua's combat-track fades. Not every field is read by both
		-- files today (BotAnimator has no locomotion crossfade), but both read from this same table.
		Combat = {
			-- One-shot swings play snappy -- a fast fade-in reads as immediate/responsive.
			SwingFadeSeconds = 0.05,
			-- Walking<->Running crossfade (a start, or a toggle-driven handoff between the two loops)
			-- -- softer than a genuine interrupt (LocomotionInterruptFadeSeconds below), since this one
			-- wants a blend, not a cut.
			LocomotionFadeSeconds = 0.2,
			BlockHoldFadeSeconds = 0.1,
			-- Deliberately NOT as fast as Dash/Slide's 0.03 below despite looking like the same "one-shot
			-- accent" shape -- those two play PREDICTED, at the instant of input (CombatAnimator.
			-- PlayPredictedDash/PlayPredictedSlide), so a hard snap reads as "immediate response to my
			-- press." ParryFlash never gets that prediction (CombatAnimator.PlayParryFlash's own header:
			-- parry availability is server-cooldown-gated state the client can't guess) -- it only ever
			-- plays after a full round trip, landing on top of a BlockHold pose that already eased in
			-- BLOCK_HOLD_FADE_TIME ago. A 0.03s snap arriving unpredictably late, on top of an already-
			-- settled pose, reads as a jarring second pop instead of a responsive first one. Blending it
			-- in over roughly BlockHoldFadeSeconds' own timescale instead lets the parry-armed pose read
			-- as the guard stance settling further, not a new, disconnected flinch.
			ParryFlashFadeSeconds = 0.12,
			DashFadeSeconds = 0.03,
			SlideFadeSeconds = 0.03,
			HitReactionFadeSeconds = 0.05,
			-- A genuine locomotion interrupt (a combat action starting, or the character actually
			-- stopping) -- a fast cut, not the softer LocomotionFadeSeconds blend above.
			LocomotionInterruptFadeSeconds = 0.03,
		},
		-- FlightAnimator.lua's Hover/CruiseLoop/BoostLoop + Takeoff/LandingSoft/LandingHard fades.
		Flight = {
			OneShotFadeSeconds = 0.15,
			LoopFadeSeconds = 0.3,
		},
		-- Shared by all three files -- see this table's own header for why a value this far above 1
		-- is needed at all.
		DominantWeight = 100,
	},
}

-- THE RUN SYSTEM'S PRESENTATION TABLE -- everything about how running LOOKS and SOUNDS, in one
-- place, so retuning the run never means grepping three client modules.
--
-- The run is a three-stage sustained sprint (Shared/Run/RunConstants.lua's Stages ladder -- THAT
-- file, not this one, is the single source of truth for each stage's threshold and speed). Stage 1
-- is the ordinary sprint that has always existed; stages 2 and 3 each engage after their own
-- ChargeSeconds of unbroken running and are genuinely different gears -- a bigger WalkSpeed
-- multiplier, their own animation, their own footstep sound, a deeper FOV pull and a one-shot "kick"
-- at the moment they engage. The STAGE ITSELF is resolved server-side (Server/Systems/RunSystem.lua,
-- via Shared/Run/RunLadder.lua) and published on the Humanoid as Constants.Attributes.SprintStage;
-- nothing in this table decides when a stage changes, only what the client does about it.
--
-- Owned by Client/Movement/RunController.lua (the presentation driver) and Client/FX/RunAudio.lua
-- (the sound registrations). Lives here rather than in ParkourConstants.lua -- which owns movement
-- NUMBERS -- because this is presentation config in the same category as Constants.Flight.Sound and
-- Constants.FX, and because RunAudio's definitions need Constants' own SoundDefinition type.
Constants.Run = {
	-- FOOTSTEPS. There is no footstep audio in the base game (Roblox's own stock "Running" sound is a
	-- single looped scuff, not a step cadence), so this is a real system rather than a re-skin: the
	-- run controller re-derives a step interval every frame from live planar speed and fires a
	-- one-shot per footfall.
	--
	-- Interval-driven rather than animation-marker-driven on purpose. A marker-driven step
	-- (GetMarkerReachedSignal) is only as reliable as the authored markers in whatever clip is
	-- currently playing, and this system has to keep working through a placeholder-id stage-2 clip, a
	-- combat action silencing the run loop, and the parkour framework taking the body over mid-stride.
	-- Speed-scaled intervals need nothing from the asset and degrade to "slightly wrong cadence"
	-- instead of "no footsteps at all."
	Footsteps = {
		-- Master switch. False silences the whole footstep layer (the run keeps every other cue).
		Enabled = true,
		-- Whether to mute Roblox's own stock "Running" Sound on the character (the looped scuff the
		-- default RbxCharacterSounds script plays out of HumanoidRootPart). On by default because
		-- leaving it audible under real footsteps reads as two unrelated surfaces at once. Muted per
		-- life via Volume = 0 rather than destroyed -- the default script owns that Instance, and
		-- deleting something another script expects to exist is how you get a stream of errors from
		-- code you don't own.
		SilenceDefaultRunSound = true,

		-- Hard bounds on the scaled interval. The lower bound is what stops a momentum-carry burst
		-- from turning the cadence into a machine-gun; the upper bound stops a near-stopped player
		-- from taking one step every two seconds before the run states drop out entirely.
		MinIntervalSeconds = 0.15,
		MaxIntervalSeconds = 0.6,

		-- PER-STAGE STEP SOUND. Point these at whatever assets you want -- this is the one place step
		-- audio is configured, and Client/FX/RunAudio.SetStepSound can additionally swap either at
		-- runtime without a restart. An empty SoundId is the codebase's standard "not authored yet"
		-- placeholder: SoundManager.Play already no-ops on it, so shipping with one costs a debug log
		-- and nothing else.
		--
		-- PoolSize 3 because a footstep genuinely can re-trigger before the previous one finishes at
		-- stage-2 cadence -- the same overlap reasoning Constants.Combat.Sound's hit/block/parry trio
		-- documents. PitchJitter randomizes each play's PlaybackSpeed by +/- that fraction, which is
		-- the cheapest possible fix for the "identical sample on a metronome" effect a fixed-interval
		-- step system otherwise has.
		-- KEYED BY STAGE ID, not one flat field per stage. The ladder in Shared/Run/RunConstants.lua is
		-- an array precisely so a fourth gear is one entry; this table has to be able to grow the same
		-- way, or "add a stage" is a data change on the server and a code change on the client. Every
		-- reader (Client/FX/RunAudio.lua's registration sweep, Client/Movement/RunController.lua's
		-- cadence) iterates or indexes this table rather than naming StageN, and all of them fall back
		-- to stage 1 for a stage with no entry -- so a ladder that grows before its assets do degrades
		-- to "the new gear sounds like the old one" instead of going silent.
		--
		-- ReferenceSpeed is the speed that stage's StepIntervalSeconds was authored FOR. The live
		-- interval is scaled by ReferenceSpeed / currentSpeed, so a player slowed to a crawl takes
		-- slower steps and a downhill momentum carry takes faster ones, without any stage needing its
		-- own curve.
		Stages = {
			[1] = {
				StepIntervalSeconds = 0.33,
				ReferenceSpeed = 32,
				PitchJitter = 0.07,
				-- Sliced out of the combined asset: the first second is the speed whoosh (which belongs
				-- to StageOnset below, not to a footfall) and the second after it is a RUN of several
				-- steps. The region here is ONE step's worth out of that run, not the whole second -- a
				-- slice containing four footfalls, retriggered every 0.33s, would layer four-step bursts
				-- on top of each other rather than producing a stride.
				--
				-- 1.0 -> 1.25 is a first-pass slice; nudge the start by ear until it lands right on a
				-- step transient (a start slightly BEFORE the transient just adds a hair of silence,
				-- which is harmless -- starting slightly after clips the attack, which is what makes a
				-- footstep sound soft and wrong).
				Sound = {
					SoundId = "rbxassetid://76038309546970",
					Volume = 0.35,
					PoolSize = 3,
					PlaybackRegion = NumberRange.new(1.0, 1.25),
				} :: SoundDefinition,
			},
			[2] = {
				StepIntervalSeconds = 0.25,
				ReferenceSpeed = 48,
				PitchJitter = 0.07,
				-- PLAYBACK REGION (SoundDefinition.PlaybackRegion) -- the answer to "my stage-2 asset
				-- has a speed whoosh at the front and then the steps." The asset is laid out as one
				-- second of whoosh (0 -> 1.0, which belongs to StageOnset below) followed by one second
				-- of running footfalls (1.0 -> 2.0), so this entry takes ONE footfall out of that
				-- second, not the whole second -- a slice containing the entire run, retriggered every
				-- 0.25s, would layer multi-step bursts on top of each other rather than producing a
				-- stride. SoundManager applies it through Sound.PlaybackRegion/PlaybackRegionsEnabled,
				-- so the ENGINE does the trimming -- no task.delay-based "stop it after N seconds,"
				-- which is both jittery and one more timer to leak. Leave it out entirely for an
				-- ordinary one-sound-one-file asset.
				--
				-- Deliberately the SAME slice stage 1 uses: it's one recording of one surface, so a
				-- second footfall out of the same run (1.25 -> 1.5, if you want the stages to use
				-- distinct samples) would differ only by recording noise, and PitchJitter above already
				-- breaks the repetition. What actually separates the stages is cadence, volume and the
				-- onset kick, not the sample.
				Sound = {
					SoundId = "rbxassetid://76038309546970",
					Volume = 0.42,
					PoolSize = 3,
					PlaybackRegion = NumberRange.new(1.0, 1.25),
				} :: SoundDefinition,
			},
			-- THE THIRD GEAR. No dedicated asset yet -- it reuses stage 2's sample, louder and at a
			-- tighter cadence, which is the same "cadence and volume separate the stages, not the
			-- sample" reasoning stage 2's own note sets out. The ReferenceSpeed is what actually does
			-- the work here: authored for 72 rather than 48, so the scaling stays honest at a gear
			-- that genuinely moves half again as fast.
			--
			-- MinIntervalSeconds below is the real floor on how fast this can get. At 81 studs per
			-- second a 0.2s nominal cadence scales to roughly 0.18s, comfortably above the 0.15s floor,
			-- so the top gear has a distinct stride rather than sitting pinned against the clamp.
			[3] = {
				StepIntervalSeconds = 0.2,
				ReferenceSpeed = 72,
				PitchJitter = 0.07,
				Sound = {
					SoundId = "rbxassetid://76038309546970",
					Volume = 0.5,
					PoolSize = 3,
					PlaybackRegion = NumberRange.new(1.0, 1.25),
				} :: SoundDefinition,
			},
		},
	},

	-- THE ONSET KICK -- the one-shot that sells a gear change at the instant it engages, keyed by the
	-- stage being ENTERED. Plays once per upward transition into that stage, never on a loop, which is
	-- the other half of the "speed sound at the beginning, then step sounds" split above.
	--
	-- Stage 1 has no entry and deliberately so: engaging the run at all is not a gear CHANGE, it is the
	-- run starting, and it already has the run animation and the footstep cadence to announce it. A
	-- whoosh there would fire every time a player tapped the key.
	--
	-- FOVDelta is the additional pull layered on top of Constants.Camera.Sprint.FOVDelta while that
	-- stage is held (Client/FX/FOVOffset.lua's named-slot composition, so it stacks with the sprint
	-- slot rather than fighting it). Negative = narrower, matching Sprint's own convention. These are
	-- ABSOLUTE per stage, not cumulative -- RunController writes one slot and simply changes its target
	-- as the stage changes, so stage 3's -9 replaces stage 2's -5 rather than adding to it.
	StageOnset = {
		[2] = {
			-- The whoosh half of the combined asset -- see Footsteps.Stages[2]'s PlaybackRegion note.
			-- The whoosh occupies the first second and the footfall run starts at 1.0, so this stops
			-- exactly there: run it any longer and the gear change ends with a stray footstep layered
			-- on top of the real stride, which is heard as one step landing twice.
			Sound = {
				SoundId = "rbxassetid://74852553291807",
				Volume = 0.55,
				PlaybackRegion = NumberRange.new(0, 1.0),
			} :: SoundDefinition,
			FOVDelta = -5,
			FOVEaseSpeed = 4,
		},
		[3] = {
			-- Same whoosh, louder and pitched by the player's own ear rather than by a second asset --
			-- there is one speed-whoosh recording, and the top gear is the same event happening harder.
			-- Swap in a dedicated sample here when one exists; nothing else has to change.
			Sound = {
				SoundId = "rbxassetid://74852553291807",
				Volume = 0.7,
				PlaybackRegion = NumberRange.new(0, 1.0),
			} :: SoundDefinition,
			-- Nearly double stage 2's pull, and eased in faster. The top gear should be unmistakable
			-- from the camera alone -- a player who cannot tell which gear they are in has a ladder with
			-- no feedback, which is the same as no ladder.
			FOVDelta = -9,
			FOVEaseSpeed = 5,
		},
	},

	-- ANIMATION. Stage 1 keeps Constants.Combat.AnimationIds.Running (the clip that has always played
	-- while sprinting); stage 2 plays RunningStage2 when authored, stage 3 plays RunningStage3 when
	-- authored -- each falls through to the stage below it when its own id is blank (RunningStage3 ->
	-- RunningStage2 -> Running), the same blank-id fallthrough ParkourAnimator uses for its
	-- half-authored directional wall-jump pair, so this ships correctly at every stage of authoring.
	Animation = {
		-- Playback speed for the run loop, keyed by stage. Applied on stage CHANGE only, never per
		-- frame: CombatAnimator.FreezeActiveCombatTrack (hit-stop) drives the same property, and a
		-- per-frame write here would silently cancel every freeze that landed on a running player.
		--
		-- Also the fallback that makes an unauthored stage still feel distinct: while RunningStage3 is
		-- blank, stage 3 plays RunningStage2 (or Running, if THAT'S also blank) at this rate instead of
		-- its own clip -- see AnimationIds.RunningStage3's own header. Retune toward 1 once a real
		-- clip lands there, or it will read as sped-up/cartoonish rather than a distinct gear.
		PlaybackSpeeds = {
			[1] = 1,
			-- Slightly hot even when a dedicated stage-2 clip exists -- a full-stride run reads as
			-- urgent, and this is what makes stage 2 visibly different on day one.
			[2] = 1.25,
			-- Hot enough to read as a different gear from stage 2 while staying short of the rate at
			-- which a run clip starts to look like a cartoon. If a dedicated stage-3 clip lands, this
			-- should come back toward 1.
			[3] = 1.5,
		},
		-- Crossfade between the two run clips at a stage change. Longer than a combat interrupt cut
		-- (the two clips are the same character doing the same thing harder, so the transition should
		-- read as accelerating, not as swapping costumes) and shorter than a settle.
		StageCrossfadeSeconds = 0.2,
	},
}

-- DashPunch's own Windup/Active/Recovery seconds, factored out to local variables so
-- DashFrontCommitmentSeconds (below, in the main Constants.Combat table) can be DERIVED from
-- these instead of hand-duplicating their sum -- a Lua table constructor can't reference its own
-- other keys, hence the locals rather than just pointing at Constants.Combat.DashPunch.*. Before
-- this, DashFrontCommitmentSeconds was a separately-typed literal (0.45) that had to be manually
-- kept equal to WindupSeconds+ActiveSeconds+RecoverySeconds every time any of the three changed --
-- exactly the kind of duplicated tunable engineering-standards.md's "one source of truth per
-- value" exists to prevent. Retuning DashPunch's timing now automatically keeps the front-dash
-- commitment lock in sync -- no separate number to remember to update.
-- Windup/Active dialed in via the (since moved into the Move Editor's "Default" moves section)
-- live attack tuner (Server/Combat/DefaultMoveRegistry.lua) and copied back here as the new file
-- defaults -- Windup=0.4 means the punch
-- now visibly winds up for a beat AFTER the front-lunge movement burst itself has already finished
-- (DashFrontDurationSeconds is still 0.28, shorter than this Windup), rather than the hitbox
-- riding along for virtually the whole dash the way the original 0.02/0.26 split did. Recovery
-- wasn't part of that live-tuning pass and is left at its prior value.
local DashPunchWindupSeconds = 0.4
local DashPunchActiveSeconds = 0.2
local DashPunchRecoverySeconds = 0.17

-- DashHit's own timing, same "locals so a derived commitment constant can reference them" reason
-- as DashPunch's own three above -- see DashHitCommitmentSeconds' own header. DashHit is the
-- SEPARATE, lighter attack every plain forward dash throws (handleDashRequest) -- distinct from
-- DashPunch, which only throws on a genuine double-tap-forward and additionally opens the air
-- combo. Windup covers most of the dash's travel (so the hitbox doesn't appear before the dash has
-- actually closed any distance), Active is a brief window right at the tail -- "a hitbox spawns at
-- the end of the attack" -- and Recovery is short, matching a plain dash's own low-commitment feel.
local DashHitWindupSeconds = 0.350
local DashHitActiveSeconds = 0.10
local DashHitRecoverySeconds = 0.08

-- Shared Offset for DashPunch, DashHit, AND AirSlam -- one local so retuning it can't let the
-- three drift out of sync with each other. All three sample the hitbox off the attacker's own hand
-- (HitboxResolver's AttackerTrackedPart, resolved by CombatSystem.lua's resolveAttackHandPart)
-- rather than a fixed offset from the root part's center.
--
-- Was CFrame.new(0, 0, -1) paired with a 7-stud-deep box (half-reach 3.5): that undersized nudge
-- left the box's BACK half sitting 2.5 studs BEHIND the hand -- i.e. bleeding back through the
-- attacker's own torso and out the far side, since the hand itself sits barely forward of the root
-- at all (mostly offset sideways, not forward). Read (correctly) as "the hitbox spawns on my own
-- character instead of in front of it." The box's front edge (the actual usable reach) was fine at
-- 4.5 studs forward of the hand -- only the rear half was broken -- so this fix re-derives the
-- offset to keep that SAME 4.5-stud front reach while pulling the back edge up to just barely in
-- front of the hand (-0.25, matching the Weapons hitboxes' own front-loaded convention below). Paired
-- with each definition's Size.Z shrinking from 7 to 4.25 (half-reach 2.125) to match -- the box is
-- now front-loaded instead of hand-centered. A tuning number per combat-philosophy.md's Tuning
-- process -- adjust freely after a playtest (MoveRegistryManager's own CLAMP_MIN/MAX_OFFSET_STUDS,
-- reused by Server/Combat/DefaultMoveRegistry.lua's Validate-backed ApplyEdit, already cover a much
-- wider range than this for the Move Editor's live Default-move tuner).
local HandTrackedOffset = CFrame.new(0, 0, -2.375)

-- CombatSystem's first-pass technical tunables (software-architecture.md's CombatSystem
-- ownership row; combat-philosophy.md for the Lock-on/Block/Parry/Posture feel these numbers
-- serve). These are engineering defaults chosen to make the state machine work correctly, NOT a
-- balance pass -- per combat-philosophy.md's Tuning process, numeric values here can move freely
-- without design ceremony. What's NOT free to move without flagging it as a design decision: the
-- systems these numbers belong to (lock-on, block/parry/posture) -- see that doc's "Established
-- systems" list.
Constants.Combat = {
	-- Vitals. Health and Posture are the game's only two vitals -- Stamina was removed (the Sekiro-
	-- grade reference point in combat-philosophy.md has no stamina; posture, not stamina, is the
	-- resource that turns sustained pressure into an opening). Actions are gated by cooldowns +
	-- the attackEndsAt commitment lock, and posture, not by a stamina budget.
	MaxHealth = 100,
	MaxPosture = 100,

	-- Mitigation while actively blocking: multiplies incoming health damage (lower = safer).
	-- Posture is left at 1.0 (neutral) deliberately -- an earlier 1.5x here made a routine 4-hit
	-- combo posture-break a blocking defender almost exactly at the combo's end (guaranteed
	-- guard-break followed by PostureBreakDuration's fully-exposed window, erasing the HP savings
	-- block was supposed to provide). Block should never be strictly worse than not blocking; if a
	-- posture *risk* for blocking turns out to be wanted after playtesting, revisit with a small
	-- value like 1.1 rather than reintroducing 1.5.
	BlockDamageMultiplier = 0.25,
	BlockPostureMultiplier = 1.0,

	-- THE PARRY/BLOCK CONFIG THAT USED TO LIVE HERE HAS MOVED, and was not merely deleted.
	--
	-- ParryWindowSeconds/ParryCooldownSeconds/ParryPunishPostureDamage/ParryPingCompensationMaxSeconds/
	-- GuardOpenSeconds/GuardResetSeconds were config for the deleted CombatSystem's parry. Every one of
	-- them is now owned by Shared/Defense/DefenseConstants.lua, or by the animation asset:
	--
	--   * The parry WINDOW is no longer a constant anywhere. It comes from ParryWindowOpen/
	--     ParryWindowClose markers authored on the parry clip (Shared/Defense/ParryWindows.lua), so
	--     retiming a parry is retiming the animation and nothing else.
	--   * The ping refund survives as DefenseConstants.Parry.PingCompensationMaxSeconds, at the same
	--     0.12 -- it is a latency correction, not a window length, so it is still a constant.
	--   * The parried attacker's punish is DefenseConstants.Stagger.DurationSeconds. Note it is 1.5s
	--     where GuardOpenSeconds was 0.6 -- and that 0.6 was DERIVED, not guessed: sized to cover
	--     reaction plus one-way latency plus the slowest weapon's own windup (Primary Basic1, 0.31,
	--     still live below) so the parrier got exactly ONE guaranteed follow-up, with a hard upper
	--     bound near 0.75 past which a Secondary user's second swing also lands inside the window.
	--     The derivation is recorded here because the constant that carried it is gone.
	--   * The anti-turtle cost is DefenseConstants.Parry.MinUnguardedSeconds, at the same 0.3.
	--   * The parry's REWARD is guard rather than posture damage (DefenseConstants.Guard.ParryRestore);
	--     nothing in the Defense System applies damage of any kind.
	--
	-- Left as a pointer rather than as dead fields, because orphaned config reads as live and gets
	-- retuned by someone who then cannot find what their change did.

	-- Disarm: combat-philosophy.md's "Established systems" list names Block/Parry/Disarm as one
	-- formal defensive layer (Block/Parry are one input -- see Shared/Defense/DefenseConstants.lua).
	--
	-- NOTHING CURRENTLY PRODUCES A DISARM, and that is deliberate rather than an oversight. The whole
	-- mechanism below it is live and correct -- HitResolution.ApplyDisarm, CombatState/BotState's
	-- disarmedUntil, the ACTION_GATES Disarm column, the "Disarmed" feedback kind and its client UI --
	-- but the PREDICATE that used to decide it (HitResolution.ShouldDisarm, "a parried Heavy disarms
	-- its attacker") has been deleted. It had been shelved in place as `return false and (...)`, which
	-- is a decision disguised as code: four specs asserted its disabled `false` and so locked the
	-- shelving in as if it were the intended contract.
	--
	-- The reason it was shelved still holds: nothing in this codebase distinguishes an armed
	-- weapon-swing from a bare-fisted one (Basic AND Heavy both fall back to the same punch-style
	-- animations -- CombatAnimator.lua's header), so being disarmed while visibly just punching read
	-- as a bug, correctly. Do NOT revive it as the parry punish's severity axis either -- GuardOpen-
	-- Seconds above is that axis now, and it does not need a weapon concept to make sense.
	--
	-- To bring it back once Heavy attacks (or some other explicit state) genuinely represent wielding
	-- a weapon: one call site in resolveHitAgainstTarget's Parry branch, guarded on that new state.
	-- The scoping argument that made it fair is worth preserving: Heavy's bigger commitment/payoff is
	-- the "telegraphed cost" combat-philosophy.md's Balance Principle #3 requires before anything
	-- punishes past the core defensive layer, and Basic pressure keeps its own value untouched.
	--
	-- A disarmed player can't throw a Basic or Heavy attack but can still Block/Parry/Dash/Sprint/
	-- LockOn -- see CombatState.disarmedUntil's own comment for why this stays within
	-- gameplay-philosophy.md's anti-lockout rule. First-pass technical tunable, free to move.
	Disarm = {
		DurationSeconds = 2.5,
	},

	-- How long a combo chain (consecutive attacks within this window of each other) stays alive
	-- before resetting to stage 1. Per-stage timing/damage/cooldown now live in Hitboxes.Basic/
	-- Heavy below, not here -- see that table's header for why. This is the BASIC finisher combo's
	-- window (CombatState.basicComboExpiry) and the client's post-attack jump lockout; the Heavy
	-- throw-combo has its own window below -- see HeavyComboResetSeconds for why they had to split.
	ComboResetSeconds = 1.5,
	-- MaxComboStacks (was 5) removed: CombatSystem.lua's advanceComboIndex now wraps the throw-combo
	-- counter over the weapon's own authored stage count instead of clamping it at a fixed ceiling
	-- unrelated to that count. See that function's own header for why the clamp was a stage lockout
	-- rather than a bound.

	-- HeavyComboResetSeconds/BasicComboLength/AttackInputBufferSeconds/Feint/Prediction (combo timing,
	-- input buffering, Feint, and client-side action-start prediction) were removed alongside the rest
	-- of the combat system -- every reader of these (CombatSystem.lua, PredictionMirror.lua,
	-- CombatClient.lua's own predict/rollback path) is gone. Server/Combat/Movement.lua and
	-- Server/Combat/DefaultMoveRegistry.lua, the two Combat/ modules kept on disk, read neither.

	-- Finisher physics (Server/Combat/RagdollController.lua applies these; CombatSystem.lua picks the
	-- variant at the 4th hit). The finisher's damage/reach/timing are the Hitboxes.Finisher swing
	-- below; THIS table is only the knockback each variant applies to a target the finisher lands on
	-- cleanly. A blocked finisher deals its (heavy) posture damage but never launches -- guarding is
	-- the counter, per combat-philosophy.md's "no true unblockable." Variant is chosen server-side
	-- (HitResolution.SelectFinisherVariant): holding space -> Uppercut; else -> Normal (a grounded
	-- final hit with no launch, so the input is never dead). Downslam is NOT chosen from this path
	-- anymore -- it used to be the "airborne, not holding space" branch here, but that's now fully
	-- superseded by the standalone AirSlam attack below (jump + M1 at any time, no combo required):
	-- since AirSlam intercepts every Basic-attack press made while airborne before the M1 combo/
	-- finisher logic ever runs, the M1 finisher can only ever be thrown while grounded, so the
	-- airborne branch could never fire again and was removed as dead code. Downslam's own knockback
	-- profile below is unchanged -- it's just invoked by AirSlam now instead. First-pass technical
	-- values, free to tune.
	Finisher = {
		Uppercut = {
			-- Launch speed (studs/sec) applied to the target, then ragdolled for the window below.
			-- 90 was v² = 2gh territory (~20 stud peak height, absurdly high for a normal Humanoid) --
			-- 55 peaks around 7-8 studs, still a dramatic launch without leaving the screen.
			LaunchUpVelocity = 55,
			-- Horizontal component, away from the attacker (RagdollController.LaunchAndRagdoll
			-- computes the direction from the attacker's rootPart to the target's) -- an UPPERCUT, so
			-- this stays small and mostly-vertical is the point; it's here only to keep the target from
			-- dropping back down in the exact spot it launched from, not to send it flying backward.
			-- 35 was way too much horizontal carry over ~2.5s of hangtime -- dropped hard.
			LaunchHorizontalVelocity = 8,
			-- Angular velocity (rad/sec) applied around the horizontal axis perpendicular to the
			-- launch direction, biasing the ragdoll's natural tumble backward so it's very likely to
			-- come down on its back rather than a random/face-down landing -- a bias, not a forced
			-- landing snap (RagdollController deliberately never CFrame-snaps a ballsocket-jointed
			-- ragdoll; see SlamToGround's own comment on why that reads as a teleport jerk).
			LaunchBackwardSpin = 6,
			RagdollSeconds = 2.5,
		},
		-- Hard downward launch that drives an airborne target back into the floor, with a briefer
		-- knockdown than the uppercut (a slam ends on the ground, it isn't a long airborne float).
		-- Consumed today by HitResolution.ApplyFinisherPhysics's "Downslam" branch -- the standalone
		-- AirSlam attack (Constants.Combat.AirSlam) always throws with FinisherVariant = "Downslam",
		-- reusing this exact knockback profile rather than a duplicate one. See this table's own
		-- header for why the M1 finisher itself no longer produces this variant.
		Downslam = {
			SlamDownVelocity = 140,
			KnockdownSeconds = 1.25,
			-- Angular velocity (rad/sec) biasing the ragdoll's tumble face-first into the ground, so a
			-- downslam reads as a genuine face-plant instead of a random/back-first drop -- the
			-- downward-launch counterpart of Uppercut's own LaunchBackwardSpin above (Server/Combat/
			-- RagdollController.SlamToGround applies this the same way LaunchAndRagdoll applies
			-- LaunchBackwardSpin: a bias on the ragdoll's angular velocity at launch, never a forced
			-- CFrame snap -- see that function's own header for why a snap is off the table entirely
			-- for a ballsocket-jointed ragdoll). Tuned noticeably higher than LaunchBackwardSpin (6):
			-- Uppercut's tumble has the whole ~2.5s of RagdollSeconds hangtime to settle into its
			-- backward bias before landing, where a downslam's SlamDownVelocity (140 studs/s) drives
			-- the target into the floor almost immediately -- the rotation needs to develop much
			-- faster to read as a deliberate pitch rather than a body that was still mid-tumble when
			-- it hit.
			FaceDownSpin = 9,
		},
		Normal = {
			-- Grounded, not holding space: no launch/ragdoll, just a heavier finishing blow -- extra
			-- hitstun on top of the swing's own damage/posture so the 4th hit still feels conclusive.
			--
			-- MUST stay meaningfully above Constants.Combat.HitStunDuration (0.6) or this variant does
			-- nothing at all. resolveHitAgainstTarget applies it as
			-- `math.max(stunExpiry, now + ExtraStunSeconds)` AFTER the ordinary hit path has already set
			-- `stunExpiry = now + HitStunDuration` -- it's a FLOOR, not an addition. At the previous 0.6
			-- the two were identical, so the max was a no-op and a "Normal" finisher was mechanically a
			-- Basic3 that happened to deal more damage. That made the variant choice fake: holding jump
			-- for the Uppercut was unconditionally correct, since Uppercut bought a 2.5s ragdoll and
			-- Normal bought nothing.
			--
			-- 1.1 gives Normal +0.5s of lockout over an ordinary hit. Deliberately far short of
			-- Uppercut's 2.5s ragdoll, because the two variants buy different things and should trade
			-- off rather than rank: Uppercut removes more agency but launches the target away and ends
			-- your pressure, Normal keeps them grounded and in front of you. Stun (unlike ragdoll) does
			-- not gate BlockStart -- see ACTION_GATES -- so the target can still guard the follow-up,
			-- which is what keeps this inside "everything is defendable."
			ExtraStunSeconds = 1.1,
		},
	},

	-- Vulnerability windows. PostureBreakDuration is how long a posture-broken target stays fully
	-- exposed (posture pinned at 0, guard bypassed). StunDuration is the shorter lockout applied
	-- to an attacker who gets parried -- a separate concept from posture break, not a reuse of it.
	PostureBreakDuration = 3,
	StunDuration = 1,

	-- Universal hit reaction: a much lighter, symmetric version of the attacker-only parry punish
	-- above -- whichever side takes an unmitigated (non-blocked, non-parried) hit gets a real,
	-- felt interruption. Reuses the exact same stunExpiry gate StunDuration extends (via math.max,
	-- so it never shortens a harsher parry/posture-break lockout already in effect) plus a short
	-- movement clip. This ALSO gates Basic/Heavy/Dash/Slide/SwapWeapon (ACTION_GATES, same table
	-- as Basic/Heavy) -- eating a hit means you can't attack again or freely disengage for a
	-- moment. Previously 0.15s, which read as no lockout at all in practice -- shorter than a
	-- human's reaction time plus the network round trip, so by the time a real player's response
	-- reached the server the window had already cleared and every action went through as if
	-- nothing had happened. Previously retuned to roughly match a quick Basic1 swing's own
	-- WindupSeconds (0.31) -- since raised again to 0.6 (from 0.35) because that still wasn't
	-- enough to survive an actual COMBO: the real minimum gap between two consecutively landed
	-- hits is RecoverySeconds(stage N) + WindupSeconds(stage N+1), and the worst case across both
	-- weapons' full Basic->Finisher chains is 0.48s (Primary Basic3->Finisher: Recovery 0.20 +
	-- Finisher Windup 0.28), with Heavy's 2-stage wraparound (Heavy1->Heavy2: Recovery 0.35 + Windup
	-- 0.20 = 0.55) even higher. A 0.35s stun let it lapse mid-combo -- the victim's stun expired
	-- before the next hit could land, opening a real window to counter-attack/dash/slide out
	-- despite still being "in" a 4-hit combo. 0.6 clears every transition on both weapons with
	-- margin, while staying well below StunDuration (1, the parry-punish lockout) and
	-- PostureBreakDuration (3) so it isn't a disproportionate change outside combo either. One
	-- shared constant, not a second "combo-only" tunable -- the values aren't different enough in
	-- kind to justify a second number, and the existing math.max at the write site already
	-- guarantees a harsher pre-existing lockout is never shortened by this.
	--
	-- BlockStart is deliberately NOT in the gated-actions list above (see ACTION_GATES.BlockStart's
	-- own comment in CombatSystem.lua) -- direct playtest feedback was that being stun-locked out of
	-- even ATTEMPTING Block/Parry against combo hits 2-4 after eating hit 1 left zero counterplay,
	-- contradicting combat-philosophy.md's "real parry window" reference point. A stunned player can
	-- still raise Block/try to Parry (and still whiff on bad timing like any other parry); they just
	-- can't attack back or Dash/Slide/swap weapons away for free.
	HitStunDuration = 0.6,

	-- How long a player is considered "in combat" after their last real exchange with an opponent --
	-- refreshed (assigned forward, not math.max'd -- this is a coarser signal than the specific
	-- lockouts above, so a fresh trigger should always reset the full duration) only by an actual
	-- hit/parry/air-tech exchange against a real opponent (player or training bot), never by merely
	-- throwing a swing or opening Block -- see CombatState.inCombatUntil's own header for the full
	-- trigger list and why. Not tied to any single action's own timing (attackEndsAt, stunExpiry,
	-- etc.) -- this is a general-purpose "still fighting" signal any current or future system can
	-- read off Types.CombatSnapshot.InCombat, independent of what specific action caused it.
	InCombatDurationSeconds = 5,
	-- CombatSystem's own explicit baseline (Roblox's Humanoid default already happens to be 16,
	-- though this codebase no longer relies on that coincidence) -- CombatSystem now owns setting/
	-- restoring WalkSpeed so HitSlowMultiplier below has a known value to multiply and restore to.
	-- Lowered from 16 to 10 (retuned alongside DefaultBonusWalkSpeed below to land the default
	-- resting speed at 18, down from 24) -- tuning, not design, per combat-philosophy.md's Tuning
	-- process; every multiplier tier (Sprint/Dash, all computed off base+bonus in
	-- Movement.ComputeDesiredWalkSpeed) scales down proportionally with it.
	BaseWalkSpeed = 10,
	-- Additive speed bonus applied on top of BaseWalkSpeed via a "BonusWalkSpeed" Attribute on each
	-- player's own Humanoid (Movement.ComputeDesiredWalkSpeed reads it; onCharacterAdded seeds it at
	-- spawn) rather than a flat Constants number, per luau-coding-standards.md's Attribute-API
	-- convention for per-instance runtime data -- this is meant to be driven per-player later by
	-- race/bloodline stat systems (progression-systems.md), not stay a single global forever. For
	-- now every player just gets this same default (10 + 8 = 18 effective base), a flat first-pass
	-- speed bump -- tuning, not design, per combat-philosophy.md's Tuning process. Left at 8 (not
	-- retuned) when BaseWalkSpeed above dropped -- this placeholder's own value isn't the thing
	-- being retuned here, only the resulting default speed.
	DefaultBonusWalkSpeed = 8,
	-- The "can't just run away" factor: every unmitigated hit clips WalkSpeed to base * this
	-- multiplier for HitSlowDuration (Movement.ComputeDesiredWalkSpeed's hit-slow tier -- below
	-- dash, above sprint). 0.6/0.3s (was ~14.4 studs/sec off a 24 base, barely slower than a brisk
	-- walk) let a hit target just hold their sprint key and disengage immediately. 0.25/0.5s (~6
	-- studs/sec, a near-crawl for half a second) gives the attacker a real follow-up window without
	-- fully rooting the target in place -- tuning, not design, per combat-philosophy.md's Tuning
	-- process.
	HitSlowMultiplier = 0.25,
	HitSlowDuration = 0.5,

	-- The MoveDirection magnitude below which there's no meaningful held movement input -- one shared
	-- threshold for every "is this character actually being steered right now" check in the codebase.
	-- Was FOUR independently hand-typed 0.1 literals that had to agree by coincidence: this module's
	-- own ResolveDashDirection/IsMoving below (gates Slide's "must be genuinely moving" reject and
	-- picks which direction a Dash throws/animates as), and client-side in Client/FX/CombatAnimator.
	-- lua's own LOCOMOTION_THRESHOLD (resolveDashDirection's animation pick, and the Walking/Running
	-- loop eligibility evaluator) and Client/FX/MovementVFX.lua's own LOCOMOTION_THRESHOLD (the
	-- sprint-dust trickle's "moving" gate) -- Movement.IsMoving's own comment literally flagged its
	-- 0.1 as "the same 0.1 magnitude threshold ResolveDashDirection above already uses inline" before
	-- this field existed, which is exactly the kind of duplication-by-coincidence engineering-
	-- standards.md's one-source-of-truth rule exists to close: a deliberate retune of "what counts as
	-- movement" would otherwise require remembering all four sites instead of changing one number.
	MovementInputMagnitudeThreshold = 0.1,

	-- Float-safety "is this vector effectively zero" epsilon -- gates a .Unit call from ever running
	-- on a near-zero-magnitude vector (HitResolution.lua's arc/line-of-sight checks, CombatSystem.
	-- lua's bot-facing update). Distinct from MinDirectionMagnitude below -- this is a pure
	-- floating-point-safety guard, not a "meaningfully non-zero direction" gameplay threshold.
	ZeroVectorEpsilon = 1e-3,
	-- "Is this horizontal direction meaningfully non-zero" threshold (RagdollController.lua's
	-- LaunchAndRagdoll) -- larger than ZeroVectorEpsilon above on purpose, a different concept at a
	-- different call site, not the same number renamed.
	MinDirectionMagnitude = 0.01,

	-- Neutral-game movement tunables (CombatSystem.lua's handleDashRequest for Dash). CombatSystem
	-- itself is gone (the combat rewrite deleted it) and nothing currently drives Dash's WalkSpeed
	-- burst through Server/Combat/Movement.ComputeDesiredWalkSpeed as a result -- see
	-- Server/Systems/RunSystem.lua's own boot-order comment in Main.server.lua for the confirmed
	-- "nothing wrote WalkSpeed at all" state this left behind.
	--
	-- Dash is a single proactive key (no i-frames, a low-stakes spacing tool meant to be used often
	-- in the neutral game): a quick WalkSpeed burst, limited by its own cooldown + commitment lock,
	-- not any resource (Stamina is gone).
	--
	-- SPRINT/THE RUN TIER USED TO LIVE HERE TOO (SprintSpeedMultiplier, SprintStage2*) and has fully
	-- moved out -- Shared/Run/RunConstants.lua now owns every run-stage number (a THREE-stage ladder,
	-- not the two-stage one these fields used to describe) and Server/Systems/RunSystem.lua is the
	-- live WalkSpeed authority for it. See RunConstants.lua's own "SEPARATE FROM Constants.Combat ON
	-- PURPOSE" header for why. There is now exactly one place the run's stage numbers live; retuning
	-- the run never touches this file. (The fields that used to sit here were dead weight, not a
	-- second live copy: Server/Combat/Movement.lua's sprint functions that read them had no caller
	-- left once CombatSystem was deleted, same as Dash's burst above.)
	--
	-- Numbers here are first-pass technical tunables, free to move without design ceremony per
	-- combat-philosophy.md's Tuning process.
	DashSpeedMultiplier = 2.2,
	-- Seconds the Dash WalkSpeed burst is active -- a quick step, not a sustained evade.
	DashDurationSeconds = 0.22,
	-- Brief post-burst recovery, reusing the shared attackEndsAt commitment lock (slightly longer
	-- than DashDurationSeconds -- window > burst). No new attack, block, sprint-speed, or dash
	-- starts until it elapses.
	DashCommitmentSeconds = 0.28,
	-- A low-stakes cooldown: Dash is meant to be used often in the neutral game, not a high-value
	-- defensive cooldown. Still governs Front/Left/Right -- see DashBackCooldownSeconds below for
	-- why Back specifically does not share this pace anymore.
	DashCooldownSeconds = 0.8,

	-- Backward-specific Dash tuning (Movement.ApplyDash's isBackDash parameter, resolved from
	-- Movement.ResolveDashDirection == "Back"). Slide can no longer move backward at all
	-- (handleSlideRequest's own header), but Dash still can -- a neutral repositioning tool needs
	-- SOME way to create distance defensively. Playtest report, though: with Back sharing the exact
	-- same speed/cooldown as every other direction, pure backward-dash-spam became "the movement
	-- meta" on its own -- a single back-dash also covered noticeably more distance than felt
	-- intentional ("falls too far backwards"). Front/Left/Right are completely untouched by this --
	-- Dash's forward/lateral use (closing distance, sidestepping mid-fight) isn't the "running"
	-- problem this targets, only using it to retreat is. Same DashDurationSeconds/
	-- DashCommitmentSeconds as every other non-front direction -- only the speed and the cooldown
	-- differ, so recovery/commitment feel stays consistent across directions.
	-- Lower than DashSpeedMultiplier (2.2) -- same burst duration, shorter distance covered.
	DashBackSpeedMultiplier = 1.5,
	-- Double DashCooldownSeconds -- a deliberate, occasional defensive option again, not a
	-- spammable retreat (mirrors the reasoning SlideCooldownSeconds already documents for Slide).
	DashBackCooldownSeconds = 1.6,

	-- A Dash resolved as "Front" (Movement.ResolveDashDirection, mirrored client-side in
	-- CombatAnimator.lua for the DashFront clip) AND reported as a double-tap
	-- (CombatSystem.lua's handleDashRequest -- see that function's own header for the client-trust
	-- tier this hint uses, and why the real safety net is DashPunch.Cooldown below, not verifying
	-- the tap itself) is a lunging punch attempt, not a plain reposition -- it travels slightly
	-- farther than a Back/Left/Right dash and throws the DashPunch hitbox below (once
	-- DashPunch.Cooldown also clears), timed to land right as the burst ends.
	DashFrontDurationSeconds = 0.28,
	-- Derived from DashPunch's own WindupSeconds+ActiveSeconds+RecoverySeconds (the locals just
	-- above this table) rather than a hand-typed duplicate -- a front dash's commitment lock has to
	-- span the whole punch, not just the movement burst, or the player could act again mid-swing.
	-- See those locals' own header for the sync bug this replaced.
	DashFrontCommitmentSeconds = DashPunchWindupSeconds + DashPunchActiveSeconds + DashPunchRecoverySeconds,
	-- Same derivation as DashFrontCommitmentSeconds just above, for DashHit -- the plain forward
	-- dash's own (lighter, non-launching) attack. Unlike DashPunch, DashHit does NOT get its own
	-- longer movement burst (handleDashRequest still applies the plain DashDurationSeconds/
	-- DashSpeedMultiplier for it -- it's not a bigger lunge, just an ordinary dash that happens to
	-- leave a hit at the end), so only the commitment lock needs a dedicated value here, long enough
	-- to cover the hitbox's own active+recovery tail past the plain DashCommitmentSeconds above.
	DashHitCommitmentSeconds = DashHitWindupSeconds + DashHitActiveSeconds + DashHitRecoverySeconds,

	-- Slide: chained off Sprint (Movement.IsMoving must also be true) -- a bigger, committed WalkSpeed
	-- burst than Dash, built the exact same way (Movement.ApplySlide mirrors Movement.ApplyDash). No
	-- hitbox, no damage/posture damage -- mirrors plain Dash, never DashPunch/DashHit. Dash and Slide
	-- can never be simultaneously active (both lock the shared attackEndsAt commitment). They DO
	-- share one cooldown pool though (CombatState.movementCooldownExpiry, checked/set by both
	-- handleDashRequest and handleSlideRequest alongside each move's own individual cooldown below) --
	-- without that, alternating Dash and Slide let a player retreat almost twice as often as either
	-- move's own designed cooldown alone permits, since two independent cooldown pools running in
	-- parallel renew faster than one (a real playtest-found "dash tech": chain-pressing both keys
	-- instead of waiting out either move's own cooldown). First-pass technical tunables, free to
	-- move without design ceremony per combat-philosophy.md's Tuning process.
	SlideSpeedMultiplier = 2.0,
	-- Seconds the Slide WalkSpeed burst is active.
	SlideDurationSeconds = 0.35,
	-- Brief post-burst recovery, reusing the shared attackEndsAt commitment lock -- longer than Dash's
	-- own (0.28s) since a slide is a bigger, more committed movement than a step.
	SlideCommitmentSeconds = 0.45,
	-- Steeper than Dash's 0.8s -- Slide is chained off Sprint (already a bigger investment than a
	-- neutral Dash press) so it's meant to be a deliberate, occasional burst, not a spammable one.
	SlideCooldownSeconds = 1.2,

	-- The front-dash punch's own HitboxAttackDefinition (Server/Combat/HitboxResolver.lua consumes
	-- this the same way it consumes any Weapons[...].Stages entry, via a dedicated throwDashPunch in
	-- CombatSystem.lua rather than commitAndThrowAttack -- a dash-punch is its own move, not an M1
	-- string stage, so it deliberately never touches basicComboLanded). Damage/PostureDamage/Size
	-- copied from Primary's Basic1 ("since its a punch," same weight as an ordinary first hit); see
	-- HandTrackedOffset's own header for Offset specifically.
	--
	-- WindupSeconds/ActiveSeconds (see the locals above this table) were retuned via a live
	-- playtest pass to 0.4/0.2 -- unlike the original 0.02/0.26 split, the active window (roughly
	-- [0.4, 0.6]) now starts AFTER the front-lunge movement burst itself has already finished
	-- (DashFrontDurationSeconds is still 0.28, shorter than this Windup) rather than tracking the
	-- attacker for virtually the whole dash. HitboxResolver.performSample still re-reads the
	-- tracked pose fresh every sample (the attacker's own hand, per resolveAttackHandPart -- see
	-- HitboxResolver.SwingConfig.AttackerTrackedPart's own header) -- with the attacker already
	-- stopped by the time the window opens, this reads as a beat of wind-up followed by the punch
	-- flashing out, rather than a hitbox riding along with the lunge itself. RecoverySeconds (0.17,
	-- untouched by this pass) is the only part that exists purely as post-move commitment, not
	-- hitbox presence. The three feed DashFrontCommitmentSeconds directly above now, so they can
	-- never drift out of sync with it.
	--
	-- Cooldown is a REAL gate (CombatState.dashPunchReadyAt, set by throwDashPunch), not
	-- documentation -- it used to be unread, with the punch actually gated only by Dash's own much
	-- cheaper dashCooldownExpiry (0.8s), which under-priced a move that deals damage/posture AND
	-- opens the air combo relative to a plain reposition. Raised to 4s after a playtest pass (was
	-- 1.6s) -- DashPunch is a gap-closer, a damage/posture hit, AND a combo-starter in one move, so
	-- a full 4-second commitment between throws is what actually made it read as the rare,
	-- deliberate double-tap-forward commitment it's meant to be rather than a spammable option. A
	-- tuning number per combat-philosophy.md's Tuning process -- adjust freely after another pass.
	DashPunch = {
		DebugName = "DashPunch",
		WindupSeconds = DashPunchWindupSeconds,
		ActiveSeconds = DashPunchActiveSeconds,
		RecoverySeconds = DashPunchRecoverySeconds,
		-- X/Y match the same "slightly bigger than the player" pass applied to every other melee
		-- hitbox. Z shrunk from 7 to 4.25 -- see HandTrackedOffset's own header for why: the old
		-- 7-stud depth was mostly wasted bleeding back through the attacker's own body, not real
		-- forward reach, once paired with the re-derived Offset above.
		Size = Vector3.new(6, 6.5, 4.25),
		Offset = HandTrackedOffset,
		Damage = 8,
		PostureDamage = 10,
		Cooldown = 4,
		ArcDegrees = 100,
		-- 1, NOT the 3 every other multi-target hitbox uses -- DashPunch is a LAUNCHER, and both
		-- weapons' own Finishers already establish the rule this now follows ("a launcher commits to
		-- one foe, not a crowd-clear", see each Finisher's MaxTargets = 1). At 3 this was the single
		-- worst agency violation in the game: AirCombo.Apply tracks exactly ONE airComboTarget
		-- (CombatState.AirCombo.airComboTarget), so victims 2 and 3 were held aloft at HoverHeight for
		-- the full AirborneSeconds with no continuation hit ever able to land on them (only the ONE
		-- tracked victim ever gets a fresh Basic hit or a follow-up hold refresh) -- they'd just hang
		-- there until the hold's own timer lapsed, with no attacker action able to affect them either
		-- way. Fixing the count is the correct fix rather than teaching the air combo to track N
		-- victims: juggling three people at once was never the intent.
		MaxTargets = 1,
	},

	-- DashHit's own HitboxAttackDefinition -- the plain forward dash's own attack
	-- (CombatSystem.lua's throwDashHit/handleDashRequest), thrown on EVERY dash that resolves
	-- "Front" and ISN'T already throwing DashPunch (i.e. every plain forward Q/ButtonB dash, not
	-- just a double-tapped one). Deliberately a separate, lighter move from DashPunch, not a
	-- reskin of it: DashPunch is the rarer, deliberate double-tap commitment that opens the air
	-- combo; DashHit is what an ordinary forward dash "always has strapped to the end of it" --
	-- weaker damage/posture, one fewer max target, and no air-combo hook at all (its DebugName never
	-- matches applyAirCombo's "DashPunch" launch condition -- see that function's own header). Same
	-- Size/Offset/ArcDegrees as DashPunch (a punch's physical reach doesn't need to differ by how it
	-- was triggered -- both also hand-tracked, see HandTrackedOffset's own header and
	-- CombatSystem.lua's resolveAttackHandPart); Damage/PostureDamage/MaxTargets scaled down to
	-- reflect that this is the free, always-available version, not the cooldown-gated,
	-- double-tap-earned one. No separate cooldown field of its own -- gated purely by Dash's own
	-- DashCooldownSeconds (0.8s) the same way DashPunch originally was before it needed a stricter
	-- one; DashHit doesn't need DashPunch's stricter gate since it doesn't open the air combo and
	-- deals meaningfully less damage.
	DashHit = {
		DebugName = "DashHit",
		WindupSeconds = DashHitWindupSeconds,
		ActiveSeconds = DashHitActiveSeconds,
		RecoverySeconds = DashHitRecoverySeconds,
		-- Same "slightly bigger than the player" pass as DashPunch (identical Size/Offset by design
		-- -- see this definition's own header for why the two share physical reach, and
		-- HandTrackedOffset's own header for why Z is 4.25 rather than the old 7).
		Size = Vector3.new(6, 6.5, 4.25),
		Offset = HandTrackedOffset,
		Damage = 5,
		PostureDamage = 6,
		Cooldown = 0.8,
		ArcDegrees = 100,
		MaxTargets = 2,
	},

	-- AirSlam's own HitboxAttackDefinition -- pressing Basic Attack (M1) while airborne, at ANY time
	-- (no M1 combo prerequisite), throws this standalone move instead of continuing the grounded
	-- Basic string -- see CombatSystem.lua's handleAirSlamRequest/throwAirSlam, modeled directly on
	-- DashPunch/DashHit just above (a real move thrown via onSwingHitCandidate directly, never
	-- startAttackSwing, so it can never touch basicComboLanded/basicAttackReadyAt -- landing or
	-- whiffing an air slam has zero effect on the grounded M1 string, and vice versa). A clean
	-- (non-blocked, non-parried) hit always resolves with FinisherVariant = "Downslam"
	-- (HitResolution.ApplyFinisherPhysics), reusing Finisher.Downslam's own SlamToGround knockback
	-- and letting CombatAnimator's existing finisherTrackName("Downslam") resolution pick the
	-- animation -- no separate physics/animation plumbing needed for this move.
	--
	-- Own real cooldown (CombatState.airSlamReadyAt), same "a move that hits hard AND launches needs
	-- a real gate, not a free spam option" reasoning as DashPunch.Cooldown's own header -- jumping is
	-- free (no Stamina), so without this a player could throw one on every hop. Damage/PostureDamage
	-- sit between a Basic3 and a Heavy1 (a committed, telegraphed hit, not a routine combo stage);
	-- hand-tracked Offset (see HandTrackedOffset's own header) and a taller Size than a ground swing
	-- since the attacker is airborne and the target is typically at or near ground level.
	-- First-pass technical values, free to tune per combat-philosophy.md's Tuning process.
	AirSlam = {
		DebugName = "AirSlam",
		WindupSeconds = 0.35,
		ActiveSeconds = 0.22,
		RecoverySeconds = 0.3,
		-- Scaled with every other melee hitbox's "slightly bigger than the player" pass -- kept
		-- taller than a level swing's own 6.5 (it's an overhead slam, needs more vertical reach
		-- toward a target typically below the attacker). Z shrunk from 7 to 4.25, same
		-- HandTrackedOffset fix as DashPunch/DashHit (see that local's own header) -- AirSlam shared
		-- the identical "bleeds behind the attacker" bug since it shares the same tracked-hand Offset.
		Size = Vector3.new(6, 7, 4.25),
		Offset = HandTrackedOffset,
		Damage = 14,
		PostureDamage = 16,
		Cooldown = 3,
		ArcDegrees = 100,
		MaxTargets = 1,
	},

	-- Air combo: a DashPunch that connects (unmitigated -- Block stops it, same rule as every
	-- finisher) holds BOTH the target AND the attacker in the air together (AirCombo.Apply). While
	-- CombatState.airComboExpiry hasn't lapsed, the attacker's own subsequent Basic (M1) hits landing
	-- on that SAME target continue the juggle -- refreshing the hold below -- up to MaxHits total, at
	-- which point the final hit slams them into the ground for bonus damage instead of holding them
	-- up again. A real player target stays LIVE the whole sequence (full Motor6D/Humanoid control,
	-- Block/Parry-capable -- see AirCombo.lua's own header); a training-dummy target stays fully
	-- ragdolled, no defend concept to preserve. Bot targets never reach this at all -- bots can't be
	-- juggled (CombatState.airComboTarget is typed Player?, never a bot).
	AirCombo = {
		-- Dummy-target only, as of this pass -- a real player target stays live-held from impact (no
		-- launch velocity/tumble at all, see AirCombo.Apply's own header for why); a training dummy
		-- still gets this pop + backward spin to sell the hit landing before RagdollController.
		-- HoldAloft's own AlignPosition takes over.
		LaunchHorizontalVelocity = 4,
		LaunchBackwardSpin = 4,
		-- How long both combatants stay locked into the sequence per launch or hold-refresh --
		-- reused for EVERYTHING that needs to agree on "how long until this sequence naturally ends
		-- without another landed hit": the target's ragdoll recovery window, RagdollController.
		-- HoldAloft's own hold duration, AND (as of this value) CombatState.airComboExpiry's own
		-- continuation deadline (applyAirCombo's `now + cfg.AirborneSeconds`) -- those three used to
		-- be governed by two DIFFERENT constants (this one plus a separate, SHORTER WindowSeconds),
		-- which meant a hit that landed physically in time (target still visibly held) could still
		-- get silently rejected as "too late" for combo-continuation purposes -- read as "we fall
		-- before I finish the combo" even on a hit that looked like it connected. One constant means
		-- that gap can't reopen. Bumped from 1.4 -- real swing windup + human reaction time to a
		-- landed hit ate more of the old, tighter budget than intended; the target is fully ragdolled/
		-- held the whole time regardless; a bit more slack costs the defender nothing extra.
		AirborneSeconds = 1.8,
		-- Guaranteed EXTRA hold time (on top of AirborneSeconds, not a replacement for it) a
		-- priority-switch parry grants -- see AirCombo.SwitchPriority's own header (Server/Combat/
		-- AirCombo.lua). A continuation-hit Parry against an already-tracked air-combo target flips
		-- who's attacking instead of just ending the sequence; this is the reward for pulling off that
		-- harder, correctly-timed defensive read, on top of the punish/disarm resolveHitAgainstTarget's
		-- Parry branch already applies to the (now-victim) attacker. Deliberately does not apply to
		-- parrying the OPENING DashPunch itself -- that stays a plain punish with no launch, see
		-- SwitchPriority's own call site (CombatSystem.lua's resolveHitAgainstTarget) for the exact
		-- isTrackedContinuation gate. A rally of back-and-forth priority-switch parries can chain
		-- indefinitely, each one re-adding this same bonus on top of the base window.
		ParryHoldExtensionSeconds = 2,
		-- How high above their hit-time position the TARGET rises and then STOPS -- a fixed world
		-- position (RagdollController.HoldAloft pins them there via AlignPosition), not a launch
		-- velocity + gravity estimate. This replaced a velocity/FloatGravityFraction-based float
		-- (v0 = 75 studs/sec, 45% net gravity) that was tuned assuming a ~14-stud peak but actually
		-- settles far higher (v0^2 / (2 * netGravity) works out closer to 30+ studs at those numbers)
		-- -- getting float kinematics exactly right is inherently fiddly, and re-launching on every
		-- continuation hit compounded the error hit-over-hit (each relaunch reset velocity from an
		-- ALREADY-elevated position, so a fast combo ratcheted the target higher and higher instead of
		-- settling at one height) -- read as "it just keeps going up and never comes back down, I
		-- can't hit him." Pinning to an exact position sidesteps both failure modes by construction:
		-- one rise, one height, held there for follow-ups, full stop, regardless of tuning or how many
		-- continuation hits land. See HoldAloft's own header.
		HoverHeight = 12,
		-- AlignPosition.MaxVelocity (studs/sec) for the target's rise to HoverHeight. Paced to a
		-- readable FLIGHT, not a snap: at ~12 studs of rise this is ~0.4s up. Deliberately close to the
		-- attacker's ChaseSpeed below so the two ascend TOGETHER (the whole point of the air combo is
		-- launching both up in formation) -- if these two drift far apart the faster body leaves the
		-- slower one out of swing range mid-rise and early continuation hits whiff. Was 60 (a fast zip
		-- that read as a snap up rather than a launch you fly alongside).
		HoverRiseSpeed = 30,
		-- AlignPosition.Responsiveness for the target's rise -- see ChaseResponsiveness below for what
		-- this knob actually does; left at a snappy value here since the target's rise already reads
		-- as a launch via LaunchAndRagdoll's own tumble/spin (LaunchBackwardSpin above), unlike the
		-- attacker's own motion which had nothing else selling "flight" until ChaseResponsiveness.
		HoverResponsiveness = 25,
		-- Total hits in the sequence including the DashPunch launcher itself -- e.g. 4 means launcher
		-- + 2 continuations + 1 slam. Capped deliberately small: combat-philosophy.md's "no true
		-- unblockable/unparryable without a telegraphed cost" -- the sequence itself stays short
		-- rather than open-ended, the same reasoning that already caps the M1 string at
		-- BasicComboLength before forcing a Finisher. (This previously also pointed at a
		-- TechWindowSeconds field "below" for the target's escape option; no such field exists
		-- anywhere in the codebase and no air-tech is implemented, so the short sequence length is
		-- currently the ONLY thing bounding a victim's helplessness here.)
		MaxHits = 4,
		-- The attacker's OWN positioning -- see RagdollController.HoldAloft's header for why a fixed-
		-- point AlignPosition pin (not a one-time launch velocity, and -- as of this value -- not a
		-- live per-Heartbeat re-target either) is what actually closes the gap and holds it: the
		-- attacker keeps full Humanoid control to keep swinging, and Roblox's own Humanoid movement
		-- handling fights/cancels an externally-set velocity almost immediately once ownership is back
		-- with the client -- a single impulse never actually closed the distance, which is why "we
		-- weren't floating next to each other." Studs/sec cap on how fast the hold can move them.
		-- Paced to a readable FLIGHT up to the target, matched to HoverRiseSpeed above so attacker and
		-- target ascend together in formation (see that field). Was 55 -- once the hold stopped sagging
		-- (gravity is now cancelled, see ChaseResponsiveness/ensureGravityCancel), that high a cap ran
		-- the attacker up the ~8-10 stud rise in ~0.15s, which read as a SNAP, not "flying to them." At
		-- ~22 studs/sec the same rise is ~0.4s -- a visible flight that arrives about when the target
		-- settles. Lower this further for a floatier ascent, raise it back toward 55 for a snappier one.
		ChaseSpeed = 22,
		-- AlignPosition.Responsiveness for the attacker's chase -- how aggressively it converts
		-- position error into target velocity. The original 25 (same value AlignPosition's own
		-- default-ish "snappy" range) made a short gap basically resolve in one physics step once
		-- MaxForce = math.huge could supply whatever force that demanded -- read as "teleporting up,"
		-- not flying. 10 makes the velocity ramp up over several frames instead of jumping straight to
		-- ChaseSpeed, which is what actually reads as a rise/flight rather than a snap -- ChaseSpeed
		-- above still caps how fast that ramp tops out, so it stays quick overall.
		-- IMPORTANT: this soft value only holds the attacker at the right spot because the attacker's
		-- hold now CANCELS GRAVITY (RagdollController.ensureGravityCancel, triggered by passing
		-- liveBodyFacePoint to the attacker's HoldAloft calls). Without that, a soft Responsiveness
		-- against a LIVE body's own gravity settles well BELOW the target Position -- the "float down,
		-- never reach them" bug -- so if the gravity-cancel is ever removed, this must go back up
		-- (~25) or the sag returns.
		ChaseResponsiveness = 10,
		-- How far back (studs, horizontal) the chase parks the attacker from the target, instead of
		-- pulling all the way to the target's exact point -- converging to zero distance put the
		-- target directly overhead (both are solid, colliding bodies, and the target is the higher of
		-- the two), read as "he's on my head, not in front of me." 3.5 sits inside a Basic swing's own
		-- forward reach (Weapons.Primary.Stages.Basic's Offset = -3, Size.Z = 6, i.e. 0-6 studs in
		-- front of the attacker) so a continuation hit's hitbox reliably contains the target once the
		-- chase settles, instead of guessing a distance unrelated to the hitbox that's supposed to
		-- land on it.
		ChaseStandoffDistance = 3.5,
		-- Below this horizontal magnitude, the away-from-target standoff direction falls back to a
		-- fixed world direction instead of normalizing a near-zero vector (DashPunch's own Offset/Size
		-- means the real degenerate case essentially never happens in practice).
		MinStandoffDirectionMagnitude = 0.5,
		-- How far below the target's hover height the chase parks the attacker's root -- a small gap
		-- (not zero, not level) so the target visually reads as "up and ahead" rather than exactly
		-- level, while staying well inside a Basic swing's own vertical reach (Size.Y = 5 centered on
		-- the attacker's own root, i.e. +/-2.5 studs) so it doesn't undershoot the hitbox at the other
		-- extreme.
		ChaseBelowTargetOffset = 1.5,
		-- The finisher slam (the hit that reaches MaxHits) -- reuses Downslam-style physics
		-- (RagdollController.SlamToGround) rather than a new mechanic. Bonus damage is on top of
		-- that hit's own normal Basic-stage damage, not a replacement for it -- "a little extra
		-- damage for smacking the ground."
		SlamDownVelocity = 85,
		SlamKnockdownSeconds = 1.25,
		SlamBonusDamage = 6,
		-- Same face-down tumble bias as Finisher.Downslam.FaceDownSpin (see that field's own header for
		-- the mechanism) -- kept as its own independently-tunable number rather than a shared reference
		-- since this slam's own SlamDownVelocity (85) already differs from Finisher.Downslam's (140),
		-- the same "each context keeps its own copy even where values happen to start equal" reasoning
		-- Constants.Debug.DevMenu's confirm-window constants already document.
		FaceDownSpin = 9,
	},

	-- Locomotion animation ids -- read generically by Client/FX/CombatAnimator.lua's BindCharacter
	-- loop (whatever's in this table gets a template built and loaded, nothing hardcodes the name
	-- list) -- see that module's own header. Every combat-specific id that used to live here
	-- (Swing1-3, Heavy1-2, Uppercut/Downslam/FinisherNormal, BlockHold, ParryFlash, DashFront/Back/
	-- Left/Right/DashPunch, Slide, Hit1-3/HitGeneric, PostureBreakStagger, Feint) was removed
	-- alongside the rest of the combat system -- CombatAnimator.lua no longer has any code path that
	-- would resolve them, and BotAnimator.lua (the other former consumer) is gone entirely.
	AnimationIds = {
		-- Walking/Running are a pair -- CombatAnimator.lua's locomotion evaluator crossfades
		-- between them on the same fade duration as sprint toggles, and stops whichever is
		-- playing on a hard interrupt (the character stops moving).
		Walking = "rbxassetid://92817463622620",
		Running = "rbxassetid://134203885804635",
		-- The SECOND run stage's own clip (Constants.Attributes.SprintStage == 2). Blank until a real
		-- full-stride run is authored -- and blank is a supported, shipped state, not a stub: the
		-- locomotion evaluator falls through to Running above when this has no id, so stage 2 still
		-- reads as a different gear through Constants.Run.Animation.PlaybackSpeeds, the FOV pull
		-- and the stage-2 footstep/onset audio. Paste an id here and the clip swaps in with no code
		-- change, the same wired-but-unauthored convention Constants.Flight.AnimationIds uses.
		RunningStage2 = "rbxassetid://95107102086715",
		-- The THIRD run stage's own clip (Constants.Attributes.SprintStage == 3). USER-SUPPLIED, not
		-- yet authored -- this codebase never guesses an asset id (see CombatAudio.lua/VitalIcon.lua's
		-- headers). Blank until pasted in, same convention as RunningStage2 above: the locomotion
		-- evaluator falls through to RunningStage2 (then, if that's also blank, to Running) when this
		-- has no id, so stage 3 still reads as a distinct gear through
		-- Constants.Run.Animation.PlaybackSpeeds alone until a real clip lands. That PlaybackSpeeds[3]
		-- rate (1.5x) was tuned for THAT fallback -- once a real clip is pasted here, dial it back
		-- toward 1 (see that field's own comment), or the clip will read as sped-up/cartoonish.
		RunningStage3 = "rbxassetid://126596518578942",
	} :: { [string]: string },

	-- PostureRegenPerSecond/HealthRegen/LockOnRange/ParryTellBroadcastRadius/MaxTrackedOpponents/
	-- PassiveVitalsSyncInterval/FeedbackHeadOffset were removed alongside the rest of the combat
	-- system -- every reader
	-- (CombatSystem.lua, CombatClient.lua, HitResolution.lua) is gone, and
	-- src/StarterPlayer/StarterCharacterScripts/Health.server.lua (the one file that still mentions
	-- HealthRegen) only ever referenced it in a comment, never read it.

	-- DebugHitboxes/Hitboxes (swept melee hitbox geometry/scheduling and its Studio debug-Part
	-- cosmetics) were removed alongside the rest of the combat system -- their one reader,
	-- Server/Combat/HitboxResolver.lua, is gone. HitboxShapes.lua's own FIELD_SPECS comments still
	-- cross-reference Hitboxes.MaxCandidateRadius by name for historical context (why its Max=500 was
	-- chosen), but never actually read the constant.

	-- Object Stun (Server/Combat/ObjectStunResolver.lua) -- the runtime constants that are NOT
	-- per-move authorable. Everything an author tunes per move lives on the move itself
	-- (Types.ObjectStunConfig); these are the physical/engine facts the resolver needs regardless of
	-- which move is being watched, kept here per luau-coding-standards.md's "no magic numbers in
	-- system logic" rather than as module-locals in the resolver.
	ObjectStun = {
		-- |normal.Y| past which a surface is classified Floor (positive) or Ceiling (negative)
		-- rather than Wall. 0.7 is ~45 degrees: a ramp steeper than 45 degrees reads, and behaves,
		-- as a wall to a body thrown into it.
		SurfaceNormalYThreshold = 0.7,
		-- Hard ceiling on how long a single watch can live, independent of the move's own
		-- MaxTravelSeconds -- a safety net against a watch leaking if a target is somehow never
		-- resolved (network ownership change mid-flight, a root part destroyed between ticks).
		MaxWatchSeconds = 8,
		-- Hard cap on simultaneously tracked watches server-wide. A watch is one shape cast per tick;
		-- this bounds the worst case in a large brawl where many moves with Object Stun land at
		-- once. Past it, new watches are declined (the move still hits normally, it just doesn't get
		-- the object-stun reaction) rather than degrading everyone's frame time.
		MaxActiveWatches = 48,
		-- How far BEHIND the target each probe starts, on top of the probe sphere's own radius. A
		-- shape cast reports nothing at all when it BEGINS already intersecting geometry, so a sweep
		-- started at the target's own centre would go blind against precisely the surface the target
		-- is already touching -- the one the clearance gate exists to find. Backing the sweep off by
		-- the full body radius plus this margin turns that case back into an ordinary hit at a short
		-- distance. The offset is added to the cast's length as well, so the distance probed AHEAD of
		-- the target is unchanged by it.
		ProbePaddingStuds = 0.25,
		-- Clamps on the radius ObjectStunResolver.probeRadiusFor derives from the TARGET'S OWN root
		-- part (both probes sweep a sphere of the target's body rather than a centre line -- see that
		-- module's header). A rig with an unusual root part must not be able to produce either a
		-- probe that degenerates back into a ray (a tiny NPC root) or one that swallows a room (a
		-- boss authored with an oversized root).
		MinProbeRadiusStuds = 0.5,
		MaxProbeRadiusStuds = 4,
		-- Hard ceiling on how far ahead a single tick may probe, INCLUDING the distance the target
		-- covers this frame (speed * deltaTime). deltaTime is not bounded: one long frame multiplied
		-- by a launch speed would otherwise sweep tens of studs and report a collision with a wall the
		-- target is nowhere near yet. Well clear of the authored ceiling on ProbeDistanceStuds
		-- (Constants.MoveEditor.ObjectStun.Limits caps it at 12) plus a frame of ordinary travel, so
		-- this only ever bites on a genuine hitch.
		MaxProbeDistanceStuds = 24,
		-- Fraction of the PREVIOUS tick's speed below which this tick counts as the target having
		-- been ARRESTED -- something stopped them, rather than a knockback decaying normally. On such
		-- a tick, and only then, a sweep that found nothing is re-asked as a direct overlap test:
		-- a body driven into a surface ends up intersecting it, which is exactly the state a shape
		-- cast cannot see out of. Gated this tightly because the overlap test is a spatial query the
		-- ordinary ticks of a flight have no reason to pay for.
		ArrestSpeedFraction = 0.25,
		-- The pin (ObjectStunConfig.PinSeconds) holds the target this far off the impact surface
		-- along its normal, so a body pinned against a wall isn't half-buried in it.
		PinSurfaceGapStuds = 1.5,
		-- AlignPosition tuning for that pin, passed straight to RagdollController.HoldAloft. Stiffer
		-- and faster than the air combo's own hover hold (Constants.Combat.AirCombo) on purpose: a
		-- body embedded in a wall should look STUCK, arriving instantly and not drifting, whereas an
		-- air-combo victim should float with some give.
		PinMaxSpeed = 120,
		PinResponsiveness = 60,

		-- The DROP that ends a pin. Previously the pin simply expired and the body was let go, which
		-- read as the target quietly sliding down the wall -- the release was the least interesting
		-- moment of a mechanic whose entire point is a hard impact. Instead the release hands the body
		-- to RagdollController.SlamToGround, the same function the Downslam finisher and the air
		-- combo's own slam finisher use, so the reaction lands as one sequence -- smashed into the
		-- surface, held against it, then driven into the floor -- and inherits Client/FX/
		-- SlamImpactVFX's full ground-impact payoff (dust, debris, shockwave, shake, hit-stop) rather
		-- than needing a second impact effect written for it.
		--
		-- Deliberately gentler than either of those two (Finisher.Downslam is 140, the air combo's is
		-- 85): both of those ARE the finisher, whereas this is the tail of a reaction whose headline
		-- beat already happened against the surface. SlamToGround clamps it to the clearance the target
		-- actually has anyway (resolveSlamScale), so a target pinned low against a wall takes the floor
		-- rather than punching through it.
		DropDownVelocity = 70,
		-- Same face-down pitch bias Constants.Combat.Finisher.Downslam.FaceDownSpin documents (see that
		-- field's own header for the mechanism and for why a pitch, unlike a velocity, still reads on a
		-- body with no room left to fall). Its own number rather than a reference to that one, per the
		-- same "each context keeps its own copy even where the values start equal" convention that
		-- field already establishes.
		DropFaceDownSpin = 9,
	},

	-- Two weapon loadout slots (combat-philosophy.md's "Established systems" list names "weapon
	-- switching with swap cooldown" alongside Lock-on/Block/Parry/Posture as already-canon). Each
	-- weapon owns its own Basic/Heavy/Finisher stage arrays (Types.HitboxAttackDefinition, same
	-- shape Hitboxes.Basic/Heavy/Finisher used before this table existed) -- CombatSystem.lua's
	-- selectAttackDefinition reads Weapons[state.equippedWeaponId].Stages instead of a single flat
	-- table, and RequestSwapWeapon (SwapCooldownSeconds below) toggles which one is active.
	-- Deliberately NOT a reskin: Secondary trades Primary's longer reach and higher per-hit damage
	-- for faster windup/cooldown and comparable-or-higher posture-damage-per-second, a genuine
	-- posture-hunting/tempo alternative to Primary's damage race -- combat-philosophy.md's Balance
	-- Principle #2 ("expand a kit's decision space, not just its damage"). First-pass technical
	-- values, not a balance pass; see combat-philosophy.md's Tuning process. Basic/Heavy each hold
	-- one entry per combo stage -- CombatSystem.lua wraps the attacker's comboIndex over however
	-- many stages are listed, so adding a stage is a data-only change, no code change.
	--
	-- Cooldown vs. WindupSeconds+ActiveSeconds+RecoverySeconds: every stage below sets Cooldown to
	-- (at most) its own full swing timeline, never longer. With no animation system yet (every
	-- swing's windup/active/recovery is currently invisible -- see CombatClient.lua's
	-- Combat_AttackStarted listener), a Cooldown longer than the swing's own timeline creates
	-- "dead time" where the swing has already finished but the next one still can't start, with
	-- nothing visible to explain why -- reads as unresponsive input, not a deliberate pause. Keeping
	-- Cooldown <= the timeline means attackEndsAt (the commitment lock, always exactly the timeline)
	-- is the true binding constraint, never Cooldown layering extra wait time on top of it.
	Weapons = {
		-- Which weapon a fresh CombatState starts equipped with (CombatTypes.lua's createFreshState/
		-- onCharacterAdded) -- also the only weapon training bots ever use (BotState has no
		-- equippedWeaponId field; see handleSwapWeaponRequest's own comment for why bot
		-- weapon-switching is out of scope).
		Default = "Primary" :: Types.WeaponId,
		-- Minimum seconds between accepted RequestSwapWeapon calls -- long enough that swap-spamming
		-- can't be used as an exploit or evasive tool, short enough to be a real mid-fight option,
		-- matching combat-philosophy.md's framing of the swap cooldown's purpose ("prevents instant
		-- weapon-cycling as a combo exploit").
		SwapCooldownSeconds = 4,

		Primary = {
			DisplayName = "Longsword",
			Stages = {
				Basic = {
					{
						DebugName = "Basic1",
						-- WindupSeconds retuned to 0.31 -- confirmed via live Studio playtest (dev menu's
						-- Hitbox Timing tab) that all three M1 stages read as landing on-swing at this
						-- value against the real swing clips, replacing the old placeholder-era 0.08.
						WindupSeconds = 0.31,
						ActiveSeconds = 0.22,
						RecoverySeconds = 0.14,
						-- Sizes across every stage/weapon retuned "slightly bigger than the player" (a
						-- standard R15 character is ~2x2x1 HumanoidRootPart, ~5-6 studs tall): height
						-- flattened to a single generous 6.5 across every melee stage (was
						-- inconsistently as low as 4 on Secondary, undershooting a standing target), and
						-- every X/reach-offset scaled x1.2 off the old values, preserving the existing
						-- relative growth between combo stages.
						--
						-- Z (reach) then cut by another ~35% across EVERY stage of BOTH weapons in one
						-- pass (this comment applies to that whole pass, not just Basic1) -- a live
						-- playtest screenshot showed Basic1's swing box reaching a full 7 studs forward
						-- (flush against the root, Offset always exactly -Size.Z/2 -- see
						-- Hitboxes.MaxCandidateRadius's own comment for that convention), roughly 3-4x a
						-- standing character's own body depth, well past what a sword swing should
						-- plausibly reach. Every Size.Z/Offset pair below is scaled by the same ~0.65
						-- factor so relative combo-stage growth (Basic < Heavy < Finisher) and the
						-- Secondary-vs-Primary reach ratio both stay exactly as designed -- only the
						-- absolute scale shrank. X/Y untouched.
						Size = Vector3.new(6, 6.5, 4.5),
						Offset = CFrame.new(0, 0, -2.25),
						Damage = 8,
						PostureDamage = 10,
						Cooldown = 0.44,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Basic2",
						WindupSeconds = 0.31,
						ActiveSeconds = 0.22,
						RecoverySeconds = 0.16,
						Size = Vector3.new(6, 6.5, 4.5),
						Offset = CFrame.new(0, 0, -2.25),
						Damage = 9,
						PostureDamage = 10,
						Cooldown = 0.47,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Basic3",
						WindupSeconds = 0.31,
						ActiveSeconds = 0.24,
						RecoverySeconds = 0.20,
						Size = Vector3.new(6.5, 6.5, 5.25),
						Offset = CFrame.new(0, 0, -2.625),
						Damage = 11,
						PostureDamage = 12,
						Cooldown = 0.54,
						ArcDegrees = 110,
						MaxTargets = 3,
					},
				},

				-- A single swing, not a string -- Heavy intentionally holds exactly one stage (array of
				-- one, not a bare table) so DefaultMoveRegistry/SwingSequencer's generic per-stage
				-- machinery still applies with zero special-casing; every Heavy press just keeps
				-- resolving back to this same stage, the same "one past the end wraps to 1" rule any
				-- other string follows. There used to be a second stage; it never received an authored
				-- animation and only added a second, harder-hitting swing on the same telegraph, so it
				-- was cut rather than finished.
				Heavy = {
					{
						DebugName = "Heavy",
						WindupSeconds = 0.600,
						ActiveSeconds = 0.22,
						-- 0.55, up from 0.35 (docs/architecture/2026-08-audit.md section 6.1/3.4) -- funds the
						-- Cooldown cut below out of a longer whiff/block punish window instead of a free
						-- reduction, so a missed Heavy stays risky.
						RecoverySeconds = 0.55,
						Size = Vector3.new(7, 6.5, 5.5),
						Offset = CFrame.new(0, 0, -2.75),
						Damage = 12,
						PostureDamage = 22,
						-- 1.37, down from 3.00 -- restores the "Cooldown == Windup+Active+Recovery" invariant
						-- this table's own header requires, matching Secondary's own Heavy stage
						-- (DaggerHeavy.Cooldown ~= its own timeline). At 3.00 the heavy button was dead
						-- ~1.63s AFTER the swing had visibly ended, with nothing on screen explaining why --
						-- reads as unresponsive input, not a deliberate pause.
						Cooldown = 1.37,
						ArcDegrees = 120,
						MaxTargets = 4,
					},
				},

				-- The M1 combo finisher (reached at BasicComboLength). Its own hitbox category, NOT
				-- a Basic stage, so training bots (which cycle Basic) never throw it and the Basic
				-- string stays a plain 3-stage combo. A single definition, not an array -- there is
				-- one finisher swing per weapon; the three variants (uppercut/downslam/normal)
				-- differ in the knockback applied on a clean hit (Constants.Combat.Finisher above),
				-- not in the swing geometry. Deliberately telegraphed: a longer Windup than any
				-- Basic stage so it reads (combat-philosophy.md's "reads beat reflexes"), a longer
				-- Recovery so a whiffed or blocked finisher is punishable, and MaxTargets = 1 (a
				-- launcher commits to one foe, not a crowd-clear).
				Finisher = {
					DebugName = "Finisher",
					WindupSeconds = 0.28,
					ActiveSeconds = 0.18,
					RecoverySeconds = 0.45,
					Size = Vector3.new(7, 6.5, 5.5),
					Offset = CFrame.new(0, 0, -2.75),
					Damage = 20,
					PostureDamage = 35,
					Cooldown = 0.9,
					ArcDegrees = 110,
					MaxTargets = 1,
				},
			},
		},

		-- Faster, shorter-reach, lower-per-hit-damage alternative to Primary -- see this table's own
		-- header for the design intent. Roughly: ~75% of Primary's windup/cooldown (faster tempo),
		-- ~85% of Primary's reach (Size/Offset), ~70% of Primary's per-hit Damage, but PostureDamage
		-- held close to Primary's -- net higher posture-damage-per-second despite lower raw damage.
		Secondary = {
			DisplayName = "Dual Daggers",
			Stages = {
				Basic = {
					{
						DebugName = "Dagger1",
						-- 0.16, up from 0.06. Secondary's own header promises "~75% of Primary's windup",
						-- but Primary's Basics were retuned 0.08 -> 0.31 in a live playtest pass and
						-- Secondary was never brought along, leaving it at ~20% of Primary rather than 75%.
						-- The result was a de facto true unparryable: a 60ms windup, over a network, against
						-- a 30Hz hitbox sampler, cannot be reacted to at all, which combat-philosophy.md's
						-- Balance Principle 3 forbids without an explicit telegraphed cost. It also made
						-- Feint (legal only inside windup) mechanically nonexistent on this weapon.
						--
						-- The added windup is funded mostly out of RecoverySeconds rather than bolted onto
						-- the front, so the total timeline barely moves (0.33 -> 0.35) and Secondary keeps
						-- its fast tempo and its roughly-75%-of-Primary cooldown ratio. What changed is the
						-- SHAPE of the swing: more of it is readable telegraph, less is endlag. The
						-- trade-off is a shorter whiff-punish window, accepted because an unreactable
						-- attack is the worse failure. Cooldown stays exactly Windup+Active+Recovery, the
						-- invariant this table's header states and every stage here already satisfied.
						-- Kept strictly under DaggerFinisher's 0.22 so the finisher remains the most
						-- telegraphed swing in the kit, as every other weapon's finisher is.
						--
						-- Still owed: a live Studio playtest pass on these three stages, the same one
						-- Primary's Basics got when they moved 0.08 -> 0.31.
						WindupSeconds = 0.16,
						ActiveSeconds = 0.11,
						RecoverySeconds = 0.08,
						-- Z cut ~35% same as Primary above -- see Basic1's own comment for why.
						Size = Vector3.new(5, 6.5, 3.75),
						Offset = CFrame.new(0, 0, -1.875),
						Damage = 6,
						PostureDamage = 9,
						Cooldown = 0.35,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Dagger2",
						-- See Dagger1's WindupSeconds header for why this rose from 0.07 and why the
						-- recovery fell to pay for it. Cooldown stays Windup+Active+Recovery.
						WindupSeconds = 0.17,
						ActiveSeconds = 0.11,
						RecoverySeconds = 0.09,
						Size = Vector3.new(5, 6.5, 3.75),
						Offset = CFrame.new(0, 0, -1.875),
						Damage = 7,
						PostureDamage = 9,
						Cooldown = 0.37,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Dagger3",
						-- See Dagger1's WindupSeconds header for why this rose from 0.08 and why the
						-- recovery fell to pay for it. Cooldown stays Windup+Active+Recovery.
						WindupSeconds = 0.18,
						ActiveSeconds = 0.12,
						RecoverySeconds = 0.11,
						Size = Vector3.new(5.5, 6.5, 4.25),
						Offset = CFrame.new(0, 0, -2.125),
						Damage = 8,
						PostureDamage = 11,
						Cooldown = 0.41,
						ArcDegrees = 110,
						MaxTargets = 3,
					},
				},

				-- Single-stage, same as Primary's own Heavy above -- see that field's own header for why
				-- (a cut second stage, not a stub waiting to be authored).
				Heavy = {
					{
						DebugName = "DaggerHeavy",
						WindupSeconds = 0.14,
						ActiveSeconds = 0.17,
						RecoverySeconds = 0.27,
						Size = Vector3.new(6, 6.5, 4.5),
						Offset = CFrame.new(0, 0, -2.25),
						Damage = 13,
						PostureDamage = 20,
						Cooldown = 0.58,
						ArcDegrees = 120,
						MaxTargets = 4,
					},
				},

				Finisher = {
					DebugName = "DaggerFinisher",
					WindupSeconds = 0.22,
					ActiveSeconds = 0.14,
					RecoverySeconds = 0.35,
					Size = Vector3.new(6, 6.5, 4.5),
					Offset = CFrame.new(0, 0, -2.25),
					Damage = 14,
					PostureDamage = 32,
					Cooldown = 0.68,
					ArcDegrees = 110,
					MaxTargets = 1,
				},
			},
		},
	},

	-- BallSocketConstraint cone/twist limits Server/Combat/RagdollController.lua applies to every
	-- non-Root joint while ragdolled -- loose enough to read as floppy, tight enough that limbs
	-- don't invert into a spiky mess. First-pass values; purely cosmetic, safe to tune. Were
	-- module-local constants in RagdollController.lua; moved here per luau-coding-standards.md's
	-- "no magic numbers in system logic," matching every other physics/hitbox tunable's home.
	Ragdoll = {
		BallSocketUpperAngle = 45,
		BallSocketTwistLowerAngle = -45,
		BallSocketTwistUpperAngle = 45,
		-- Rotational friction (stud * mass * stud / s^2) on every ragdoll ball socket. A frictionless
		-- socket has nothing to bleed energy into, so a limb that gets kicked by a landing impact keeps
		-- swinging on essentially forever -- the "spaghetti flail that never settles" look. Friction is
		-- what makes a ragdoll come to REST at a natural pose within a second or so of landing instead
		-- of twitching for its whole knockdown window. Deliberately modest: too high reads as a stiff
		-- mannequin that barely reacts to the hit at all. Dropped to zero during the recovery blend
		-- (RecoverBlendSeconds below) so it never fights the limbs' own return to rest pose.
		BallSocketFrictionTorque = 15,
		-- Elasticity every ragdoll part is forced to for as long as it's limp, overriding whatever its
		-- material (or the ground/terrain/grass it lands on) would otherwise contribute -- Roblox
		-- resolves a collision's bounce from BOTH surfaces' Elasticity (weighted by ElasticityWeight,
		-- Average by default), so a real material's non-zero default was enough, at the speeds a
		-- finisher launch or a wall-drop actually lands at, to visibly bounce/launch a body back off
		-- the ground it just fell onto -- which is what read as "flying" on landing, distinct from the
		-- mid-air launch itself. RagdollElasticityWeight is set far above any ordinary surface's own
		-- weight (Roblox materials default to 1) specifically so this zero wins the combine regardless
		-- of what the character lands on.
		RagdollElasticity = 0,
		RagdollElasticityWeight = 100,
		-- Hard ceiling (studs/s) on any linear velocity RagdollController writes onto a body. Nothing
		-- authored today comes close (the biggest is Finisher.Downslam's 140), so this never bites on a
		-- tuned move -- it exists so an authored Move Creation System knockback (Types.
		-- HitboxAttackDefinition.Knockback is designer-editable at runtime via the Move Editor) can't
		-- fat-finger a body clean off the map. A ragdoll that leaves the play space can't be recovered
		-- into anything meaningful, so this is a containment guard, not a feel knob.
		MaxLaunchSpeed = 250,
		-- Smooth recovery ("blend") -- how long the body spends physically folding back to its rest pose
		-- BEFORE the Motor6Ds are re-enabled, instead of snapping there in one frame. Re-enabling a
		-- Motor6D instantly teleports its limb from wherever physics left it to wherever the animation
		-- says it should be; from a sprawled ragdoll that is a large, very visible pop on every client.
		-- During this window each joint gets an AlignOrientation easing it back toward the pose captured
		-- at ragdoll time while the socket's own cone/twist limits tighten toward zero, so by the time
		-- the motors come back the limbs are already within a few degrees of where the motors would put
		-- them and the handoff is invisible. All of it is real physics on a server-owned assembly, so it
		-- replicates to every client -- a script-side Motor6D.Transform lerp would NOT (Transform is
		-- evaluated per-client by each Animator, so a server write to it is never seen by anyone else).
		--
		-- Long enough to read as "picking myself up," short enough that it never eats into the authored
		-- RagdollSeconds/KnockdownSeconds an attacker is counting on: the blend runs AFTER that window
		-- expires, so it is added lockout, which is why it stays well under a quarter second of feel.
		RecoverBlendSeconds = 0.35,
		-- AlignOrientation.Responsiveness the per-joint recovery drives ramp UP to across the blend
		-- (eased in as alpha^2 from 0, so the fold-back starts as a gentle gather rather than an
		-- immediate yank the instant the window opens). Higher = limbs snap to rest pose sooner within
		-- the blend; lower = a looser, more gradual gather that may not fully arrive before the motors
		-- re-enable.
		RecoverJointResponsiveness = 30,
		-- Same ramp, for the single AlignOrientation that brings the root assembly (HRP + LowerTorso)
		-- back upright during the blend. Softer than the joints' own value on purpose: this rotates the
		-- heaviest part of the body and the CAMERA follows it, so an aggressive gain here reads as the
		-- view being wrenched upright. Yaw is preserved (the body stands up facing wherever it landed),
		-- only pitch/roll are corrected.
		RecoverUprightResponsiveness = 20,
		-- What the ball sockets' cone/twist limits tighten TO by the end of the blend (degrees, from
		-- BallSocketUpperAngle/BallSocketTwist*Angle above). Not zero -- a hard 0 makes the solver fight
		-- itself against unavoidable float error on the last step -- just small enough that the residual
		-- error the motors have to absorb on re-enable is below what the eye can catch.
		RecoverEndAngle = 5,
		-- Settle-aware recovery (RagdollController.isSettled / Update). A knockdown's authored window
		-- is "how long they're down", but a real launch spends much of that window still IN THE AIR --
		-- a timer-only recovery therefore opened the stand-up blend mid-flight, so the body folded
		-- itself upright while still travelling and landed neatly on its feet, which reads as the
		-- knockback being shrugged off. Recovery now additionally waits for the body to actually stop
		-- moving. Speed (studs/s) at or below which a limp body counts as done moving: comfortably
		-- above the residual jitter a settled ragdoll keeps from its own ball-socket friction, well
		-- below any speed a body is still meaningfully travelling at.
		RecoverSettleSpeed = 6,
		-- Hard cap on that extra wait, measured from the authored window's own expiry. Bounds the one
		-- failure mode the wait introduces -- a body that never comes to rest (knocked into a
		-- bottomless fall, onto a conveyor, into geometry the solver keeps nudging) would otherwise
		-- stay limp forever. Long enough to cover a full finisher launch's remaining hangtime, short
		-- enough that a caller mirroring this module's timer (see RagdollController.RemainingSeconds)
		-- never drifts by a gameplay-relevant amount.
		RecoverSettleMaxSeconds = 0.75,
		-- Below this horizontal distance between the air-combo hold position and the face-toward
		-- point, ensureFaceOrientation skips re-aligning rather than pointing at a near-zero look
		-- vector (the degenerate "target directly overhead" case).
		FaceAlignToleranceStuds = 0.05,
		-- ensureFaceOrientation's AlignOrientation eases toward its face-point at this Responsiveness
		-- (RigidityEnabled = false, MaxTorque = math.huge -- same soft-constraint pairing HoldAloft's
		-- own AlignPosition already uses for position) instead of snapping instantly. A rigid lock read
		-- fine for the ORIGINAL air-combo design (only ever a small correction -- an attacker already
		-- entering roughly facing the target they just DashPunched), but AirCombo.SwitchPriority can
		-- now re-point a body that was facing ANY direction a moment ago (the new victim was mid-swing,
		-- not necessarily aligned with the new attacker) -- an instant, potentially large re-facing
		-- whips the third-person camera (which follows the character's own back) around with it,
		-- reading as the camera lurching to stare at whoever's now attacking instead of smoothly
		-- panning to keep watching the player's own back through the turn.
		--
		-- 50, not the original 10 -- a SwitchPriority re-facing is routinely close to a full 180 (the
		-- parrier and the puncher were facing each other, so each now needs to reverse), and 10 was
		-- tuned only against the ORIGINAL design's small corrections. At that gain a big turn crawled
		-- so slowly it read as "doesn't turn to face the opponent at all" rather than a smooth pan --
		-- indistinguishable, over the few seconds someone actually watches it, from stuck facing the
		-- old direction. MaxTorque is already math.huge (uncapped authority), so raising Responsiveness
		-- doesn't fight that -- it's purely how quickly the constraint spends that authority. 50 still
		-- reads as a deliberate turn, not a snap, for the ORIGINAL small-correction case, while actually
		-- completing a big SwitchPriority re-facing within a fraction of a second instead of many.
		FaceOrientationResponsiveness = 50,
		-- Ground-aware slam clamping (RagdollController.SlamToGround / resolveGroundClearance) -- fixes
		-- "the downslam launches the target INTO THE AIR instead of into the floor." A slam writes its
		-- DownVelocity onto EVERY BasePart, and AirSlam only ever requires the ATTACKER to be airborne
		-- (Constants.Combat.AirSlam / CombatSystem.isAirborneForAirSlam), so the overwhelmingly common
		-- downslam target is someone STANDING ON THE GROUND -- feet already in contact with the floor.
		-- Injecting a large downward velocity into a body that has nowhere to fall drives every part
		-- through the floor surface on the very first physics step (at 140 studs/s that's 2.33 studs per
		-- 1/60s step, deeper than the parts are tall), and Roblox's penetration recovery then ejects them
		-- back out hard -- each ball-socketed limb resolving in its own direction, which is precisely what
		-- read as the body rocketing upward and flipping the instant it was hit. A slam only has anywhere
		-- to GO if there's real clearance beneath the target, so the applied speed is scaled to that.
		--
		-- How far down resolveGroundClearance looks for a floor. A miss (nothing within range -- slammed
		-- out over a void or off a cliff) means there's nothing to hit and so nothing to clamp against:
		-- the full authored DownVelocity applies unscaled.
		SlamGroundCheckDistance = 512,
		-- The clamp itself: usable drop distance / this = the fastest the body may travel without
		-- outrunning the solver's ability to resolve contact. 1/15s is roughly four physics steps of
		-- headroom, so even at the clamped speed a part covers well under its own height per step. A
		-- target with a full 12-stud air-combo HoverHeight beneath them still clears the authored 140
		-- outright (12 / (1/15) = 180) and slams at full force -- this only ever bites on a target who
		-- genuinely has no room to fall.
		SlamPenetrationGuardSeconds = 1 / 15,
		-- Floor on the clamped result, so a slam on an already-grounded target still reads as a real
		-- physical pop rather than a silent collapse -- the ragdoll itself, independent of whether
		-- Client/FX/SlamImpactVFX.BeginWatch's own detection catches it (see
		-- SlamImmediateImpactDropStuds below for that half of the story). First pass shipped this at a
		-- bare 25 -- just past Constants.FX.SlamImpact.FastFallSpeedThreshold (20 studs/s) -- and it
		-- read as barely any hit at all (RagdollController.SlamToGround's own FaceDownSpin is
		-- deliberately NOT gated by this same clearance clamp, so the pitch was never the missing
		-- piece; the velocity floor was). 50 is still well clear of the tunnel-through-the-floor regime
		-- the SlamPenetrationGuardSeconds clamp above exists to avoid (0.83 studs of travel per physics
		-- step, versus a HumanoidRootPart's own ~2-stud height, and the Ragdoll collision group /
		-- buildRagdollJoints' pose-capture fix already removed the two mechanisms -- self-collision
		-- explosion and rest-pose joint snapping -- that actually caused a grounded slam to eject
		-- upward in the first place, so this floor is no longer fighting those). Purely a feel tunable
		-- -- raise or lower freely.
		SlamMinDownVelocity = 50,
		-- Usable-drop distance (studs, from resolveSlamScale's own clearance math) at or below which
		-- RagdollController.SlamToGround reports the impact as IMMEDIATE rather than something the
		-- client should watch for. This exists because Client/FX/SlamImpactVFX.BeginWatch's own
		-- fall-then-arrest detection is a Heartbeat-rate poll (~60Hz) of REPLICATED velocity, and a
		-- clamped-to-near-zero slam (the common case: a target already standing on the ground, which
		-- is most Downslam finishers and most standalone AirSlams) travels its entire clamped drop and
		-- fully arrests within a SINGLE physics step -- often within a single Heartbeat interval, and
		-- sometimes within a single network replication snapshot, meaning the transient fast-falling
		-- velocity the poll is looking for may never be sampled, or may never even be sent to the
		-- client at all. No amount of client-side polling can reliably catch a transition that fast --
		-- the server already knows definitively (via this exact clearance calculation) that contact is
		-- essentially instantaneous, so it says so directly instead of making the client guess. A
		-- target with real height on them (a genuine multi-frame fall) stays well above this and keeps
		-- using the existing velocity-poll detection, which works fine for that case. 1.5 is comfortably
		-- inside "no meaningful fall to observe" (SlamPenetrationGuardSeconds's own 1/15s guard already
		-- caps a body at this range to a few studs/sec) while staying well clear of a genuine short hop.
		SlamImmediateImpactDropStuds = 1.5,
	},

	-- Sound (CombatAudio.lua's registered sound effects) and RemoteNames (every RemoteEvent
	-- CombatSystem.lua owned) were removed alongside the rest of the combat system -- CombatAudio.lua
	-- is gone, and every remote these named was created exclusively by CombatSystem.lua's own Init(),
	-- which no longer runs. HotbarMoveClient.lua/HotbarBindings.lua's own header still references
	-- RequestFireHotbarMove by name for historical context; that module was also removed (see
	-- Client/Combat/HotbarBindings.lua's own header on the surviving data-only half).
}

return Constants
