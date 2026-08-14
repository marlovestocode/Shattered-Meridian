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

	During the lock this state runs in Velocity drive mode and integrates its own gravity, so the arc
	is a real ballistic arc rather than a floaty constant-velocity glide. It hands off to Falling the
	moment the lock expires, with the live velocity intact.

	CHAIN FALLOFF (ChainFalloffMultiplier, applied via ParkourMath.WallJumpVelocity) scales both the
	push and the lift by a compounding factor per wall-jump since the last ground contact. Chaining
	still works -- it is one of the most satisfying things in the movement set -- it just pays
	diminishing returns, which caps achievable height without ever telling the player "no."

	THE ASSIST, and why a wall-jump is no longer just a push. A fixed push away from a wall is aimed by
	the player and lands wherever it lands; between two walls that means every link of a chain is a fresh
	act of estimation, and one bad estimate ends the line. So on every jump this state asks
	EnvironmentProbe.FindWallJumpTarget what is actually out there -- a fan of rays across the open side
	plus a short upward arc -- ranks the hits by how nearly each one lies where the player is asking to
	go, and, when something qualifies, flies a trajectory SOLVED to land on it
	(ParkourMath.SolveLaunchVelocity) rather than the fixed push. The surplus in that solve
	(Assist.ReachMargin) is deliberate and small: just more than enough to reach, because landing on the
	mathematical minimum makes every frame of error a miss.

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
local LEDGE = ParkourConstants.Ledge

-- The velocity being flown this frame, integrated across the control lock.
local velocity = Vector3.zero
-- Whether THIS jump is flying a solved trajectory rather than the fixed push. Decided in Enter and read
-- by Update for one thing only: how long the control lock holds. A solved arc is a promise, and air
-- control applied to it immediately is the player steering off a prediction made for them.
local assisted = false

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
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeJump(context.Now)
		StateSupport.NoteJump(context.Now)

		local wall = nearestWall(context)
		local normal = if wall then wall.Normal else Vector3.new(0, 0, -1)
		local bounce = if wall then wall.BounceScale else 1
		local outward = ParkourMath.SafeUnit(ParkourMath.Flatten(normal), Vector3.new(0, 0, -1))

		velocity = ParkourMath.WallJumpVelocity(
			normal,
			StateSupport.TravelDirection(context),
			context.Momentum,
			WALLJUMP.PushSpeed * bounce,
			WALLJUMP.UpSpeed,
			WALLJUMP.ForwardRetainFraction,
			context.WallJumpChain,
			WALLJUMP.ChainFalloffMultiplier
		)
		assisted = false

		-- WHERE THE JUMP IS AIMED, before anything is scanned for.
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
				velocity = solved
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
		context.Momentum = ParkourMath.PlanarSpeed(velocity)

		local motor = context.Motor
		motor.Mode = "Velocity"
		motor.Velocity = velocity
		motor.CancelGravity = true
		motor.FaceDirection = ParkourMath.Flatten(velocity)
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
		-- THE CONDITIONS ARE RESTATED HERE RATHER THAN LEFT TO LedgeHanging.CanEnter, and that is not
		-- duplication for its own sake: a transition a state returns from its own Update is route 1 in
		-- StateMachine.Update, which applies it WITHOUT consulting the target's CanEnter (the caller is
		-- asserting, not asking). So the two gates that make an automatic grab something the player asked
		-- for -- not still rocketing upward, and actually looking at the face -- have to be asked here, or
		-- this hands out exactly the no-button grab of an edge nobody reached for that
		-- Ledge.MaxGrabFacingAngleDegrees exists to refuse.
		--
		-- The vertical test is against this state's OWN integrated velocity rather than the context's
		-- measured one: during the control lock the constraint is being commanded from `velocity`, and the
		-- measured value trails it by a frame.
		if
			context.Assists.LedgeAssist
			and context.Ledge.Found
			and context.Ledge.Allowed
			and context.Ledge.HasStandingSpace
			and context.Ledge.HasHangSpace
			and velocity.Y <= LEDGE.MaxVerticalSpeedToGrab
			and StateSupport.IsMovingToward(
				context.RootPart.CFrame.LookVector,
				context.Ledge.WallNormal,
				LEDGE.MaxGrabFacingAngleDegrees
			)
		then
			return "LedgeHanging"
		end

		local lockSeconds = if assisted then ASSIST.ControlLockSeconds else WALLJUMP.ControlLockSeconds
		if context.StateElapsed >= lockSeconds then
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
