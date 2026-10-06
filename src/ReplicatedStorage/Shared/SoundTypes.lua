--!strict
--[[
	SoundTypes.lua

	Owns: the two sound-table shapes every constants module annotates its sounds with, and that
	Client/FX/SoundManager.lua registers. A LEAF on purpose -- it requires nothing -- so a constants module
	(Combat, Flight, Run, Parkour) can type its sounds without depending on Shared/Constants.lua, which used
	to be the only home of these two types and pulled the whole hub in for one annotation.
]]

-- Shape shared by Constants.Combat.Sound/Constants.Flight.Sound's one-shot entries and consumed by
-- Client/FX/SoundManager.lua's Register() -- declared in Shared, not in SoundManager.lua, because this
-- module is Shared (client+server-safe) while SoundManager.lua is client-only; a client-only module
-- can depend on Shared, never the other way around. PoolSize is optional (Register() defaults it to
-- 1) -- only sounds prone to overlapping replays during play (fast combat combos) need to name one.
-- PlaybackRegion is optional and, when supplied, restricts playback to that [start, stop] slice of
-- the asset in seconds (SoundManager applies it via Sound.PlaybackRegion + PlaybackRegionsEnabled).
-- It exists so ONE asset containing several distinct sounds -- Constants.Run's stage-2 file, which
-- opens with a speed whoosh and continues into footsteps -- can be registered as two independent
-- named sounds instead of needing the audio split into two uploads, and so trimming is done by the
-- engine rather than by a task.delay stop (which would be both audibly imprecise and one more timer
-- per play to keep track of).
export type SoundDefinition = {
	SoundId: string,
	Volume: number,
	PoolSize: number?,
	PlaybackRegion: NumberRange?,
}
-- The one deliberate exception to SoundDefinition's shape -- a continuous loop (Constants.Flight.
-- Sound.WindLoop, played via SoundManager.PlayLooped) has no single Volume, only a ramped range the
-- caller eases across every frame (Client/FX/FlightAudio.lua's SetWindIntensity) -- see that
-- function for how MaxVolume/MinPlaybackSpeed/MaxPlaybackSpeed get used.
export type LoopSoundDefinition = {
	SoundId: string,
	MaxVolume: number,
	MinPlaybackSpeed: number,
	MaxPlaybackSpeed: number,
}

return {}
