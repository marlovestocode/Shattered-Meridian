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
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext
type WallProbe = ParkourTypes.WallProbe

local WALLJUMP = ParkourConstants.WallJump

-- The velocity being flown this frame, integrated across the control lock.
local velocity = Vector3.zero

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
		context.WallJumpChain += 1
		context.Momentum = ParkourMath.PlanarSpeed(velocity)
		context.AnimationVariant = "WallJump"

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
		if context.StateElapsed >= WALLJUMP.ControlLockSeconds then
			return "Falling"
		end
		return nil
	end,

	Exit = function(context: ParkourContext): ()
		context.AnimationVariant = nil
		StateSupport.HandOff(context, velocity)
	end,
}

return WallJumping
