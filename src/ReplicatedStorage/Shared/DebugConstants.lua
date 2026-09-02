--!strict
--[[
	DebugConstants.lua

	Owns: the Studio-only diagnostics surface -- Logger's per-scope levels, the Dev Menu's action
	catalogue and preset whitelists, the raw debug KeyCodes, VersionWatch and TrainingDummy.

	Lifted out of Constants.lua, where at 561 lines it was a fifth of the file. Constants.Debug
	re-exports this module, so every existing Constants.Debug.X call site keeps working unchanged;
	new code should require this module directly.

	IT STAYS IN Shared/ AND MUST NOT FOLLOW THE DEV TOOLS OUT. That looks wrong at first glance --
	this is admin/diagnostics config, and live.project.json already omits Client/DevTools/ and
	Client/UI/Screens/DevTools/ -- so it is worth stating why, once, here. Of the 43 files that read
	this table, 38 are OUTSIDE both omitted subtrees: Shared/Logger.lua, seven domain *Constants.lua
	files, the whole combat stack (HitboxEngine, DefenseSystem, DamageSystem, AttackRequestSystem,
	GrabSystem, EngagementSystem), four parkour modules, BootManifest.lua and AdminConfig.lua. Moving
	this under a dev-tooling path would break the live build at require time for all of them.

	The production-safety contract is unchanged and is Logger.lua's, not this file's: a log only ever
	prints when RunService:IsStudio() AND Enabled are both true, so shipping with Enabled = true is
	safe -- outside Studio this table does nothing regardless of its contents.

	Does not own: any per-domain Debug flag. HitboxEngineConstants.Debug, DefenseConstants.Debug,
	AttackConstants.Debug and ParkourConstants.Debug each gate their own high-frequency logging and
	stay with their own domain -- this file's entries point at them, never the other way round.
]]

-- Studio-only diagnostics config for Logger.lua -- NOT gameplay logic, NOT a balance/tunable
-- table like Constants.Combat below, and read by nothing except that one module. See Logger.lua's
-- header for the exact production-safety contract: a log only ever prints when
-- RunService:IsStudio() AND Enabled are both true, so shipping this with Enabled = true is safe --
-- it does nothing outside Studio regardless of this table's contents.
local DebugConstants = {
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
DebugConstants.VersionWatch = {
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
DebugConstants.TrainingDummy = {
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

return DebugConstants
