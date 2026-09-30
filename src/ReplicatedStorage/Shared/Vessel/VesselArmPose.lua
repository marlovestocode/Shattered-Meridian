--!strict
--[[
	VesselArmPose.lua

	Owns: putting a mounted character's HANDS ON THE THING -- a two-bone IK solve per arm that lands each
	hand on a grip point of the station part, every frame, for as long as the mount lasts.

	LIFTED OUT OF Shared/Blimp/BlimpArmPose.lua when the Boat layer arrived. A hand on a ship's wheel and
	a hand on a blimp's wheel are the same solve against the same rig, and the only thing that was ever
	blimp-specific was which Attachment names it looked for and which tuning table it read.

	WHY THIS IS CLIENT-SIDE PRESENTATION AND NOT A SERVER WRITE, which is the single most important thing
	about this file. There are three ways to pose an arm in Roblox and only one of them works here:

	  * An animation asset. The obvious answer, and the one to switch to the day somebody authors a real
	    "hands on the wheel" clip -- but it is blocked on an upload, it cannot adapt to a helm of a size
	    the animator did not have in front of them, and this codebase already has a standing lesson about
	    authored numbers drifting from real assets. Not available today.
	  * Motor6D.C0. Replicates from the server, so one write would reach every client -- but C0 is the
	    joint's REST offset, and the Animate script's idle clip composes on top of it via Transform. The
	    arms would sit on the wheel and then breathe off it.
	  * Motor6D.Transform, written per-frame, per-client. Transform is exactly what an AnimationTrack
	    writes, so writing it AFTER the animation step is what beats the idle clip rather than fighting
	    it -- and Transform does NOT replicate, which is precisely why this runs on every client rather
	    than once on the server. <- what this file does.

	The consequence to keep in mind when reading any vehicle's System: the mount remote is broadcast to
	ALL clients, not fired at the mounting player, because the pose is everyone else's view of that
	player, not their own. A payload sent only to the two interested parties would produce a pilot whose
	arms are on the wheel on their own screen and hanging at their sides on everybody else's.

	TIMING IS NOT NEGOTIABLE. The caller must drive Apply from RunService:BindToRenderStep at a priority
	ABOVE Enum.RenderPriority.Character (each vehicle's client controller does). Heartbeat is too early --
	the character/animation update has not run yet, so the clip overwrites this solve on the same frame,
	and the arms flicker between the two poses at whatever beat the two rates happen to alias into.

	THE SOLVE re-reads the torso's CURRENT world CFrame every frame rather than caching a pose. That is
	what makes an idle clip's shoulder sway a feature instead of a bug: the body drifts, and the hands
	stay welded to the grip because the solve chases them there again. It also means this is correct for
	free on a hull that is banking, on a rig that has been scaled by a HumanoidDescription, and on a
	station part a builder resized after the fact -- no authored offsets to drift out of date.

	Does not own: WHERE the grips are in the general case (the builder does, via the LeftGrip/RightGrip
	Attachments in each vehicle's Constants.Attachments -- ResolveGrips only supplies the fallback for a
	station that has none), who is mounted (that vehicle's System), or the body weld itself
	(Server/Vessel/VesselMount.lua, server-side, and deliberately: a weld is authority over where a
	player is, and this file only decides what their arms look like).
]]

local VesselArmPose = {}

-- What one vehicle layer binds this to -- its two grip Attachment names plus its Pose tuning.
export type Config = {
	LeftGrip: string,
	RightGrip: string,
	-- Fallback grip half-separation, in studs, when a station part carries no grip Attachments.
	FallbackGripHalfWidth: number,
	-- ...clamped by this, so a very wide railing does not splay the arms into a crucifixion pose.
	FallbackGripMaxHalfWidth: number,
	-- Which way the elbows break. 1 puts the elbow behind the arm plane (the natural reach-forward pose).
	ElbowPoleSign: number,
	-- Fraction of full arm extension the solver will reach before it stops reaching and simply points.
	MaxReachFraction: number,
}

-- Which limb we are solving. Every rig lookup below is this string spliced into a name, which is what
-- keeps the R15 branch a single code path instead of two mirrored ones.
export type Side = "Left" | "Right"

export type Poser = {
	ResolveGrips: (station: BasePart) -> (CFrame, CFrame),
	Apply: (character: Model, station: BasePart) -> boolean,
	ApplyHand: (character: Model, side: Side, target: Vector3) -> boolean,
}

-- Guard for the degenerate cases the law of cosines cannot answer: a target sitting exactly on the
-- shoulder, or an arm/target arrangement that has collapsed to a point. Small enough to be invisible,
-- large enough to keep every division below away from zero.
local EPSILON = 1e-3

-- The R15 chain, per side. Named parts rather than a joint walk because R15's names are a fixed contract
-- (Players:CreateHumanoidModelFromDescription builds exactly these, as DebugDummySystem.lua relies on)
-- and a generic walk would buy nothing but a way to silently pose the wrong limb on a custom rig.
local function resolveR15Chain(character: Model, side: Side): (Motor6D?, Motor6D?, Motor6D?)
	local upperArm = character:FindFirstChild(side .. "UpperArm")
	local lowerArm = character:FindFirstChild(side .. "LowerArm")
	local hand = character:FindFirstChild(side .. "Hand")
	if not upperArm or not lowerArm or not hand then
		return nil, nil, nil
	end

	local shoulder = upperArm:FindFirstChild(side .. "Shoulder")
	local elbow = lowerArm:FindFirstChild(side .. "Elbow")
	local wrist = hand:FindFirstChild(side .. "Wrist")
	if not shoulder or not shoulder:IsA("Motor6D") then
		return nil, nil, nil
	end
	if not elbow or not elbow:IsA("Motor6D") then
		return nil, nil, nil
	end
	return shoulder, elbow, (if wrist and wrist:IsA("Motor6D") then wrist else nil)
end

-- The R6 chain: one joint, no elbow. R6 is what this game's rigs actually are, so this is not the
-- fallback it reads as -- but the R15 branch above still has to exist, because a player can arrive on
-- one and a solver that errors on a nil elbow every frame for the whole mount is worse than arms that
-- simply hang.
local function resolveR6Shoulder(character: Model, side: Side): Motor6D?
	local torso = character:FindFirstChild("Torso")
	if not torso then
		return nil
	end
	local shoulder = torso:FindFirstChild(side .. " Shoulder")
	if shoulder and shoulder:IsA("Motor6D") then
		return shoulder
	end
	return nil
end

-- The world CFrame of a joint at its current pose: where Transform = identity would put it. Every solve
-- below is expressed as "what Transform turns THIS into the frame I want", which is the whole reason the
-- file never has to know a single authored offset.
local function restJointWorld(motor: Motor6D): CFrame?
	local part0 = motor.Part0
	if not part0 then
		return nil
	end
	return part0.CFrame * motor.C0
end

-- A limb's joint frame, built so its NEGATIVE Y axis runs down the limb -- the orientation an R15 arm
-- joint has at rest (its C1 carries no rotation). R15 ONLY: an R6 shoulder's C1 is a quarter turn, and a
-- frame built this way rolls an R6 arm ninety degrees about its length -- the R6 path uses SwingToward.
--
-- `bendAxis` is the axis the whole arm plane pivots about; passing it in rather than deriving it here is
-- what guarantees the upper and lower segments share one plane, which is what an elbow is.
local function limbFrame(origin: Vector3, alongLimb: Vector3, bendAxis: Vector3): CFrame
	return CFrame.fromMatrix(origin, bendAxis, -alongLimb)
end

-- The axis the arm plane bends about: perpendicular to both the reach direction and the torso's own up.
-- Deriving it from the TORSO rather than from world up is what keeps the elbow breaking the same way when
-- the hull banks -- world up would swing the elbow around the arm as the deck rolled.
local function resolveBendAxis(torsoCFrame: CFrame, reachDirection: Vector3): Vector3
	local axis = reachDirection:Cross(torsoCFrame.UpVector)
	if axis.Magnitude < EPSILON then
		-- Reaching straight up or straight down: the up vector gives no plane, so fall back to the
		-- torso's own facing, which always does.
		axis = reachDirection:Cross(torsoCFrame.LookVector)
	end
	if axis.Magnitude < EPSILON then
		return Vector3.new(1, 0, 0)
	end
	return axis.Unit
end

-- The joint frame that points a one-bone limb's TIP along `direction` (world space), by swinging the
-- joint's REST frame about the joint -- the smallest rotation that takes the rest tip direction onto
-- `direction`. `restJoint` is the joint's world frame with Transform = identity; `tipInJoint` is the
-- limb's far end in that frame (C1:Inverse() applied to the tip point in the limb part's own space).
--
-- WHY A SWING AND NOT limbFrame. limbFrame builds the joint frame from scratch with -Y down the limb,
-- which is right for R15 (C1 carries no rotation, the limb hangs straight off its joint). An R6
-- shoulder's C1 is a QUARTER TURN about Y with the joint at the arm's inner top corner, so a frame
-- built that way rolls the whole arm ninety degrees about its own length: the hand still lands where
-- it was aimed, but the arm's box swings out of line with the shoulder -- "my arm is offset from my
-- shoulder at an unhuman angle". Swinging the rest frame keeps the arm's roll as its rig authored it,
-- keeps the pivot in the socket, and puts the tip -- not the joint's axis, which on R6 is 18 degrees
-- off it -- exactly on the line, in closed form.
function VesselArmPose.SwingToward(restJoint: CFrame, tipInJoint: Vector3, direction: Vector3): CFrame
	local pivot = restJoint.Position
	local restOffset = restJoint:VectorToWorldSpace(tipInJoint)
	if restOffset.Magnitude < EPSILON or direction.Magnitude < EPSILON then
		return restJoint
	end
	local from = restOffset.Unit
	local to = direction.Unit
	local axis = from:Cross(to)
	local swing: CFrame
	if axis.Magnitude < EPSILON then
		if from:Dot(to) > 0 then
			return restJoint
		end
		-- Exactly opposite: any axis perpendicular to the limb does; the joint's own X is one.
		swing = CFrame.fromAxisAngle(restJoint.XVector, math.pi)
	else
		swing = CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(from:Dot(to), -1, 1)))
	end
	return CFrame.new(pivot) * swing * restJoint.Rotation
end

-- One vehicle layer's bound solver. See this file's header; the config is bound once here so the
-- per-frame call sites pass nothing but a character and a station.
function VesselArmPose.New(config: Config): Poser
	-- Two-bone IK. Returns the two joint frames (shoulder, elbow) that put the end of the chain on
	-- `target`, or as close to it as the arm can reach.
	--
	-- Reaching PAST the target is impossible and reaching short of it is common (a grip a builder placed
	-- a little far from where a body can stand), so an unreachable target is answered by pointing the
	-- whole arm at it at MaxReachFraction extension -- never by refusing to pose, which would drop the
	-- arm mid-mount, and never by fully straightening it, which reads as a mannequin rather than a
	-- person holding on.
	local function solveTwoBone(
		shoulderPos: Vector3,
		target: Vector3,
		upperLength: number,
		lowerLength: number,
		bendAxis: Vector3,
		poleSign: number
	): (CFrame, CFrame)
		local toTarget = target - shoulderPos
		local distance = toTarget.Magnitude
		local direction = if distance > EPSILON then toTarget / distance else Vector3.new(0, -1, 0)

		local maxReach = (upperLength + lowerLength) * config.MaxReachFraction
		local minReach = math.abs(upperLength - lowerLength) + EPSILON
		distance = math.clamp(distance, minReach, math.max(maxReach, minReach + EPSILON))

		-- Law of cosines: the angle between the shoulder-to-target line and the upper arm.
		local cosShoulder = (upperLength * upperLength + distance * distance - lowerLength * lowerLength)
			/ (2 * upperLength * distance)
		local shoulderAngle = math.acos(math.clamp(cosShoulder, -1, 1))

		local upperDirection = CFrame.fromAxisAngle(bendAxis, shoulderAngle * poleSign):VectorToWorldSpace(direction)
		local elbowPos = shoulderPos + upperDirection * upperLength

		local reachedTarget = shoulderPos + direction * distance
		local toWrist = reachedTarget - elbowPos
		local lowerDirection = if toWrist.Magnitude > EPSILON then toWrist.Unit else upperDirection

		return limbFrame(shoulderPos, upperDirection, bendAxis), limbFrame(elbowPos, lowerDirection, bendAxis)
	end

	local function poseR15Arm(character: Model, side: Side, target: Vector3): boolean
		local shoulder, elbow, wrist = resolveR15Chain(character, side)
		if not shoulder or not elbow then
			return false
		end

		local shoulderRest = restJointWorld(shoulder)
		local elbowRest = restJointWorld(elbow)
		if not shoulderRest or not elbowRest then
			return false
		end

		-- Bone lengths measured from the CURRENT pose. Rotation cannot change a distance between two
		-- joints, so this is exact whatever the animation is doing -- and it is what makes the solve
		-- correct for a rig scaled by a HumanoidDescription without a single authored number.
		local upperLength = (elbowRest.Position - shoulderRest.Position).Magnitude
		local wristRest = if wrist then restJointWorld(wrist) else nil
		local lowerLength = if wristRest then (wristRest.Position - elbowRest.Position).Magnitude else upperLength
		if upperLength < EPSILON or lowerLength < EPSILON then
			return false
		end

		local torso = shoulder.Part0
		if not torso then
			return false
		end

		local reach = target - shoulderRest.Position
		local bendAxis =
			resolveBendAxis(torso.CFrame, if reach.Magnitude > EPSILON then reach.Unit else torso.CFrame.LookVector)

		-- Mirrored, so both elbows break outward-and-back rather than both breaking the same way in world
		-- space (which is what makes one arm look broken).
		local poleSign = config.ElbowPoleSign * (if side == "Left" then -1 else 1)

		local upperFrame, lowerFrame =
			solveTwoBone(shoulderRest.Position, target, upperLength, lowerLength, bendAxis, poleSign)

		shoulder.Transform = shoulderRest:Inverse() * upperFrame

		-- The elbow's rest frame has to be recomputed from where the upper arm is ABOUT to be, not where
		-- it is: the shoulder Transform written a line above does not take effect until the next
		-- animation step, so reading elbow.Part0.CFrame here would solve the forearm against last frame's
		-- upper arm and leave the hand permanently one frame behind the grip.
		local predictedUpperArm = upperFrame * shoulder.C1:Inverse()
		elbow.Transform = (predictedUpperArm * elbow.C0):Inverse() * lowerFrame

		if wrist then
			-- Neutralised rather than left alone: an untouched wrist keeps whatever the idle clip is
			-- writing, which is a hand rotating on a stationary forearm. Identity simply carries the
			-- forearm's own orientation into the hand, which is what a hand gripping something does.
			wrist.Transform = CFrame.identity
		end

		return true
	end

	local function poseR6Arm(character: Model, side: Side, target: Vector3): boolean
		local shoulder = resolveR6Shoulder(character, side)
		if not shoulder then
			return false
		end
		local shoulderRest = restJointWorld(shoulder)
		local torso = shoulder.Part0
		if not shoulderRest or not torso then
			return false
		end

		local arm = shoulder.Part1
		local reach = target - shoulderRest.Position
		if not arm or reach.Magnitude < EPSILON then
			return false
		end

		-- One bone: swing it at the grip. No elbow to solve, so no law of cosines -- see this file's
		-- header on why the other rig gets a reduced pose rather than no pose. See SwingToward on why
		-- this is a swing of the rest pose and not a frame built with limbFrame.
		local tip = shoulder.C1:Inverse() * Vector3.new(0, -arm.Size.Y * 0.5, 0)
		shoulder.Transform = shoulderRest:Inverse() * VesselArmPose.SwingToward(shoulderRest, tip, reach.Unit)
		return true
	end

	local poser = {}

	-- Where the two hands go, as world CFrames. Prefers the builder's own grip Attachments and falls
	-- back to a symmetric pair straddling the station part's centre along its widest horizontal axis --
	-- correct for a railing, approximate for a detailed wheel, which is exactly the case where a builder
	-- should add the Attachments (each vehicle's authoring contract says so too).
	--
	-- Both Attachments are required for either to be used. Honouring one and deriving the other would
	-- put one hand where the builder asked and the other wherever the bounding box happened to land,
	-- which looks more broken than a symmetric guess and is much harder to diagnose from a screenshot.
	function poser.ResolveGrips(station: BasePart): (CFrame, CFrame)
		local left = station:FindFirstChild(config.LeftGrip)
		local right = station:FindFirstChild(config.RightGrip)
		if left and left:IsA("Attachment") and right and right:IsA("Attachment") then
			return left.WorldCFrame, right.WorldCFrame
		end

		local stationCFrame = station.CFrame
		local size = station.Size
		local useX = size.X >= size.Z
		local axis = if useX then stationCFrame.RightVector else stationCFrame.LookVector
		local halfExtent = (if useX then size.X else size.Z) * 0.5

		local half = math.min(config.FallbackGripHalfWidth, config.FallbackGripMaxHalfWidth, halfExtent)

		local centre = stationCFrame.Position
		return stationCFrame.Rotation + (centre - axis * half), stationCFrame.Rotation + (centre + axis * half)
	end

	-- Poses both arms onto `station` for this frame. Returns whether anything was actually written --
	-- false means the rig had no arms this solver understands, which the caller uses to stop retrying a
	-- character it can never pose rather than paying for the lookups every frame of the mount.
	--
	-- Safe to call on a character mid-teardown: every lookup above is a FindFirstChild that answers nil,
	-- and nil is a `return false`, not an error.
	function poser.Apply(character: Model, station: BasePart): boolean
		local leftGrip, rightGrip = poser.ResolveGrips(station)
		local posedRight = poser.ApplyHand(character, "Right", rightGrip.Position)
		local posedLeft = poser.ApplyHand(character, "Left", leftGrip.Position)
		return posedRight or posedLeft
	end

	-- One hand onto one world point, for this frame -- the half of Apply that knows nothing about a
	-- station. Public because a grip is not always a pair of Attachments on a part: GrabHoldPose
	-- (Client/FX) puts an attacker's right hand on a held victim's collar with exactly this solve. Same
	-- return contract and same timing requirement as Apply.
	function poser.ApplyHand(character: Model, side: Side, target: Vector3): boolean
		if character:FindFirstChild("RightUpperArm") then
			return poseR15Arm(character, side, target)
		end
		return poseR6Arm(character, side, target)
	end

	return poser
end

return VesselArmPose
