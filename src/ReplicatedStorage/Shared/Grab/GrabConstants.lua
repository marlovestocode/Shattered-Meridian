--!strict
--[[
	GrabConstants.lua

	Owns: the Grab layer's tunables. Standalone, and deliberately NOT a section of Shared/Constants.lua
	-- the same choice AttackConstants.lua/DamageConstants.lua/DefenseConstants.lua all make, and for
	the same reason: this system is a module, and a module that can be dropped in or pulled out without
	editing the game's central constants table is the concrete form of that.

	THERE IS NO PER-MOVE NUMBER IN THIS FILE, same as its siblings. HoldSeconds/ThrowUpVelocity/
	ThrowHorizontalVelocity/ThrowImpactDamage/ThrowSelfDamage are all authored PER MOVE in the Move
	Creation System (MoveTypes.MoveGrabConfig) and reach GrabSystem through DamageResult.Grab. What IS
	here is everything no single move could sensibly author: what each hold MODE means (a move picks a
	mode by name; the arm direction and gripped body part behind it live here), how the held body is kept
	out of the physics solver's way, and how the flight's landing/impact checks are tuned.

	Does not own: per-move hold/throw numbers (the Move Editor, via MoveTypes.MoveGrabConfig), the
	hold/flight state machine itself (Server/Combat/Grab/GrabSystem.lua), or clamping a saved move
	(Limits below is what MoveRegistryManager.Validate reads, but the clamping itself stays its job).
]]

local GrabConstants = {}

-- Hold modes -------------------------------------------------------------------------------------

-- How a held body is carried. One entry per GrabTypes.GrabMode; a move picks one in the Move Editor
-- (MoveGrabConfig.Mode) and everything the mode means is here, so a new way of holding someone is a new
-- entry, not new code.
--
-- A MODE NAMES BODY PARTS, NOT COORDINATES. The victim's GripPart (their torso or head) is welded
-- straight to the holder's right HAND part (Shared/Grab/GrabRig.lua), at a point found from that part's
-- own size, and the holder's arm is posed to point along Arm. Nothing here assumes a rig's proportions:
-- the first version of modes placed the body with R6 offsets from the root, and an R15 debug dummy (whose
-- root sits at the hips, not mid-torso) ended up wedged against the holder's shoulder.
--
--   Arm         Which way the holder's right arm points, in the HOLDER'S root space (normalised below).
--               The hand is wherever that puts it -- the victim is attached to the hand, so the two
--               cannot disagree.
--   GripPart    "Torso" (R6 Torso / R15 UpperTorso) or "Head" -- the victim part welded to the hand.
--   GripAt      Where on that part the hand closes: "Collar" (top of its front face), "Face" (centre of
--               its front face), "Crown" (centre of its top face).
--   Body        How the victim's body is turned, in the holder's root space.
--   ThrowAway   Throw along the line from holder to victim instead of the holder's facing. A dragged
--               body is BEHIND the holder, and throwing it "forward" would launch it through them.
--
-- The Arm/Body pairs were solved against R6 part sizes (hand at the R6 arm's true 1.58-stud reach, zero
-- overlap between the two bodies, a dragged body's lowest point ~0.1 studs above the floor), not
-- eyeballed. The held body collides with nothing, so a bad number clips rather than flings -- it is
-- only visible in play.
export type GripPart = "Torso" | "Head"
export type GripAt = "Collar" | "Face" | "Crown"
export type ModeSpec = {
	Label: string,
	Arm: Vector3,
	GripPart: GripPart,
	GripAt: GripAt,
	Body: CFrame,
	ThrowAway: boolean,
}

local FACING_HOLDER = CFrame.Angles(0, math.pi, 0)

-- On its back, head toward the holder, the upper body raised `degrees` off the floor by the grip.
local function onBackRaised(degrees: number): CFrame
	return CFrame.Angles(math.rad(degrees - 90), 0, 0) * FACING_HOLDER
end

GrabConstants.Modes = {
	-- Lifted off the floor by the collar, facing the holder, arm raised forward and up. R6 feet ~0.5 up.
	Collar = {
		Label = "Lift by the collar",
		Arm = Vector3.new(0.294, 0.646, -0.705).Unit,
		GripPart = "Torso",
		GripAt = "Collar",
		Body = FACING_HOLDER,
		ThrowAway = false,
	},
	-- Hoisted by the face, the arm raised higher; the victim hangs with their toes just off the floor.
	Head = {
		Label = "Lift by the head",
		Arm = Vector3.new(0.234, 0.818, -0.526).Unit,
		GripPart = "Head",
		GripAt = "Face",
		Body = FACING_HOLDER,
		ThrowAway = false,
	},
	-- Dragged along the floor behind and to the right by the collar: on their back, head toward the
	-- holder, the arm swung down, out and back, the upper body raised 25 degrees by the grip.
	Drag = {
		Label = "Drag by the collar",
		Arm = Vector3.new(0.639, -0.5, 0.585).Unit,
		GripPart = "Torso",
		GripAt = "Collar",
		Body = onBackRaised(25),
		ThrowAway = true,
	},
	-- Dragged straight behind by the top of the head, arm hanging down and back, body raised 16 degrees.
	HeadDrag = {
		Label = "Drag by the head",
		Arm = Vector3.new(0, -0.906, 0.424).Unit,
		GripPart = "Head",
		GripAt = "Crown",
		Body = onBackRaised(16),
		ThrowAway = true,
	},
} :: { [string]: ModeSpec }

-- Dropdown order in the Move Editor, and the answer for a config that names no mode.
GrabConstants.ModeOrder = { "Collar", "Head", "Drag", "HeadDrag" }
GrabConstants.DefaultMode = "Collar"

-- The mode a config holds with -- its own, or DefaultMode for one saved before modes existed (and, as a
-- backstop, for a name that is not in the table: Validate refuses those, so only a hand-built config
-- can carry one).
function GrabConstants.ModeOf(modeName: string?): ModeSpec
	return GrabConstants.Modes[modeName or GrabConstants.DefaultMode] or GrabConstants.Modes[GrabConstants.DefaultMode]
end

-- Authoring defaults -------------------------------------------------------------------------------

GrabConstants.Defaults = {
	Mode = "Collar",
	HoldSeconds = 3,
	ThrowUpVelocity = 20,
	ThrowHorizontalVelocity = 55,
	ThrowImpactDamage = 15,
	ThrowSelfDamage = 10,
}

-- Clamp bounds for MoveRegistryManager's validateGrab, in Constants.MoveEditor.Limits' {Min, Max}
-- shape -- one place the Move Editor's Grab fields (ImpactTab) and the server's clamp agree on a range.
GrabConstants.Limits = {
	HoldSeconds = { Min = 0.5, Max = 15 },
	ThrowUpVelocity = { Min = 0, Max = 150 },
	ThrowHorizontalVelocity = { Min = 0, Max = 150 },
	ThrowImpactDamage = { Min = 0, Max = 200 },
	ThrowSelfDamage = { Min = 0, Max = 200 },
}

-- Hold physics -------------------------------------------------------------------------------------

-- A HOLD IS A WELD, NOT A CONSTRAINT PAIR. See GrabSystem.lua's header, THE HOLD, for the full account
-- of why the old AlignPosition/AlignOrientation spring flung people. What is here is the two things a
-- weld needs so the held body is carried rather than fought over.
GrabConstants.Hold = {
	-- Every BasePart of a held victim is moved into this group for the hold, and the group collides
	-- with NOTHING (GrabSystem registers it and turns off every pairing it can see at that moment). A
	-- held body is part of the attacker's assembly, so any contact it makes -- an attacker's own arm, a
	-- wall they walk the victim into, a bystander -- is a contact the attacker's Humanoid feels as a
	-- shove. Restored part by part to whatever group each part had before, on throw or release.
	CollisionGroup = "GrabHeld",
	-- Studs kept between a released/thrown body and any wall found between the attacker and it. A held
	-- body collides with nothing, so an attacker who backs the victim into a wall has it partly INSIDE
	-- that wall at the moment of release; switching collision back on there resolves as an
	-- intersection, which is a fling. GrabSystem pulls the body back toward the attacker by the wall's
	-- distance minus this first.
	WallClearanceStuds = 1.5,
	-- CollectionService tags GrabSystem puts on the two Models for exactly the length of a hold (not
	-- the flight), plus three Attributes: on the holder, which arm is holding (Client/FX/GrabHoldPose.lua
	-- pins that arm's joints so no animation swings the victim around); on the victim, the mode's name,
	-- and whether an authored VictimAnimation owns their arms. Tags and Attributes replicate for free, so
	-- the pose needs no remote -- the same seam GuardStrainPose reads DefenseConstants.GuardCrack.Tag
	-- through.
	HolderTag = "GrabHolding",
	HeldTag = "GrabHeldBody",
	ArmAttribute = "GrabArm",
	ModeAttribute = "GrabMode",
	VictimAnimatedAttribute = "GrabVictimAnimated",
	-- The name of the hold's Weld, parented to the victim's gripped part. The pose finds the holder's
	-- hand through it (Weld.Part0) to put the victim's own hands on it.
	WeldName = "GrabWeld",
	-- For a rig with no arm or no torso/head this module recognises (a bare test rig, an odd NPC): the
	-- weld falls back to root-to-root, placing the grip where an R6 hand and R6 part would put it.
	FallbackShoulder = Vector3.new(1, 0.5, 0),
	FallbackReach = 1.58,
	FallbackGrips = {
		Collar = Vector3.new(0, 1, -0.5),
		Face = Vector3.new(0, 1.5, -0.5),
		Crown = Vector3.new(0, 2, 0),
	} :: { [string]: Vector3 },
}

-- Hold animations (MoveGrabConfig.VictimAnimation / AttackerAnimation) ---------------------------------

-- Played by GrabSystem through Shared/Animation/AnimationManager.lua on a manager of its own per body,
-- for the length of the hold. Action4 is the top of Roblox's priority ladder, so the hold clip wins
-- over the Animate script and every client-side combat layer on the same rig without having to know
-- about any of them. Looped: a hold has no fixed length (it ends on a Throw or HoldSeconds), so a
-- one-shot would run out partway through.
GrabConstants.Animation = {
	Layer = "Grab",
	Priority = Enum.AnimationPriority.Action4,
	FadeInSeconds = 0.12,
	FadeOutSeconds = 0.15,
}

-- Hold pose (Client/FX/GrabHoldPose.lua) --------------------------------------------------------------

GrabConstants.Pose = {
	-- Fraction of full arm extension the IK will reach on an R15 rig before it stops reaching and
	-- points (Shared/Vessel/VesselArmPose.lua's MaxReachFraction). R6 has no elbow and always points.
	MaxReachFraction = 0.97,
	-- Which way an R15 elbow breaks -- 1 is behind the arm plane, the natural reach-forward pose.
	ElbowPoleSign = 1,
	-- Where the victim's own hands go when no VictimAnimation is authored: on either side of the holder's
	-- hand part, this fraction of its length up from the grip end, and this far off its surface --
	-- clawing at the wrist that has them. Relative to the holder's hand, so it is right in every mode.
	VictimHandAlongArm = 0.3,
	VictimHandClearance = 0.15,
}

-- Flight / impact ------------------------------------------------------------------------------------

GrabConstants.Impact = {
	-- Absolute ceiling on how long a thrown body may stay in flight before GrabSystem forces a landing
	-- regardless of what its own sweep found -- the same "bounded worst case" reasoning
	-- HitboxEngineConstants.MaxSwingSeconds already applies to a stuck swing. A throw that somehow never
	-- clips geometry (an authored ThrowUpVelocity/HorizontalVelocity pair that clears every ledge on a
	-- given map) must still return control eventually.
	MaxFlightSeconds = 6,
	-- Radius of the per-frame overlap check GrabSystem's own sweep runs at the thrown body's current
	-- position, looking for another registered combatant to apply ThrowImpactDamage to. Roughly a
	-- character's own width -- generous enough that a near-miss still counts as a collision, tight
	-- enough that a throw arcing past a crowd does not tag everyone in the room.
	CollisionRadiusStuds = 4,
	-- Extra probe distance added to the ray this sweep casts between last frame's position and this
	-- frame's, so a landing registers on the frame it happens rather than one frame after the physics
	-- solver has already arrested the body and erased the evidence.
	GroundProbeExtraStuds = 2,
	-- How far below the thrown body's root a DESCENDING body looks for a floor. A standing R6 or R15
	-- root sits three studs above its feet, so this is "the feet are about to touch": the swept ray
	-- above only ever sees what is AHEAD of the body, and a throw that skims in low and flat along the
	-- ground has nothing ahead of it -- it used to fall back on Humanoid.FloorMaterial, which a
	-- PlatformStanding body does not keep current.
	FootProbeStuds = 3.25,
	-- No landing check at all for this long after the throw, so a throw from a low hold cannot "land"
	-- on the floor it was thrown off before it has left it. Short enough to be invisible: the default
	-- ThrowUpVelocity is still rising when it ends.
	MinFlightSeconds = 0.1,
	-- A body moving slower than this for StallSeconds straight has come to rest somewhere neither probe
	-- recognises as a floor (wedged on a ledge, caught on a railing) -- land it there rather than leave
	-- the victim locked out of their own character until MaxFlightSeconds. Held for a window, not a
	-- single frame, because a straight-up throw passes through zero speed at its apex.
	StallSpeed = 2,
	StallSeconds = 0.25,
}

-- Network ---------------------------------------------------------------------------------------

GrabConstants.Network = {
	RemoteNames = {
		-- Client -> server, the follow-up "throw them" input. No payload -- see GrabTypes.lua's own
		-- header on why a grab request carries nothing but the press itself.
		Throw = "Grab_Throw",
		-- Server -> both participants, on every hold starting/ending.
		HoldChanged = "Grab_HoldChanged",
	},
	-- Sized against AttackConstants.Network.MaxCallsPerSecondPerPlayer (10) as the established order of
	-- magnitude for a combat input remote -- a Throw press is refused for free (an unbounded
	-- OnServerEvent dispatch plus a Character read) if a client fires it faster than any legitimate
	-- input device could, which was otherwise the one gameplay remote in this codebase with no limiter.
	MaxThrowsPerSecondPerPlayer = 10,
}

-- Debug -----------------------------------------------------------------------------------------

GrabConstants.Debug = {
	Enabled = false,
	LogHoldStarted = true,
	LogHoldReleased = true,
	LogThrowLanded = true,
	LogRefused = true,
}

return GrabConstants
