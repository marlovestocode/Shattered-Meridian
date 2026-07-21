--!strict
--[[
	SoundManager.lua

	Owns: a shared registry of one-shot sound effects, keyed by name -- Register() declares a
	sound's SoundId/Volume once, Play() triggers it from anywhere without the caller needing to
	manage a Sound Instance itself. Generalizes the pattern CombatAudio.lua originally hand-rolled
	for a single sound (BlockImpact) into something every future FX-producing module (UI clicks,
	footsteps, ability casts, ...) can share instead of re-deriving its own Sound-instance-reuse
	logic -- see animation-systems.md's "All VFX are object-pooled, never instanced-and-destroyed
	per use" principle, applied here to SFX: one Sound Instance per registered name, reused and
	restarted on every Play(), never recreated.

	Domain-specific modules (CombatAudio.lua, and future ones) own WHICH names exist and WHEN to
	play them -- this module only owns the name -> Sound Instance registry and playback mechanics.
	It has no combat/UI/gameplay knowledge of its own.

	2D-only (SoundService-parented) for now -- positional/3D audio (a Sound parented to a world
	Part) is a different concern nothing has asked for yet; adding it later is a new Register()
	option, not a rewrite of this module's shape.
]]

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("SoundManager")

local SoundManager = {}

export type SoundDefinition = {
	-- Empty string is a valid, intentional placeholder (this repo has no asset-upload pipeline, so
	-- a guessed rbxassetid is never used -- see e.g. VitalIcon.lua/CombatAudio.lua's headers for
	-- the same constraint elsewhere). Play() warns and no-ops for a sound registered this way
	-- rather than erroring, so registering a sound ahead of having a real asset id is safe.
	SoundId: string,
	Volume: number?,
}

type RegisteredSound = {
	definition: SoundDefinition,
	instance: Sound?,
}

local registeredSounds: { [string]: RegisteredSound } = {}

-- Declares a sound under `name` -- call once per name, typically at module load time from the
-- domain module that owns it (e.g. CombatAudio.lua registering "BlockImpact"). Calling this again
-- for a name that's already registered overwrites the old definition and logs a warning, since two
-- different call sites registering the same name is almost always a naming collision, not intended
-- reuse -- but it isn't refused outright (Studio script re-execution during iteration shouldn't
-- hard-error).
function SoundManager.Register(name: string, definition: SoundDefinition): ()
	if registeredSounds[name] then
		logger:warn("Sound re-registered, overwriting previous definition", { name = name })
	end
	registeredSounds[name] = { definition = definition, instance = nil }
	logger:debug("Sound registered", { name = name, hasSoundId = definition.SoundId ~= "" })
end

local function getOrCreateInstance(name: string, registered: RegisteredSound): Sound
	if registered.instance then
		return registered.instance
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = registered.definition.SoundId
	sound.Volume = registered.definition.Volume or 1
	sound.Parent = SoundService

	registered.instance = sound
	return sound
end

-- Plays the sound registered under `name`. Logs a warning and no-ops (never errors) if `name` was
-- never registered, or if it was registered with an empty SoundId placeholder -- either is a
-- config gap to fix, not a reason to interrupt whatever gameplay moment triggered this call.
function SoundManager.Play(name: string): ()
	local registered = registeredSounds[name]
	if not registered then
		logger:warn("Play requested for unregistered sound", { name = name })
		return
	end
	if registered.definition.SoundId == "" then
		logger:warn("Play skipped: sound has no SoundId configured", { name = name })
		return
	end

	local sound = getOrCreateInstance(name, registered)
	sound:Play()
	logger:debug("Sound played", { name = name })
end

-- Looped-sound capability (Client/FX/FlightAudio.lua's wind-rush loop is the first user) -- Play()
-- above is one-shot-only by design, so a sustained sound needs its own start/stop/ramp entry points
-- rather than repeatedly calling Play() every frame. Mechanics-only, same as Play(): the caller
-- (FlightAudio.lua) computes/eases its own target volume/speed every frame and just calls the
-- setter here, the same division of labor CombatAudio.lua already has with Play().
--
-- Idempotent: calling this while already playing is a no-op rather than restarting the loop from
-- the beginning.
function SoundManager.PlayLooped(name: string): ()
	local registered = registeredSounds[name]
	if not registered then
		logger:warn("PlayLooped requested for unregistered sound", { name = name })
		return
	end
	if registered.definition.SoundId == "" then
		logger:warn("PlayLooped skipped: sound has no SoundId configured", { name = name })
		return
	end

	local sound = getOrCreateInstance(name, registered)
	sound.Looped = true
	if not sound.IsPlaying then
		sound:Play()
		logger:debug("Looped sound started", { name = name })
	end
end

function SoundManager.StopLooped(name: string): ()
	local registered = registeredSounds[name]
	if not registered or not registered.instance then
		return
	end
	registered.instance:Stop()
	logger:debug("Looped sound stopped", { name = name })
end

-- Direct volume write, no tween -- the caller is expected to already be easing its own target value
-- across frames (Constants.Flight.Sound.WindLoop's own header), so a second smoothing layer here
-- would just be redundant lag on top of the caller's.
function SoundManager.SetLoopedVolume(name: string, volume: number): ()
	local registered = registeredSounds[name]
	if not registered or not registered.instance then
		return
	end
	registered.instance.Volume = volume
end

function SoundManager.SetLoopedPlaybackSpeed(name: string, speed: number): ()
	local registered = registeredSounds[name]
	if not registered or not registered.instance then
		return
	end
	registered.instance.PlaybackSpeed = speed
end

return SoundManager
