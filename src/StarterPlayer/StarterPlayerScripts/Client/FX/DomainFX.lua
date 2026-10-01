--!strict
--[[
	DomainFX.lua

	Owns: drawing every live realm on this client, and the three things a realm does to the LOCAL player's
	own experience: the colour grade while they stand under its law, the predicted wall of a Barred edge,
	and applying a Pull/Push impulse the server handed them. Everything arrives on Domain_State
	(Server/Combat/Domain/DomainSystem.lua); nothing here reaches the server except the one "send me every
	live realm" request at start.

	THE SHELL IS THE BOUNDARY. One client-local part per realm, shaped and sized from the same numbers the
	server's DomainGeometry tests against (a ball, an upright cylinder, a box square to the realm's yaw), so
	the edge a player sees is the edge the server enforces. It grows from nothing across the realm's
	activation and folds back across its ending, eased (FXConstants.Domain.UnfurlEasingStyle) on the phase
	times the server stated -- on the shared clock, so every client unfurls a realm in step. A FollowOwner
	realm is recentred on its owner's root every frame (the view's Offset, fixed in world space).

	THE LOOK is the domain move's own Presentation (MovePresentationTypes' Domain moments), falling back to
	FXConstants.Domain: DomainActive's CoreColor tints the grade, its GlowColor is the shell (whose ForceField
	rim draws the edge).

	FRAME COST, which is the constraint this module is built around (2026-09-30: the first version tanked
	every client standing in a realm). What costs is the shell's SCREEN COVERAGE, so: no Highlight on it
	(an extra full-adornee outline pass), no per-frame writes that change nothing (a settled Fixed realm
	writes zero properties a frame), and the look is picked by how much of the view the realm spans
	(DomainGeometry.AngularRadius against the camera's field of view, FXConstants.Domain's three looks):
	the animated ForceField only while it is small on screen, a plain near-clear surface once it fills the
	view from outside, hidden from inside except at the edge. The second pass fixed the first's question --
	it asked "is the camera inside", and a 120-stud realm fills the screen of a camera well OUTSIDE it,
	which is where every third-person camera behind a body near the edge sits. Every one of those tests runs
	against the realm's CURRENT, unfurled size, not its final one.
	The four moments' cues play off the messages that mark them -- Open (DomainOpen), the Phase to Active
	(DomainActive), the Phase to Ending (DomainClose), each Pulse (DomainPulse, at every body it reached) --
	through the same CombatAudio / ImpactSparks / MovePresentation paths every other move cue uses, with the
	camera parts only for a participant (the owner, or a body the realm governs) and Audience honoured.

	THE ESTABLISHED AND FOLD CUES RUN ON THE REALM'S CLOCK, NOT THE PHASE MESSAGE (2026-09-30). A realm's
	phase times are known the moment it opens (PhaseEndsAt, on the shared server clock), and the shell is
	drawn from exactly those times -- so a cue hung on the message arriving fired a network hop AFTER the
	boundary was drawn complete (and an eased unfurl reads as formed before its last frame, so the sound
	felt later still). DomainActive is now scheduled at the end of Activating, and DomainClose at the end of
	Active, by that same clock; the moment's sparks, camera and template land on it, and its SOUND lands
	where the cue's SoundDelay puts it (negative = a lead, which is only possible because the moment is
	known ahead -- Shared/Combat/MovePresentationTypes' SOUND TIMING). The message stays the authority: a
	collapse or erosion that brings the real moment forward cancels the schedule and plays what has not
	played yet, immediately.

	LOOPS (a cue's Loop = "RestOfMove", MovePresentationTypes' SOUND LOOPS). A realm cue that loops its own
	sound -- the unfurl's, the established, the fold's -- repeats from its moment until the realm's last
	instant, the end of the fold (known once the fold begins), its FadeOut landing on that instant; a realm
	dropped earlier cuts its loops at once, each sinking over its own fade. The pulse is an instant and does not
	loop.

	THE GRADE follows the Humanoid's own DomainGovernor attribute (Shared/Domain/DomainRules.lua): the
	server's answer to "whose law am I under", never this client's geometry. One ColorCorrectionEffect,
	eased in and out.

	THE VICTIM'S VIEW. A body the realm governs that is not its owner is its VICTIM (the same DomainGovernor
	answer as the grade), and to a victim the barrier is a wall of solid black: the realm has closed over
	them. That is a second part per realm, the INTERIOR -- the shell's own shape inside out (a SpecialMesh at
	a negative scale), because the engine never draws a part's faces from inside it, so the shell itself
	cannot be seen from where a victim stands. Unlit black (FXConstants.Domain.VictimInterior*) so no light,
	grade or fog greys it. Only ever drawn on a victim's own client; everyone else, the owner included, sees
	the shell as above. Victimhood is latched through the realm's Ending (the law lifts the moment the
	realm starts to fold, but the dark folds away with the boundary rather than blinking out), and dropped
	the moment an Active realm stops governing the body (a member who walked out and was released).
	While a victim sees the interior, the shell is hidden -- the black is the edge. Opaque, so it costs less
	than the blended shell it replaces, and it hides the world beyond the edge.

	THE PREDICTED WALL. A Barred edge is enforced by the server as a correction (a body set back across the
	line); this client draws the same wall for its own body so an honest player meets a wall instead of a
	correction. Held IN: the realm governs this body and its exit is Barred. Held OUT: its entry is Barred and
	this body was outside when the realm was established (a body inside then is a founding member whose
	membership may simply not have replicated yet -- it must never be pushed out in that gap). The owner is
	never held. Presentation-grade only: the server's correction is the authority either way.

	Does not own: anything a realm decides (DomainSystem), the strikes' shots (ProjectileFX draws them, as
	any shot), or the realm's HUD text.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local SlowWatch = require(ReplicatedStorage.Shared.SlowWatch)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)

local CombatAudio = require(script.Parent.CombatAudio)
local ImpactSparks = require(script.Parent.ImpactSparks)
local MovePresentation = require(script.Parent.MovePresentation)
local KnockbackClient = require(script.Parent.Parent.Combat.KnockbackClient)

type Cue = MovePresentationTypes.Cue
type DomainMessage = DomainTypes.DomainMessage
type DomainView = DomainTypes.DomainView

local logger = Logger.scope("DomainFX")

local DomainFX = {}

local CONFIG = FXConstants.Domain
local FOLDER_NAME = "DomainFX"

-- Which of FXConstants.Domain's three looks the shell wears (see this file's header, FRAME COST).
type ShellLook = "Far" | "Near" | "Inside"

-- One scheduled domain moment. `Token` names the current schedule: a timer from an older one finds it changed
-- and does nothing. The visual channels and the sound are placed separately (a sound can lead its moment).
type CueState = { Token: number, VisualsDone: boolean, SoundDone: boolean }

type Realm = {
	View: DomainView,
	Shell: BasePart,
	Core: Color3,
	Glow: Color3,
	-- What was last written to the shell, so a frame that changes nothing writes nothing (see onHeartbeat).
	LastSize: Vector3?,
	LastPose: CFrame?,
	LastTransparency: number?,
	-- The look the shell wore last frame; nil until its first frame.
	Look: ShellLook?,
	-- The inside-out black wall a VICTIM sees (this file's header, THE VICTIM'S VIEW), and whether it is
	-- showing. Sized and posed with the shell.
	Interior: BasePart,
	InteriorShown: boolean,
	-- Whether the local body is this realm's victim -- latched through Ending.
	Victim: boolean,
	-- Whether the local body was outside when the realm was established (the predicted Barred entry's
	-- precondition -- see this file's header). nil until it is established.
	OutsideAtEstablish: boolean?,
	-- Per moment (DomainActive, DomainClose): what has played of its cue and which schedule is current.
	Cues: { [string]: CueState },
	-- The looping cue sounds (a cue's Loop = "RestOfMove") this realm has running: ended with its fold, or at
	-- once if it is dropped first.
	Loops: { CombatAudio.CueLoop },
}

local realms: { [string]: Realm } = {}
local started = false
local trove = Trove.New()
local folder: Folder? = nil
local grade: ColorCorrectionEffect? = nil
-- 0..1 -- how far the grade is eased in, and which realm's tint it is easing toward.
local gradeBlend = 0
local gradeColor = CONFIG.CoreColor

local localPlayer = Players.LocalPlayer

-- Helpers ---------------------------------------------------------------------------------------------------

local function ensureFolder(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Workspace
	folder = created
	return created
end

local function ensureGrade(): ColorCorrectionEffect
	local existing = grade
	if existing and existing.Parent then
		return existing
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "DomainGrade"
	effect.Enabled = false
	effect.Parent = Lighting
	grade = effect
	return effect
end

local function localCharacter(): Model?
	return if localPlayer then localPlayer.Character else nil
end

local function localHumanoid(): Humanoid?
	local character = localCharacter()
	return if character then CharacterUtil.HumanoidOf(character) else nil
end

local function centerOf(view: DomainView): Vector3
	if view.Anchor == "FollowOwner" and view.Owner then
		local root = CharacterUtil.RootOf(view.Owner)
		if root then
			return root.Position + view.Offset
		end
	end
	return view.Center
end

local function boundaryOf(view: DomainView): DomainGeometry.Boundary
	return {
		Shape = view.Shape,
		Center = centerOf(view),
		Yaw = view.Yaw,
		Radius = view.Radius,
		Height = view.Height,
	}
end

-- Whether the local player takes part in this realm: its owner, or a body it governs.
local function isParticipant(view: DomainView): boolean
	local character = localCharacter()
	if character ~= nil and view.Owner == character then
		return true
	end
	return DomainRules.GovernorOf(localHumanoid()) == view.Id
end

local function cueFor(view: DomainView, moment: string): Cue?
	return MovePresentation.CueFor(view.MoveId, moment)
end

-- Ends a loop with the realm: its FadeOut starts that long before `endsAt` (a server-clock time), so the fade
-- lands on the realm's last instant.
local function scheduleLoopStop(loop: CombatAudio.CueLoop, endsAt: number): ()
	local wait = math.max(endsAt - DomainRules.ServerNow(), 0) - loop.FadeOutSeconds
	if wait <= 0 then
		loop.Stop()
	else
		task.delay(wait, loop.Stop)
	end
end

-- Starts a cue's looping sound for the rest of the realm (this file's header, LOOPS). Its end is the end of the
-- fold, known only once the fold begins (onPhase): a loop that starts earlier is scheduled then, one that starts
-- during the fold is scheduled now.
local function startRealmLoop(view: DomainView, cue: Cue, position: Vector3): ()
	local realm = realms[view.Id]
	if realm == nil then
		return
	end
	local loop = CombatAudio.PlayCueLoop(cue, position)
	if loop == nil then
		return
	end
	table.insert(realm.Loops, loop)
	if view.Phase == "Ending" and view.PhaseEndsAt > 0 then
		scheduleLoopStop(loop, view.PhaseEndsAt)
	end
end

local function playPointCue(view: DomainView, moment: string, position: Vector3, defaultSparks: string?): ()
	local cue = cueFor(view, moment)
	local participant = isParticipant(view)
	if cue and not MovePresentation.Reaches(cue, participant) then
		return
	end
	if MovePresentation.LoopsToEnd(cue) then
		startRealmLoop(view, cue :: Cue, position)
	else
		CombatAudio.PlayCue(cue, position)
	end
	local preset, overrides = MovePresentation.Sparks(cue, defaultSparks)
	if preset then
		ImpactSparks.Play(preset, position, overrides)
	end
	if participant then
		MovePresentation.PlayCamera(cue)
	end
	MovePresentation.PlayTemplate(cue, CFrame.new(position), view.MoveId, moment)
end

-- Seconds until a server-clock time, floored at now.
local function secondsUntil(serverTime: number): number
	return math.max(serverTime - DomainRules.ServerNow(), 0)
end

-- Plays one of the realm's SCHEDULED moments (DomainActive, DomainClose) -- this file's header, THE
-- ESTABLISHED AND FOLD CUES. `ahead` is how many seconds away the moment still is (nil: it is now). Its
-- sparks, camera and template land on the moment; its sound lands SoundDelay from it, a lead included.
-- Calling again for the same moment re-places whatever has not played yet: a later call cancels the earlier
-- schedule, and a channel that has already played is not played twice.
local function cueMoment(realm: Realm, moment: string, ahead: number?): ()
	local view = realm.View
	local cue = cueFor(view, moment)
	local state = realm.Cues[moment]
	if state == nil then
		state = { Token = 0, VisualsDone = false, SoundDone = false }
		realm.Cues[moment] = state
	end
	if cue == nil then
		state.VisualsDone = true
		state.SoundDone = true
		return
	end
	if state.VisualsDone and state.SoundDone then
		return
	end
	state.Token += 1
	local token = state.Token

	-- Audience is judged when the cue FIRES: a body only becomes a participant once the realm governs it.
	local function heard(): boolean
		return MovePresentation.Reaches(cue, isParticipant(view))
	end
	local function visuals(): ()
		if state.VisualsDone then
			return
		end
		state.VisualsDone = true
		if not heard() then
			return
		end
		local position = centerOf(view)
		local preset, overrides = MovePresentation.Sparks(cue, nil)
		if preset then
			ImpactSparks.Play(preset, position, overrides)
		end
		if isParticipant(view) then
			MovePresentation.PlayCamera(cue)
		end
		MovePresentation.PlayTemplate(cue, CFrame.new(position), view.MoveId, moment)
	end
	local function sound(): ()
		if state.SoundDone then
			return
		end
		state.SoundDone = true
		if heard() then
			if MovePresentation.LoopsToEnd(cue) then
				startRealmLoop(view, cue, centerOf(view))
			else
				CombatAudio.PlayCueNow(cue, centerOf(view))
			end
		end
	end
	local function after(seconds: number, run: () -> ()): ()
		if seconds <= 0 then
			run()
			return
		end
		task.delay(seconds, function()
			if realms[view.Id] == realm and state.Token == token then
				run()
			end
		end)
	end

	local until_ = ahead or 0
	after(until_, visuals)
	after(until_ + MovePresentation.SoundDelay(cue), sound)
end

-- Places the moment this realm's current phase is heading for, from the times the server stated: the end of
-- Activating is the established moment, the end of Active is the fold. Called when a realm becomes known and
-- whenever its phase times change.
local function scheduleKnownMoments(realm: Realm): ()
	local view = realm.View
	if view.PhaseEndsAt <= 0 then
		return
	end
	if view.Phase == "Activating" then
		cueMoment(realm, "DomainActive", secondsUntil(view.PhaseEndsAt))
	elseif view.Phase == "Active" then
		cueMoment(realm, "DomainClose", secondsUntil(view.PhaseEndsAt))
	end
end

-- The shell -------------------------------------------------------------------------------------------------

local function shellShape(view: DomainView): Enum.PartType
	if view.Shape == "Sphere" then
		return Enum.PartType.Ball
	elseif view.Shape == "Cylinder" then
		return Enum.PartType.Cylinder
	end
	return Enum.PartType.Block
end

-- The shell's full size and orientation for the realm (a Cylinder part's axis is its X, so it is turned
-- upright).
local function shellPose(view: DomainView, center: Vector3, scale: number): (Vector3, CFrame)
	local diameter = view.Radius * 2 * scale
	local height = view.Height * scale
	if view.Shape == "Sphere" then
		return Vector3.new(diameter, diameter, diameter), CFrame.new(center)
	elseif view.Shape == "Cylinder" then
		return Vector3.new(height, diameter, diameter), CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2)
	end
	return Vector3.new(diameter, height, diameter), CFrame.new(center) * CFrame.Angles(0, view.Yaw, 0)
end

-- The inside-out black wall a victim sees (this file's header, THE VICTIM'S VIEW). The part carries the
-- shell's size and pose; its SpecialMesh fills it at scale -1 on every axis, which mirrors the geometry
-- and flips which faces point outward -- so it draws from INSIDE and is back-face culled from outside.
-- A SpecialMesh Cylinder lies along X exactly as a Cylinder part does, so shellPose's turn fits it too.
-- Hidden (Transparency 1, culled) until the local body is this realm's victim.
local function buildInterior(view: DomainView): BasePart
	local interior = Instance.new("Part")
	interior.Name = `RealmInterior_{view.Id}`
	interior.Anchored = true
	interior.CanCollide = false
	interior.CanQuery = false
	interior.CanTouch = false
	interior.CastShadow = false
	interior.Material = CONFIG.VictimInteriorMaterial
	interior.Color = CONFIG.VictimInteriorColor
	interior.Transparency = 1
	interior.Size = Vector3.one * 0.1

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = if view.Shape == "Sphere"
		then Enum.MeshType.Sphere
		elseif view.Shape == "Cylinder" then Enum.MeshType.Cylinder
		else Enum.MeshType.Brick
	mesh.Scale = -Vector3.one
	mesh.Parent = interior

	interior.Parent = ensureFolder()
	return interior
end

-- `activeCue` overrides the catalogue's DomainActive cue -- the Move Editor's preview of an unsaved draft.
local function buildRealm(view: DomainView, activeCue: Cue?): Realm
	local active = activeCue or cueFor(view, "DomainActive")
	local core = MovePresentation.Color(if active then active.CoreColor else nil, CONFIG.CoreColor) or CONFIG.CoreColor
	local glow = MovePresentation.Color(if active then active.GlowColor else nil, CONFIG.GlowColor) or CONFIG.GlowColor

	-- NO HIGHLIGHT, deliberately (it used to have one, and it tanked every client's frame rate inside a
	-- realm): a Highlight re-renders its whole adornee in extra outline passes, and this adornee fills the
	-- screen. The ForceField material's own rim glow already draws the edge, in the glow colour.
	local shell = Instance.new("Part")
	shell.Name = `Realm_{view.Id}`
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CanTouch = false
	shell.CastShadow = false
	shell.Shape = shellShape(view)
	shell.Material = CONFIG.ShellMaterial
	shell.Color = glow
	shell.Transparency = 1
	shell.Size = Vector3.one * 0.1

	shell.Parent = ensureFolder()
	return {
		View = view,
		Shell = shell,
		Core = core,
		Glow = glow,
		LastSize = nil,
		LastPose = nil,
		LastTransparency = nil,
		Look = nil,
		Interior = buildInterior(view),
		InteriorShown = false,
		Victim = false,
		OutsideAtEstablish = nil,
		Cues = {},
		Loops = {},
	}
end

local function dropRealm(id: string): ()
	local realm = realms[id]
	if realm then
		-- A realm dropped before its fold finished (a collapse, a replaced preview) cuts its loops now, each
		-- sinking over its own FadeOut.
		for _, loop in realm.Loops do
			loop.Stop()
		end
		realm.Shell:Destroy()
		realm.Interior:Destroy()
		realms[id] = nil
	end
end

-- How unfurled the realm is right now, 0..1, from the phase times the server stated.
local function unfurlOf(view: DomainView, serverNow: number): number
	local span = view.PhaseEndsAt - view.PhaseStartedAt
	local progress = if span > 0 then math.clamp((serverNow - view.PhaseStartedAt) / span, 0, 1) else 1
	if view.Phase == "Activating" then
		return TweenService:GetValue(progress, CONFIG.UnfurlEasingStyle, Enum.EasingDirection.Out)
	elseif view.Phase == "Ending" then
		return 1 - TweenService:GetValue(progress, CONFIG.UnfurlEasingStyle, Enum.EasingDirection.In)
	elseif view.Phase == "Active" then
		return 1
	end
	return 0
end

-- Messages --------------------------------------------------------------------------------------------------

local function noteEstablished(realm: Realm): ()
	local character = localCharacter()
	local root = if character then CharacterUtil.RootOf(character) else nil
	realm.OutsideAtEstablish = root == nil or not DomainGeometry.Contains(boundaryOf(realm.View), root.Position)
end

local function onOpen(view: DomainView, playCue: boolean): ()
	dropRealm(view.Id)
	local realm = buildRealm(view)
	realms[view.Id] = realm
	if view.Phase == "Active" then
		noteEstablished(realm)
	end
	if playCue and view.Phase == "Activating" then
		playPointCue(view, "DomainOpen", centerOf(view), nil)
	end
	scheduleKnownMoments(realm)
end

local function onPhase(message: DomainMessage): ()
	local realm = realms[message.Id or ""]
	if realm == nil then
		return
	end
	local view = realm.View
	local previous = view.Phase
	view.Phase = message.Phase or view.Phase
	view.PhaseStartedAt = message.PhaseStartedAt or view.PhaseStartedAt
	view.PhaseEndsAt = message.PhaseEndsAt or view.PhaseEndsAt
	if previous == view.Phase then
		-- The same phase with a new end (an erosion shortened it): re-place the moment it is heading for.
		scheduleKnownMoments(realm)
		return
	end
	if view.Phase == "Active" then
		noteEstablished(realm)
		-- The established moment is NOW if its schedule has not already played it (a realm joined mid-phase,
		-- or an Activating that ended early); then the fold is placed from this phase's end.
		cueMoment(realm, "DomainActive", nil)
		scheduleKnownMoments(realm)
	elseif view.Phase == "Ending" then
		cueMoment(realm, "DomainClose", nil)
		-- The fold's end is the realm's last instant: every loop running now ends with it.
		if view.PhaseEndsAt > 0 then
			for _, loop in realm.Loops do
				scheduleLoopStop(loop, view.PhaseEndsAt)
			end
		end
	elseif view.Phase == "Finished" then
		dropRealm(view.Id)
	end
end

local function onPulse(message: DomainMessage): ()
	local realm = realms[message.Id or ""]
	local targets = message.Targets
	if realm == nil or targets == nil then
		return
	end
	-- Bounded per pulse and by distance: a realm striking thirty bodies at once must not be thirty bursts,
	-- thirty sounds and thirty templates on every client in the server.
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else nil
	local played = 0
	for _, target in targets do
		if played >= CONFIG.MaxPulseBursts then
			break
		end
		local root = if typeof(target) == "Instance" and target:IsA("Model") then CharacterUtil.RootOf(target) else nil
		if root and (cameraPosition == nil or (root.Position - cameraPosition).Magnitude <= CONFIG.PulseRangeStuds) then
			playPointCue(realm.View, "DomainPulse", root.Position, CONFIG.PulseSparks)
			played += 1
		end
	end
end

local function onMessage(message: DomainMessage): ()
	if typeof(message) ~= "table" then
		return
	end
	local kind = message.Kind
	if kind == "Open" and message.Domain then
		onOpen(message.Domain, true)
	elseif kind == "Snapshot" and message.Domains then
		for _, view in message.Domains do
			if realms[view.Id] == nil then
				onOpen(view, false)
			end
		end
	elseif kind == "Phase" then
		onPhase(message)
	elseif kind == "Clash" then
		local realm = realms[message.Id or ""]
		if realm and message.ClashState then
			realm.View.ClashState = message.ClashState
		end
	elseif kind == "Pulse" then
		onPulse(message)
	elseif kind == "Impulse" and typeof(message.Velocity) == "Vector3" then
		-- The server's Pull/Push for this body, applied through the same client path a knockback push uses.
		KnockbackClient.Push(message.Velocity, 0)
	end
end

-- The frame -------------------------------------------------------------------------------------------------

-- Holds the local body on its side of a Barred edge (this file's header, THE PREDICTED WALL).
local function predictWall(realm: Realm, humanoid: Humanoid, root: BasePart, character: Model): ()
	local view = realm.View
	if view.Phase ~= "Active" or view.Owner == character then
		return
	end
	local boundary = boundaryOf(view)
	local margin = CONFIG.PredictedMarginStuds
	local depth = DomainGeometry.Depth(boundary, root.Position)
	local target: Vector3? = nil
	if view.ExitRule == "Barred" and DomainRules.GovernorOf(humanoid) == view.Id and depth < 0 then
		target = DomainGeometry.ClampInside(boundary, root.Position, margin)
	elseif
		view.EntryRule == "Barred"
		and realm.OutsideAtEstablish == true
		and DomainRules.GovernorOf(humanoid) ~= view.Id
		and depth > 0
	then
		target = DomainGeometry.ClampOutside(boundary, root.Position, margin)
	end
	if target == nil then
		return
	end
	local pushBack = target - root.Position
	if pushBack.Magnitude < 1e-3 then
		return
	end
	-- Keep the facing; drop only the velocity carrying the body through the wall.
	root.CFrame = root.CFrame.Rotation + target
	local normal = pushBack.Unit
	local velocity = root.AssemblyLinearVelocity
	local into = velocity:Dot(normal)
	if into < 0 then
		root.AssemblyLinearVelocity = velocity - normal * into
	end
end

-- Which look the shell should wear for a camera at `cameraPosition` (FXConstants.Domain's three looks),
-- against the realm's CURRENT boundary `scaled`, and the camera's depth inside it. A realm the camera is
-- outside is Near once its bounding sphere spans ShellFillEnter of the half field of view, and stays Near
-- until it drops below ShellFillExit (a camera that just left the inside counts as already Near).
local function lookFor(
	previous: ShellLook?,
	scaled: DomainGeometry.Boundary,
	cameraPosition: Vector3?,
	halfFov: number
): (ShellLook, number)
	if cameraPosition == nil then
		return "Far", -math.huge
	end
	local depth = DomainGeometry.Depth(scaled, cameraPosition)
	if depth >= 0 then
		return "Inside", depth
	end
	local filling = previous == "Near" or previous == "Inside"
	local threshold = halfFov * (if filling then CONFIG.ShellFillExit else CONFIG.ShellFillEnter)
	local look: ShellLook = if DomainGeometry.AngularRadius(scaled, cameraPosition) >= threshold then "Near" else "Far"
	return look, depth
end

-- Last values written to the grade, so a steady grade (fully in, or fully out) costs no property writes.
local writtenBlend = -1
local writtenColor: Color3? = nil

-- ONE FRAME. The shell is written only when something about it actually changed: a Fixed realm that has
-- finished unfurling writes nothing at all per frame (a FollowOwner one writes its CFrame). Rewriting a
-- screen-filling part's Size every frame forced its geometry to rebuild every frame, which is part of what
-- made a realm unplayable to stand in.
local function onHeartbeat(deltaTime: number): ()
	if next(realms) == nil and writtenBlend <= 0 then
		return
	end
	debug.profilebegin("DomainFX")
	local serverNow = DomainRules.ServerNow()
	local character = localCharacter()
	local humanoid = localHumanoid()
	local root = if character then CharacterUtil.RootOf(character) else nil
	local governor = DomainRules.GovernorOf(humanoid, serverNow)
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else nil
	-- Camera.FieldOfView is the VERTICAL field of view, in degrees.
	local halfFov = math.rad(if camera then camera.FieldOfView else 70) / 2

	local targetBlend = 0
	for id, realm in realms do
		local view = realm.View
		local scale = unfurlOf(view, serverNow)
		if view.Phase == "Ending" and scale <= 0 then
			dropRealm(id)
			continue
		end
		local center = centerOf(view)
		local drawnScale = math.max(scale, 0.01)
		local size, pose = shellPose(view, center, drawnScale)
		local shell = realm.Shell
		local interior = realm.Interior
		if realm.LastSize ~= size then
			realm.LastSize = size
			shell.Size = size
			interior.Size = size
		end
		if realm.LastPose ~= pose then
			realm.LastPose = pose
			shell.CFrame = pose
			interior.CFrame = pose
		end

		-- THE VICTIM'S VIEW (this file's header): governed and not the owner, on the server's word; held
		-- through the fold; let go the moment an Active realm stops governing this body.
		if view.Phase == "Active" then
			realm.Victim = governor == id and character ~= nil and view.Owner ~= character
		elseif view.Phase ~= "Ending" then
			realm.Victim = false
		end
		if realm.InteriorShown ~= realm.Victim then
			realm.InteriorShown = realm.Victim
			interior.Transparency = if realm.Victim then 0 else 1
		end

		-- The CAMERA decides the look, not the body, and by how much of the view the shell covers, not by
		-- which side of the edge it is on (this file's header, FRAME COST). Tested against the shell as drawn
		-- this frame -- the unfurled size -- so a realm still growing is seen growing from inside its final
		-- radius, instead of being judged by an edge it has not reached yet. Inside, the shell is HIDDEN (a
		-- fully transparent part is culled -- zero draw cost) except within EdgeRevealStuds of the edge,
		-- where it fades in so a player about to meet the boundary can see it. The grade is what says "you
		-- are inside"; a screen-filling surface saying it too was pure cost.
		local drawn = DomainGeometry.Scaled(boundaryOf(view), drawnScale)
		local look, cameraDepth = lookFor(realm.Look, drawn, cameraPosition, halfFov)
		local previousLook = realm.Look
		if previousLook ~= look then
			realm.Look = look
			-- Near and Inside share the plain material; only a change to or from Far swaps it.
			if previousLook == nil or (previousLook == "Far") ~= (look == "Far") then
				shell.Material = if look == "Far" then CONFIG.ShellMaterial else CONFIG.ShellPlainMaterial
			end
		end
		local reveal = 1
		if look == "Inside" then
			reveal = math.clamp(1 - cameraDepth / CONFIG.EdgeRevealStuds, 0, 1)
		end
		local base = if look == "Inside"
			then CONFIG.ShellInsideTransparency
			elseif look == "Near" then CONFIG.ShellNearTransparency
			else CONFIG.ShellTransparency
		-- Faded with the unfurl, so the shell's arrival and departure read as one motion. Quantised, so a
		-- body drifting near the edge is a handful of writes, not one a frame.
		local transparency = 1 - (1 - base) * scale * reveal
		transparency = math.min(math.round(transparency / 0.02) * 0.02, 1)
		-- A victim's edge is the black interior; the shell over it would only be a second, blended layer.
		if realm.Victim then
			transparency = 1
		end
		local last = realm.LastTransparency
		if last == nil or math.abs(last - transparency) > 1e-3 then
			realm.LastTransparency = transparency
			shell.Transparency = transparency
		end

		if governor == id and view.Phase == "Active" then
			targetBlend = 1
			gradeColor = realm.Core
		end
		if humanoid and root and character then
			predictWall(realm, humanoid, root, character)
		end
	end

	-- The grade eases toward where it should be, whatever the frame rate.
	local fade = CONFIG.GradeFadeSeconds
	local step = if fade > 0 then deltaTime / fade else 1
	if gradeBlend < targetBlend then
		gradeBlend = math.min(gradeBlend + step, targetBlend)
	elseif gradeBlend > targetBlend then
		gradeBlend = math.max(gradeBlend - step, targetBlend)
	end
	if gradeBlend ~= writtenBlend or gradeColor ~= writtenColor then
		writtenBlend = gradeBlend
		writtenColor = gradeColor
		if gradeBlend > 0 or grade ~= nil then
			local effect = ensureGrade()
			effect.Enabled = gradeBlend > 0
			effect.TintColor = Color3.new(1, 1, 1):Lerp(gradeColor, gradeBlend * CONFIG.InsideTintBlend)
			effect.Saturation = CONFIG.InsideSaturation * gradeBlend
			effect.Contrast = CONFIG.InsideContrast * gradeBlend
		end
	end
	debug.profileend()
end

-- Boot ------------------------------------------------------------------------------------------------------

function DomainFX.Start(): ()
	if started then
		return
	end
	started = true
	local stateRemote = NetworkBridge.GetRemoteEvent(DomainConstants.Network.RemoteNames.State)
	-- Watched (Shared/SlowWatch.lua): a realm's open, establish, pulse and close each land here once, and each
	-- builds or cues something (a shell, a template, sounds, sparks) -- the moments a realm hitches on.
	trove:Connect(
		stateRemote.OnClientEvent,
		SlowWatch.Handler(logger, "DomainFX.onMessage", function(message: DomainMessage)
			local ok, err = pcall(onMessage, message)
			if not ok then
				logger:warn("A realm message could not be applied", { errorMessage = tostring(err) })
			end
		end)
	)
	trove:Connect(RunService.Heartbeat, onHeartbeat)
	-- Realms already up when this client joined.
	NetworkBridge.GetRemoteEvent(DomainConstants.Network.RemoteNames.Request):FireServer()
end

-- THE MOVE EDITOR'S PREVIEW of one Realm moment for an unsaved draft (Client/DevTools/MoveEditor/
-- PresentationPreview.lua): the moment's cue through the same point-cue path a live realm uses, and -- for
-- the three shell moments -- a local realm drawn with the draft's own colours, unfurling, holding and folding
-- on a short scripted clock. Local only; nothing reaches the server.
local PREVIEW_ID = "Preview"
local PREVIEW_HOLD_SECONDS = 1.5
-- How long a looping cue previews before it is stopped (a preview has no real realm to end it).
local PREVIEW_LOOP_SECONDS = 2.5
local previewSerial = 0

function DomainFX.Preview(
	presentation: MovePresentationTypes.Presentation?,
	spec: DomainTypes.DomainSpec,
	moment: string,
	origin: CFrame
): ()
	local look = origin.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local forward = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.new(0, 0, -1)
	local center = origin.Position + forward * spec.CenterForward
	local cue = MovePresentation.CueFrom(presentation, moment)

	local position = if moment == "DomainPulse" then origin.Position + forward * 6 else center
	if MovePresentation.LoopsToEnd(cue) then
		local loop = CombatAudio.PlayCueLoop(cue, position)
		if loop then
			task.delay(PREVIEW_LOOP_SECONDS, loop.Stop)
		end
	else
		CombatAudio.PlayCue(cue, position)
	end
	local preset, overrides = MovePresentation.Sparks(cue, if moment == "DomainPulse" then CONFIG.PulseSparks else nil)
	if preset then
		ImpactSparks.Play(preset, position, overrides)
	end
	MovePresentation.PlayCamera(cue)
	MovePresentation.PlayTemplate(cue, CFrame.new(position), nil, moment)
	if moment == "DomainPulse" then
		return
	end

	previewSerial += 1
	local serial = previewSerial
	local now = DomainRules.ServerNow()
	local activation = math.min(spec.ActivationSeconds, 2)
	local ending = math.max(math.min(spec.EndSeconds, 2), 0.3)
	local startPhase = if moment == "DomainOpen"
		then "Activating"
		elseif moment == "DomainActive" then "Active"
		else "Ending"
	local view: DomainView = {
		Id = PREVIEW_ID,
		Owner = nil,
		MoveId = "",
		Shape = spec.Shape,
		Radius = spec.Radius,
		Height = if spec.Shape == "Sphere" then spec.Radius * 2 else spec.Height,
		Center = center,
		Offset = Vector3.zero,
		Yaw = math.atan2(-forward.X, -forward.Z),
		Anchor = "Fixed",
		EntryRule = "Open",
		ExitRule = "Open",
		Phase = startPhase,
		PhaseStartedAt = now,
		PhaseEndsAt = now + (if startPhase == "Activating"
			then activation
			elseif startPhase == "Active" then PREVIEW_HOLD_SECONDS
			else ending),
		ActivationSeconds = activation,
		EndSeconds = ending,
		ClashState = "None",
	}
	dropRealm(PREVIEW_ID)
	local activeCue = MovePresentation.CueFrom(presentation, "DomainActive")
	realms[PREVIEW_ID] = buildRealm(view, activeCue)

	-- The scripted clock: each phase hands to the next at its end, unless a newer preview replaced this one.
	local function advance(): ()
		local realm = realms[PREVIEW_ID]
		if realm == nil or previewSerial ~= serial then
			return
		end
		local current = realm.View
		local at = DomainRules.ServerNow()
		if current.Phase == "Activating" then
			current.Phase = "Active"
			current.PhaseStartedAt = at
			current.PhaseEndsAt = at + PREVIEW_HOLD_SECONDS
			task.delay(PREVIEW_HOLD_SECONDS, advance)
		elseif current.Phase == "Active" then
			current.Phase = "Ending"
			current.PhaseStartedAt = at
			current.PhaseEndsAt = at + ending
		end
	end
	if startPhase ~= "Ending" then
		task.delay(view.PhaseEndsAt - now, advance)
	end
end

-- How many realms this client is drawing. Spec/diagnostic only.
function DomainFX.DrawnCount(): number
	local count = 0
	for _ in realms do
		count += 1
	end
	return count
end

return DomainFX
