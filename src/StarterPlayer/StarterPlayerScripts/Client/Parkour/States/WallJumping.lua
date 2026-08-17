--!strict
--[[
	States/WallJumping.lua

	Owns: kicking off a wall -- the departure velocity, the brief control lock that makes the push
	mean something, and the chain falloff that keeps a sequence of wall-jumps from being free
	altitude.

	THE CONTROL LOCK is the non-obvious part and the reason this is a state at all rather than a
	one-line impulse. A wall-jump's push is away from the wall; with full air control available
	immediately, the correct play is to steer straight back into the same wall on the next frame, and
	a "chained wall jump" degenerates into climbing one flat surface. Holding the character's own
	velocity for ParkourConstants.WallJump.ControlLockSeconds -- a sixth of a second, well below the
	threshold where it reads as losing control -- is what makes the push actually carry, and therefore
	what makes chaining require two walls rather than one.

	The lock RAMPS OUT rather than ending on a frame (Assist.ControlRampStartFraction): it used to be
	strictly binary, so the instant it expired the character went from unsteerable to fully steerable
	with nothing in between, and that discontinuity is felt as the jump "snapping" back under control.
	Only the front of the window needs to be absolute -- that is where a steer back into the wall
	would undo the push -- so authority fades in across the tail and the hand-off to Falling becomes a
	continuation instead of a switch. It touches the planar direction only; the vertical arc stays
	ballistic, because air control over lift is a glide, not a jump.

	FACING is eased over its own (shorter) window rather than written to the departure direction on
	frame one -- see FacingEaseSeconds. The orientation drive goes exactly where it is told, so
	retargeting it in a single step is a rotation with no intermediate frames: nothing for the eye to
	follow, so the body reads as re-posed rather than as pushing off something. Exactly the problem,
	and exactly the fix, that States/LedgeHanging documents for its own grab pose.

	During the lock this state runs in Velocity drive mode and integrates its own gravity, so the arc
	is a real ballistic arc rather than a floaty constant-velocity glide. It hands off to Falling the
	moment the lock expires, with the live velocity intact.

	A GRABBABLE LEDGE OUTRANKS THE KICK, enforced in CanEnter rather than left to the priority table.
	LedgeHanging already sits above this state (210 against 180), but priority only decides the frame
	where both accept -- and the case that actually bites is the grab being a frame or two out, so the
	kick fires first and carries the player off the wall past the lip they were reaching for, after
	which nothing can pre-empt this state because it is Committed. Deferring is safe because it asks
	the same StateSupport.LedgeGrabAvailable predicate LedgeHanging.CanEnter does, so it only ever
	declines when the grab would genuinely be taken, and the buffered jump survives to fire the kick
	next frame if it is not.

	CHAIN FALLOFF (ChainFalloffMultiplier, applied via ParkourMath.WallJumpVelocity) scales both the
	push and the lift by a compounding factor per wall-jump since the last ground contact. Chaining
	still works -- it is one of the most satisfying things in the movement set -- it just pays
	diminishing returns, which caps achievable height without ever telling the player "no."

	THE ASSIST, and why a wall-jump is no longer just a push. A fixed push away from a wall is aimed by
	the player and lands wherever it lands; between two walls that means every link of a chain is a fresh
	act of estimation, and one bad estimate ends the line. So on every jump this state asks
	EnvironmentProbe.FindWallJumpTarget what is actually out there -- a fan of rays across the open side
	plus a short upward arc -- ranks the hits, and, when something qualifies, flies a trajectory SOLVED
	to land on it (ParkourMath.SolveLaunchVelocity) rather than the fixed push. The surplus in that solve
	(Assist.ReachMargin) is deliberate and small: just more than enough to reach, because landing on the
	mathematical minimum makes every frame of error a miss.

	The ranking prefers the NEAREST usable surface (Assist.ProximityWeight now leads AlignmentWeight),
	so the jump goes where the player can see themselves landing. Alignment leading meant a barely-
	aimed-at wall forty studs out could beat a well-placed one six studs away, and the same press
	produced either a hop or a committed long flight depending on scenery nobody was aiming at.

	A CORRIDOR KICK KEEPS THE SPEED IT ARRIVED WITH. The solved velocity owns two axes -- across the
	gap, and up -- and in a chimney the gap is small, so its planar component is small too. Assigning
	it wholesale therefore threw away everything the player had built up: sprinting a narrow tunnel
	and kicking off a wall collapsed planar speed to single digits, instantly. Travel ALONG the
	corridor is a third axis the solve has no claim on (sliding down a tunnel does not change the
	distance to either wall), so that component is decomposed out and re-added at the same
	ForwardRetainFraction the unassisted kick already uses. The crossing still lands where it was
	solved to land; the run keeps its momentum.

	Nothing about that removes the chain's limits. The scan refuses to aim back at the wall it just left
	(by instance AND by radius, since a wall face is usually several parts), the vertical cap bounds a
	single jump's gain, and MaxChainWithoutGround still counts. What it removes is the estimation: a
	player who can see the next surface no longer has to guess how hard to push at it, and the chain
	becomes a line to read rather than a series of coin flips. A jump with nothing to aim at is exactly
	the jump this file always described -- same push, same falloff, same lock.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext
type WallProbe = ParkourTypes.WallProbe

local WALLJUMP = ParkourConstants.WallJump
local ASSIST = WALLJUMP.Assist

-- The velocity being flown this frame, integrated across the control lock.
local velocity = Vector3.zero
-- Whether THIS jump is flying a solved trajectory rather than the fixed push. Decided in Enter and read
-- by Update for one thing only: how long the control lock holds. A solved arc is a promise, and air
-- control applied to it immediately is the player steering off a prediction made for them.
local assisted = false

-- THE FACING EASE. Where the body was pointing on the frame the kick launched, so Update can turn it
-- toward the departure direction over the lock instead of retargeting the orientation drive to it on
-- frame one. Same problem States/LedgeHanging solves for its hang pose, same shape of answer: the
-- discontinuity IS the clunk, because a rotation with no intermediate frames has nothing for the eye
-- to follow and reads as the character being re-posed rather than as them pushing off something.
local entryFacing = Vector3.new(0, 0, -1)

-- Whichever side currently has a wall close enough to jump from. Unlike WallRunning's own selection
-- this does NOT care about approach angle -- pushing off a wall you ran straight into is legitimate
-- (and is how a wall-jump out of a dead-end corridor works), where wall-RUNNING along one is not.
local function nearestWall(context: ParkourContext): WallProbe?
	local left = context.WallLeft
	local right = context.WallRight
	local leftOk = left.Found and left.TiltAngle <= ParkourConstants.WallRun.MaxSurfaceTiltDegrees
	local rightOk = right.Found and right.TiltAngle <= ParkourConstants.WallRun.MaxSurfaceTiltDegrees
	if leftOk and rightOk then
		return if left.Distance <= right.Distance then left else right
	end
	if leftOk then
		return left
	end
	if rightOk then
		return right
	end
	return nil
end

local WallJumping: ParkourTypes.StateDefinition = {
	Id = "WallJumping",
	Priority = 180,
	Drive = "Velocity",
	Probes = { Ground = true, Walls = true, Ledge = true },
	Reports = "WallJump",
	-- Committed for its own (very short) duration: the control lock is the mechanic, and letting
	-- another state pre-empt during it would be the same as not having it.
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- Asked first -- see States/WallRunning.CanEnter's own note on why the combat refusal leads.
		if StateSupport.CombatBlocks(context, "WallJumping") then
			return false, "InCombat"
		end
		if context.Ground.Grounded then
			return false, "Grounded"
		end
		if not StateSupport.JumpQueued(context) then
			return false, "NoJumpInput"
		end
		if not StateSupport.JumpIntervalElapsed(context.Now) then
			return false, "JumpCooldown"
		end
		if context.WallJumpChain >= WALLJUMP.MaxChainWithoutGround then
			return false, "WallJumpChainExhausted"
		end
		if not nearestWall(context) then
			return false, "NoWallToJumpFrom"
		end
		-- A GRABBABLE LEDGE BEATS A KICK, and this is the gate that makes that true rather than merely
		-- implied by priority. LedgeHanging already outranks this state (210 against 180), so route 2
		-- pre-emption picks it whenever both accept -- but that only settles the case where both
		-- accept, and the case players actually hit is the one where the grab is a frame or two away
		-- and the kick fires first, taking them off the wall and past the lip they were reaching for.
		-- Once WallJumping has started nothing can pre-empt it either, because it is Committed.
		--
		-- Refusing here is safe precisely because it asks the SHARED predicate rather than a restated
		-- copy: this declines only when a grab would genuinely be accepted this frame, so the jump
		-- input is never eaten in exchange for nothing. The buffered press survives
		-- (InputBuffer.ConsumeJump is in Enter, which did not run), so if the grab does not materialise
		-- the very next frame the kick still fires off the same press.
		--
		-- Asked against the MEASURED vertical velocity, not an owned one: nothing is commanding a
		-- velocity at this point -- this is a CanEnter, and the character is in whatever the previous
		-- state left them in.
		if StateSupport.LedgeGrabAvailable(context, context.VerticalVelocity) then
			return false, "LedgeTakesPriority"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeJump(context.Now)
		StateSupport.NoteJump(context.Now)

		entryFacing =
			ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.new(0, 0, -1))

		local wall = nearestWall(context)
		local normal = if wall then wall.Normal else Vector3.new(0, 0, -1)
		local bounce = if wall then wall.BounceScale else 1
		local outward = ParkourMath.SafeUnit(ParkourMath.Flatten(normal), Vector3.new(0, 0, -1))

		-- WHERE THE JUMP IS AIMED, computed BEFORE the push itself now -- both the unassisted push below
		-- and the target scan further down read this same blend, so a player's aim means one thing for
		-- the whole jump rather than two slightly different things depending on whether a target ends up
		-- being found.
		--
		-- The push away from the wall is a hard requirement (jumping back INTO the face you are standing
		-- on is not a jump), and everything else is the player's own statement of intent: facing carries
		-- most of the weight because under shift lock it is where the player is LOOKING, which is where
		-- they mean to go, and travel carries the rest so a fast run along a wall still leans the aim down
		-- the line it was already travelling. Blended rather than chosen between, so a diagonal reads as a
		-- diagonal. If the blend somehow ends up pointing back at the wall -- a player looking straight
		-- into the face they are kicking off -- it collapses to the pure push, which is the honest answer
		-- to "you have not told me anywhere to go."
		local aim = outward
			+ ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.zero) * 1.15
			+ ParkourMath.Flatten(StateSupport.TravelDirection(context)) * 0.6
		aim = ParkourMath.SafeUnit(ParkourMath.Flatten(aim), outward)
		if aim:Dot(outward) < 0.1 then
			aim = outward
		end

		-- THE UNASSISTED PUSH IS NOW STEERABLE, not pinned to the bare wall normal. `aim` already leans
		-- toward wherever the player is looking; ParkourMath.SteerDirection here is doing something it
		-- was not written for (that function is normally a per-frame turn-rate ramp) but is exactly the
		-- primitive this needs anyway: called with a "rate" of WallJump.MaxAimSteerDegrees and a
		-- "deltaTime" of 1 second, it rotates `outward` toward `aim` by AT MOST that many degrees in one
		-- step -- landing exactly on `aim` when it is already within the cone (the common case: a modest
		-- look-away), and clamped to the cone's edge when it is not (a player aiming almost along the
		-- wall face, which this refuses to fully honor -- see MaxAimSteerDegrees' own header for why a
		-- kick must stay recognizably a kick). A player who is not aiming anywhere in particular has `aim
		-- == outward` from the fallback two lines up, so this is a no-op for them: the departure is
		-- identical to the wall-jump that existed before this steering did.
		--
		-- Passed as the PUSH DIRECTION into WallJumpVelocity below, which only ever uses its `wallNormal`
		-- parameter to flatten-and-normalize it for the push -- it has no idea, and no need to know,
		-- whether what it is handed is the literal surface normal or a direction merely steered off it.
		local pushDirection = ParkourMath.SteerDirection(outward, aim, WALLJUMP.MaxAimSteerDegrees, 1)

		velocity = ParkourMath.WallJumpVelocity(
			pushDirection,
			StateSupport.TravelDirection(context),
			context.Momentum,
			WALLJUMP.PushSpeed * bounce,
			WALLJUMP.UpSpeed,
			WALLJUMP.ForwardRetainFraction,
			context.WallJumpChain,
			WALLJUMP.ChainFalloffMultiplier
		)
		assisted = false

		local target = EnvironmentProbe.FindWallJumpTarget(
			context.RootPart,
			aim,
			outward,
			if wall then wall.Instance else nil,
			if wall and wall.Found then wall.Position else nil,
			context.Now
		)

		-- A corridor kick off the wall you JUST kicked off is the free elevator: stand against one face,
		-- press jump repeatedly, and take a full-lift kick each time without ever crossing to the other
		-- side. Refusing the corridor branch (not the jump -- the ordinary falloff push is still there) is
		-- what makes the climb require alternating walls, which is the whole reason it can be allowed to
		-- run as long as the shaft is tall. Deliberately a short window: a genuine round trip across a
		-- corridor takes longer than this, so the legitimate return to the wall you came from is untouched.
		local sameWallAsLastKick = wall ~= nil
			and wall.Instance ~= nil
			and wall.Instance == context.LastWallInstance
			and (context.Now - context.LastWallLeftAt) < ASSIST.SameWallCooldownSeconds

		if target.Found and target.Corridor and not sameWallAsLastKick then
			-- THE CHIMNEY KICK: everything into lift, and exactly enough horizontal speed to be touching
			-- the far wall at the top of the arc. The height comes from ParkourMath.CorridorKickHeight,
			-- which is where the reasoning lives; here it is only turned into an aim point and handed to
			-- the same solver everything else uses. MinUpSpeed and MaxUpSpeed are both pinned to
			-- CorridorUpSpeed so the solver flies exactly the lift this case was budgeted for rather than
			-- deriving its own from a height it did not choose.
			local climbHeight = ParkourMath.CorridorKickHeight(
				target.Distance,
				Workspace.Gravity,
				ASSIST.CorridorUpSpeed,
				ASSIST.MaxPlanarSpeed,
				ASSIST.ReachMargin
			) - ASSIST.CorridorHeightSafetyStuds
			-- The aim height is measured from the ROOT, not from the target's own Y, and the distinction is
			-- not cosmetic: CorridorKickHeight budgets a climb relative to where the jump starts, and
			-- SolveLaunchVelocity measures its rise the same way -- but the scan that found the far wall
			-- casts from slightly above the root (so the fan clears whatever the character is level with),
			-- so the hit sits half a stud high. Adding the budget to THAT asks the solver for half a stud
			-- more than the budget allowed, which at the apex -- where the vertical cap is binding by
			-- construction -- is the difference between a reachable arc and the assist silently declining
			-- on precisely the jump it exists for.
			local aimPosition = Vector3.new(
				target.AimPosition.X,
				context.RootPart.Position.Y + math.max(climbHeight, 0),
				target.AimPosition.Z
			)
			local solved, reachable = ParkourMath.SolveLaunchVelocity(
				context.RootPart.Position,
				aimPosition,
				Workspace.Gravity,
				0,
				ASSIST.ReachMargin,
				ASSIST.CorridorUpSpeed,
				ASSIST.CorridorUpSpeed,
				ASSIST.MaxPlanarSpeed
			)
			if reachable then
				-- THE ALONG-TUNNEL CARRY, and why a corridor kick is the one solve that gets to keep
				-- momentum the solver did not compute.
				--
				-- SolveLaunchVelocity returns a complete velocity: lift, plus exactly the planar speed
				-- needed to cross the gap in that flight time. In a corridor the gap is SMALL -- 2.5 to a
				-- few studs is the normal case -- so that planar speed is correspondingly tiny, and
				-- assigning it wholesale threw away every bit of speed the player arrived with. Running a
				-- narrow tunnel at sprint and kicking off a wall dropped planar speed from ~46 studs/s to
				-- single digits, instantly: the "random" massive slowdown, which is not random at all but
				-- fires on exactly the jumps that take this branch (and so flickers with whether the
				-- corridor test qualified that frame).
				--
				-- The fix is a decomposition, not a fudge. The solve legitimately owns two axes: the
				-- OUTWARD one (crossing to the far face) and the vertical one. It has no claim on the
				-- third -- travel ALONG the corridor -- and re-adding that component costs the arc
				-- nothing, because sliding down a tunnel does not change the distance to the wall on
				-- either side of it. So the crossing still lands where it was solved to land, and the
				-- run keeps its speed.
				--
				-- Retained IN FULL (Assist.CorridorAlongRetainFraction, 1) rather than at the ordinary
				-- kick's ForwardRetainFraction. That distinction is the difference between the fix
				-- working and not: because the solve contributes ~nothing along the tunnel, the fraction
				-- here is the entire forward speed rather than a top-up on it, so anything below 1 is a
				-- straight speed cut on every kick -- which is exactly the "wall-run down a tunnel, jump,
				-- fall short every time" this is meant to end. See that constant's own comment for why 1
				-- is the neutral value and not a generous one. A chimney climb from a standstill is
				-- unchanged either way: there is no along-tunnel component to keep.
				local travel = ParkourMath.Flatten(StateSupport.TravelDirection(context)) * context.Momentum
				local alongCorridor = travel - outward * travel:Dot(outward)
				velocity = solved + alongCorridor * ASSIST.CorridorAlongRetainFraction
				assisted = true
			end
		elseif target.Found and not target.Corridor then
			local solved, reachable = ParkourMath.SolveLaunchVelocity(
				context.RootPart.Position,
				target.AimPosition,
				Workspace.Gravity,
				ASSIST.ApexClearance,
				ASSIST.ReachMargin,
				ASSIST.MinUpSpeed,
				ASSIST.MaxUpSpeed,
				ASSIST.MaxPlanarSpeed
			)
			-- An UNREACHABLE solve is refused rather than flown. The caps that made it unreachable are
			-- there precisely so a chain cannot become an elevator or outrun the camera, and flying the
			-- clipped arc anyway would be aiming at something while knowingly throwing short of it -- which
			-- is worse than the plain push, because the plain push never claimed to be aimed at anything.
			if reachable then
				velocity = solved
				assisted = true
			end
		end

		context.WallJumpChain += 1
		context.Momentum = ParkourMath.PlanarSpeed(velocity)
		-- Which side the wall was on, so the clip that plays is the mirrored one that matches -- exactly
		-- the pair States/WallRunning.lua already selects between. "Neutral" is a real case rather than a
		-- fallback for missing data: a wall square in front of (or behind) the character has no side, and
		-- playing either mirror for it looks like the character kicking off nothing.
		local side = ParkourMath.WallSide(context.RootPart.CFrame.LookVector, normal)
		context.AnimationVariant = if side < 0 then "Left" elseif side > 0 then "Right" else "Neutral"

		-- Record the wall so States/WallRunning.lua's same-wall lockout also applies to a re-attach
		-- attempted straight out of this jump. Without this, wall-jump -> immediately re-attach to the
		-- same surface would sidestep the lockout entirely, since the run's own Exit only records the
		-- wall when the run itself ends.
		if wall and wall.Instance then
			context.LastWallInstance = wall.Instance
			context.LastWallLeftAt = context.Now
		end
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		-- Real gravity, integrated here because the LinearVelocity constraint commands all three axes
		-- and would otherwise hold the character at a constant vertical speed for the whole lock.
		velocity -= Vector3.new(0, Workspace.Gravity * context.DeltaTime, 0)

		local lockSeconds = if assisted then ASSIST.ControlLockSeconds else WALLJUMP.ControlLockSeconds
		local lockAlpha = math.clamp(context.StateElapsed / math.max(lockSeconds, 1e-3), 0, 1)

		-- THE CONTROL RAMP, replacing a hard cliff. The lock used to be strictly binary -- zero air
		-- control for its whole duration, then the full amount on the frame it expired -- so the moment
		-- steering became available was a visible discontinuity in how the character responded, which
		-- is the "control comes back abruptly" half of a wall-jump feeling rough. The push is still
		-- fully protected where it matters (the front of the window, where steering back into the wall
		-- would undo the whole mechanic -- see this file's header), and authority is faded in across
		-- the back half so the hand-off to Falling is a continuation rather than a switch.
		--
		-- Applied to the PLANAR component only: vertical is the ballistic arc, and letting air control
		-- touch it would turn a wall-jump into a glide. Blended toward the steer direction rather than
		-- added to it, so the ramp can never increase total speed -- an assisted arc still arrives
		-- where it was solved to arrive, just aimable at the end.
		local steerAuthority = math.max(lockAlpha - ASSIST.ControlRampStartFraction, 0)
			/ math.max(1 - ASSIST.ControlRampStartFraction, 1e-3)
		if steerAuthority > 0 and StateSupport.HasMoveIntent(context) then
			local planar = ParkourMath.Flatten(velocity)
			local planarSpeed = planar.Magnitude
			if planarSpeed > 1e-3 then
				local steered = ParkourMath.SteerDirection(
					planar.Unit,
					StateSupport.TravelDirection(context),
					WALLJUMP.ControlRampTurnDegreesPerSecond * steerAuthority,
					context.DeltaTime
				)
				velocity = steered * planarSpeed + Vector3.new(0, velocity.Y, 0)
			end
		end

		context.Momentum = ParkourMath.PlanarSpeed(velocity)

		local motor = context.Motor
		motor.Mode = "Velocity"
		motor.Velocity = velocity
		motor.CancelGravity = true
		-- Eased from the facing the kick started with rather than snapped to the departure direction --
		-- see entryFacing's own note. Uses the same EaseOutCubic States/LedgeHanging pulls its grab
		-- with, over a window deliberately shorter than the control lock (FacingEaseSeconds): the turn
		-- should be finished and out of the way before the player gets steering back, or the two read
		-- as fighting each other.
		local facingAlpha = math.clamp(context.StateElapsed / math.max(WALLJUMP.FacingEaseSeconds, 1e-3), 0, 1)
		local departureFacing = ParkourMath.SafeUnit(ParkourMath.Flatten(velocity), entryFacing)
		motor.FaceDirection = ParkourMath.SafeUnit(
			entryFacing:Lerp(departureFacing, ParkourMath.EaseOutCubic(facingAlpha)),
			departureFacing
		)
		motor.DesiredSpeed = context.Momentum

		if context.Ground.Grounded and context.StateElapsed > 0.05 then
			return "Falling"
		end

		-- THE TOP-OUT. A ledge appearing mid-flight beats finishing the control lock, the same way it
		-- beats finishing a wall-run (States/WallRunning.Update makes the identical call, for the identical
		-- reason). This is what turns a chimney climb into something that ENDS somewhere: the last kick of
		-- an ascent arrives at the top of the shaft with the lip right there, and without this the grab is
		-- unavailable for the whole lock -- which is most of the window in which the lip is actually within
		-- reach -- and the climb tops out by falling back down it.
		--
		-- THE CONDITIONS ARE ASKED OF THE SHARED PREDICATE, not restated here. A transition a state
		-- returns from its own Update is route 1 in StateMachine.Update, which applies it WITHOUT
		-- consulting the target's CanEnter (the caller is asserting, not asking) -- so the gates that
		-- make an automatic grab something the player asked for have to be asked somewhere, and the
		-- hand-written restatement that used to sit here had already drifted from the real thing in two
		-- ways: it demanded HasStandingSpace (declining a legitimate hang under any overhang, which
		-- LedgeHanging itself allows) and it could not see the regrab lockouts at all, so a deliberate
		-- drop could be undone by the very next kick. See StateSupport.LedgeGrabAvailable's own header.
		--
		-- The vertical test is against this state's OWN integrated velocity rather than the context's
		-- measured one -- during the control lock the constraint is being commanded from `velocity`, and
		-- the measured value trails it by a frame. That is exactly why the predicate takes the speed as
		-- a parameter instead of reading the context itself.
		if StateSupport.LedgeGrabAvailable(context, velocity.Y) then
			return "LedgeHanging"
		end

		if lockAlpha >= 1 then
			return "Falling"
		end
		return nil
	end,

	Exit = function(context: ParkourContext): ()
		context.AnimationVariant = nil
		assisted = false
		StateSupport.HandOff(context, velocity)
	end,
}

return WallJumping
