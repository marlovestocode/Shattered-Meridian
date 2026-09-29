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
	here is everything no single move could sensibly author: which physical part a victim attaches to,
	how hard the constraints that pin them there pull, how the impact sweep is tuned, and the one
	authoring default (AttachOffset) that is deliberately NOT exposed to an author at all -- see
	Defaults.AttachOffset's own comment.

	Does not own: per-move hold/throw numbers (the Move Editor, via MoveTypes.MoveGrabConfig), the
	hold/flight state machine itself (Server/Combat/Grab/GrabSystem.lua), or clamping a saved move
	(Limits below is what MoveRegistryManager.Validate reads, but the clamping itself stays its job).
]]

local GrabConstants = {}

-- Attachment -------------------------------------------------------------------------------------

-- Which BasePart on the attacker's rig a hold pins the victim to, tried in order. "RightHand" is the
-- R15 name; "Right Arm" is R6's. Neither existing is not an error -- resolveAttachPart falls back to
-- the attacker's own PrimaryPart (the same root every registration path in this combat stack already
-- requires), which still reads as "grabbed by the attacker" even without a literal fist to point at,
-- and covers a rig this list has never seen (a bot, a custom NPC skeleton).
GrabConstants.HandPartNames = { "RightHand", "Right Arm" }

-- Authoring defaults -------------------------------------------------------------------------------

GrabConstants.Defaults = {
	-- Root/hand-relative -- see MoveGrabConfig.AttachOffset's own header on why this is the ONE field
	-- of the sub-table an author never edits: MoveRegistryManager.Validate always writes this exact
	-- value onto a saved move regardless of what a client submits, the same "the server decides what
	-- the numbers mean" posture the move's own top-level Offset already takes, just total rather than
	-- partial here since there is no legitimate reason for two different Grab moves to pin a victim to
	-- two different points on the attacker's fist.
	--
	-- Slightly down and to the side of the resolved hand part, and a little in front of it -- a fist
	-- holding a collar, not a point floating in space.
	AttachOffset = CFrame.new(0, -0.5, -1),
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

-- AlignPosition/AlignOrientation tuning for the hold's own pin. Rigid enough that the victim reads as
-- genuinely CARRIED (not dragged on a spring) while still being a physics constraint rather than a
-- teleport -- a direct CFrame write would fight the victim's own (server-owned, see GrabSystem's own
-- header on SetNetworkOwner) physics simulation every frame instead of cooperating with it.
GrabConstants.Hold = {
	MaxForce = 100000,
	PositionResponsiveness = 60,
	MaxTorque = 100000,
	OrientationResponsiveness = 60,
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
