--!strict
--[[
	ParkourOwnership.lua

	Owns: the one definition of "a parkour action is driving this body right now", in both the forms
	the rest of the codebase needs to ask it -- off a Humanoid Attribute (what a server System can
	see) and off a live MovementStateId (what the local client can see). Pure predicates over data
	somebody else publishes; this module holds no state and drives nothing.

	IT EXISTS BECAUSE TWO COMBAT LAYERS HAVE TO AGREE. Server/Combat/Attack/AttackRequestSystem.lua
	refuses a throw and Server/Combat/Defense/DefenseSystem.lua refuses a guard on the same rule, and
	an inlined Attribute read in each is two copies of a gameplay rule that will drift the first time
	one of them is retuned -- the same "one system, two configs" failure Constants.Combat's own former
	Sprint* fields were. One predicate, two callers, one answer.

	THE TWO FORMS DO NOT COVER THE SAME SET, and pretending otherwise would be the bug this header
	exists to prevent:

	  * OwnsBody reads Constants.Attributes.ParkourVelocityOwned, which ParkourSystem raises only for
	    a REPORTED action -- ParkourTypes.ActionKind, which is Slide/Vault/Mantle/WallRun/LedgeClimb/
	    Roll/Leap and deliberately nothing else (see that type's own header on why only the states
	    that take velocity are network events). A ledge hang or a mid-air state is invisible to it.
	    It is watchdog-bounded server-side, so a client that crashes mid-slide cannot leave it stuck.

	  * IsActionState reads the live MovementStateId and sees everything the client's own state
	    machine knows, ledge hangs included. It is only available where that state machine runs, which
	    is the local client, and a client is not an authority.

	So they are used together rather than interchangeably: the client declines to SEND a press it can
	already see is illegal (the wider set, no round trip, no authority claimed), and the server
	refuses the ones that reach it anyway (the narrower set, authoritative). The gap between them --
	a press thrown from a ledge hang by a client that chose not to filter -- is a press the server
	currently allows, and closing it means ParkourTypes.ActionKind growing a reportable hang, which is
	the parkour layer's call and not something to fake from a combat gate.

	AerialCombat IS DELIBERATELY NOT AN ACTION HERE. That state is where the parkour framework parks
	while COMBAT already owns the body (States/AerialCombat.lua: "doing nothing, correctly"). Counting
	it would mean a combat action refusing itself: the first swing hands the body to combat, parkour
	parks in AerialCombat, and every following swing is refused for being "in a parkour action" --
	which would take aerial combat out of the game entirely.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

type MovementStateId = ParkourTypes.MovementStateId

local ParkourOwnership = {}

-- Every MovementStateId that counts as "in a parkour action" for the purpose of refusing a combat
-- action. Ordinary locomotion is absent (Idle/Walking/Sprinting -- you must be able to fight while
-- standing or walking, and Sprinting is handled by forcing the run down rather than by refusing) and
-- so is ordinary air time (Jumping/Falling/Landing -- a jump is not a traversal, and refusing an
-- attack for being briefly airborne would delete jump-cancelling and every aerial exchange).
-- AerialCombat is absent for the reason this file's header gives at length.
--
-- Listed exhaustively rather than derived from a DriveMode or a priority number: this is a GAMEPLAY
-- rule about which traversals commit you, and tying it to an implementation detail of how a state
-- happens to move the body would silently re-decide it the next time a state changes motors.
local ACTION_STATES: { [string]: boolean } = {
	Sliding = true,
	Vaulting = true,
	Mantling = true,
	WallRunning = true,
	LedgeHanging = true,
	LedgeClimbing = true,
	Rolling = true,
	Dashing = true,
	Leaping = true,
	LedgeLeaping = true,
}

-- Whether a parkour action currently owns this body, as the SERVER can see it.
--
-- Reads the Attribute rather than calling into ParkourSystem, which is the same choice
-- Server/Systems/RunSystem.lua's whole resolver makes and for the same reason its header gives: a
-- System can influence combat without the combat layer ever learning that System exists. It also
-- works for a Model with no Player behind it -- a bot has no parkour and no Attribute, so it reads
-- false and is never gated, with no special case anywhere.
function ParkourOwnership.OwnsBody(humanoid: Humanoid): boolean
	return humanoid:GetAttribute(Constants.Attributes.ParkourVelocityOwned) == true
end

-- Whether this live MovementStateId is a parkour action, as the local CLIENT can see it. `nil` is a
-- legitimate answer meaning "the framework is not driving at all" (disabled, or between characters)
-- and is not an action.
function ParkourOwnership.IsActionState(stateId: MovementStateId?): boolean
	return stateId ~= nil and ACTION_STATES[stateId] == true
end

return ParkourOwnership
