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
	Sprint/Dash/Slide's own request-firing is NOT resurrected here, since CombatSystem.lua (their only
	server-side handler) is gone -- see Server/Combat/Movement.lua's own header on being left
	deliberately orphaned rather than rewired. AttackInputClient and DefenseClient each bind their OWN
	AnimationManager per life rather than going through that hookup, which is that module's documented
	"construct once, Bind() per respawn" shape and not an inconsistency.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)
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
local ParkourController = require(script.Parent.Parkour.ParkourController)
local RunController = require(script.Parent.Movement.RunController)
local DevMenuClient = require(script.Parent.DevMenu.DevMenuClient)
local MoveEditorClient = require(script.Parent.MoveEditor.MoveEditorClient)
local LiveConsoleClient = require(script.Parent.LiveConsole.LiveConsoleClient)
local FlightController = require(script.Parent.DevMenu.FlightController)
local DefenseClient = require(script.Parent.Defense.DefenseClient)
local AttackInputClient = require(script.Parent.Combat.AttackInputClient)
local CombatFeedbackClient = require(script.Parent.Combat.CombatFeedbackClient)
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
SettingsClient.RestoreSettings()
logger:debug("SettingsClient RestoreSettings end")

-- Announces every new life to the presentation-layer modules that used to bind off
-- Client/Combat/CombatClient.lua's own CharacterAdded handler -- see this file's own header. Covers
-- both the ordinary respawn path and a Studio play-solo start where a character already exists
-- before this line runs.
logger:debug("Character-bind hookup start")
local function bindCharacterPresentation(character: Model): ()
	CombatAnimator.BindCharacter(character)
	MovementVFX.BindCharacter(character)
	RunController.BindCharacter(character)
end
Players.LocalPlayer.CharacterAdded:Connect(bindCharacterPresentation)
if Players.LocalPlayer.Character then
	bindCharacterPresentation(Players.LocalPlayer.Character)
end
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
EmoteWheelClient.Start(uiHandles.EmoteWheel, uiHandles.ClientState)
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

-- Attack input -- the light/heavy strings, the five hotbar slots and the weapon swap. Unconditional
-- for every client, and deliberately AFTER SettingsClient.RestoreSettings above for exactly the same
-- reason DefenseClient is: it reads BasicAttack/HeavyAttack/HotbarSlot1-5/SwapWeapon through
-- KeybindManager, so a player who rebound any of them must have their override live before the first
-- press can reach this. Replaces the deleted TestAttackHarnessClient, whose own header always said a
-- real input layer would.
--
-- Also after UI.Mount() above, though not for a reason of its own: the HUD's ability slots subscribe
-- to this module's OnSlotCooldown at mount time, and a subscription made before Start() is fine (the
-- listener list outlives Start), so this ordering is documented rather than load-bearing.
logger:debug("AttackInputClient start")
AttackInputClient.Start()
logger:debug("AttackInputClient end")

-- Hit presentation -- damage numbers, the outcome banner and the camera shake, driven off the damage
-- layer's Combat_Feedback event. AFTER UI.Mount(), and that IS load-bearing: it is handed the
-- CombatFeedback screen's own handle, which does not exist until UI.Mount() returns.
logger:debug("CombatFeedbackClient start")
CombatFeedbackClient.Start(uiHandles.CombatFeedback)
logger:debug("CombatFeedbackClient end")

logger:debug("DevMenuClient start")
DevMenuClient.Start(uiHandles.DevMenu)
logger:debug("DevMenuClient end")

-- Same whitelist-gated, delayed-authorization shape as DevMenuClient above.
logger:debug("MoveEditorClient start")
MoveEditorClient.Start(uiHandles.MoveEditor)
logger:debug("MoveEditorClient end")

-- Unlike DevMenuClient/MoveEditorClient above, this one binds its input unconditionally for every
-- client -- the real gate is server-side, on Subscribe, fired only once the panel actually opens.
-- See LiveConsoleClient.lua's own header.
logger:debug("LiveConsoleClient start")
LiveConsoleClient.Start(uiHandles.LiveConsole)
logger:debug("LiveConsoleClient end")

-- Unconditional for every client, unlike DevMenuClient above -- the bug report form has no
-- whitelist gate; every player can open and submit it.
logger:debug("BugReportClient start")
BugReportClient.Start(uiHandles.BugReport)
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
SettingsClient.Start(uiHandles.Settings)
logger:debug("SettingsClient end")

-- Unconditional for every client, not just admins -- see FlightController.lua's own header for
-- why: it's purely reactive to a server-set Attribute on each player's own Humanoid, so a non-
-- admin who's simply the TARGET of another player's admin action still needs this running to
-- actually move when granted flight.
logger:debug("FlightController start")
FlightController.Start()
logger:debug("FlightController end")

logger:info("Client boot end")
