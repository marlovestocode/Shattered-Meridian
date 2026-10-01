--!strict
--[[
	ProjectileFX.lua

	Owns: drawing every projectile in flight on this client -- the shot itself (a glowing sphere whose
	diameter IS the hit volume's, with a trail), flown locally between the server's Attack_Projectile
	events, and the scatter when one ends on a wall.

	FLOWN, NOT STREAMED. The server does not send positions every frame. It sends an event when something
	a client could not work out for itself happens -- a launch (or a parry handing a shot to someone else),
	a bounce, a homing target change, an end -- and this module flies each shot in between with the SAME
	integrator the server flies it with (Shared/HitboxEngine/ProjectileMotion.Integrate): gravity,
	acceleration and homing toward the same target body. Each event says how old it is (Lead, plus the
	server-clock gap since SentAt), and the shot is flown forward by exactly that, so a shot is drawn where
	the server has it rather than a round trip behind. A corrected position (a bounce, a homing re-sync)
	eases in over FXConstants.Projectile.CorrectionSeconds rather than snapping.

	PRESENTATION ONLY. Nothing here reaches the server, and a contact is still the engine's answer alone. A
	shot that hits a BODY ends quietly here: the hit's own sparks, sound, flash and hit-stop arrive on
	Combat_Feedback like any other contact's (CombatFeedbackClient).

	POOLED (Client/FX/FXPool.lua): a shot past FXConstants.Projectile.PoolMaxSize is not drawn -- it still
	flies and still hits on the server. And GLOW-BUDGETED: only MaxGlowingShots carry their glow ball at
	once (the dearer half of a shot -- a second, larger ForceField sphere); a flood past it draws bare cores.
	The server sends this client only the shots it could see (Server/Combat/Attack/ProjectileRelevance.lua).

	PER-MOVE PRESENTATION (2026-09-30, Shared/Combat/MovePresentationTypes.lua). A launch names its MoveId,
	so a shot looks up its move's cues once, when it is first drawn:
	  * In flight -- the shot's own core, glow and trail colours, trail lifetime and a SizeScale on the glow
	    and the trail (never the core: the core IS the hit volume), each falling back to FXConstants
	    .Projectile field by field; and a looping sound riding the shot, one per volley at most and at most
	    FXConstants.MovePresentation.MaxLoopingShots on this client, stopped when the carrier is released.
	  * Launch -- once per volley (per GroupId in a batch), at the first shot; its camera cues only on the
	    thrower's own client, since a shake for somebody else's cast would be noise.
	  * Bounce -- an Update tagged Reason "Bounce" (the simulator tags it; homing re-syncs are untagged).
	  * WorldImpact -- an End on the world; its default is the ProjectileWorld sparks this module always
	    played. End -- a shot that ran out of range or lifetime; its default is nothing.
	Audience "Participants" plays a projectile cue only for the thrower and the shot's homing target. A
	shot that was never drawn (past the pool cap) plays no cue but the world sparks' default. Everything a
	cue changes is reset on the carrier's release, so a pooled carrier never carries one move's look into
	the next move's shot. Preview (the Move Editor) flies a local shot through this same Launch path.

	Does not own: flight, collision or anything a shot does (Server/Combat/HitboxEngine/
	ProjectileSimulator.lua), or a hit's feedback (CombatFeedbackClient).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)
local Trove = require(ReplicatedStorage.Shared.Trove)

local CombatAudio = require(script.Parent.CombatAudio)
local FXPool = require(script.Parent.FXPool)
local ImpactSparks = require(script.Parent.ImpactSparks)
local MovePresentation = require(script.Parent.MovePresentation)
local MovePresentationCatalog = require(script.Parent.MovePresentationCatalog)

type WireEvent = AttackTypes.ProjectileWireEvent
type Cue = MovePresentationTypes.Cue
type Presentation = MovePresentationTypes.Presentation

local logger = Logger.scope("ProjectileFX")

local CONFIG = FXConstants.Projectile
local MAX_LOOPING_SHOTS = FXConstants.MovePresentation.MaxLoopingShots
-- The ImpactSparks preset a shot ending on the world has always burst -- WorldImpact's default.
local WORLD_SPARKS = "ProjectileWorld"

-- An event older than this is not flown forward in one go -- a client that stalled for seconds would
-- otherwise integrate a shot through the world in a single step. The shot simply starts a little behind.
local MAX_CATCH_UP_SECONDS = 0.5
local CATCH_UP_STEP_SECONDS = 1 / 60

local ProjectileFX = {}

type Carrier = {
	Core: Part,
	Glow: Part,
	Trail: Trail,
	Top: Attachment,
	Bottom: Attachment,
	-- A move's In flight loop, built the first time a carrier needs one and kept on it for reuse.
	Loop: Sound?,
	-- The move's SizeScale for the glow and trail (never the core).
	LookScale: number,
}

type Shot = {
	Id: number,
	Carrier: Carrier,
	Position: Vector3,
	Velocity: Vector3,
	Motion: ProjectileMotion.Motion,
	Radius: number,
	Target: Model?,
	-- os.clock() past which the shot is dropped even if its End never arrives.
	ExpiresAt: number,
	-- What is drawn is Position + Correction; Correction decays to zero (see this file's header).
	Correction: Vector3,
	-- Who threw it and which move it is, off its Launch -- for the move's cues and their audience.
	Owner: Model?,
	MoveId: string?,
	Presentation: Presentation?,
	Looping: boolean,
	-- Whether this shot holds one of the MaxGlowingShots glow slots.
	Glowing: boolean,
}

local shots: { [number]: Shot } = {}
local trove = Trove.New()
local started = false
local loopingCount = 0
local glowingCount = 0
local MAX_GLOWING_SHOTS = CONFIG.MaxGlowingShots

local function getHolder(): Folder
	return FXPool.GetHolder("ProjectileFXHolder", function(): Instance
		return Workspace
	end)
end

local function newBall(name: string, transparency: number, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = material
	part.Color = CONFIG.CoreColor
	part.Transparency = transparency
	return part
end

local function makeCarrier(): Carrier
	local core = newBall("ProjectileCore", CONFIG.CoreTransparency, Enum.Material.Neon)
	local glow = newBall("ProjectileGlow", CONFIG.GlowTransparency, Enum.Material.ForceField)
	glow.Parent = core

	local top = Instance.new("Attachment")
	top.Name = "TrailTop"
	top.Parent = core
	local bottom = Instance.new("Attachment")
	bottom.Name = "TrailBottom"
	bottom.Parent = core

	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Color = CONFIG.TrailColor
	trail.Transparency = CONFIG.TrailTransparency
	trail.Lifetime = CONFIG.TrailLifetimeSeconds
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = core

	return { Core = core, Glow = glow, Trail = trail, Top = top, Bottom = bottom, Loop = nil, LookScale = 1 }
end

-- The default look, put back on every release so a move's cue never outlives its shot.
local function restoreDefaultLook(carrier: Carrier): ()
	carrier.Core.Color = CONFIG.CoreColor
	carrier.Glow.Color = CONFIG.CoreColor
	carrier.Glow.Transparency = CONFIG.GlowTransparency
	carrier.Trail.Color = CONFIG.TrailColor
	carrier.Trail.Transparency = CONFIG.TrailTransparency
	carrier.Trail.Lifetime = CONFIG.TrailLifetimeSeconds
	carrier.LookScale = 1
end

local function resetCarrier(carrier: Carrier): ()
	carrier.Trail.Enabled = false
	carrier.Trail:Clear()
	carrier.Core.Parent = nil
	local loop = carrier.Loop
	if loop and loop.IsPlaying then
		loop:Stop()
	end
	restoreDefaultLook(carrier)
end

local pool = FXPool.New(makeCarrier, resetCarrier, CONFIG.PoolMaxSize)

local function sizeCarrier(carrier: Carrier, radius: number): ()
	local diameter = math.max(radius * 2, 0.05)
	local lookScale = carrier.LookScale
	carrier.Core.Size = Vector3.one * diameter
	carrier.Glow.Size = Vector3.one * diameter * CONFIG.GlowScale * lookScale
	carrier.Top.Position = Vector3.new(0, radius * 0.6 * lookScale, 0)
	carrier.Bottom.Position = Vector3.new(0, -radius * 0.6 * lookScale, 0)
end

-- A move's In flight look over the defaults, field by field (MovePresentationTypes' precedence).
local function applyLook(carrier: Carrier, cue: Cue?): ()
	restoreDefaultLook(carrier)
	if cue == nil then
		return
	end
	local core = MovePresentation.Color(cue.CoreColor, nil)
	if core then
		carrier.Core.Color = core
		carrier.Glow.Color = core
	end
	local glow = MovePresentation.Color(cue.GlowColor, nil)
	if glow then
		carrier.Glow.Color = glow
	end
	if cue.TrailColor == MovePresentationTypes.None then
		carrier.Trail.Transparency = NumberSequence.new(1)
	else
		local trail = MovePresentation.Color(cue.TrailColor, nil)
		if trail then
			carrier.Trail.Color = ColorSequence.new(trail)
		end
	end
	if cue.TrailLifetime then
		carrier.Trail.Lifetime = cue.TrailLifetime
	end
	carrier.LookScale = cue.SizeScale or 1
end

-- This client's character, or nil -- including where there is no LocalPlayer at all (a spec harness).
local function localCharacter(): Model?
	local player = Players.LocalPlayer
	return if player then player.Character else nil
end

-- Whether this client is one of a shot's participants: its thrower, or the body it is homing on.
local function isParticipant(owner: Model?, target: Model?): boolean
	local character = localCharacter()
	return character ~= nil and (owner == character or target == character)
end

-- The shot's In flight loop, if its move authors one, this shot leads its volley, and the budget allows.
local function startLoop(shot: Shot, cue: Cue?): ()
	if cue == nil or cue.SoundId == nil or cue.SoundId == MovePresentationTypes.None then
		return
	end
	if loopingCount >= MAX_LOOPING_SHOTS then
		return
	end
	if not MovePresentation.Reaches(cue, isParticipant(shot.Owner, shot.Target)) then
		return
	end
	local carrier = shot.Carrier
	local loop = carrier.Loop
	if loop == nil then
		local sound = Instance.new("Sound")
		sound.Name = "ShotLoop"
		sound.Looped = true
		sound.Parent = carrier.Core
		carrier.Loop = sound
		loop = sound
	end
	local sound = loop :: Sound
	sound.SoundId = cue.SoundId :: string
	sound.Volume = FXConstants.MovePresentation.MoveSoundBaseVolume * (cue.Volume or 1)
	sound.PlaybackSpeed = cue.Pitch or 1
	-- Always positional -- it rides the shot. A rolloff of 0 takes the engine's own falloff.
	sound.RollOffMaxDistance = if cue.RolloffDistance and cue.RolloffDistance > 0 then cue.RolloffDistance else 10000
	sound:Play()
	shot.Looping = true
	loopingCount += 1
end

-- A projectile moment's one-off cue at `position` (Launch, Bounce, WorldImpact, End): sound, sparks over
-- the moment's default preset, template, and -- on the thrower's own client only -- camera.
local function playPointCue(
	cue: Cue?,
	moment: string,
	position: Vector3,
	defaultSparks: string?,
	participant: boolean,
	thrower: boolean,
	moveId: string?
): ()
	if cue and not MovePresentation.Reaches(cue, participant) then
		return
	end
	CombatAudio.PlayCue(cue, position)
	local preset, overrides = MovePresentation.Sparks(cue, defaultSparks)
	if preset then
		ImpactSparks.Play(preset, position, overrides)
	end
	if thrower then
		MovePresentation.PlayCamera(cue)
	end
	MovePresentation.PlayTemplate(cue, CFrame.new(position), moveId, moment)
end

local function place(shot: Shot): ()
	local drawn = CFrame.new(shot.Position + shot.Correction)
	shot.Carrier.Core.CFrame = drawn
	shot.Carrier.Glow.CFrame = drawn
end

local function homingPointOf(shot: Shot): Vector3?
	local target = shot.Target
	if target == nil or shot.Motion.HomingStrength <= 0 then
		return nil
	end
	local root = target.PrimaryPart
	return if root then root.Position else nil
end

-- Flies a shot forward `seconds`, in fixed steps -- used to catch an event up to now.
local function flyForward(shot: Shot, seconds: number): ()
	local remaining = math.clamp(seconds, 0, MAX_CATCH_UP_SECONDS)
	while remaining > 1e-4 do
		local dt = math.min(remaining, CATCH_UP_STEP_SECONDS)
		shot.Position, shot.Velocity =
			ProjectileMotion.Integrate(shot.Position, shot.Velocity, shot.Motion, dt, homingPointOf(shot))
		remaining -= dt
	end
end

local function release(id: number): ()
	local shot = shots[id]
	if shot == nil then
		return
	end
	shots[id] = nil
	if shot.Looping then
		loopingCount -= 1
	end
	if shot.Glowing then
		glowingCount -= 1
	end
	pool:Release(shot.Carrier)
end

-- Volleys whose Launch cue (and loop) already played in the batch being read -- see this file's header.
local cuedGroups: { [number]: boolean } = {}

-- `presentation` overrides the catalogue lookup -- only the Move Editor's Preview passes one.
local function onLaunch(event: WireEvent, age: number, presentation: Presentation?): ()
	local motion = event.Motion
	if motion == nil then
		return
	end
	local shot = shots[event.Id]
	-- The In flight cue whose loop this shot carries, once it is in the world (a Sound plays only there).
	local loopCue: Cue? = nil
	if shot == nil then
		local carrier = pool:Acquire()
		if carrier == nil then
			logger:debug("Projectile pool at cap -- not drawing a shot", { id = event.Id })
			return
		end
		local moveId = if typeof(event.MoveId) == "string" then event.MoveId else nil
		local resolved = presentation or (if moveId then MovePresentationCatalog.Get(moveId) else nil)
		shot = {
			Id = event.Id,
			Carrier = carrier,
			Position = event.Position,
			Velocity = event.Velocity,
			Motion = motion,
			Radius = event.Radius or 1,
			Target = event.Target,
			ExpiresAt = 0,
			Correction = Vector3.zero,
			Owner = event.Owner,
			MoveId = moveId,
			Presentation = resolved,
			Looping = false,
			Glowing = glowingCount < MAX_GLOWING_SHOTS,
		}
		shots[event.Id] = shot
		local flightCue = MovePresentation.CueFrom(resolved, "InFlight")
		applyLook(carrier, flightCue)
		-- Past the glow budget, a bare core: a fully transparent glow is culled, so it costs nothing.
		if shot.Glowing then
			glowingCount += 1
		else
			carrier.Glow.Transparency = 1
		end
		-- Once per volley: its first drawn shot launches the cue and carries the loop.
		if resolved and not cuedGroups[event.GroupId] then
			cuedGroups[event.GroupId] = true
			local launchCue = MovePresentation.CueFrom(resolved, "Launch")
			local thrower = event.Owner ~= nil and event.Owner == localCharacter()
			playPointCue(
				launchCue,
				"Launch",
				event.Position,
				nil,
				isParticipant(event.Owner, event.Target),
				thrower,
				moveId
			)
			loopCue = flightCue
		end
	end
	-- A re-launch (a parry sent it back) keeps the carrier but restarts everything else, including the
	-- trail: the old one would draw a streak through the parrier from where the shot used to be.
	shot.Position = event.Position
	shot.Velocity = event.Velocity
	shot.Motion = motion
	shot.Radius = event.Radius or shot.Radius
	shot.Target = event.Target
	-- A parry that turns the shot hands it to the parrier -- the owner its cues' audience now means.
	shot.Owner = event.Owner or shot.Owner
	shot.Correction = Vector3.zero
	shot.ExpiresAt = os.clock() + math.max((event.LifetimeSeconds or 0) - age, 0) + CONFIG.OrphanGraceSeconds
	flyForward(shot, age)

	local carrier = shot.Carrier
	sizeCarrier(carrier, shot.Radius)
	carrier.Trail.Enabled = false
	carrier.Trail:Clear()
	place(shot)
	carrier.Core.Parent = getHolder()
	carrier.Trail.Enabled = true
	if loopCue then
		startLoop(shot, loopCue)
	end
end

local function onUpdate(event: WireEvent, age: number): ()
	local shot = shots[event.Id]
	if shot == nil then
		return
	end
	if event.Reason == "Bounce" then
		playPointCue(
			MovePresentation.CueFrom(shot.Presentation, "Bounce"),
			"Bounce",
			event.Position,
			nil,
			isParticipant(shot.Owner, shot.Target),
			false,
			shot.MoveId
		)
	end
	local drawnBefore = shot.Position + shot.Correction
	shot.Position = event.Position
	shot.Velocity = event.Velocity
	shot.Target = event.Target
	flyForward(shot, age)
	shot.Correction = drawnBefore - shot.Position
end

local function onEnd(event: WireEvent): ()
	local shot = shots[event.Id]
	local presentation = if shot then shot.Presentation else nil
	local participant = shot ~= nil and isParticipant(shot.Owner, shot.Target)
	local moveId = if shot then shot.MoveId else nil
	if event.Reason == "World" then
		playPointCue(
			MovePresentation.CueFrom(presentation, "WorldImpact"),
			"WorldImpact",
			event.Position,
			WORLD_SPARKS,
			participant,
			false,
			moveId
		)
	elseif event.Reason == "Range" or event.Reason == "Expired" then
		playPointCue(
			MovePresentation.CueFrom(presentation, "End"),
			"End",
			event.Position,
			nil,
			participant,
			false,
			moveId
		)
	end
	release(event.Id)
end

local function onBatch(payload: unknown): ()
	if typeof(payload) ~= "table" then
		return
	end
	local batch = payload :: AttackTypes.ProjectileBatchPayload
	if typeof(batch.Events) ~= "table" or typeof(batch.SentAt) ~= "number" then
		return
	end
	local transit = math.max(Workspace:GetServerTimeNow() - batch.SentAt, 0)
	table.clear(cuedGroups)
	for _, event in batch.Events do
		local age = transit + (if typeof(event.Lead) == "number" then event.Lead else 0)
		if event.Kind == "Launch" then
			onLaunch(event, age)
		elseif event.Kind == "Update" then
			onUpdate(event, age)
		elseif event.Kind == "End" then
			onEnd(event)
		end
	end
end

local function step(deltaTime: number): ()
	local now = os.clock()
	local decay = if CONFIG.CorrectionSeconds > 0 then math.exp(-deltaTime / CONFIG.CorrectionSeconds) else 0
	for id, shot in shots do
		if now >= shot.ExpiresAt then
			release(id)
			continue
		end
		shot.Position, shot.Velocity =
			ProjectileMotion.Integrate(shot.Position, shot.Velocity, shot.Motion, deltaTime, homingPointOf(shot))
		shot.Correction *= decay
		place(shot)
	end
end

function ProjectileFX.Start(): ()
	if started then
		return
	end
	started = true
	local remote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Projectile)
	trove:Connect(remote.OnClientEvent, onBatch)
	trove:Connect(RunService.RenderStepped, step)
	logger:info("ProjectileFX started")
end

-- PREVIEW (the Move Editor). Plays one projectile moment of `presentation` locally, through the same
-- functions a real shot's events reach: In flight and Launch fly a short local shot from `origin` along its
-- look vector through onLaunch (negative ids, which the server never issues, so it cannot collide with a
-- real shot); the rest play their point cue a few studs in front of `origin`.
local previewSerial = 0
local PREVIEW_SPEED = 40
local PREVIEW_SECONDS = 1.2

function ProjectileFX.Preview(presentation: Presentation?, moment: string, origin: CFrame): ()
	local ahead = origin.Position + origin.LookVector * 6
	if moment == "Launch" or moment == "InFlight" then
		previewSerial += 1
		table.clear(cuedGroups)
		onLaunch(
			{
				Kind = "Launch",
				Id = -previewSerial,
				GroupId = -previewSerial,
				Position = origin.Position + origin.LookVector * 2,
				Velocity = origin.LookVector * PREVIEW_SPEED,
				Lead = 0,
				Owner = localCharacter(),
				Radius = 0.8,
				LifetimeSeconds = PREVIEW_SECONDS,
				Motion = { Gravity = 0, Acceleration = 0, HomingStrength = 0, MaxSpeed = PREVIEW_SPEED },
			} :: any,
			0,
			presentation or {}
		)
		return
	end
	local defaults: { [string]: string } = { WorldImpact = WORLD_SPARKS }
	playPointCue(MovePresentation.CueFrom(presentation, moment), moment, ahead, defaults[moment], true, true, nil)
end

-- How many shots are being drawn. Diagnostics and specs.
function ProjectileFX.DrawnCount(): number
	local count = 0
	for _ in shots do
		count += 1
	end
	return count
end

return ProjectileFX
