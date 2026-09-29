--!strict
--[[
	Main.client.lua

	Owns: the client boot sequence. Every client-side UI/FX module gets required and started from
	here in explicit order, mirroring Main.server.lua's boot pattern -- never rely on Script
	instancing order.

	Does not own gameplay decisions: per engineering-standards.md, everything this boots only
	requests and displays server-validated state; it never computes gameplay outcomes itself
	(software-architecture.md: "server owns truth, client owns feel").

	FX (animation-systems.md, VFX/animation sync) modules get added to the boot list here as
	they're built.

	Logs its own boot sequence (Logger.lua, Studio-only) under the "Main" scope -- start/end of
	each phase.

	Character-lifecycle announcement: this file's own localPlayer.CharacterAdded hookup below calls
	CombatAnimator.BindCharacter/MovementVFX.BindCharacter/RunController.BindCharacter for every new
	life -- the role Client/Combat/CombatClient.lua's own CharacterAdded handler used to play before
	the combat system was removed. CombatAnimator's plain Walking/Running locomotion loop (a movement
	feature, not a combat one -- see that module's own header) has nothing to play without this;
	Dash/Slide's own request-firing is NOT resurrected here, since CombatSystem.lua (their only
	server-side handler) is gone and the orphaned resolver that would have applied their WalkSpeed
	bursts has since been deleted. Sprint DID come back, elsewhere: Client/Movement/RunController.lua
	owns the intent and Server/Systems/RunSystem.lua owns the ladder. AttackInputClient and DefenseClient each bind their OWN
	AnimationManager per life rather than going through that hookup, which is that module's documented
	"construct once, Bind() per respawn" shape and not an inconsistency.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local EngineLogCapture = require(ReplicatedStorage.Shared.EngineLogCapture)

local UI = require(script.Parent.UI)
local StartMenuClient = require(script.Parent.StartMenu.StartMenuClient)
local LoadingClient = require(script.Parent.Loading.LoadingClient)
local IntroClient = require(script.Parent.Intro.IntroClient)
local CombatAnimator = require(script.Parent.FX.CombatAnimator)
local MovementVFX = require(script.Parent.FX.MovementVFX)
local EmoteController = require(script.Parent.Emotes.EmoteController)
local EmoteWheelClient = require(script.Parent.Emotes.EmoteWheelClient)
local ShiftLockCamera = require(script.Parent.Camera.ShiftLockCamera)
local FlightCamera = require(script.Parent.Camera.FlightCamera)
local CameraShake = require(script.Parent.FX.CameraShake)
local FOVOffset = require(script.Parent.FX.FOVOffset)
local CameraOffsetComposer = require(script.Parent.FX.CameraOffsetComposer)
local CameraFollow = require(script.Parent.Camera.CameraFollow)
local ParkourController = require(script.Parent.Parkour.ParkourController)
local RunController = require(script.Parent.Movement.RunController)
local CharacterMenuClient = require(script.Parent.CharacterMenu.CharacterMenuClient)
local FlightController = require(script.Parent.Flight.FlightController)
local DefenseClient = require(script.Parent.Defense.DefenseClient)
local AttackInputClient = require(script.Parent.Combat.AttackInputClient)
local WeaponInventoryClient = require(script.Parent.Combat.WeaponInventoryClient)
local GrabInputClient = require(script.Parent.Combat.GrabInputClient)
local AirComboClient = require(script.Parent.Combat.AirComboClient)
local AirComboFX = require(script.Parent.FX.AirComboFX)
local BlimpController = require(script.Parent.Blimp.BlimpController)
local BoatController = require(script.Parent.Boat.BoatController)
local FurnacePromptClient = require(script.Parent.Blimp.FurnacePromptClient)
local SwingLunge = require(script.Parent.Combat.SwingLunge)
local LockOnController = require(script.Parent.Combat.LockOnController)
local SwingTracking = require(script.Parent.Combat.SwingTracking)
local SwingTellFX = require(script.Parent.FX.SwingTellFX)
local CombatAudio = require(script.Parent.FX.CombatAudio)
local AttackTrail = require(script.Parent.FX.AttackTrail)
local RollAfterimage = require(script.Parent.FX.RollAfterimage)
local FpsCounter = require(script.Parent.Diagnostics.FpsCounter)
local RemoteMovementFX = require(script.Parent.FX.RemoteMovementFX)
local GrabHoldPose = require(script.Parent.FX.GrabHoldPose)
local GuardStrainPose = require(script.Parent.FX.GuardStrainPose)
local CombatFeedbackClient = require(script.Parent.Combat.CombatFeedbackClient)
local DeathNoticeClient = require(script.Parent.Combat.DeathNoticeClient)
local BugReportClient = require(script.Parent.BugReport.BugReportClient)
local AnnouncementClient = require(script.Parent.Announcement.AnnouncementClient)
local SettingsClient = require(script.Parent.Settings.SettingsClient)

local logger = Logger.scope("Main")

logger:info("Client boot start")

-- Connects LogService before anything else below gets a chance to log a boot-time error/warning it
-- should have seen -- same "boots before everything else, gates nothing" reasoning as the server's
-- own EngineLogCapture.Init() call in Main.server.lua. Zero dependency on any gate below (Start
-- Menu/Loading/Onboarding included): it only ever touches Shared/Logger.lua's own always-on capture
-- buffer.
EngineLogCapture.Init()

-- Three boot-time gates run in sequence before anything else in this file, each blocking until it's
-- genuinely done: Start Menu -> Loading -> Onboarding.
--
-- StartMenuClient.Run() is the TRUE first thing shown -- see that module's own header for its
-- unusual contract: it returns immediately if this arrival was via a Play-triggered server hop
-- (TeleportService:GetLocalPlayerTeleportData()'s FromStartMenu marker), and otherwise does NOT
-- return at all on this server -- either a later Play click succeeds and the engine tears this whole
-- script down mid-teleport, or a failed attempt just re-shows the Start Menu to retry. Nothing below
-- this line runs at all until either this returns (post-hop) or never (direct join, Start Menu
-- showing).
logger:debug("StartMenuClient run start")
StartMenuClient.Run()
logger:debug("StartMenuClient run end")

-- BLOCKS until every known client asset (sounds, combat/flight animation clips, VFX textures) has
-- been preloaded, showing a Loading screen the whole time, so nothing below this line can pay a
-- cold-load hitch for an asset it assumes is ready. Every CombatAudio.lua/FlightAudio.lua Register()
-- call has already run by this point (each require() above executes that module's top-level body
-- immediately, in order), so the full sound registry exists before AssetPreloader.lua ever reads it.
-- See LoadingClient.lua's own header for why this always runs (unlike IntroClient.Run() below,
-- which skips for returning players).
logger:debug("LoadingClient run start")
LoadingClient.Run()
logger:debug("LoadingClient run end")

-- Runs BEFORE everything else in this file, including UI.Mount() -- first-time-player onboarding
-- (Server/Systems/CharacterCreationSystem.lua's GetOnboardingState/Finalize) owns this session's
-- first Player:LoadCharacter() call for every player (Players.CharacterAutoLoads = false (default.project.json)), so
-- nothing below this line can assume a character (or a finished profile) exists until this returns.
-- IntroClient.Run() returns immediately for a returning player (NeedsOnboarding = false) and
-- otherwise blocks through the whole cinematic-intro-through-awakening sequence -- lying pose,
-- camera pan, character creation (delegated to Client/Onboarding/OnboardingClient.lua's own
-- exports), black screen, the server's race-keyed teleport, first-person blur/blink reveal, get-up
-- animation, and the greeting banner -- see that module's own header for why it mounts and tears
-- down its OWN temporary Fusion scope rather than using UI.Mount()'s session-long one, and why
-- camera systems below (ShiftLockCamera/FlightCamera/CameraShake) starting only after this returns
-- is load-bearing for Client/Intro/IntroCamera.lua's own Scriptable-camera handoff.
logger:debug("IntroClient run start")
IntroClient.Run()
logger:debug("IntroClient run end")

logger:debug("UI mount start")
local uiHandles = UI.Mount()
logger:debug("UI mount end")

-- A rebound key must already be live in KeybindManager the instant any input-driven client module
-- below could start reacting to a press -- see SettingsClient.RestoreSettings' own header for why
-- this is a separate, earlier phase than SettingsClient.Start(uiHandles.Settings) further down (that
-- call only wires the Settings PANEL's own interactivity, which has no such urgency).
logger:debug("SettingsClient RestoreSettings start")
SettingsClient.RestoreSettings(uiHandles.SetUIScale)
logger:debug("SettingsClient RestoreSettings end")

-- Announces every new life to the presentation-layer modules that used to bind off
-- Client/Combat/CombatClient.lua's own CharacterAdded handler -- see this file's own header. Covers
-- both the ordinary respawn path and a Studio play-solo start where a character already exists
-- before this line runs.
logger:debug("Character-bind hookup start")
-- Shared/PlayerLifecycle.lua owns the whole shape now: waiting for the Humanoid before handing the
-- character to any sub-binder below, spawning the already-present-character call rather than blocking
-- this boot thread on it, and re-checking after that yield that the character is still the current
-- one. All three used to be written out here, at length, and in fourteen other client modules with
-- byte-identical comments -- see that module's header for what each of them is actually protecting
-- against and what losing the race looks like from the player's seat.
PlayerLifecycle.BindLocalCharacter({
	Scope = "Main",
	OnCharacter = function(character: Model)
		CombatAnimator.BindCharacter(character)
		MovementVFX.BindCharacter(character)
		RunController.BindCharacter(character)
		SwingLunge.BindCharacter(character)
		AttackTrail.BindCharacter(character)
	end,
})
logger:debug("Character-bind hookup end")

-- After UI.Mount() above: UI.Mount() is what calls ClientState.Bootstrap() internally, which is
-- what resolves the Emote_Started/Emote_Stopped/Emote_UnlockedUpdated/Emote_LoadoutUpdated remotes
-- EmoteController.Start() below also looks up -- both modules independently WaitForChild the same
-- already-created remotes, so the ordering itself isn't strictly load-bearing, but keeping this
-- cluster after UI.Mount() matches this file's own boot position above for the same "gameplay
-- input modules start once the UI they might eventually surface through exists" reasoning.
logger:debug("EmoteController start")
EmoteController.Start()
logger:debug("EmoteController end")

-- After EmoteController above (this module's own RequestPlay is the only thing EmoteWheelClient is
-- allowed to call to actually play an emote) and after UI.Mount() (needs both uiHandles.EmoteWheel,
-- the Screen's own IsOpen/SelectedIndex handle, and uiHandles.ClientState, to read the live loadout
-- -- neither exists before UI.Mount() returns).
logger:debug("EmoteWheelClient start")
EmoteWheelClient.Start(uiHandles.EmoteWheel, uiHandles.ClientState, uiHandles.Chrome)
logger:debug("EmoteWheelClient end")

-- Before ShiftLockCamera/FlightCamera/CameraShake below: FOVOffset is the single canonical writer
-- of camera.FieldOfView that FlightCamera (started below) composes through -- see that module's own
-- header.
logger:debug("FOVOffset start")
FOVOffset.Start()
logger:debug("FOVOffset end")

-- Same reasoning as FOVOffset above, for Humanoid.CameraOffset instead of FieldOfView -- the single
-- canonical writer ShiftLockCamera/FlightCamera below both compose through. See that module's header.
logger:debug("CameraOffsetComposer start")
CameraOffsetComposer.Start()
logger:debug("CameraOffsetComposer end")

-- After CameraOffsetComposer: the smoothed follow writes its trail as one of that composer's slots. See
-- Client/Camera/CameraFollow.lua.
logger:debug("CameraFollow start")
CameraFollow.Start()
logger:debug("CameraFollow end")

logger:debug("ShiftLockCamera start")
ShiftLockCamera.Start(uiHandles.ShiftLockEngaged)
logger:debug("ShiftLockCamera end")

-- Same RenderPriority.Camera + 1 slot as ShiftLockCamera above -- mutually exclusive at runtime
-- (ShiftLockCamera skips its own CameraOffset/yaw writes while Flying is true), never both driving
-- the same frame. See FlightCamera.lua's own header.
logger:debug("FlightCamera start")
FlightCamera.Start()
logger:debug("FlightCamera end")

-- After ShiftLockCamera/FlightCamera: CameraShake composes on top of the final camera pose at
-- RenderPriority.Camera + 2 (after ShiftLock's Camera + 1) -- see CameraShake's header. Both bind at
-- their own priority regardless of call order; keeping the boot order aligned mirrors that intent.
logger:debug("CameraShake start")
CameraShake.Start()
logger:debug("CameraShake end")

-- After FOVOffset/CameraOffsetComposer/CameraShake above, whose named slots
-- Client/Parkour/ParkourCamera.lua composes its speed zoom, slide framing, wall-run lean and landing
-- dips through. Starting before those three would mean ParkourCamera writing into compositors that
-- have not bound their render steps yet -- harmless for a frame, but the ordering is kept explicit
-- here for the same reason every other entry in this file is.
--
-- Unconditional for every client. Client/Settings/SettingsClient.RestoreSettings() (already run
-- further up) has by this point pushed the player's own persisted movement preferences in, including
-- the master Parkour toggle -- so a player who has switched parkour off gets a controller that starts
-- and immediately does nothing, rather than this boot line needing to know about the setting.
logger:debug("ParkourController start")
ParkourController.Start()
logger:debug("ParkourController end")

-- After ParkourController (the live movement state id RunController.SetParkourState reads) and this
-- file's own character-bind hookup above. Starting it earlier would be harmless -- every one of its
-- inputs is pushed, so it would simply present nothing until the first push arrives -- but the order
-- is kept explicit here for the same reason every other entry in this file is. Also after FOVOffset,
-- whose named-slot composer this module's stage-2 zoom writes into.
logger:debug("RunController start")
RunController.Start()
logger:debug("RunController end")

-- Block and parry input. Unconditional for every client, and deliberately AFTER
-- SettingsClient.RestoreSettings above -- it reads the Block action through KeybindManager, so a
-- player who rebound that key must have their override live before the first press can reach this.
-- Nothing else about its position is load-bearing: it decides nothing locally (see its own header),
-- so starting it earlier would simply mean sending presses to a server that answers them the same
-- way.
logger:debug("DefenseClient start")
DefenseClient.Start()
logger:debug("DefenseClient end")

-- Attack input -- the light/heavy strings, the feint, the five hotbar slots and the weapon swap.
-- Unconditional for every client, and deliberately AFTER SettingsClient.RestoreSettings above for
-- exactly the same reason DefenseClient is: it binds BasicAttack/HeavyAttack/Feint/HotbarSlot1-5 and
-- the weapon keys through InputRouter (which matches through KeybindManager), so a player who rebound
-- any of them must have their override live before the first press can reach this. Replaces the deleted TestAttackHarnessClient, whose own header always said a
-- real input layer would.
--
-- Also after UI.Mount() above, though not for a reason of its own: the HUD's ability slots subscribe
-- to this module's OnSlotCooldown at mount time, and a subscription made before Start() is fine (the
-- listener list outlives Start), so this ordering is documented rather than load-bearing.
logger:debug("AttackInputClient start")
AttackInputClient.Start()
logger:debug("AttackInputClient end")

-- Drives the inventory HUD off Weapon_InventoryChanged. Receive-only (the T/Y keys belong to
-- AttackInputClient above), so its position here is about keeping the two weapon-facing client modules
-- adjacent rather than about ordering -- the server re-pushes the whole inventory on every character
-- bind, so a listener connected late still gets the current state rather than missing an edge.
logger:debug("WeaponInventoryClient start")
WeaponInventoryClient.Start(uiHandles.WeaponInventory)
logger:debug("WeaponInventoryClient end")

-- Grab-throw input, alongside AttackInputClient above -- same "AFTER SettingsClient.RestoreSettings so
-- a rebound GrabThrow key is live before the first press" reasoning that module's own comment gives.
logger:debug("GrabInputClient start")
GrabInputClient.Start()
logger:debug("GrabInputClient end")

-- The air combo (docs/design/air-combat-and-evade.md, Part B): the local attacker's follow, and every
-- combatant's phase readability. Both read only replicated Attributes, so neither depends on the other or on
-- anything started above beyond the parkour controller, which parks itself off the same Attributes.
logger:debug("AirComboClient start")
AirComboClient.Start()
AirComboFX.Start()
logger:debug("AirComboClient end")

-- Blimp mount input, the mounted-body pose and the pilot's helm. AFTER SettingsClient.RestoreSettings
-- for the same reason the two input modules above are -- it reads the Interact bind both to match the
-- release press AND to re-key every blimp ProximityPrompt, so a rebound key that was not live yet would
-- leave prompts showing the default while the release press listened for the new one.
--
-- Client/Camera/BlimpCamera.lua and Client/FX/BlimpAudio.lua are deliberately NOT started here. Neither
-- has a Start() at all: both are driven entirely off this module's mount/dismount edges, and the camera
-- binds its own render step only while somebody is actually aboard rather than for the session -- see
-- its own header on why that differs from FlightCamera/ShiftLockCamera immediately above.
logger:debug("BlimpController start")
BlimpController.Start(uiHandles.BlimpHelm, uiHandles.BlimpFuel, uiHandles.CarriedResources, uiHandles.Notify)

-- The furnace's custom prompt. A SIBLING of BlimpController rather than part of it -- see
-- Client/Blimp/FurnacePromptClient.lua's own header: this serves anyone standing next to a hull,
-- including someone who has never boarded one, which is the opposite audience to everything that
-- module owns. Order relative to it does not matter (they share no state and no remote); it is
-- started here because this is where the blimp client cluster lives.
logger:debug("FurnacePromptClient start")
FurnacePromptClient.Start(uiHandles.FurnacePrompt, uiHandles.ViewportScale)
logger:debug("FurnacePromptClient end")
logger:debug("BlimpController end")

-- The boat client. A SIBLING of the blimp cluster above rather than part of it: the two share their
-- whole mount/pose layer through Shared/Vessel, share no state and no remote, and the order between
-- them is free. Started here because this is where the vehicle client cluster lives.
--
-- TAKES NO UI HANDLES, unlike BlimpController immediately above, and that is the one visible
-- difference between the two. A boat has no helm panel yet -- see Client/Boat/BoatController.lua's own
-- header, which names that omission and the seam a future one plugs into. Everything a player needs to
-- actually sail one (prompts, the mount, the rudder, the sail rungs, the release) is here.
logger:debug("BoatController start")
BoatController.Start()
logger:debug("BoatController end")

-- Next to AttackInputClient above because its only input is that module's OnAttackStarted seam --
-- read as one unit, not because the order is load-bearing. OnAttackStarted appends to a plain
-- listener list that nothing rebuilds, so subscribing on either side of that module's own Start()
-- would work; there is no hidden ordering rule here to preserve. The one real dependency is on
-- ParkourController.Start() further up, which is what binds the ParkourMotor this module pushes its
-- velocity through -- already satisfied by boot position, and self-correcting anyway (an unbound
-- motor refuses the impulse rather than erroring, and rebinds on the next life).
logger:debug("SwingLunge start")
SwingLunge.Start()

-- Lock-on (CapsLock / R3): the target, the soft camera pull and the marker with its guard bar -- see
-- Client/Combat/LockOnController.lua. Then swing tracking, which turns the body toward that target (or the
-- soft assist's pick) during a windup. Both after AttackInputClient.Start above, whose swing signals
-- SwingTracking listens to.
LockOnController.Start(uiHandles.LockOnMarker, uiHandles.ViewportScale)
SwingTracking.Start()

-- The heavy tell on other combatants (AttackConstants.Tell) -- a server-published tag, drawn here.
SwingTellFX.Start()
logger:debug("SwingLunge end")

-- Same one real dependency as SwingLunge directly above -- AttackInputClient.OnAttackStarted -- and
-- the same reason for sitting next to it: read as one unit, not because the order is load-bearing.
logger:debug("AttackTrail start")
AttackTrail.Start()
logger:debug("AttackTrail end")

-- Same one real dependency as SwingLunge directly above -- AttackInputClient.OnAttackStarted, which
-- this module subscribes to for the swing whoosh (Client/FX/CombatAudio.lua's own header on why it
-- keeps its own subscription rather than being called out to). Registration itself already happened
-- earlier, at LoadingClient.Run()'s AssetPreloader pass (Client/Loading/AssetPreloader.lua's own
-- require(CombatAudio) for exactly that side effect) -- Start() here only arms the listener.
logger:debug("CombatAudio start")
CombatAudio.Start()
logger:debug("CombatAudio end")

-- The roll's afterimage (the ghosts' fade loop), then the watcher that draws OTHER players' rolls off
-- the replicated ParkourState Attribute. The local player's own roll reaches RollAfterimage through
-- MovementVFX's state hook, which ParkourController (started above) drives. RollAfterimage first: a
-- remote roll that replicates the instant the watcher binds must find the fade loop running.
logger:debug("RollAfterimage start")
RollAfterimage.Start()
logger:debug("RollAfterimage end")
logger:debug("RemoteMovementFX start")
RemoteMovementFX.Start()
logger:debug("RemoteMovementFX end")

-- Every body whose guard is cracking strains its guard pose, on every client, off the GuardCrack tag
-- DefenseSystem publishes (no remote). Then the environment's dust and chipped debris -- a swing scuffing
-- a wall and a body splatted into one -- off Combat_EnvironmentFX, plus this player's own swing scuff,
-- predicted locally off AttackInputClient.OnAttackStarted (started above). Neither depends on the other.
logger:debug("GuardStrainPose start")
GuardStrainPose.Start()
logger:debug("GuardStrainPose end")

-- Every grab being held puts the holder's right hand on the victim's collar (and the victim's hands on
-- that arm), on every client, off the tags GrabSystem publishes (no remote) -- same shape as the guard
-- strain above, bound one render priority after it.
logger:debug("GrabHoldPose start")
GrabHoldPose.Start()
logger:debug("GrabHoldPose end")

-- Hit presentation -- damage numbers, the outcome banner and the camera shake, driven off the damage
-- layer's Combat_Feedback event. AFTER UI.Mount(), and that IS load-bearing: it is handed the
-- CombatFeedback screen's own handle, which does not exist until UI.Mount() returns.
logger:debug("CombatFeedbackClient start")
CombatFeedbackClient.Start(uiHandles.CombatFeedback)
logger:debug("CombatFeedbackClient end")

-- Death presentation -- the local player's death overlay and the kill feed, driven off
-- PlayerDeathSystem's Death_Notice broadcast. After UI.Mount() for the same reason as the line above:
-- it is handed the DeathFeed screen's handle.
logger:debug("DeathNoticeClient start")
DeathNoticeClient.Start(uiHandles.DeathFeed)
logger:debug("DeathNoticeClient end")

-- The frame-rate overlay (F3). Needs nothing from UI.Mount() -- it builds its own plain ScreenGui so it
-- keeps working if the UI layer is what is misbehaving -- and is not dev-gated: see
-- Constants.Debug.FpsCounter.
FpsCounter.Start()

-- THE ONE DEV-TOOLING CALL. Dev Menu, Move Editor, Kit Editor, Live Console and the Storybook are
-- started together by Client/DevTools/init.lua, and this file reaches that module by FindFirstChild
-- rather than by path because a build config is allowed to omit the whole subtree -- see
-- live.project.json and that module's own header. uiHandles.DevTools is nil in exactly the same
-- builds, so the two guards are one condition, not two.
--
-- Nothing about the call site's position changes: each of the five already returned immediately and
-- did its real work behind a server authorization round trip, and each panel is still a Shared/Lazy.lua
-- thunk that only builds if that answer comes back yes.
--
-- Client/Flight/ is NOT part of this and is started unconditionally further down -- an admin can grant
-- flight to a NON-admin, whose own client must drive the movement.
local devToolsModule = script.Parent:FindFirstChild("DevTools")
if devToolsModule and uiHandles.DevTools then
	local DevTools = require(devToolsModule :: ModuleScript) :: any
	logger:debug("DevTools start")
	DevTools.Start(uiHandles.DevTools, uiHandles.Chrome)
	logger:debug("DevTools end")
else
	logger:info("DevTools absent -- this build does not ship dev tooling")
end

-- Unconditional for every client, unlike DevMenuClient above -- the character menu (M: sheet, Arts,
-- Emotes, Bounties) has no whitelist gate. This was the one Screens/ handle UI.Mount() used to
-- discard outright, which left CharacterMenuClient.Start with no caller anywhere and the whole
-- panel unreachable -- M did nothing, and there was no way to unlock or equip an Art in play.
logger:debug("CharacterMenuClient start")
CharacterMenuClient.Start(uiHandles.Menus, uiHandles.Chrome)
logger:debug("CharacterMenuClient end")

-- Unconditional for every client, unlike DevMenuClient above -- the bug report form has no
-- whitelist gate; every player can open and submit it.
logger:debug("BugReportClient start")
BugReportClient.Start(uiHandles.BugReport, uiHandles.Chrome)
logger:debug("BugReportClient end")

-- Unconditional for every client, same reasoning as BugReportClient above -- an admin broadcast (or
-- a shutdown-countdown warning) is meant for the whole server, not just other admins.
logger:debug("AnnouncementClient start")
AnnouncementClient.Start(uiHandles.Announcement)
logger:debug("AnnouncementClient end")

-- Unconditional for every client, same "no whitelist gate" reasoning as BugReportClient above --
-- every player gets the Settings panel. Only wires the PANEL's own interactivity here; the
-- KeybindManager restore already happened earlier (see SettingsClient.RestoreSettings' own call
-- site above).
logger:debug("SettingsClient start")
SettingsClient.Start(uiHandles.Settings, uiHandles.Chrome)
logger:debug("SettingsClient end")

-- Unconditional for every client, not just admins -- see FlightController.lua's own header for
-- why: it's purely reactive to a server-set Attribute on each player's own Humanoid, so a non-
-- admin who's simply the TARGET of another player's admin action still needs this running to
-- actually move when granted flight. That is exactly why it (and FlightPhysics beside it) moved out
-- of Client/DevTools/DevMenu/ to Client/Flight/ when the dev tooling was put behind an omittable path: flight
-- is a shipped feature that was misfiled, not tooling.
logger:debug("FlightController start")
FlightController.Start()
logger:debug("FlightController end")

logger:info("Client boot end")
