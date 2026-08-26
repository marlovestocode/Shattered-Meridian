--!strict
--[[
	BlimpPilotPose.lua

	Owns: the mounted BODY's lean -- a spring-driven roll/pitch/sway written onto the root and neck
	joints of every character this client can see standing at a blimp station, so a helmsman visibly
	braces when the engines bite and leans into a turn instead of standing on the deck like furniture.

	THE COMPANION TO BlimpArmPose.lua, AND READ THAT FILE'S HEADER FIRST. Everything it says about why
	this cannot be an animation asset, why Motor6D.C0 is the wrong channel, why Motor6D.Transform is
	the right one, why it therefore has to run on every client rather than once on the server, and why
	the caller must drive it above Enum.RenderPriority.Character is true here word for word. This file
	is the same technique applied one joint further up the chain.

	IT IS PHYSICS-DRIVEN IN THE SAME SENSE THE CAMERA IS. The lean is not a clip, and there are no
	authored keyframes to drift out of sync with a retune: the targets are coefficients on the hull's
	OWN measured yaw rate, forward acceleration and climb rate -- the identical sample
	Client/Camera/BlimpCamera.lua reads off the assembly's replicated velocity, handed here rather than
	measured twice. A hull tuned to turn twice as hard produces twice the lean with nothing re-authored.
	It also means every client sees the same lean without a byte on the wire, because every client can
	see the same hull moving.

	THE TWO CHANNELS PULL IN OPPOSITE DIRECTIONS, WHICH IS THE ENTIRE EFFECT:
	  * ROLL leans INTO the turn. A helmsman's hands are on the wheel, so the ship rolls out from under
	    them and they go with it.
	  * PITCH leans AGAINST the acceleration. Nothing anchors them fore-and-aft, so when the engines
	    bite they are left behind and brace backward; when the ship brakes they pitch forward over the
	    wheel.
	Get either sign backwards and the body looks pushed by the animation rather than by the ship. This
	is the one thing to check first if it ever looks wrong.

	IT OVERWRITES THE IDLE CLIP'S TORSO RATHER THAN COMPOSING ONTO IT, unlike the obvious alternative of
	reading Transform back and multiplying. Composing works only while something else is writing that
	joint EVERY frame -- and whether a given idle animation keys the root joint at all is a property of
	an uploaded asset, not something this file can check. On a clip that does not key it, a compose
	multiplies the previous frame's own output over and over and winds the body up into a spin within
	seconds. An absolute write cannot do that under any clip. The cost is that a mounted body loses the
	idle's own breathing, which is the correct trade twice over: a person braced at a ship's wheel is
	not idling, and this pose is doing that job better anyway.

	THE ARMS ARE LEFT TO SOLVE THEMSELVES, deliberately, and BlimpArmPose needs no change to cope. Its
	solve re-reads the torso's CURRENT world CFrame every frame instead of caching a pose -- its own
	header calls that out as what makes an idle clip's shoulder sway a feature rather than a bug -- so a
	torso this file leaned lands the hands back on the grips for free. The arms trail the lean by
	exactly one frame, which at spring rates this slow is a fraction of a degree.

	Does not own: the hands (BlimpArmPose.lua), measuring the hull (Client/Camera/BlimpCamera.lua's
	sample, via Shared/Blimp/BlimpCameraMath.Observe), the coefficients (BlimpConstants.Lean), who is
	mounted (Server/Systems/BlimpSystem.lua), or the weld that holds the body there -- which is the
	server's authority over where a player IS, where this file only decides what they look like.
]]

local BlimpConstants = require(script.Parent.BlimpConstants)
local CharacterUtil = require(script.Parent.Parent.CharacterUtil)
local FlightMath = require(script.Parent.Parent.FlightMath)

local BlimpPilotPose = {}

-- Seconds. Same reasoning, and deliberately the same order of magnitude, as BlimpCameraMath's own
-- cap: a frame longer than this is a hitch, not motion.
local MAX_STEP_SECONDS = 0.2

-- One character's live lean. Two springs and a cached CFrame, allocated once per posed body and
-- mutated in place for the whole mount -- this runs per rendered frame for every mounted character on
-- screen, so a table per channel per frame is exactly the steady GC pressure to avoid.
export type State = {
	RollValue: number,
	RollVelocity: number,
	PitchValue: number,
	PitchVelocity: number,
	-- The composed root-joint lean, rebuilt each Step and read by Apply. Kept on the state rather than
	-- returned so Step allocates nothing and a caller cannot start doing so by accident.
	RootLean: CFrame,
	HeadLean: CFrame,
}

function BlimpPilotPose.NewState(): State
	return {
		RollValue = 0,
		RollVelocity = 0,
		PitchValue = 0,
		PitchVelocity = 0,
		RootLean = CFrame.identity,
		HeadLean = CFrame.identity,
	}
end

-- Advances both springs one frame and rebuilds the two lean CFrames, in place.
--
-- Pure in the sense that matters: it takes three plain numbers off a motion sample and touches no
-- Instance, so "does a starboard turn roll the body to starboard" and "does the lean settle back to
-- upright when the ship does" are answerable in the TestEZ suite without a rig.
function BlimpPilotPose.Step(
	state: State,
	yawRate: number,
	forwardAccel: number,
	climbRate: number,
	deltaTime: number
): ()
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
	if dt <= 0 then
		return
	end

	local cfg = BlimpConstants.Lean

	-- Negated for the same reason BlimpDrive negates its own yaw integration: a positive Steer axis is
	-- starboard, and Roblox rolls the starboard side DOWN on a negative rotation about the local Z.
	local rollTarget = math.clamp(-yawRate * cfg.RollRadiansPerYawRate, -cfg.MaxRollRadians, cfg.MaxRollRadians)
	state.RollValue, state.RollVelocity =
		FlightMath.SpringStep(state.RollValue, state.RollVelocity, rollTarget, cfg.Stiffness, cfg.Damping, dt)

	-- Surge and heave sum into ONE pitch target rather than each driving their own spring: they are two
	-- causes of one motion, and two springs on the same axis ring twice off a single throttle change.
	local pitchTarget = math.clamp(
		forwardAccel * cfg.PitchRadiansPerAccel + climbRate * cfg.PitchRadiansPerClimbRate,
		-cfg.MaxPitchRadians,
		cfg.MaxPitchRadians
	)
	state.PitchValue, state.PitchVelocity =
		FlightMath.SpringStep(state.PitchValue, state.PitchVelocity, pitchTarget, cfg.Stiffness, cfg.Damping, dt)

	-- Weight shifting between the feet -- derived from the roll that is already settled rather than
	-- from the raw yaw rate, so the sway can never lead the lean it is supposed to be a consequence of.
	local sway = (state.RollValue / math.max(cfg.MaxRollRadians, 1e-4)) * cfg.SwayStuds

	state.RootLean = CFrame.new(sway, 0, 0) * CFrame.Angles(state.PitchValue, 0, state.RollValue)
	-- The head counter-rotates a fraction of the way back toward level -- a person keeps their eyes on
	-- the horizon. Without it the whole rig pivots as one board, which reads as a prop tipping rather
	-- than a person leaning.
	state.HeadLean =
		CFrame.Angles(-state.PitchValue * cfg.HeadCounterFraction, 0, -state.RollValue * cfg.HeadCounterFraction)
end

-- Drives the lean toward upright without any motion input -- the release path, so a body whose mount
-- has ended (or whose hull has stopped being readable) straightens up over its own spring instead of
-- snapping. Callers hold the state for a few frames after a dismount for exactly this.
function BlimpPilotPose.Relax(state: State, deltaTime: number): ()
	BlimpPilotPose.Step(state, 0, 0, 0, deltaTime)
end

-- True once both springs have settled close enough to upright that the remaining lean is invisible --
-- the caller's signal that a relaxing state can be dropped. A threshold rather than an equality test
-- because a spring approaches zero asymptotically and never actually arrives.
function BlimpPilotPose.IsSettled(state: State): boolean
	return math.abs(state.RollValue) < 1e-3
		and math.abs(state.PitchValue) < 1e-3
		and math.abs(state.RollVelocity) < 1e-3
		and math.abs(state.PitchVelocity) < 1e-3
end

-- The R6 chain. Named first and checked first because this game's rigs are R6 -- despite what a
-- handful of source comments elsewhere still claim -- so this is the hot path, not the fallback.
local function resolveR6(character: Model): (Motor6D?, Motor6D?)
	local root = CharacterUtil.RootOf(character)
	local torso = character:FindFirstChild("Torso")
	if not root or not torso then
		return nil, nil
	end
	local rootJoint = root:FindFirstChild("RootJoint")
	local neck = torso:FindFirstChild("Neck")
	return (if rootJoint and rootJoint:IsA("Motor6D") then rootJoint else nil),
		(if neck and neck:IsA("Motor6D") then neck else nil)
end

-- The R15 chain. Kept for the same reason BlimpArmPose keeps its R6 branch in reverse: a player can
-- still arrive on the other rig, and a body that simply does not lean is a far better outcome than a
-- solver that indexes nil every frame for the whole mount.
local function resolveR15(character: Model): (Motor6D?, Motor6D?)
	local lowerTorso = character:FindFirstChild("LowerTorso")
	local head = character:FindFirstChild("Head")
	if not lowerTorso then
		return nil, nil
	end
	local rootJoint = lowerTorso:FindFirstChild("Root")
	local neck = head and head:FindFirstChild("Neck")
	return (if rootJoint and rootJoint:IsA("Motor6D") then rootJoint else nil),
		(if neck and neck:IsA("Motor6D") then neck else nil)
end

-- Writes the current lean onto `character`. Returns false for a rig this cannot pose, which the
-- caller uses to drop the entry rather than retry -- the same contract, for the same reason, as
-- BlimpArmPose.Apply: one unusual avatar must not cost every frame of everyone else's mount.
--
-- The neck is optional and its absence is not a failure. A rig with a root joint and no neck leans as
-- one piece, which looks slightly stiff; a rig with neither cannot be posed at all.
function BlimpPilotPose.Apply(character: Model, state: State): boolean
	local rootJoint, neck = resolveR6(character)
	if not rootJoint then
		rootJoint, neck = resolveR15(character)
	end
	if not rootJoint then
		return false
	end

	rootJoint.Transform = state.RootLean
	if neck then
		neck.Transform = state.HeadLean
	end
	return true
end

return BlimpPilotPose
