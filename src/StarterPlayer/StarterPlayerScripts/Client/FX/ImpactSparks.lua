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

	A MOVE MAY RESHAPE A BURST (Shared/Combat/MovePresentationTypes.lua): Play's `overrides` recolour it,
	scale its count and particle size, swap its texture, or drop the preset's camera punch -- always on the
	same pooled carrier, so a move's cue can never add a burst the pool did not already allow. The emitter
	is fully re-configured on every Play, so an override never leaks into the next burst.

	Does not own: whether an exchange happened or what kind it was (the server), the shake (CameraShake),
	the flash (HitFlash) or the sound (CombatAudio). Purely local presentation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local FOVOffset = require(script.Parent.FOVOffset)
local FXPool = require(script.Parent.FXPool)

-- What a move's cue changes about one burst -- MovePresentation.SparkOverrides, restated here so this
-- module needs nothing from the presentation layer to be called without one.
export type Overrides = {
	Color: Color3?,
	CountScale: number,
	SizeScale: number,
	Texture: string?,
	-- false drops the preset's own camera punch (the cue plays its own instead).
	Punch: false?,
}

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
	-- Remembered so a move's texture override can be put back: the engine's default sparkle is the look
	-- every preset wants (FXConstants.ImpactSparks' header).
	emitter:SetAttribute("DefaultTexture", emitter.Texture)
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
local function scaledSize(size: NumberSequence, scale: number): NumberSequence
	if scale == 1 then
		return size
	end
	local keypoints = {}
	for _, keypoint in size.Keypoints do
		table.insert(
			keypoints,
			NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale)
		)
	end
	return NumberSequence.new(keypoints)
end

function ImpactSparks.Play(outcomeKind: string, position: Vector3, overrides: Overrides?): ()
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
	emitter.Color = if overrides and overrides.Color then ColorSequence.new(overrides.Color) else preset.Color
	emitter.Speed = preset.Speed
	emitter.Lifetime = preset.LifetimeSeconds
	emitter.Size = scaledSize(preset.Size, if overrides then overrides.SizeScale else 1)
	emitter.Drag = preset.Drag
	emitter.Acceleration = preset.Acceleration
	emitter.LightEmission = preset.LightEmission
	local defaultTexture = emitter:GetAttribute("DefaultTexture")
	emitter.Texture = if overrides and overrides.Texture
		then overrides.Texture
		elseif typeof(defaultTexture) == "string" then defaultTexture
		else emitter.Texture
	part.CFrame = CFrame.new(position)
	part.Parent = getHolder()
	local count = if overrides then math.floor(preset.Count * overrides.CountScale + 0.5) else preset.Count
	if count > 0 then
		emitter:Emit(count)
	end

	task.delay((preset.LifetimeSeconds :: NumberRange).Max, function()
		pool:Release(part)
	end)

	local punch = CONFIG.Punches[outcomeKind]
	if punch and not (overrides and overrides.Punch == false) then
		FOVOffset.Punch(PARRY_PUNCH_SLOT, punch.FOVDelta, punch.OutSeconds, punch.BackSeconds)
	end
end

return ImpactSparks
