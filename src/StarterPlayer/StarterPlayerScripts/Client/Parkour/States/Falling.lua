--!strict
--[[
	States/Falling.lua

	Owns: being airborne and descending, apex tracking, and the classification of how hard the
	resulting landing is.

	APEX TRACKING is why fall severity is measured here rather than at the moment of contact. The
	naive version -- "height of the ground I left minus height of the ground I hit" -- is wrong for
	every interesting case: a wall-jump chain that climbs then falls, a vault off a roof, a fall that
	starts with an upward launch. Tracking the highest point reached since leaving the ground and
	measuring the drop from THERE gives the number a player would intuitively call "how far I fell,"
	which is the number the landing rules should key off.

	The severity decision is published on the context (LandingSeverity) rather than recomputed by each
	consumer, because three separate systems need the same answer -- States/Landing.lua's recovery
	window, the camera dip, and the shake preset -- and three independent classifications of the same
	fall is exactly how a landing ends up with a hard camera shake and a soft recovery.

	This state is also where a roll rescues a bad landing, and the rescue is decided HERE, on the contact
	frame, rather than by Rolling pre-empting on priority. A roll never starts in the air
	(StateSupport.CanRoll demands ground contact), so the only honest moment to ask "did they press roll
	in time" is the frame the ground arrives: a press within ParkourConstants.Roll.LandingWindowSeconds
	before it returns "Rolling" instead of "Landing", so the landing -- its momentum cut, its camera dip,
	its shake -- simply never happens. It used to be decided a frame EARLY instead, by letting Rolling
	enter while merely NearGround, which is how a roll came to start airborne and float.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local FALL = ParkourConstants.Fall

local Falling: ParkourTypes.StateDefinition = {
	Id = "Falling",
	Priority = 60,
	Drive = "Humanoid",
	-- Everything: a fall is the state with the most possible exits (ledge grab, wall-run off a
	-- passing surface, vault-into-mantle on contact, landing), and each of those needs its probe
	-- fresh at the moment the opportunity appears rather than up to a frame later.
	Probes = { Ground = true, Walls = true, Ledge = true, Obstacle = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if context.Ground.Grounded then
			return false, "Grounded"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		-- Seed the apex from wherever the fall began. Without this, a fall that starts at the top of a
		-- launch would measure its apex from the first FRAME of the fall rather than the launch point,
		-- under-reporting every fall that begins with upward motion.
		context.ApexHeight = math.max(context.ApexHeight, context.RootPart.Position.Y)
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		StateSupport.ApplyAirLocomotion(context)

		local currentHeight = context.RootPart.Position.Y
		if currentHeight > context.ApexHeight then
			context.ApexHeight = currentHeight
		end

		if not context.Ground.Grounded then
			return nil
		end

		-- Contact, with a roll pressed in time: roll out of the fall instead of landing it. A route-1
		-- transition, so it asks the same predicate Rolling.CanEnter does -- cooldown and combat
		-- commitment included -- under the roll's own landing window rather than the shared buffer. No
		-- severity is computed or published, which is what keeps the dip and the shake from firing
		-- (Rolling.Enter clears both again regardless).
		if StateSupport.CanRoll(context, ParkourConstants.Roll.LandingWindowSeconds) then
			return "Rolling"
		end

		-- Contact. Compute the drop from the apex, classify it, publish both, and hand off.
		local fallHeight = math.max(context.ApexHeight - currentHeight, 0)
		context.FallHeight = fallHeight
		context.LandingSeverity =
			ParkourMath.ClassifyLanding(fallHeight, FALL.SoftLandingHeight, FALL.MediumLandingHeight)
		return "Landing"
	end,

	Exit = function(context: ParkourContext): ()
		-- Reset the apex on the way out so the next airborne stretch starts fresh. Done in Exit rather
		-- than in the next state's Enter because every exit from Falling -- landing, ledge grab,
		-- wall-run, roll -- needs it, and putting it in one place is the only way it cannot be
		-- forgotten by whichever exit is added next.
		context.ApexHeight = context.RootPart.Position.Y
	end,
}

return Falling
