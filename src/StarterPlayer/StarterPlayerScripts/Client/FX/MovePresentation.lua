--!strict
--[[
	MovePresentation.lua

	Owns: answering "what does THIS move want at THIS moment" on the client -- the move layer of the
	presentation precedence -- and the one effect nothing else here already draws: an authored template
	from ReplicatedStorage[FXConstants.MovePresentation.TemplateFolder], pooled.

	PRECEDENCE (Shared/Combat/MovePresentationTypes.lua states it; every function below implements it):

	    move config  >  the weapon's authored SFX folder  >  FXConstants / CombatConstants defaults

	field by field -- an unset field falls through, only None silences. This module answers the MOVE
	layer and states the rule (Pick, SoundSource); the layers beneath it stay with the modules that already
	own them: CombatAudio knows the weapon's SFX folder and the shared stingers, ImpactSparks its presets,
	CombatFeedbackClient which shake and freeze an outcome gets, ProjectileFX the default shot look,
	AttackTrail the swing trail. Each of those takes the resolved cue and applies it on top of its own
	answer, so there is still exactly ONE path per effect -- a move's cue changes what that path plays,
	it never runs a second copy of it.

	PURE WHERE IT CAN BE. CueFrom, Pick, SoundSource, Color, Shake, SparkOverrides and the rest take plain
	values and touch no Instance, so the precedence is specced directly (Tests/FX/MovePresentation.spec).
	CueFor is CueFrom over the replicated catalogue (MovePresentationCatalog).

	SETTINGS. Camera shake and FOV punches only ever go through CameraShake.Shake and FOVOffset.Punch, which
	are the settings.Comfort gates -- a move cannot shake a camera whose owner turned shaking off.

	BUDGET: templates only (sounds live in SoundManager's pools, sparks in ImpactSparks' pool). At most
	FXConstants.MovePresentation.MaxActiveTemplates clones live at once and TemplatePoolPerName of any one;
	past either cap a cue's template is dropped, never allocated. A template name the folder does not hold
	warns once per move and moment (Logger), never silently.

	Does not own: when a moment happens (the event owners above, and SwingPresentation for the swing
	moments), the catalogue (MovePresentationCatalog) or the schema (MovePresentationTypes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)

local CameraShake = require(script.Parent.CameraShake)
local FOVOffset = require(script.Parent.FOVOffset)
local FXPool = require(script.Parent.FXPool)
local MovePresentationCatalog = require(script.Parent.MovePresentationCatalog)

type Cue = MovePresentationTypes.Cue
type Presentation = MovePresentationTypes.Presentation

export type Layer = "Move" | "Weapon" | "Default"
export type SoundSource = "None" | "Move" | "Weapon" | "Default"
export type ShakePreset = { Amplitude: number, Frequency: number, DurationSeconds: number }
export type Punch = { FOVDelta: number, OutSeconds: number, BackSeconds: number }
-- What a cue changes about an ImpactSparks burst. Punch: nil keeps the preset's own camera punch, false
-- drops it (the cue's FovPunch answers the camera instead -- see PlayPunch).
export type SparkOverrides = {
	Color: Color3?,
	CountScale: number,
	SizeScale: number,
	Texture: string?,
	Punch: false?,
}

local logger = Logger.scope("MovePresentation")

local NONE = MovePresentationTypes.None
local CONFIG = FXConstants.MovePresentation
local PUNCH_SLOT = "MoveCue"

local MovePresentation = {}

-- The move layer -----------------------------------------------------------------------------------

-- `moment`'s cue in `presentation`, with its FallbackMoment's fields beneath its own (a Perfect parry
-- reads the Parried cue for what it leaves unset). nil when neither is authored. PURE.
function MovePresentation.CueFrom(presentation: Presentation?, moment: string): Cue?
	if presentation == nil then
		return nil
	end
	local cue = presentation[moment]
	local fallbackName = MovePresentationTypes.FallbackMoment[moment]
	local fallback = if fallbackName then presentation[fallbackName] else nil
	if fallback == nil then
		return cue
	end
	local merged = table.clone(fallback) :: any
	if cue then
		for field, value in cue :: any do
			merged[field] = value
		end
	end
	return merged :: Cue
end

-- The cue the replicated catalogue holds for `moveId` at `moment`, or nil (nothing authored, or not
-- known on this client yet -- both mean every layer below answers).
function MovePresentation.CueFor(moveId: unknown, moment: string): Cue?
	if typeof(moveId) ~= "string" then
		return nil
	end
	return MovePresentation.CueFrom(MovePresentationCatalog.Get(moveId), moment)
end

-- Precedence ---------------------------------------------------------------------------------------

-- THE rule, for one field: the first layer that says anything, and which layer that was. None is a
-- value like any other here -- a move that says None has answered. PURE.
function MovePresentation.Pick(moveValue: any, weaponValue: any, defaultValue: any): (any, Layer?)
	if moveValue ~= nil then
		return moveValue, "Move"
	end
	if weaponValue ~= nil then
		return weaponValue, "Weapon"
	end
	if defaultValue ~= nil then
		return defaultValue, "Default"
	end
	return nil, nil
end

-- Which layer's SOUND plays: the cue's own id, its explicit None, else the weapon's slot if it has one,
-- else the shared default if there is one. nil = nothing at any layer. Volume and pitch are NOT part of
-- this choice: the cue's scales apply to whichever sound answered (CombatAudio). PURE.
function MovePresentation.SoundSource(cue: Cue?, hasWeapon: boolean, hasDefault: boolean): SoundSource?
	local soundId = if cue then cue.SoundId else nil
	if soundId == NONE then
		return "None"
	end
	local _, layer = MovePresentation.Pick(soundId, if hasWeapon then true else nil, if hasDefault then true else nil)
	return layer
end

-- How far the cue's sound is shifted from its moment, in seconds: positive later, negative earlier (a lead --
-- only a caller that knows its moment AHEAD can honour that; see MovePresentationTypes' SOUND TIMING). 0 when
-- unset. PURE.
function MovePresentation.SoundDelay(cue: Cue?): number
	local delay = if cue then cue.SoundDelay else nil
	return if typeof(delay) == "number" and delay == delay then delay else 0
end

-- Whether the cue's sound loops for the rest of the move. Needs a sound of the cue's OWN (a SoundId that is not
-- None): there is nothing to loop otherwise -- a weapon's or the default's one-shot is not the author's loop.
-- PURE.
function MovePresentation.LoopsToEnd(cue: Cue?): boolean
	if cue == nil or cue.Loop ~= "RestOfMove" then
		return false
	end
	return typeof(cue.SoundId) == "string" and cue.SoundId ~= "" and cue.SoundId ~= NONE
end

-- The cue's sound fade as SoundManager's FadeSpec, or nil when it asks for none: seconds to rise from silence
-- (In) and to sink back to it over the sound's last seconds (Out). Either or both. PURE.
function MovePresentation.Fade(cue: Cue?): { In: number?, Out: number? }?
	if cue == nil then
		return nil
	end
	local fadeIn = if typeof(cue.FadeIn) == "number" and cue.FadeIn > 0 then cue.FadeIn else nil
	local fadeOut = if typeof(cue.FadeOut) == "number" and cue.FadeOut > 0 then cue.FadeOut else nil
	if fadeIn == nil and fadeOut == nil then
		return nil
	end
	return { In = fadeIn, Out = fadeOut }
end

-- A cue colour ("#RRGGBB"), or `default` when unset; nil for None (or unset with no default). PURE.
function MovePresentation.Color(hex: string?, default: Color3?): Color3?
	if hex == NONE then
		return nil
	end
	if hex then
		local ok, color = pcall(Color3.fromHex, hex)
		if ok then
			return color
		end
	end
	return default
end

-- The shake a moment plays: the cue's preset (or the default the caller would have played), scaled by
-- ShakeScale. nil = no shake. PURE.
function MovePresentation.Shake(cue: Cue?, default: ShakePreset?): ShakePreset?
	local name = if cue then cue.Shake else nil
	if name == NONE then
		return nil
	end
	local base: ShakePreset? = if name then (FXConstants.CameraShake :: any)[name] else default
	if base == nil then
		return nil
	end
	local scale = if cue and cue.ShakeScale then cue.ShakeScale else 1
	if scale == 1 then
		return base
	end
	return {
		Amplitude = base.Amplitude * scale,
		Frequency = base.Frequency,
		DurationSeconds = base.DurationSeconds,
	}
end

-- The cue's own FOV punch: a Punch, false for an explicit None, nil when the cue leaves it to the default
-- (for a hit, the spark preset's own punch). PURE.
function MovePresentation.Punch(cue: Cue?): (Punch | false)?
	local name = if cue then cue.FovPunch else nil
	if name == nil then
		return nil
	end
	if name == NONE then
		return false
	end
	return (FXConstants.ImpactSparks.Punches :: any)[name]
end

-- Which ImpactSparks preset a moment bursts (nil = none), and what the cue changes about it. PURE.
function MovePresentation.Sparks(cue: Cue?, defaultPreset: string?): (string?, SparkOverrides?)
	local preset = MovePresentation.Pick(if cue then cue.Sparks else nil, nil, defaultPreset)
	if preset == nil or preset == NONE then
		return nil, nil
	end
	if cue == nil then
		return preset, nil
	end
	local hasOverride = cue.SparkColor ~= nil
		or cue.SparkCount ~= nil
		or cue.SparkSize ~= nil
		or cue.SparkTexture ~= nil
		or cue.FovPunch ~= nil
	if not hasOverride then
		return preset, nil
	end
	return preset,
		{
			Color = MovePresentation.Color(cue.SparkColor, nil),
			CountScale = cue.SparkCount or 1,
			SizeScale = cue.SparkSize or 1,
			Texture = cue.SparkTexture,
			-- The cue's own punch replaces the preset's -- played by PlayPunch, so a punch authored on a
			-- moment with no sparks still lands.
			Punch = if cue.FovPunch ~= nil then false else nil,
		}
end

-- The hit-flash colour: the cue's, the default's, or nil for none. PURE.
function MovePresentation.FlashColor(cue: Cue?, default: Color3?): Color3?
	return MovePresentation.Color(if cue then cue.FlashColor else nil, default)
end

-- The exchange freeze: the cue's seconds, else the default. 0 is none. PURE.
function MovePresentation.HitStopSeconds(cue: Cue?, default: number?): number?
	if cue and cue.HitStopSeconds then
		return cue.HitStopSeconds
	end
	return default
end

-- Whether a projectile cue plays on this client: Everyone (the default) always, Participants only on the
-- thrower's and the homing target's. PURE.
function MovePresentation.Reaches(cue: Cue?, isParticipant: boolean): boolean
	if cue == nil or cue.Audience ~= "Participants" then
		return true
	end
	return isParticipant
end

-- Camera ------------------------------------------------------------------------------------------------

-- The cue's own punch, if it authored one. Through FOVOffset, so settings.Comfort gates it.
function MovePresentation.PlayPunch(cue: Cue?): ()
	local punch = MovePresentation.Punch(cue)
	if punch then
		FOVOffset.Punch(PUNCH_SLOT, punch.FOVDelta, punch.OutSeconds, punch.BackSeconds)
	end
end

-- Shake + punch for a moment whose default is nothing (a swing moment, a launch). Through CameraShake and
-- FOVOffset, so settings.Comfort gates both.
function MovePresentation.PlayCamera(cue: Cue?): ()
	if cue == nil then
		return
	end
	local shake = MovePresentation.Shake(cue, nil)
	if shake then
		CameraShake.Shake(shake :: any)
	end
	MovePresentation.PlayPunch(cue)
end

-- Templates -------------------------------------------------------------------------------------------

type Carrier = {
	Model: Model,
	Emitters: { ParticleEmitter },
	EmitCounts: { number },
	-- Beams, Trails and Lights: enabled for the lifetime, then off again.
	Toggles: { Instance },
	LifetimeSeconds: number,
}

local pools: { [string]: FXPool.Pool<Carrier> } = {}
local activeTemplates = 0
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string, data: { [string]: any }): ()
	if warned[key] then
		return
	end
	warned[key] = true
	logger:warn(message, data)
end

local function getHolder(): Folder
	return FXPool.GetHolder("MovePresentationHolder", function(): Instance
		return Workspace
	end)
end

-- The authored template called `name`, or nil.
function MovePresentation.FindTemplate(name: string): Instance?
	local folder = ReplicatedStorage:FindFirstChild(CONFIG.TemplateFolder)
	return if folder then folder:FindFirstChild(name) else nil
end

local function numberAttribute(instance: Instance, attribute: string): number?
	local value = instance:GetAttribute(attribute)
	return if typeof(value) == "number" and value == value then value else nil
end

local function makeCarrier(template: Instance): Carrier
	local model = Instance.new("Model")
	model.Name = `MoveFX_{template.Name}`
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Size = Vector3.one * 0.2
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.identity
	anchor.Parent = model
	model.PrimaryPart = anchor

	local clone = template:Clone()
	if clone:IsA("Attachment") then
		clone.Parent = anchor
	elseif clone:IsA("BasePart") or clone:IsA("Model") then
		-- Decoration only: anchored, and invisible to physics, raycasts and touches.
		local parts: { Instance } = clone:GetDescendants()
		table.insert(parts, clone)
		for _, part in parts do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
			end
		end
		(clone :: PVInstance):PivotTo(CFrame.identity)
		clone.Parent = model
	else
		local attachment = Instance.new("Attachment")
		attachment.Parent = anchor
		clone.Parent = attachment
	end

	local emitters: { ParticleEmitter } = {}
	local counts: { number } = {}
	local toggles: { Instance } = {}
	local longest = 0
	local defaultCount = numberAttribute(template, "EmitCount") or CONFIG.TemplateDefaultEmitCount
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
			table.insert(emitters, descendant)
			table.insert(counts, math.clamp(numberAttribute(descendant, "EmitCount") or defaultCount, 0, 200))
			longest = math.max(longest, descendant.Lifetime.Max)
		elseif descendant:IsA("Beam") or descendant:IsA("Trail") or descendant:IsA("Light") then
			(descendant :: any).Enabled = false
			table.insert(toggles, descendant)
		end
	end
	local lifetime = numberAttribute(template, "LifetimeSeconds") or longest
	return {
		Model = model,
		Emitters = emitters,
		EmitCounts = counts,
		Toggles = toggles,
		LifetimeSeconds = math.clamp(lifetime, 0.1, CONFIG.TemplateMaxLifetimeSeconds),
	}
end

local function resetCarrier(carrier: Carrier): ()
	for _, toggle in carrier.Toggles do
		(toggle :: any).Enabled = false
	end
	carrier.Model.Parent = nil
end

local function poolFor(name: string, template: Instance): FXPool.Pool<Carrier>
	local pool = pools[name]
	if pool == nil then
		pool = FXPool.New(function(): Carrier
			return makeCarrier(template)
		end, resetCarrier, CONFIG.TemplatePoolPerName)
		pools[name] = pool
	end
	return pool :: FXPool.Pool<Carrier>
end

-- Plays the cue's Template at `where`, if it names one. `moveId`/`moment` only label the warning a
-- missing template raises. Returns whether a template played.
function MovePresentation.PlayTemplate(cue: Cue?, where: CFrame, moveId: string?, moment: string): boolean
	local name = if cue then cue.Template else nil
	if name == nil then
		return false
	end
	local template = MovePresentation.FindTemplate(name)
	if template == nil then
		warnOnce(`{moveId}:{moment}:{name}`, "Move presentation template not found -- nothing plays", {
			moveId = moveId,
			moment = moment,
			template = name,
			folder = `ReplicatedStorage.{CONFIG.TemplateFolder}`,
		})
		return false
	end
	if activeTemplates >= CONFIG.MaxActiveTemplates then
		return false
	end
	local pool = poolFor(name, template)
	local carrier = pool:Acquire()
	if carrier == nil then
		return false
	end
	activeTemplates += 1
	carrier.Model:PivotTo(where)
	carrier.Model.Parent = getHolder()
	for index, emitter in carrier.Emitters do
		emitter:Emit(carrier.EmitCounts[index])
	end
	for _, toggle in carrier.Toggles do
		(toggle :: any).Enabled = true
	end
	task.delay(carrier.LifetimeSeconds, function()
		activeTemplates -= 1
		pool:Release(carrier)
	end)
	return true
end

-- Live template clones. Diagnostics and specs.
function MovePresentation.ActiveTemplateCount(): number
	return activeTemplates
end

return MovePresentation
