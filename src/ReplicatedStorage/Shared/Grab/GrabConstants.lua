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
	here is everything no single move could sensibly author: where on the attacker a held victim sits,
	how the held body is kept out of the physics solver's way, how the flight's landing/impact checks
	are tuned, and the one authoring default (AttachOffset) that is deliberately NOT exposed to an
	author at all -- see Defaults.AttachOffset's own comment.

	Does not own: per-move hold/throw numbers (the Move Editor, via MoveTypes.MoveGrabConfig), the
	hold/flight state machine itself (Server/Combat/Grab/GrabSystem.lua), or clamping a saved move
	(Limits below is what MoveRegistryManager.Validate reads, but the clamping itself stays its job).
]]

local GrabConstants = {}

-- Hold modes -------------------------------------------------------------------------------------

-- How a held body is carried. One entry per GrabTypes.GrabMode; a move picks one in the Move Editor
-- (MoveGrabConfig.Mode) and EVERYTHING the mode means is here, so a new way of holding someone is a new
-- entry, not new code:
--
--   Hand         Where the holder's right hand closes, in the HOLDER'S root space. Client/FX/
--                GrabHoldPose.lua solves the arm onto it; an R6 arm reaches ~1.58 studs from its shoulder
--                joint at (1, 0.5, 0), so a Hand much past ~1.75 from there visibly stops short.
--   Grip         The point of the VICTIM it closes on, in the victim's root space (an R6 torso's top face
--                is y = +1 and its front face z = -0.5; the head's centre is y = +1.5).
--   Body         How the victim's body is turned, in the holder's root space.
--   Placement    Derived, never authored: the weld's C0 that puts Grip exactly on Hand with Body's turn.
--                This, not a hand-tuned offset, is what MoveRegistryManager.Validate writes as a saved
--                move's AttachOffset, so re-tuning a mode here re-places every move that uses it.
--   VictimHands  Where the victim's own hands go (victim root space) when no VictimAnimation is
--                authored: a little way up the holder's forearm, clawing at the grip.
--   ThrowAway    Throw along the line from holder to victim instead of the holder's facing. A dragged
--                body is BEHIND the holder, and throwing it "forward" would launch it through them.
--
-- Every number below was solved against R6 part sizes rather than eyeballed (hand within reach, zero
-- overlap between the two bodies' parts, a dragged body's lowest point ~0.1 studs above the floor).
-- Re-check those three if you move one; the held body collides with nothing, so a bad number clips
-- rather than flings, and it is only visible in play.
export type ModeSpec = {
	Label: string,
	Hand: Vector3,
	Grip: Vector3,
	Body: CFrame,
	Placement: CFrame,
	VictimHands: { Left: Vector3, Right: Vector3 },
	ThrowAway: boolean,
}

local FACING_HOLDER = CFrame.Angles(0, math.pi, 0)

-- On its back, head toward the holder, the upper body raised `degrees` off the floor by the grip.
local function onBackRaised(degrees: number): CFrame
	return CFrame.Angles(math.rad(degrees - 90), 0, 0) * FACING_HOLDER
end

local function mode(spec: {
	Label: string,
	Hand: Vector3,
	Grip: Vector3,
	Body: CFrame,
	VictimHands: { Left: Vector3, Right: Vector3 },
	ThrowAway: boolean,
}): ModeSpec
	return {
		Label = spec.Label,
		Hand = spec.Hand,
		Grip = spec.Grip,
		Body = spec.Body,
		Placement = CFrame.new(spec.Hand) * spec.Body * CFrame.new(-spec.Grip),
		VictimHands = spec.VictimHands,
		ThrowAway = spec.ThrowAway,
	}
end

GrabConstants.Modes = {
	-- Lifted off the floor by the collar, facing the holder, level with their right shoulder. Feet 0.6
	-- studs up, ~0.7 studs between the two chests.
	Collar = mode({
		Label = "Lift by the collar",
		Hand = Vector3.new(1.5, 1.6, -1.2),
		Grip = Vector3.new(0, 1, -0.5),
		Body = FACING_HOLDER,
		VictimHands = { Left = Vector3.new(-0.15, 0.78, -0.74), Right = Vector3.new(0.45, 0.56, -0.98) },
		ThrowAway = false,
	}),
	-- Hoisted by the face, the arm raised higher; the victim hangs with their toes 0.4 studs up.
	Head = mode({
		Label = "Lift by the head",
		Hand = Vector3.new(1.4, 1.9, -0.9),
		Grip = Vector3.new(0, 1.5, -0.5),
		Body = FACING_HOLDER,
		VictimHands = { Left = Vector3.new(-0.17, 1.22, -0.68), Right = Vector3.new(0.41, 0.94, -0.86) },
		ThrowAway = false,
	}),
	-- Dragged along the floor behind and to the right by the collar: on their back, head toward the
	-- holder, the arm swung low and back. The body is raised 21 degrees from the floor at the grip.
	Drag = mode({
		Label = "Drag by the collar",
		Hand = Vector3.new(2.03, -0.62, 0.86),
		Grip = Vector3.new(0, 1, -0.4),
		Body = onBackRaised(21),
		VictimHands = { Left = Vector3.new(-0.04, 1.24, -0.55), Right = Vector3.new(0.66, 1.48, -0.69) },
		ThrowAway = true,
	}),
	-- Dragged straight behind by the top of the head, arm hanging down and back; the body trails
	-- further out than a collar drag (the head is between hand and shoulders) at 16 degrees.
	HeadDrag = mode({
		Label = "Drag by the head",
		Hand = Vector3.new(1.0, -1.04, 0.72),
		Grip = Vector3.new(0, 2, 0),
		Body = onBackRaised(16),
		VictimHands = { Left = Vector3.new(-0.25, 2.11, -0.13), Right = Vector3.new(0.25, 2.25, -0.26) },
		ThrowAway = true,
	}),
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
	-- Where the victim's root sits, in the ATTACKER'S ROOT space -- the weld's C0 (GrabSystem.beginHold).
	-- Always the default mode's Placement: see MoveGrabConfig.AttachOffset's own header on why this is
	-- never authored. MoveRegistryManager.Validate writes the CHOSEN mode's Placement, not this; this is
	-- the value for a config that has no mode to choose by.
	--
	-- Root-relative, NOT hand-relative, on purpose. It used to hang off the RightHand part, and that is
	-- half of why a grab flung people: the hand's pose on the server is whatever the grab SWING left it
	-- in, so the same offset put the victim somewhere different on every grab -- usually with their
	-- torso inside the attacker's arm. The root is the one frame on a rig that is upright, animation-
	-- free and identical on every client, so the victim lands in the same place every time, and
	-- Client/FX/GrabHoldPose.lua then brings the HAND to the body instead.
	AttachOffset = GrabConstants.Modes.Collar.Placement,
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
	-- the flight), plus three Attributes: on the holder, the grip point in the holder's root space
	-- (Vector3); on the victim, the mode's name, and whether an authored VictimAnimation owns their arms.
	-- Tags and Attributes replicate for free, which is all Client/FX/GrabHoldPose.lua needs to pose every
	-- hold on every client with no remote -- the same seam GuardStrainPose reads
	-- DefenseConstants.GuardCrack.Tag through.
	HolderTag = "GrabHolding",
	HeldTag = "GrabHeldBody",
	GripAttribute = "GrabGrip",
	ModeAttribute = "GrabMode",
	VictimAnimatedAttribute = "GrabVictimAnimated",
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
	-- (Where the victim's hands go is per mode -- Modes[...].VictimHands.)
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
