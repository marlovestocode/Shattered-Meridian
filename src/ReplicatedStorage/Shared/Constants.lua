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
			StorybookClient = true,
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
			-- The swing's own forward step (Client/Combat/SwingLunge.lua). Its only lines are the
			-- Start() lifecycle one and a warn for a character that arrived without a Humanoid or a
			-- root -- which is precisely the case where a player reports "my swings don't move me"
			-- and there is otherwise nothing anywhere to read.
			SwingLunge = true,
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
			-- WallRunning is the second, and earned one the same way: its Catching phase (the head-on
			-- wall catch) is a decision made and lost inside a tenth of a second, against geometry the
			-- player cannot see the measurements of. "I ran at the wall and nothing happened" has no
			-- answer anywhere without this -- the F6 overlay can show the verdict live, but only if the
			-- panel is open and the eye is on it at that exact instant. Edge-triggered, so this costs
			-- nothing until a verdict actually changes -- see ParkourConstants.Debug.LogWallCatch.
			WallRunning = true,

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
			-- Live Admin Console (F5). These two entries only gate their own Init/lifecycle lines
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
			-- Per-weapon idle-clip resolution (Shared/Combat/WeaponIdleAnimations.lua). Its Get() traces
			-- every step of finding a weapon's Animations/IDLE clip -- missing folder, missing
			-- subfolder, no Animation instance, a blank AnimationId -- which is what actually
			-- distinguishes "wrong weaponId," "wrong folder shape," and "the clip has no real content
			-- authored" from each other, none of which read any differently from CombatAnimator's own
			-- side of the seam.
			WeaponIdleAnimations = true,
			-- Per-weapon swing-clip resolution (Shared/Attack/AttackAnimations.lua) -- the identical
			-- trace, one folder slot per M1/M2/M3/HEAVY/FINISHER stage instead of IDLE alone.
			AttackAnimations = true,
			-- Per-weapon PARRY/BLOCK resolution (Shared/Defense/WeaponDefenseAnimations.lua) -- the same
			-- trace again, and the one where it earns the most: an unresolved PARRY slot does not just
			-- look wrong, it silently costs that weapon its parry WINDOW, since the window IS that
			-- clip's markers. This trace distinguishes the five authoring states; ParryWindows' own
			-- boot-time ValidateAll warning is what reports the sixth (a real clip with no markers).
			WeaponDefenseAnimations = true,
		},
		-- Per (scope, level, message) cap, keyed off the static message text so a log site that
		-- fires every frame can't flood Output even at Trace -- see Logger.lua's rate limiter. Also
		-- gates the always-on console capture buffer below (same key, same window) for the identical
		-- flood-protection reason, independent of Enabled/IsStudio.
		MaxRepeatsPerSecond = 20,
		-- Fixed capacity of Logger.lua's always-on capture buffer (one per VM -- the server has its
		-- own, each client has its own), read once at require-time. Feeds
		-- Server/Systems/LiveConsoleSystem.lua's Subscribe snapshot and Client/DevTools/LiveConsole/
		-- LiveConsoleClient.lua's local "My Client" tab -- NOT gated by Enabled/IsStudio/Level/Scope
		-- above (see Logger.lua's own header for why that split is safe). Oldest entries are evicted
		-- past this count; 1000 is generous enough to cover a genuine investigation window without
		-- an unbounded per-VM memory cost.
		ConsoleBufferSize = 1000,
		-- Minimum level the always-on capture buffer above will RECORD: same vocabulary as `Level`,
		-- and deliberately a separate knob from it. `Level` gates printing to Studio Output (and is
		-- already dead outside Studio); this one gates the capture path, which is the only part of
		-- this module that costs anything in a live server -- a LogEntry table, a ring write, and a
		-- fan-out to every Logger.OnEntry listener, paid on all 380-odd logger:debug call sites in
		-- src/ whether or not an admin is ever going to read them.
		--
		-- THIS IS THE IDLE FLOOR, not the only one. It is what gets recorded when nobody is
		-- watching, which on a live server is almost always -- and "Trace" here meant every one of
		-- the ~981 logger: call sites in src/ allocated a LogEntry table, called os.time() and
		-- fanned out to every listener, in both VMs, forever, for a buffer only an admin ever reads.
		--
		-- "Info" makes every Trace/Debug call site resolve to one upvalue compare and a return,
		-- which is the cheapest a call can be without deleting it. The Live Console does not lose
		-- its debug lines: Server/Systems/LiveConsoleSystem.lua calls Logger.SetCaptureLevel("Trace")
		-- on the first admin subscribing and restores this level when the last one leaves, so
		-- everything from the moment a console opens is complete. What is genuinely given up is
		-- Trace/Debug HISTORY from before it opened -- the ring still reaches back 1000 entries, but
		-- the older ones are Info and above. That is the right side of the trade for a live server:
		-- a debug line nobody was there to read is not worth a table allocation per frame.
		--
		-- Set this to "Trace" to go back to capturing everything unconditionally (a Studio session,
		-- or a server being actively investigated where the pre-open backlog matters more than the
		-- allocation). Logger.lua reads it once at require-time into an upvalue, so a change here
		-- needs a restart -- SetCaptureLevel is the live knob.
		CaptureLevel = "Info",
	},

	-- Whitelist-gated developer tooling -- unlike Logging above, this is NOT Studio-only; it's
	-- meant to work in live servers too, since that's often exactly when a developer needs it.
	-- Safety comes entirely from the whitelist below plus DevMenuSystem.lua re-checking every
	-- request's Player.UserId server-side -- never from being hidden or from Studio-gating. See
	-- DevMenuSystem.lua's header for the full authorization contract.
	-- The component Storybook (Client/UI/Screens/DevTools/Storybook/init.lua, driven by
	-- Client/DevTools/Storybook/StorybookClient.lua) -- the gallery of every shared component, token and layout
	-- primitive. Studio-only diagnostics, which is why it lives under Constants.Debug rather than in
	-- Constants.Keybinds below.
	Storybook = {
		-- Master switch, same shape and same meaning as Logging.Enabled above: the driver ALSO requires
		-- RunService:IsStudio(), so shipping this true is safe -- it does nothing on a live client.
		Enabled = true,
		-- A RAW key, deliberately NOT a Types.KeybindAction in Constants.Keybinds. Same call
		-- ParkourConstants.Debug.ToggleKeyCode's F6 overlay makes, for the same reason: an authoring tool
		-- that never opens for a player has no business occupying a row in the player-facing rebind list.
		--
		-- The cost of a raw bind is that no table checks it for collisions, which is exactly how F5 and
		-- F6 ended up both firing on one press (see Constants.Keybinds.Defaults.OpenDevConsole's own
		-- comment). So, checked by hand against BOTH tables at the time of writing: F5 is
		-- OpenDevConsole, F6 is ParkourConstants.Debug.ToggleKeyCode, F8 is OpenBugReport, and F7 --
		-- this -- was free in both. A future dev key must check all three places.
		ToggleKeyCode = Enum.KeyCode.F7,
	},

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
			-- Debug Dummy (Server/Systems/DebugDummySystem.lua) -- a real, fully-registered combatant
			-- against the rebuilt HitboxEngine/DefenseSystem stack, not the deleted CombatSystem's own
			-- training dummy. SpawnDummy is the same name that module's own SpawnDummy action used
			-- (never renamed -- this is the direct successor to that action, not a new feature sharing
			-- an old label), reused here rather than minted fresh. SpawnTrainingBot stays UNUSED and
			-- orphaned -- an AI-controlled training bot is a materially bigger feature that nothing in
			-- the rebuilt stack has rebuilt yet (its tunables were deleted with TrainingBotSystem.lua
			-- since neither ever had a caller; re-author them if this gets rebuilt).
			SpawnDummy = "DevMenu_SpawnDummy",
			-- Clears every active debug dummy at once -- the Spawn tab's companion to SpawnDummy, so a
			-- tester can reset the training area without waiting out MaxActive eviction one dummy at a
			-- time.
			DespawnAllDebugDummies = "DevMenu_DespawnAllDebugDummies",
			-- Server-wide toggle: every currently-active (and every future) debug dummy holds its guard
			-- up until toggled off again -- see DebugDummySystem.SetGuard's own header for why this
			-- makes Blocked/Parried/GuardBroken all testable against a dummy, not just Clean/Backstab.
			SetDummyGuard = "DevMenu_SetDummyGuard",
			-- Fetch-once-on-open for the Spawn tab's Guard toggle and active-count readout -- same
			-- "never let a joining admin's client guess a server-wide toggle's truth" reasoning
			-- GetHitboxDebug already establishes for the swing-volume visualiser.
			GetDebugDummyState = "DevMenu_GetDebugDummyState",
			SpawnTrainingBot = "DevMenu_SpawnTrainingBot",
			-- Blimp Fuel System's dev/test convenience (Server/Systems/ResourceGatheringSystem.
			-- SpawnDebugNode) -- spawns one tagged CoalDeposit/WaterSource Part near the requesting
			-- admin, the same "spawn near me" shape SpawnDummy above already uses, so a tester can
			-- gather without a builder having placed real world nodes yet.
			SpawnCoalDeposit = "DevMenu_SpawnCoalDeposit",
			SpawnWaterSource = "DevMenu_SpawnWaterSource",
			-- Tops the requesting admin's own carried coal AND water up to their carry cap in one
			-- call. The companion to the two node spawns above, and the one a tester actually reaches
			-- for: those place a rock to mine, this skips the mining. Between them, "I want to test a
			-- blimp" stops being a gathering trip.
			FillCarriedFuel = "DevMenu_FillCarriedFuel",
			-- Admin actions -- all three target whichever player the requesting admin currently has
			-- locked on (CombatState.lockOnTarget), falling back to themselves if nothing's locked --
			-- reuses the existing lock-on system as the "who am I targeting" picker instead of a new
			-- player-select UI. See DevMenuSystem.lua's handleSetHealth/handleSetGodmode/
			-- handleSetFlight for the resolution.
			-- Hands the resolved target BloodlineConstants.DevGrantRerollAmount bloodline rerolls.
			-- The ONLY grant path that exists for them -- a fresh profile gets StartingRerolls and
			-- nothing in the game has ever added one since, so the character menu's reroll control was
			-- permanently dead for anyone who spent theirs. See BloodlineSystem.GrantRerolls.
			GrantBloodlineRerolls = "DevMenu_GrantBloodlineRerolls",
			SetTargetHealth = "DevMenu_SetTargetHealth",
			SetTargetGodmode = "DevMenu_SetTargetGodmode",
			SetTargetFlight = "DevMenu_SetTargetFlight",
			-- Toggles Collide mode for an already-flying target (Client/Flight/FlightPhysics.lua) --
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
			-- Sidebar header stats (persistent Sidebar, Screens/DevTools/DevMenu/Sidebar.lua) -- one combined
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

-- Training dummy tunables -- Server/Systems/DebugDummySystem.lua owns the dummy's actual combat
-- behavior now (a real, fully-registered HitboxEngine/DefenseSystem combatant, not a static prop:
-- swings resolve against it exactly like a player, including guard/posture-break and death/respawn).
-- CombatSystem.lua's own training dummy (this table's original owner) was deleted along with the rest
-- of that system; every field below was worth keeping because the CONCEPT survived the teardown even
-- though the implementation didn't -- see DebugDummySystem.lua's own header for the rebuilt version.
-- Grouped under Debug because the dummy itself is dev-only tooling (only DevMenuSystem.lua can spawn
-- one), not because these specific fields are diagnostic flags.
Constants.Debug.TrainingDummy = {
	MaxHealth = 500,
	-- SUPERSEDED, not read by DebugDummySystem.lua. The rebuilt stack has no per-combatant posture
	-- ceiling to configure -- Guard IS the posture pool now, and its max is the one global
	-- DefenseConstants.Guard.Max every combatant (player, bot, or dummy) shares alike. Left here rather
	-- than deleted purely as a record of what the old system's own dummy configured; a future pass
	-- that actually wants a taller-than-normal guard bar on the dummy specifically would need
	-- DefenseSystem to grow a per-combatant override first, which it does not have today.
	MaxPosture = 100,
	-- Seconds after a dummy is defeated before it's replaced with a fresh one at the same spawn
	-- point. A dead Humanoid can't be revived in place (Roblox's Dead HumanoidStateType is
	-- terminal), so "respawn" here means destroy-and-recreate, not heal-back-up -- see
	-- DebugDummySystem.lua's own reviveInPlace.
	RespawnDelay = 3,
	-- Studs in front of the requesting player's HumanoidRootPart to spawn a new dummy.
	SpawnDistance = 8,
	-- Oldest active dummy is despawned to make room once this many exist at once -- keeps repeated
	-- dev menu use from growing Workspace unbounded without needing a separate despawn action (Despawn
	-- All is still offered as its own action for a deliberate full reset).
	MaxActive = 5,
	-- SUPERSEDED, not read by DebugDummySystem.lua -- the deleted CombatSystem's own finisher/ragdoll
	-- launch-and-reset loop has no equivalent in the rebuilt stack yet (Knockback resolves as a number
	-- but nothing applies the physics -- see DamageTypes.DamageResult.Knockback's own header). Left
	-- here as a record of the original behavior for whichever future pass rebuilds it.
	LaunchResetBufferSeconds = 1.5,
	-- Floating log billboard's rolling event buffer (DebugDummySystem.lua's pushLogLine) -- how many
	-- of the most recent resolved hits/grab-state changes stay visible above the status line before
	-- the oldest scrolls off. Short enough that the billboard stays readable at a glance; long enough
	-- to see a short combo's worth of hits without needing to squint at a wall of text.
	LogLineCount = 5,
	-- The debug dummy's own BillboardGui size -- taller and wider than a plain nameplate would need,
	-- since this one also renders the live HP/Guard/Grabbed status line and the rolling event log,
	-- not just a name.
	BillboardSize = UDim2.fromOffset(240, 150),
	-- Floating nameplate/body color (DebugDummySystem.lua's buildRig, reused for both the
	-- HumanoidDescription's body colors AND the billboard) -- amber/burnished-gold, the same swatch as
	-- Tokens.Color.Warning/the Posture vital, reading as a passive, non-threatening practice target
	-- rather than a live opponent.
	LabelColor = Color3.fromRGB(199, 149, 34),
}

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
		-- ShiftLock below -- Q is the conventional dodge/evade key this genre has left. Read by
		-- Client/Parkour/ParkourInput.lua, which buffers the press for States/Dashing.lua: the
		-- four-way, facing-relative dash. (It named CombatSystem.lua's handleDashRequest for a while
		-- after that system was deleted, with nothing reading the binding at all -- a rebind row in
		-- the Settings panel for a key that did nothing.)
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
		-- T is the conventional "draw/sheath" key in the genre. Fires Weapon_ToggleDraw --
		-- Server/Combat/Weapon/WeaponInventorySystem.lua pulls out the selected weapon, or puts it
		-- away if it is already out. A one-shot toggle like Dash.
		--
		-- USED TO BE SwapWeapon (cycle between two hardcoded loadout slots), which stopped meaning
		-- anything once weapons became an open roster you pick up: there are no slots to swap between,
		-- there is an inventory to draw FROM. Cycling which weapon is selected moved to ToggleWeapon's
		-- neighbour below rather than staying on this key, because "put my sword away" is the action a
		-- player reaches for constantly and "switch to my other sword" is the one they reach for
		-- occasionally.
		ToggleWeapon = { KeyCode = Enum.KeyCode.T },
		-- Cycles which owned weapon T will draw, applying immediately if one is already out. Y sits
		-- next to T and is unbound elsewhere in this table -- the two weapon actions stay adjacent.
		SelectNextWeapon = { KeyCode = Enum.KeyCode.Y },
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
		-- Kit Editor toggle (Race Traits + Bloodline Abilities plan) -- unbound elsewhere in this
		-- table, sits directly next to OpenMoveEditor's Minus key in the same "secondary system
		-- action" row of the keyboard (DevMenuToggle = Equals, OpenMoveEditor = Minus, this =
		-- LeftBracket). Admin-only, same authorization contract as OpenMoveEditor above.
		OpenKitEditor = { KeyCode = Enum.KeyCode.LeftBracket },
		-- Opens the Live Admin Console (Client/DevTools/LiveConsole/LiveConsoleClient.lua,
		-- Client/UI/Screens/DevTools/LiveConsole/init.lua) for an authorized admin -- a bespoke live log
		-- stream, not Roblox's own native Developer Console. It used to open the native one via
		-- StarterGui:SetCore("DevConsoleVisible") until it was replaced: that panel only ever showed
		-- anything in Studio, since Shared/Logger.lua never calls print()/warn() outside
		-- RunService:IsStudio() by design, so on a live server the one key meant to surface logs
		-- opened an empty panel. The Live Admin Console reads Logger.lua's always-on capture buffer
		-- instead, which works regardless of IsStudio -- see that module's own header.
		--
		-- F5 rather than the engine's own F9: F9 is bound by Roblox itself only for accounts with
		-- edit access to the place and does nothing for anyone else, so reusing it would leave a key
		-- that works for some admins and silently not for others.
		--
		-- And NOT F6, which is where this first went: F6 is already the parkour debug overlay's raw
		-- toggle (ParkourConstants.Debug.ToggleKeyCode). That binding is not in this table -- it is
		-- deliberately raw so it never shows up in the player-facing rebind list -- so nothing here
		-- flagged the collision, and the two handlers simply both fired on the same press. If another
		-- "developer tooling" key is ever added, check ParkourConstants.Debug as well as this table.
		--
		-- This was F7 until it was moved here by request. One caveat that comes with F5 and did not
		-- come with F7: in Studio, F5 is Studio's own Play/Resume shortcut, so a press that lands on
		-- the Studio window rather than the running game view will drive Studio instead of this panel.
		-- In a live client F5 is unclaimed by the engine, so shipped behaviour is unaffected.
		OpenDevConsole = { KeyCode = Enum.KeyCode.F5 },
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
		-- Board/leave a blimp station (Client/Blimp/BlimpController.lua, and the KeyboardKeyCode that
		-- module writes onto each server-created ProximityPrompt so a rebind carries to the prompt too).
		--
		-- DELIBERATELY SHARES E WITH Leap ABOVE, which is the only doubled key in this table and so needs
		-- saying out loud -- the F5/F6 collision OpenDevConsole's own comment records is what happens when
		-- a doubled key is NOT written down. It is safe in both directions and neither is an accident:
		--   * Pressing E to BOARD also buffers a leap, but Leaping's own CanEnter refuses a standing
		--     character, and the mount sets RootControlLocked a frame later, which parks parkour outright.
		--   * Pressing E to LEAVE cannot buffer a leap at all -- ParkourInput skips the Leap branch while
		--     Constants.Attributes.Mounted is set, which is the one case that would otherwise have fired
		--     (a buffered press surviving the release and launching the player off the deck).
		-- E is the conventional interact key this genre trains players to reach for, which is the same
		-- argument Leap's own comment makes; if the overlap ever stops being acceptable, MOVE Leap -- a
		-- prompt is the more discoverable of the two and the one a new player meets first.
		Interact = { KeyCode = Enum.KeyCode.E },
		-- Grab layer's follow-up throw input (Client/Combat/GrabInputClient.lua). G is unbound
		-- elsewhere in this table and sits under the same hand already on WASD -- a throw has to be
		-- reachable the instant a hold lands, the same "no leaving the movement keys" requirement
		-- Roll/Leap's own comments give.
		GrabThrow = { KeyCode = Enum.KeyCode.G },
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
		-- B (Circle on a DualSense) is the near-universal roll/dash button in this genre. Same
		-- consumer as the keyboard entry above -- KeybindManager.Matches checks both device maps in
		-- one call, so States/Dashing.lua needs no per-device branching.
		Dash = { KeyCode = Enum.KeyCode.ButtonB },
		-- R3 (click right stick) is the standard lock-on button (Souls, Zelda). This line used to say
		-- exactly that and then bind ButtonL2 -- a doc/code mismatch recorded, but not fixed, by
		-- Feint's own comment below. It is fixed now, and the fix was forced rather than tidy: L2 had
		-- to come free to become GamepadModifier below, and the button this comment always claimed
		-- LockOn should be on is the one Feint was sitting on.
		LockOn = { KeyCode = Enum.KeyCode.ButtonR3 },
		-- L3 (click left stick) is a common third-person sprint convention.
		Sprint = { KeyCode = Enum.KeyCode.ButtonL3 },
		-- X (Square) -- a free face button, pressed while already holding L3 for Sprint.
		Slide = { KeyCode = Enum.KeyCode.ButtonX },
		-- DPadLeft. A face button would be nicer, but ShiftLock is the one action here that can afford
		-- NOT to have one: it is a MODE TOGGLE, pressed once and then lived in for minutes, so the cost
		-- of taking a thumb off the left stick to reach it is paid at a moment the player chose. It sat
		-- on ButtonY until Roll took that button below -- read Roll's comment for why that trade is not
		-- symmetric.
		ShiftLock = { KeyCode = Enum.KeyCode.DPadLeft },
		-- D-pad item/weapon-swap is a standard convention in this genre.
		ToggleWeapon = { KeyCode = Enum.KeyCode.DPadRight },
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
		-- Y (Triangle). THE ROLL GOT ITS FACE BUTTON, and this is the one binding in this table that
		-- was a genuine BUG rather than a compromise.
		--
		-- It sat on DPadLeft, under a comment that said "not ideal -- a roll deserves a face button"
		-- and treated that as taste. It was not taste. States/Rolling.lua's whole reason to exist is
		-- the LANDING ROLL: a roll pressed within ParkourConstants.Roll.LandingWindowSeconds (0.2s) of
		-- ground contact converts a hard landing into a full-speed continuation. That is a reflex input
		-- on a two-tenths-of-a-second window, and it is pressed while the player is IN THE AIR STEERING
		-- -- which on a gamepad means the left thumb is on Thumbstick1 and cannot also be on the D-pad.
		-- The binding did not make the landing roll hard on a controller, it made it unreachable, and
		-- with it the timing skill the parkour system is built around.
		--
		-- WHAT PAID FOR IT was ShiftLock, which moved to DPadLeft above. That trade is not symmetric
		-- and that is the point: a mode toggle can afford a thumb-off-stick reach because the player
		-- picks the moment, and a 0.2s landing window cannot afford one at all. Dash (ButtonB) stays
		-- put -- doubling roll onto it would make two distinct mechanics indistinguishable, which is
		-- what the old comment here was right to refuse.
		Roll = { KeyCode = Enum.KeyCode.ButtonY },
		-- Leap, Interact, GrabThrow and HotbarSlot1-5 have no entry in THIS table and are not
		-- unbound: they live one table down, in GamepadChords, reached by holding GamepadModifier.
		-- This comment used to say there was "genuinely nowhere left to put" Leap without doubling up
		-- two distinct mechanics on one button, and that was true of the single-press map and only of
		-- the single-press map -- every face/shoulder/stick-click/D-pad value in this genre's own
		-- convention family really is claimed above. A held modifier is the way out of that wall
		-- rather than an admission of defeat: see GamepadChords' own header below.
		--
		-- DevMenuToggle deliberately has NO gamepad default -- admin-only, keyboard already covers
		-- it, and exposing a stray always-live single-button dev-menu toggle to every controller
		-- user isn't something to do by default. KeybindManager.Matches simply never matches for an
		-- action with no bound gamepad input. Value type is Keybind? (unlike Defaults' Keybind
		-- above), honestly reflecting that this map is deliberately partial -- every consumer that
		-- reads it must nil-check. HotbarSlot1-5 are absent from THIS map for the reason Leap is
		-- (they are on the chord layer below), not for the admin-only reason this comment used to
		-- give.
	} :: { [Types.KeybindAction]: Types.Keybind? },

	-- The held button that switches the gamepad onto GamepadChords below. ButtonL2 -- free only
	-- because LockOn moved to the ButtonR3 its own comment always claimed, which freed ButtonR3 for
	-- Feint, which is now on the chord layer anyway.
	--
	-- WHY L2 AND NOT A FACE BUTTON. A modifier has to be holdable without giving up any of the four
	-- buttons a thumb needs DURING the hold, which rules out every face button and both stick
	-- clicks. That leaves the four shoulders: R1/R2 are light/heavy attack and L1 is guard, all
	-- three of which must stay single-press in combat. L2 is the only one left, and it is the one a
	-- player's index finger is already resting on.
	--
	-- REBINDABLE, like everything else here -- Types.GamepadSettings.ChordModifier is the persisted
	-- override, and Client/Input/Chord.lua reads through that rather than off this constant directly.
	GamepadModifier = { KeyCode = Enum.KeyCode.ButtonL2 } :: Types.Keybind,

	-- The ALTERNATE gamepad layer: what each button means while GamepadModifier is held. A third
	-- map rather than a wider Keybind, for the same reason GamepadDefaults is a second one -- an
	-- action can be live on keyboard, on a plain gamepad button, and on a gamepad chord at once, and
	-- collapsing them would force every consumer to branch on device and on modifier state.
	--
	-- THIS EXISTS BECAUSE THE BUTTON BUDGET IS GENUINELY FULL, not because chords are nice. Read
	-- GamepadDefaults above: Roll's comment and Leap's comment independently hit the same wall --
	-- every face, shoulder, stick-click and D-pad direction in this genre's convention family is
	-- already spoken for -- and Leap, Interact and GrabThrow are live gameplay actions, not admin
	-- tooling. The choice was doubling two distinct mechanics onto one button (which makes them
	-- indistinguishable) or adding a layer. A layer also means the NEXT action to need a binding
	-- gets one without re-litigating any of this.
	--
	-- EACH PAIRING IS THE MODIFIED FORM OF WHAT THE PLAIN BUTTON ALREADY MEANS, so the layer is
	-- learnable rather than arbitrary -- and Client/Input/Glyph.lua swaps every on-screen legend to
	-- this map while the modifier is held, so it is discoverable rather than secret.
	--
	-- FLAGGED FOR A REAL CONTROLLER PLAYTEST, the same standing OpenBugReport's ButtonSelect note and
	-- Roll's DPadLeft note already take in the map above. These are reasoned, not measured.
	GamepadChords = {
		-- R1 is BasicAttack; a feint is the cancel of exactly that, so it reads as a modified attack.
		Feint = { KeyCode = Enum.KeyCode.ButtonR1 },
		-- B is Dash; a leap is the committed version of the same "get clear of here" idea.
		Leap = { KeyCode = Enum.KeyCode.ButtonB },
		-- X is Slide; both are "engage with the ground/world in front of you".
		Interact = { KeyCode = Enum.KeyCode.ButtonX },
		-- Y. Its plain binding is Roll, which is a TAP with a 0.2s window; this is a modified tap, so
		-- the two never compete for a press (the same hold-versus-tap argument HotbarSlot5 makes about
		-- sharing L1 with Block). This comment used to justify the button by saying Y was ShiftLock,
		-- "the least combat-critical face button" -- that is stale, ShiftLock moved to DPadLeft when
		-- Roll took this button, and the reasoning is now the modifier rather than what it displaces.
		GrabThrow = { KeyCode = Enum.KeyCode.ButtonY },
		-- The D-pad is already this game's quick-select semantic (ToggleWeapon/EmoteWheel/Settings
		-- all live there unmodified), so the modified D-pad is the natural home for the slot picker.
		HotbarSlot1 = { KeyCode = Enum.KeyCode.DPadUp },
		HotbarSlot2 = { KeyCode = Enum.KeyCode.DPadRight },
		HotbarSlot3 = { KeyCode = Enum.KeyCode.DPadDown },
		HotbarSlot4 = { KeyCode = Enum.KeyCode.DPadLeft },
		-- The fifth slot has no fifth D-pad direction to take, so it goes to the one shoulder that is
		-- neither the modifier nor an attack: L1. Guard is a HOLD and this is a modified TAP, so the
		-- two never compete for the same press.
		HotbarSlot5 = { KeyCode = Enum.KeyCode.ButtonL1 },
	} :: { [Types.KeybindAction]: Types.Keybind? },

	-- NO DoubleTapDashWindowSeconds HERE ANY MORE, and it should not come back. It configured a
	-- double-tap-W alternate trigger for the dash, read only by CombatClient.lua's InputBegan, and it
	-- outlived that file by the whole combat rewrite with no consumer at all. The dash is on a
	-- dedicated, rebindable key now (Defaults.Dash above), which is the same conclusion
	-- States/Leaping.lua reached when the leap stopped being a double-tap of jump: a gesture built out
	-- of another action's key can never be independently rebound, and it silently steals presses from
	-- the key it is layered on.
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
		-- Camera-comfort preferences (Types.ComfortSettings) -- same field-name-plus-value shape as
		-- UpdateParkour above, and chosen for the same reason: this is a group expected to gain
		-- entries as more accessibility options are added, and a remote per toggle would mean a
		-- NetworkBridge registration, a handler and a client call site for each one. The field name is
		-- therefore untrusted input, validated against a closed set server-side exactly as
		-- PARKOUR_SETTING_TYPES already does.
		UpdateComfort = "Settings_UpdateComfort",
		-- Gamepad device preferences (Types.GamepadSettings) -- same field-name-plus-value shape as
		-- UpdateParkour/UpdateComfort above, and chosen for the same reason. Unlike those two, this
		-- group's values are not all booleans (three of the five are numbers), so the closed set
		-- server-side carries a value TYPE per field and the numeric ones are clamped to Gamepad.Bounds
		-- below rather than merely type-checked -- a client is free to send 400 for a sensitivity, and
		-- the answer is to clamp it, not to trust it or to drop the write.
		UpdateGamepad = "Settings_UpdateGamepad",
	},

	-- The shipped gamepad stick defaults, and the range each numeric one may be set to. Lives HERE, in
	-- shared Constants, rather than in Client/Input/Analog.lua where it is consumed, because the
	-- SERVER has to validate writes against the same numbers and cannot require a client module --
	-- Analog.lua reads its own DEFAULT_CONFIG out of this table so there is exactly one source of
	-- truth, the same rule Types.ParkourSettings follows against ParkourConstants.
	Gamepad = {
		Defaults = {
			LookSensitivity = 1,
			-- Roughly the point at which a healthy stick's resting noise stops registering, without
			-- eating enough of the range to make small corrections impossible.
			MoveDeadzone = 0.2,
			LookDeadzone = 0.2,
			InvertLookY = false,
			Vibration = true,
		},
		-- Inclusive. The deadzone ceiling is deliberately well below 1: a deadzone at or near 1 is not
		-- a preference, it is a stick that no longer works, and Analog.ApplyStick would return zero
		-- for every input. The sensitivity floor is likewise above 0 for the same reason -- a
		-- sensitivity of 0 is indistinguishable from a broken controller, and a player who set it by
		-- accident would have no way to reach the menu to undo it on a pad.
		Bounds = {
			LookSensitivity = { Min = 0.25, Max = 4 },
			Deadzone = { Min = 0, Max = 0.6 },
		},
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
		MeridianFlow = "QIF",
		Might = "MGT",
		Pressure = "PRS",
		Fleetness = "FLT",
	} :: { [string]: string },

	-- What each attribute is CALLED on screen, as opposed to what its field is named in code. Keyed
	-- the same way as AttributeFields/AttributeAbbreviations above, and every surface that shows an
	-- attribute to a player reads this rather than rendering the raw key.
	--
	-- It exists for exactly one entry. `MeridianFlow` is the field name in Types.AttributeBlock, in
	-- every saved profile, in KitValidation's allow-list, in Types.ActiveModifierAttributeKey, and in
	-- ~15 bloodline stage effects in DefaultBloodlineRegistry -- so renaming the KEY is a data
	-- migration across a persisted schema, not a copy change. What the player actually needed was the
	-- LABEL: "MeridianFlow" is jargon that reads as a system name, where the thing it governs is
	-- plainly your qi (user, 2026-08-20). So the key stays and the label is "Qi Flow", with the
	-- abbreviation moving MER -> QIF to match.
	--
	-- The other five map to themselves. They are listed anyway rather than left to fall through to
	-- the key, so that a sixth rename is a one-line edit here instead of a discovery that only one
	-- attribute in the table ever had a display name.
	AttributeDisplayNames = {
		Vitality = "Vitality",
		Fortitude = "Fortitude",
		MeridianFlow = "Qi Flow",
		Might = "Might",
		Pressure = "Pressure",
		Fleetness = "Fleetness",
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
		Hollowborn = "A deep lean toward Qi Flow, paid for out of Vitality.",
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

-- Move Creation System (Server/Combat/MoveRegistryManager.lua, Server/Systems/MoveEditorSystem.lua,
-- Client/UI/Screens/DevTools/MoveEditor/) -- an in-game, admin-gated editor for authoring new combat moves
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
		-- Puts the open move in one of the player's own hotbar slots, for live-fire testing.
		--
		-- It is an ART EQUIP, not a second kind of binding: an art IS a move carrying a
		-- MoveTypes.MoveArtBinding (see ArtTreeManager.lua's header -- an art's ArtId is its MoveId),
		-- so a slot has exactly one occupant and one owner, ArtSystem, whose equippedArts already
		-- persists. This remote exists only because ArtSystem.Equip refuses an art the player has not
		-- UNLOCKED, and an admin testing a form they authored ten seconds ago has not earned it --
		-- see ArtSystem.DevGrantAndEquip, which is the only unlock bypass in the codebase.
		EquipArtSlot = "MoveEditor_EquipArtSlot",
	},
}

-- Race Traits + Bloodline Abilities plan -- KitAbilitySystem's own shared trigger/resolution path
-- (Server/Systems/KitAbilitySystem.lua, not built yet). ONE remote pair for both content layers'
-- Active abilities, not two -- the same anti-duplication reasoning Shared/Kit/KitTypes.lua's own
-- header gives for sharing KitAbilityDefinition itself.
Constants.Kit = {
	RemoteNames = {
		-- RemoteFunction, not a RemoteEvent -- "the panel has to say why" a use was refused, the same
		-- request/response contract ArtSystem.UnlockArt/EquipArt already use. A utility press is
		-- low-frequency (unlike a combat swing), so there's no client-side prediction/input buffer to
		-- keep in sync the way Combat_RequestBasicAttack's fire-and-forget shape needs.
		RequestAbility = "Kit_RequestAbility",
		-- Server -> owning client only, fired on a successful UseAbility -- the post-success FX echo.
		-- Payload: Types.KitAbilityUsedPayload.
		AbilityUsed = "Kit_AbilityUsed",
	},
	-- Same per-player budget ArtConstants.RequestMaxCallsPerSecond already uses for its own
	-- low-frequency gated-action remotes (unlock/equip) -- a genuine player mashing this button still
	-- can't press faster than a few times a second, so anything beyond this is a modified client.
	RequestMaxCallsPerSecond = 4,

	-- Per-field authoring bounds for KitAbilityDefinition/ActiveModifierSpec (Shared/Kit/KitTypes.lua,
	-- Types.lua) -- ONE table read by both RaceManager.Validate/BloodlineManager.Validate and, once it
	-- exists, KitEditorSystem's own client field bounds, the same "one place the editor's own bounds
	-- and the server's own clamp agree on a range" reasoning Constants.MoveEditor.ObjectStun.Limits'
	-- own header already establishes for that feature. First-pass ranges, wide enough to cover any
	-- real authored ability -- not a balance opinion, same as MoveRegistryManager's own clamp
	-- constants, just a floor against a value that would read as broken.
	Limits = {
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
	},
}

-- Race Traits + Bloodline Abilities plan -- the shared admin editor for both Race Traits and
-- Bloodline stages (Server/Systems/KitEditorSystem.lua, Client/UI/Screens/DevTools/KitEditor/, not built yet).
-- Mirrors Constants.MoveEditor above field-for-field: same DataStore retry/backoff shape (Shared/
-- DataStoreRetry.lua), same debounce reasoning between a PropertyEditor field edit and the
-- UpdateDraft round trip it triggers.
Constants.KitEditor = {
	SchemaVersion = 1,
	DraftDebounceSeconds = 0.15,

	-- Admin-only, same trust model as Constants.MoveEditor above -- every RemoteFunction below is
	-- gated by KitEditorSystem's own checkKitEditorPreconditions (AdminGate.Check + a dedicated
	-- rate-limit bucket). One roster of five actions PER content type (Race Traits, Bloodlines) --
	-- List/Get/UpdateDraft/Save/Delete -- rather than two separately-named sets, since the two share
	-- one screen and the naming already disambiguates which content type each acts on.
	RemoteNames = {
		ListRaceTraits = "KitEditor_ListRaceTraits",
		GetRaceTrait = "KitEditor_GetRaceTrait",
		-- In-memory only, no DataStore write -- takes effect immediately in RaceManager's live
		-- registry, the same "Save is explicit only" contract Constants.MoveEditor.RemoteNames.
		-- UpdateDraft already establishes for moves.
		UpdateRaceTraitDraft = "KitEditor_UpdateRaceTraitDraft",
		SaveRaceTrait = "KitEditor_SaveRaceTrait",
		DeleteRaceTrait = "KitEditor_DeleteRaceTrait",

		ListBloodlines = "KitEditor_ListBloodlines",
		GetBloodline = "KitEditor_GetBloodline",
		UpdateBloodlineDraft = "KitEditor_UpdateBloodlineDraft",
		SaveBloodline = "KitEditor_SaveBloodline",
		DeleteBloodline = "KitEditor_DeleteBloodline",
	},
}

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

	-- Hit-stop (freeze-frame) durations, in seconds.
	--
	-- VictimSeconds and PostureBreakSeconds are LIVE again as of Client/FX/HitStop.
	-- FreezeVictimMovement -- a brief freeze of the DEFENDER's own AssemblyLinearVelocity (via
	-- ParkourMotor.ApplyImpulse), not an animation-track freeze. See HitStop.lua's own header for why
	-- the mechanism changed: the original design (below) predates this codebase's combat rewrite and
	-- pauses the involved players' combat animation TRACKS, but no swing plays a body animation today
	-- (every Default move's AnimationId is ""), so an animation freeze would visibly do nothing for
	-- most hits. CombatFeedbackClient.lua wires it off Combat_Feedback for the DEFENDER role only, on
	-- the same Clean/Backstab/GuardBroken outcomes DamageConstants.Hitstun already grants a real
	-- lockout for -- Clean takes VictimSeconds, Backstab/GuardBroken take the heavier
	-- PostureBreakSeconds, the same asymmetry CombatFeedbackClient's own ShakePresets.Defender table
	-- already draws between those three kinds.
	--
	-- AttackerSeconds, HeavyBonusSeconds and ParrySeconds remain ORPHANED -- read by zero files, exactly
	-- as they were before VictimSeconds/PostureBreakSeconds were reconnected. No attacker-side freeze
	-- or parry-side freeze was part of that reconnection; wiring those is a separate call for whoever
	-- wants an attacker's own hit-stop next, not something to infer from these numbers merely existing.
	-- Kept rather than deleted because they are pre-tuned and cheap to keep, the same reasoning that
	-- left DamageConstants.AttackerLunge in place for the bodies it can still reach.
	--
	-- MinIntervalSeconds throttles back-to-back freezes (per HitStop.lua's own makeThrottledFreeze) so
	-- a multi-target swing, or a fast combo string, can't chain consecutive freezes into slow motion.
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
			-- No DashFadeSeconds/SlideFadeSeconds here any more. Both were read by exactly one thing --
			-- CombatAnimator.PlayPredictedDash/PlayPredictedSlide, deleted with the rest of the combat
			-- system -- and neither had a consumer anywhere in the codebase afterwards. The dash's
			-- blend now lives where the dash does: ParkourConstants.Animation.BlendProfiles.Snap,
			-- selected per clip by ParkourAnimator rather than by a second global fade table.
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

		-- ONE STEP SOUND, PITCHED UP PER STAGE. Only stage 1 carries a Sound -- every other stage reuses
		-- that same registered instance and just plays it faster (PlaybackSpeedMultiplier), rather than
		-- registering a second/third asset that was, until this simplification, an identical sample at a
		-- louder volume anyway (see the removed stage-2/3 notes this replaced). A faster gear sounding
		-- like the same stride playing quicker is closer to how a real footfall actually changes than a
		-- separate louder recording ever was. Point Stage 1's Sound at whatever asset you want -- this is
		-- the one place step audio is configured, and Client/FX/RunAudio.SetStepSound can additionally
		-- swap it at runtime without a restart. An empty SoundId is the codebase's standard "not authored
		-- yet" placeholder: SoundManager.Play already no-ops on it, so shipping with one costs a debug
		-- log and nothing else.
		--
		-- PoolSize 3 because a footstep genuinely can re-trigger before the previous one finishes at
		-- stage-2 cadence -- the same overlap reasoning Constants.Combat.Sound's hit/block/parry trio
		-- documents. PitchJitter randomizes each play's PlaybackSpeed by +/- that fraction ON TOP OF
		-- PlaybackSpeedMultiplier, which is the cheapest possible fix for the "identical sample on a
		-- metronome" effect a fixed-interval step system otherwise has.
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
				-- Sliced out of the combined asset: the first second is a speed whoosh this system no
				-- longer plays (StageOnset below is a pure camera cue now, not audio) and the second
				-- after it is a RUN of several steps. The region here is ONE step's worth out of that
				-- run, not the whole second -- a slice containing four footfalls, retriggered every
				-- 0.33s, would layer four-step bursts on top of each other rather than producing a
				-- stride.
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
				-- No Sound of its own -- stage 1's is reused and pitched up by this factor instead (see
				-- Footsteps' own header above). First-pass number: nudge by ear, the same discipline
				-- stage 1's PlaybackRegion slice used before it was tuned in.
				PlaybackSpeedMultiplier = 1.15,
			},
		},
	},

	-- THE ONSET KICK -- a pure camera cue now, keyed by the stage being ENTERED: the extra FOV pull
	-- that sells a gear change at the instant it engages. Used to also carry a one-shot whoosh Sound;
	-- removed in favor of Footsteps.Stages' own PlaybackSpeedMultiplier selling the speed change through
	-- the footsteps themselves instead of a second cue competing with them. FOVDelta/FOVEaseSpeed are
	-- unchanged by that removal -- RunController reads them exactly as before.
	--
	-- Stage 1 has no entry and deliberately so: engaging the run at all is not a gear CHANGE, it is the
	-- run starting, and it already has the run animation and the footstep cadence to announce it. A
	-- pull there would fire every time a player tapped the key.
	--
	-- FOVDelta is the additional pull layered on top of Constants.Camera.Sprint.FOVDelta while that
	-- stage is held (Client/FX/FOVOffset.lua's named-slot composition, so it stacks with the sprint
	-- slot rather than fighting it). Negative = narrower, matching Sprint's own convention. These are
	-- ABSOLUTE per stage, not cumulative -- RunController writes one slot and simply changes its target
	-- as the stage changes, so a ladder carrying several entries here never accumulates their pulls.
	StageOnset = {
		-- The ladder's only gear change, so this is the whole camera language of "you are at full stride":
		-- a player who cannot tell which gear they are in has a ladder with no feedback, which is the same
		-- as no ladder. Sized while a third gear still sat above it and took the unmistakable pull for
		-- itself -- worth a second pass by eye now that this IS the top.
		[2] = {
			FOVDelta = -5,
			FOVEaseSpeed = 4,
		},
	},

	-- ANIMATION. Stage 1 keeps Constants.Combat.AnimationIds.Running (the clip that has always played
	-- while sprinting); stage 2 plays RunningStage2 when authored, and falls through to Running when its
	-- own id is blank -- the same blank-id fallthrough ParkourAnimator uses for its half-authored
	-- directional wall-jump pair, so this ships correctly at every stage of authoring.
	Animation = {
		-- Playback speed for the run loop, keyed by stage. Applied on stage CHANGE only, never per
		-- frame: CombatAnimator.FreezeActiveCombatTrack (hit-stop) drives the same property, and a
		-- per-frame write here would silently cancel every freeze that landed on a running player.
		--
		-- Also the fallback that makes an unauthored stage still feel distinct: while a stage's own clip is
		-- blank it plays the stage below's at this rate instead -- see AnimationIds.RunningStage2's own
		-- header. Retune toward 1 once a real clip lands there, or it will read as sped-up/cartoonish
		-- rather than a distinct gear.
		PlaybackSpeeds = {
			[1] = 1,
			-- Slightly hot even when a dedicated stage-2 clip exists -- a full-stride run reads as
			-- urgent, and this is what makes stage 2 visibly different on day one.
			[2] = 1.25,
		},
		-- Crossfade between the two run clips at a stage change. Longer than a combat interrupt cut
		-- (the two clips are the same character doing the same thing harder, so the transition should
		-- read as accelerating, not as swapping costumes) and shorter than a settle.
		StageCrossfadeSeconds = 0.2,
	},
}

-- Hand-authored combat content and physics-feel numbers (weapon move catalog, DashPunch/DashHit/
-- AirSlam, AirCombo, Finisher/Ragdoll physics, AnimationIds, Sound) moved to
-- Shared/Combat/CombatConstants.lua -- see that file's own header for why. Server/Combat/
-- DefaultMoveRegistry.lua mutates that table live, at runtime, from the Move Editor's admin
-- remotes, which is exactly the kind of thing a module named "Constants" should never be surprised
-- to be doing (docs/architecture/2026-08-audit.md section 5, finding 3.4).

return Constants
