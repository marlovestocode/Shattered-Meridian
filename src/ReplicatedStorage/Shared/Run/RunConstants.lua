--!strict
--[[
	RunConstants.lua

	Owns: the whole run -- both its NUMBERS (the stage ladder itself, what each stage is worth, how
	long it takes to earn, and the conditions under which the charge that earns it builds, holds or
	bleeds away) and its PRESENTATION (Footsteps/StageOnset/Animation, at the bottom of this file).

	THE SPLIT, which used to be a three-way one and is now two:
	  * THIS FILE            -- what the run IS, and what it looks and sounds like. Stage speeds,
	                            charge thresholds, hysteresis and decay, read by
	                            Server/Systems/RunSystem.lua (the authority) and Shared/Run/
	                            RunLadder.lua (the pure resolver both sides share); plus footstep
	                            cadence, per-stage step sounds, the FOV pull and the onset kick, read
	                            by Client/Movement/RunController.lua and Client/FX/RunAudio.lua.
	                            The presentation half decides nothing -- it only reacts to the stage
	                            the server already resolved -- but it is keyed by the same ladder,
	                            which is why it moved in from Constants.Run rather than staying a
	                            file away from the array it indexes.
	  * ParkourConstants.Locomotion -- what the parkour framework BELIEVES about ground speed, for its
	                            own entry gates and its debug readout. Mirrors of the tiers below, and
	                            deliberately informational: see MotorCommand.DesiredSpeed's header.
	A number that decides a WalkSpeed belongs here and only here.

	Callers require this module directly; the old Constants.Run re-export was removed (2026-10-06).

	SEPARATE FROM Constants.Combat ON PURPOSE. The sprint tier used to live in Constants.Combat
	(SprintSpeedMultiplier, SprintStage2*) because the combat monolith owned WalkSpeed. It no longer
	does -- Server/Systems/RunSystem.lua does -- and running is not a combat mechanic: it is the thing
	a player does for the ninety percent of the session they are not fighting. Keeping the ladder here
	means retuning the run never touches a combat file, and the combat layer's own speed effects
	(hit-slow, dash, a committed-attack lock) compose ON TOP through the Attribute seam RunSystem
	documents, rather than by sharing a table with it.

	Does not own: when a stage actually changes (RunLadder.lua resolves it, RunSystem.lua drives it),
	or anything about parkour traversals.
]]

local RunConstants = {}

-- ONE NORMAL RUN SPEED. Stage 1 is the only sprinting speed: holding sprint never earns a faster
-- gear. The ordered table remains the seam RunLadder and RunSystem share, so stage 0 can still mean
-- "not sprinting" without adding a second speed path.
export type StageDefinition = {
	-- The stage's own id, and its index in the array. Published verbatim on the Humanoid as
	-- AttributeConstants.SprintStage, so it is the number every client-side consumer keys off.
	Id: number,
	-- Multiplier on the effective base walk speed (Constants.Combat.BaseWalkSpeed + the per-player
	-- BonusWalkSpeed Attribute, itself scaled by the admin SpeedMultiplier Attribute). A multiplier
	-- rather than an absolute speed so a bloodline/stat system that raises the base rescales every
	-- gear proportionally instead of flattening the ladder.
	SpeedMultiplier: number,
	-- Seconds of unbroken, actually-granted running required to ENTER this stage from below. Stage 1
	-- is 0: engaging sprint at all is the whole requirement.
	ChargeSeconds: number,
	-- Hysteresis. Once this stage is held, it survives until the charge falls below this FRACTION of
	-- its own ChargeSeconds, rather than dropping the instant the charge dips under the entry
	-- requirement. Without it a single frame in which the tier is not granted -- brushing a doorframe,
	-- the instant between two movement inputs -- drops a gear and then re-earns it a few frames later,
	-- which on the client means the onset kick and the animation crossfade replaying every time the
	-- player clips a wall. Ignored for stage 1, which has nothing below it to fall to.
	SustainFraction: number,
}

-- THE ONE NORMAL SPRINT, against the effective base speed of 18: 32.4 studs per second. Stage 1 is
-- retained as the shared RunSystem/RunController representation of a held sprint; there is no higher
-- speed to earn from prolonged running.
--
-- Bound through a local because Luau has no type-annotation syntax for a table FIELD assignment
-- (`RunConstants.Stages: {StageDefinition} = ...` is a parse error). The annotation is worth the extra
-- line: it is what makes a malformed stage entry -- a missing SustainFraction, a typo'd field name --
-- a type error here rather than a nil arithmetic crash inside RunLadder at runtime.
local stages: { StageDefinition } = {
	{
		Id = 1,
		-- The normal sprint: 18 effective base speed * 1.8 = 32.4 studs/s. This is the only speed a
		-- player receives while sprinting, regardless of how long they hold the input.
		--
		-- ParkourConstants.Locomotion.SprintSpeed MIRRORS THIS BY HAND and must move with it. Nothing
		-- checks that: the comment there cites a Shared/ConstantsValidation.lua that does not exist.
		SpeedMultiplier = 1.8,
		ChargeSeconds = 0,
		SustainFraction = 0,
	},
}

RunConstants.Stages = stages

-- These charge settings remain the generic RunLadder inputs. With one stage, MaxChargeSeconds is 0,
-- so they cannot produce a speed increase; keeping them avoids a special one-stage resolver path.
RunConstants.ChargeDecayMultiplier = 2.0

RunConstants.StopGraceSeconds = 0.35
RunConstants.StopDecayMultiplier = 6.0

-- Minimum Humanoid.MoveDirection magnitude that counts as "genuinely moving" for charge accrual.
-- Holding the run key while standing still is not running, and letting it build charge would mean a
-- player could stand in a corner for sixteen seconds and then leave at top speed.
RunConstants.MoveInputThreshold = 0.1

-- WalkSpeed ramp rates, in studs per second per second. They smooth the transition between walking,
-- the normal sprint, and movement locks; no sprint-to-sprint speed transition remains.
RunConstants.WalkSpeedAcceleration = 90
RunConstants.WalkSpeedDeceleration = 140

-- HOW MUCH OF A HELD GEAR A SWING KEEPS (2026-10-06, "combat feels clunky"). A combat commitment pins the body
-- to walking pace (Server/Systems/RunSystem.lua's header), and for a guard, a stagger or a stun that is right.
-- For the player's OWN swing it made pressure stop-start: every M1 thrown on the run dropped ~32 studs/s to 18,
-- so chasing with a string meant stalling on every press. Now a swing (and nothing else) moves at
--
--   base x max(1, held gear's multiplier x SwingGearCarry)
--
-- -- walking stays walking (the max), and a sprint gear (x1.8) carries about 1.26x base through the swing. The
-- published stage is still walking: you are not SPRINTING mid-swing, you are pressing forward. 0 restores
-- plain walking pace for every commitment.
RunConstants.Combat = {
	SwingGearCarry = 0.7,
}

RunConstants.Network = {
	RemoteNames = {
		-- Client -> server, fired ONLY on the edges of sprint intent (pressed, released) rather than
		-- per-frame or per-tick. Intent is a boolean that changes a couple of times a minute; anything
		-- more than an edge is bandwidth spent restating something the server already knows.
		--
		-- There is deliberately no server -> client counterpart. The resolved stage travels as a
		-- Humanoid Attribute (AttributeConstants.SprintStage), which replicates to EVERY client for
		-- free -- so a remote player's own client can pick the matching run animation for them with no
		-- per-stage broadcast of ours. Same reasoning as Attributes.ParkourState's own note.
		SetSprinting = "Run_SetSprinting",
	},
	-- Sprint intent is an edge-driven boolean, so a legitimate client fires it a handful of times a
	-- minute. This budget is generous against that specifically to absorb a player mashing the key --
	-- which is annoying but not an attack -- while still bounding a client that has decided to fire it
	-- every frame. A dropped intent edge self-corrects on the next one, so throttling here is safe in a
	-- way throttling a parkour action report is not.
	MaxIntentPerSecondPerPlayer = 12,
}

-- The highest charge the clock will hold, derived from the ladder. The one normal-speed stage needs
-- no charge, so this is zero and a long run cannot earn an acceleration.
local maxCharge = 0
for _, stage in stages do
	if stage.ChargeSeconds > maxCharge then
		maxCharge = stage.ChargeSeconds
	end
end
RunConstants.MaxChargeSeconds = maxCharge

-- THE RUN SYSTEM'S PRESENTATION TABLE -- everything about how running LOOKS and SOUNDS, in one
-- place, so retuning the run never means grepping three client modules.
--
-- The run has one sustained sprint speed. The server publishes stage 1 while sprinting and stage 0
-- otherwise; the presentation entries below supply the normal run's animation and cadence.
--
-- Owned by Client/Movement/RunController.lua (the presentation driver) and Client/FX/RunAudio.lua
-- (the sound registrations). Moved here from Constants.Run, which is now a re-export of this
-- module. The reason its old header gave for living in Constants.lua -- that RunAudio's definitions
-- need Constants' own SoundDefinition type -- is exactly what the move had to give up: see the note
-- on Footsteps.Stages[1].Sound below. What it buys is that a stage now has ONE home, instead of its
-- threshold and speed living here while its sound, animation and FOV pull lived a file away.
-- FOOTSTEPS. There is no footstep audio in the base game (Roblox's own stock "Running" sound is a
-- single looped scuff, not a step cadence), so this is a real system rather than a re-skin: the
-- run controller re-derives a step interval every frame from live planar speed and fires a
-- one-shot per footfall.
--
-- Interval-driven rather than animation-marker-driven on purpose. A marker-driven step
-- (GetMarkerReachedSignal) is only as reliable as the authored markers in whatever clip is
-- currently playing, and this system has to keep working through an unavailable animation asset, a
-- combat action silencing the run loop, and the parkour framework taking the body over mid-stride.
-- Speed-scaled intervals need nothing from the asset and degrade to "slightly wrong cadence"
-- instead of "no footsteps at all."
RunConstants.Footsteps = {
	-- Master switch. False silences the whole footstep layer (the run keeps every other cue).
	Enabled = true,
	-- Whether to mute Roblox's own stock "Running" Sound on the character (the looped scuff the
	-- default RbxCharacterSounds script plays out of HumanoidRootPart). On by default because
	-- leaving it audible under real footsteps reads as two unrelated surfaces at once. Muted per
	-- life via Volume = 0 rather than destroyed -- the default script owns that Instance, and
	-- deleting something another script expects to exist is how you get a stream of errors from
	-- code you don't own.
	SilenceDefaultRunSound = true,

	-- Hard bounds on the scaled interval. The lower bound is what stops a momentum-carry burst
	-- from turning the cadence into a machine-gun; the upper bound stops a near-stopped player
	-- from taking one step every two seconds before the run states drop out entirely.
	MinIntervalSeconds = 0.15,
	MaxIntervalSeconds = 0.6,

	-- The normal sprint's one footstep sound. Client/FX/RunAudio.SetStepSound can swap it at runtime
	-- without a restart. An empty SoundId is the codebase's standard "not authored yet" placeholder:
	-- SoundManager.Play already no-ops on it, so shipping with one costs a debug log and nothing else.
	--
	-- PoolSize 3 lets a step re-trigger before the prior sample ends. PitchJitter randomizes each
	-- play's PlaybackSpeed by +/- that fraction to avoid an identical-sample metronome effect.
	--
	-- ReferenceSpeed is the speed that stage's StepIntervalSeconds was authored FOR. The live
	-- interval is scaled by ReferenceSpeed / currentSpeed, so a player slowed to a crawl takes
	-- slower steps and a downhill momentum carry takes faster ones, without any stage needing its
	-- own curve.
	Stages = {
		[1] = {
			StepIntervalSeconds = 0.33,
			ReferenceSpeed = 32,
			PitchJitter = 0.07,
			-- Sliced out of the combined asset: the first second is a speed whoosh this system no
			-- longer plays (StageOnset below is a pure camera cue now, not audio) and the second
			-- after it is a RUN of several steps. The region here is ONE step's worth out of that
			-- run, not the whole second -- a slice containing four footfalls, retriggered every
			-- 0.33s, would layer four-step bursts on top of each other rather than producing a
			-- stride.
			--
			-- 1.0 -> 1.25 is a first-pass slice; nudge the start by ear until it lands right on a
			-- step transient (a start slightly BEFORE the transient just adds a hair of silence,
			-- which is harmless -- starting slightly after clips the attack, which is what makes a
			-- footstep sound soft and wrong).
			-- Shape matches Constants.SoundDefinition (SoundId/Volume/PoolSize?/PlaybackRegion?) and is
			-- read as one by RunAudio.SetStepSound, but carries no `:: SoundDefinition` annotation. That
			-- type is exported from Constants.lua, and Constants.Run re-exports THIS module -- importing
			-- it back to annotate one table would close a require cycle. ParkourConstants.Dash.Sound
			-- already makes the same call for the same reason (keeping that file free of requires); the
			-- consumer's own parameter type is what still checks the shape.
			Sound = {
				SoundId = "rbxassetid://76038309546970",
				Volume = 0.35,
				PoolSize = 3,
				PlaybackRegion = NumberRange.new(1.0, 1.25),
			},
		},
	},
}

-- No stage-onset cue: there is no higher speed to announce.
RunConstants.StageOnset = {}

-- ANIMATION. Stage 1 keeps CombatConstants.AnimationIds.Running, the ordinary sprint loop.
RunConstants.Animation = {
	-- Playback speed for the run loop, keyed by stage. Applied on stage CHANGE only, never per
	-- frame: CombatAnimator.FreezeActiveCombatTrack (hit-stop) drives the same property, and a
	-- per-frame write here would silently cancel every freeze that landed on a running player.
	--
	PlaybackSpeeds = {
		[1] = 1,
	},
	-- Retained for the armed-run animation handoff in CombatAnimator.
	StageCrossfadeSeconds = 0.2,
}

return RunConstants
