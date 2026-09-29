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

-- Authoring defaults -------------------------------------------------------------------------------

GrabConstants.Defaults = {
	-- Where the victim's root sits, in the ATTACKER'S ROOT space -- the weld's C0 (GrabSystem.beginHold).
	-- See MoveGrabConfig.AttachOffset's own header on why this is the ONE field of the sub-table an
	-- author never edits: MoveRegistryManager.Validate always writes this exact value onto a saved move
	-- regardless of what a client submits (and ToWire never sends one), so changing it here re-places
	-- every grab move at once, persisted ones included.
	--
	-- Root-relative, NOT hand-relative, on purpose. It used to hang off the RightHand part, and that is
	-- half of why a grab flung people: the hand's pose on the server is whatever the grab SWING left it
	-- in, so the same offset put the victim somewhere different on every grab -- usually with their
	-- torso inside the attacker's arm. The root is the one frame on a rig that is upright, animation-
	-- free and identical on every client, so the victim lands in the same place every time.
	--
	-- Out in front at the right hand's reach and lifted half a stud (feet off the floor -- held up by the
	-- collar, not standing), turned to FACE the attacker. Three studs forward leaves a clear two-stud gap
	-- between the two torsos, so nothing overlaps even before the collision group below takes effect.
	AttachOffset = CFrame.new(0.5, 0.5, -3) * CFrame.Angles(0, math.pi, 0),
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
