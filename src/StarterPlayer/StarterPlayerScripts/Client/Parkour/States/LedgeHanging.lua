--!strict
--[[
	States/LedgeHanging.lua

	Owns: catching and holding a ledge -- the automatic grab while falling past a grabbable edge, the
	held pose, shimmying along it, and the four ways out (climb up, leap to another ledge, drop, time
	out).

	THE SHIMMY (Update, once attached) reads lateral MoveIntent against ParkourMath.WallRight(wallNormal)
	-- a STABLE left/right pair, not WallTangent's travel-oriented one, because a hang has no travel to
	agree with and "left" must mean the same physical direction all the way through a shimmy regardless
	of which way the character last happened to be facing. Each frame that clears the input threshold
	tries ONE step of EnvironmentProbe.ProbeLedgeAt from the candidate new position; a step that finds
	no continuing edge, or one whose wall normal has diverged past Ledge.ShimmyMaxNormalDivergenceDegrees
	(a real corner, or simply the end of the wall), is simply not taken -- the character holds at the
	last position that worked rather than falling or snapping. A committed step re-derives hangCFrame
	the same way Enter does and lets it ride the rigid drive already running every frame; there is no
	separate easing to manage because each step is small enough that the drive's own per-physics-step
	snap already reads as continuous motion, the same way WallRunning's Velocity mode reads as motion
	from a per-frame commanded value rather than a series of teleports.

	THE LEDGE-TO-LEDGE LEAP (Update, on a directional jump press) is a SEPARATE input from the plain
	climb below it, and deliberately: press jump alone and this file's original behavior is completely
	unchanged (climb if there's standing space, drop if there isn't). Press jump WHILE HOLDING A
	DIRECTION and, if EnvironmentProbe.FindLedgeLeapTarget finds a reachable edge along that aim, this
	launches States/LedgeLeaping.lua at it instead -- a route-1 hand-off, with the solved velocity
	written straight into context.Motor on this same frame for the same "the grab bites on the frame
	it's detected" reason the Enter block below does. Finding nothing is not a refusal of the input: it
	falls straight through to the ordinary climb/drop check, so a player who holds a direction without
	genuinely aiming at anything sees no behavior change at all.

	A ledge is a fundamentally different thing from an obstacle, which is why this is not part of
	States/Mantling.lua: an obstacle is something a GROUNDED character walks into and decides what to
	do about; a ledge is an edge an AIRBORNE character catches. The probe geometry is different (a
	band around head height rather than a height ladder from the feet), the entry condition is
	different (falling, not moving fast), and the outcome is different (a hold you can act from,
	rather than a traversal that completes on its own).

	Hanging is a TRANSITION, not a resting place -- MaxHangSeconds drops the character automatically.
	A ledge you can hang from indefinitely is a ledge players use to park, and parking mid-wall in a
	PvP game is a problem rather than a feature.

	Kinematic: the character is pinned to a computed offset from the edge, via
	Client/Parkour/ParkourMotor.lua's rigid (RigidityEnabled = true) AlignPosition drive -- see that
	module's own header for why this is a real, unanchored, network-owned assembly and not an anchored
	CFrame write. Rigid rather than the soft, force-limited drive Velocity mode uses is what makes a
	hang actually hold without drifting or vibrating against the wall it is pressed into: RigidityEnabled
	bypasses MaxForce entirely and solves position exactly every physics step, the same "cannot be shoved
	off its target" guarantee an anchored write gave, without going invisible to every other client the
	way an anchored write did (see ParkourMotor.lua's header for that failure in full).

	THE COST OF KINEMATIC DRIVE, and what this file does about it: a rigid drive goes exactly where its
	Position is written, every physics step -- functionally instant, same as the anchored write it
	replaced. So the naive grab -- write the hang pose on the first frame -- is a teleport of up to
	several studs plus a rotation snap, and no amount of tuning the thresholds around it will stop that
	from reading as clunky, because the problem is that nothing MOVES. The grab instead runs in two
	beats: Enter stops the fall dead at the point of contact (on the detection frame, not the one after
	it), and Update eases the body from there into the pose over a window scaled to how far it actually
	has to travel. That window doubles as the grip settle -- inputs open when the pull lands -- so the
	time the player cannot act is time they can see being used.

	The design's "make the system smart enough to determine ... whether there is enough space for the
	character to stand after climbing it" is enforced at the probe level (LedgeProbe.HasStandingSpace)
	and consumed here: an edge with nothing to stand on can still be HUNG from -- that is a legitimate
	thing to do while deciding where to go -- but the climb-up out of it is refused, which is the
	honest behavior rather than pretending the ledge is not there.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

-- A LOGGER, unlike this framework's other individual state modules -- ParkourController already logs
-- every state TRANSITION (which state, from where) at Trace, so a sibling that only ever runs to
-- completion needs nothing more. This one earns its own scope because the shimmy and the ledge-leap
-- are both DECISIONS MADE INSIDE a single state's Update, every frame, with no transition to show for
-- most of them -- "why didn't the shimmy move" or "why did jump climb instead of leap" has no signal
-- anywhere else to read. Debug level, so it costs nothing with logging off and says something concrete
-- when it's on.
local logger = Logger.scope("LedgeHanging")

local LEDGE = ParkourConstants.Ledge
local LEAP = ParkourConstants.Leap

-- The pose held for the duration of the hang, computed once at Enter. Recomputing it per frame from
-- a live probe would let the pose creep as the probe's own hit point shifts by fractions of a stud.
local hangCFrame = CFrame.identity
local edgePosition = Vector3.zero
local wallNormal = Vector3.new(0, 0, -1)
local hasStandingSpace = false
local grabbedInstance: BasePart? = nil

-- THE PULL INTO THE POSE. Where the body was on the frame the grab landed, when that frame was, and
-- how long the pull it starts should take. See Enter for why all three are captured there and
-- Ledge.AttachSpeed for why the duration is derived from a distance rather than authored flat.
local attachFrom = CFrame.identity
local attachBeganAt = 0
local attachSeconds = 0

-- The regrab lockout state (which edge the last voluntary drop let go of, and the two windows that
-- keep it from being caught again on the way down) used to live here as file-locals. It has moved to
-- States/StateSupport.lua, along with the grab predicate that reads it -- see
-- StateSupport.LedgeGrabAvailable's own header. Keeping it private here was the actual bug: the two
-- states that grab a ledge from their own Update (WallJumping's top-out, Leaping's near-miss catch)
-- could not see it, so a deliberate drop could be undone by the very next wall-jump.

local LedgeHanging: ParkourTypes.StateDefinition = {
	Id = "LedgeHanging",
	Priority = 210,
	Drive = "Kinematic",
	Probes = { Ground = true, Ledge = true, Walls = true },
	-- Committed, unlike every other non-traversal state: a hang is a HELD POSE the player acts from,
	-- and this file's header names its three exits (climb, drop, time out) as the complete set. Route 2
	-- pre-emption is not a fourth exit, it is a way for those three to be bypassed -- which is exactly
	-- what happened, since LedgeClimbing sits one priority step above this and used to accept
	-- unconditionally. Belt and braces with LedgeClimbing.CanEnter's own input check: that one makes the
	-- climb require asking, this one makes Update the only thing that can answer -- including the
	-- hasStandingSpace gate, which lives here and which no other state can see.
	--
	-- Does NOT block combat taking the body: ParkourController routes that through
	-- machine:ForceTransition, which bypasses CanEnter and commitment alike.
	Committed = true,

	-- Every condition now lives in StateSupport.LedgeGrabAvailable, shared with the two states that
	-- grab from their own Update -- see that function's header for what the three independently
	-- written copies of this cascade had drifted into. The measured-velocity form of the vertical test
	-- is the right one HERE (this is a CanEnter -- nothing is commanding a velocity this frame);
	-- WallJumping/Leaping hand it their own integrated value instead.
	--
	-- One nuance worth keeping visible because it is easy to reintroduce: HasHangSpace, not
	-- HasStandingSpace, is what this gate asks for. An edge inside the grab band can still sit too
	-- close to the floor for a hang to mean anything (the pose would put the character's feet in the
	-- ground), and refusing that is also what stops a grab from STEALING a mantle -- the mantle band
	-- (Obstacle.VaultMaxHeight 4.2 to MantleMaxHeight 7.5) overlaps the bottom of the grab band, and
	-- this state outranks Mantling on priority, so jumping at a chest-high wall would otherwise
	-- produce a grounded-looking "hang" instead of the climb the player asked for.
	CanEnter = function(context: ParkourContext): (boolean, string?)
		return StateSupport.LedgeGrabAvailable(context, context.VerticalVelocity)
	end,

	Enter = function(context: ParkourContext): ()
		-- Both intents that can act FROM a hang are consumed on the way in, so neither can be satisfied
		-- by a press made before the grab existed.
		--
		-- This is the difference between a hang and a mantle. Catching a ledge is a DECISION POINT --
		-- climb, drop, or hold -- and a decision made by an input the player aimed at something else is
		-- not a decision. Jumping at a wall means pressing jump within a fraction of a second of contact,
		-- so without this the buffered jump outlived the pull into the pose and fired the climb on the
		-- next frame: the player never saw a hang, only a slower mantle they did not ask for. Same for a
		-- slide press carried in from sliding off a roof, which would drop them the instant they caught
		-- the edge they were reaching for.
		--
		-- Every other state in this framework already consumes on Enter (Sliding.Enter, and
		-- LedgeClimbing.Enter below); this one was the outlier. The climb and the drop now require a
		-- FRESH press made while hanging, which is what makes the hold real.
		InputBuffer.ConsumeJump(context.Now)
		InputBuffer.ConsumeSlide(context.Now)

		edgePosition = context.Ledge.EdgePosition
		wallNormal = ParkourMath.SafeUnit(ParkourMath.Flatten(context.Ledge.WallNormal), Vector3.new(0, 0, -1))
		hasStandingSpace = context.Ledge.HasStandingSpace
		grabbedInstance = context.Ledge.Instance
		context.AnimationVariant = "Hang"
		-- Published for States/LedgeClimbing.lua -- see ParkourContext.LedgeAnchorPosition's own header
		-- for why the climb cannot simply re-probe for the edge it is already holding.
		context.LedgeAnchorPosition = edgePosition
		context.LedgeAnchorNormal = wallNormal

		-- Hanging pose: below the edge by HangVerticalOffset and backed off along the wall's outward
		-- normal by HangHorizontalOffset, facing INTO the wall (hence the negated normal as the look
		-- direction). The position itself comes from ParkourMath.HangPosition because
		-- EnvironmentProbe.probeLedge tests this exact pose for floor clearance before offering the grab
		-- -- if the two computed it separately, that check would be validating a pose nobody uses.
		local position =
			ParkourMath.HangPosition(edgePosition, wallNormal, LEDGE.HangVerticalOffset, LEDGE.HangHorizontalOffset)
		hangCFrame = CFrame.lookAt(position, position - wallNormal)

		-- THE GRAB BITES ON THE FRAME IT IS DETECTED, not the frame after.
		--
		-- StateMachine.Update applies at most one transition and returns, so this state's Update does not
		-- run until the NEXT frame -- meaning without this block the frame that decided to grab still
		-- commits the outgoing Falling state's command, and the character falls for one more frame under
		-- ordinary gravity before the rigid drive engages. At a fast fall that is a stud or two of visible
		-- overshoot past the lip followed by a correction back up to it, which is precisely the "it
		-- doesn't catch when I press it" the grab is accused of. Writing the motor here is the same
		-- technique StateSupport.HandOff uses for the opposite edge of a transition, and for the same
		-- ordering reason -- see that function's own header.
		--
		-- Target is the CURRENT pose, not the hang pose: this frame's job is to stop the fall dead where
		-- contact happened. Update takes over next frame and eases from here to hangCFrame.
		attachFrom = context.RootPart.CFrame
		attachBeganAt = context.Now
		attachSeconds = math.clamp(
			(position - attachFrom.Position).Magnitude / math.max(LEDGE.AttachSpeed, 1e-3),
			LEDGE.AttachMinSeconds,
			LEDGE.AttachMaxSeconds
		)
		context.Motor.Mode = "Kinematic"
		context.Motor.TargetCFrame = attachFrom
		context.Motor.DesiredSpeed = 0

		-- A caught ledge cancels the fall outright: the drop is over, and letting the severity survive
		-- would apply a hard-landing momentum cost to the eventual climb-up, several seconds later,
		-- for a fall the player successfully arrested.
		context.LandingSeverity = nil
		context.FallHeight = 0
		context.ApexHeight = position.Y
		context.Momentum = 0
		-- Catching a ledge is as good as touching the ground for chain-limit purposes: it is a
		-- deliberate, skilful stop, and refusing to reset the counters would punish the player for
		-- succeeding.
		context.WallRunChain = 0
		context.WallJumpChain = 0
		-- The air dash's charge, refunded here for the same reason -- and it matters more than the two
		-- above do, because reaching an out-of-range lip is the single thing the air dash exists for.
		-- Refusing the refund would mean the reward for a successful air-dash-to-catch is being unable
		-- to dash off the ledge you just caught.
		context.AirDashChain = 0
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local motor = context.Motor
		motor.Mode = "Kinematic"
		motor.DesiredSpeed = 0

		-- The root is RIGIDLY DRIVEN for the whole hang (see this file's header), so whatever goes in
		-- TargetCFrame is where the body ends up within one physics step. Writing hangCFrame directly --
		-- which this used to do -- therefore teleports the character up to several studs and spins them
		-- to face the wall inside a single frame. That discontinuity IS the clunk: there is no motion for
		-- the eye to follow, so the grab reads as the character being relocated rather than as them
		-- catching something.
		--
		-- Interpolating the whole CFrame rather than just the position matters as much: CFrame:Lerp
		-- slerps the rotation, so the turn to face the wall happens over the same window as the reach
		-- instead of snapping on frame one.
		local attachAlpha = math.clamp((context.Now - attachBeganAt) / math.max(attachSeconds, 1e-3), 0, 1)
		motor.TargetCFrame = attachFrom:Lerp(hangCFrame, ParkourMath.EaseOutCubic(attachAlpha))

		-- Inputs open the moment the pull lands. This replaces a flat grip-settle window, and the
		-- difference is not the duration -- they are within a few hundredths of each other -- it is that
		-- the window is now spent on something visible. A fixed delay in front of a teleport is dead
		-- time the player experiences as lag; the same delay spent watching the body swing into the pose
		-- is the grab itself. It also means a near-instant grab (hands already at the lip) is actionable
		-- in a frame or two rather than always costing the far case's settle.
		if attachAlpha < 1 then
			return nil
		end

		-- Defaulted every frame BEFORE either mechanic below decides otherwise -- see
		-- ParkourContext.DebugShimmy/DebugLedgeLeap's own header for why these have to be fresh every
		-- frame rather than left stale. "Idle" is the honest answer for "fully attached, nothing being
		-- attempted right now," which is the overwhelming majority of a hang's own lifetime.
		--
		-- AnimationVariant is reset here too, alongside them, for the identical reason: Enter published
		-- "Hang" once, but the shimmy branch below flips it to "Shimmy" for exactly the frames lateral
		-- intent clears the threshold, and it has to fall back to "Hang" the instant that stops being
		-- true rather than staying stuck on whichever it last was.
		context.DebugShimmy = "Idle"
		context.DebugLedgeLeap = "Idle"
		context.AnimationVariant = "Hang"

		-- THE SHIMMY. Only once fully attached -- shimmying mid pull-in would be steering a position the
		-- pull is still easing toward, which is a different motion than the pose it is easing FROM.
		--
		-- WallRight, not WallTangent: a hang has no travel direction for WallTangent to agree with (its
		-- own contract returns the zero vector without one), and even if it did, "which way is right"
		-- must not flip depending on which way the character was last moving before they grabbed on.
		local wallRight = ParkourMath.WallRight(wallNormal)
		local lateral = context.MoveIntent:Dot(wallRight)
		if wallRight.Magnitude > 1e-3 and math.abs(lateral) >= ParkourConstants.Locomotion.InputMagnitudeThreshold then
			context.AnimationVariant = "Shimmy"
			local direction = if lateral > 0 then wallRight else -wallRight
			local step = direction * LEDGE.ShimmySpeed * context.DeltaTime
			-- THE HEAD POSITION THE PROBE SEARCHES FROM -- and the thing that was wrong here before.
			--
			-- This used to be built from `edgePosition` (the LIP -- the top of the wall face) offset by a
			-- flat 0.3 studs. But a head is not at the lip: Ledge.HangVerticalOffset pulls the HANGING
			-- ROOT 2.4 studs below it, and probeLedge's own convention for "head position" -- the one
			-- every OTHER ledge search in this file already honors -- is the ROOT plus half the rig's own
			-- height, not some fraction of a stud off the edge. Anchoring the search to the edge instead
			-- of the actual hanging head put the origin roughly a stud too high: a horizontal cast fired
			-- from there skims along the TOP of the wall rather than into its face, which finds nothing on
			-- essentially every real wall -- the shimmy did not move because commitShimmyStep was never
			-- being reached, straight case or corner case, on any frame.
			--
			-- Derived from hangCFrame.Position (the CURRENT, already-correct hang root -- the same value
			-- the rigid drive is holding the character at this very frame) rather than re-deriving it from
			-- edgePosition a second, slightly different way.
			local headPosition = hangCFrame.Position + Vector3.new(0, context.RootPart.Size.Y * 0.5, 0) + step

			-- Commits a shimmy step onto `hit`, re-deriving the hang pose from scratch the way Enter
			-- does. Shared by the straight case and the corner case below it -- both end up needing to do
			-- exactly the same thing to exactly the same file-locals once a usable edge is found; the
			-- only difference between them is HOW that edge was found.
			local function commitShimmyStep(hit: EnvironmentProbe.LedgeHit): ()
				edgePosition = hit.EdgePosition
				wallNormal = ParkourMath.SafeUnit(ParkourMath.Flatten(hit.WallNormal), wallNormal)
				hasStandingSpace = hit.HasStandingSpace
				grabbedInstance = hit.Instance
				local position = ParkourMath.HangPosition(
					edgePosition,
					wallNormal,
					LEDGE.HangVerticalOffset,
					LEDGE.HangHorizontalOffset
				)
				hangCFrame = CFrame.lookAt(position, position - wallNormal)
				-- Kept current for States/LedgeClimbing.lua, which reads these rather than re-probing the
				-- edge it is already holding -- see ParkourContext.LedgeAnchorPosition's own header. A
				-- climb taken after shimmying without this would pull the character up at the ORIGINAL
				-- grab point instead of wherever they actually shimmied to.
				context.LedgeAnchorPosition = edgePosition
				context.LedgeAnchorNormal = wallNormal
			end

			-- THE STRAIGHT CASE: the wall continues facing the same way. Probed first because it is the
			-- overwhelmingly common frame -- most of a shimmy is along one flat face -- and because it is
			-- cheap to rule out before spending a second cast on the corner case below.
			local straightHit = EnvironmentProbe.ProbeLedgeAt(headPosition, -wallNormal, 0, context.Now)
			if
				straightHit
				and straightHit.HasHangSpace
				and ParkourMath.ApproachAngle(wallNormal, straightHit.WallNormal)
					<= LEDGE.ShimmyMaxNormalDivergenceDegrees
			then
				commitShimmyStep(straightHit)
				context.DebugShimmy = "Straight"
				logger:debug("Shimmy stepped", { via = "Straight" })
			else
				-- THE CLIMB-AROUND: the straight probe found nothing usable -- either genuinely nothing,
				-- or a wall whose normal has diverged too far to be "the same face, continuing." Both read
				-- identically to a single face's own probe, which cannot express "the surface continues,
				-- just facing a new way" any more than a single wall-run probe can (see States/
				-- WallRunning.Update's own corner turn for the identical ambiguity on a run instead of a
				-- hold). So before refusing the step outright, peek around the corner: a second cast from
				-- the SAME candidate origin, rotated from "straight into the wall just held" toward "the
				-- direction being shimmied" by up to Ledge.ShimmyCornerPeekDegrees.
				--
				-- ParkourMath.SteerDirection again doing one-shot cone work rather than its usual per-frame
				-- ramp -- see States/WallJumping.Enter's identical reuse of it for the same reason: called
				-- with a "rate" of ShimmyCornerPeekDegrees and a "deltaTime" of 1 second, it rotates
				-- -wallNormal toward `direction` by AT MOST that many degrees in one step, which is exactly
				-- a bounded peek around the corner rather than an unbounded search.
				--
				-- No normal-divergence check on the result -- unlike the straight case, ANY wall the peek
				-- finds IS the corner by definition; requiring it to still resemble the old wall's normal
				-- would refuse the exact thing this branch exists to accept.
				local peekForward = ParkourMath.SteerDirection(-wallNormal, direction, LEDGE.ShimmyCornerPeekDegrees, 1)
				local cornerHit = EnvironmentProbe.ProbeLedgeAt(headPosition, peekForward, 0, context.Now)
				if cornerHit and cornerHit.HasHangSpace then
					commitShimmyStep(cornerHit)
					context.DebugShimmy = "Corner"
					logger:debug("Shimmy stepped", { via = "Corner" })
				else
					-- A step that found nothing usable, straight or around a corner, is simply not taken
					-- -- see this file's header. hangCFrame already holds the last position that worked,
					-- and Update below drives toward exactly that every frame regardless, so there is no
					-- state to fix here; the log line and the debug annotation exist purely so "why
					-- isn't the shimmy moving" has an answer on the frame it happens rather than needing
					-- to be reproduced blind.
					context.DebugShimmy = "Refused"
					logger:debug("Shimmy step refused -- no continuing edge", {
						straightFound = straightHit ~= nil,
						cornerFound = cornerHit ~= nil,
					})
				end
			end
		end

		-- LEDGE-TO-LEDGE LEAP: a directional jump press, checked BEFORE the plain climb/drop below so a
		-- held direction with a real target takes priority -- but only ever a peek here, never a
		-- consuming read, until a target is actually found and reachable. See this file's header.
		if StateSupport.JumpQueued(context) and StateSupport.HasMoveIntent(context) then
			local aim = ParkourMath.SafeUnit(context.AimDirection, context.RootPart.CFrame.LookVector)
			local target = EnvironmentProbe.FindLedgeLeapTarget(context.RootPart, aim, context.Now)
			context.DebugLedgeLeap = if target.Found then "Unreachable" else "NoTarget"
			logger:debug("Ledge leap attempt", { found = target.Found, distance = target.Distance })
			if target.Found then
				local solved, reachable = ParkourMath.SolveLaunchVelocity(
					context.RootPart.Position,
					target.LandingPosition,
					Workspace.Gravity,
					LEAP.ApexClearance,
					LEAP.ReachMargin,
					LEAP.MinUpSpeed,
					LEAP.MaxUpSpeed,
					LEAP.MaxPlanarSpeed
				)
				if reachable then
					context.DebugLedgeLeap = "Launched"
					InputBuffer.ConsumeJump(context.Now)
					-- Written directly into the shared command, not left for States/LedgeLeaping.Enter to
					-- compute -- Enter runs immediately after this state's own Exit on the SAME frame (see
					-- StateMachine.applyTransition), and reads this back out rather than re-deriving it,
					-- the same "the deciding frame writes the motor itself" technique this file's own
					-- Enter block below uses for the opposite edge of a transition.
					context.Motor.Mode = "Velocity"
					context.Motor.Velocity = solved
					context.Motor.CancelGravity = true
					context.Motor.FaceDirection = ParkourMath.Flatten(solved)
					context.Motor.DesiredSpeed = ParkourMath.PlanarSpeed(solved)
					return "LedgeLeaping"
				end
				logger:debug("Ledge leap target found but unreachable -- falling through to climb/drop", {
					distance = target.Distance,
				})
			end
			-- No target, or not reachable: NOT a refusal of the input. Falls straight through to the
			-- ordinary climb/drop below, using the same still-unconsumed jump press.
		elseif StateSupport.JumpQueued(context) then
			-- Jump WAS pressed but this branch never ran at all -- HasMoveIntent was false. The single
			-- most useful line for "why does jump always just climb": if this fires every time you press
			-- space regardless of which direction you're holding, the leap is never even being attempted,
			-- which points at MoveIntent rather than at the target search.
			context.DebugLedgeLeap = "NoIntent"
			logger:debug("Jump pressed with no move intent -- leap not attempted", {
				moveIntent = tostring(context.MoveIntent),
			})
		end

		-- Jump = climb up, when there is somewhere to climb to.
		if StateSupport.JumpQueued(context) then
			if hasStandingSpace then
				return "LedgeClimbing"
			end
			-- No standing space: the jump becomes a drop instead of doing nothing, so the input is
			-- never silently eaten.
			InputBuffer.ConsumeJump(context.Now)
			return "Falling"
		end

		-- Slide/crouch = let go. The same key that ducks on the ground releases a grip in the air,
		-- which is the convention this genre has settled on.
		if InputBuffer.PeekSlide(context.Now) then
			InputBuffer.ConsumeSlide(context.Now)
			return "Falling"
		end

		if context.StateElapsed >= LEDGE.MaxHangSeconds then
			return "Falling"
		end
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		context.AnimationVariant = nil
		if nextState == "LedgeClimbing" then
			return
		end
		-- Recorded on every OTHER exit, including the leap: a leap that fails to reach its target and
		-- ends up falling must not instantly re-catch the very ledge it just launched from.
		StateSupport.NoteLedgeReleased(context.Now, grabbedInstance, edgePosition)
		context.LedgeAnchorPosition = nil
		context.LedgeAnchorNormal = nil
		if nextState == "LedgeLeaping" then
			-- The launch velocity Update just solved and wrote into context.Motor for this exact frame --
			-- see that branch's own header. A HandOff here would overwrite it with the ordinary release
			-- push below, which is right for every other exit and wrong for the one that already knows
			-- exactly where it's going.
			return
		end
		-- Released with a small push away from the wall so the character falls clear of the face
		-- rather than scraping down it (and immediately re-satisfying the grab probe).
		StateSupport.HandOff(context, wallNormal * 4)
	end,
}

return LedgeHanging
