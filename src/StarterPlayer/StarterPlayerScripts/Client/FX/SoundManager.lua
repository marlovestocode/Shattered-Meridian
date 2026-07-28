--!strict
--[[
	SoundManager.lua

	Owns: a shared registry of one-shot sound effects, keyed by name -- Register() declares a
	sound's SoundId/Volume once, Play() triggers it from anywhere without the caller needing to
	manage a Sound Instance itself. Generalizes the pattern CombatAudio.lua originally hand-rolled
	for a single sound (BlockImpact) into something every future FX-producing module (UI clicks,
	footsteps, ability casts, ...) can share instead of re-deriving its own Sound-instance-reuse
	logic -- see animation-systems.md's "All VFX are object-pooled, never instanced-and-destroyed
	per use" principle, applied here to SFX.

	Each registered name owns a small pool of Sound instances (Constants.SoundDefinition.PoolSize,
	default 1) rather than exactly one -- a single shared instance meant a second Play() while the
	first was still audible cut it off and restarted from zero, which reads as a missed hit for
	fast-combo sounds like Constants.Combat.Sound's Hit/BlockImpact/HandToHandParried. Play() round-
	robins across the pool; PlayLooped/StopLooped/SetLoopedVolume/SetLoopedPlaybackSpeed always
	address pool slot 1, since only one loop instance can ever meaningfully be "the" loop for a name.
	Deliberately NOT Client/FX/FXPool.lua's Acquire/Release model -- that needs an explicit release
	signal, and a fire-and-forget one-shot SFX has no natural one without a Sound.Ended connection
	per play; a fixed round-robin array needs no bookkeeping for "N concurrent overlaps of one short
	sound."

	Domain-specific modules (CombatAudio.lua, and future ones) own WHICH names exist and WHEN to
	play them -- this module only owns the name -> Sound Instance registry and playback mechanics.
	It has no combat/UI/gameplay knowledge of its own.

	2D-only (SoundService-parented) for now -- positional/3D audio (a Sound parented to a world
	Part) is a different concern nothing has asked for yet; adding it later is a new Register()
	option, not a rewrite of this module's shape.
]]

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("SoundManager")

local SoundManager = {}

-- Constants.lua owns the canonical shape (it's Shared, client+server-safe; this module is client-
-- only, so the dependency has to run this direction) -- see that module's own SoundDefinition
-- comment for why PoolSize is optional and what it's for.
export type SoundDefinition = Constants.SoundDefinition

type RegisteredSound = {
	definition: SoundDefinition,
	-- Clamped >= 1 at Register() time (see Register() below) -- every other function can assume
	-- this is always a valid divisor/count without re-checking.
	poolSize: number,
	instances: { Sound },
	nextIndex: number,
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

	-- The one runtime guard this module adds beyond --!strict's own type-checking (every caller is
	-- a compiled Luau module, so a wrong-TYPE PoolSize is already a compile error -- this is the one
	-- wrong-VALUE case strict typing can't catch): PoolSize <= 0 would make Play()'s round-robin
	-- modulo index nothing and silently break playback forever, so it's clamped, not trusted as-is.
	local poolSize = definition.PoolSize or 1
	if poolSize < 1 then
		logger:warn("Sound registered with a non-positive PoolSize, clamped to 1", { name = name, poolSize = poolSize })
		poolSize = 1
	end

	registeredSounds[name] = { definition = definition, poolSize = poolSize, instances = {}, nextIndex = 1 }
	logger:debug("Sound registered", { name = name, hasSoundId = definition.SoundId ~= "", poolSize = poolSize })
end

local function getOrCreateInstanceAt(name: string, registered: RegisteredSound, index: number): Sound
	local existing = registered.instances[index]
	if existing then
		return existing
	end

	local sound = Instance.new("Sound")
	sound.Name = if index == 1 then name else `{name}{index}`
	sound.SoundId = registered.definition.SoundId
	sound.Volume = registered.definition.Volume
	sound.Parent = SoundService

	registered.instances[index] = sound
	return sound
end

-- Plays the sound registered under `name`, round-robining across its pool (poolSize == 1, the
-- default, behaves exactly as a single shared instance always has). Logs a warning and no-ops
-- (never errors) if `name` was never registered, or if it was registered with an empty SoundId
-- placeholder -- either is a config gap to fix, not a reason to interrupt whatever gameplay moment
-- triggered this call.
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

	local index = registered.nextIndex
	registered.nextIndex = (registered.nextIndex % registered.poolSize) + 1

	local sound = getOrCreateInstanceAt(name, registered, index)
	sound:Play()
	logger:debug("Sound played", { name = name, poolIndex = index })
end

-- Looped-sound capability (Client/FX/FlightAudio.lua's wind-rush loop is the first user) -- Play()
-- above is one-shot-only by design, so a sustained sound needs its own start/stop/ramp entry points
-- rather than repeatedly calling Play() every frame. Mechanics-only, same as Play(): the caller
-- (FlightAudio.lua) computes/eases its own target volume/speed every frame and just calls the
-- setter here, the same division of labor CombatAudio.lua already has with Play(). Always pool slot
-- 1 -- a loop is singular by definition, pooling it would be nonsensical.
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

	local sound = getOrCreateInstanceAt(name, registered, 1)
	sound.Looped = true
	if not sound.IsPlaying then
		sound:Play()
		logger:debug("Looped sound started", { name = name })
	end
end

function SoundManager.StopLooped(name: string): ()
	local registered = registeredSounds[name]
	if not registered or not registered.instances[1] then
		return
	end
	registered.instances[1]:Stop()
	logger:debug("Looped sound stopped", { name = name })
end

-- Direct volume write, no tween -- the caller is expected to already be easing its own target value
-- across frames (Constants.Flight.Sound.WindLoop's own header), so a second smoothing layer here
-- would just be redundant lag on top of the caller's.
function SoundManager.SetLoopedVolume(name: string, volume: number): ()
	local registered = registeredSounds[name]
	if not registered or not registered.instances[1] then
		return
	end
	registered.instances[1].Volume = volume
end

function SoundManager.SetLoopedPlaybackSpeed(name: string, speed: number): ()
	local registered = registeredSounds[name]
	if not registered or not registered.instances[1] then
		return
	end
	registered.instances[1].PlaybackSpeed = speed
end

-- Eagerly creates every registered sound's pooled Sound instance(s) (skipping still-placeholder
-- SoundId = "" entries -- nothing to stream) and returns them for a caller to preload -- so the
-- FIRST real Play() of a session doesn't pay Roblox's CDN streaming latency mid-combat, the same
-- "no first-use cold-load hitch" principle performance-optimization.md already mandates for combat
-- animation tracks. Returns the list rather than calling ContentProvider:PreloadAsync itself
-- (Client/Loading/AssetPreloader.lua owns that call, batched together with every other domain
-- module's own preload instances) so there's one unified preload pass and one real progress count
-- across sounds/animations/textures, not a separate fire-and-forget call per module.
function SoundManager.GetPreloadInstances(): { Instance }
	local instances: { Instance } = {}
	for name, registered in registeredSounds do
		if registered.definition.SoundId == "" then
			continue
		end
		for index = 1, registered.poolSize do
			table.insert(instances, getOrCreateInstanceAt(name, registered, index))
		end
	end
	return instances
end

return SoundManager
