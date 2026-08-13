--!strict
--[[
	States/StateSupport.lua

	Owns: the handful of operations more than one movement state needs, factored out so they exist
	once rather than being re-derived per state -- ground/air locomotion application, the
	grounded-state picker, the jump primitive, obstacle classification, and the shared "is the body
	currently ours to drive" gate.

	Not itself a state (it has no Id and is never registered) -- it sits alongside them because every
	one of its functions is meaningless outside a state's Update, and putting it a directory up would
	just mean a longer require path for the only callers it will ever have.

	The bar for something living here rather than in the one state that uses it is deliberately high:
	two or more real callers, or a piece of logic whose duplication would let two states silently
	disagree about the same question (which grounded state to be in; whether a jump is legal). A
	helper with one caller belongs in that caller.

	Does not own: any state's own behavior, any Constants value (it reads ParkourConstants like
	everything else), or any decision the state machine makes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObstacleClassifier = require(ReplicatedStorage.Shared.Parkour.ObstacleClassifier)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local ParkourMotor = require(script.Parent.Parent.ParkourMotor)

type ParkourContext = ParkourTypes.ParkourContext
type MovementStateId = ParkourTypes.MovementStateId

local StateSupport = {}

local LOCOMOTION = ParkourConstants.Locomotion
local SLOPE = ParkourConstants.Slope

-- Reused measurement table handed to ObstacleClassifier.Classify -- one allocation for the session
-- rather than one per frame per state that asks about obstacles (which, while sprinting, is every
-- frame).
local obstacleMeasurement = {
	Found = false,
	Height = 0,
	Depth = 0,
	Distance = 0,
	Speed = 0,
	Grounded = false,
	HasLandingSpace = false,
	HasStandingSpace = false,
	VaultAllowed = true,
	MantleAllowed = true,
}

-- Whether there is meaningful movement intent this frame. One definition, used by every state, so
-- "is the player asking to move" can never mean two different things in two states.
function StateSupport.HasMoveIntent(context: ParkourContext): boolean
	return context.MoveIntent.Magnitude >= LOCOMOTION.InputMagnitudeThreshold
end

-- THE SHARED "AM I ACTUALLY GOING TOWARD THE THING I'M ABOUT TO INTERACT WITH" GATE.
--
-- `travelDirection` and `outwardNormal` need not be flat or unit already -- both are flattened and
-- normalized here, so every caller can hand in a raw probe field without its own SafeUnit dance. A
-- degenerate outward normal (the zero vector -- should not happen for a real hit, but a caller should
-- never crash on a bad probe) refuses rather than passing, which is the correct default: "cannot tell
-- whether you're facing it" is not "yes."
--
-- Written once because the same question recurs everywhere a traversal is offered on obstacle/probe
-- geometry that was found on a DIFFERENT frame than the one deciding whether to commit to it: a
-- mantle or vault found the obstacle on one cast, then re-evaluates CanEnter on live input that has
-- had a probe interval's worth of time to diverge (the player let go, reversed, or is now merely
-- grazing the obstacle's side rather than closing on its face). Three independently-written angle
-- checks in Mantling/Vaulting/wherever comes next would be three chances for the threshold, the sign
-- convention, or the flattening to quietly disagree -- see this file's own header on why that bar is
-- what earns a helper a place here.
function StateSupport.IsMovingToward(travelDirection: Vector3, outwardNormal: Vector3, maxAngleDegrees: number): boolean
	local into = ParkourMath.SafeUnit(ParkourMath.Flatten(outwardNormal), Vector3.zero) * -1
	if into.Magnitude < 1e-3 then
		return false
	end
	return ParkourMath.ApproachAngle(travelDirection, into) <= maxAngleDegrees
end

-- The direction the character should be treated as travelling: its actual movement direction while
-- it has one, falling back to held input, then to facing. Three fallbacks rather than one because
-- each covers a real case -- a character sliding with no input still has a travel direction, a
-- character accelerating from rest has input but barely any velocity, and a character standing still
-- against a wall has neither but is still facing somewhere.
function StateSupport.TravelDirection(context: ParkourContext): Vector3
	local moving = ParkourMath.Flatten(context.MoveDirection)
	if moving.Magnitude >= 1e-3 then
		return moving.Unit
	end
	local intent = ParkourMath.Flatten(context.MoveIntent)
	if intent.Magnitude >= 1e-3 then
		return intent.Unit
	end
	return ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.new(0, 0, -1))
end

-- Target speed for ordinary ground locomotion: sprint speed while sprint is engaged AND there is real
-- input, walk speed otherwise, scaled for the slope being travelled. Sprint requires input because
-- holding the sprint key while standing still is not sprinting, and letting it raise the target would
-- mean the character launched off the line at sprint speed the instant a key was touched.
--
-- The result is INFORMATIONAL -- it reaches MotorCommand.DesiredSpeed and no further. See that field's
-- own header for why (the server owns running speed and is slope-blind), and for where slope actually
-- takes effect instead. Kept rather than deleted because it is the honest statement of what this state
-- wants, which is what the debug overlay needs to show; do not mistake it for something that moves the
-- character.
function StateSupport.GroundTargetSpeed(context: ParkourContext): number
	if not StateSupport.HasMoveIntent(context) then
		return 0
	end
	local base = if context.SprintHeld then LOCOMOTION.SprintSpeed else LOCOMOTION.WalkSpeed
	local signedSlope = ParkourMath.SignedSlopeAlong(context.Ground.Normal, StateSupport.TravelDirection(context))
	return base
		* ParkourMath.SlopeSpeedScale(signedSlope, SLOPE.UphillSpeedPenaltyPerDegree, SLOPE.DownhillSpeedBonusPerDegree)
end

-- Applies one frame of ordinary, engine-driven locomotion: hands the body to Roblox's own character
-- controller and reconciles the framework's momentum belief toward what the character is actually
-- doing.
--
-- Momentum is RECONCILED here, not simulated. While the engine drives, the engine's measured speed
-- is the truth -- the framework's own number exists so a traversal that starts on the next frame
-- knows what it inherited, and letting it drift away from reality would make every traversal's
-- entry gate lie. The convergence is rate-limited (LOCOMOTION.MomentumReconcileRate) rather than
-- instant so one frame of contact with a doorframe doesn't erase a sprint's worth of speed.
--
-- The reason this can be so simple -- and the reason no WalkSpeed is written here -- is that
-- Server/Combat/Movement.ComputeDesiredWalkSpeed already owns that property and already ramps it
-- (see its own momentum smoothing), including honoring the post-action momentum floor this
-- framework's action reports hand it. Writing WalkSpeed from the client would be overwritten within
-- a frame and would fight the very system it needs to cooperate with.
function StateSupport.ApplyGroundLocomotion(context: ParkourContext): ()
	context.Momentum = ParkourMath.StepToward(
		context.Momentum,
		context.PlanarSpeed,
		LOCOMOTION.MomentumReconcileRate,
		context.DeltaTime
	)
	context.Motor.Mode = "Humanoid"
	context.Motor.DesiredSpeed = StateSupport.GroundTargetSpeed(context)
end

-- Airborne counterpart. Same reconciliation, same hand-off to the engine -- Roblox's own air control
-- is responsive and correct, and the momentum a jump carries is preserved by the server's momentum
-- floor rather than by this framework re-implementing air physics. States that genuinely need
-- bounded air control (WallJumping's post-push control lock) take Velocity mode instead and
-- integrate their own gravity; everything else is better served by the engine.
function StateSupport.ApplyAirLocomotion(context: ParkourContext): ()
	context.Momentum = ParkourMath.StepToward(
		context.Momentum,
		context.PlanarSpeed,
		LOCOMOTION.MomentumReconcileRate,
		context.DeltaTime
	)
	context.Motor.Mode = "Humanoid"
	context.Motor.DesiredSpeed = context.Momentum
end

-- Which of the three ordinary ground states the character belongs in right now. Centralized because
-- all three of them, plus every state that ends by handing back to the ground (Landing, Sliding,
-- Rolling, Mantling, Vaulting), need the same answer -- and three states independently deciding
-- "am I walking or sprinting" is exactly how a character ends up flickering between two of them.
function StateSupport.ResolveGroundedState(context: ParkourContext): MovementStateId
	if not StateSupport.HasMoveIntent(context) and context.PlanarSpeed < LOCOMOTION.IdleSpeedThreshold then
		return "Idle"
	end
	if context.SprintHeld and StateSupport.HasMoveIntent(context) then
		return "Sprinting"
	end
	return "Walking"
end

-- Classifies whatever the obstacle probe last found. Returns the classifier's shared result table --
-- read it immediately, never retain it (ObstacleClassifier.Classify's own contract).
function StateSupport.ClassifyObstacle(context: ParkourContext): ObstacleClassifier.Classification
	local probe = context.Obstacle
	obstacleMeasurement.Found = probe.Found
	obstacleMeasurement.Height = probe.Height
	obstacleMeasurement.Depth = probe.Depth
	obstacleMeasurement.Distance = probe.Distance
	obstacleMeasurement.Speed = context.Momentum
	obstacleMeasurement.Grounded = context.Ground.Grounded
	obstacleMeasurement.HasLandingSpace = probe.HasLandingSpace
	obstacleMeasurement.HasStandingSpace = probe.HasStandingSpace
	obstacleMeasurement.VaultAllowed = probe.VaultAllowed
	obstacleMeasurement.MantleAllowed = probe.MantleAllowed
	return ObstacleClassifier.Classify(obstacleMeasurement, ParkourConstants.Obstacle)
end

-- Whether the character is close enough to an obstacle to begin traversing it. The classifier
-- answers "is this traversable"; this answers "is it time" -- a vault decided ten studs out and
-- started immediately would launch the character into open air.
function StateSupport.WithinTraversalRange(context: ParkourContext): boolean
	-- Scales with speed for the same reason the probe's own reach does: at a sprint the character
	-- covers more ground per frame, so the commit distance has to be further out or the near face is
	-- already behind them by the time the next frame runs.
	local commitDistance = 1.8 + context.Momentum * ParkourConstants.Obstacle.ProbeDistanceSpeedScale
	return context.Obstacle.Found and context.Obstacle.Distance <= commitDistance
end

-- os.clock() of the most recent jump produced by ANY route. Lives here rather than in
-- States/Jumping.lua because this game can launch a jump from three different states -- an ordinary
-- jump, a slide-jump (which keeps the slide's boosted momentum instead of the jump state's) and a
-- wall-jump (which composes its own velocity) -- and a guard that only covered one of them would let
-- a single press produce two launches whenever two of those resolved on the same frame. Coyote time
-- and the jump buffer make that overlap a genuine, reachable case, not a theoretical one.
local lastJumpAt = 0

function StateSupport.NoteJump(now: number): ()
	lastJumpAt = now
end

function StateSupport.JumpIntervalElapsed(now: number): boolean
	return (now - lastJumpAt) >= ParkourConstants.Jump.MinIntervalSeconds
end

-- Planar launch velocity for a jump: travel direction at the given speed, safe against a degenerate
-- direction. Shared by all three launch sites above so they cannot disagree about how momentum maps
-- onto a launch vector.
function StateSupport.LaunchPlanarVelocity(direction: Vector3, speed: number): Vector3
	return ParkourMath.SafeUnit(ParkourMath.Flatten(direction), Vector3.zero) * speed
end

-- Performs a jump, choosing the correct mechanism for the situation, and returns whether one
-- actually happened.
--
-- Two mechanisms, because there genuinely are two cases:
--   * Grounded -> ask the Humanoid. This produces the engine's own Jumping state transition, which
--     Server/Combat/Movement.ComputeGenuineJumpAirborne reads to credit a GENUINE jump (the flag
--     that gates AirSlam -- see that function's own header for the exploit list it closes). A
--     parkour jump that bypassed the Humanoid would silently stop crediting that, and AirSlam would
--     quietly stop working out of parkour movement.
--   * Airborne (coyote time, or launching out of an owned action) -> a direct velocity write, since
--     the Humanoid refuses to jump while it believes it is falling.
-- Both honor CombatClient.lua's jump suppression through ParkourMotor's own state-enabled check.
function StateSupport.TryJump(context: ParkourContext, planarVelocity: Vector3, verticalSpeed: number): boolean
	if not ParkourMotor.IsJumpEnabled() then
		return false
	end
	if context.Ground.Grounded and planarVelocity.Magnitude < 1e-3 then
		return ParkourMotor.RequestHumanoidJump()
	end
	return ParkourMotor.ApplyImpulse(Vector3.new(planarVelocity.X, verticalSpeed, planarVelocity.Z))
end

-- Whether a jump input is live and legal right now, without consuming it. The CanEnter-safe half of
-- TryJump -- see InputBuffer.lua's Peek/Consume contract for why every CanEnter must use this and
-- never the consuming form.
function StateSupport.JumpQueued(context: ParkourContext): boolean
	return ParkourMotor.IsJumpEnabled() and InputBuffer.PeekJump(context.Now)
end

-- THE HAND-OFF, called from a velocity-owning or kinematic state's Exit: describes the frame's motor
-- command as "give the body back to the engine, carrying this velocity."
--
-- This exists because of a specific ordering fact that is easy to get wrong. On the frame a
-- transition happens, the OUTGOING state's Update has already filled the shared motor command (with,
-- say, a kinematic CFrame), and the incoming state's Update does not run until the next frame --
-- StateMachine.Update applies at most one transition and returns immediately. Without this call the
-- transition frame would commit the outgoing state's last command one extra time: a vault would
-- re-anchor for a frame after it finished, and its exit velocity would be written onto an anchored
-- part and silently discarded (see ParkourMotor.Apply's own note on that ordering). Calling this
-- from Exit rewrites the command to the correct hand-off, so the very frame a traversal ends is the
-- frame the body is released with its momentum intact.
function StateSupport.HandOff(context: ParkourContext, exitVelocity: Vector3): ()
	context.Motor.Mode = "Humanoid"
	context.Motor.Velocity = exitVelocity
	context.Motor.TargetCFrame = nil
	context.Motor.HipHeightDelta = 0
	context.Motor.CancelGravity = false
end

return StateSupport
