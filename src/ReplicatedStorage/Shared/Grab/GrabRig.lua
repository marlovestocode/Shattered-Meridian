--!strict
--[[
	GrabRig.lua

	Owns: the rig arithmetic of a hold -- which joints make up an arm, where every part of a rig sits at
	rest relative to its root, how to turn a shoulder so the hand points a given way, which part of a
	victim is gripped and at what point on it, and from all of that, the one Weld that puts the victim's
	gripped part ON the holder's hand.

	WHY THE VICTIM IS WELDED TO THE HAND, AND NOT NEAR IT. The previous hold welded the victim to the
	holder's ROOT and then moved the holder's arm toward them on each client. That only ever lined up
	when two sets of numbers happened to agree -- the victim placement (authored for an R6 body) and the
	arm's reach -- and they stopped agreeing the first time a rig was not R6: an R15 debug dummy, whose
	root sits at the hips rather than mid-torso, was placed a stud further out and ended up across the
	holder's shoulder. Welding the victim's torso or head to the hand PART makes "attached to the hand" a
	property of the assembly rather than of tuning: wherever that hand is, on any machine, the grip is.

	THE ARM IS POSED THROUGH THE SHOULDER'S C0, ON THE SERVER. That is the one joint value that replicates,
	so the server, every client and the physics owner all compute the same hand position -- and therefore
	the same victim position (the server's matters: it is what hit detection and the throw start from).
	Shared/Vessel/VesselArmPose.lua's header explains why C0 is wrong for a pose that must BREATHE with an
	idle clip; this one must not, which is why Client/FX/GrabHoldPose.lua pins the same arm's Transform to
	identity every frame on top of it. GrabSystem restores the original C0 when the hold ends.

	THE TIP CORRECTION is VesselArmPose's: an R6 hand is half a stud off its shoulder joint's axis, so the
	aim is rotated by that fixed angle to land the tip, not the joint's axis, along Arm. Both are read from
	the rig (C1 and the hand part's size), never authored.

	Pure: no state, no services, no authority. Server/Combat/Grab/GrabSystem.lua applies what Solve
	returns; the client pose calls ArmChain to know which joints to pin.
]]

local GrabConstants = require(script.Parent.GrabConstants)

local GrabRig = {}

export type Side = "Left" | "Right"

-- The joints of one arm: the shoulder (the one Solve poses), every joint from the shoulder to the hand
-- (the ones the client pins), and the hand part itself (what the victim is welded to).
export type ArmChain = {
	Shoulder: Motor6D,
	Joints: { Motor6D },
	Hand: BasePart,
}

-- What GrabSystem applies: a Weld's four fields, plus the shoulder C0 to write now and restore later
-- (nil when the rig had no arm this module understands and the weld fell back to root-to-root).
export type Solution = {
	Part0: BasePart,
	Part1: BasePart,
	C0: CFrame,
	C1: CFrame,
	Shoulder: Motor6D?,
	ShoulderC0: CFrame?,
	OriginalShoulderC0: CFrame?,
}

local EPSILON = 1e-3

local function motorIn(parent: Instance?, name: string): Motor6D?
	local child = if parent then parent:FindFirstChild(name) else nil
	return if child and child:IsA("Motor6D") then child else nil
end

local function partIn(model: Model, name: string): BasePart?
	local child = model:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

-- One arm's chain on an R6 rig ("Right Shoulder" on the Torso, one bone) or an R15 one (shoulder, elbow
-- and wrist). nil for anything else.
function GrabRig.ArmChain(model: Model, side: Side): ArmChain?
	local r6Shoulder = motorIn(model:FindFirstChild("Torso"), side .. " Shoulder")
	if r6Shoulder then
		local arm = r6Shoulder.Part1
		if arm then
			return { Shoulder = r6Shoulder, Joints = { r6Shoulder }, Hand = arm }
		end
		return nil
	end

	local shoulder = motorIn(model:FindFirstChild(side .. "UpperArm"), side .. "Shoulder")
	local hand = partIn(model, side .. "Hand")
	if not shoulder or not hand then
		return nil
	end
	local joints = { shoulder }
	local elbow = motorIn(model:FindFirstChild(side .. "LowerArm"), side .. "Elbow")
	if elbow then
		table.insert(joints, elbow)
	end
	local wrist = motorIn(hand, side .. "Wrist")
	if wrist then
		table.insert(joints, wrist)
	end
	return { Shoulder = shoulder, Joints = joints, Hand = hand }
end

-- Every joint that decides where `side`'s hand is relative to `root`: the arm (ArmChain.Joints) AND the
-- torso chain it hangs from (R6 RootJoint; R15 Waist then Root). Pinning only the arm is not enough --
-- every run and walk cycle animates the torso (bob, lean, twist), and a pinned arm on a moving torso
-- still carries the hand, and the body welded to it, through the whole stride. Pin all of these to
-- identity and the hand is exactly where GrabRig.Solve put it, relative to the root, whatever the legs
-- are doing. nil for a rig with no arm this module reads.
function GrabRig.HoldJoints(model: Model, root: BasePart, side: Side): { Motor6D }?
	local chain = GrabRig.ArmChain(model, side)
	if not chain then
		return nil
	end
	local joints = table.clone(chain.Joints)

	local motors: { Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			table.insert(motors, descendant)
		end
	end

	-- Walk from the part the shoulder hangs off back to the root, one parent joint at a time. Bounded,
	-- because a malformed rig with a joint cycle must cost a few iterations, not a hang.
	local current = chain.Shoulder.Part0
	for _ = 1, 8 do
		if current == nil or current == root then
			break
		end
		local parentJoint: Motor6D? = nil
		for _, motor in motors do
			if motor.Part1 == current then
				parentJoint = motor
				break
			end
		end
		if not parentJoint then
			break
		end
		table.insert(joints, parentJoint)
		current = parentJoint.Part0
	end
	return joints
end

-- Every part's CFrame in `root`'s space with every joint at rest (Transform ignored), found by walking
-- the rig's own joints out from the root: Part1 = Part0 * C0 * C1:Inverse(). Only joints whose two parts
-- are both in `model` count -- a hold's own GrabWeld reaches into another rig and must not be followed.
-- A rig is ~20 joints, so the repeated pass is cheaper than building an adjacency map.
function GrabRig.RestInRoot(model: Model, root: BasePart): { [BasePart]: CFrame }
	local joints: { JointInstance } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("JointInstance") then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 and part0:IsDescendantOf(model) and part1:IsDescendantOf(model) then
				table.insert(joints, descendant)
			end
		end
	end

	local rest: { [BasePart]: CFrame } = { [root] = CFrame.identity }
	local progressed = true
	while progressed do
		progressed = false
		for _, joint in joints do
			local part0 = joint.Part0 :: BasePart
			local part1 = joint.Part1 :: BasePart
			local rest0, rest1 = rest[part0], rest[part1]
			if rest0 and not rest1 then
				rest[part1] = rest0 * joint.C0 * joint.C1:Inverse()
				progressed = true
			elseif rest1 and not rest0 then
				rest[part0] = rest1 * joint.C1 * joint.C0:Inverse()
				progressed = true
			end
		end
	end
	return rest
end

-- The grip end of a hand part: the centre of its bottom face (an R6 arm's hand end, an R15 hand's
-- fingertips), in that part's own space.
local function handTipLocal(hand: BasePart): Vector3
	return Vector3.new(0, -hand.Size.Y * 0.5, 0)
end

-- The shoulder C0 that points `chain`'s hand tip along `direction` (a unit vector in root space) with
-- every joint otherwise at rest. See this file's header on the tip correction.
local function shoulderC0Toward(chain: ArmChain, rest: { [BasePart]: CFrame }, direction: Vector3): CFrame?
	local shoulder = chain.Shoulder
	local torso = shoulder.Part0
	local torsoRest = if torso then rest[torso] else nil
	local handRest = rest[chain.Hand]
	if not torsoRest or not handRest then
		return nil
	end

	local jointFrame = torsoRest * shoulder.C0
	local tip = jointFrame:PointToObjectSpace(handRest * handTipLocal(chain.Hand))
	-- The tip's angle off the joint's -Y axis, within the plane the arm swings in.
	local tipAngle = math.atan2(tip.Z, -tip.Y)

	local bend = direction:Cross(torsoRest.UpVector)
	if bend.Magnitude < EPSILON then
		bend = direction:Cross(torsoRest.LookVector)
	end
	if bend.Magnitude < EPSILON then
		return nil
	end
	bend = bend.Unit

	local aim = CFrame.fromAxisAngle(bend, tipAngle):VectorToWorldSpace(direction)
	-- The joint frame whose -Y runs down the (tip-corrected) arm -- VesselArmPose's limbFrame.
	local limb = CFrame.fromMatrix(jointFrame.Position, bend, -aim)
	return torsoRest:Inverse() * limb
end

-- The part of a victim that is gripped, or nil for a rig without one.
function GrabRig.GripPart(model: Model, gripPart: GrabConstants.GripPart): BasePart?
	if gripPart == "Head" then
		return partIn(model, "Head")
	end
	return partIn(model, "Torso") or partIn(model, "UpperTorso")
end

-- Where on `part` the hand closes, in the part's own space -- from its size, so it is the same point on
-- any rig's torso or head.
function GrabRig.GripLocal(part: BasePart, at: GrabConstants.GripAt): Vector3
	local half = part.Size * 0.5
	if at == "Face" then
		return Vector3.new(0, 0, -half.Z)
	elseif at == "Crown" then
		return Vector3.new(0, half.Y, 0)
	end
	return Vector3.new(0, half.Y, -half.Z)
end

-- The whole hold, solved from the two rigs as they are. Never fails: a rig this module cannot read
-- falls back side by side to root-to-root at R6 numbers (GrabConstants.Hold's Fallback* values).
function GrabRig.Solve(
	attacker: Model,
	attackerRoot: BasePart,
	victim: Model,
	victimRoot: BasePart,
	mode: GrabConstants.ModeSpec
): Solution
	local hold = GrabConstants.Hold

	-- Holder side: the hand part and where it is (root space) once the arm is posed.
	local part0: BasePart = attackerRoot
	local part0InRoot = CFrame.identity
	local tipInRoot = hold.FallbackShoulder + mode.Arm * hold.FallbackReach
	local shoulder: Motor6D? = nil
	local posedC0: CFrame? = nil
	local originalC0: CFrame? = nil

	local chain = GrabRig.ArmChain(attacker, "Right")
	if chain then
		local newC0 = shoulderC0Toward(chain, GrabRig.RestInRoot(attacker, attackerRoot), mode.Arm)
		if newC0 then
			-- Written to find the posed hand, then put back: applying it is GrabSystem's call, not a side
			-- effect of solving.
			local original = chain.Shoulder.C0
			chain.Shoulder.C0 = newC0
			local handPosed = GrabRig.RestInRoot(attacker, attackerRoot)[chain.Hand]
			chain.Shoulder.C0 = original
			if handPosed then
				part0 = chain.Hand
				part0InRoot = handPosed
				tipInRoot = handPosed * handTipLocal(chain.Hand)
				shoulder = chain.Shoulder
				posedC0 = newC0
				originalC0 = original
			end
		end
	end

	-- Victim side: the gripped part and the point on it.
	local part1: BasePart = victimRoot
	local gripLocal = hold.FallbackGrips[mode.GripAt] or hold.FallbackGrips.Collar
	local gripPart = GrabRig.GripPart(victim, mode.GripPart)
	if gripPart then
		part1 = gripPart
		gripLocal = GrabRig.GripLocal(gripPart, mode.GripAt)
	end

	-- Part1 = Part0 * C0 * C1:Inverse(). C0 puts the grip frame at the hand tip, turned by Body (both
	-- expressed from root space into the hand's own); C1 is the grip point on the victim's part, so that
	-- point -- not the part's centre -- is what lands on the tip.
	return {
		Part0 = part0,
		Part1 = part1,
		C0 = part0InRoot:Inverse() * (CFrame.new(tipInRoot) * mode.Body),
		C1 = CFrame.new(gripLocal),
		Shoulder = shoulder,
		ShoulderC0 = posedC0,
		OriginalShoulderC0 = originalC0,
	}
end

return GrabRig
