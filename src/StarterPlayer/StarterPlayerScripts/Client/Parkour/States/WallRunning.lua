--!strict
--[[
	States/WallRunning.lua

	Owns: running along a vertical surface AND kicking off it -- entry conditions, following the wall's
	actual tangent, the rise-then-sink vertical profile, the departure push/assist/control-lock, and
	every rule that stops either half from becoming free vertical flight.

	THE KICK LIVES HERE NOW, not in its own state. It used to be States/WallJumping.lua, a separately
	registered state reached by a route-1 hand-off the instant jump was pressed mid-run. That split was
	a liability rather than a boundary: the hand-off bypassed WallJumping.CanEnter entirely (route 1
	always does), which meant every gate that mattered for the KICK -- the combat gate, and critically
	the wall-jump chain cap -- had to be manually restated at the hand-off site, and the chain cap
	restatement was missing for a while (see the chain-cap reasoning in `phase == "Departing"`'s trigger
	below). A gate that has to be copied to stay correct eventually isn't. Folding the kick in as a
	second PHASE of this same state, rather than a second state, means there is exactly one place that
	decides whether a kick may happen, and it can never be bypassed by construction -- there is no
	second entry point left to bypass it FROM. It also means a wall-jump is no longer reachable by
	simply falling past a wall: kicking off is now something a wall-run DOES on its way out, not an
	independently-triggerable move.

	THE TWO PHASES, tracked by the file-local `phase`:
	  * "Running"   -- the ordinary ride: follow the tangent, rise then sink, watch for a ledge or a
	                   jump press. Everything this file always did.
	  * "Departing" -- the kick and its brief control lock, ending in a hand-off to Falling (or a
	                   ledge grab, if one appears mid-flight -- see updateDeparting's own note). A
	                   PHASE change, not a state transition: StateMachine never sees it, Enter/Exit do
	                   not run, and context.StateElapsed keeps counting from the ORIGINAL wall attach --
	                   which is exactly why the kick keeps its own clock (kickBeganAt) rather than
	                   reading StateElapsed the way the old standalone state could.
	Both phases report to the server as the same "WallRun" action (Reports below is unchanged) -- the
	kick is not a separate network event any more either, just a continuation of the same open
	ownership window. Validation's caps are already uniform across every ActionKind (see
	ParkourValidation's own header), so nothing there needed loosening for a kick's higher peak speed.

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

	THE ANTI-INFINITE-CLIMB RULES, which together are why this cannot be used to ascend arbitrarily and
	why none of them needed to be a blunt "no vertical gain" ban:
	  1. SameWallLockoutSeconds -- the specific part just left cannot be re-attached to for a moment.
	     Kills the "run, jump, re-attach to the same wall" ladder.
	  2. MaxChainWithoutGround -- a hard count of wall-runs since the last ground contact. Kills the
	     "three walls in a triangle" version rule 1 alone does not cover.
	  3. The vertical profile itself -- a short rise (RiseSeconds) then a decaying sink under a
	     fraction of gravity. The run visibly runs out of lift, which makes the limit legible without
	     any UI.
	  4. WallJump.MaxChainWithoutGround -- the kick's OWN chain cap, checked at the single trigger site
	     below. Falloff (ChainFalloffMultiplier) already shrinks the push and lift per link, but the
	     MOMENTUM CARRY component does not decay at all -- so without the cap, alternating wall-run ->
	     kick -> wall-run -> kick could keep full carried speed indefinitely down a corridor. This is
	     the one gate that used to need restating at the old route-1 hand-off and was, for a while,
	     missing; merging the kick in here removes the second site that restatement could drift from.

	Runs in Velocity drive mode with gravity cancelled while Running (fully integrated, ballistic, while
	Departing), so both the rise/sink profile and the kick's own arc are authored/physical rather than
	emergent. The inward stick component during Running is what keeps the character against the surface
	instead of drifting off it.
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

local WALLRUN = ParkourConstants.WallRun
local WALLJUMP = ParkourConstants.WallJump
local ASSIST = WALLJUMP.Assist

-- Which side the active run is on, and everything derived from the wall it is on. Captured at Enter
-- and refreshed each frame from whichever probe is still finding the same surface. Also what the kick
-- reads to know which wall it is departing -- see updateDeparting/beginKick, neither of which needs a
-- separate wall lookup of their own any more (WallJumping.lua's old `nearestWall` existed only because
-- that state could be entered from open air with no wall already selected; a kick can now only start
-- from an active run, where this is already known).
local side = 0
local verticalSpeed = 0
local reattachUntil = 0

-- Phase within an active wall-run -- see this file's header for what each means and why a phase change
-- is not a state transition.
local phase: "Running" | "Departing" = "Running"

-- THE KICK'S OWN STATE, mirroring what used to be States/WallJumping.lua's own file-locals.
--
-- The velocity being flown this frame, integrated across the control lock.
local kickVelocity = Vector3.zero
-- Whether THIS kick is flying a solved trajectory rather than the fixed push. Decided when the kick
-- begins and read every Departing frame for one thing only: how long the control lock holds. A solved
-- arc is a promise, and air control applied to it immediately is the player steering off a prediction
-- made for them.
local kickAssisted = false
-- Where the body was pointing on the frame the kick launched, so updateDeparting can turn it toward the
-- departure direction over the lock instead of retargeting the orientation drive to it on frame one.
local kickEntryFacing = Vector3.new(0, 0, -1)
-- os.clock() the current kick began. The control lock and facing ease both need a clock that starts at
-- ZERO when the kick starts -- context.StateElapsed does not, because it spans the whole run the kick
-- is departing from, which could already be well past either window's own length.
local kickBeganAt = 0

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

-- Begins the kick: computes the departure velocity (unassisted push, or a solved trajectory when
-- EnvironmentProbe.FindWallJumpTarget finds something to aim at) exactly the way States/WallJumping.lua
-- used to in its own Enter, and switches `phase` to "Departing". Ported near-verbatim -- the physics
-- did not change, only where it lives and what it reads the wall from (`probe`, the run's own active
-- wall, rather than a fresh scan).
local function beginKick(context: ParkourContext, wall: WallProbe): ()
	InputBuffer.ConsumeJump(context.Now)
	StateSupport.NoteJump(context.Now)

	kickBeganAt = context.Now
	kickEntryFacing =
		ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.new(0, 0, -1))

	local normal = wall.Normal
	local bounce = wall.BounceScale
	local outward = ParkourMath.SafeUnit(ParkourMath.Flatten(normal), Vector3.new(0, 0, -1))

	-- WHERE THE JUMP IS AIMED, computed BEFORE the push itself -- both the unassisted push below and
	-- the target scan further down read this same blend, so a player's aim means one thing for the
	-- whole kick rather than two slightly different things depending on whether a target ends up being
	-- found.
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

	-- THE UNASSISTED PUSH IS STEERABLE, not pinned to the bare wall normal. `aim` already leans toward
	-- wherever the player is looking; ParkourMath.SteerDirection here is doing something it was not
	-- written for (that function is normally a per-frame turn-rate ramp) but is exactly the primitive
	-- this needs anyway: called with a "rate" of WallJump.MaxAimSteerDegrees and a "deltaTime" of 1
	-- second, it rotates `outward` toward `aim` by AT MOST that many degrees in one step -- landing
	-- exactly on `aim` when it is already within the cone (the common case: a modest look-away), and
	-- clamped to the cone's edge when it is not (a player aiming almost along the wall face, which this
	-- refuses to fully honor -- see MaxAimSteerDegrees' own header for why a kick must stay recognizably
	-- a kick). A player not aiming anywhere in particular has `aim == outward` from the fallback two
	-- lines up, so this is a no-op for them: the departure is identical to the wall-jump that existed
	-- before this steering did.
	local pushDirection = ParkourMath.SteerDirection(outward, aim, WALLJUMP.MaxAimSteerDegrees, 1)

	kickVelocity = ParkourMath.WallJumpVelocity(
		pushDirection,
		StateSupport.TravelDirection(context),
		context.Momentum,
		WALLJUMP.PushSpeed * bounce,
		WALLJUMP.UpSpeed,
		WALLJUMP.ForwardRetainFraction,
		context.WallJumpChain,
		WALLJUMP.ChainFalloffMultiplier
	)
	kickAssisted = false

	local target =
		EnvironmentProbe.FindWallJumpTarget(context.RootPart, aim, outward, wall.Instance, wall.Position, context.Now)

	-- A corridor kick off the wall you JUST kicked off is the free elevator: stand against one face,
	-- press jump repeatedly, and take a full-lift kick each time without ever crossing to the other
	-- side. Refusing the corridor branch (not the jump -- the ordinary falloff push is still there) is
	-- what makes the climb require alternating walls, which is the whole reason it can be allowed to
	-- run as long as the shaft is tall. Deliberately a short window: a genuine round trip across a
	-- corridor takes longer than this, so the legitimate return to the wall you came from is untouched.
	local sameWallAsLastKick = wall.Instance ~= nil
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
			-- THE ALONG-TUNNEL CARRY. The solve legitimately owns two axes -- crossing to the far face,
			-- and vertical -- and has no claim on the third, travel ALONG the corridor, which costs the
			-- arc nothing to keep (sliding down a tunnel does not change the distance to either wall).
			-- Retained IN FULL (Assist.CorridorAlongRetainFraction, 1) rather than at the ordinary
			-- kick's ForwardRetainFraction -- see that constant's own header for why 1 is neutral here,
			-- not generous.
			local travel = ParkourMath.Flatten(StateSupport.TravelDirection(context)) * context.Momentum
			local alongCorridor = travel - outward * travel:Dot(outward)
			kickVelocity = solved + alongCorridor * ASSIST.CorridorAlongRetainFraction
			kickAssisted = true
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
		-- An UNREACHABLE solve is refused rather than flown -- flying the clipped arc anyway would be
		-- aiming at something while knowingly throwing short of it, which is worse than the plain push,
		-- because the plain push never claimed to be aimed at anything.
		if reachable then
			kickVelocity = solved
			kickAssisted = true
		end
	end

	context.WallJumpChain += 1
	context.Momentum = ParkourMath.PlanarSpeed(kickVelocity)
	-- Which side the wall was on, so the clip that plays is the mirrored one that matches. Named
	-- distinctly from the run's own "Left"/"Right" variants (see ParkourAnimator's WallRunning entry)
	-- so the two moments -- the loop and the one-shot kick -- can never be confused for one another by
	-- a reader of the variant string alone. "KickNeutral" is a real case rather than a fallback for
	-- missing data: a wall square in front of (or behind) the character has no side, and playing either
	-- mirror for it looks like the character kicking off nothing.
	local kickLeanSide = ParkourMath.WallSide(context.RootPart.CFrame.LookVector, normal)
	context.AnimationVariant = if kickLeanSide < 0
		then "KickLeft"
		elseif kickLeanSide > 0 then "KickRight"
		else "KickNeutral"

	-- Record the wall so the same-wall lockout (both this run's own SameWallLockoutSeconds and the
	-- kick's SameWallCooldownSeconds above) also applies to a re-attach or re-kick attempted straight
	-- out of this one.
	if wall.Instance then
		context.LastWallInstance = wall.Instance
		context.LastWallLeftAt = context.Now
	end

	phase = "Departing"
end

-- One frame of the kick's flight. Called both on the frame the kick begins (immediately after
-- beginKick, so the departure is committed to the motor on the SAME frame it was decided -- the old
-- two-state split could not do this; WallJumping.Enter computed the velocity but did not write the
-- motor until its OWN Update ran a frame later) and on every frame after, for as long as `phase`
-- remains "Departing".
local function updateDeparting(context: ParkourContext): ParkourTypes.TransitionResult
	-- Real gravity, integrated here because the LinearVelocity constraint commands all three axes and
	-- would otherwise hold the character at a constant vertical speed for the whole lock.
	kickVelocity -= Vector3.new(0, Workspace.Gravity * context.DeltaTime, 0)

	local elapsed = context.Now - kickBeganAt
	local lockSeconds = if kickAssisted then ASSIST.ControlLockSeconds else WALLJUMP.ControlLockSeconds
	local lockAlpha = math.clamp(elapsed / math.max(lockSeconds, 1e-3), 0, 1)

	-- THE CONTROL RAMP, replacing a hard cliff. The push is fully protected at the front of the window
	-- (steering back into the wall would undo the whole mechanic), and authority fades in linearly
	-- across the back half so the hand-off to Falling is a continuation rather than a switch. Applied to
	-- the PLANAR component only -- vertical is the ballistic arc, and air control touching it would turn
	-- a kick into a glide.
	local steerAuthority = math.max(lockAlpha - ASSIST.ControlRampStartFraction, 0)
		/ math.max(1 - ASSIST.ControlRampStartFraction, 1e-3)
	if steerAuthority > 0 and StateSupport.HasMoveIntent(context) then
		local planar = ParkourMath.Flatten(kickVelocity)
		local planarSpeed = planar.Magnitude
		if planarSpeed > 1e-3 then
			local steered = ParkourMath.SteerDirection(
				planar.Unit,
				StateSupport.TravelDirection(context),
				WALLJUMP.ControlRampTurnDegreesPerSecond * steerAuthority,
				context.DeltaTime
			)
			kickVelocity = steered * planarSpeed + Vector3.new(0, kickVelocity.Y, 0)
		end
	end

	context.Momentum = ParkourMath.PlanarSpeed(kickVelocity)

	local motor = context.Motor
	motor.Mode = "Velocity"
	motor.Velocity = kickVelocity
	motor.CancelGravity = true
	-- Eased from the facing the kick started with rather than snapped to the departure direction, over
	-- a window deliberately shorter than the control lock (FacingEaseSeconds): the turn should be
	-- finished and out of the way before the player gets steering back.
	local facingAlpha = math.clamp(elapsed / math.max(WALLJUMP.FacingEaseSeconds, 1e-3), 0, 1)
	local departureFacing = ParkourMath.SafeUnit(ParkourMath.Flatten(kickVelocity), kickEntryFacing)
	motor.FaceDirection = ParkourMath.SafeUnit(
		kickEntryFacing:Lerp(departureFacing, ParkourMath.EaseOutCubic(facingAlpha)),
		departureFacing
	)
	motor.DesiredSpeed = context.Momentum

	if context.Ground.Grounded and elapsed > 0.05 then
		return "Falling"
	end

	-- THE TOP-OUT. A ledge appearing mid-flight beats finishing the control lock, the same way it beats
	-- finishing the run itself (Update's own check below does the identical thing while Running, for
	-- the identical reason). This is what turns a chimney climb into something that ENDS somewhere.
	--
	-- Asked against the KICK'S OWN integrated velocity rather than the context's measured one -- during
	-- the lock the constraint is being commanded from `kickVelocity`, and the measured value trails it
	-- by a frame.
	if StateSupport.LedgeGrabAvailable(context, kickVelocity.Y) then
		return "LedgeHanging"
	end

	if lockAlpha >= 1 then
		return "Falling"
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
		phase = "Running"
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
		if phase == "Departing" then
			return updateDeparting(context)
		end

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

		-- A GRABBABLE LEDGE IS CHECKED BEFORE THE KICK, and the order is the point. It used to be the
		-- other way round, which meant running along a wall toward its top edge and pressing jump kicked
		-- you off the wall and past the lip instead of catching it.
		--
		-- Reaching a ledge is also strictly the better outcome: a grab ends the run somewhere, where a
		-- kick taken at the top of a wall throws the player back into open air having gained nothing.
		if StateSupport.LedgeGrabAvailable(context, verticalSpeed) then
			return "LedgeHanging"
		end

		-- THE KICK. Available throughout an active run, and takes priority over everything below --
		-- kicking off a wall is the whole point of being on one. This is the SINGLE site a kick can ever
		-- be triggered from now (see this file's header) -- there is no longer a separate CanEnter this
		-- could bypass, so every gate that matters lives here once and cannot drift out of sync with a
		-- second copy.
		--
		-- The chain cap is what actually needs enforcing here: WALLJUMP.MaxChainWithoutGround bounds how
		-- many kicks a player may take without touching the ground. Falloff (ChainFalloffMultiplier)
		-- already shrinks the push and lift per link, but the momentum-carry component does not decay at
		-- all -- so without this check, a long alternating wall-run/kick chain would keep full carried
		-- speed indefinitely down a corridor, uncapped.
		if
			StateSupport.JumpQueued(context)
			and StateSupport.JumpIntervalElapsed(context.Now)
			and not StateSupport.CombatBlocks(context, "WallJumping")
			and context.WallJumpChain < WALLJUMP.MaxChainWithoutGround
		then
			beginKick(context, probe)
			return updateDeparting(context)
		end
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		context.AnimationVariant = nil

		if phase == "Departing" then
			-- The kick composed its own departure velocity into `kickVelocity`; hand off with THAT, not
			-- with whatever the run's own tangent-following command last was.
			kickAssisted = false
			-- LedgeHanging genuinely wants no hand-off: its Enter writes the kinematic command itself --
			-- see that state's "THE GRAB BITES ON THE FRAME IT IS DETECTED" note.
			if nextState == "LedgeHanging" then
				return
			end
			StateSupport.HandOff(context, kickVelocity)
			return
		end

		local probe = activeWall(context)
		-- Record the wall and the moment it was left, for rule 1 (SameWallLockoutSeconds). Only
		-- meaningful for a Running-phase exit -- a kick already recorded its own departure wall in
		-- beginKick, at the moment it launched, which this must not overwrite with a stale or absent
		-- probe from mid-flight.
		if probe and probe.Instance then
			context.LastWallInstance = probe.Instance
			context.LastWallLeftAt = context.Now
		end
		reattachUntil = context.Now + WALLRUN.ReattachCooldownSeconds

		if nextState == "LedgeHanging" then
			return
		end
		local tangent = if probe
			then ParkourMath.WallTangent(probe.Normal, StateSupport.TravelDirection(context))
			else Vector3.zero
		StateSupport.HandOff(context, tangent * context.Momentum + Vector3.new(0, verticalSpeed, 0))
	end,
}

return WallRunning
