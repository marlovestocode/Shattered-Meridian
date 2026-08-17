--!strict
--[[
	States/AerialCombat.lua

	Owns: doing nothing, correctly, while the combat layer owns the body.

	This is the state the framework parks in whenever CombatSystem, RagdollController, the Emote
	System, admin flight or an admin freeze has taken control of the character -- signalled by the
	Humanoid Attributes those systems already publish and resolved into ParkourContext.CombatOwned by
	ParkourController.

	It is a real state rather than "the framework switches itself off" for three reasons, all of which
	are about the system being observable and predictable rather than about behavior:
	  1. The debug overlay shows a state at all times. "AerialCombat" is a far better answer to "why
	     isn't my movement responding" than a blank readout.
	  2. Entering it runs the normal Exit path of whatever was active, so a wall-run's constraints, a
	     vault's rigid position drive and a slide's crouch are all released through the same code that
	     releases them normally -- rather than through a separate emergency teardown that would
	     inevitably drift out of sync with the states it is tearing down.
	  3. Leaving it goes through the normal transition machinery, so the character resumes into
	     whichever state genuinely fits (Falling if they are in the air after being juggled, Idle if
	     they were put down) rather than into whatever they were doing before combat interrupted.

	The design asked for this explicitly: "the parkour system should recognize when a player is in an
	aerial combat state instead of trying to force them back onto normal ground movement." Forcing
	ground movement onto a player being juggled would fight RagdollController's AlignPosition hold for
	every frame both were active -- the exact failure mode Client/DevMenu/FlightController.lua's own
	RootControlLocked gate was added to fix for flight.

	Highest priority in the framework by a wide margin (1000): nothing may pre-empt combat ownership.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local AerialCombat: ParkourTypes.StateDefinition = {
	Id = "AerialCombat",
	Priority = 1000,
	Drive = "Humanoid",
	-- Ground only, and only so the exit can tell whether the character was put down or is still in the
	-- air. Probing for vault targets while ragdolled would be pure waste.
	Probes = { Ground = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not context.CombatOwned then
			return false, "CombatNotOwningBody"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		-- Momentum is dropped rather than preserved. Whatever speed the character had before being
		-- launched, hit or frozen is no longer theirs, and resuming a sprint's worth of momentum the
		-- instant a ragdoll releases would let a knockdown end in a free burst of speed.
		context.Momentum = 0
		context.AnimationVariant = nil
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		-- Explicitly hands the body to Roblox's own character controller every frame. Not a no-op:
		-- ParkourMotor.BeginFrame already defaults to this, but stating it means a future edit to that
		-- default cannot silently start driving a ragdolled character.
		context.Motor.Mode = "Humanoid"
		context.Motor.DesiredSpeed = 0

		if context.CombatOwned then
			return nil
		end
		if not context.Ground.Grounded then
			return "Falling"
		end
		return StateSupport.ResolveGroundedState(context)
	end,

	Exit = function(context: ParkourContext): ()
		-- Chain counters and fall bookkeeping reset on the way out: a fall that began before a juggle
		-- is not a fall the player should be charged for on landing, and the wall-run/wall-jump chains
		-- have no meaning across a combat interruption.
		context.ApexHeight = context.RootPart.Position.Y
		context.FallHeight = 0
		context.LandingSeverity = nil
		context.WallRunChain = 0
		context.WallJumpChain = 0
	end,
}

return AerialCombat
