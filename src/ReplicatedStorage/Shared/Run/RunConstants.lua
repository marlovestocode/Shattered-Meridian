--!strict
--[[
	RunConstants.lua

	Owns: the run's NUMBERS -- the stage ladder itself, what each stage is worth, how long it takes to
	earn, and the conditions under which the charge that earns it builds, holds or bleeds away.

	THE SPLIT, because there are now three tables with "run" in the name and they are not
	interchangeable:
	  * THIS FILE            -- what the run IS. Stage speeds, charge thresholds, hysteresis, decay.
	                            Read by Server/Systems/RunSystem.lua (the authority) and by
	                            Shared/Run/RunLadder.lua (the pure resolver both sides share).
	  * Constants.Run        -- what the run LOOKS AND SOUNDS like. Footstep cadence, per-stage step
	                            sounds, the FOV pull, the onset kick. Client presentation only;
	                            nothing in it decides when a stage changes.
	  * ParkourConstants.Locomotion -- what the parkour framework BELIEVES about ground speed, for its
	                            own entry gates and its debug readout. Mirrors of the tiers below, and
	                            deliberately informational: see MotorCommand.DesiredSpeed's header.
	A number that decides a WalkSpeed belongs here and only here.

	SEPARATE FROM Constants.Combat ON PURPOSE. The sprint tier used to live in Constants.Combat
	(SprintSpeedMultiplier, SprintStage2*) because the combat monolith owned WalkSpeed. It no longer
	does -- Server/Systems/RunSystem.lua does -- and running is not a combat mechanic: it is the thing
	a player does for the ninety percent of the session they are not fighting. Keeping the ladder here
	means retuning the run never touches a combat file, and the combat layer's own speed effects
	(hit-slow, dash, a committed-attack lock) compose ON TOP through the Attribute seam RunSystem
	documents, rather than by sharing a table with it.

	Does not own: when a stage actually changes (RunLadder.lua resolves it, RunSystem.lua drives it),
	what a stage looks like (Constants.Run), or anything about parkour traversals.
]]

local RunConstants = {}

-- ONE STAGE OF THE LADDER. Adding a fourth gear is one more entry in the Stages array below and
-- nothing else -- RunLadder walks the array rather than branching on a stage number, RunSystem reads
-- whatever RunLadder returns, and the client's presentation layer falls back to the highest stage it
-- has assets for. That property is the whole reason this is an ordered array of records instead of
-- three pairs of flat SprintStageN* constants, which is what it replaced and what made "add a third
-- stage" a change in five files.
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

-- THE LADDER, lowest gear first. Multipliers are against the effective base of 18, so the three gears
-- are 27, 54 and 81 studs per second.
--
-- Stage 1 is the sprint that has always existed. Stages 2 and 3 are two and three times THAT, which
-- makes the top gear a genuine cross-the-map traversal speed rather than a slightly faster jog -- and
-- it is deliberately a large number. The safety argument is not the magnitude, it is what the charge
-- is gated on: the clock only accrues while the run tier is ACTUALLY being granted and the character
-- is genuinely moving, and it decays whenever either stops being true. Anything that interrupts a run
-- -- a swing, a block, a hit, a stun, standing still for a moment -- stops the clock, so the upper
-- gears are reachable essentially only out of combat, on open ground. They are traversal gears, not
-- fighting gears.
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
		SpeedMultiplier = 1.5,
		ChargeSeconds = 0,
		SustainFraction = 0,
	},
	{
		Id = 2,
		SpeedMultiplier = 3.0,
		-- Long enough that it is never reached inside a fight, short enough that a player crossing open
		-- ground feels it every single time rather than only on marathon runs.
		ChargeSeconds = 7,
		-- ~2.1s of non-running slack at the decay rate below: far more than any flicker, far less than
		-- a real stop.
		SustainFraction = 0.6,
	},
	{
		Id = 3,
		SpeedMultiplier = 4.5,
		-- Another nine seconds past stage 2. The top gear should feel earned rather than routine: a
		-- player who is genuinely committed to crossing distance gets it, a player who runs between two
		-- fights does not.
		ChargeSeconds = 16,
		-- Tighter than stage 2's. Falling out of the top gear is a bigger, more visible event, so it
		-- gets more protection against a momentary hitch -- but not so much that a real stop leaves the
		-- player coasting at 81 studs per second for seconds afterwards.
		SustainFraction = 0.75,
	},
}

RunConstants.Stages = stages

-- How fast accrued charge bleeds off once the run tier stops being granted, as a multiple of the rate
-- it builds at. A decay rather than a hard reset because the alternative punishes exactly the wrong
-- thing: a one-frame gate flicker (a hitch, a doorframe, the instant between two movement inputs)
-- would drop a player who has been running for twenty seconds all the way back to zero. At 2.0 a full
-- stage-3 charge is gone after eight seconds of not running -- long enough to survive a stumble, far
-- too short to bank.
RunConstants.ChargeDecayMultiplier = 2.0

-- A FLICKER AND A STOP ARE NOT THE SAME EVENT, and the decay above only ever described the first one.
--
-- ChargeDecayMultiplier is deliberately gentle because it has to survive a one-frame gate flicker: a
-- hitch, a doorframe, the instant between releasing one movement key and pressing another. But a
-- gentle decay applied to a GENUINE stop means stopping costs almost nothing -- stand still for half a
-- second, start again, and you are back in top gear immediately, having lost about a second of charge
-- out of sixteen. That makes the whole ladder free: there is no reason to maintain a run when you can
-- stop, do something else, and resume at full stride.
--
-- So not-accruing is split in two. For the first StopGraceSeconds it decays at ChargeDecayMultiplier,
-- which is the flicker protection and behaves exactly as before. Past that, the player has genuinely
-- stopped running, and the charge bleeds at StopDecayMultiplier instead.
--
-- At 6.0 a full stage-3 charge falls below stage 3's own sustain floor about half a second after the
-- grace expires, below stage 2's ENTRY requirement within about a second and a half, and to nothing in
-- under three seconds. The practical effect is the intended one: a momentary interruption keeps your
-- gear, and actually stopping means re-earning it from the full entry requirement rather than from the
-- sustain floor -- you cannot stop and drop straight back into the gear you had.
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
-- Both are deliberately larger than the parkour framework's own WalkSpeedAcceleration pair, which was
-- authored when the top gear was 36: ramping from 27 to 81 at the old rate took most of a second, and
-- a gear change nobody can feel is not a gear change.
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
-- minutes loses the top gear on the same timer as one who has run for sixteen seconds.
local maxCharge = 0
for _, stage in stages do
	if stage.ChargeSeconds > maxCharge then
		maxCharge = stage.ChargeSeconds
	end
end
RunConstants.MaxChargeSeconds = maxCharge

return RunConstants
