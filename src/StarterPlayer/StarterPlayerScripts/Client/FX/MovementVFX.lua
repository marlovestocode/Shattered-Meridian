--!strict
--[[
	MovementVFX.lua

	Owns: ground dust kicked up under a character's feet -- a steady trickle while the local player
	sprints (moving, grounded, not flying), one bigger burst at Slide-start, and a puff at each end of
	a roll (the local player's own, and -- through Client/FX/RemoteMovementFX.lua -- everyone else's),
	colored by the standing surface's Humanoid.FloorMaterial (Constants.FX.MovementDust.ColorByFloorMaterial).
	Also the local player's roll-start camera kick and afterimage hand-off, from the same state hook. The visual idea
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

	THE STATE HOOK. OnStateChanged is one more call in Client/Parkour/ParkourController.lua's
	onTransition list, beside ParkourAudio's -- the same "no event source of its own" shape. Entering
	Sliding plays the slide burst (which had no caller at all after CombatClient.lua was deleted);
	entering Rolling plays the tuck puff, the Roll camera kick and RollAfterimage.PlayRoll; leaving it
	plays the stand-up puff.

	Does not own: deciding WHEN the local player is sprinting/sliding/rolling (the parkour state
	machine decides; RunController calls SetSprinting), the ghosts themselves (RollAfterimage.lua), the
	camera FOV that accompanies Sprint/Slide (FOVOffset.lua), or the animation (ParkourAnimator.lua).
	Purely local presentation; nothing here crosses the network.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local CameraShake = require(script.Parent.CameraShake)
local FXPool = require(script.Parent.FXPool)
local RollAfterimage = require(script.Parent.RollAfterimage)

local logger = Logger.scope("MovementVFX")

local CONFIG = Constants.FX.MovementDust

-- Same threshold CombatAnimator's own locomotion evaluator uses for "is there real held movement
-- input right now" -- now CombatConstants.MovementInputMagnitudeThreshold, see that field's own header
-- for the other call sites this used to independently duplicate.
local LOCOMOTION_THRESHOLD = CombatConstants.MovementInputMagnitudeThreshold

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

local currentCharacter: Model? = nil
local currentHumanoid: Humanoid? = nil
local currentRootPart: BasePart? = nil
local sprintingIntent = false
local lastTrickleClock = 0

-- Caches the character for the trickle loop, the slide burst and the roll hook -- called from
-- Main.client.lua's character-bind path alongside CombatAnimator.BindCharacter, same lifecycle.
function MovementVFX.BindCharacter(character: Model): ()
	currentCharacter = character
	currentHumanoid = CharacterUtil.HumanoidOf(character)
	currentRootPart = CharacterUtil.RootOf(character)
end

-- Held-Sprint INTENT only, exactly CombatAnimator.StartRunning/StopRunning's shape -- whether a
-- puff actually spawns this frame is re-derived every tick by the persistent evaluator below, never
-- decided here.
function MovementVFX.SetSprinting(sprinting: boolean): ()
	sprintingIntent = sprinting
end

-- One-shot bigger burst at the current foot position -- on entering Sliding, through OnStateChanged.
function MovementVFX.PlaySlideBurst(): ()
	local rootPart = currentRootPart
	if not rootPart then
		return
	end
	local floorMaterial = if currentHumanoid then currentHumanoid.FloorMaterial else Enum.Material.Air
	local position = rootPart.Position - Vector3.new(0, CONFIG.FootOffsetStuds, 0)
	spawnPuff(position, floorMaterial, CONFIG.SlideBurstParticleCount)
end

-- One roll puff under ANY character -- the local player's through OnStateChanged, a remote player's
-- through RemoteMovementFX. Radial rather than aimed: at half a second the roll is over before a
-- directional spray would read as anything but noise.
function MovementVFX.PlayRollBurst(character: Model): ()
	local rootPart = CharacterUtil.RootOf(character)
	if not rootPart then
		return
	end
	local humanoid = CharacterUtil.HumanoidOf(character)
	local floorMaterial = if humanoid then humanoid.FloorMaterial else Enum.Material.Air
	if floorMaterial == Enum.Material.Air then
		-- A roll carried off a ledge ends in the air; dust needs a floor to come off.
		return
	end
	local position = rootPart.Position - Vector3.new(0, CONFIG.FootOffsetStuds, 0)
	spawnPuff(position, floorMaterial, CONFIG.RollBurstParticleCount)
end

-- The local player's parkour transitions -- see this file's header, THE STATE HOOK.
function MovementVFX.OnStateChanged(previous: string, next: string): ()
	if next == "Sliding" and previous ~= "Sliding" then
		MovementVFX.PlaySlideBurst()
	end
	local character = currentCharacter
	if not character then
		return
	end
	if next == "Rolling" and previous ~= "Rolling" then
		MovementVFX.PlayRollBurst(character)
		RollAfterimage.PlayRoll(character)
		CameraShake.Shake(Constants.FX.CameraShake.Roll)
	elseif previous == "Rolling" and next ~= "Rolling" then
		MovementVFX.PlayRollBurst(character)
	end
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
