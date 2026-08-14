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

	Domain-specific modules (CombatAudio.lua, RunAudio.lua, and future ones) own WHICH names exist and
	WHEN to play them -- this module only owns the name -> Sound Instance registry and playback
	mechanics. It has no combat/UI/gameplay knowledge of its own.

	Two capabilities beyond "register a name, play it," both added for the run system's footsteps and
	both deliberately general rather than run-specific:
	  * A per-play PlaybackSpeed (Play's optional second argument) -- pitch variation on a repeated
	    one-shot, without a second registration per variant.
	  * Reconfigure(), which repoints an existing name at a new definition in place, so a domain
	    module can offer "change this sound at runtime" without leaking a Sound instance per swap.
	SoundDefinition.PlaybackRegion (see Constants.lua) rides along with both: one asset containing
	several distinct sounds can be registered under several names, each restricted to its own slice by
	the engine rather than by a stop timer.

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

	-- The second wrong-VALUE guard strict typing can't catch, and the one that has actually cost a
	-- playtest: a SoundId that is a bare asset NUMBER ("76038309546970") rather than a content URL
	-- ("rbxassetid://76038309546970"). It is a perfectly good string, so nothing in the type system or
	-- the linter objects; Roblox simply fails to resolve it, and the ONLY signal is a Studio-console
	-- line ("Failed to load sound <id>: Temp read failed") that is easy to miss under a boot log --
	-- while this module cheerfully reports every subsequent Play() as succeeding, because :Play() on a
	-- Sound with an unresolvable id raises nothing. Warned rather than corrected: silently rewriting a
	-- caller's asset id would hide a genuine typo just as effectively as ignoring it, and this is the
	-- kind of mistake that should be fixed at the constant.
	if definition.SoundId ~= "" and not string.match(definition.SoundId, "^rbxassetid://") then
		logger:warn(
			"Sound registered with a SoundId that is not a content URL -- Roblox will fail to load it "
				.. "and every Play() will silently do nothing. Prefix the asset id with 'rbxassetid://'.",
			{ name = name, soundId = definition.SoundId }
		)
	end

	registeredSounds[name] = { definition = definition, poolSize = poolSize, instances = {}, nextIndex = 1 }
	logger:debug("Sound registered", { name = name, hasSoundId = definition.SoundId ~= "", poolSize = poolSize })
end

-- Writes a definition's properties onto a live Sound instance. Factored out of instance creation so
-- Reconfigure (below) can re-apply a NEW definition to instances that already exist -- the two must
-- agree on exactly which properties a definition controls, or a re-configured sound would keep some
-- fields from its previous definition.
--
-- PlaybackRegion is applied through the PlaybackRegionsEnabled pair rather than assumed: a
-- definition without one has to actively DISABLE the region, or a Reconfigure that removes a region
-- would leave the old slice in force on an already-created instance.
local function applyDefinition(sound: Sound, definition: SoundDefinition): ()
	sound.SoundId = definition.SoundId
	sound.Volume = definition.Volume
	local region = definition.PlaybackRegion
	if region then
		sound.PlaybackRegion = region
		sound.PlaybackRegionsEnabled = true
	else
		sound.PlaybackRegionsEnabled = false
	end
end

local function getOrCreateInstanceAt(name: string, registered: RegisteredSound, index: number): Sound
	local existing = registered.instances[index]
	if existing then
		return existing
	end

	local sound = Instance.new("Sound")
	sound.Name = if index == 1 then name else `{name}{index}`
	applyDefinition(sound, registered.definition)
	sound.Parent = SoundService

	registered.instances[index] = sound
	return sound
end

-- Plays the sound registered under `name`, round-robining across its pool (poolSize == 1, the
-- default, behaves exactly as a single shared instance always has). Logs a warning and no-ops
-- (never errors) if `name` was never registered, or if it was registered with an empty SoundId
-- placeholder -- either is a config gap to fix, not a reason to interrupt whatever gameplay moment
-- triggered this call.
-- `playbackSpeed` is optional and per-play: pass one to pitch-shift THIS play without changing the
-- registration (Client/FX/RunAudio.lua's per-footstep jitter is the first user -- a fixed-interval
-- step system replaying one identical sample reads as a metronome, and a few percent of random pitch
-- is the cheapest fix there is). Omitting it restores 1, so a pooled instance that was pitched by an
-- earlier play never leaks that pitch into an unrelated later one.
function SoundManager.Play(name: string, playbackSpeed: number?): ()
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
	sound.PlaybackSpeed = playbackSpeed or 1
	sound:Play()
	logger:debug("Sound played", { name = name, poolIndex = index })
end

-- Repoints an ALREADY-REGISTERED name at a new definition, in place -- the runtime half of "the step
-- sounds are configurable." Register() warns and rebuilds on a duplicate name because two call sites
-- claiming one name is a collision; this is the opposite case, one owner deliberately swapping its
-- own sound (Client/FX/RunAudio.SetStepSound, so a step sound can be changed live without a rejoin),
-- so it neither warns nor discards the pooled instances -- it re-applies the definition onto them.
--
-- Reusing the instances rather than rebuilding them is what keeps this leak-free: the old Sound
-- objects are already parented to SoundService and already referenced by the pool, and creating
-- replacements would strand the originals there forever, one set per swap.
function SoundManager.Reconfigure(name: string, definition: SoundDefinition): ()
	local registered = registeredSounds[name]
	if not registered then
		logger:warn("Reconfigure requested for unregistered sound", { name = name })
		return
	end
	-- PoolSize is deliberately NOT re-read: it is a property of the pool, which already exists, and
	-- growing/shrinking it mid-session would mean either orphaning live instances or handing the
	-- round-robin index a range that no longer matches `instances`. A sound whose overlap
	-- characteristics change that much is a different registration, not a reconfiguration.
	registered.definition = definition
	for _, sound in registered.instances do
		applyDefinition(sound, definition)
	end
	logger:debug("Sound reconfigured", { name = name, hasSoundId = definition.SoundId ~= "" })
end

-- Silences every pooled instance of `name` at once -- the one-shot counterpart to StopLooped, for a
-- caller whose sound has stopped being TRUE rather than having finished playing.
--
-- Play() is fire-and-forget precisely because a short one-shot has no meaningful stop point: a hit
-- sound outliving the hit by 200ms is the sound, not a bug. A REPEATING one-shot is different --
-- Client/FX/RunAudio.lua's footsteps are triggered while a condition holds, so when that condition
-- ends, any still-playing copies are describing something that is no longer happening. With a pool
-- of N and a cadence faster than the sample, that is up to N overlapping copies to cut, which is why
-- this stops the whole pool rather than the last-played slot.
--
-- Costs nothing on an already-finished sound (Stop on a non-playing Sound is a no-op), so a caller
-- may fire it on any edge it likes without checking first.
function SoundManager.StopAll(name: string): ()
	local registered = registeredSounds[name]
	if not registered then
		return
	end
	for _, sound in registered.instances do
		sound:Stop()
	end
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
