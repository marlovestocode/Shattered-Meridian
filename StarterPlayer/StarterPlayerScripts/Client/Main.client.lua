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
local CombatClient = require(script.Parent.Combat.CombatClient)
local ShiftLockCamera = require(script.Parent.Camera.ShiftLockCamera)
local FlightCamera = require(script.Parent.Camera.FlightCamera)
local CameraShake = require(script.Parent.FX.CameraShake)
local FOVOffset = require(script.Parent.FX.FOVOffset)
local CameraOffsetComposer = require(script.Parent.FX.CameraOffsetComposer)
local DevMenuClient = require(script.Parent.DevMenu.DevMenuClient)
local FlightController = require(script.Parent.DevMenu.FlightController)
local BugReportClient = require(script.Parent.BugReport.BugReportClient)

local logger = Logger.scope("Main")

logger:info("Client boot start")

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

-- Unconditional for every client, not just admins -- see FlightController.lua's own header for
-- why: it's purely reactive to a server-set Attribute on each player's own Humanoid, so a non-
-- admin who's simply the TARGET of another player's admin action still needs this running to
-- actually move when granted flight.
logger:debug("FlightController start")
FlightController.Start()
logger:debug("FlightController end")

logger:info("Client boot end")
