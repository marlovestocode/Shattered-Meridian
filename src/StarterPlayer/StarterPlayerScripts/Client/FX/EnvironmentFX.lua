--!strict
--[[
	EnvironmentFX.lua

	Owns: the environment's reaction to a fight on THIS client -- dust and chipped debris off a wall a swing
	passed close to (the swing scuff), a bigger burst where a body was slammed into one (the wall splat), and
	the splat's two consequences that belong to a client: the victim mirrors the stun the server gave them
	(LocalCombatState.NoteHitstun) and both sides feel it (CameraShake). Server/Combat/Environment/
	EnvironmentReactionSystem.lua decides both events; this only draws and mirrors them.

	THREE INPUTS, ONE DRAW PATH:
	  * Combat_EnvironmentFX (reliable): wall splats -- the stun rides it, so it must arrive.
	  * Combat_EnvironmentFXCosmetic (UNRELIABLE): other players' swing scuffs. A lost one is a puff of dust
	    nobody misses; the server skips the swinger themselves.
	  * the local player's OWN swing scuff, PREDICTED: at the strike of their own swing (AttackInputClient.
	    OnAttackStarted, windup seconds later) this client casts the same probe the server does
	    (EnvironmentProbe.SwingFan), so your own blade chips the wall on the frame it reaches it rather than a
	    round trip later. A swing cancelled in its windup never struck, so it scuffs nothing.

	POOLED, NEVER PER-USE (performance-optimization.md): a burst borrows a dust carrier (an anchored, invisible
	Part holding one ParticleEmitter, :Emit'd) and up to ChipCount chip Parts from FXPool, and gives them back
	when their lifetime ends. At either pool's cap a burst simply draws less -- the oldest dust is not stolen.
	Chips are real, loose, non-colliding Parts in the surface's own colour and material (a sprite could not
	borrow the surface's look); they are client-local, so their physics costs no one else anything.

	Before 2026-10-07 the server already sent both events and nothing on the client listened: the dust never
	drew and a splatted victim's client did not know it was stunned. This module is that missing listener.

	Does not own: whether either event happened (the server's), the stun itself (DamageSystem.ExtendHitstun --
	this only mirrors it), the probe (Shared/Combat/EnvironmentProbe), or the tuning (EnvironmentConstants for
	outcomes, FXConstants.EnvironmentImpact for looks).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local EnvironmentConstants = require(ReplicatedStorage.Shared.Combat.EnvironmentConstants)
local EnvironmentProbe = require(ReplicatedStorage.Shared.Combat.EnvironmentProbe)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)

local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
local LocalCombatState = require(script.Parent.Parent.Combat.LocalCombatState)
local CameraShake = require(script.Parent.CameraShake)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("EnvironmentFX")

local EnvironmentFX = {}

local LOOK = FXConstants.EnvironmentImpact
local NAMES = EnvironmentConstants.Network.RemoteNames

-- Where a pooled part waits while free: far below the world, anchored, invisible.
local PARKED = CFrame.new(0, -10000, 0)

type Preset = typeof(LOOK.Presets.SwingScuff)

local started = false
local trove = Trove.New()
local random = Random.new()

local function holder(): Folder
	return FXPool.GetHolder("EnvironmentFXHolder", function(): Instance
		return Workspace
	end)
end

local dustPool = FXPool.New(function(): BasePart
	local carrier = Instance.new("Part")
	carrier.Name = "EnvironmentDust"
	carrier.Anchored = true
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CanTouch = false
	carrier.CastShadow = false
	carrier.Transparency = 1
	carrier.Size = LOOK.CarrierPartSize
	carrier.CFrame = PARKED
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Dust"
	emitter.Enabled = false
	emitter.Texture = LOOK.DustTexture
	emitter.Transparency = LOOK.DustTransparency
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.Rate = 0
	emitter.Drag = 4
	emitter.LockedToPart = false
	emitter.Parent = carrier
	carrier.Parent = holder()
	return carrier
end, function(carrier: BasePart)
	carrier.CFrame = PARKED
end, LOOK.DustPoolMaxSize)

local chipPool = FXPool.New(function(): BasePart
	local chip = Instance.new("Part")
	chip.Name = "EnvironmentChip"
	chip.Anchored = true
	chip.CanCollide = false
	chip.CanQuery = false
	chip.CanTouch = false
	chip.CastShadow = false
	chip.CFrame = PARKED
	chip.Parent = holder()
	return chip
end, function(chip: BasePart)
	chip.Anchored = true
	chip.AssemblyLinearVelocity = Vector3.zero
	chip.AssemblyAngularVelocity = Vector3.zero
	chip.CFrame = PARKED
end, LOOK.ChipPoolMaxSize)

local function between(range: NumberRange): number
	return random:NextNumber(range.Min, range.Max)
end

-- A direction off the wall: mostly along its normal, scattered across it, lifted a little.
local function launchDirection(normal: Vector3): Vector3
	local scatter = random:NextUnitVector()
	local direction = normal * LOOK.ChipNormalBias + scatter * (1 - LOOK.ChipNormalBias)
	return if direction.Magnitude > 1e-3 then direction.Unit else normal
end

-- One burst of `preset` at `position` on a surface facing `normal`.
local function burst(preset: Preset, position: Vector3, normal: Vector3, material: Enum.Material, color: Color3): ()
	local face = if normal.Magnitude > 1e-3 then normal.Unit else Vector3.yAxis

	local carrier = FXPool.Acquire(dustPool)
	if carrier then
		local emitter = carrier:FindFirstChild("Dust") :: ParticleEmitter?
		if emitter then
			-- The emitter fires along the carrier's up vector, so the carrier is turned to face off the wall.
			carrier.CFrame = CFrame.lookAt(position, position + face) * CFrame.Angles(-math.pi / 2, 0, 0)
			emitter.Color = ColorSequence.new(color)
			emitter.Size = preset.DustSize
			emitter.Speed = preset.DustSpeed
			emitter.Lifetime = preset.DustLifetimeSeconds
			emitter:Emit(preset.DustCount)
		end
		task.delay(preset.DustLifetimeSeconds.Max, function()
			FXPool.Release(dustPool, carrier)
		end)
	end

	for _ = 1, preset.ChipCount do
		local chip = FXPool.Acquire(chipPool)
		if not chip then
			break
		end
		local size = between(preset.ChipSize)
		chip.Size = Vector3.new(size, size * random:NextNumber(0.5, 1), size * random:NextNumber(0.6, 1.2))
		chip.Color = color
		chip.Material = material
		chip.CFrame = CFrame.new(position + face * 0.15)
			* CFrame.Angles(
				random:NextNumber(0, math.pi * 2),
				random:NextNumber(0, math.pi * 2),
				random:NextNumber(0, math.pi * 2)
			)
		chip.Anchored = false
		chip.AssemblyLinearVelocity = launchDirection(face) * between(preset.ChipSpeed)
			+ Vector3.yAxis * LOOK.ChipUpwardSpeed
		chip.AssemblyAngularVelocity = random:NextUnitVector() * 20
		task.delay(preset.ChipLifetimeSeconds, function()
			FXPool.Release(chipPool, chip)
		end)
	end
end

local function presetFor(kind: string): Preset?
	return (LOOK.Presets :: any)[kind]
end

local function isPayload(payload: unknown): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	local data = payload :: any
	return typeof(data.Kind) == "string"
		and typeof(data.Position) == "Vector3"
		and typeof(data.Normal) == "Vector3"
		and typeof(data.Color) == "Color3"
		and typeof(data.Material) == "EnumItem"
end

local function onPayload(payload: unknown): ()
	if not isPayload(payload) then
		return
	end
	local data = payload :: EnvironmentProbe.FxPayload
	local preset = presetFor(data.Kind)
	if not preset then
		return
	end
	burst(preset, data.Position, data.Normal, data.Material, data.Color)

	if data.Kind ~= "WallSplat" then
		return
	end
	local character = Players.LocalPlayer.Character
	if character == nil then
		return
	end
	if data.Victim == character then
		-- The server already stunned this body (DamageSystem.ExtendHitstun); mirror it so this client does not
		-- predict a swing or a guard the server is about to refuse.
		if typeof(data.StunSeconds) == "number" and data.StunSeconds > 0 then
			LocalCombatState.NoteHitstun(os.clock() + data.StunSeconds)
		end
		CameraShake.Shake(FXConstants.CameraShake.WallSplat)
	elseif data.Attacker == character then
		CameraShake.Shake(FXConstants.CameraShake.HitHeavy)
	end
end

-- The local player's own swing scuff (see this file's header) -------------------------------------------

-- The one swing waiting for its strike. A newer swing replaces it; a cancel drops it.
local pendingStrikeAt: number? = nil
local strikeConnection: RBXScriptConnection? = nil

local function stopWatching(): ()
	pendingStrikeAt = nil
	if strikeConnection then
		strikeConnection:Disconnect()
		strikeConnection = nil
	end
end

local function strike(): ()
	local character = Players.LocalPlayer.Character
	local root = if character then CharacterUtil.RootOf(character) else nil
	if not character or not root then
		return
	end
	local hit = EnvironmentProbe.SwingFan(root.CFrame, { character })
	if not hit then
		return
	end
	local preset = presetFor("SwingScuff")
	if not preset then
		return
	end
	local color = EnvironmentProbe.ColorOf(hit, FXConstants.MovementDust.ColorByFloorMaterial, LOOK.DefaultColor)
	burst(preset, hit.Position, hit.Normal, hit.Material, color)
end

local function onAttackStarted(payload: AttackTypes.AttackStartedPayload): ()
	if not EnvironmentConstants.SwingScuff.Enabled then
		return
	end
	pendingStrikeAt = os.clock() + math.max(payload.WindupSeconds, 0)
	if strikeConnection then
		return
	end
	-- Polled rather than task.delay'd, like SwingLunge: a cancel or a newer swing only has to drop the deadline.
	strikeConnection = RunService.Heartbeat:Connect(function()
		local at = pendingStrikeAt
		if at == nil then
			stopWatching()
			return
		end
		if os.clock() >= at then
			stopWatching()
			strike()
		end
	end)
end

-- Lifecycle ------------------------------------------------------------------------------------------------

function EnvironmentFX.Start(): ()
	if started then
		return
	end
	started = true
	trove:Connect(NetworkBridge.GetRemoteEvent(NAMES.Fx).OnClientEvent, onPayload)
	trove:Connect(NetworkBridge.GetUnreliableRemoteEvent(NAMES.FxCosmetic).OnClientEvent, onPayload)
	trove:Add(AttackInputClient.OnAttackStarted(onAttackStarted))
	trove:Add(AttackInputClient.OnSwingCancelled(function()
		stopWatching()
	end))
	trove:Add(stopWatching)
	logger:info("EnvironmentFX started")
end

function EnvironmentFX.Stop(): ()
	if not started then
		return
	end
	started = false
	trove:Clean()
end

-- Exposed for its spec: whether a remote payload is one this module would draw.
EnvironmentFX.IsPayload = isPayload

return EnvironmentFX
