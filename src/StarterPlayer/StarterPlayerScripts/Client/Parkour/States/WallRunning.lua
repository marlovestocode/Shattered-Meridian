--!strict
--[[
	States/WallRunning.lua

	Owns: running along a vertical surface -- entry conditions, following the wall's actual tangent,
	the rise-then-sink vertical profile, and every rule that stops it from becoming free vertical
	flight.

	FOLLOWING THE SURFACE, not moving sideways. The design called this out specifically ("should
	properly follow the surface of the wall rather than feeling like the player is simply moving
	sideways"), and the mechanism is ParkourMath.WallTangent: each frame the commanded velocity is the
	wall's own horizontal tangent, re-derived from the live surface normal and oriented to agree with
	the direction the character is already travelling. A curved wall therefore curves the run within a
	single probe's own contact.

	CORNERS ARE FOLLOWED, NOT JUST SURVIVED (Update, when activeWall loses the current surface). A
	single wall segment's probe cannot itself express "the surface continues, just facing a new way" --
	a real corner and a genuine dead end look identical to it, both are simply "not found here anymore."
	So on losing contact, before falling, Update re-runs selectWall -- the SAME selection CanEnter uses
	for a brand new attach, but with its FACING gate switched off -- and pivots onto whatever it finds,
	in place, with no fresh Enter: momentum, the wall-jump chain and the rise/sink profile's own elapsed
	clock all carry straight through, because a turn is a continuation of the run that started, not a new
	one.

	THE FACING GATE HAS TO BE SKIPPED FOR THE PIVOT, and this is not a loosening of the check so much as
	a recognition that it is answering a different question here. MaxFacingAngleDegrees exists to tell a
	genuine player-driven wall-run attempt from an accident -- facing is the camera-controlled, honest
	signal of "am I looking at this wall" on the frame a fresh attach is being decided. But once a run is
	ACTIVE, facing is no longer independent: this file's own Update commands it toward the wall's tangent
	every frame (motor.FaceDirection = tangent), so at the instant a corner is crossed, facing is still
	pointed along the wall just left -- it had been converging to exactly that for the whole run leading
	up to the corner. Holding the pivot to the same facing tolerance a fresh attach needs would refuse
	almost every real corner on the one frame it needs to succeed, which is turning INTO the check that
	exists to confirm intent. The approach-angle gate (WallRun.MaxApproachAngleDegrees, measured against
	TRAVEL rather than the commanded facing) is what still bounds the pivot: a corner sharp enough to fail
	THAT was never one this move could have followed, and it degrades to the wall simply ending, exactly
	the behavior this had before the turn existed. See selectWall's own header for the full reasoning.

	THE THREE ANTI-INFINITE-CLIMB RULES, which together are why this cannot be used to ascend
	arbitrarily and why none of them needed to be a blunt "no vertical gain" ban:
	  1. SameWallLockoutSeconds -- the specific part just left cannot be re-attached to for a moment.
	     Kills the "run, jump, re-attach to the same wall" ladder.
	  2. MaxChainWithoutGround -- a hard count of wall-runs since the last ground contact. Kills the
	     "three walls in a triangle" version rule 1 alone does not cover.
	  3. The vertical profile itself -- a short rise (RiseSeconds) then a decaying sink under a
	     fraction of gravity. The run visibly runs out of lift, which makes the limit legible without
	     any UI.

	Runs in Velocity drive mode with gravity cancelled, integrating its own vertical speed so the rise
	and sink are authored rather than emergent. The inward stick component is what keeps the character
	against the surface instead of drifting off it.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext
type WallProbe = ParkourTypes.WallProbe

local WALLRUN = ParkourConstants.WallRun
-- For the automatic ledge grab in Update below, which must restate LedgeHanging.CanEnter's gates
-- itself -- see that branch's own comment.

-- Which side the active run is on, and everything derived from the wall it is on. Captured at Enter
-- and refreshed each frame from whichever probe is still finding the same surface.
local side = 0
local verticalSpeed = 0
local reattachUntil = 0

-- Picks the wall to run on: whichever side has a usable surface, preferring the one the character is
-- travelling more nearly parallel to when both qualify. Returns the probe and the side (-1 left,
-- 1 right), or nil when neither side qualifies -- with the reason, so CanEnter can report it.
--
-- `requireFacing` exists for exactly one reason: the corner turn in Update below reuses this same
-- selection for a MID-RUN PIVOT, and the facing check is calibrated for the wrong question there. It
-- asks "is the player's own facing aimed at this wall" -- the right question for a FRESH attach, where
-- facing is the camera-driven, player-controlled signal of intent (see the check's own comment on shift
-- lock, below). But once a run is already active, facing is no longer independent: Update's own
-- `motor.FaceDirection = tangent` is COMMANDING it toward the wall just held, and a non-rigid
-- AlignOrientation takes several frames to converge. At the exact frame a corner is crossed, facing is
-- still pointed along the OLD tangent -- because it had been converging to exactly that for the whole
-- run leading up to the corner -- so ApproachAngle(facing, newTangent) reads close to the corner's own
-- turn angle. For anything near or past a right angle, that is past MaxFacingAngleDegrees on the FIRST
-- frame the new wall would otherwise be offered, which is precisely the frame the pivot needs to
-- succeed. The check was refusing the turn for being a turn. Skipping it for the pivot leaves the
-- approach-angle check (against TRAVEL, not facing) as the guard -- travel is not artificially pinned by
-- the orientation drive the way facing is, so it is still a real bound on how sharp a "corner" this can
-- follow; see Update's own header for that bound's exact shape.
local function selectWall(context: ParkourContext, requireFacing: boolean): (WallProbe?, number, string?)
	local travel = StateSupport.TravelDirection(context)
	-- Read once here rather than inside `evaluate`, which runs twice per call -- and kept as its own
	-- named value because it is a genuinely different vector from `travel` above the moment shift lock
	-- is engaged. See the facing check in evaluate.
	local facing = context.RootPart.CFrame.LookVector

	local function evaluate(probe: WallProbe): (boolean, number, string?)
		if not probe.Found then
			return false, 180, "NoWall"
		end
		if not probe.WallRunAllowed then
			return false, 180, "WallNotRunnable"
		end
		if probe.TiltAngle > WALLRUN.MaxSurfaceTiltDegrees then
			return false, 180, "SurfaceTooTilted"
		end
		local approach = ParkourMath.ApproachAngle(travel, probe.Tangent)
		if approach > WALLRUN.MaxApproachAngleDegrees then
			return false, approach, "ApproachAngleTooSteep"
		end
		-- The travel check above cannot catch a BACKWARDS wall-run, and no amount of tightening it
		-- would: ParkourMath.WallTangent orients the tangent to agree with travel, so travel-vs-tangent
		-- is small by construction whichever way along the wall the character is moving. All it can
		-- actually refuse is running INTO the wall. Facing is the independent witness -- and under shift
		-- lock (Client/Camera/ShiftLockCamera.lua) it is a genuinely separate vector, since WASD is
		-- camera-relative with AutoRotate off, so holding S past a wall gives the tangent a perfectly
		-- good backward direction to run along while the character looks the other way down it.
		-- Refuses with 180 rather than the measured angle because the number in that slot is the
		-- SELECTION metric (which side to prefer when both qualify), and it is defined as the approach
		-- angle -- returning a facing angle there would put two different measurements in one slot.
		--
		-- Skipped entirely when `requireFacing` is false -- see this function's own header.
		if requireFacing and ParkourMath.ApproachAngle(facing, probe.Tangent) > WALLRUN.MaxFacingAngleDegrees then
			return false, 180, "NotFacingRunDirection"
		end
		return true, approach, nil
	end

	local leftOk, leftAngle, leftReason = evaluate(context.WallLeft)
	local rightOk, rightAngle, rightReason = evaluate(context.WallRight)

	if leftOk and rightOk then
		return if leftAngle <= rightAngle then context.WallLeft else context.WallRight,
			if leftAngle <= rightAngle then -1 else 1,
			nil
	end
	if leftOk then
		return context.WallLeft, -1, nil
	end
	if rightOk then
		return context.WallRight, 1, nil
	end
	return nil, 0, leftReason or rightReason or "NoWall"
end

-- The speed band this run is entered into, raised by how many wall-jumps the character has taken since
-- last touching the ground.
--
-- THE RAMP IS THE REWARD HALF OF THE CHAIN. The falloff on the jump itself keeps a chain from being
-- free altitude; without something pulling the other way, that leaves a long chain strictly worse than
-- a short one and the whole line pointless to attempt. So each link makes the NEXT run faster: a
-- five-wall traversal across a courtyard ends visibly quicker than it started, which is what makes
-- committing to the long route worth more than dropping down and sprinting.
--
-- Both ends of the band move together (ChainSpeedBonus added to Speed and to MaxSpeed alike, capped at
-- ChainMaxSpeed). Raising only the ceiling would do nothing at all for a player entering below it,
-- which is most of them -- entry momentum on a mid-chain link comes from the previous jump's arc, not
-- from a sprint -- so the FLOOR is the half that is actually felt.
local function chainSpeedBand(context: ParkourContext): (number, number)
	local bonus = WALLRUN.ChainSpeedBonus * math.max(context.WallJumpChain, 0)
	local floor = math.min(WALLRUN.Speed + bonus, WALLRUN.ChainMaxSpeed)
	local ceiling = math.min(WALLRUN.MaxSpeed + bonus, WALLRUN.ChainMaxSpeed)
	return floor, math.max(ceiling, floor)
end

-- The probe currently describing the wall being run on, or nil if it has been lost.
local function activeWall(context: ParkourContext): WallProbe?
	local probe = if side < 0 then context.WallLeft else context.WallRight
	if probe.Found and probe.WallRunAllowed then
		return probe
	end
	return nil
end

local WallRunning: ParkourTypes.StateDefinition = {
	Id = "WallRunning",
	Priority = 160,
	Drive = "Velocity",
	Probes = { Ground = true, Walls = true, Ledge = true },
	Reports = "WallRun",

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- Asked FIRST, ahead of every geometric check: a refusal the player cannot do anything about
		-- should be the cheapest one and the one the debug overlay reports, rather than being masked by
		-- whichever probe happens to also be unsatisfied this frame.
		if StateSupport.CombatBlocks(context, "WallRunning") then
			return false, "InCombat"
		end
		if context.Ground.Grounded then
			return false, "Grounded"
		end
		if context.Now < reattachUntil then
			return false, "ReattachCooldown"
		end
		if context.WallRunChain >= WALLRUN.MaxChainWithoutGround then
			return false, "WallRunChainExhausted"
		end
		-- The entry-speed requirement exists so a wall-run is earned by a run-up rather than available
		-- from a standstill against a wall. It is waived MID-CHAIN, because arriving off a wall-jump IS a
		-- run-up -- just one whose speed was spent on the flight rather than carried into the contact. An
		-- assisted jump aimed at a near surface legitimately lands slow (the solve gives just enough to
		-- reach, by design), and testing that against a threshold tuned for a sprint is how the fourth
		-- link of a chain refuses for a reason the player cannot see. The entry clamp lifts momentum to
		-- the band floor immediately, so nothing downstream sees the slow arrival; this only stops the
		-- gate from eating the link.
		if context.WallJumpChain <= 0 and context.Momentum < WALLRUN.MinEntrySpeed then
			return false, "TooSlowToWallRun"
		end
		if context.Ground.NearGround and context.Ground.Distance < WALLRUN.MinGroundClearance then
			return false, "TooCloseToGround"
		end
		local probe, _selected, reason = selectWall(context, true)
		if not probe then
			return false, reason
		end
		-- Rule 1: the wall just left is off-limits for a moment. Compared by Instance so a DIFFERENT
		-- wall is available immediately -- which is exactly the chained wall-run the design asks for,
		-- and is why this is a per-wall lockout rather than a global cooldown.
		if
			context.LastWallInstance ~= nil
			and probe.Instance == context.LastWallInstance
			and (context.Now - context.LastWallLeftAt) < WALLRUN.SameWallLockoutSeconds
		then
			return false, "SameWallLockout"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		local probe, selectedSide = selectWall(context, true)
		side = selectedSide
		verticalSpeed = 0
		context.WallRunChain += 1
		context.AnimationVariant = if side < 0 then "Left" else "Right"
		if probe then
			-- Entry speed is clamped into the wall-run's own band: a very fast entry does not make the
			-- run faster than the band's ceiling, and a marginal one is lifted to its floor so the run
			-- always reads as deliberate rather than as a slow scrape along a wall. The band itself widens
			-- with the chain -- see chainSpeedBand.
			local floor, ceiling = chainSpeedBand(context)
			context.Momentum = math.clamp(context.Momentum, floor, ceiling)
		end
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		-- Defaulted every frame before the corner turn below can override it -- see ParkourContext.
		-- DebugWallRunPivot's own header for why this has to be fresh rather than left stale. "Straight"
		-- is the honest answer for "still on the wall I attached to," which is most of a run's own
		-- lifetime.
		context.DebugWallRunPivot = "Straight"
		local probe = activeWall(context)
		if not probe then
			-- THE CORNER TURN. The wall just lost is not necessarily the run ending -- an outside or
			-- inside corner reads exactly the same to activeWall (the side the run was on stops finding
			-- anything) as a genuine dead end does, because a single wall segment's probe has no notion of
			-- "the surface continues, just facing a different way." Before giving up, ask the SAME
			-- question CanEnter asks a fresh attach: is there a usable wall right now, on either side, that
			-- the character is still plausibly running along?
			--
			-- selectWall is reused rather than re-implemented, but with its FACING gate switched off --
			-- see that function's own header for why: facing during an active run is being commanded
			-- toward the OLD wall by this state's own Update, so at the exact frame a corner is crossed it
			-- is still pointed along the tangent just left, and a corner anywhere near a right angle fails
			-- that check on the one frame the turn needs to succeed. The remaining approach-angle gate
			-- (WallRun.MaxApproachAngleDegrees, checked against TRAVEL rather than the commanded facing)
			-- is what still bounds how sharp a turn this can follow -- a corner sharp enough to fail THAT
			-- was never one this run could have followed, and it becomes an ordinary end of the wall,
			-- exactly as it did before this existed. Also picks up a new wall on the OPPOSITE side for
			-- free: after a real corner the surface is routinely sensed by the other side's probe, and
			-- selectWall already checks both.
			local newProbe, newSide = selectWall(context, false)
			if not newProbe then
				return "Falling"
			end
			-- Deliberately does NOT go through Enter. side is repointed in place and everything else --
			-- momentum, WallJumpChain, verticalSpeed's own place in the rise/sink profile, StateElapsed --
			-- carries over exactly as it was, because a turn is a CONTINUATION, not a fresh attach. Costing
			-- a chain slot or re-clamping the speed band (both Enter-only effects) for simply following a
			-- wall around a corner would be punishing the player for the wall's shape rather than for
			-- anything they did.
			side = newSide
			probe = newProbe
			context.DebugWallRunPivot = "Pivoted"
			-- The camera tilt and the animator's left/right pick both read this off the context rather
			-- than off `side` directly (see ParkourController's own per-frame push) -- without updating it
			-- here, a corner that flips which side the wall is on would leave the lean and the animation
			-- pointing the wrong way for the rest of the run.
			context.AnimationVariant = if side < 0 then "Left" else "Right"
		end
		if context.Ground.Grounded then
			return StateSupport.ResolveGroundedState(context)
		end
		if context.StateElapsed >= WALLRUN.MaxDurationSeconds then
			return "Falling"
		end

		-- Re-derived every frame from the live normal: this is what makes the run follow a curved
		-- surface and end at a corner rather than clipping through it.
		local tangent = ParkourMath.WallTangent(probe.Normal, StateSupport.TravelDirection(context))
		if tangent.Magnitude < 1e-3 then
			return "Falling"
		end

		verticalSpeed = ParkourMath.WallRunVerticalSpeed(
			context.StateElapsed,
			verticalSpeed,
			WALLRUN.RiseSeconds,
			WALLRUN.RiseSpeed,
			WALLRUN.GravityFraction,
			Workspace.Gravity,
			context.DeltaTime
		)

		-- Inward stick: a small velocity component INTO the wall (opposite its outward normal), which
		-- is what holds the character against the surface. Without it the run drifts off within a few
		-- frames as collision response pushes the body away.
		local stick = -ParkourMath.SafeUnit(ParkourMath.Flatten(probe.Normal), Vector3.zero) * WALLRUN.StickSpeed

		local motor = context.Motor
		motor.Mode = "Velocity"
		motor.Velocity = tangent * context.Momentum + stick + Vector3.new(0, verticalSpeed, 0)
		motor.CancelGravity = true
		motor.FaceDirection = tangent
		motor.DesiredSpeed = context.Momentum

		-- A GRABBABLE LEDGE IS CHECKED BEFORE THE WALL-JUMP, and the order is the point. It used to be
		-- the other way round, which meant running along a wall toward its top edge and pressing jump
		-- kicked you off the wall and past the lip instead of catching it -- the same "the kick steals
		-- the grab" problem States/WallJumping.CanEnter now guards against, in the one place that guard
		-- cannot reach (this is a route-1 transition; see below).
		--
		-- Reaching a ledge is also strictly the better outcome: a grab ends the run somewhere, where a
		-- kick taken at the top of a wall throws the player back into open air having gained nothing.
		if StateSupport.LedgeGrabAvailable(context, verticalSpeed) then
			return "LedgeHanging"
		end

		-- A wall-jump is available throughout, and takes priority over everything below -- kicking off
		-- a wall is the whole point of being on one.
		--
		-- THE COMBAT GATE IS RESTATED HERE because this is a route-1 transition: StateMachine.Update
		-- applies it without consulting WallJumping.CanEnter, so the gate that file added would simply
		-- not run. Reachable rather than theoretical -- a run legitimately started out of combat and an
		-- exchange begins mid-run, at which point the kick must stop being available like any other
		-- blocked traversal. (The run itself is already ending on its own timer; it is not force-exited
		-- here, because yanking a player off a wall the instant someone swings at them would be a
		-- worse experience than letting the run finish.)
		if
			StateSupport.JumpQueued(context)
			and StateSupport.JumpIntervalElapsed(context.Now)
			and not StateSupport.CombatBlocks(context, "WallJumping")
		then
			return "WallJumping"
		end
		-- The ledge check that used to sit HERE, below the wall-jump, has moved above it -- see its own
		-- note up there for why catching the lip has to beat kicking off it. Its conditions were a
		-- hand-written restatement (route 1 does not consult LedgeHanging.CanEnter) that tested only
		-- Found and HasStandingSpace, silently skipping Allowed, HasHangSpace, the vertical-speed cap
		-- and the facing gate; all of it now comes from StateSupport.LedgeGrabAvailable, which
		-- additionally honors the regrab lockouts this site could never see. See that function's own
		-- header for what the four independent copies of this cascade had drifted into.
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		local probe = activeWall(context)
		-- Record the wall and the moment it was left, for rule 1. Recorded on EVERY exit, including
		-- the wall-jump exit, because a wall-jump straight back onto the same surface is the most
		-- common way players attempt the infinite ladder.
		if probe and probe.Instance then
			context.LastWallInstance = probe.Instance
			context.LastWallLeftAt = context.Now
		end
		reattachUntil = context.Now + WALLRUN.ReattachCooldownSeconds
		context.AnimationVariant = nil

		-- LedgeHanging genuinely wants no hand-off: its ENTER writes the kinematic command itself (see
		-- that state's "THE GRAB BITES ON THE FRAME IT IS DETECTED" note), so it has already replaced
		-- this frame's command by the time it is committed.
		--
		-- WallJumping was grouped with it on the reasoning that it "composes its own departure velocity
		-- and needs the state intact to do it." The second half is true -- it reads this module's locals
		-- in its Enter -- but it does not follow: WallJumping.Enter computes its velocity into a local
		-- and writes the MOTOR only from its Update, a frame later. So this frame still committed the
		-- WALL-RUN's command, whose velocity includes the stick INTO the wall, on the exact frame the
		-- player kicked off it. Handing off with the live velocity releases the body cleanly instead;
		-- the write is a no-op against what the assembly already has, and it is the rig teardown that
		-- matters. Same reading, same fix, and the same false premise as the traversal exits in
		-- States/Sliding.lua and States/Rolling.lua.
		if nextState == "LedgeHanging" then
			return
		end
		if nextState == "WallJumping" then
			StateSupport.HandOff(context, context.RootPart.AssemblyLinearVelocity)
			return
		end
		local tangent = if probe
			then ParkourMath.WallTangent(probe.Normal, StateSupport.TravelDirection(context))
			else Vector3.zero
		StateSupport.HandOff(context, tangent * context.Momentum + Vector3.new(0, verticalSpeed, 0))
	end,
}

return WallRunning
