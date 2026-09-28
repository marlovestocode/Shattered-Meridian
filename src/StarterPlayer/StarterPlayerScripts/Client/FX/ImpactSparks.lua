--!strict
--[[
	ImpactSparks.lua

	Owns: the contact sparks of a steel-on-steel exchange -- a pooled particle burst at the contact point
	of a Parried, Blocked, Traded or GuardBroken outcome, plus the parry's camera punch. Driven by
	Client/Combat/CombatFeedbackClient.lua off Combat_Feedback, which reaches both participants, so both
	see the same burst at the same place.

	WHY. Before this, a parry -- the hardest read in the defence layer and the game's signature moment --
	was a banner, a shake, a gold hit-flash and a (still-blank) sound. Nothing happened AT the blades.
	Sparks at the contact are what make the clash physically located, and they cost the server nothing:
	ContactPosition already rides on every Combat_Feedback.

	POOLED, the MovementVFX way: one invisible anchored carrier Part with one ParticleEmitter, acquired,
	configured from the outcome's preset, moved to the contact, fired with :Emit(count), and released
	after the preset's longest lifetime. Rate stays 0 and Enabled false for ever -- every burst is a
	discrete :Emit. A burst past FXConstants.ImpactSparks.PoolMaxSize is dropped, never allocated.

	Does not own: whether an exchange happened or what kind it was (the server), the shake (CameraShake),
	the flash (HitFlash) or the sound (CombatAudio). Purely local presentation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local FOVOffset = require(script.Parent.FOVOffset)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("ImpactSparks")

local CONFIG = FXConstants.ImpactSparks
local PARRY_PUNCH_SLOT = "ParryClash"

local ImpactSparks = {}

local function getHolder(): Folder
	return FXPool.GetHolder("ImpactSparksHolder", function(): Instance
		return Workspace
	end)
end

local function makeCarrier(): Part
	local part = Instance.new("Part")
	part.Name = "ImpactSparkCarrier"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = CONFIG.CarrierPartSize

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sparks"
	emitter.Enabled = false
	emitter.Rate = 0
	-- Spray in every direction from the contact -- a clash throws sparks off both edges, not along one.
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.LightInfluence = 0
	emitter.Parent = part
	return part
end

local function resetCarrier(part: Part): ()
	part.Parent = nil
end

local pool = FXPool.New(makeCarrier, resetCarrier, CONFIG.PoolMaxSize)

-- Whether an outcome kind has a spark preset. For the caller's dispatch and for a spec.
function ImpactSparks.HasPreset(outcomeKind: string): boolean
	return (CONFIG.Presets :: { [string]: any })[outcomeKind] ~= nil
end

-- One burst for `outcomeKind` at `position`, plus the preset's camera punch if it carries one (the
-- parry, and harder, the perfect parry). `outcomeKind` is a PRESET key: an OutcomeKind, or one of the two
-- variants CombatFeedbackClient picks off the payload (ParriedPerfect, BlockedCracking). A kind with no
-- preset (Clean, Backstab, Evaded -- a body, not a blade) is a no-op, not an error.
function ImpactSparks.Play(outcomeKind: string, position: Vector3): ()
	local preset = (CONFIG.Presets :: { [string]: any })[outcomeKind]
	if not preset then
		return
	end
	if position ~= position then
		return
	end

	local part = pool:Acquire()
	if not part then
		logger:debug("ImpactSparks pool at cap -- dropping a burst", { kind = outcomeKind })
		return
	end
	local emitter = part:FindFirstChildOfClass("ParticleEmitter") :: ParticleEmitter
	emitter.Color = preset.Color
	emitter.Speed = preset.Speed
	emitter.Lifetime = preset.LifetimeSeconds
	emitter.Size = preset.Size
	emitter.Drag = preset.Drag
	emitter.Acceleration = preset.Acceleration
	emitter.LightEmission = preset.LightEmission
	part.CFrame = CFrame.new(position)
	part.Parent = getHolder()
	emitter:Emit(preset.Count)

	task.delay((preset.LifetimeSeconds :: NumberRange).Max, function()
		pool:Release(part)
	end)

	local punch = CONFIG.Punches[outcomeKind]
	if punch then
		FOVOffset.Punch(PARRY_PUNCH_SLOT, punch.FOVDelta, punch.OutSeconds, punch.BackSeconds)
	end
end

return ImpactSparks
