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
export type SoundDefinition = { SoundId: string, Volume: number, PoolSize: number? }
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
		},
		-- Per (scope, level, message) cap, keyed off the static message text so a log site that
		-- fires every frame can't flood Output even at Trace -- see Logger.lua's rate limiter.
		MaxRepeatsPerSecond = 20,
	},

	-- Whitelist-gated developer tooling -- unlike Logging above, this is NOT Studio-only; it's
	-- meant to work in live servers too, since that's often exactly when a developer needs it.
	-- Safety comes entirely from the whitelist below plus DevMenuSystem.lua re-checking every
	-- request's Player.UserId server-side -- never from being hidden or from Studio-gating. See
	-- DevMenuSystem.lua's header for the full authorization contract.
	DevMenu = {
		-- Roblox UserIds allowed to open the dev menu and use its actions. Empty by default (fails
		-- closed -- nobody is authorized until this is explicitly populated). Add your own UserId
		-- (and any testers') here, e.g. [123456789] = true. Never guess or invent a UserId.
		AuthorizedUserIds = {
			[3888090557] = true,
		} :: { [number]: boolean },

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

		-- Ban Player admin action (Players tab roster row) -- UNLIKE ShutdownConfirmWindowSeconds
		-- above, this arm/confirm window is enforced ENTIRELY client-side (DevMenu/init.lua's
		-- playerRosterRow): a first press just shows "press again to confirm" and starts this local
		-- timer, a second press within the window is what actually fires BanPlayerRequested. Ban is
		-- permanent and DataStore-backed (survives rejoin) where Kick is cheap and reversible (a kicked
		-- player can just rejoin), so it earns the extra friction Kick doesn't need. No server-side
		-- state backs this window -- the server still authorizes/executes every Ban request on its own
		-- merits regardless of how the client arrived at sending it.
		BanConfirmWindowSeconds = 4,

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
			-- Live flight-feel tuner (Server/DevMenu/FlightTuning.lua) -- same fetch-once/adjust/reset
			-- shape as ListHitboxStages/AdjustHitboxTiming/ResetHitboxStage above, scoped to
			-- Constants.Flight's own tunables instead of hitbox timing.
			ListFlightTuning = "DevMenu_ListFlightTuning",
			AdjustFlightTuning = "DevMenu_AdjustFlightTuning",
			ResetFlightTuning = "DevMenu_ResetFlightTuning",
			-- Live hitbox-timing tuner (Server/Combat/HitboxTuning.lua) -- ListHitboxStages fetches
			-- every tunable Basic/Heavy/Finisher stage across both weapons once; AdjustHitboxTiming
			-- nudges one stage's Windup/Active/RecoverySeconds by a signed delta; ResetHitboxStage
			-- restores that stage's captured file-default values. See HitboxTuning.lua's own header.
			ListHitboxStages = "DevMenu_ListHitboxStages",
			AdjustHitboxTiming = "DevMenu_AdjustHitboxTiming",
			ResetHitboxStage = "DevMenu_ResetHitboxStage",
			-- Same live-tuning idea as the three above, for DashPunch/DashHit specifically -- see
			-- HitboxTuning.lua's own "Standalone attacks" section header for why these need their
			-- own remotes rather than reusing ListHitboxStages/AdjustHitboxTiming/ResetHitboxStage
			-- (they aren't a weapon combo stage, and this tool ALSO exposes OffsetForwardStuds,
			-- which the weapon-stage tool deliberately doesn't).
			ListStandaloneAttacks = "DevMenu_ListStandaloneAttacks",
			AdjustStandaloneField = "DevMenu_AdjustStandaloneField",
			ResetStandaloneAttack = "DevMenu_ResetStandaloneAttack",
			-- Bug report triage (DevMenu/init.lua's "Reports" tab) -- handlers live in
			-- DevMenuSystem.lua but call straight into BugReportSystem.ListReports/UpdateStatus, the
			-- same "gate here, compute there" split as every other admin action above. The PUBLIC
			-- submit remote is a separate name, Constants.BugReport.RemoteNames.Submit, since
			-- BugReportSystem itself (not DevMenuSystem) creates/handles that one -- any player may
			-- call it, no whitelist check.
			ListBugReports = "DevMenu_ListBugReports",
			UpdateBugReportStatus = "DevMenu_UpdateBugReportStatus",
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
			-- Reversible manual cheater-flag toggle (see ModerationSystem.lua's FlagSuspectedCheater/
			-- UnflagSuspectedCheater) -- same explicit-UserId-from-a-roster-row targeting as
			-- KickPlayer/BanPlayer/MutePlayer above, never the lock-on target.
			SetSuspectedCheater = "DevMenu_SetSuspectedCheater",
			-- Sidebar header stats (persistent Sidebar, Screens/DevMenu/Sidebar.lua) -- one combined
			-- RemoteFunction rather than folding into ListPlayers/ListBugReports, since neither of
			-- those two remotes' existing callers need the other's count.
			GetSidebarStats = "DevMenu_GetSidebarStats",
		},
	},
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
	-- parries given ParryWindowSeconds vs typical windup+active timing).
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
		-- DevMenuToggle deliberately has NO gamepad default -- admin-only, keyboard already covers
		-- it, and exposing a stray always-live single-button dev-menu toggle to every controller
		-- user isn't something to do by default. KeybindManager.Matches simply never matches for an
		-- action with no bound gamepad input. Value type is Keybind? (unlike Defaults' Keybind
		-- above), honestly reflecting that this map is deliberately partial -- every consumer that
		-- reads it must nil-check.
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

-- Canonical player-progression persistence (Server/Systems/PlayerDataSystem.lua) -- the single
-- DataStore-backed owner every other System's player-state reads/writes eventually route through
-- (engineering-standards.md's "one serialized entry point per player's data"). Mirrors
-- Constants.BugReport's own shape/naming below (retry/backoff pair, versioned DataStore name) --
-- this table existing separately from Constants.BugReport, despite both being DataStore config,
-- is deliberate: BugReportSystem is a fire-and-forget public feature with its own unrelated
-- tuning (cooldowns, page size), where PlayerDataSystem is the load-bearing progression spine
-- every other gameplay System depends on, with its own distinct tuning surface (autosave
-- cadence, schema version, load-failure messaging) that has nothing to do with bug reports.
Constants.PlayerData = {
	-- Versioned DataStore name -- same convention Constants.BugReport.DataStoreName established as
	-- this codebase's first DataStoreService usage.
	DataStoreName = "PlayerProfiles_v5",

	-- Current on-disk schema version (Types.StoredPlayerProfile.SchemaVersion) -- PlayerDataSystem.
	-- MigrateRecord walks a stored record forward from whatever version it was saved at toward this
	-- number. Only version 1 has ever existed, so there are no registered migrations yet -- see
	-- PlayerDataSystem.lua's Migrations table for the (currently empty) skeleton that future schema
	-- changes register into.
	SchemaVersion = 1,

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

	-- Player-facing kick messages for the two distinct load-failure modes PlayerDataSystem.lua
	-- distinguishes (engineering-standards.md: DataStore failures are "expected-but-rare... not
	-- edge cases to ignore," and the safe fallback for either is "never fabricate a profile that
	-- could overwrite real save data on next write," not a generic message that hides which one
	-- happened).
	LoadFailureKickMessage = "Failed to load your character data. Please rejoin in a moment.",
	CorruptDataKickMessage = "Your save data could not be read. Please contact support if this persists.",
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

	-- DEPRECATED -- superseded by the three-layer RaceEpithets/RaceWorldLines/RaceCostLines below
	-- (docs/design/intro-redesign-handoff.md Phase C). Kept only until the Onboarding rebuild
	-- (Phase E) migrates RaceSelect.lua's last reference off it, the same "keep it compiling until
	-- the sweep lands" contract Tokens.lua's own deprecated aliases follow. Do not add a fifth race
	-- here -- extend the three tables below instead.
	RaceHooks = {
		Human = "No starting lean -- the choice is entirely yours.",
		Firmborn = "Starts leaning toward sustained defense (Posture).",
		Rivenkin = "Starts leaning toward harder, faster strikes (Might).",
		Hollowborn = "Starts leaning toward a deeper energy well, at the cost of a thinner body "
			.. "(Meridian Flow, less Vitality).",
	} :: { [string]: string },

	-- Three-layer replacement for RaceHooks above (docs/design/intro-redesign-figma-spec.md's Origin
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
	-- MeridianFlow's is explicit that Qi is inert today (no live QiSystem yet -- see
	-- QiDeviationSystem.lua/progression-systems.md) so the player isn't told a live mechanic exists
	-- when it doesn't. Fleetness is deliberately scoped to movement + Dash/Sprint/Slide cooldown trim
	-- ONLY -- combat-philosophy.md's attack-speed/combo-timing/parry-window feel stays
	-- attribute-invariant, so this copy never implies otherwise.
	AttributeEffects = {
		Vitality = "Max Health",
		Fortitude = "Max Posture + regen",
		MeridianFlow = "Max Qi + regen (not active yet)",
		Might = "Outgoing health damage",
		Pressure = "Outgoing posture damage",
		Fleetness = "Movement speed + Dash/Sprint/Slide cooldown trim",
	} :: { [string]: string },

	-- Display name rules (screen 3) -- the in-game character name, separate from the Roblox
	-- username, NOT globally unique (no reservation table -- CharacterCreationSystem.lua never checks
	-- another player's name). CharacterCreationSystem.ValidateDisplayName enforces length/charset;
	-- server-side TextService:FilterStringAsync/GetNonChatStringForBroadcastAsync (same call site
	-- pattern as BugReportSystem.Submit) runs after that, and Denylist is a final studio-authored
	-- blocklist checked in addition to the moderation filter. Empty by design at this pass -- real
	-- content to fill in before shipping, never fabricated here.
	DisplayName = {
		MinLength = 3,
		MaxLength = 20,
		Denylist = {} :: { string },
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
	},

	-- Named Workspace instances CharacterCreationSystem.lua resolves via WaitForChild --
	-- default.project.json has no Workspace tree (Rojo can't author Workspace geometry in this repo),
	-- so these are references to Studio/place-file content a human must place; see this feature's own
	-- delivery notes for exactly what each needs to be. ThresholdSpawn is an isolated "Waking
	-- Threshold" pocket space outside SafeZones/ContestedZones/VoidFractureZones/Territories (a
	-- first-time player is frozen there for the cinematic + creator); ArrivalSpawn is the real
	-- Median Paradise entry point chargen teleports (PivotTo) the player to once Finalize succeeds.
	ThresholdSpawnPath = { "Onboarding", "WakingThresholdSpawn" },
	ArrivalSpawnPath = { "Onboarding", "MedianParadiseArrivalSpawn" },

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

	DescriptionMinLength = 10,
	DescriptionMaxLength = 1000,

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

	-- Versioned DataStore names -- the first DataStoreService usage in this codebase, so a version
	-- suffix is established here as the convention for any future schema change.
	DataStoreName = "BugReports_v1",
	OrderedDataStoreName = "BugReportsByTime_v1",

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

	-- Versioned, separate from BugReport's own DataStore -- a ban record and a bug report share
	-- nothing schema-wise and have no reason to share a store.
	BanDataStoreName = "PlayerBans_v1",

	-- Suspected-cheater manual flagging -- its own store, separate from Ban's: a flag is reversible
	-- (RemoveAsync on Unflag) where a ban is permanent-by-default, and the two have no reason to
	-- share a schema or a key namespace.
	SuspectedCheaterDataStoreName = "SuspectedCheaters_v1",
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
			ParryFlashFadeSeconds = 0.03,
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

-- DashPunch's own Windup/Active/Recovery seconds, factored out to local variables so
-- DashFrontCommitmentSeconds (below, in the main Constants.Combat table) can be DERIVED from
-- these instead of hand-duplicating their sum -- a Lua table constructor can't reference its own
-- other keys, hence the locals rather than just pointing at Constants.Combat.DashPunch.*. Before
-- this, DashFrontCommitmentSeconds was a separately-typed literal (0.45) that had to be manually
-- kept equal to WindupSeconds+ActiveSeconds+RecoverySeconds every time any of the three changed --
-- exactly the kind of duplicated tunable engineering-standards.md's "one source of truth per
-- value" exists to prevent. Retuning DashPunch's timing now automatically keeps the front-dash
-- commitment lock in sync -- no separate number to remember to update.
-- Windup/Active dialed in via the dev menu's live Standalone Attacks tuner (Server/Combat/
-- HitboxTuning.lua) and copied back here as the new file defaults -- Windup=0.4 means the punch
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
-- process -- adjust freely after a playtest (CLAMP_MIN/MAX_OFFSET_STUDS in HitboxTuning.lua already
-- cover a much wider range than this for the dev-menu live tuner).
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

	-- Parry: a timed block, not a separate input -- every accepted BlockStart request opens this
	-- short server-tracked window (CombatSystem.lua's handleBlockStart), subject to the cooldown
	-- between attempts below, and a hit landing inside that window is punished with the posture
	-- damage dealt to the attacker instead of landing on the defender.
	ParryWindowSeconds = 0.35,
	ParryCooldownSeconds = 1.2,
	ParryPunishPostureDamage = 30,
	-- Ping compensation for the parry window (players only -- bots have no network latency). The
	-- server opens the parry window when a block request ARRIVES, which is already ~ping later than
	-- the client pressed, so a laggy player's real-time timing is silently punished by their
	-- connection. handleBlockStart adds min(player ping, this cap) to the window so a high-ping
	-- player gets back roughly the time their connection ate -- keeping "reads beat reflexes"
	-- (combat-philosophy.md) fair across connections without trusting any client-sent timing. Capped
	-- so an extreme/spoofed ping can't turn the window into a near-permanent parry.
	ParryPingCompensationMaxSeconds = 0.12,

	-- Disarm: combat-philosophy.md's "Established systems" list names Block/Parry/Disarm as one
	-- formal defensive layer (see ParryWindowSeconds' own comment for the Block/Parry merge).
	-- Deterministic (no RNG, matching every decision this table drives): Parrying a HEAVY attack
	-- disarms its attacker for DurationSeconds -- Basic pressure keeps its own value untouched
	-- (only Heavy throws risk this on top of the existing ParryPunishPostureDamage), and Heavy's
	-- bigger commitment/payoff is the "telegraphed cost" combat-philosophy.md's Balance Principle
	-- #3 requires before anything bypasses/punishes past the core defensive layer. A disarmed
	-- player can't throw a Basic or Heavy attack but can still Block/Parry/Dash/Sprint/
	-- LockOn -- see CombatState.disarmedUntil's own comment for why this stays within
	-- gameplay-philosophy.md's anti-lockout rule. First-pass technical tunable, free to move.
	Disarm = {
		DurationSeconds = 2.5,
	},

	-- How long a combo chain (consecutive attacks within this window of each other) stays alive
	-- before resetting to stage 1. Per-stage timing/damage/cooldown now live in Hitboxes.Basic/
	-- Heavy below, not here -- see that table's header for why. Reused as the reset window for the
	-- basic finisher combo below (CombatState.basicComboExpiry) as well as the Heavy throw-combo.
	ComboResetSeconds = 1.5,
	MaxComboStacks = 5,

	-- The basic (M1) finisher combo: land this many basic hits in a row (within ComboResetSeconds of
	-- each other) and the next M1 becomes the Finisher (Hitboxes.Finisher below) instead of a normal
	-- Basic swing. The combo is LANDING-based, not press-based (CombatSystem.lua's handleAttackRequest
	-- / startAttackSwing) -- only hits that connect advance it, so whiffing can't fast-track a
	-- launcher, and it matches the "3 hits that stun, then a finisher" design. Set to 4 = 3 normal
	-- basic hits (Hitboxes.Basic stages 1-3) + the finisher; the value is the finisher's stage index.
	BasicComboLength = 4,

	-- Input buffering (CombatState.bufferedAttack): a Basic/Heavy attack request rejected purely
	-- for landing before the previous swing's cooldown/commitment cleared is remembered and
	-- automatically replayed once that gate opens, as long as it's still within this many seconds
	-- of the original press -- short enough that it only smooths over "a few frames too early," not
	-- a genuinely delayed queued action from a player who's moved on.
	AttackInputBufferSeconds = 0.2,

	-- Feint (right-click, RequestFeint/CombatSystem.lua's handleFeintRequest): cancels the player's
	-- own Basic/Heavy/Finisher/AirSlam swing while it's still inside WindupSeconds, before the
	-- hitbox can ever go active -- a mind-game tool (combat-philosophy.md's "reads beat reflexes"),
	-- not a free escape hatch. Two things keep it from trivializing the swing it cancels: the swing's
	-- own Cooldown (already committed to basicAttackReadyAt/heavyAttackReadyAt/airSlamReadyAt at
	-- throw time) is NOT refunded, so baiting with the same attack slot repeatedly still costs the
	-- real cooldown every time; and RecoverySeconds below REPLACES the remaining windup+active+
	-- recovery commitment rather than clearing it outright, so a feint returns to neutral faster than
	-- finishing the swing would have, but not instantly. Deliberately scoped to Basic/Heavy/Finisher/
	-- AirSlam only, NOT Dash/DashPunch/DashHit/Slide -- see CombatSystem.lua's handleFeintRequest for
	-- why those four (movement-integrated commitment, not a stationary telegraph) are out of scope.
	-- First-pass technical value, free to tune per combat-philosophy.md's Tuning process.
	Feint = {
		RecoverySeconds = 0.15,
	},

	-- Client-side action-start prediction (Client/Combat/PredictionMirror.lua + CombatClient.lua):
	-- the acting client plays its own swing/dash feedback the frame the input is pressed (when its
	-- local mirror of server state says the action is legal) instead of waiting a full round-trip
	-- for the AttackStarted/MovementPerformed echo. The echo CONFIRMS the prediction; a
	-- Combat_ActionRejected event (or this timeout lapsing with neither echo nor reject seen)
	-- ROLLS IT BACK with a fast fade. TimeoutSeconds must comfortably exceed a bad round-trip so a
	-- merely-slow confirm doesn't read as a reject; RollbackFadeSeconds is the fade-out applied to
	-- a rolled-back animation track so a mispredicted swing melts instead of snapping to idle.
	-- Server-validated HIT feedback (damage numbers, hit SFX/VFX) is NEVER predicted -- see
	-- animation-systems.md; this covers only the actor's own action-start presentation.
	Prediction = {
		TimeoutSeconds = 0.35,
		RollbackFadeSeconds = 0.08,
	},

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
		},
		Normal = {
			-- Grounded, not holding space: no launch/ragdoll, just a heavier finishing blow -- extra
			-- hitstun on top of the swing's own damage/posture so the 4th hit still feels conclusive.
			ExtraStunSeconds = 0.6,
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

	-- Neutral-game movement tunables (CombatSystem.lua's handleDashRequest for Dash, and
	-- handleSprintStart/Stop for Sprint).
	--
	-- Dash is a single proactive key (no i-frames, a low-stakes spacing tool meant to be used often
	-- in the neutral game): a quick WalkSpeed burst, limited by its own cooldown + commitment lock,
	-- not any resource (Stamina is gone). Sprint is the separate sustained-speed hold, limited by
	-- combat state instead (you can't sprint while blocking, committed to a swing, stunned, or
	-- posture-broken).
	--
	-- Speed ordering by design: effective base < Sprint < Dash, where "effective base" is
	-- BaseWalkSpeed + BonusWalkSpeed (18 by default today: 10 + 8 -- see those constants' own
	-- headers) and every tier below multiplies off that same effective base, not the raw
	-- BaseWalkSpeed alone (so retuning either constant rescales every tier proportionally, e.g.
	-- today's 18 base -> Sprint 27, Dash ~40). Sprint is a sustained hold; Dash is a brief committed
	-- burst that covers ground faster than sprint's acceleration, for micro-spacing and closing gaps.
	--
	-- Both drive movement purely through a temporary Humanoid.WalkSpeed multiplier applied in
	-- onHeartbeat's single unified computation (never task.delay, so they never race the hit-slow
	-- writer for the same property) -- the player's own already-held movement input carries
	-- direction, so the server computes no displacement and needs no trusted direction from the
	-- client. Numbers here are first-pass technical tunables, free to move without design ceremony
	-- per combat-philosophy.md's Tuning process.
	SprintSpeedMultiplier = 1.5,

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
		MaxTargets = 3,
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
	-- finisher) launches BOTH the target AND the attacker into the air together
	-- (CombatSystem.lua's applyAirCombo). While CombatState.airComboExpiry hasn't lapsed, the
	-- attacker's own subsequent Basic (M1) hits landing on that SAME target continue the
	-- juggle -- refreshing the hold below -- up to MaxHits total, at which point the final hit slams
	-- them into the ground for bonus damage instead of holding them up again. PLAYER TARGETS ONLY for
	-- this pass (bots/dummies just take a plain DashPunch hit, no launch) -- CombatState.airComboTarget
	-- is typed Player? specifically to keep this first pass simple; extending to bots/dummies would
	-- need a wider target type and is deliberately out of scope here.
	AirCombo = {
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
		-- BasicComboLength before forcing a Finisher. The target is no longer fully helpless for the
		-- whole sequence either, as of TechWindowSeconds below -- see that field's own header.
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

		-- Air-tech escape (double-tap-W while held as someone ELSE's air-combo target -- see
		-- CombatState.airTechWindowExpiry/CombatSystem.lua's handleAirTechRequest). Closes the "target
		-- genuinely cannot act for the whole sequence" gap MaxHits' own header used to describe as
		-- accepted-by-design: combat-philosophy.md's "no true unblockable/unparryable without a
		-- telegraphed cost" means the juggle itself needs a real counter, not just a short duration.
		-- How long the window stays open after each launch/re-launch (opened fresh on the DashPunch
		-- launch AND every continuation hit, applyAirCombo's own openAirTechWindow calls) -- a
		-- Sekiro-grade precision window, not a generous one: roughly comparable to
		-- ParryWindowSeconds (0.35) but its own tunable, since teching a full air combo is a
		-- stronger payoff (converts the juggle into a suspended, Block-capable mutual exchange +
		-- an attacker punish) than a plain parry.
		TechWindowSeconds = 0.3,
		-- Cooldown after a GENUINELY MISTIMED air-tech attempt (a request that arrived while truly
		-- juggled, but outside TechWindowSeconds) -- prevents spamming the remote hoping to land the
		-- window by luck. Also applied on a SUCCESSFUL tech (see handleAirTechRequest) -- a free,
		-- infinitely-repeatable escape + attacker punish on every single juggle attempt would make
		-- DashPunch's own cooldown and chase commitment worthless.
		TechCooldownSeconds = 2,
		-- How long a successfully-teched target stays suspended (un-ragdolled but still held aloft
		-- next to the attacker, via RagdollController.HoldAloft's live-body treatment) before the
		-- exchange auto-resolves if neither side acts -- see CombatState.airComboSuspendedUntil's own
		-- header for the full state machine. Deliberately the SAME value as AirborneSeconds above (a
		-- fresh full window, not a fraction of it, since this is a distinct exchange rather than a
		-- continuation of the original juggle timing) -- can't reference that key directly from
		-- within this same table literal, so kept as its own number; retune both together if either
		-- changes.
		SuspendedSeconds = 1.8,
		-- The suspended victim's own one-shot counter-punch (CombatSystem.lua's
		-- handleSuspendedCounterPunchRequest), thrown only while the attacker isn't mid-swing ("only
		-- if the attacker is not hitting them"). Sized between a Basic1 and a Basic3 -- a real payoff
		-- for winning the exchange, not a throwaway tap. Still fully parryable/blockable by the
		-- attacker (HitResolution.ClassifyDefense runs against it exactly like any other hit) --
		-- everything stays parryable, including this.
		SuspendedCounterDamage = 10,
		SuspendedCounterPostureDamage = 14,
	},

	-- Every combat animation id, named once here so a player's own client
	-- (StarterPlayer/.../FX/CombatAnimator.lua) and a training bot's server-driven equivalent
	-- (ServerScriptService/.../Combat/BotAnimator.lua) always play the identical clip for the
	-- identical move -- a bot is meant to look like a real opponent (see createTrainingBot's own
	-- comment on bot vitals), which includes moving like one. Real ids, supplied for this pass (not
	-- guessed -- see CombatAudio.lua/VitalIcon.lua's headers for why this codebase never fabricates
	-- an asset id). Heavy attacks have no dedicated animation yet and are a silent no-op in both
	-- consumers until one is supplied.
	AnimationIds = {
		Swing1 = "rbxassetid://104588315151150",
		Swing2 = "rbxassetid://78226937952673",
		Swing3 = "rbxassetid://106982083848684",
		-- Walking/Running are a pair -- CombatAnimator.lua's locomotion evaluator crossfades
		-- between them on the same fade duration as sprint toggles, and stops whichever is
		-- playing on a hard interrupt (combat action, or the character stops moving).
		Walking = "rbxassetid://92817463622620",
		Running = "rbxassetid://134203885804635",
		Uppercut = "rbxassetid://138196103225171",
		BlockHold = "rbxassetid://105157110369149",
		ParryFlash = "rbxassetid://71843503021113",
		DashFront = "rbxassetid://124093005439273",
		DashBack = "rbxassetid://79144536812023",
		DashLeft = "rbxassetid://139531382954813",
		DashRight = "rbxassetid://108317494909424",
		-- The double-tap-W throw specifically (DashPunch -- Constants.Combat.DashPunch,
		-- CombatSystem.lua's handleDashRequest/throwDashPunch) -- distinct from DashFront so the
		-- punch reads as its own committed attack rather than reusing the plain forward-dash clip a
		-- single Q-press-forward (DashHit) or a bare movement dash already plays. CombatAnimator.lua's
		-- PlayPredictedDash/ConfirmDash pick this one specifically via viaDoubleTapForward/
		-- DashFrontCommitmentSeconds -- see those functions' own headers.
		DashPunch = "rbxassetid://93292051604189",
		-- The new Slide ability (Movement.ApplySlide/CombatSystem.lua's handleSlideRequest) -- a
		-- single clip, unlike Dash's four directional ones, since Slide never steers: it always plays
		-- this one animation in whatever direction the player was already sprinting.
		Slide = "rbxassetid://137106503700813",
		Hit1 = "rbxassetid://122404425463872",
		Hit2 = "rbxassetid://84510912158390",
		Hit3 = "rbxassetid://71830231198123",
		-- Slots wired end-to-end (every play path in CombatAnimator/BotAnimator resolves these
		-- names) but awaiting Studio-authored assets -- an empty id is a SAFE no-op: CombatAnimator's
		-- template loader skips empty ids, so the track never loads and every play path degrades to
		-- its documented fallback (Heavy -> silent, Downslam/FinisherNormal -> the Uppercut stand-in,
		-- HitGeneric -> no flinch, PostureBreakStagger -> no stagger, Feint -> the cancelled swing
		-- just stops with no distinct recoil pose) exactly as before these slots were listed. Drop a
		-- rbxassetid in and the wired path lights up with no code change.
		Heavy1 = "rbxassetid://123661407769898",
		Heavy2 = "rbxassetid://123661407769898",
		-- The standalone AirSlam attack's ground-slam clip (Constants.Combat.AirSlam,
		-- CombatSystem.lua's throwAirSlam) -- always thrown with FinisherVariant = "Downslam", so this
		-- is the one slot that resolves it (see finisherTrackName in CombatAnimator.lua).
		Downslam = "rbxassetid://106111823142540",
		FinisherNormal = "",
		HitGeneric = "",
		PostureBreakStagger = "",
		-- Feint's own recoil/whip-back clip (CombatAnimator.CancelActiveSwing) -- optional: with no
		-- id supplied, a feint just stops whatever swing was playing (ROLLBACK_FADE_TIME fade to
		-- idle) instead of crossfading into a dedicated cancel pose.
		Feint = "",
	} :: { [string]: string },

	-- Passive posture regen once a target is outside its posture-broken window and not being hit.
	-- The only passive-regen model the game has, now that Stamina is gone (Health has no passive
	-- regen either -- see StarterCharacterScripts/Health.server.lua and combat-philosophy.md's
	-- Sekiro-grade reference point).
	PostureRegenPerSecond = 8,

	-- Lock-on acquisition range -- deliberately larger than any hitbox's reach so a player can lock
	-- a target slightly outside melee range and close the distance, per combat-philosophy.md's
	-- "Established systems" lock-on entry.
	LockOnRange = 40,

	-- Proximity radius (studs) CombatSystem.lua's refreshInCombatFromProximity checks a tracked
	-- recent opponent (CombatState.recentOpponents) against, to EXTEND (never start) an
	-- already-earned inCombatUntil window -- see that field's own header for the full "why." Same
	-- value as Hitboxes.MaxCandidateRadius below, deliberately: both represent "close enough to
	-- still plausibly be fighting," and were kept in sync on purpose here, not by coincidence -- a
	-- future tuning pass touching one should consider whether the other should move too, rather than
	-- assuming they drifted apart independently.
	CombatEngagementRange = 20,

	-- Cap on CombatState.recentOpponents -- a small, fixed-size set of "who I've actually traded
	-- with lately," not an unbounded fight history. HitResolution.StampRecentOpponent evicts the
	-- OLDEST entry (lowest timestamp) once this many are already tracked, before adding a new one.
	MaxTrackedOpponents = 4,

	-- Passive (non-action-driven) vitals sync is throttled separately from action-driven syncs
	-- (attack/block/parry resolution always syncs immediately) so idle posture regen
	-- doesn't spend the whole per-player remote budget in NetworkBudget above -- see
	-- performance-optimization.md: "cosmetic/UI-sync remotes... should be throttled first."
	PassiveVitalsSyncInterval = 0.5,

	-- Vertical lift (studs) applied on top of a combat-feedback target's root-part height (or its
	-- server-reported TargetPosition) before placing a damage number / "PARRIED" label on screen --
	-- Client/Combat/CombatClient.lua's own TARGET_HEAD_OFFSET, moved here so the number has a shared
	-- home next to its sibling Constants.Combat presentation-adjacent tunables (LockOnRange etc.)
	-- instead of living as a bare client-only local with no cross-reference. A fixed offset rather
	-- than a real Head lookup: TargetPosition is a bare Vector3 the server reports (no live Instance
	-- to look a Head up from for, e.g., a training dummy target with no owning Player), so both the
	-- TargetPosition and TargetUserId resolution branches in CombatClient.lua need to agree on the
	-- same approximation to avoid feedback jumping vertically depending on which branch fired -- see
	-- that module's own comment at the use site. Roughly root-to-head height for a standard R15 rig.
	FeedbackHeadOffset = Vector3.new(0, 3, 0),

	-- Studio-only visualization of sampled hitbox poses (temporary, non-colliding, non-queryable
	-- Parts) -- see Server/Combat/HitboxResolver.lua. Never affects hit logic even when on, and
	-- HitboxResolver additionally gates rendering on RunService:IsStudio() so this flag flipping
	-- true can't accidentally ship visible hitboxes in a live server -- on for active Studio
	-- playtesting; flip back to false before anything resembling a real deployment.
	DebugHitboxes = true,

	-- Swept melee hitbox geometry/scheduling -- shared regardless of which weapon (Weapons below) is
	-- equipped. Per-weapon Basic/Heavy/Finisher stage arrays live in Constants.Combat.Weapons, not
	-- here -- see that table's own header for why they were split out.
	Hitboxes = {
		-- Seconds between re-samples of the oriented box while a swing's active window is open.
		SampleRate = 1 / 30,
		-- Hard cap on samples taken in a single swing, independent of ActiveSeconds -- guards
		-- against a misconfigured (too-long) ActiveSeconds turning into an unbounded per-swing cost.
		MaxSamplesPerSwing = 20,
		-- Extra distance (studs) added past a hit candidate's root position when re-checking line of
		-- sight for a swing-confirmed overlap, so standing flush against a thin wall doesn't produce
		-- a false "blocked" reading from floating-point edge contact.
		LineOfSightPadding = 0.5,
		-- Radius (studs) CombatSystem.lua's getSwingCandidates spatial-queries around the attacker
		-- for swing candidates, instead of scanning every connected player -- see that function's
		-- own header for the scalability reasoning (performance-optimization.md: cost should scale
		-- with local combat density, not total server population). Sized generously past the
		-- farthest actual hitbox reach across every weapon (every melee stage's Offset sits at
		-- exactly -Size.Z/2, so the box is flush against the root and extends its full Size.Z
		-- forward -- the biggest is Primary Heavy2's Size.Z=5.75, i.e. ~5.75 studs) since this list is
		-- only the roster HitboxResolver's per-sample box query narrows further -- being a little generous here
		-- costs nothing (arc/LOS/distance are all re-validated downstream), being too tight would
		-- risk missing a legitimately reachable target.
		MaxCandidateRadius = 20,
		-- Sub-samples interpolated between the previous and current main sample pose (CFrame:Lerp)
		-- so a fast-moving/rotating hitbox still catches a target it swept past between two
		-- SampleRate ticks -- see HitboxResolver.performSample, the only reader. Was a module-local
		-- constant there; moved here per luau-coding-standards.md's "no magic numbers in system
		-- logic" now that every other hitbox-timing number already lives in this table.
		SweepSubsteps = 3,
		-- Hard cap on parts a single OverlapParams query can return (Workspace:GetPartBoundsInBox) --
		-- guards against a pathological number of candidate parts in one query. Same
		-- moved-from-module-local reasoning as SweepSubsteps above.
		MaxPartsPerQuery = 100,

		-- Studio-only debug-hitbox Part cosmetics (Server/Combat/HitboxResolver.lua's
		-- renderDebugHitbox, gated behind Constants.Combat.DebugHitboxes AND RunService:IsStudio() --
		-- see that flag's own header above). Were three module-local constants in HitboxResolver.lua
		-- (DEBUG_PART_LIFETIME/DEBUG_PART_COLOR/DEBUG_PART_TRANSPARENCY), inconsistent with this same
		-- table's own sibling tunables (SweepSubsteps/MaxPartsPerQuery just above), which already made
		-- the jump to Constants per luau-coding-standards.md's "no magic numbers in system logic" --
		-- moved here to match. Purely cosmetic -- never read by, or able to influence, the actual
		-- overlap query above it in performSample.
		DebugPart = {
			LifetimeSeconds = 0.15,
			Color = Color3.fromRGB(255, 64, 64),
			Transparency = 0.6,
		},
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

				Heavy = {
					{
						DebugName = "Heavy1",
						WindupSeconds = 0.600,
						ActiveSeconds = 0.22,
						RecoverySeconds = 0.35,
						Size = Vector3.new(7, 6.5, 5.5),
						Offset = CFrame.new(0, 0, -2.75),
						Damage = 12,
						PostureDamage = 22,
						Cooldown = 3.00,
						ArcDegrees = 120,
						MaxTargets = 4,
					},
					{
						DebugName = "Heavy2",
						WindupSeconds = 0.20,
						ActiveSeconds = 0.24,
						RecoverySeconds = 0.40,
						Size = Vector3.new(8, 6.5, 5.75),
						Offset = CFrame.new(0, 0, -2.875),
						Damage = 21,
						PostureDamage = 25,
						Cooldown = 3.00,
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
						WindupSeconds = 0.06,
						ActiveSeconds = 0.12,
						RecoverySeconds = 0.15,
						-- Z cut ~35% same as Primary above -- see Basic1's own comment for why.
						Size = Vector3.new(5, 6.5, 3.75),
						Offset = CFrame.new(0, 0, -1.875),
						Damage = 6,
						PostureDamage = 9,
						Cooldown = 0.33,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Dagger2",
						WindupSeconds = 0.07,
						ActiveSeconds = 0.12,
						RecoverySeconds = 0.16,
						Size = Vector3.new(5, 6.5, 3.75),
						Offset = CFrame.new(0, 0, -1.875),
						Damage = 7,
						PostureDamage = 9,
						Cooldown = 0.35,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Dagger3",
						WindupSeconds = 0.08,
						ActiveSeconds = 0.13,
						RecoverySeconds = 0.19,
						Size = Vector3.new(5.5, 6.5, 4.25),
						Offset = CFrame.new(0, 0, -2.125),
						Damage = 8,
						PostureDamage = 11,
						Cooldown = 0.40,
						ArcDegrees = 110,
						MaxTargets = 3,
					},
				},

				Heavy = {
					{
						DebugName = "DaggerHeavy1",
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
					{
						DebugName = "DaggerHeavy2",
						WindupSeconds = 0.15,
						ActiveSeconds = 0.18,
						RecoverySeconds = 0.30,
						Size = Vector3.new(6.5, 6.5, 5.25),
						Offset = CFrame.new(0, 0, -2.625),
						Damage = 15,
						PostureDamage = 23,
						Cooldown = 0.63,
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
		-- Below this horizontal distance between the air-combo hold position and the face-toward
		-- point, ensureFaceOrientation skips re-aligning rather than pointing at a near-zero look
		-- vector (the degenerate "target directly overhead" case).
		FaceAlignToleranceStuds = 0.05,
	},

	-- CombatAudio.lua's registered sound effects -- SoundId/Volume named once here so the client
	-- module only owns the verb-named play functions, same split as Constants.Flight.Sound.
	-- PoolSize = 2 on all three: fast combos can re-trigger the same name (a second Hit/BlockImpact/
	-- HandToHandParried) before the first finishes playing, and a single shared Sound instance would
	-- cut the first off rather than let them overlap -- see SoundManager.lua's own Play() comment.
	Sound = {
		Hit = { SoundId = "rbxassetid://100187980380825", Volume = 0.6, PoolSize = 2 } :: SoundDefinition,
		BlockImpact = { SoundId = "rbxassetid://111982142063703", Volume = 0.6, PoolSize = 2 } :: SoundDefinition,
		HandToHandParried = { SoundId = "rbxassetid://79732341463482", Volume = 0.6, PoolSize = 2 } :: SoundDefinition,
	},

	-- Every RemoteEvent CombatSystem owns, named once here so the server (which creates them) and
	-- the client (which looks them up) never risk a typo'd duplicate -- luau-coding-standards.md's
	-- networking convention ("declared once... never instanced ad hoc").
	RemoteNames = {
		RequestBasicAttack = "Combat_RequestBasicAttack",
		RequestHeavyAttack = "Combat_RequestHeavyAttack",
		RequestBlockStart = "Combat_RequestBlockStart",
		RequestBlockStop = "Combat_RequestBlockStop",
		-- Server -> acting client, fired the moment a BlockStart request is accepted -- the block
		-- counterpart of AttackStarted/MovementPerformed, carrying just enough for CombatAnimator to
		-- start the guard stance and (if ParryWindowOpened) the parry-flash, synced to the server's
		-- real parryWindowExpiry rather than guessed from raw input. See CombatSystem.lua's
		-- handleBlockStart and Types.BlockStartedPayload.
		BlockStarted = "Combat_BlockStarted",
		-- Server -> ALL clients (broadcast, unlike BlockStarted which is unicast to the blocker),
		-- fired the moment ANY combatant's parry window opens -- a player OR a training bot. Carries
		-- the combatant's character Model so every client can show the parry-window TELL (a bright
		-- highlight, HitFlash.FlashHold) on it: this is what makes the tell both OBVIOUS (an attacker
		-- can read "they're parry-armed") and SYNCED for everyone (a broadcast highlight any client can
		-- adorn, not an animation that depends on the actor's own replicated Animator weight winning).
		-- See CombatSystem.lua's handleBlockStart / RequestBotBlockStart.
		ParryWindowOpened = "Combat_ParryWindowOpened",
		-- Fires the neutral-game Dash -- see CombatSystem.lua's handleDashRequest. A forward-resolved
		-- Dash reported as a double-tap (CombatClient.lua's double-tap-W trigger) can also throw
		-- DashPunch off this same request.
		RequestDash = "Combat_RequestDash",
		-- Sprint is a held movement state (start/stop, like Block).
		RequestSprintStart = "Combat_RequestSprintStart",
		RequestSprintStop = "Combat_RequestSprintStop",
		-- Fires the new Slide ability -- chained off Sprint (CombatSystem.lua's handleSlideRequest
		-- independently re-checks state.sprinting/Movement.IsMoving server-side). No hitbox, unlike
		-- a forward Dash -- pure repositioning, mirrors plain Dash.
		RequestSlide = "Combat_RequestSlide",
		RequestLockOn = "Combat_RequestLockOn",
		VitalsUpdated = "Combat_VitalsUpdated",
		FeedbackEvent = "Combat_FeedbackEvent",
		LockOnChanged = "Combat_LockOnChanged",
		AttackStarted = "Combat_AttackStarted",
		-- Server -> acting client, fired the moment a Dash is accepted -- the movement counterpart of
		-- AttackStarted, carrying just enough for the animation/FX layer to time a dash-step. Not
		-- consumed for any gameplay decision (Sprint has no event: Roblox's default run cycle already
		-- reflects the raised WalkSpeed).
		MovementPerformed = "Combat_MovementPerformed",
		-- Server -> acting client, fired the moment a Slide is accepted -- the Slide counterpart of
		-- MovementPerformed, kept as its own remote/payload (Types.SlidePerformedPayload) rather than
		-- reusing MovementPerformed, since that one is already disambiguated between plain-Dash and
		-- DashPunch by a fragile numeric-duration comparison (PredictionMirror.OnMovementPerformed) --
		-- see that type's own header for the full reasoning.
		SlidePerformed = "Combat_SlidePerformed",
		-- Server -> owning client, fired when the M1 combo's finisher becomes ready/unready (3 hits
		-- landed). The client uses it to suppress the jump on the 4th hit so pressing Space triggers
		-- the Uppercut instead of a jump -- see CombatSystem.lua's syncFinisherReady and CombatClient.
		ComboStateChanged = "Combat_ComboStateChanged",
		-- Server -> acting client, fired when a Basic/Heavy/Dash/Slide/BlockStart/Sprint request is GENUINELY
		-- rejected (never for the too-early-but-buffered pseudo-reject, and never for Stop actions,
		-- which are always honored) -- the rollback signal for the client's predicted action-start
		-- feedback (Constants.Combat.Prediction above; Sprint's feedback is visual-only -- see
		-- Types.RejectedActionKind's own header). Network budget: server->client, fires at most
		-- once per rejected request, so its rate is upper-bounded by the client->server rate limiters
		-- (NetworkBudget) -- it can never exceed what the client was already allowed to send.
		ActionRejected = "Combat_ActionRejected",
		-- Client -> server, a one-shot toggle between Constants.Combat.Weapons.Primary/Secondary --
		-- see handleSwapWeaponRequest. No payload: there are exactly two slots, so "swap" always
		-- means "the other one."
		RequestSwapWeapon = "Combat_RequestSwapWeapon",
		-- Server -> owning client, fired on every accepted weapon swap so the HUD can reflect which
		-- weapon is equipped -- the weapon-switching counterpart of ComboStateChanged's "fire on
		-- transition" pattern.
		WeaponChanged = "Combat_WeaponChanged",
		-- Client -> server, right-click -- cancels the player's own Basic/Heavy/Finisher/AirSlam swing
		-- while it's still in its WindupSeconds telegraph. See CombatSystem.lua's handleFeintRequest
		-- and Types.FeintPerformedPayload's own header for the full mechanic.
		RequestFeint = "Combat_RequestFeint",
		-- Server -> acting client, fired the moment a Feint is accepted -- the Feint counterpart of
		-- MovementPerformed/SlidePerformed, carrying the shortened commitment (Types.
		-- FeintPerformedPayload.RecoverySeconds) so PredictionMirror can collapse its own mirrored
		-- attackEndsAt down to the real, shorter value instead of staying conservatively locked out
		-- for the cancelled swing's original (longer) commitment.
		FeintPerformed = "Combat_FeintPerformed",
		-- Client -> server, the double-tap-forward air-tech attempt while held aloft in someone
		-- ELSE's air combo (CombatState.airComboTarget is tracked on the ATTACKER's own state -- see
		-- that field's header, there's no direct "my attacker" pointer on the victim's side). A
		-- distinct action from Block/Parry (Combat_RequestBlockStart is unusable here --
		-- ACTION_GATES.BlockStart.Ragdoll = true blocks it outright while ragdolled/held) and from
		-- Dash (CombatClient branches to THIS remote instead of RequestDash when the local player's
		-- own PredictionMirror says they're currently held). See CombatSystem.lua's
		-- handleAirTechRequest.
		RequestAirTech = "Combat_RequestAirTech",
		-- Server -> owning client, fired when CombatState.inCombatUntil (see that field's own header)
		-- transitions true/false -- same "fire on transition, not per-tick" shape as ComboStateChanged/
		-- WeaponChanged, so the HUD's combat-state badge (Components/CombatStateBadge.lua) gets exactly
		-- one event per real state change instead of a remote per Heartbeat tick.
		InCombatChanged = "Combat_InCombatChanged",
	},
}

return Constants
