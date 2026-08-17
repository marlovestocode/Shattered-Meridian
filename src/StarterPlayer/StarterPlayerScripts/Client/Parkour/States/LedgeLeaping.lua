--!strict
--[[
	States/LedgeLeaping.lua

	Owns: the ledge-to-ledge leap's flight -- once States/LedgeHanging.lua has decided to launch one.
	This file solves nothing and searches for nothing; both already happened in the state that handed
	off to it. What this owns is the arc itself: integrating gravity into the velocity it was launched
	with, and catching whatever ledge comes into range on the way.

	ROUTE-1 ONLY, like States/Landing.lua. CanEnter always refuses -- "should a ledge-to-ledge leap be
	starting" is not a question this state, or any pre-emption pass, can answer from context alone; it
	depends on having just been hanging, aimed somewhere, and found a reachable target, which is exactly
	what LedgeHanging.Update already decided before returning this state's id. That decision is a route-1
	transition (StateMachine.Update's own current.Update()-return path), which does not consult CanEnter
	at all -- the refusal below exists purely so the debug overlay and any future pre-emption pass never
	mistake this for an offered state.

	THE LAUNCH VELOCITY IS NOT COMPUTED HERE. LedgeHanging.Update wrote it straight into context.Motor on
	the deciding frame (the same "the frame that decides also commits the motor" technique that file's
	own Enter block uses for the grab itself -- see StateMachine.applyTransition for why Exit runs before
	Enter on the SAME frame, which is what makes reading it back here safe rather than stale). Enter below
	only seeds this state's own integrated `velocity` from that value, exactly the way States/Leaping.lua
	seeds its own `velocity` from a solve it performs itself -- the only difference is who did the
	solving, not what either state does with the result afterward.

	THE ARRIVAL IS THE SAME AMBIENT CATCH States/Leaping.lua's own near-miss uses
	(StateSupport.LedgeGrabAvailable, checked every frame this state's declared Probes keep live) rather
	than any bespoke "did I reach MY specific target" tracking. That is deliberate, not a simplification
	that lost precision: the flight was aimed at a target EnvironmentProbe.FindLedgeLeapTarget already
	confirmed reachable, so arriving close enough to it is arriving close enough to satisfy the same
	grab predicate every other airborne ledge-catch in this framework uses -- one answer to "is there a
	ledge here to catch," not two.

	Does not own: whether to leap at all, or where (States/LedgeHanging.lua), the search
	(EnvironmentProbe.FindLedgeLeapTarget), or the arc math (ParkourMath.SolveLaunchVelocity).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local LEAP = ParkourConstants.Leap

-- The velocity being flown this frame, integrated across the flight -- same arrangement as States/
-- Leaping.lua and States/WallJumping.lua, and for the same reason: the LinearVelocity constraint
-- commands all three axes, so gravity has to be integrated here or the character holds a constant
-- vertical speed for the whole arc.
local velocity = Vector3.zero

local LedgeLeaping: ParkourTypes.StateDefinition = {
	Id = "LedgeLeaping",
	-- Priority is required by the registry but never consulted -- CanEnter always refuses, so this can
	-- never win a pre-emption pass regardless of the number. Placed alongside Leaping (175) rather than
	-- at either extreme, purely so a reader scanning States/init.lua's priority ladder finds it next to
	-- the move it is a sibling of.
	Priority = 176,
	Drive = "Velocity",
	-- Ledge, for the ambient catch (see this file's header); Ground, the blanket requirement every
	-- state in this framework carries. No Walls -- unlike States/Leaping.lua, nothing here reads
	-- context.WallLeft/WallRight, so requesting it would only be paying for a probe nobody uses.
	Probes = { Ground = true, Ledge = true },
	Reports = "Leap",
	-- Committed for the length of the flight, same reasoning as States/Leaping.lua's own: the arc is a
	-- promise to a specific target, and letting another state steal the character mid-flight would be
	-- the same as never having searched for one.
	Committed = true,

	CanEnter = function(): (boolean, string?)
		return false, "Route1Only"
	end,

	Enter = function(context: ParkourContext): ()
		-- Seeded from what LedgeHanging.Update already wrote into the shared command -- see this file's
		-- header for why reading it back here is safe rather than stale.
		velocity = context.Motor.Velocity
		context.Momentum = ParkourMath.PlanarSpeed(velocity)
		context.AnimationVariant = nil
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		velocity -= Vector3.new(0, Workspace.Gravity * context.DeltaTime, 0)
		context.Momentum = ParkourMath.PlanarSpeed(velocity)

		local motor = context.Motor
		motor.Mode = "Velocity"
		motor.Velocity = velocity
		motor.CancelGravity = true
		motor.FaceDirection = ParkourMath.Flatten(velocity)
		motor.DesiredSpeed = context.Momentum

		-- THE CATCH -- see this file's header for why this is the same predicate every other airborne
		-- ledge grab in the framework uses rather than bespoke arrival tracking. Handed this state's OWN
		-- integrated vertical speed, not the context's measured one, for the same reason States/
		-- Leaping.lua's identical check is: the constraint is being commanded from `velocity` here, and
		-- the context's measured value trails it by a frame.
		if StateSupport.LedgeGrabAvailable(context, velocity.Y) then
			return "LedgeHanging"
		end

		-- Landed short, or overshot onto solid ground rather than catching anything -- resolve into
		-- ordinary ground locomotion the same way a landed States/Leaping.lua flight does. The minimum
		-- flight guard is the same one WallJumping/Leaping use: on the launch frame the character is
		-- often still touching whatever they left.
		if context.Ground.Grounded and context.StateElapsed > LEAP.MinFlightSeconds then
			return StateSupport.ResolveGroundedState(context)
		end

		-- The backstop, not the exit. Reuses Leap.MaxFlightSeconds rather than a value of its own so
		-- this state's worst case can never exceed what ParkourController's own ACTION_DURATIONS table
		-- grants the "Leap" report kind it shares with States/Leaping.lua -- a dedicated, LONGER cap here
		-- would silently outlive the server's ownership window and hand WalkSpeed back to the resolver
		-- while this state still believed it owned velocity.
		if context.StateElapsed >= LEAP.MaxFlightSeconds then
			return "Falling"
		end
		return nil
	end,

	Exit = function(context: ParkourContext): ()
		context.AnimationVariant = nil
		StateSupport.HandOff(context, velocity)
	end,
}

return LedgeLeaping
