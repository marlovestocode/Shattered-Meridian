--!strict
--[[
	MovementVFX.lua

	Owns: ground dust kicked up under the local player's own feet -- a steady trickle while sprinting
	(moving, grounded, not flying) and one bigger burst at Slide-start, colored by the standing
	surface's Humanoid.FloorMaterial (Constants.FX.MovementDust.ColorByFloorMaterial). The visual idea
	is the one a downloaded reference Sprint asset already demonstrated (floor-material-colored dust
	puffs), rebuilt from scratch through this codebase's own pooling conventions rather than copied --
	that asset used raw Instance.new + Debris per puff, which has no place here.

	Pooled via FXPool (Constants.FX.MovementDust.PoolMaxSize), same acquire -> configure -> parent to
	a persistent holder -> release-after-lifetime shape HitFlash.lua/FlightVFX.lua already establish.
	Unlike either of those (Highlight / tweened Part), the pooled item here carries a real
	ParticleEmitter -- the first one in this FX library -- fired via one-shot :Emit(count) bursts
	rather than continuous Rate-based emission (Rate stays 0 always; Enabled is never toggled true),
	since every puff is a discrete kick, not a stream. A real particle emitter reads as a scatter of
	irregular motes; FlightVFX's tweened-ring approach reads as a shockwave, right for a flight
	landing but wrong for footstep dust -- new code, not a reuse of that module, though it reuses the
	exact same POOLING pattern.

	The trickle is driven by a persistent module-level Heartbeat loop (connected once at module load,
	not per Sprint-press) that re-derives every tick whether a puff should spawn right now
	(SetSprinting's intent flag AND real MoveDirection input AND grounded AND not Flying), rate-
	limited by its own throttle clock -- the same "one evaluator, re-deriving the answer every frame
	instead of scheduling one-shot restores" idiom CombatAnimator's own Walking/Running evaluator
	already uses for the identical class of problem. Deliberately does NOT check CombatAnimator's
	combatActionTrackCount (whether a swing/dash/slide/block is currently silencing the Running
	animation) -- introducing that cross-module dependency isn't worth it for the worst case (one
	extra dust puff exactly at the instant a combat action interrupts a sprint).

	Foot position is a fixed downward offset from HumanoidRootPart.Position
	(Constants.FX.MovementDust.FootOffsetStuds), not a raycast to the actual ground -- a first-pass
	approximation, retune in Studio.

	Does not own: deciding WHEN the local player is sprinting/sliding (CombatClient.lua calls
	SetSprinting/PlaySlideBurst), the camera FOV/shake that accompanies Sprint/Slide (FOVOffset.lua,
	CameraShake.lua), or the animation itself (CombatAnimator.lua). Purely local presentation;
	nothing here crosses the network.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("MovementVFX")

local CONFIG = Constants.FX.MovementDust

-- Same threshold CombatAnimator's own locomotion evaluator and Server/Combat/Movement.lua's
-- ResolveDashDirection/IsMoving use for "is there real held movement input right now" -- now
-- Constants.Combat.MovementInputMagnitudeThreshold, see that field's own header for the other call
-- sites this used to independently duplicate.
local LOCOMOTION_THRESHOLD = Constants.Combat.MovementInputMagnitudeThreshold

local MovementVFX = {}

-- A persistent, unreplicated container the pooled dust carriers live under while active -- same
-- "off any world Model so nothing destroyed mid-effect takes a pooled instance with it" reasoning
-- HitFlash.lua/FlightVFX.lua's own holders use. World-space (like FlightVFX's), not adorning a
-- character. Lazily created via FXPool.GetHolder, shared with those two modules' own holders.
local function getHolder(): Folder
	return FXPool.GetHolder("MovementVFXHolder", function(): Instance
		return Workspace
	end)
end

local function makeDustCarrier(): Part
	local part = Instance.new("Part")
	part.Name = "MovementDustCarrier"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = CONFIG.CarrierPartSize
	part.Parent = nil

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Dust"
	-- Real dust-puff sprite -- without this, Roblox falls back to its OWN default ParticleEmitter
	-- texture (a 4-point sparkle/star), which is why this read as "stars" instead of dirt before.
	emitter.Texture = CONFIG.Texture
	-- No additive glow -- a bright/glowing sparkle is exactly the "star" look this is fixing away
	-- from; dust should read as flat/matte, tinted only by Color below.
	emitter.LightEmission = 0
	emitter.LightInfluence = 1
	-- Rate stays 0 forever -- every puff is an explicit :Emit(count) burst, never continuous
	-- emission, so Enabled never needs to be true.
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Lifetime =
		NumberRange.new(CONFIG.ParticleLifetimeSeconds * CONFIG.LifetimeJitterFraction, CONFIG.ParticleLifetimeSeconds)
	emitter.Speed = CONFIG.Speed
	emitter.SpreadAngle = CONFIG.SpreadAngle
	emitter.Size = CONFIG.SizeSequence
	emitter.Transparency = CONFIG.TransparencySequence
	emitter.Parent = part
	return part
end

local function resetDustCarrier(part: Part): ()
	part.Parent = nil
end

local pool = FXPool.New(makeDustCarrier, resetDustCarrier, CONFIG.PoolMaxSize)

local function spawnPuff(position: Vector3, floorMaterial: Enum.Material, particleCount: number): ()
	local part = pool:Acquire()
	if not part then
		logger:debug("MovementVFX pool at cap -- dropping dust puff")
		return
	end

	local emitter = part:FindFirstChildOfClass("ParticleEmitter") :: ParticleEmitter
	local color = (CONFIG.ColorByFloorMaterial :: { [Enum.Material]: Color3 })[floorMaterial] or CONFIG.DefaultColor
	emitter.Color = ColorSequence.new(color)
	part.CFrame = CFrame.new(position)
	part.Parent = getHolder()
	emitter:Emit(particleCount)

	task.delay(CONFIG.ParticleLifetimeSeconds, function()
		pool:Release(part)
	end)
end

local currentHumanoid: Humanoid? = nil
local currentRootPart: BasePart? = nil
local sprintingIntent = false
local lastTrickleClock = 0

-- Caches humanoid/root part for the trickle loop and PlaySlideBurst -- called from CombatClient.
-- lua's character-bind path alongside CombatAnimator.BindCharacter, same lifecycle.
function MovementVFX.BindCharacter(character: Model): ()
	currentHumanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	currentRootPart = if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

-- Held-Sprint INTENT only, exactly CombatAnimator.StartRunning/StopRunning's shape -- whether a
-- puff actually spawns this frame is re-derived every tick by the persistent evaluator below, never
-- decided here.
function MovementVFX.SetSprinting(sprinting: boolean): ()
	sprintingIntent = sprinting
end

-- One-shot bigger burst at the current foot position -- called from CombatClient.lua's predicted
-- Slide press and its server-confirmed fallback.
function MovementVFX.PlaySlideBurst(): ()
	local rootPart = currentRootPart
	if not rootPart then
		return
	end
	local floorMaterial = if currentHumanoid then currentHumanoid.FloorMaterial else Enum.Material.Air
	local position = rootPart.Position - Vector3.new(0, CONFIG.FootOffsetStuds, 0)
	spawnPuff(position, floorMaterial, CONFIG.SlideBurstParticleCount)
end

-- The persistent trickle evaluator -- see header for why this is one always-connected loop rather
-- than something started/stopped per Sprint press.
RunService.Heartbeat:Connect(function()
	if not sprintingIntent then
		return
	end
	local humanoid = currentHumanoid
	local rootPart = currentRootPart
	if not humanoid or not rootPart then
		return
	end
	if humanoid:GetAttribute(Constants.Attributes.Flying) == true then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end
	if humanoid.MoveDirection.Magnitude < LOCOMOTION_THRESHOLD then
		return
	end

	local now = os.clock()
	if now - lastTrickleClock < CONFIG.TrickleIntervalSeconds then
		return
	end
	lastTrickleClock = now

	local position = rootPart.Position - Vector3.new(0, CONFIG.FootOffsetStuds, 0)
	spawnPuff(position, humanoid.FloorMaterial, CONFIG.TrickleParticleCount)
end)

return MovementVFX
