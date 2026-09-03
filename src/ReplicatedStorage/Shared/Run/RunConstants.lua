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

	Constants.Run is now a re-export of this module, so existing Constants.Run.Footsteps/StageOnset/
	Animation call sites keep working; new code should require this module directly. That re-export
	widens Constants.Run from the presentation tables alone to this whole file -- nothing reads it
	wholesale (all seventeen call sites go through one of those three keys), but a future one that
	iterated it would now walk the ladder too.

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

-- ONE STAGE OF THE LADDER. Adding or removing a gear is one entry in the Stages array below and
-- nothing else -- RunLadder walks the array rather than branching on a stage number, RunSystem reads
-- whatever RunLadder returns, and the client's presentation layer falls back to the highest stage it
-- has assets for. That property is the whole reason this is an ordered array of records instead of
-- flat SprintStageN* constants, which is what it replaced and what made resizing the ladder a change
-- in five files -- and it is why dropping the third gear back out was a one-entry deletion here.
export type StageDefinition = {
	-- The stage's own id, and its index in the array. Published verbatim on the Humanoid as
	-- Constants.Attributes.SprintStage, so it is the number every client-side consumer keys off.
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

-- THE LADDER, lowest gear first. Multipliers are against the effective base of 18, so the two gears
-- are 32.4 and 54 studs per second.
--
-- Stage 1 is the sprint that has always existed. Stage 2 is most of twice THAT, which makes the top gear a
-- genuine cross-the-map traversal speed rather than a slightly faster jog -- and it is deliberately a
-- large number. The safety argument is not the magnitude, it is what the charge is gated on: the clock
-- only accrues while the run tier is ACTUALLY being granted and the character is genuinely moving, and
-- it decays whenever either stops being true. Anything that interrupts a run -- a swing, a block, a
-- hit, a stun, standing still for a moment -- stops the clock, so the top gear is reachable essentially
-- only out of combat, on open ground. It is a traversal gear, not a fighting gear.
--
-- TWO GEARS, NOT THREE. There was a third at 4.5x -- 81 studs per second, entered at 16 seconds of
-- unbroken running. It is gone, and the ladder is two gears now. A player can tell "sprinting" from
-- "at full stride" at a glance; a rung between them that most of a run never reached bought a
-- distinction nobody could name mid-traversal, and cost a third set of presentation assets to say it
-- with. Everything downstream reads this array, so removing it was this entry plus its keyed entries
-- below (Footsteps.Stages[3], StageOnset[3], Animation.PlaybackSpeeds[3]) and its animation
-- slot in CombatConstants.AnimationIds -- no resolver, System or controller changed.
--
-- The one interruption that deliberately does NOT break the charge is a parkour action (see
-- RunLadder.StepCharge's `held` branch). Vaulting a wall mid-run is the movement system working as
-- designed, and dropping a player out of full stride for using it would teach exactly the wrong
-- lesson about the game's own traversal.
-- Bound through a local because Luau has no type-annotation syntax for a table FIELD assignment
-- (`RunConstants.Stages: {StageDefinition} = ...` is a parse error). The annotation is worth the extra
-- line: it is what makes a malformed stage entry -- a missing SustainFraction, a typo'd field name --
-- a type error here rather than a nil arithmetic crash inside RunLadder at runtime.
local stages: { StageDefinition } = {
	{
		Id = 1,
		-- RAISED FROM 1.5 (27 studs/s). The run CLIP is authored for a faster gait than 27 delivered,
		-- so the bottom gear read as a character whose legs were outrunning them -- and that mismatch
		-- became the normal case once Client/FX/CombatAnimator.lua started pinning armed runs to the
		-- stage-2 clip at every stage. 1.8 is 32.4 studs/s: a fifth faster, still a long way under the
		-- top gear, and still under every traversal threshold that gates on speed (all of which are
		-- MINIMUMS, so a faster stage 1 only makes them easier to reach -- which is intended).
		--
		-- ParkourConstants.Locomotion.SprintSpeed MIRRORS THIS BY HAND and must move with it. Nothing
		-- checks that: the comment there cites a Shared/ConstantsValidation.lua that does not exist.
		SpeedMultiplier = 1.8,
		ChargeSeconds = 0,
		SustainFraction = 0,
	},
	{
		Id = 2,
		SpeedMultiplier = 3.0,
		-- Long enough that it is never reached inside a fight, short enough that a player crossing open
		-- ground feels it every single time rather than only on marathon runs. This is the top gear, so it
		-- is also the ceiling of the charge clock -- MaxChargeSeconds at the bottom of this file derives
		-- from it rather than being authored a second time.
		ChargeSeconds = 7,
		-- ~2.1s of non-running slack at the decay rate below: far more than any flicker, far less than
		-- a real stop.
		SustainFraction = 0.6,
	},
}

RunConstants.Stages = stages

-- How fast accrued charge bleeds off once the run tier stops being granted, as a multiple of the rate
-- it builds at. A decay rather than a hard reset because the alternative punishes exactly the wrong
-- thing: a one-frame gate flicker (a hitch, a doorframe, the instant between two movement inputs)
-- would drop a player who has been running for twenty seconds all the way back to zero. At 2.0 a full
-- top-gear charge is gone after three and a half seconds of not running -- long enough to survive a
-- stumble, far too short to bank.
RunConstants.ChargeDecayMultiplier = 2.0

-- A FLICKER AND A STOP ARE NOT THE SAME EVENT, and the decay above only ever described the first one.
--
-- ChargeDecayMultiplier is deliberately gentle because it has to survive a one-frame gate flicker: a
-- hitch, a doorframe, the instant between releasing one movement key and pressing another. But a
-- gentle decay applied to a GENUINE stop means stopping costs almost nothing -- stand still for half a
-- second, start again, and you are back in top gear immediately, having lost about a second of charge
-- out of seven. That makes the whole ladder free: there is no reason to maintain a run when you can
-- stop, do something else, and resume at full stride.
--
-- So not-accruing is split in two. For the first StopGraceSeconds it decays at ChargeDecayMultiplier,
-- which is the flicker protection and behaves exactly as before. Past that, the player has genuinely
-- stopped running, and the charge bleeds at StopDecayMultiplier instead.
--
-- At 6.0 a full top-gear charge falls below the top gear's own sustain floor about a third of a second
-- after the grace expires, and to nothing about a second after that. The practical effect is the
-- intended one: a momentary interruption keeps your gear, and actually stopping means re-earning it
-- from the full entry requirement rather than from the sustain floor -- you cannot stop and drop
-- straight back into the gear you had.
RunConstants.StopGraceSeconds = 0.35
RunConstants.StopDecayMultiplier = 6.0

-- Minimum Humanoid.MoveDirection magnitude that counts as "genuinely moving" for charge accrual.
-- Holding the run key while standing still is not running, and letting it build charge would mean a
-- player could stand in a corner for sixteen seconds and then leave at top speed.
RunConstants.MoveInputThreshold = 0.1

-- WalkSpeed ramp rates, in studs per second per second. The resolver decides WHAT speed is correct;
-- these decide HOW FAST the property gets there, so a gear change reads as an acceleration rather
-- than a teleport. Deceleration is faster than acceleration because dropping a gear is usually a
-- consequence (a hit, a stop) and should land immediately, where earning one should be felt.
--
-- Both are deliberately larger than the parkour framework's own WalkSpeedAcceleration pair (85/55),
-- which was authored when the top gear was 36. They were raised for a top gear of 81 and are KEPT at
-- 54 rather than walked back with it: stage 1 -> stage 2 is the only gear change this ladder has left,
-- so it should land in about a third of a second rather than most of one -- a gear change nobody can
-- feel is not a gear change.
RunConstants.WalkSpeedAcceleration = 90
RunConstants.WalkSpeedDeceleration = 140

RunConstants.Network = {
	RemoteNames = {
		-- Client -> server, fired ONLY on the edges of sprint intent (pressed, released) rather than
		-- per-frame or per-tick. Intent is a boolean that changes a couple of times a minute; anything
		-- more than an edge is bandwidth spent restating something the server already knows.
		--
		-- There is deliberately no server -> client counterpart. The resolved stage travels as a
		-- Humanoid Attribute (Constants.Attributes.SprintStage), which replicates to EVERY client for
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

-- The highest charge the clock will hold, derived rather than authored so it cannot drift from the
-- ladder. Capped rather than unbounded so charge can't be banked: a player who has run for two
-- minutes loses the top gear on the same timer as one who has run for seven seconds.
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
-- The run is a three-stage sustained sprint (the Stages ladder above -- THAT array, not these three
-- tables, is the single source of truth for each stage's threshold and speed). Stage 1 is the
-- ordinary sprint that has always existed; stages 2 and 3 each engage after their own ChargeSeconds
-- of unbroken running and are genuinely different gears -- a bigger WalkSpeed multiplier, their own
-- animation, their own footstep sound, a deeper FOV pull and a one-shot "kick" at the moment they
-- engage. The STAGE ITSELF is resolved server-side (Server/Systems/RunSystem.lua, via
-- Shared/Run/RunLadder.lua) and published on the Humanoid as Constants.Attributes.SprintStage;
-- nothing in these three tables decides when a stage changes, only what the client does about it.
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
-- currently playing, and this system has to keep working through a placeholder-id stage-2 clip, a
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

	-- ONE STEP SOUND, PITCHED UP PER STAGE. Only stage 1 carries a Sound -- every other stage reuses
	-- that same registered instance and just plays it faster (PlaybackSpeedMultiplier), rather than
	-- registering a second/third asset that was, until this simplification, an identical sample at a
	-- louder volume anyway (see the removed stage-2/3 notes this replaced). A faster gear sounding
	-- like the same stride playing quicker is closer to how a real footfall actually changes than a
	-- separate louder recording ever was. Point Stage 1's Sound at whatever asset you want -- this is
	-- the one place step audio is configured, and Client/FX/RunAudio.SetStepSound can additionally
	-- swap it at runtime without a restart. An empty SoundId is the codebase's standard "not authored
	-- yet" placeholder: SoundManager.Play already no-ops on it, so shipping with one costs a debug
	-- log and nothing else.
	--
	-- PoolSize 3 because a footstep genuinely can re-trigger before the previous one finishes at
	-- stage-2 cadence -- the same overlap reasoning Constants.Combat.Sound's hit/block/parry trio
	-- documents. PitchJitter randomizes each play's PlaybackSpeed by +/- that fraction ON TOP OF
	-- PlaybackSpeedMultiplier, which is the cheapest possible fix for the "identical sample on a
	-- metronome" effect a fixed-interval step system otherwise has.
	-- KEYED BY STAGE ID, not one flat field per stage. The ladder in Shared/Run/RunConstants.lua is
	-- an array precisely so a fourth gear is one entry; this table has to be able to grow the same
	-- way, or "add a stage" is a data change on the server and a code change on the client. Every
	-- reader (Client/FX/RunAudio.lua's registration sweep, Client/Movement/RunController.lua's
	-- cadence) iterates or indexes this table rather than naming StageN, and all of them fall back
	-- to stage 1 for a stage with no entry -- so a ladder that grows before its assets do degrades
	-- to "the new gear sounds like the old one" instead of going silent.
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
		[2] = {
			StepIntervalSeconds = 0.25,
			ReferenceSpeed = 48,
			PitchJitter = 0.07,
			-- No Sound of its own -- stage 1's is reused and pitched up by this factor instead (see
			-- Footsteps' own header above). First-pass number: nudge by ear, the same discipline
			-- stage 1's PlaybackRegion slice used before it was tuned in.
			PlaybackSpeedMultiplier = 1.15,
		},
	},
}

-- THE ONSET KICK -- a pure camera cue now, keyed by the stage being ENTERED: the extra FOV pull
-- that sells a gear change at the instant it engages. Used to also carry a one-shot whoosh Sound;
-- removed in favor of Footsteps.Stages' own PlaybackSpeedMultiplier selling the speed change through
-- the footsteps themselves instead of a second cue competing with them. FOVDelta/FOVEaseSpeed are
-- unchanged by that removal -- RunController reads them exactly as before.
--
-- Stage 1 has no entry and deliberately so: engaging the run at all is not a gear CHANGE, it is the
-- run starting, and it already has the run animation and the footstep cadence to announce it. A
-- pull there would fire every time a player tapped the key.
--
-- FOVDelta is the additional pull layered on top of Constants.Camera.Sprint.FOVDelta while that
-- stage is held (Client/FX/FOVOffset.lua's named-slot composition, so it stacks with the sprint
-- slot rather than fighting it). Negative = narrower, matching Sprint's own convention. These are
-- ABSOLUTE per stage, not cumulative -- RunController writes one slot and simply changes its target
-- as the stage changes, so a ladder carrying several entries here never accumulates their pulls.
RunConstants.StageOnset = {
	-- The ladder's only gear change, so this is the whole camera language of "you are at full stride":
	-- a player who cannot tell which gear they are in has a ladder with no feedback, which is the same
	-- as no ladder. Sized while a third gear still sat above it and took the unmistakable pull for
	-- itself -- worth a second pass by eye now that this IS the top.
	[2] = {
		FOVDelta = -5,
		FOVEaseSpeed = 4,
	},
}

-- ANIMATION. Stage 1 keeps Constants.Combat.AnimationIds.Running (the clip that has always played
-- while sprinting); stage 2 plays RunningStage2 when authored, and falls through to Running when its
-- own id is blank -- the same blank-id fallthrough ParkourAnimator uses for its half-authored
-- directional wall-jump pair, so this ships correctly at every stage of authoring.
RunConstants.Animation = {
	-- Playback speed for the run loop, keyed by stage. Applied on stage CHANGE only, never per
	-- frame: CombatAnimator.FreezeActiveCombatTrack (hit-stop) drives the same property, and a
	-- per-frame write here would silently cancel every freeze that landed on a running player.
	--
	-- Also the fallback that makes an unauthored stage still feel distinct: while a stage's own clip is
	-- blank it plays the stage below's at this rate instead -- see AnimationIds.RunningStage2's own
	-- header. Retune toward 1 once a real clip lands there, or it will read as sped-up/cartoonish
	-- rather than a distinct gear.
	PlaybackSpeeds = {
		[1] = 1,
		-- Slightly hot even when a dedicated stage-2 clip exists -- a full-stride run reads as
		-- urgent, and this is what makes stage 2 visibly different on day one.
		[2] = 1.25,
	},
	-- Crossfade between the two run clips at a stage change. Longer than a combat interrupt cut
	-- (the two clips are the same character doing the same thing harder, so the transition should
	-- read as accelerating, not as swapping costumes) and shorter than a settle.
	StageCrossfadeSeconds = 0.2,
}

return RunConstants
