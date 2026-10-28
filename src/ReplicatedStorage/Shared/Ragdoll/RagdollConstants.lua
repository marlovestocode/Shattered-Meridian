--!strict
--[[
	RagdollConstants.lua

	Owns: every ragdoll number that is NOT per move -- the rig (joint cones, colliders, friction ranges), how
	often a limp body is polled and what counts as at rest, the get-up, the anti-lock rules, the safety caps,
	and the death ragdoll. The per-move numbers are the move's own Ragdoll block (Shared/Ragdoll/RagdollTypes).

	READ LIVE, SNAPSHOTTED PER RAGDOLL. Server/Combat/Ragdoll/RagdollSystem reads this table when a ragdoll
	BEGINS and keeps what it needs on that body's record, so a tune in Studio applies to the next ragdoll without
	a restart and a ragdoll in progress never changes shape under itself. Nothing here is read per frame.

	Replaces CombatConstants.Ragdoll (deleted 2026-10-27): those numbers belonged to the deleted
	RagdollController and had no reader. The proven ones were carried over -- socket friction 15, the 0
	elasticity weighting idea (now the move's Bounce), the 0.35 s blend, the 5 degree end angle, the 250 studs/s
	containment cap -- and the rest went with the controller.
]]

local RagdollConstants = {
	-- The whole system. Off: no move ragdolls and no death ragdolls; DamageSystem resolves every hit exactly
	-- as it did before the system existed.
	Enabled = true,

	Rig = {
		-- Each limb gets an invisible collider this fraction of its size, welded to it: R6 limbs do not collide
		-- on their own (the Humanoid manages their CanCollide), and a ragdoll whose arms and legs fall through
		-- the floor reads as a torso on stilts. A shade smaller than the limb so a resting limb never visibly
		-- floats on its collider.
		ColliderScale = 0.9,
		-- Per joint class: the rest direction of the limb from its socket (in the LIMB's own space), the cone
		-- the limb may swing within around it, and the twist about it, in degrees. A joint is classed by its
		-- Motor6D's name; a joint no class names takes Default.
		Joints = {
			Neck = { Axis = Vector3.yAxis, UpperAngle = 50, TwistLower = -55, TwistUpper = 55 },
			Shoulder = { Axis = -Vector3.yAxis, UpperAngle = 115, TwistLower = -80, TwistUpper = 80 },
			Hip = { Axis = -Vector3.yAxis, UpperAngle = 75, TwistLower = -35, TwistUpper = 35 },
			Default = { Axis = -Vector3.yAxis, UpperAngle = 60, TwistLower = -40, TwistUpper = 40 },
		},
		-- Stiffness (the move's 0..1) narrows every cone and twist toward this fraction of its class angle...
		StiffAngleScale = 0.4,
		-- ...and raises socket friction from the first number to the second. 15 was the old controller's tuned
		-- middle: enough that a limb bleeds its energy and comes to rest instead of flailing forever.
		FrictionTorque = { Limp = 6, Stiff = 45 },
		-- Weighting of the limbs' own Elasticity against whatever they land on. Far above any material's default
		-- (1), so the move's Bounce wins the combine whatever the floor is.
		ElasticityWeight = 100,
		FrictionWeight = 100,
	},

	-- THE POLL. A limp body is checked for "at rest" this many times a second, not every frame, and only once
	-- its DurationSeconds is spent -- before that nothing about rest is asked. Each body's checks are offset so
	-- a crowd ragdolled on one frame does not all poll on the same later frame.
	Settle = {
		PollHz = 8,
		-- The torso's speed (studs/s) and spin (rad/s) at or below which the body counts as at rest.
		LinearSpeed = 2,
		AngularSpeed = 3,
		-- Consecutive at-rest polls before it gets up -- one quiet sample mid-bounce is not rest.
		StableSamples = 2,
	},

	Recovery = {
		-- What every joint's cone and twist tighten TO across the get-up, degrees. Not zero: a hard zero makes
		-- the solver fight float error on the last step.
		FinalAngleDegrees = 5,
		-- How hard the get-up rights the body: the drive's Responsiveness is this divided by GetUpSeconds, so a
		-- quicker get-up is a firmer one and every length arrives at about the same point of its curve.
		ResponsivenessPerSecond = 9,
		-- How far down the get-up looks for the floor to stand the body on.
		GroundProbeStuds = 14,
		-- An ANCHORED body (a training dummy) is returned to where it stood once it is up, rather than left
		-- re-anchored wherever it landed -- a test bench whose dummies wander off is not a test bench.
		ReturnAnchoredHome = true,
	},

	Rules = {
		-- A ragdolling hit on a body that is already limp refreshes it: re-thrown, its clock restarted. A juggle.
		RefreshWhileRagdolled = true,
		-- ...but no body is held limp longer than this from its FIRST fall, however many hits keep landing. Past
		-- it, hits land as ordinary hits until the body is up. The anti-infinite.
		MaxChainSeconds = 5,
		-- Once up, a body cannot be ragdolled again for this long: it gets to act before it can be put down.
		ImmunitySeconds = 1,
		-- MovementGuard's allowance after the get-up (MovementAllowance.Stamp): the client takes its body back
		-- wherever the server left it, and its first frames of motion are not judged.
		AllowanceAfterSeconds = 0.75,
	},

	Limits = {
		-- Containment, not feel: no composed throw exceeds these, whatever a move authors.
		MaxLinearSpeed = 250,
		MaxAngularSpeed = 45,
	},

	-- A LETHAL hit from a move with no Ragdoll block still puts the corpse down physically, with this spec,
	-- instead of the engine's joint break. A move's own block always wins (an Execution preset).
	Death = {
		Enabled = true,
		Spec = {
			Trigger = "Lethal",
			DurationSeconds = 2,
			MaxSeconds = 2,
			RecoverOnSettle = false,
			KnockbackScale = 1,
			Push = 30,
			Lift = 12,
			Tumble = 5,
			Twist = 0,
			Stiffness = 0.2,
			Bounce = 0.05,
			Friction = 0.8,
			GravityScale = 1.1,
			GetUpSeconds = 0.4,
		},
	},
}

return RagdollConstants
