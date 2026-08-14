--!strict
--[[
	ParkourConstants.lua

	Owns: every tunable number the parkour/movement framework reads -- speeds, accelerations,
	durations, probe distances, height thresholds, assist windows, camera feel, animation ids,
	network budgets and validation caps. Single source of truth for the whole feature: no module
	under Shared/Parkour/, Client/Parkour/ or Server/Systems/ParkourSystem.lua is allowed to hardcode
	a movement number of its own, so retuning movement feel is always an edit to THIS file and
	nothing else (the explicit ask this system was built against: "movement values ... should not be
	hardcoded throughout the system").

	Lives beside Shared/QiConstants.lua / TierConstants.lua / ArtConstants.lua / BountyConstants.lua
	/ EmoteConstants.lua rather than inside Shared/Constants.lua, following the convention this repo
	already settled on for a feature with a large tuning surface of its own: Constants.lua stays the
	home for cross-system tunables every System reads, and a feature this size would otherwise add
	~400 lines to a file that is already 3,700. The handful of parkour values that genuinely ARE
	cross-system (the Humanoid Attribute NAMES the server writes and the client reads) stay in
	Constants.Attributes, not here -- see that table's own ParkourVelocityOwned/ParkourState/
	ParkourSpeedFloor entries.

	Units, stated once so no field below has to repeat them: distances/heights are STUDS, speeds are
	STUDS PER SECOND, accelerations are STUDS PER SECOND SQUARED, durations/windows are SECONDS,
	angles are DEGREES (converted to radians at the one or two call sites that need radians, the same
	"easier to eyeball and retune than raw radians" convention Constants.Intro.Camera already uses).

	Does not own: any decision made FROM these numbers (Shared/Parkour/ParkourMath.lua,
	ObstacleClassifier.lua and the Client/Parkour/States/ modules own that), or any runtime state.
	This file is read-only data, exactly like Constants.lua -- nothing mutates a field here, and
	Client/Input/KeybindManager.lua's own "clone before mutating" discipline applies to any consumer
	that wants a mutable copy of a table in here.
]]

local ParkourConstants = {}

-- Master switch consulted by Client/Parkour/ParkourController.lua at bind time and by
-- Server/Systems/ParkourSystem.lua when validating a reported action. False disables the entire
-- framework and falls the game back to the pre-parkour behavior (CombatClient.lua's own legacy
-- Slide/Sprint path, Roblox's stock character controller for everything else) -- see
-- ParkourController.SetEnabled's own header for why that fallback is a real, exercised path and not
-- a dead branch: the player-facing "Parkour movement" Settings toggle drives exactly this.
ParkourConstants.Enabled = true

-- Ordinary ground/air locomotion -- the continuum Idle/Walking/Sprinting share. Speeds are
-- deliberately aligned with the combat layer's own established numbers (Constants.Combat.
-- BaseWalkSpeed 10 + DefaultBonusWalkSpeed 8 = 18 effective, times SprintSpeedMultiplier 1.5 = 27)
-- so a parkour-driven sprint and a combat-driven sprint read as the SAME speed rather than two
-- systems disagreeing about how fast "running" is. If Constants.Combat's numbers are retuned, these
-- two should move with them -- Shared/ConstantsValidation.lua asserts the relationship at boot.
ParkourConstants.Locomotion = {
	WalkSpeed = 18,
	SprintSpeed = 27,
	-- The SECOND run stage's speed (Constants.Combat.SprintStage2SpeedMultiplier 2.0 x the same
	-- effective base 18), reached after Constants.Combat.SprintStage2ThresholdSeconds of unbroken
	-- running -- see that constant's own header for why a sustained tier this fast is safe.
	--
	-- Mirrored here for the same reason SprintSpeed above is: the framework's own target-speed
	-- reporting (States/StateSupport.GroundTargetSpeed) has to agree with what the server's WalkSpeed
	-- resolver is actually granting, or the debug overlay and every future consumer of DesiredSpeed
	-- describe a run that isn't happening. Retune Constants.Combat's multiplier and this moves with it.
	--
	-- Everything downstream that keys off momentum -- the slide's entry speed, the wall-run's minimum,
	-- the vault's speed floor -- becomes easier to reach at this speed, which is intended: reaching
	-- full stride SHOULD open up the traversal moves. Nothing needed retuning for it, because every
	-- one of those thresholds is a MINIMUM, and the validator's own ceilings (Validation.
	-- MaxReportedSpeed 110, MaxTravelSpeed 140) sit far above even a stage-2 downhill slide.
	SprintStage2Speed = 36,

	-- How fast momentum climbs toward the target speed on the ground. Deliberately high enough that
	-- a standing start still feels immediate (0 -> 27 in ~0.32s) -- the "extremely responsive" bar
	-- this system is held to -- while still being a real ramp rather than an instant snap, which is
	-- what makes a slide/vault/wall-jump exit carrying extra momentum actually READ as extra
	-- momentum instead of being erased on the first frame of ground contact.
	Acceleration = 100,
	-- Ground deceleration when there's no held input (or when over the target speed). Lower than
	-- Acceleration on purpose: overspeed bleeds off gradually so momentum earned from a slide or a
	-- wall-jump survives a moment of neutral input instead of evaporating.
	Deceleration = 75,
	-- Extra bleed applied ON TOP of Deceleration while momentum is ABOVE the state's own target
	-- speed. This is the single knob that decides how long "earned" speed lasts -- raise it to make
	-- momentum feel disposable, lower it to make chaining more rewarding. Currently tuned so a slide
	-- exit at ~34 decays to sprint speed (27) in roughly half a second of running.
	OverspeedDecay = 14,

	-- Air control: the fraction of ground acceleration usable while airborne, and the cap on how
	-- much the player may REDIRECT existing horizontal momentum mid-jump. Two separate knobs on
	-- purpose -- a low AirAccelerationFraction alone would also prevent steering, which reads as
	-- floaty and unresponsive; this pair lets a jump keep its committed speed while still allowing
	-- meaningful mid-air aim.
	AirAccelerationFraction = 0.45,
	AirTurnRateDegreesPerSecond = 220,

	-- How long a finished parkour action's earned speed survives as a WalkSpeed floor before decaying
	-- to nothing (Constants.Attributes.ParkourSpeedFloor, applied by
	-- Server/Combat/Movement.ComputeParkourSpeedFloor). This is the server-side half of momentum: the
	-- client simulates the action, reports the speed it ended with, and this window is how long that
	-- speed keeps the server's own WalkSpeed resolver from snapping the player back to sprint pace.
	-- Long enough that a slide-jump lands still fast, short enough that a single well-timed slide is
	-- not a sustained speed buff.
	MomentumCarrySeconds = 0.9,

	-- Ceiling on the momentum floor above, as a multiple of SprintSpeed. A hard cap on how fast the
	-- server will let a reported parkour exit make anyone run, independent of the plausibility
	-- validator -- so even a report that passes validation cannot translate into unbounded ground
	-- speed. Belt and braces on the one number a client can influence. Deliberately well BELOW
	-- Slide.MaxSpeed: exiting a fast downhill slide should carry real speed into the run that follows,
	-- but running at slide speed on the flat is not something the carry is meant to grant.
	MomentumCarryMaxMultiplier = 2.2,

	-- How fast the server's own WalkSpeed ramps toward whatever the resolver currently wants. This is
	-- what turns the combat layer's tiered, instantaneous WalkSpeed into something with real
	-- acceleration and deceleration, without either system needing to know about the other: the tiers
	-- keep deciding the TARGET, and this decides how fast the property gets there. Deliberately
	-- matched to the client-side Acceleration/Deceleration above so the framework's own momentum
	-- belief and the server's WalkSpeed converge on the same curve.
	WalkSpeedAcceleration = 85,
	WalkSpeedDeceleration = 55,

	-- How fast the framework's own momentum belief is pulled back toward the character's MEASURED
	-- planar speed while Roblox's character controller is the one driving (DriveMode "Humanoid").
	-- The framework and the engine must not be allowed to disagree about how fast the character is
	-- moving -- every traversal decision keys off momentum -- but reconciling instantly would let a
	-- single frame of wall contact or a physics hiccup erase speed the player legitimately earned.
	-- High enough to converge within ~0.2s, slow enough to ignore a one-frame dip.
	MomentumReconcileRate = 130,

	-- Below this planar speed the controller reports Idle rather than Walking -- also the "is this
	-- character actually moving" threshold every state module shares, so there is exactly one
	-- definition of standing still. Matches Constants.Combat.MovementInputMagnitudeThreshold's role
	-- on the INPUT side (that one thresholds held stick/key magnitude; this one thresholds resulting
	-- speed) -- both are needed, they answer different questions.
	IdleSpeedThreshold = 1.5,

	-- Held-input magnitude below which there is no movement intent at all. Same value and same
	-- meaning as Constants.Combat.MovementInputMagnitudeThreshold -- duplicated here rather than
	-- cross-required so ParkourMath.lua stays free of a Constants.lua dependency (it is pure,
	-- headlessly testable math per its own header); ConstantsValidation.lua asserts the two agree.
	InputMagnitudeThreshold = 0.1,
}

ParkourConstants.Jump = {
	-- Upward velocity injected by a parkour-initiated jump (coyote jump, buffered jump, slide-jump,
	-- ledge-hop). Matches Roblox's own default JumpPower of 50 so a parkour jump and a stock
	-- Humanoid jump reach the same apex -- players must never be able to tell which code path threw
	-- their jump.
	JumpVelocity = 50,

	-- Coyote time: how long after WALKING OFF a ledge a jump input still counts as a ground jump.
	-- The single most-felt forgiveness window in a movement system of this kind; 0.12s is long
	-- enough to rescue a genuine "I pressed it right as I left the edge" and short enough that it
	-- never reads as a free double jump. Gated by Assists.CoyoteTime below.
	CoyoteTimeSeconds = 0.12,

	-- Jump buffering: a jump pressed while still airborne fires automatically on landing if the
	-- landing happens within this window. Same forgiveness reasoning as CoyoteTimeSeconds, on the
	-- other side of the ground contact. Gated by Assists.JumpBuffer below.
	BufferSeconds = 0.15,

	-- The window used INSTEAD of BufferSeconds when Assists.JumpBuffer is off. Not a smaller
	-- forgiveness window -- it is the press-to-step delivery gap, and it exists so that turning the
	-- assist off narrows buffering rather than deleting the press.
	--
	-- This is a real bug's fix, not a hypothetical. InputBuffer.PeekJump used to pass the assist flag
	-- straight through to ParkourMath.BufferLive's `enabled` parameter, which short-circuits to false
	-- before it ever looks at the timestamp. So JumpBuffer = false made PeekJump return false for
	-- EVERY press at EVERY instant -- and PeekJump is the "was jump pressed at all" test behind
	-- Jumping.CanEnter, WallJumping.CanEnter, Leaping.CanEnter, LedgeClimbing.CanEnter,
	-- LedgeHanging's climb branch and Sliding's slide-jump exit. A player who turned off one
	-- forgiveness toggle in Settings silently lost wall-jumps, leaps, slide-jumps and ledge climb-ups
	-- entirely, while ordinary jumping kept working (Roblox's own control script owns Space), which
	-- is about as confusing as a settings toggle can get.
	--
	-- InputBuffer.PeekDoubleJump already had this right and says so in its own comment -- that
	-- preference is about jumps firing LATE, and an action that never fires at all is a different
	-- complaint. Sized to cover one step at a bad framerate (20fps): a press is stamped by
	-- ParkourInput's InputBegan handler and read on the next controller step, so a window of zero
	-- would drop presses to a race rather than to a preference.
	UnbufferedWindowSeconds = 0.05,

	-- Fraction of current planar momentum preserved through a jump. 1.0 (full preservation) is
	-- correct for a momentum-based system -- a jump should never be a speed penalty -- and is kept
	-- as an explicit tunable rather than an implicit "just don't touch velocity" so a future design
	-- pass can tax jumping if it turns out to be strictly dominant.
	MomentumRetainFraction = 1,

	-- Minimum interval between two parkour-initiated jumps. Purely an anti-double-fire guard for the
	-- buffer/coyote paths (both can otherwise resolve on the same frame from one press), not a
	-- gameplay cooldown.
	MinIntervalSeconds = 0.1,

	-- How close together two jump presses must be to read as a DOUBLE TAP -- the input for the leap
	-- (Leap below). Comfortably longer than MinIntervalSeconds (so the two presses of a deliberate
	-- double tap are never rejected as one press double-firing) and short enough that two ordinary
	-- jumps taken in quick succession -- a hop, then another hop a third of a second later -- are not
	-- mistaken for one.
	DoubleTapSeconds = 0.26,
}

-- THE LEAP: a long, committed jump aimed at wherever the player is looking, on a double tap of jump.
--
-- It exists because the ordinary jump is deliberately modest -- it is tuned against the combat layer's
-- own speeds, and making it cover real ground would change every fight in the game -- while traversal
-- genuinely needs a move that crosses a courtyard. Separating the two by INPUT rather than by tuning is
-- what lets both be right: a single tap is the jump the combat system was balanced around, and a double
-- tap is the traversal move, and neither has to compromise for the other.
--
-- The arc is SOLVED, not fixed (ParkourMath.SolveLaunchVelocity, the same solver the assisted wall-jump
-- flies): the probe finds the FARTHEST landable surface along the player's own view direction that the
-- caps can actually reach, and the launch is computed to land on it. Farthest rather than nearest is
-- the whole character of the move -- a leap that picks the near ledge when you are plainly looking at
-- the far one has misread you, and the near one was reachable with an ordinary jump anyway.
ParkourConstants.Leap = {
	-- How far along the view direction the scan looks for somewhere to land, and the near cut-off below
	-- which a surface is not worth a leap (an ordinary jump already covers it).
	MaxRange = 96,
	MinRange = 12,
	-- How many points along the view ray are tested for a floor beneath them. Each costs two casts (the
	-- floor, then its headroom), so this is the dominant term in the scan's ray budget -- see
	-- Probe.MaxScanRaysPerEvent.
	RangeSamples = 5,
	-- How far above and below each sample point the floor search reaches. Generous downward, because a
	-- leap across a gap onto a LOWER roof is one of the most natural uses of the move.
	SurfaceScanAbove = 6,
	SurfaceScanBelow = 30,
	-- Headroom a landing surface needs before it counts as somewhere to land.
	SurfaceHeadroom = 5,
	-- How far past the near edge of a found surface the landing point is pulled, along the leap
	-- direction. This is the "perfect ledge jump" in one number: aiming at the exact point a downward
	-- cast happened to find puts the landing on the lip, where half the character is over the drop and a
	-- stud of error is a miss. Aiming a little further in makes the same arc land on the surface.
	LandingInsetStuds = 2.2,

	-- THE SURFACE YOU ARE ALREADY ON, AND THE ONES BESIDE YOU, and why they need a rule of their own.
	--
	-- The scan finds candidates by casting DOWNWARD from points along the view ray, which is what lets it
	-- find a lower roof across a gap or a courtyard floor below -- and which also means that on any
	-- reasonably large platform, the thing under those sample points is the platform the player is
	-- standing on. Combined with "take the farthest", that produced leaps to a spot on the player's own
	-- floor: technically the most distant landing found, and obviously not what anyone asked for by
	-- double-tapping jump.
	--
	-- The rule is not a blanket ban, because a leap down your own ramp or along your own rooftop IS a
	-- legitimate thing to want. It is a DIRECTNESS requirement: the surface you are standing on, and
	-- anything close enough to be part of where you already are, may only be chosen when the view ray
	-- itself lands on it -- when you are looking straight at the spot rather than merely looking over it.
	-- Anything genuinely elsewhere is unaffected.
	--
	-- How close counts as "where you already are", measured in three dimensions from the launch rather
	-- than planar like MinRange, so a landing directly below or above the player is caught too.
	IgnoreNearRadius = 18,

	-- The surplus over the exact solution. MUCH smaller than the wall-jump's ReachMargin (1.09), and the
	-- difference is the point: overshooting into a wall face is free, where overshooting a LANDING means
	-- sailing off the far side of the ledge you were aiming at. Just enough to absorb a frame of error.
	ReachMargin = 1.025,
	-- Apex clearance above the landing point, so the arc comes down ONTO the surface rather than into the
	-- lip in front of it.
	ApexClearance = 2.5,
	-- Launch caps. Both are well clear of Validation.MaxReportedSpeed/MaxVerticalGainStuds, so a
	-- legitimate leap can never have its own report refused.
	MinUpSpeed = 42,
	MaxUpSpeed = 72,
	MaxPlanarSpeed = 95,

	-- What a leap with nothing to aim at does. It is never a dud: the player asked for distance, so they
	-- get distance, just not aimed at anything in particular. This is also what a leap into open air
	-- (off a cliff, across a canyon with no far side in range) produces, which is a legitimate thing to
	-- want.
	FallbackPlanarSpeed = 58,
	FallbackUpSpeed = 52,

	-- THE LEAP FLIES ITS WHOLE ARC. Not a window after which control returns -- a backstop, in case a
	-- leap somehow never reaches ground or a ledge, so the state can never own the body indefinitely.
	--
	-- The wall-jump hands control back after a fraction of its flight, and that is right there: its
	-- promise is a direction, and the player steering the back half is part of the move. A leap's promise
	-- is a precise LANDING on a specific ledge, and Roblox's own air control would undo it in two ways --
	-- steering the arc off line, and, worse, actively decelerating it, since the engine pushes an
	-- airborne character toward WalkSpeed in their input direction and a leap flies at roughly twice
	-- that. Holding forward during your own leap would slow it down. So the constraint drives the whole
	-- flight, and the arc that was solved is the arc that happens.
	--
	-- Ending is by arrival, not by clock: States/Leaping exits on ground contact or on a ledge catch.
	-- This number only bounds the pathological case.
	MaxFlightSeconds = 1.4,
	-- Minimum time the state holds even if it thinks it has landed, so a leap taken from a standstill
	-- next to a wall does not end on its own launch frame.
	MinFlightSeconds = 0.08,
	-- A leap is a committed traversal move, not a movement mode. The cooldown stops it being mashed, and
	-- States/Leaping.CanEnter additionally requires the character to have touched the ground since the
	-- last one -- together those are what keep it from being a flight system.
	CooldownSeconds = 0.9,
}

-- Slide: a momentum CONTINUATION, not a separate scripted move. Entry requires real speed, the
-- slide itself only ever decays (or accelerates downhill), and every exit hands its live momentum
-- to the next state rather than resetting it -- see States/Sliding.lua.
ParkourConstants.Slide = {
	-- Minimum planar speed to start a slide at all. Just under SprintSpeed so a slide is reliably
	-- available the instant sprint is up to speed, but a walking player can't slide.
	EntryMinSpeed = 24,
	-- One-shot multiplier applied to entry momentum, so committing to a slide is rewarded with a
	-- burst rather than merely preserving what you had. 34 studs/s from a 27 sprint.
	EntryBoostMultiplier = 1.26,
	-- Floor on entry momentum when the slide starts on a slope steep enough to sustain one
	-- (SustainSlopeDegrees below). A multiplier alone cannot start a slide that began from a standstill
	-- -- 0 * anything is 0 -- and the slide drives the body through a velocity constraint, so a slide
	-- entered at zero speed PINS the character in place for the half-second the integrator needs to
	-- build any, which reads as the input having done nothing at all. This is the "the hill started
	-- you" speed: below WalkSpeed, so it is never a burst, and gated on a real downhill so it can never
	-- be farmed as a free shove on the flat. Applies to forced slides too -- walking onto a cliff face
	-- has exactly the same zero-entry problem.
	DownhillEntrySpeed = 14,
	-- Hard ceiling on slide speed. Reached ONLY downhill -- a flat slide always decays under friction
	-- and never approaches this -- so it is a safety rail on terrain-driven acceleration rather than a
	-- governor on sliding generally.
	--
	-- Was 46 (a bare 1.7x sprint), which was the single biggest reason a steep descent felt wrong: the
	-- slide reached the cap in about a fifth of a second and then held there, so the whole sensation
	-- of a slope accelerating you never happened -- you simply moved at a constant, unremarkable speed
	-- down a cliff. Nearly 3x sprint speed is what makes a genuine drop read as committed and
	-- dangerous; the flat-ground slide is completely unaffected by this number.
	MaxSpeed = 80,
	-- Slide ends (transitions to Walking/Sprinting) once momentum decays below this. Suspended while
	-- terrain is carrying the slide, exactly like MaxDurationSeconds -- see SustainSlopeDegrees.
	MinExitSpeed = 15,

	-- FLAT-GROUND friction, in studs/s^2. Scaled by cos(slope) inside
	-- ParkourMath.IntegrateSlideSpeed -- see that function's own header for why friction has to fall
	-- away as a slope steepens. Tuned so a flat slide from 34 lasts roughly 1.1s before hitting
	-- MinExitSpeed: long enough to clear a gap or duck a swing, short enough that spamming it is
	-- slower than just sprinting.
	FrictionPerSecond = 17,
	-- How much of real gravity the slide receives along the surface. Well under 1 on purpose -- a
	-- sliding body has genuine drag, and full gravity down a steep face is uncontrollable rather than
	-- exciting. This replaced a linear per-degree term that under-read badly on steep slopes; see
	-- ParkourMath.IntegrateSlideSpeed. THE knob for how hard terrain pulls: raise for a more punishing,
	-- more committed descent, lower for a gentler one.
	SlopeGravityFraction = 0.7,
	-- Multiplier on the (negative) slope pull while sliding uphill -- so sliding up a ramp dies almost
	-- immediately and is never a viable way to travel.
	UphillFrictionScale = 2.2,

	-- Below this signed downhill angle, a slide is running on its entry burst and expires on
	-- MaxDurationSeconds or on MinExitSpeed. At or above it the slide is being carried by terrain, and
	-- BOTH of those exits are suspended -- a long hill should last as long as the hill does. Without
	-- this, a genuine descent was cut off mid-slope for no reason the player could see, which read as
	-- the system giving up on them. Releasing the slide key still ends it either way; this only
	-- suspends the automatic exits, never the player's own control.
	--
	-- Also the threshold that waives the entry-speed requirement and applies DownhillEntrySpeed, so
	-- "the terrain is carrying this slide" means exactly one thing everywhere in this feature. Note
	-- this is well BELOW the ~7 degrees at which SlopeGravityFraction's pull first exceeds
	-- FrictionPerSecond -- any slope that sustains a slide is one the slide genuinely accelerates on.
	SustainSlopeDegrees = 12,

	-- Hard cap on a single slide on flat or near-flat ground, where it would otherwise run until
	-- friction alone finished it. Suspended on a real downhill -- see SustainSlopeDegrees above.
	MaxDurationSeconds = 1.6,
	-- Minimum time a slide must run before it can be voluntarily cancelled into Walking/Sprinting --
	-- stops a tapped slide key from producing a one-frame animation pop. A slide can still be
	-- exited INSTANTLY at any time by jumping, rolling, vaulting or being hit; this only gates the
	-- "released the key, stand back up" exit.
	MinDurationSeconds = 0.18,
	CooldownSeconds = 0.45,

	-- How much the character is lowered while sliding (a HipHeight delta, restored on exit). This is
	-- what lets a slide pass under a low obstacle -- combined with the ceiling probe in
	-- EnvironmentProbe.lua, which is what stops a slide from ENDING while still under one.
	HipHeightDelta = 1.6,

	-- CONTACT LOSS TOLERANCE -- the three numbers that decide whether a frame without ground contact
	-- ends the slide or is ridden out.
	--
	-- The slide used to hand straight off to Falling the instant Ground.Grounded went false, which is
	-- correct for sliding off a roof and badly wrong for everything else, because a grounded slide loses
	-- contact for a frame or two all the time: the crest of a ramp, a seam between two parts, a bump, and
	-- -- the case that made this urgent -- any moment the character's own animated mass tips the root far
	-- enough that a straight-down cast from its centre reads longer than GroundedDistance. A slide down a
	-- slope with a real clip on it was ending within a few frames of entry for exactly that reason, while
	-- the same slide with no animation attached ran to completion.
	--
	-- The grace is deliberately gated on the floor still being THERE (SurfaceGraceDistance, measured from
	-- the sole exactly like Ground.Distance) rather than on time alone, so it cannot turn sliding off an
	-- edge into a moment of hanging in the air: over a real drop the floor leaves the band on the first
	-- frame and the slide ends immediately, as before.
	SurfaceGraceSeconds = 0.16,
	SurfaceGraceDistance = 3.6,
	-- Downward bias applied to the commanded velocity to hold the body against the surface. The first is
	-- the ordinary bump-smoothing pull; the second is what re-seats the character during the grace window
	-- above, and is deliberately much stronger -- the whole point of the window is to get contact BACK,
	-- and pulling at the cruising value would just spend it drifting.
	SurfaceStickSpeed = 8,
	SurfaceRecoverStickSpeed = 30,
	-- Steering authority while sliding, in degrees per second. Non-zero (a slide you cannot aim at
	-- all reads as a cutscene) but well below normal turn rate, so a slide still commits.
	SteerRateDegreesPerSecond = 130,

	-- Fraction of live slide momentum carried into a jump taken out of the slide. Above 1 on purpose
	-- -- the slide-jump is the intended skill-expression chain of this whole system, and it should
	-- pay slightly more than the sum of its parts.
	JumpOutRetainFraction = 1.08,
	-- Fraction carried into a roll taken out of a slide.
	RollOutRetainFraction = 0.95,
}

-- Obstacle traversal. Height bands are measured from the character's FOOT plane (root position
-- minus half the root part's height), so they read as real-world "knee/waist/chest/head" heights
-- independent of rig scale. ObstacleClassifier.lua is the single consumer.
ParkourConstants.Obstacle = {
	-- How far in front of the character the forward probe looks. Scaled up with speed (see
	-- ProbeDistanceSpeedScale) so a fast approach gets more reaction distance.
	ProbeDistance = 3.2,
	ProbeDistanceSpeedScale = 0.055,
	ProbeMaxDistance = 6,
	-- Vertical spacing between the stacked forward rays that measure an obstacle's top edge. Finer =
	-- more accurate height classification, more rays. 0.35 gives ~10 samples over the full 0-3.5
	-- stud band this system cares about.
	HeightSampleStep = 0.35,
	-- Everything at or below this is stepped over silently by Roblox's own character controller --
	-- the classifier reports "Step" and the parkour system deliberately does nothing, rather than
	-- playing a vault animation for a curb.
	StepMaxHeight = 1.2,
	-- Knee-to-waist: a quick hop-over with a short, snappy traversal. No hands-down animation.
	HopMaxHeight = 2.6,
	-- Waist-to-chest: the full hands-down vault.
	VaultMaxHeight = 5,
	-- Above VaultMaxHeight and up to this, the obstacle is a MANTLE target instead (pull yourself
	-- onto the top) rather than something to vault over.
	MantleMaxHeight = 7.5,
	-- Deeper than this and it isn't an obstacle to vault OVER, it's a wall/platform -- the
	-- classifier routes it to Mantle (if the top is reachable and standable) or refuses.
	VaultMaxDepth = 3,

	-- Minimum planar speed required to vault/hop. A standing player gets a mantle or nothing --
	-- vaulting is a momentum move.
	VaultMinSpeed = 12,
	-- Mantling has no speed requirement (you can pull yourself up from standing) but does need the
	-- obstacle within reach.
	MantleMaxReach = 3.4,

	-- How far off dead-on the character's CURRENT travel direction may sit from the obstacle's inward
	-- face normal and still be allowed to vault/mantle it. This is a LIVE check, deliberately separate
	-- from ObstacleProbe.TravelDirection (the frozen direction the obstacle was originally found
	-- along) -- it exists to catch the case where the probe's cached obstacle is still sitting there
	-- but the player's own input has since diverged from it (let go and reversed, a strafe that walked
	-- past the wall's edge), which is what let a mantle or vault fire backward or sideways into
	-- geometry the character was no longer actually approaching. 65 degrees is wide enough to allow a
	-- real diagonal sprint into a corner (which this system should still catch) while refusing anything
	-- past roughly "running along the wall" -- 90 degrees would be dead sideways, and this sits well
	-- short of that.
	MaxApproachAngleDegrees = 65,

	-- Clearance required on the FAR side of a vaultable obstacle before the vault is allowed --
	-- vertical drop room and a horizontal footprint for the character to land in. Without this
	-- check, vaulting a wall with a wall right behind it drops the character inside geometry.
	LandingClearanceHeight = 3.6,
	LandingClearanceRadius = 1.6,
	-- Headroom required above the obstacle's top surface for a mantle to be legal -- there has to be
	-- somewhere to actually stand.
	StandClearanceHeight = 5.2,

	-- Traversal durations. Short and distinct so each action reads as its own beat; every one of
	-- these is the duration of a kinematic (CFrame-driven) traversal, so they are also literally how
	-- long the player is not in control -- keep them tight.
	HopDurationSeconds = 0.3,
	VaultDurationSeconds = 0.42,
	MantleDurationSeconds = 0.55,

	-- Fraction of entry momentum returned at the end of each traversal. A hop barely costs anything;
	-- a full mantle costs most of it (you stopped and pulled yourself up).
	HopExitRetainFraction = 0.98,
	VaultExitRetainFraction = 0.88,
	MantleExitRetainFraction = 0.35,
	-- Minimum planar speed granted on traversal exit even when the retain fractions above would
	-- produce less -- landing a vault into a dead stop reads as a bug, not a cost.
	ExitMinSpeed = 10,

	-- Extra forward push applied at the END of a vault, past the obstacle's far edge, so the
	-- character clears the lip rather than clipping it.
	VaultExitForwardStuds = 1.4,

	CooldownSeconds = 0.25,
}

-- Ledge detection, hanging and climbing. Distinct from Obstacle above: an OBSTACLE is something in
-- front of a grounded character; a LEDGE is an edge grabbed while AIRBORNE (jumped short, fell past
-- an edge, kicked off a wall).
ParkourConstants.Ledge = {
	-- Only grabbable while falling (or rising slower than this) -- a player still rocketing upward
	-- out of a jump shouldn't snap onto a ledge they're about to clear anyway.
	MaxVerticalSpeedToGrab = 12,
	-- How far ahead the grab probe reaches, and the vertical band (relative to the character's head)
	-- an edge must fall within to be grabbable. Reach is measured from the ROOT's centre, so roughly a
	-- stud of it is spent crossing the character's own torso before it reaches open air.
	GrabReachDistance = 3.4,
	-- Asymmetric on purpose, and the asymmetry is about how far the grab MOVES you. An edge above the
	-- head puts the hang pose within a few tenths of a stud of where the character already is (the lip
	-- is HangVerticalOffset above the hanging root), so reaching further up costs the player nothing;
	-- an edge below the head yanks them down by nearly the whole band on top of that offset, and a
	-- generous lower band is how a grab starts feeling like being swallowed by the wall.
	GrabBandAboveHead = 1.8,
	GrabBandBelowHead = 2.4,
	-- Radius of the spherecast that finds the wall face. Lateral forgiveness, in one cast: see
	-- EnvironmentProbe.tryLedgeDirection for why a zero-width ray from the root's centre line is the
	-- wrong instrument for "is the player reaching for this".
	GrabProbeRadius = 0.7,
	-- How far the top of the grab band stretches UPWARD to cover the ground a fast fall covers between
	-- two probe samples. Without it the band is a 4.2-stud window that a terminal-velocity fall steps
	-- straight over at any frame rate below ~60, and the grab that "didn't register" was never offered.
	-- Capped rather than unbounded: past a couple of studs the resulting pull upward stops reading as
	-- catching yourself and starts reading as being teleported.
	GrabSweepMaxStuds = 2.5,
	-- How far apart travel and facing must be before the probe spends a second cast on facing as well.
	-- Below this they are the same question asked twice.
	GrabDirectionSplitDegrees = 22,
	-- The other end of that same comparison: past this many degrees of divergence, travel is not a
	-- strafe-along-the-face anymore, it is the character moving substantially AWAY from where they are
	-- looking -- a backpedal into a wall behind them, most commonly, since shift lock
	-- (Client/Camera/ShiftLockCamera.lua) makes travel and facing fully independent. That is motion,
	-- not a reach, so travel is not even tried as a search direction past this threshold -- only facing
	-- is, which correctly finds nothing behind the character and leaves the fall uninterrupted. Set
	-- just SHORT of a right angle: at 90 travel has no forward component left in the character's own
	-- frame at all, so everything at or past it is sideways-or-worse and cannot be a reach. The
	-- legitimate "strafing along a face while staring at it" grab is untouched by the tightening --
	-- that case is found by the FACING cast, which runs precisely because the two have diverged.
	GrabDirectionMaxSplitDegrees = 85,
	-- THE GRAB'S FACING GATE, and the one that actually decides -- the two constants above only steer
	-- where the probe CASTS, which is not the same question as whether to COMMIT. However the edge was
	-- found, the character's own facing (RootPart.CFrame.LookVector) must point within this many
	-- degrees of INTO the grabbed face, because facing the wall is the pose a hang actually holds
	-- (States/LedgeHanging.Enter). Without this, the search heuristic was the only thing between a
	-- shift-locked player and an automatic, no-button grab of an edge they never looked at.
	-- Wider than Obstacle.MaxApproachAngleDegrees on purpose: a grab is a CATCH, and an arcing fall
	-- legitimately arrives with the camera some way off the face, where a mantle is something the
	-- player deliberately walked into. Still inside a right angle, so an edge purely to the
	-- character's side -- or behind them -- is refused.
	MaxGrabFacingAngleDegrees = 75,
	-- How far off vertical a surface may tilt and still count as a grabbable FACE. Guards the hang
	-- pose: ParkourMath.HangPosition backs the character off along the face's horizontal normal, and a
	-- near-horizontal "face" (the top of the lip itself, which a spherecast can legitimately clip)
	-- has no horizontal normal to back off along -- so the pose collapses into the wall.
	MaxFaceTiltDegrees = 38,
	-- Where the character's root ends up relative to the grabbed edge while hanging.
	HangVerticalOffset = -2.4,
	HangHorizontalOffset = -0.85,
	-- How long a hang can be held before the character drops automatically. Hanging is a transition,
	-- not a resting place.
	MaxHangSeconds = 6,
	-- THE PULL INTO THE HANG POSE, and why it is a speed rather than a duration.
	--
	-- The root is anchored for the whole hang, so without a blend the grab is a single-frame CFrame
	-- write: the character teleports up to ~4 studs into the pose, instantly, with a rotation snap on
	-- top of it. That teleport is what a grab "feeling clunky" actually is -- there is no motion to
	-- read, just a discontinuity.
	--
	-- A fixed duration cannot fix it, because the distance varies by an order of magnitude: a grab made
	-- with the hands already at the lip moves a few tenths of a stud, one caught at the far edge of the
	-- reach (or pulled UP to a lip the sweep above let the player catch on the way past) moves several.
	-- One number short enough for the near case pops in the far one; one long enough for the far case
	-- turns the near one to mush. So the pull runs at a SPEED, floored and capped -- near grabs resolve
	-- in a frame or two, far ones get long enough to read as a snatch.
	AttachSpeed = 30,
	AttachMinSeconds = 0.05,
	AttachMaxSeconds = 0.14,
	ClimbDurationSeconds = 0.6,
	-- Momentum granted on top after a climb-up. Low on purpose -- a climb is the slow option; the
	-- fast option was to not fall short.
	ClimbExitSpeed = 12,
	-- Lockout after voluntarily dropping from a ledge, so the same edge isn't re-grabbed on the next
	-- frame of the resulting fall. Scoped to the edge that was dropped (see LedgeHanging's own
	-- isBlockedLedge) rather than to ledges in general: descending a stepped face by dropping from
	-- one lip to the next is a legitimate and good way to move, and a blanket half-second of deafness
	-- to every edge in the world is what made it feel like the system had stopped responding.
	RegrabLockoutSeconds = 0.45,
	-- The blanket half of the same lockout, kept short. Long enough that the release push has moved
	-- the body clear of the face before anything can be caught again, short enough to be invisible.
	RegrabAnyLedgeSeconds = 0.15,
	-- How close a candidate edge has to be to the dropped one to count as the same edge. A wall face
	-- is usually several parts, so an instance test alone lets a drop re-grab the neighbouring block
	-- half a stud sideways -- which strands the player exactly where they asked to leave.
	RegrabIgnoreRadius = 3.5,
	-- Headroom needed above the ledge for the climb to be legal (nothing to stand on/in = no climb).
	StandClearanceHeight = 5.2,
	StandClearanceRadius = 1.4,

	-- WHERE THE CLIMB ACTUALLY PUTS YOU. The climb used to end at a position DERIVED from the lip --
	-- one authored step in from the edge, at the edge's own height -- which is only correct when the top
	-- of the ledge is a flat plane continuing back from the lip at exactly the height the lip was found
	-- at. Real geometry is rarely that: a parapet has a lower walkway behind it, a stepped roof rises
	-- behind its edge, a sloped roof's lip is its lowest point, and a railing has nothing behind it at
	-- the lip's height at all. In every one of those the derived position was somewhere the character
	-- could not stand -- floating over the walkway, buried in the step, hovering off the slope.
	--
	-- So the climb now MEASURES the surface it is pulling onto (EnvironmentProbe.FindStandSurface): a
	-- short ladder of downward casts at increasing insets from the lip, taking the first one that is
	-- both standable and has headroom. These are that ladder's parameters. The insets are in studs from
	-- the lip, along the climb direction.
	ClimbInsetMin = 1,
	ClimbInsetMax = 2.6,
	ClimbInsetSamples = 3,
	-- How far above and below the lip's own height each inset sample looks for the real surface. Up
	-- covers a step or a rise behind the edge; down covers a parapet with a lower floor behind it, and is
	-- the deeper of the two because a drop behind a lip is both more common and more punishing to get
	-- wrong.
	ClimbSurfaceScanAbove = 2.4,
	ClimbSurfaceScanBelow = 4.5,
	-- Headroom a measured surface needs before the climb will end on it. Shorter than
	-- StandClearanceHeight above (which gates whether the ledge is climbable AT ALL, cast at the lip)
	-- because this one is cast further in, where a low ceiling is a reason to pick a different inset
	-- rather than to refuse the climb.
	ClimbSurfaceHeadroom = 4.2,

	-- Air required beneath the HANGING character's feet, on top of the rig's own foot offset, for a
	-- grab to be offered at all. The counterpart to StandClearanceHeight above, on the underside of
	-- the edge.
	--
	-- Without this, any edge inside the grab band was grabbable no matter how low it sat, and the hang
	-- pose (HangVerticalOffset below the lip, plus the rig's ~3 studs from root to sole) put the
	-- character's feet BELOW the floor they jumped from. The root is anchored during a hang, so the
	-- result was a character jammed upright into the ground while the state readout said LedgeHanging
	-- -- which is also how jumping at a mantle-height wall stole the mantle and turned it into a grab.
	-- Same reasoning as WallRun.MinGroundClearance: hanging one stud off the floor is just standing.
	HangFootClearance = 0.5,
}

ParkourConstants.WallRun = {
	-- Entry requires real speed AND a wall within reach AND ground clearance -- all three, see
	-- States/WallRunning.CanEnter.
	MinEntrySpeed = 20,
	-- Speed held along the wall. Slightly under SprintSpeed so wall-running is a traversal option
	-- rather than a strictly faster way to travel in a straight line.
	Speed = 26,
	MaxSpeed = 36,
	-- How far sideways the wall probes reach from the root.
	--
	-- Raised from 2.6 for the chimney climb. 2.6 studs from the root is roughly "shoulder against the
	-- wall", which is the right requirement for STARTING a wall-run off a run-up -- you have to commit to
	-- the surface -- and much too strict for the other thing these probes now feed: a player rising
	-- between two walls arrives near a face rather than pressed against it, and at 2.6 the wall they are
	-- plainly next to did not exist as far as States/WallJumping.CanEnter was concerned. That is a large
	-- part of why a corridor climb "ran out": not a chain limit, just the next kick never being offered.
	ProbeDistance = 3.2,
	-- Multiplier on that reach for the FORWARD-DIAGONAL fallback cast, which only runs while airborne and
	-- only when the straight side cast found nothing -- see EnvironmentProbe.probeWall. Longer than the
	-- straight reach because a diagonal has to cross the same lateral gap over a longer hypotenuse, and
	-- because the case it serves is a character flying INTO a surface, where a little extra warning is
	-- the difference between a wall-jump that fires and one that fires a frame after contact.
	DiagonalProbeScale = 1.45,
	-- A surface only counts as a wall if its normal is within this many degrees of horizontal --
	-- this is what stops the system from letting players "wall-run" up a gentle ramp or along a
	-- ceiling.
	MaxSurfaceTiltDegrees = 22,
	-- The angle between travel direction and the wall's tangent must be under this for entry --
	-- running straight AT a wall shouldn't start a wall-run, running ALONG it should.
	MaxApproachAngleDegrees = 62,
	-- The same question asked of FACING instead of travel; both have to pass. The travel check above
	-- cannot catch a backwards wall-run on its own, because ParkourMath.WallTangent ORIENTS the tangent
	-- to agree with travel -- so travel-vs-tangent can only ever refuse running INTO a wall, never
	-- running along one the wrong way round. Facing is the independent witness, and under shift lock
	-- (Client/Camera/ShiftLockCamera.lua) it is a genuinely different vector: WASD is camera-relative
	-- with AutoRotate off, so holding S past a wall hands the tangent a perfectly good backward
	-- direction to run while the character is looking the other way down it. Looser than the travel
	-- threshold because glancing off-axis mid-approach is normal and shouldn't cost the entry; tight
	-- enough that facing sideways or backwards relative to the run direction does.
	MaxFacingAngleDegrees = 70,
	-- Minimum clearance below the character for a wall-run to start or continue -- wall-running six
	-- inches off the floor is just running.
	MinGroundClearance = 3.4,

	MaxDurationSeconds = 2.2,
	-- Vertical behavior across the run: an initial rise, then a decay to a controlled slide down the
	-- wall as the run expires. GravityFraction is how much of normal gravity still applies once the
	-- rise window is over -- non-zero so a long wall-run visibly sinks, which is what makes the
	-- duration limit legible without a UI element.
	RiseSeconds = 0.45,
	RiseSpeed = 13,
	GravityFraction = 0.32,
	-- Inward force keeping the character glued to the wall against its own outward drift.
	StickSpeed = 6,

	-- After leaving a wall, that SPECIFIC wall part can't be re-attached to for this long -- this is
	-- the anti-cheese rule that stops infinite vertical climbing by re-triggering the same surface.
	-- A DIFFERENT wall is available immediately, which is exactly the chained wall-jump the design
	-- asks for.
	SameWallLockoutSeconds = 0.9,
	-- Global re-entry cooldown after any wall-run ends, so a dismount doesn't instantly re-latch.
	ReattachCooldownSeconds = 0.18,
	-- Total wall-runs allowed without touching the ground -- the second anti-infinite-climb rule,
	-- covering the "three walls in a triangle" case SameWallLockoutSeconds alone doesn't.
	--
	-- Raised from 3 alongside the assisted wall-jump (WallJump.Assist below). Three was tuned for a chain
	-- the player had to aim by hand, where the fourth link was rarely reached anyway; with the jump
	-- solving its own trajectory to a real surface, a long traversal across a courtyard is a thing players
	-- will now actually complete, and cutting it off at three reads as the system giving up mid-line. The
	-- anti-infinite-climb guarantee does not rest on this number -- SameWallLockoutSeconds still forbids
	-- laddering one surface, and the assist refuses to aim at the wall it just left -- so raising it costs
	-- reach, not safety.
	MaxChainWithoutGround = 6,

	-- THE CHAIN SPEED RAMP: every wall-jump taken without touching the ground makes the NEXT wall-run
	-- faster, by this much, up to ChainMaxSpeed. This is the reward half of the chain -- the falloff on
	-- the jump itself (WallJump.ChainFalloffMultiplier) keeps a chain from becoming free ALTITUDE, and
	-- this keeps it from becoming pointless: a five-link line across a courtyard should end visibly faster
	-- than it started, which is what makes committing to the long route worth more than dropping to the
	-- ground and sprinting.
	--
	-- Applied to both ends of the entry clamp in States/WallRunning.Enter, so the ramp raises the FLOOR
	-- (a late link never scrapes along slower than an early one) as well as the ceiling.
	ChainSpeedBonus = 3.4,
	-- Hard ceiling on the ramp, reached at roughly the sixth link. Comfortably under Slide.MaxSpeed --
	-- terrain should still be the fastest thing in the game -- and far under Validation.MaxReportedSpeed,
	-- so a legitimately long chain can never have its own movement rejected.
	ChainMaxSpeed = 44,
}

ParkourConstants.WallJump = {
	-- Away-from-wall push and upward kick. The push is what makes a wall-jump a REPOSITION rather
	-- than just a second jump.
	PushSpeed = 26,
	UpSpeed = 46,
	-- Fraction of the pre-jump along-wall momentum carried through. Above zero so a wall-jump taken
	-- out of a fast wall-run travels further than one taken from a standstill against a wall.
	ForwardRetainFraction = 0.55,
	-- Brief window after a wall-jump during which air control is reduced, so the push actually
	-- carries the character away from the wall instead of being immediately steered back into it
	-- (which is how chained wall-jumps degenerate into climbing one flat surface).
	ControlLockSeconds = 0.16,
	-- Each consecutive wall-jump without touching the ground is weaker, by this multiplier. Caps the
	-- height a pure wall-jump chain can gain without banning the chain outright.
	--
	-- Applies to the UNASSISTED jump only. An assisted jump (Assist below) composes its velocity from a
	-- solved trajectory instead, and scaling that by a falloff would mean deliberately aiming at a
	-- surface and then deliberately throwing short of it -- the falloff's job is done there by the
	-- solver's own vertical cap and by the fact that a jump can only be aimed at a surface that exists.
	ChainFalloffMultiplier = 0.86,
	-- Raised again, from 8, once the chimney climb (Assist.Corridor* below) made a genuinely VERTICAL
	-- chain possible: a kick gains around 11.8 studs, so eight of them cap the climb at roughly 90 studs
	-- and a taller shaft would strand the player partway up a wall for no reason they could see. Twelve
	-- covers any structure a player is likely to be asked to climb.
	--
	-- The cap is not what makes the climb bounded, which is why raising it is cheap: a corridor kick
	-- requires a wall that FACES the one being left (so a single wall cannot be laddered),
	-- Assist.SameWallCooldownSeconds forbids taking two kicks off the same face without crossing, and
	-- the climb ends when the walls do. This number is the backstop, not the mechanism.
	MaxChainWithoutGround = 12,
	MinIntervalSeconds = 0.12,

	-- THE ASSIST: what turns a wall-jump from "a push away from this wall" into "a jump AT the next
	-- surface." On every wall-jump the framework casts a short fan of rays across the open side, ranks
	-- what it finds, and -- when something qualifies -- solves the ballistic velocity that lands the
	-- character on it, rather than applying the fixed PushSpeed/UpSpeed pair above. A jump with nothing
	-- to aim at falls back to that fixed pair unchanged, so the plain "kick off a wall into open air"
	-- case is exactly what it always was.
	--
	-- The design constraint this satisfies, and the reason the solve is not simply "throw hard at it":
	-- the jump must give *just a little more* than the trajectory strictly needs. Landing exactly on the
	-- mathematical minimum means every frame of error is a miss, and a miss on a chained traversal is the
	-- whole chain. ReachMargin is that surplus, and it is small enough that the arc still reads as a
	-- jump the player made rather than as being fired from a cannon.
	Assist = {
		-- Master switch, so the whole behavior can be turned off in one place if a design pass wants the
		-- hand-aimed chain back.
		Enabled = true,

		-- How far the target scan reaches, and the near cut-off below which a surface is too close to be
		-- worth aiming at (it is already within an ordinary push's reach, and solving for it produces a
		-- comically weak hop).
		ScanDistance = 42,
		MinTargetDistance = 6,
		-- Half-width of the scan fan, in degrees either side of the aim direction, and how many rays span
		-- it. An odd count keeps one ray dead on the aim direction. These rays are an EVENT cost -- at most
		-- once per wall-jump, never per frame -- which is why they are budgeted separately from
		-- Probe.MaxRaysPerFrame; see Probe.MaxScanRaysPerEvent.
		ScanYawSpreadDegrees = 78,
		ScanRayCount = 9,
		-- A second, shorter arc of rays angled upward, so a ledge or a balcony ABOVE the character's own
		-- height is findable at all -- a flat fan only ever finds things level with the jump.
		ScanPitchDegrees = 26,
		ScanPitchRayCount = 3,

		-- How the fan's hits are ranked. Alignment is how nearly the candidate sits along the direction
		-- the player is actually asking to go (facing blended with the push away from the wall);
		-- proximity prefers the nearer of two equally-aimed surfaces, because the nearer one is the one
		-- the player can see themselves reaching; and squareness prefers a surface whose face is turned
		-- toward the character, which is what makes the arrival a wall-run or a grab rather than a graze.
		AlignmentWeight = 1,
		ProximityWeight = 0.45,
		SquarenessWeight = 0.55,
		-- Below this, a candidate is not in the direction the player asked for and is not offered at all,
		-- whatever else it scores. Expressed as a dot product against the aim direction rather than an
		-- angle because it is a rejection threshold rather than a measurement.
		MinAlignmentDot = 0.12,
		-- Likewise for squareness: a face angled this far away from the character cannot be landed on in
		-- any useful way, so aiming at it would be a jump into a glancing scrape.
		MinSquarenessDot = 0.3,
		-- How far the wall the character just left is treated as "the same wall" for the purposes of
		-- refusing to aim back at it. The Instance check alone is not enough -- a wall face is usually
		-- several parts, and aiming at the neighbouring block half a stud sideways is the infinite ladder
		-- with extra steps. Same reasoning, and roughly the same value, as Ledge.RegrabIgnoreRadius.
		SameWallIgnoreRadius = 4,

		-- Where the trajectory is actually aimed: out from the hit face along its own normal, so the
		-- character arrives NEXT TO the surface (where the wall probes can find it and a wall-run can
		-- attach) rather than inside it.
		TargetOutwardOffset = 1.5,
		-- Extra apex clearance above the target, in studs, so the arc passes over the lip of whatever is
		-- being jumped to instead of into its front face.
		ApexClearance = 1.8,
		-- The surplus, applied to the solved horizontal speed: "a little more than enough to reach."
		ReachMargin = 1.09,

		-- Bounds on what the solver is allowed to produce. The vertical cap is the one that matters for
		-- fairness -- it is what stops a well-placed pair of walls from being an elevator -- and is set so
		-- a single assisted jump's own ballistic gain stays inside Validation.MaxVerticalGainStuds. The
		-- horizontal cap keeps a far target from turning into a launch that outruns the camera.
		MinUpSpeed = 34,
		MaxUpSpeed = 62,
		MaxPlanarSpeed = 72,

		-- THE CHIMNEY CLIMB. Between two walls that FACE each other, a wall-jump stops being a jump across
		-- and becomes a jump UP: the arc is aimed at the apex of what the lift can buy, positioned so the
		-- highest point of the flight and the contact with the far wall are the same moment (see
		-- ParkourMath.CorridorKickHeight). Alternate walls and you ascend; the climb tops out into a ledge
		-- grab on its own, because an apex arrival has almost no vertical speed left and that is precisely
		-- what Ledge.MaxVerticalSpeedToGrab asks for.
		--
		-- This is a SEPARATE branch from the ordinary target assist rather than a tuning of it, because
		-- the two are answering different questions -- see CorridorKickHeight's own header. The ordinary
		-- assist aims at a point a ray found, and a ray finds a wall at the height it was cast from, so
		-- every corridor jump it produced was a level crossing that gained nothing.
		--
		-- How far apart two facing walls may be and still be a corridor. Past this it is not a chimney,
		-- it is two walls that happen to be parallel, and the ordinary target assist is the right answer.
		CorridorMaxGap = 26,
		-- The near end. Deliberately much smaller than MinTargetDistance (which exists so the ordinary
		-- assist does not aim at things already within arm's reach): in a chimney, CLOSE IS THE POINT.
		CorridorMinGap = 2.5,
		-- How nearly the two faces must oppose each other, as a dot product between the far wall's normal
		-- and the direction back toward the wall being kicked off. 1 is perfectly parallel facing walls;
		-- this allows roughly fifty degrees of splay, which covers every real stairwell, alley and shaft
		-- while refusing a wall that merely happens to be over there somewhere.
		CorridorOpposedDot = 0.64,
		-- How far either side of straight-out the two extra corridor rays are angled. Small: this is
		-- tolerance for a shaft that is not perfectly square and for a character not perfectly square to
		-- it, not a search. A wide splay would start finding "corridors" that are really one wall and
		-- something off to the side.
		CorridorSplayDegrees = 20,
		-- Lift for a corridor kick, replacing the MinUpSpeed/MaxUpSpeed band. Higher than either, because
		-- height is the entire purpose here and the horizontal cost of a chimney crossing is small. Gains
		-- about 11.8 studs per kick under default gravity -- so a five-storey shaft is five or six kicks --
		-- and a single kick's ballistic gain stays comfortably inside Validation.MaxVerticalGainStuds, which
		-- is what keeps an honest climb from having its own reports refused.
		CorridorUpSpeed = 68,
		-- Shaved off the computed aim height so the solve is never asked for an arc that is EXACTLY at the
		-- edge of what its own vertical cap allows -- at the apex the two agree to the last decimal place,
		-- and a solver that answers "unreachable" to a rounding error would silently drop the assist on
		-- precisely the jump it was written for.
		CorridorHeightSafetyStuds = 0.15,
		-- How long after kicking off a wall that SAME wall stops granting a corridor kick. Without it, a
		-- player hugging one wall can pump the jump key and take kick after kick off the same face without
		-- ever crossing to the other one, which is the free elevator every rule in this feature exists to
		-- prevent. Comfortably longer than Jump.MinIntervalSeconds (so it actually binds on a spam) and
		-- comfortably shorter than a real round trip across a corridor (so it never blocks the legitimate
		-- return to the wall you came from).
		SameWallCooldownSeconds = 0.28,

		-- Replaces WallJump.ControlLockSeconds for an assisted jump only, and is longer for a reason the
		-- unassisted lock does not have: the solved arc is a PREDICTION, and air control applied to it is
		-- the player steering off the trajectory that was computed for them. Long enough that the arc
		-- visibly sets and the assist's promise is kept, short enough that it never reads as the jump
		-- having been taken out of the player's hands -- they can still steer the back half of the flight,
		-- which is where steering is meaningful anyway.
		ControlLockSeconds = 0.24,
	},
}

ParkourConstants.Roll = {
	Speed = 30,
	DurationSeconds = 0.5,
	CooldownSeconds = 0.9,
	-- Fraction of live momentum a roll preserves on exit. Above the slide's, because a roll is the
	-- shorter, more committed option and should reward the correct read.
	ExitRetainFraction = 1,
	-- Rolling out of a landing is the reward for timing a roll input near ground contact -- within
	-- this window before/after touchdown, a roll converts what would have been a hard landing into a
	-- full-momentum continuation. This is the landing/combat interaction the design asks for.
	LandingWindowSeconds = 0.2,
	-- A roll may be started from these states only -- everything else must transition first. Kept
	-- here (not hardcoded in States/Rolling.lua) so a design pass can widen it without touching code.
	AllowedFromStates = {
		Idle = true,
		Walking = true,
		Sprinting = true,
		Sliding = true,
		Landing = true,
		Falling = true,
	},
}

-- Falling and landing. Fall height is measured from the APEX of the fall (the highest point since
-- leaving the ground), not from wherever the character last stood -- see States/Falling.lua.
ParkourConstants.Fall = {
	-- Below this, landing is invisible: straight back into Walking/Sprinting with full momentum.
	SoftLandingHeight = 9,
	-- Between SoftLandingHeight and this, a brief landing beat plays but control is never taken.
	MediumLandingHeight = 22,
	-- Above MediumLandingHeight, a real hard landing: a short recovery during which momentum is cut.
	-- A correctly-timed roll (Roll.LandingWindowSeconds) skips this entirely.
	HardLandingRecoverySeconds = 0.42,
	-- Momentum retained through each landing severity.
	SoftLandingRetainFraction = 1,
	MediumLandingRetainFraction = 0.85,
	HardLandingRetainFraction = 0.35,
	-- Terminal-ish downward speed the controller clamps to while falling, so a very long drop stays
	-- readable (and so landing classification stays bounded).
	MaxFallSpeed = 190,
	-- How long the Landing state holds before handing off to ground locomotion, for the soft/medium
	-- cases. Deliberately short -- the design's "small falls should transition directly into normal
	-- movement" rule.
	LandingHoldSeconds = 0.08,
}

ParkourConstants.Slope = {
	-- Steeper than this and a surface is not standable -- the character slides down it instead of
	-- walking up. Matches Roblox's own default Humanoid slope limit closely enough that the
	-- character controller and this system agree about what "ground" is.
	MaxWalkableAngleDegrees = 55,
	-- At or above this angle, gravity takes over: a grounded character transitions into Sliding whether
	-- they asked to or not (States/Idle, Walking and Sprinting all hand off on it).
	--
	-- Was 48, which was too steep to ever fire on the ramps people actually build -- a big, obviously
	-- steep wedge sits around 35-40 degrees, so running down one did nothing at all and the whole
	-- slope system appeared dead. 38 catches a genuine ramp while staying well clear of ordinary
	-- terrain undulation, and comfortably below MaxWalkableAngleDegrees above: "steep enough that
	-- gravity owns you" should trigger before "too steep to stand on at all", not after it.
	--
	-- THE knob for how eagerly slopes take control. Raise it if ordinary terrain starts sliding you;
	-- lower it if ramps still feel inert.
	ForcedSlideAngleDegrees = 38,
	-- Speed scaling walking up/down a slope, per degree.
	UphillSpeedPenaltyPerDegree = 0.011,
	DownhillSpeedBonusPerDegree = 0.019,
	-- Ground probe: how far below the character to look for a floor, and how far below counts as
	-- genuinely grounded. The gap between the two is the "about to land" band the animator and the
	-- jump buffer both read.
	GroundProbeDistance = 6,
	GroundedDistance = 2.6,
}

-- Raycast/spatial-query budget. Every probe in EnvironmentProbe.lua declares which bucket it
-- belongs to; the controller refuses to exceed MaxRaysPerFrame in a single Heartbeat, deferring the
-- lowest-priority probes to the next frame instead. This is what keeps the system honest during a
-- 20-player fight -- see EnvironmentProbe.lua's own header for the scheduling.
ParkourConstants.Probe = {
	-- Raised from 14 when the ledge probe learned to search a second direction and to fall back to a
	-- ray when its spherecast comes back degenerate: a falling frame's honest worst case (ground 1 +
	-- obstacle 6 + walls 2 + ledge 8) now sits at 17, and a ceiling that starts too low silently
	-- starves the LAST probe in EnvironmentProbe's ordering -- which, while airborne, is the ledge
	-- search itself. This is a per-frame budget for ONE locally-controlled character, not a server
	-- cost; the number is a guard against a runaway probe, not a figure anyone is close to paying.
	-- Raised again to 20 when the wall probes gained their airborne forward-diagonal fallback (two extra
	-- casts, and only on a frame where both straight side casts already missed). An airborne frame's
	-- honest worst case -- ground 1 + obstacle 6 + walls 4 + ledge 8 -- is now 19, and leaving the ceiling
	-- at 18 would silently starve whichever probe runs last, which while airborne is the ledge search.
	MaxRaysPerFrame = 20,
	-- Ceiling on a single EVENT scan -- the wall-jump target fan and the ledge-climb surface ladder.
	-- Deliberately its own budget rather than a slice of MaxRaysPerFrame, because these are a different
	-- kind of cost and conflating them would make both wrong: the per-frame budget bounds a cost paid
	-- sixty times a second forever, where an event scan is paid once per discrete action (a wall-jump, a
	-- climb) at most a handful of times a second even during the fastest chain a player can execute.
	-- Starving a one-shot scan to protect a steady-state budget would mean the assist silently failing on
	-- exactly the busy frames it is most useful.
	--
	-- Event casts still ADD to the frame's used count, so the per-frame probes that run after one degrade
	-- to cached results for that frame rather than pretending the scan was free.
	MaxScanRaysPerEvent = 16,
	-- Refresh intervals per probe family. A probe whose result is still within its interval is
	-- reused from cache rather than re-cast. Ground is every frame (it gates everything); walls and
	-- obstacles are cheaper to run at ~30Hz while not already using them, and are forced to every
	-- frame by the states that actually depend on them.
	GroundIntervalSeconds = 0,
	ObstacleIntervalSeconds = 1 / 30,
	WallIntervalSeconds = 1 / 30,
	LedgeIntervalSeconds = 1 / 30,
	CeilingIntervalSeconds = 1 / 20,
	-- Probes are skipped entirely below this planar speed when the current state doesn't require
	-- them -- a player standing still has nothing to vault into.
	IdleSkipSpeed = 1,
	-- Collision group every parkour probe filters against, so debug/FX parts and other characters
	-- never register as vaultable geometry. Empty string = no group filtering (the default until a
	-- place actually defines one); see ParkourTagging.lua for the per-part opt-out that works
	-- without any collision-group setup at all.
	CollisionGroup = "",
}

-- Configurable movement assists. Every one of these defaults ON (the design's "these should all be
-- configurable rather than permanently forced on players"), is individually persisted through the
-- Settings System, and is honored at the single point where the assist is applied -- never scattered
-- through the state modules.
ParkourConstants.Assists = {
	CoyoteTime = true,
	JumpBuffer = true,
	-- Automatic vault/hop detection while running at an obstacle (vs. requiring an explicit input).
	AutoVault = false,
	-- Automatic ledge grab while falling past a grabbable edge.
	LedgeAssist = true,
	-- Smoothing of sub-StepMaxHeight geometry so small clutter never interrupts a sprint.
	StepAssist = true,
	-- How long an action input stays buffered waiting for its state to become available. Shared by
	-- slide/vault/roll/wall-jump -- jump has its own, tighter Jump.BufferSeconds.
	ActionBufferSeconds = 0.18,
}

-- Camera feel. Every value here is composed through the existing named-slot camera primitives
-- (Client/FX/FOVOffset.lua, CameraOffsetComposer.lua, CameraShake.lua) rather than written to the
-- Camera directly -- see ParkourCamera.lua. Deliberately restrained per docs/ui-ux-philosophy.md's
-- Critical States rule; the design's own constraint was "do not make the camera effects so
-- aggressive that they interfere with combat."
ParkourConstants.Camera = {
	-- Continuous FOV widening, scaled by how far current speed exceeds SprintSpeed. Positive
	-- (widening) unlike Constants.Camera.Sprint.FOVDelta's narrowing -- that one reads as "focusing"
	-- for a combat sprint; this one reads as "going fast" for genuine parkour overspeed, and the two
	-- sum harmlessly through FOVOffset's named slots.
	SpeedFOVMaxDelta = 7,
	SpeedFOVEaseSpeed = 5,
	-- Planar speed at which SpeedFOVMaxDelta is fully applied.
	SpeedFOVFullAtSpeed = 46,

	SlideFOVDelta = -3.5,
	SlideFOVEaseSpeed = 9,
	-- Camera dips slightly during a slide so the low stance reads.
	SlideCameraDropStuds = 1.1,

	-- Roll/wall-run camera tilt, in degrees, applied as camera roll. Small -- a big roll angle is
	-- disorienting and, mid-fight, actively harmful.
	WallRunTiltDegrees = 9,
	WallRunTiltEaseSpeed = 7,

	-- One-shot vertical camera dip on landing, scaled between the soft and hard cases.
	LandingDipSoftStuds = 0.25,
	LandingDipHardStuds = 1.2,
	LandingDipRecoverSpeed = 9,

	VaultFOVPunchDelta = -2.5,
	VaultFOVPunchOutSeconds = 0.09,
	VaultFOVPunchBackSeconds = 0.24,

	-- Named FOVOffset/CameraOffsetComposer slot keys this feature owns. Named here so no two parkour
	-- modules can typo the same slot into two slots.
	SpeedFOVSlot = "ParkourSpeed",
	SlideFOVSlot = "ParkourSlide",
	VaultFOVSlot = "ParkourVault",
	OffsetSlot = "Parkour",
}

-- Camera-shake presets, same {Amplitude, Frequency, DurationSeconds} shape Constants.FX.CameraShake
-- already defines for combat impacts (Client/FX/CameraShake.lua consumes both). Kept here rather
-- than added to that table so the parkour tuning surface stays in one file -- CameraShake.Shake
-- takes a plain preset table and neither knows nor cares which Constants module it came from.
ParkourConstants.Shake = {
	HardLanding = { Amplitude = 0.035, Frequency = 22, DurationSeconds = 0.28 },
	Vault = { Amplitude = 0.012, Frequency = 26, DurationSeconds = 0.14 },
	WallJump = { Amplitude = 0.016, Frequency = 24, DurationSeconds = 0.16 },
	SlideStart = { Amplitude = 0.014, Frequency = 20, DurationSeconds = 0.18 },
}

-- Animation ids per movement action. Placeholder ids (the same shared clip Constants.Intro/
-- Constants.Flight's own AnimationIds tables use as their placeholder) -- swapped for real authored
-- clips as they're produced, with no code change: ParkourAnimator.lua resolves purely by state id +
-- variant, and a missing/placeholder id degrades to "no clip plays," never an error.
ParkourConstants.AnimationIds = {
	SlideStart = "rbxassetid://94692413714016",
	SlideLoop = "rbxassetid://94692413714016",
	SlideEnd = "rbxassetid://94692413714016",
	VaultHop = "rbxassetid://125167812303491",
	VaultOver = "rbxassetid://126138799180188",
	Mantle = "rbxassetid://126138799180188",
	LedgeHang = "rbxassetid://83474290053648",
	LedgeClimb = "rbxassetid://73047490092830",
	WallRunLeft = "rbxassetid://70828439233197",
	WallRunRight = "rbxassetid://86594988194527",
	-- Three wall-jump clips, selected by which side the wall was on, exactly like the wall-run pair
	-- above: kicking off a wall on your left and kicking off a wall on your right are mirrored actions,
	-- and one shared clip plays half of them backwards. WallJump itself is kept as the NEUTRAL case --
	-- a wall square in front of or behind the character, where neither mirror is right -- and as the
	-- fallback the resolver lands on if either directional id is left blank. Both start on the same
	-- placeholder as the old shared clip so nothing regresses before the real mirrored pair is authored;
	-- swapping either one is an id edit here and no code change (see ParkourAnimator's own header).
	WallJump = "rbxassetid://88023924827467",
	WallJumpLeft = "rbxassetid://88023924827467",
	WallJumpRight = "rbxassetid://75811078175435",
	Roll = "rbxassetid://125167812303491",
	-- The double-tap leap. Starts on the vault-over clip as its placeholder because the two are the same
	-- shape of movement -- a committed forward launch -- which makes it the least wrong thing to play
	-- until a real one exists.
	Leap = "rbxassetid://126138799180188",
	LandSoft = "rbxassetid://125167812303491",
	LandHard = "rbxassetid://125167812303491",
	FallLoop = "rbxassetid://125167812303491",
} :: { [string]: string }

-- Animation blend/priority tuning. FadeSeconds is deliberately short across the board: an
-- interruptible movement system that blends slowly reads as unresponsive, and every clip here can
-- be cut off mid-play by the next action (the design's "animations should be interruptible ... so
-- the player does not get locked into an animation").
ParkourConstants.Animation = {
	-- DEFAULT blend times. Every clip may override both (ParkourAnimator's STATE_CLIPS/VARIANT_CLIPS
	-- carry optional FadeIn/FadeOut), and most of the airborne set does -- see BlendProfiles below for
	-- the values and the reasoning. These two are what a clip that has nothing special to say uses.
	--
	-- Raised from 0.08/0.2, and the OLD PAIR IS THE INTERESTING PART: an outgoing clip stopped over
	-- 0.2s while the incoming one reached full weight in 0.08s, and since every parkour clip loads at
	-- the same Movement priority, Roblox blends them by WEIGHT. So for the 0.12s between those two
	-- numbers, two clips were both at or near full weight and the character was playing the average of
	-- a wall-jump and a fall. That average is the muddiness -- it is not a missing blend, it is two
	-- blends that disagreed about how long the transition was.
	--
	-- Matched now, so a transition is a genuine crossfade with a constant total weight: as one clip
	-- gives up weight the other takes exactly that much.
	FadeInSeconds = 0.12,
	FadeOutSeconds = 0.12,

	-- Per-clip overrides, named rather than written inline in the animator so blend feel stays tunable
	-- from this file like every other movement number. The rule behind the three bands:
	--   * SNAP -- an action whose FIRST FRAME is the readable moment. A wall-jump kick, a roll, a vault:
	--     the pose that communicates what happened is at the start, and blending into it slowly means
	--     the character is still half-standing when the informative frame goes past.
	--   * SETTLE -- a loop the character SETTLES into and holds. A fall, a wall-run, a slide: nothing
	--     about the first frame is urgent, and a long blend is what makes entering one read as a
	--     transition rather than a costume change.
	--   * The LEAVING half of a one-shot is always longer than its entry, which is the specific fix for
	--     "wall-jumps look chopped": the kick is a 0.16-0.24s state, so its clip is always cut off
	--     mid-swing by the fall that follows it. A long fade out lets that swing finish underneath the
	--     incoming fall loop instead of being deleted at the transition frame.
	BlendProfiles = {
		Snap = { FadeIn = 0.05, FadeOut = 0.26 },
		Settle = { FadeIn = 0.22, FadeOut = 0.16 },
		Ground = { FadeIn = 0.1, FadeOut = 0.12 },
	},
	-- Movement clips sit at Movement priority so a combat swing (Action priority, CombatAnimator's
	-- own tracks) always visually wins -- the concrete mechanism behind "parkour animations must not
	-- fight combat animations."
	Priority = Enum.AnimationPriority.Movement,
	-- Loop clips whose playback speed scales with actual speed, so a wall-run at 34 doesn't play at
	-- the same cadence as one at 20.
	SpeedScaleReferenceSpeed = 27,
	MinPlaybackSpeed = 0.6,
	MaxPlaybackSpeed = 1.6,
}

-- Environmental interaction. A part opts IN or OUT of specific parkour behaviors either by
-- CollectionService tag or by a Boolean Attribute of the same name -- see ParkourTagging.lua for the
-- precedence rules. Both mechanisms are supported because they suit different authoring workflows
-- (tags for bulk tagging via a plugin, attributes for one-off tweaks in the Properties panel), and
-- neither requires touching code to add a new surface.
ParkourConstants.Tags = {
	-- Opt-outs: present = this part is invisible to that behavior.
	NoParkour = "ParkourIgnore",
	NoVault = "ParkourNoVault",
	NoWallRun = "ParkourNoWallRun",
	NoMantle = "ParkourNoMantle",
	NoLedge = "ParkourNoLedge",
	-- Opt-ins: present = force-allow, overriding the geometric checks that would otherwise refuse
	-- (e.g. a decorative railing thinner than the classifier's minimums, or a slightly-tilted
	-- surface a designer still wants wall-runnable).
	ForceVaultable = "ParkourVaultable",
	ForceWallRunnable = "ParkourWallRunnable",
	ForceMantleable = "ParkourMantleable",
	ForceLedge = "ParkourLedge",
	-- Numeric Attribute (not a tag): multiplies slide friction on this surface, so ice/gravel can
	-- feel different without any per-material table. Absent = 1.
	SurfaceFrictionAttribute = "ParkourFriction",
	-- Numeric Attribute: multiplies momentum retained when this surface is used for a wall-jump.
	WallBounceAttribute = "ParkourWallBounce",
}

-- Networking. The client simulates and the server validates -- so the only traffic this feature
-- generates is one small report per discrete parkour ACTION (start and end), never a per-frame
-- position/velocity stream. See Server/Systems/ParkourSystem.lua's own header for the trust model.
ParkourConstants.Network = {
	RemoteNames = {
		-- Client -> server, fired once when a parkour action begins and once when it ends. The
		-- server validates plausibility, stamps the Humanoid Attributes the combat WalkSpeed
		-- resolver reads, and (for actions other clients need to see) replicates the state tag.
		ReportAction = "Parkour_ReportAction",
		-- Server -> acting client, fired ONLY when a report is rejected -- the rollback signal, same
		-- shape and reasoning as Combat_ActionRejected. A silent accept is the overwhelmingly common
		-- case and costs nothing.
		ActionRejected = "Parkour_ActionRejected",
	},
	-- Action reports share one budget. Generous relative to Constants.NetworkBudget's default 4/s
	-- because a genuinely fast chain (slide -> jump -> wall-run -> wall-jump -> vault) can legitimately
	-- produce several starts and ends within a second, and throttling a legitimate chain would
	-- desync the server's view of who owns velocity -- the exact failure the attack budget's own
	-- MaxAttackCallsPerSecondPerPlayer split already exists to avoid.
	MaxReportsPerSecondPerPlayer = 20,
	-- Minimum interval between two reports of the SAME action kind from one player -- a cheaper,
	-- per-kind guard that catches a stuck client re-firing one action without eating the shared
	-- budget above.
	MinSameActionIntervalSeconds = 0.06,
}

-- Server-side plausibility caps (Shared/Parkour/ParkourValidation.lua). These are deliberately
-- LOOSE: the client owns its own character's physics in Roblox regardless of what this system does,
-- so these exist to catch the crude, obviously-impossible claims (a "wall-jump" that gains 200
-- studs, a vault reported every frame) and to keep an honest client's state machine and the
-- server's view of it in agreement -- not to prevent all movement exploits, which is not achievable
-- for a client-authoritative character and would be dishonest to claim.
ParkourConstants.Validation = {
	-- Ceiling on any reported planar speed. Must stay comfortably above the fastest legitimate chain --
	-- which is a slide at Slide.MaxSpeed down a steep face -- or an honest player on a big hill gets
	-- their own movement rejected. src/Tests/Parkour/StateRegistry.spec.lua asserts the relationship
	-- rather than leaving it to whoever next retunes the slide to remember.
	MaxReportedSpeed = 110,
	-- Ceiling on vertical gain attributable to a single action.
	MaxVerticalGainStuds = 24,
	-- Ceiling on how far a character may have moved between an action's start report and its end
	-- report, per second of elapsed time. Above MaxReportedSpeed with headroom, since a slide that
	-- accelerates throughout can legitimately average close to its peak.
	MaxTravelSpeed = 140,
	-- An action window can never be claimed longer than this, regardless of kind -- backstop against
	-- a client claiming a permanent "I own my velocity" window and never ending it.
	MaxActionSeconds = 8,
	-- How many consecutive rejected reports before the player is flagged through ModerationSystem's
	-- existing suspected-cheater path. High enough that a lag spike or a genuine edge case never
	-- flags an honest player.
	RejectionsBeforeFlag = 25,
	-- Rejection counter decays: a rejection older than this stops counting toward the flag.
	RejectionWindowSeconds = 60,

	-- MOMENTUM-CARRY CROSS-CHECK. The speed a client reports at the end of an action is the one
	-- client-supplied number in this whole feature that reaches gameplay (it becomes the
	-- ParkourSpeedFloor that Movement.ComputeParkourSpeedFloor holds the player's WalkSpeed up to),
	-- so it gets checked against something the SERVER can see for itself rather than only against a
	-- constant ceiling.
	--
	-- The exploit this closes: an End report was honored even with no matching open window, and it
	-- stamped the carry unconditionally. Firing End{Kind="Slide", Speed=110} on a loop -- while
	-- standing still, having never performed a parkour action -- held a permanent WalkSpeed of ~59
	-- against a base of 18. Worse, every one of those reports was ACCEPTED, so the suspected-cheater
	-- counter never moved. Requiring a real window closes the standing-still case; this cross-check
	-- closes the "cycle Start/End at the rate limit to keep claiming 110" variant, because the server
	-- can simply look at how fast the body is actually travelling.
	--
	-- Tolerance and slack are both generous ON PURPOSE. The server's view of a client-owned
	-- assembly's velocity is replicated and therefore slightly stale, and the honest case -- a real
	-- slide ending at real speed -- must never lose its carry to a network hiccup. A cheat claiming
	-- a large speed it isn't moving at is off by far more than this margin, which is the only case
	-- that needs catching. Applied as a CLAMP, not a rejection: a mismatch is more likely lag than
	-- malice, and silently capping the carry to the truth costs an honest player nothing.
	MomentumCarryObservedTolerance = 1.35,
	-- Additive headroom on top of the tolerance, in studs/sec, so that a low-but-legitimate observed
	-- speed (an action ending right as the body is handed back to the Humanoid) isn't scaled down to
	-- nothing by the multiplier alone.
	MomentumCarryObservedSlackStuds = 6,
}

-- Debug mode (Client/Parkour/ParkourDebug.lua) -- Studio-gated dev tooling, same "not a player
-- feature" category as Constants.Debug.Logging.
ParkourConstants.Debug = {
	-- Whether the debug overlay starts enabled. Toggled at runtime with the key below.
	StartEnabled = false,
	-- Raw, non-rebindable key (the same carve-out KeybindManager.lua documents for jump) -- this is
	-- dev tooling, deliberately absent from the player-facing rebind list.
	--
	-- NOT F9: Roblox binds that to its own developer console at the engine level, so the overlay and
	-- the console opened together and the console won. F6 is unclaimed by the engine, unclaimed by
	-- Constants.Keybinds (F8 is OpenBugReport there), and sits in the same "system/meta function-row
	-- key rather than a gameplay key" band that entry's own header reasons about.
	ToggleKeyCode = Enum.KeyCode.F6,
	-- Adorn appearance for visualized probes.
	HitColor = Color3.fromRGB(80, 235, 120),
	MissColor = Color3.fromRGB(235, 90, 90),
	BlockedColor = Color3.fromRGB(245, 190, 70),
	RayThickness = 0.08,
	PointSize = 0.28,
	-- Maximum adorn parts kept alive -- a hard cap so the overlay can never itself become the
	-- performance problem it exists to diagnose.
	MaxAdorns = 64,
	-- How often the text readout refreshes. Every frame is unreadable and wasteful.
	ReadoutIntervalSeconds = 0.1,
	-- How many recent transitions the readout lists.
	TransitionHistory = 6,
}

return ParkourConstants
