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
	each phase, and a hard error if UI.Mount() doesn't hand back what CombatClient.Start() needs --
	so a broken boot shows up immediately in Studio Output instead of silently doing nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)

local UI = require(script.Parent.UI)
local StartMenuClient = require(script.Parent.StartMenu.StartMenuClient)
local LoadingClient = require(script.Parent.Loading.LoadingClient)
local OnboardingClient = require(script.Parent.Onboarding.OnboardingClient)
local CombatClient = require(script.Parent.Combat.CombatClient)
local ShiftLockCamera = require(script.Parent.Camera.ShiftLockCamera)
local FlightCamera = require(script.Parent.Camera.FlightCamera)
local CameraShake = require(script.Parent.FX.CameraShake)
local FOVOffset = require(script.Parent.FX.FOVOffset)
local CameraOffsetComposer = require(script.Parent.FX.CameraOffsetComposer)
local DevMenuClient = require(script.Parent.DevMenu.DevMenuClient)
local FlightController = require(script.Parent.DevMenu.FlightController)
local BugReportClient = require(script.Parent.BugReport.BugReportClient)
local AnnouncementClient = require(script.Parent.Announcement.AnnouncementClient)

local logger = Logger.scope("Main")

logger:info("Client boot start")

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
-- See LoadingClient.lua's own header for why this always runs (unlike OnboardingClient.Run() below,
-- which skips for returning players).
logger:debug("LoadingClient run start")
LoadingClient.Run()
logger:debug("LoadingClient run end")

-- Runs BEFORE everything else in this file, including UI.Mount() -- first-time-player onboarding
-- (Server/Systems/CharacterCreationSystem.lua's GetOnboardingState/Finalize) owns this session's
-- first Player:LoadCharacter() call for every player (Players.CharacterAutoLoads = false (default.project.json)), so
-- nothing below this line can assume a character (or a finished profile) exists until this returns.
-- OnboardingClient.Run() returns immediately for a returning player (NeedsOnboarding = false) and
-- otherwise blocks until chargen's own CharacterCreation_Finalize call succeeds -- see that module's
-- own header for why it mounts and tears down its OWN temporary Fusion scope rather than using
-- UI.Mount()'s session-long one.
logger:debug("OnboardingClient run start")
OnboardingClient.Run()
logger:debug("OnboardingClient run end")

logger:debug("UI mount start")
local uiHandles = UI.Mount()
logger:debug("UI mount end")

if not uiHandles.CombatFeedback then
	logger:error("UI.Mount() returned no CombatFeedback handle -- CombatClient cannot start")
	return
end

logger:debug("CombatClient start")
CombatClient.Start(uiHandles.CombatFeedback)
logger:debug("CombatClient end")

-- Before ShiftLockCamera/FlightCamera/CameraShake below: FOVOffset is the single canonical writer
-- of camera.FieldOfView that SwingEffect (used inside CombatClient, already started above) and
-- FlightCamera (started below) both compose through -- see that module's own header.
logger:debug("FOVOffset start")
FOVOffset.Start()
logger:debug("FOVOffset end")

-- Same reasoning as FOVOffset above, for Humanoid.CameraOffset instead of FieldOfView -- the single
-- canonical writer ShiftLockCamera/FlightCamera below both compose through. See that module's header.
logger:debug("CameraOffsetComposer start")
CameraOffsetComposer.Start()
logger:debug("CameraOffsetComposer end")

logger:debug("ShiftLockCamera start")
ShiftLockCamera.Start(uiHandles.CombatFeedback.ShiftLockEngaged)
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

logger:debug("DevMenuClient start")
DevMenuClient.Start(uiHandles.DevMenu)
logger:debug("DevMenuClient end")

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

-- Unconditional for every client, not just admins -- see FlightController.lua's own header for
-- why: it's purely reactive to a server-set Attribute on each player's own Humanoid, so a non-
-- admin who's simply the TARGET of another player's admin action still needs this running to
-- actually move when granted flight.
logger:debug("FlightController start")
FlightController.Start()
logger:debug("FlightController end")

logger:info("Client boot end")
