--!strict
--[[
	States/WallLaunching.lua

	Owns: the custom launch off a wall too tall to vault, mantle, wall-run or catch -- a short,
	high-priority window between leaving the ground and Falling taking back over, that exists for
	exactly one purpose: hand a player who jumped AT a dead-end wall the room and the time to look up
	and dash straight up it.

	WHY THIS IS ITS OWN STATE, NOT A BRANCH INSIDE States/Jumping.lua (which is what an earlier version
	of this feature was). An ordinary jump and a deliberate wall-scaling launch are genuinely different
	moves with genuinely different numbers -- folding one into the other meant every reader of Jumping
	had to hold both in their head, and meant Jumping's own "an ordinary jump, always" contract (see its
	own header) was no longer quite true. Splitting them costs nothing this framework doesn't already
	pay for every other move: one more file, one more line in States/init.lua, and the state machine's
	own priority-sorted route-2 scan (StateMachine.Update) does the actual dispatch for free -- a
	wall-facing jump press resolves to THIS state whenever its own conditions are met and to the
	ordinary Jumping otherwise, with neither file needing to know the other exists.

	PRIORITY 75, one above Jumping's 70 and nothing more:
	  * ABOVE JUMPING, so that when both this state's and Jumping's CanEnter would accept on the same
	    frame (grounded, jump pressed, a wall dead ahead), the state machine's descending-priority scan
	    (StateMachine.Update) reaches this one first and Jumping is never even asked. Below every
	    genuine traversal state (Sliding at 120 and up) on purpose: this is a JUMP variant, not a
	    traversal, and nothing about the launch needs to out-rank a vault, a mantle or a wall-run that
	    was already legitimately in progress.
	  * BELOW DASHING (130), which is what lets "look up, click dash" actually work: route-2 entry into
	    Dashing requires the incoming state to strictly outrank the active one, and Dash.AllowedFromStates
	    names this state explicitly for exactly that pre-emption.

	THE THREE THINGS THE LAUNCH DOES, all at Enter, all synchronous (ParkourMotor.ApplyImpulse -- which
	StateSupport.TryJump reaches here, since this launch always carries planar speed -- writes
	AssemblyLinearVelocity directly; no physics step has to pass for either to take effect):
	  1. VERTICAL -- WallLaunch.VerticalVelocity, a bit more than an ordinary jump's (Jump.JumpVelocity).
	     "A little higher," not a second jump's worth -- see that constant's own comment.
	  2. THE BACKWARD TILT -- WallLaunch.BackwardSpeed, pushed along -entryFacing (away from the wall).
	     Two jobs at once, not one: it is the "room to look up" the design asked for (the wall's face no
	     longer fills the camera the instant the launch starts), and it is what keeps
	     States/WallRunning.lua's own Catching phase from immediately re-claiming this launch on the very
	     next frame -- that phase's own MinClosingSpeed gate is measured on the SURFACE NORMAL, and a
	     body already moving AWAY from the wall has a negative closing speed by construction. No priority
	     fight against WallRunning (160, well above this state's own 75) is needed; the physics of the
	     launch itself is the guard.
	  3. THE DASH-CHAIN WINDOW -- context.WallLaunchDashBoostUntil, a deadline States/Dashing.lua reads
	     (never writes) to grant its own Up-quadrant dash some extra hang once chained from here. See
	     Dash.WallLaunchChainExtraHangSeconds' own comment for the number and the full reasoning.

	THE WALL DETECTION is the same signal States/Vaulting.lua and States/Mantling.lua would refuse on:
	ObstacleProbe.Height == math.huge is EnvironmentProbe's own "no top surface found within the
	traversable band" result, i.e. an honestly unclimbable wall rather than a tall-but-mantleable ledge.
	Gating on that instead of a height NUMBER means a wall this state should launch off of and a wall
	Mantling should instead pull the player onto can never be confused for each other by construction.

	Runs in Humanoid drive mode, exactly like Jumping -- Roblox's own air control is responsive and
	correct for the rise, and there is no bounded-air-control requirement here the way a wall-kick's
	control lock has.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local WALL_LAUNCH = ParkourConstants.WallLaunch

local WallLaunching: ParkourTypes.StateDefinition = {
	Id = "WallLaunching",
	Priority = 75,
	Drive = "Humanoid",
	-- The same set Jumping and Falling request, and for the same reason: this state has real exits
	-- (a ledge that appears mid-rise, a wall that turns out to be wall-runnable once moving away from
	-- it fails and the player is falling back toward it) and the probes that decide them have to be
	-- fresh on the frame the opportunity appears.
	Probes = { Ground = true, Walls = true, Ledge = true, Obstacle = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- NOT combat-gated, deliberately, matching Jumping's own precedent exactly: this is a jump
		-- variant, not a traversal, and jumping is fundamental movement the combat layer must never
		-- suppress (see States/Jumping.lua, which does not call StateSupport.CombatBlocks either).
		-- ParkourConstants.CombatGate.BlockedStates has no "WallLaunching" entry to match.
		--
		-- GROUNDED ONLY, deliberately unlike Jumping's coyote branch: this is a deliberate "I am
		-- standing at a wall and choosing to launch off it" move, not a forgiveness window for a jump
		-- that was already going to happen anyway.
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		if not StateSupport.JumpQueued(context) then
			return false, "NoJumpInput"
		end
		if not StateSupport.JumpIntervalElapsed(context.Now) then
			return false, "JumpCooldown"
		end
		if not (context.Obstacle.Found and context.Obstacle.Height == math.huge) then
			return false, "NoWallAhead"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeJump(context.Now)
		StateSupport.NoteJump(context.Now)

		local entryFacing =
			ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.new(0, 0, -1))
		-- Away from the wall the character is facing -- see the file header for why this vector does
		-- two jobs, not one.
		local backward = -entryFacing

		context.Momentum = WALL_LAUNCH.BackwardSpeed
		StateSupport.TryJump(
			context,
			StateSupport.LaunchPlanarVelocity(backward, WALL_LAUNCH.BackwardSpeed),
			WALL_LAUNCH.VerticalVelocity
		)

		context.WallLaunchDashBoostUntil = context.Now + WALL_LAUNCH.DashBoostWindowSeconds

		-- Same landing-rescue courtesy every launch in this framework performs on entry -- a fresh
		-- launch should not also be paying a stale fall's cost.
		context.LandingSeverity = nil
		context.FallHeight = 0
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		StateSupport.ApplyAirLocomotion(context)

		-- Landed again already (launched at a wall with a low ledge right beside it). Falling owns the
		-- landing classification, so hand off rather than duplicating it here -- exactly Jumping's own
		-- rule.
		if context.Ground.Grounded and context.StateElapsed > 0.1 then
			return "Falling"
		end
		-- Past the apex: Falling owns everything downward. The small negative threshold rather than
		-- <= 0 avoids flickering between the two states for the frame or two vertical velocity hovers
		-- around zero at the top of the arc.
		if context.VerticalVelocity < -1 then
			return "Falling"
		end
		return nil
	end,
}

return WallLaunching
