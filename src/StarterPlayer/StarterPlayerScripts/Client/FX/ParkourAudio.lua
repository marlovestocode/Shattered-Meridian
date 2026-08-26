--!strict
--[[
	ParkourAudio.lua

	Owns: every sound the parkour state machine makes -- which movement states have one, whether it is
	a one-shot or a loop, and the single OnStateChanged dispatcher
	Client/Parkour/ParkourController.lua's onTransition calls.

	REPLACES DashAudio.lua, SlideAudio.lua AND MantleAudio.lua, which were the same five lines of
	logic three times under thirty-line headers apiece: register a sound at load, then
	`if next == "<State>" then SoundManager.Play(name) end`. Slide differed only in being the loop
	variant of that identical shape. 203 lines became these two tables, and adding the next state's
	sound is now a one-line table entry rather than a new module, a new require in
	ParkourController.lua, a new require in AssetPreloader.lua and a new call in onTransition.

	Client/FX/RunAudio.lua deliberately did NOT fold in. It is not a wrapper: it jitters pitch per run
	stage and silences Roblox's own default running sound, which is real behaviour a declarative table
	cannot express, and pretending otherwise would cost the module its reason to exist.

	Registered at load -- what puts these in SoundManager.GetPreloadInstances, which
	Client/Loading/AssetPreloader.lua sweeps at boot so the first dash/slide/mantle of a session does
	not pay CDN streaming latency mid-move. AssetPreloader requires this module directly for exactly
	that ordering reason.

	NO SUBSCRIPTION OF ITS OWN, unlike Client/FX/CombatAudio.lua's Attack_Started hook. These are
	MovementStateIds the framework's own state machine already tracks, and ParkourController already
	calls ParkourAnimator.OnStateChanged/ParkourCamera.OnStateChanged on every real transition -- this
	module's OnStateChanged is one more call in that same list, not a new event source.

	Does not own: WHEN any of these states is entered (each state's own CanEnter/Enter decides that;
	this module only reacts to a transition the controller already detected), or the Sound-instance
	mechanics (SoundManager.lua). Purely local presentation; nothing here crosses the network or
	affects an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local SoundManager = require(script.Parent.SoundManager)

type MovementStateId = ParkourTypes.MovementStateId

local ParkourAudio = {}

-- Played once on ENTERING the state, whatever the previous state was.
--
-- Dash is one sound for all five quadrants, deliberately, unlike ParkourAnimator's per-quadrant clips
-- (DashFront/DashBack/DashLeft/DashRight/DashUp): those are genuinely different animations because the
-- BODY moves differently in each direction, but a burst is a burst to the ear. Mantle is a single
-- committed beat for the same reason.
local ONE_SHOTS: { [string]: { Name: string, Definition: SoundManager.SoundDefinition } } = {
	Dashing = { Name = "DashLaunch", Definition = ParkourConstants.Dash.Sound },
	Mantling = { Name = "Mantle", Definition = ParkourConstants.Obstacle.MantleSound },
}

-- Started on entering the state and stopped on leaving it. The config tables here carry
-- FadeInSeconds/FadeOutSeconds alongside the SoundDefinition-shaped fields; SoundManager.Register
-- ignores the fades (it only reads the definition fields) and the dispatcher below reads them.
local LOOPS: { [string]: { Name: string, Config: typeof(ParkourConstants.Slide.Sound) } } = {
	Sliding = { Name = "SlideLoop", Config = ParkourConstants.Slide.Sound },
}

for _, entry in ONE_SHOTS do
	SoundManager.Register(entry.Name, entry.Definition)
end
for _, entry in LOOPS do
	SoundManager.Register(entry.Name, entry.Config)
end

-- Called from Client/Parkour/ParkourController.lua's onTransition, alongside
-- ParkourAnimator.OnStateChanged and ParkourCamera.OnStateChanged.
--
-- The two lookups are independent rather than an if/elseif chain, which matters for exactly one case:
-- a transition whose previous and next state share a loop must not stop and restart it. `leaving ~=
-- entering` is that guard, and it is what the three separate modules got for free by only ever
-- knowing about one state each.
function ParkourAudio.OnStateChanged(previous: MovementStateId, next: MovementStateId): ()
	local oneShot = ONE_SHOTS[next]
	if oneShot then
		SoundManager.Play(oneShot.Name)
	end

	local entering = LOOPS[next]
	if entering then
		SoundManager.PlayLooped(entering.Name, entering.Config.FadeInSeconds)
	end

	local leaving = LOOPS[previous]
	if leaving and leaving ~= entering then
		SoundManager.StopLooped(leaving.Name, leaving.Config.FadeOutSeconds)
	end
end

-- Called from Client/Parkour/ParkourController.lua's BindCharacter AND unbind, alongside
-- ParkourCamera.Reset. A character that dies or despawns mid-slide never gets the chance to hand
-- OnStateChanged a "leaving Sliding" transition (the machine is force-reset or torn down out from
-- under it), which would otherwise leave the loop playing forever into a respawn or an empty
-- character slot.
--
-- No fade-out passed, deliberately -- this is emergency cleanup for a body that no longer exists in
-- the ordinary sense, not the ordinary exit path, and a lingering fade tween outliving the very
-- character it was scoped to would be its own small leak. One-shots need no equivalent: they have
-- already finished or are about to.
function ParkourAudio.Reset(): ()
	for _, entry in LOOPS do
		SoundManager.StopLooped(entry.Name)
	end
end

return ParkourAudio
