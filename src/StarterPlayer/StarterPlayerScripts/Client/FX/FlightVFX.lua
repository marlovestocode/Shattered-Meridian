--!strict
--[[
	FlightVFX.lua

	Owns: the dev-menu flight feature's world-space impact VFX -- a takeoff dust ring, a landing
	shockwave ring (soft/hard variants), and a sonic-boom burst -- all sharing ONE pooled "ring" Part
	factory (Constants.FX.FlightRingPool.PoolMaxSize) rather than three separate pools, since all
	three are visually the same primitive (an expanding flat ring) just with different starting/
	ending radii and colors (Constants.FX.FlightTakeoffDust/FlightLandingRing/FlightSonicBoom). Same
	acquire-from-pool -> animate -> release-on-Completed shape Client/FX/HitFlash.lua already
	established for its own pooled Highlights, adapted here to tween Size (radius) instead of just
	Transparency, per performance-optimization.md/animation-systems.md's "all VFX are object-pooled,
	never instanced-and-destroyed per use" mandate.

	Does not own: deciding WHEN a takeoff/landing/sonic-boom happened (Client/DevTools/DevMenu/
	FlightController.lua's own detection/classification), or any sound/camera-shake/hit-stop that
	accompanies these (FlightAudio.lua, CameraShake.lua, HitStop.lua) -- purely local presentation,
	nothing here crosses the network.
]]

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("FlightVFX")

local FlightVFX = {}

-- A persistent, unreplicated container the pooled rings live under while active -- same "off any
-- world Model so nothing destroyed mid-effect takes a pooled instance with it" reasoning
-- HitFlash.lua's holder uses, though a ring is positioned in the world rather than adorning a
-- character, so plain Workspace is fine (no character-destruction risk to guard against here).
-- Lazily created via FXPool.GetHolder, shared with HitFlash.lua/MovementVFX.lua's own holders.
local function getHolder(): Folder
	return FXPool.GetHolder("FlightVFXHolder", function(): Instance
		return Workspace
	end)
end

-- A flattened, thin cylinder -- the local X axis (Roblox's default Cylinder axis) is rotated to
-- world-up so the circular face lies flat, reading as a ground-level ring. Cosmetic shape only;
-- Studio-tune the exact orientation/proportions once this is actually seen in-engine.
local function makeRing(): Part
	local part = Instance.new("Part")
	part.Name = "FlightRing"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Size = Constants.FX.FlightRingPool.StartSize
	part.Parent = nil
	return part
end

local function resetRing(part: Part): ()
	part.Parent = nil
end

local pool = FXPool.New(makeRing, resetRing, Constants.FX.FlightRingPool.PoolMaxSize)

local function playRing(position: Vector3, color: Color3, maxRadiusStuds: number, expandDurationSeconds: number): ()
	local part = pool:Acquire()
	if not part then
		logger:debug("FlightVFX pool at cap -- dropping ring", { position = tostring(position) })
		return
	end

	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Color = color
	part.Transparency = Constants.FX.FlightRingPool.StartTransparency
	part.Size = Constants.FX.FlightRingPool.StartSize
	part.Parent = getHolder()

	local diameter = maxRadiusStuds * 2
	local tween = TweenService:Create(
		part,
		TweenInfo.new(expandDurationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.2, diameter, diameter), Transparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		pool:Release(part)
	end)
end

function FlightVFX.PlayTakeoffDust(position: Vector3): ()
	local cfg = Constants.FX.FlightTakeoffDust
	playRing(position, cfg.Color, cfg.MaxRadiusStuds, cfg.ExpandDurationSeconds)
end

function FlightVFX.PlayLandingRing(position: Vector3, isHard: boolean): ()
	local cfg = Constants.FX.FlightLandingRing
	local radius = if isHard then cfg.HardMaxRadiusStuds else cfg.SoftMaxRadiusStuds
	local color = if isHard then cfg.HardColor else cfg.SoftColor
	playRing(position, color, radius, cfg.ExpandDurationSeconds)
end

function FlightVFX.PlaySonicBoomBurst(position: Vector3): ()
	local cfg = Constants.FX.FlightSonicBoom
	playRing(position, cfg.Color, cfg.MaxRadiusStuds, cfg.ExpandDurationSeconds)
end

return FlightVFX
