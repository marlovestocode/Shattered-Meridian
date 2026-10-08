--!strict
--[[
	States/Evading.lua

	Owns: the combat evade -- a short, committed GLIDE along the ground on the DASH key (Q / gamepad B),
	which is the combat dash's ground half: Q in the air is States/Dashing.lua's air dash, Q on the ground
	in combat is this, and Q on the ground out of combat does nothing. (The old Evade key, Z / gamepad Y,
	still buffers the same evade.) The body keeps its facing, never crouches and never tumbles; it slides
	out of the way on a flash-step speed curve (Shared/Combat/EvadeMotion.lua) and stops.

	THE DIRECTION IS THE HELD KEY. Hold a movement key and the glide goes that way (camera-relative, so
	"hold left and press Q" goes left of the camera); hold nothing and it goes straight back from facing.

	ONE MOVE, NO VARIANTS. This replaced States/Rolling.lua, which was two moves on one key -- a traversal
	tumble and a combat snap-step -- chosen between by whether the InCombat Attribute had already arrived.
	On the first dodge of most fights it had not, so the player rolled into the floor while the training
	bot, which never had a traversal branch, glided. The glide itself never branches on InCombat or shift
	lock, so there is nothing to pick wrong. The landing roll, the slide roll-out and the ceiling crawl went
	with the roll, deliberately (docs/design/air-combat-and-evade.md, A2).

	COMBAT ONLY (user call, 2026-09-28). CanEnter refuses the evade outright unless the InCombat Attribute is
	set -- it is not a traversal tool. The cost is deliberate: the tag only lands on the first contact of a
	fight (EngagementSystem), so the opening swing of an exchange cannot be evaded, only blocked or parried.

	THE SERVER DECIDES WHETHER IT WAS AN EVADE. This state reports "Evade"; ParkourSystem's accepted report
	opens evade frames on DefenseSystem (EvadeConstants.Frames, wired in Main.server.lua), and a swing
	landing inside them resolves "Evaded". Nothing here knows that.

	FACING IS HELD at the value it had on the press. A dodge that turned its back on the opponent would hand
	them a backstab bearing (OutcomeResolver) the instant the frames closed.

	Committed: once started it runs its length. Most of an evade's value is that it is reliable. The one
	thing that ends it early is a hit -- ParkourController's generic interrupt rule ends any body-owning
	state an external impulse lands on, so there is no bespoke knockback handling here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)
local EvadeMotion = require(ReplicatedStorage.Shared.Combat.EvadeMotion)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

-- Per-evade scratch, module-level for the same singleton reason every state here uses (see
-- States/Sliding.lua's own note).
local travelDirection = Vector3.zero
local heldFacing = Vector3.new(0, 0, -1)
-- When the evade may next start. Local to this file because Evading.CanEnter is the only route in: the
-- evade has no route-1 entries (the slide roll-out and the landing roll were cut with the roll), so there
-- is no second asker that would need to see it.
local cooldownUntil = 0

local function flatFacing(context: ParkourContext): Vector3
	return ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.new(0, 0, -1))
end

-- Which way the glide goes: HELD INPUT first (camera-relative, so "hold left and evade" goes left of the
-- camera), else straight BACK from facing -- the direction a player pressing evade with no input means,
-- away from whatever they are looking at.
local function directionFor(context: ParkourContext, facing: Vector3): Vector3
	if StateSupport.HasMoveIntent(context) then
		return ParkourMath.SafeUnit(ParkourMath.Flatten(context.MoveIntent), -facing)
	end
	return -facing
end

-- One frame of glide at `speed`: HORIZONTAL PLANE ONLY, grounded or not, so the Humanoid's own floor
-- support keeps the body at standing height and gravity owns the fall off an edge.
--
-- NEVER A DOWNWARD SURFACE STICK. This used to command the full vector with -SurfaceStickSpeed on Y while
-- grounded, the way Sliding does. At the drive's 90000 MaxForce that beats the Humanoid's hip-height
-- support outright, and R6 legs do not collide, so the root was pushed down until the TORSO met the
-- floor: the body glided half-sunk into the ground. That is the "rolling into the ground" the evade was
-- built to remove, and it came back through the stick rather than through a crouch. A slide can afford
-- the stick because it is crouched on purpose; a standing glide cannot. The training bot never had it
-- (TrainingBotSystem writes horizontal velocity and keeps Y), which is why its evade always looked right.
local function drive(context: ParkourContext, speed: number): ()
	local motor = context.Motor
	motor.Mode = "Velocity"
	motor.CancelGravity = false
	motor.Velocity = travelDirection * speed
	motor.PlanarOnly = true
	motor.FaceDirection = heldFacing
	motor.HipHeightDelta = 0
	motor.DesiredSpeed = speed
end

local Evading: ParkourTypes.StateDefinition = {
	Id = "Evading",
	Priority = 140,
	Drive = "Velocity",
	Probes = { Ground = true },
	Reports = "Evade",
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- No evading out of your own swing or out of a stun. The server refuses the evade frames for the same
		-- two conditions (DefenseSystem.BeginEvade), so a client that skipped this would glide and still be
		-- hit; this is the client declining to send an evade the server will not honour.
		if context.CombatCommitted == true then
			return false, "CombatCommitted"
		end
		-- COMBAT ONLY. The evade is a fighting move, not traversal: outside an engagement (the InCombat
		-- Attribute EngagementSystem publishes) the key does nothing. The server applies the same rule
		-- before opening evade frames (Main.server.lua), so a client that skipped this only glides.
		if context.InCombat ~= true then
			return false, "NotInCombat"
		end
		if context.Now < cooldownUntil then
			return false, "EvadeCooldown"
		end
		-- Either key's press: the Evade key's, or the Dash key's (Q), which on the ground is the evade.
		if not InputBuffer.PeekEvadeOrDash(context.Now) then
			return false, "NoEvadeInput"
		end
		if not EvadeConstants.AllowedFromStates[context.CurrentStateId] then
			return false, "NotAllowedFromThisState"
		end
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeEvadeOrDash(context.Now)
		cooldownUntil = context.Now + EvadeConstants.CooldownSeconds
		heldFacing = flatFacing(context)
		travelDirection = directionFor(context, heldFacing)
		context.Momentum = EvadeConstants.PeakSpeed
		context.AnimationVariant = EvadeMotion.DirectionalVariant(travelDirection, heldFacing)
		-- An evade out of a landing leaves the fall behind it: no dip or shake is owed for a landing the
		-- player has already moved on from.
		context.LandingSeverity = nil
		context.FallHeight = 0
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local elapsed = context.StateElapsed
		if elapsed < EvadeConstants.DurationSeconds then
			local speed = EvadeMotion.SpeedAt(elapsed)
			context.Momentum = speed
			drive(context, speed)
			return nil
		end
		if not context.Ground.Grounded then
			return "Falling"
		end
		return StateSupport.ResolveGroundedState(context)
	end,

	Exit = function(context: ParkourContext): ()
		context.AnimationVariant = nil
		-- The glide eased itself to rest, so it hands back nothing of its own: walking pace along held input
		-- when a direction is held (so an evade does not end in a dead stop the player did not ask for),
		-- otherwise nothing. Vertical velocity is carried through untouched -- an evade that ran off an edge
		-- keeps falling.
		local verticalSpeed = context.RootPart.AssemblyLinearVelocity.Y
		if StateSupport.HasMoveIntent(context) then
			local walk = ParkourConstants.Locomotion.WalkSpeed
			local direction = ParkourMath.SafeUnit(ParkourMath.Flatten(context.MoveIntent), travelDirection)
			context.Momentum = walk
			StateSupport.HandOff(context, direction * walk + Vector3.new(0, verticalSpeed, 0))
		else
			context.Momentum = 0
			StateSupport.HandOff(context, Vector3.new(0, verticalSpeed, 0))
		end
	end,
}

return Evading
