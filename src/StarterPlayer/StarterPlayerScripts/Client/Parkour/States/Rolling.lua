--!strict
--[[
	States/Rolling.lua

	Owns: the dodge/roll -- a short, committed, momentum-preserving burst usable from the ground, out
	of a slide, and (most importantly) at the moment of landing.

	THE LANDING ROLL is the reason this state earns its place rather than being a second slide. A roll
	input landing within ParkourConstants.Roll.LandingWindowSeconds of ground contact converts what
	would have been a hard landing -- most of the player's momentum gone, a recovery window they can't
	move through -- into a full-speed continuation. That is a real, learnable, timing-based skill
	expression attached to something players do constantly, and it is the concrete form of the design's
	"allow the landing system to interact with combat so attacks, rolls, slides, or other actions can
	potentially be performed immediately after landing."

	The set of states a roll may be started from is DATA (ParkourConstants.Roll.AllowedFromStates), not
	a condition in this file, so widening it is a tuning change rather than a code change -- the same
	reasoning that keeps every other threshold in this system out of the state modules.

	Runs in Velocity drive mode with a fixed speed rather than a decaying one: a roll is short enough
	that decay within it would be imperceptible, and a constant speed is what makes its distance
	predictable, which is what makes it usable as a dodge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local ROLL = ParkourConstants.Roll

local rollDirection = Vector3.zero
local cooldownUntil = 0
-- Momentum the roll was entered with, so its exit can return the better of "what I had" and "what a
-- roll is worth" rather than flatly overwriting a faster entry with the roll's own speed.
local entryMomentum = 0

local Rolling: ParkourTypes.StateDefinition = {
	Id = "Rolling",
	Priority = 140,
	Drive = "Velocity",
	Probes = { Ground = true, Obstacle = true, Ceiling = true },
	Reports = "Roll",
	-- Committed: a roll is short and must complete. Without this a roll started at speed would be
	-- immediately pre-empted by whatever the character rolled toward, and the dodge would not exist as
	-- a reliable defensive option -- which is most of its value.
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- Asked first -- see States/WallRunning.CanEnter's own note on why the combat refusal leads.
		-- This is the entry flagged in ParkourConstants.CombatGate's own comment as the most arguable
		-- one: a roll reads as a dodge as much as a traversal move. Remove "Rolling" from that table if
		-- combat starts feeling stiff; nothing structural depends on it being listed.
		if StateSupport.CombatBlocks(context, "Rolling") then
			return false, "InCombat"
		end
		if context.Now < cooldownUntil then
			return false, "RollCooldown"
		end
		if not InputBuffer.PeekRoll(context.Now) then
			return false, "NoRollInput"
		end
		local allowed = (ROLL.AllowedFromStates :: { [string]: boolean })[context.CurrentStateId]
		if not allowed then
			return false, "NotAllowedFromThisState"
		end
		-- The landing-roll case: airborne is legal, but only inside the window where contact is
		-- imminent. Rolling in open air is not a mechanic this system has.
		if not context.Ground.Grounded then
			if not context.Ground.NearGround then
				return false, "AirborneNotNearGround"
			end
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeRoll(context.Now)
		cooldownUntil = context.Now + ROLL.CooldownSeconds
		rollDirection = StateSupport.TravelDirection(context)
		entryMomentum = context.Momentum
		-- A landing roll cancels the fall's momentum cost outright: the severity is cleared before
		-- States/Landing.lua can ever apply it, which is exactly what "rolling out of a fall" means.
		-- Clearing FallHeight alongside it keeps the camera dip and shake from firing for a landing the
		-- player successfully avoided.
		context.LandingSeverity = nil
		context.FallHeight = 0
		context.Momentum = math.max(entryMomentum, ROLL.Speed)
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local motor = context.Motor
		local travel =
			ParkourMath.SafeUnit(ParkourMath.ProjectOnPlane(rollDirection, context.Ground.Normal), rollDirection)

		motor.Mode = "Velocity"
		motor.Velocity = travel * context.Momentum - Vector3.new(0, 8, 0)
		motor.CancelGravity = false
		motor.FaceDirection = travel
		-- Rolls duck under the same geometry slides do -- a roll that could not pass under something a
		-- slide can would make the two options inconsistent for no reason a player could infer.
		motor.HipHeightDelta = ParkourConstants.Slide.HipHeightDelta
		motor.DesiredSpeed = context.Momentum

		if context.StateElapsed < ROLL.DurationSeconds then
			return nil
		end
		-- Standing up into a ceiling is the one thing that extends a roll past its duration, same rule
		-- and same reason as the slide's.
		if not context.CeilingClear then
			return nil
		end
		if not context.Ground.Grounded then
			return "Falling"
		end
		return StateSupport.ResolveGroundedState(context)
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		context.Momentum = ParkourMath.ExitMomentum(context.Momentum, ROLL.ExitRetainFraction, 0)
		if nextState == "Vaulting" or nextState == "Mantling" then
			return
		end
		local travel = ParkourMath.SafeUnit(ParkourMath.Flatten(rollDirection), Vector3.zero)
		StateSupport.HandOff(
			context,
			travel * context.Momentum + Vector3.new(0, context.RootPart.AssemblyLinearVelocity.Y, 0)
		)
	end,
}

return Rolling
