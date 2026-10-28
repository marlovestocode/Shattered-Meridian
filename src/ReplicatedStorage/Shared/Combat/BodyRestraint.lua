--!strict
--[[
	BodyRestraint.lua

	Owns: "may this body <verb> now?" for every restraint that lives on a Humanoid Attribute -- one policy table, verb by verb,
	each an ORDERED list of (restraint, reason). Pure: it reads Attributes (and Health) and holds no state.

	WHY (coworking plan F5, W9). At least eight consumers each read their own subset of about a dozen restraint Attributes, in
	their own order: the attack layer checked Mounted before Frozen, the evade checked Grabbed/Grabbing/Mounted, then Frozen, then
	the air hold; RunSystem pinned WalkSpeed for seven; parkour's HeldElsewhere had its own six. Nothing showed where they disagreed,
	so a disagreement could only be found by a player. The policy table below IS that comparison: a verb's row is its whole answer,
	and a blank in it is visible. The matrix, with each blank marked deliberate or escalated, is in
	docs/architecture/2026-10-27-body-restraint-matrix.md.

	EVERY CONVERSION PRESERVES ITS ANSWER. Each verb's list reproduces the consumer it replaced -- the same restraints, the same
	order, the same reason strings (Tests/Combat/BodyRestraint.spec.lua runs each old predicate and the verb over every
	combination). Changing what a verb refuses is a design decision with its own escalation, never a side effect of moving here.

	Does not own:
	  * RECORD-BACKED gates -- DefenseSystem.CanAttack, DamageSystem.CanAttack, GrabSystem.CanAttack, AirComboSystem.CanAttack.
	    They answer from a System's own records (a swing in flight, a stun deadline), stay where they are, and run BEFORE a verb
	    here in every caller that has both.
	  * ParkourOwnership.OwnsBody (parkour driving the body is the other direction of the question) and a defence state.
	  * Writing any Attribute. Each has one writer (RootControl, MovementAllowance, GrabSystem, VesselMount, AdminActionSystem,
	    EmoteSystem, HitboxEngine's swing lock); this module only reads them.
	  * Cached, change-driven readers (CombatCamera's camera mode, RunSystem's mirror). They still ask THIS module which
	    Attributes a verb reads (`AttributesOf`) and what the answer is; they only choose when to ask.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)

local BodyRestraint = {}

export type Restraint =
	"Frozen"
	| "Grabbed"
	| "Grabbing"
	| "GrabThrowing"
	| "Mounted"
	| "Flying"
	| "RootLocked"
	| "SwingRooted"
	| "EmoteLocked"
	| "Ragdolled"
	| "AirHeld"
	| "AirParticipant"
	| "DomainRooted"
	| "DomainNoEvade"
	| "Dead"

export type Verb =
	"Swing"
	| "Guard"
	| "GuardRequest"
	| "Evade"
	| "Move"
	| "Parkour"
	| "LocalSwing"
	| "Emote"
	| "LockOn"
	| "Judge"
	| "Launch"
	| "CameraMotion"

-- The restraints that are one boolean Attribute, by the Attribute's name. The rest are leases or derived (below).
local FLAG_ATTRIBUTE: { [Restraint]: string } = {
	Frozen = AttributeConstants.Frozen,
	Grabbed = AttributeConstants.Grabbed,
	Grabbing = AttributeConstants.Grabbing,
	GrabThrowing = AttributeConstants.GrabThrowing,
	Mounted = AttributeConstants.Mounted,
	Flying = AttributeConstants.Flying,
	RootLocked = AttributeConstants.RootControlLocked,
	SwingRooted = AttributeConstants.SwingRooted,
	EmoteLocked = AttributeConstants.EmoteMovementLocked,
	Ragdolled = AttributeConstants.Ragdolled,
}

local DERIVED: { [Restraint]: (humanoid: Humanoid, now: number?) -> boolean } = {
	AirHeld = function(humanoid)
		return AirComboAttributes.IsHeld(humanoid)
	end,
	AirParticipant = function(humanoid)
		return AirComboAttributes.IsParticipant(humanoid)
	end,
	-- Both realm rules are read through the realm's DomainUntil lease (DomainRules' contract), on the caller's clock.
	DomainRooted = function(humanoid, now)
		return DomainRules.Has(humanoid, "Rooted", now)
	end,
	DomainNoEvade = function(humanoid, now)
		return DomainRules.Has(humanoid, "NoEvade", now)
	end,
	Dead = function(humanoid)
		return humanoid.Health <= 0
	end,
}

type Rule = { Restraint: Restraint, Reason: string }

local function rule(restraint: Restraint, reason: string?): Rule
	return { Restraint = restraint, Reason = reason or restraint }
end

-- THE POLICY. Each row is ordered: the first restraint that holds is the refusal. A row reproduces the consumer named beside it.
--
-- RAGDOLLED (2026-10-27, Server/Combat/Ragdoll/RagdollSystem) was added as a design decision, last in each row it joins so
-- no existing answer changes: a limp body swings, guards (so it cannot stun-parry its way up), evades, emotes, starts parkour
-- or is launched into an air string by nothing, and its motion is not judged. Move and CameraMotion do not list it: the
-- ragdoll also claims RootControl, whose RootLocked already stands those two down, and RunSystem keeping the run gear across
-- a fall is wanted.
local POLICY: { [Verb]: { Rule } } = {
	-- AttackRequestSystem.bodyGate's Attribute tail, after the four record gates and the traversal gate.
	Swing = { rule("Mounted"), rule("Frozen"), rule("Ragdolled") },
	-- DefenseSystem's guard PRESS (a release always goes through).
	Guard = { rule("Frozen"), rule("Ragdolled") },
	-- DefenseSystem's SetBlocking REMOTE handler (press and release alike): a mounted player's guard is never forwarded.
	GuardRequest = { rule("Mounted") },
	-- DefenseSystem.evadeBodyRefusal, after its record-backed "Committed".
	Evade = {
		rule("Grabbed", "Restrained"),
		rule("Grabbing", "Restrained"),
		rule("Mounted", "Restrained"),
		rule("Frozen"),
		rule("AirHeld"),
		rule("DomainNoEvade", "DomainSealed"),
		rule("Ragdolled"),
	},
	-- RunSystem's "another System has taken this character" tiers. The realm's Rooted rule is NOT here: RunSystem's mirror is
	-- event-driven and the realm's lease must be compared every tick, so RunSystem asks DomainRooted itself, per tick.
	Move = {
		rule("Frozen"),
		rule("Flying"),
		rule("EmoteLocked"),
		rule("Grabbed"),
		rule("GrabThrowing"),
		rule("Mounted"),
		rule("SwingRooted"),
	},
	-- ParkourOwnership.HeldElsewhere: someone else holds this body, so parkour may not drive it (client park, server Start).
	Parkour = {
		rule("RootLocked"),
		rule("Flying"),
		rule("Frozen"),
		rule("EmoteLocked"),
		rule("AirParticipant"),
		rule("DomainRooted"),
		rule("Dead"),
		rule("Ragdolled"),
	},
	-- AttackInputClient's local filter: a press the client declines to send (the server's Swing row still decides).
	LocalSwing = { rule("Mounted"), rule("Grabbed"), rule("Grabbing"), rule("Ragdolled") },
	-- EmoteSystem.RequestPlay.
	Emote = { rule("Mounted"), rule("Ragdolled") },
	-- LockOnController.bodyRefusesLock (its root check stays there: a missing part is not a restraint).
	LockOn = { rule("Dead"), rule("Mounted"), rule("Flying") },
	-- MovementGuard.excuseOf's "a server System holds this body" excuse: such a body's speed and climb are not judged.
	Judge = {
		rule("RootLocked", "ServerHeld"),
		rule("Grabbed", "ServerHeld"),
		rule("Mounted", "ServerHeld"),
		rule("Flying", "ServerHeld"),
		rule("Ragdolled", "ServerHeld"),
	},
	-- AirComboSystem's launch refusal: a body on either end of a grab, or welded to a vehicle, is never launched.
	Launch = { rule("Grabbed"), rule("Grabbing"), rule("Mounted"), rule("Ragdolled") },
	-- Client/Camera/CameraMotion: the movement-responsive camera reads the body's own velocity, so it stands down when a
	-- system other than the player's legs is moving it -- a vessel or flight (their cameras own the frame), a root lock
	-- (ragdoll, air-combo hold, throw), a grab, a freeze. Flag Attributes only, so its reader can mirror them by change;
	-- death is the reader's own Health check, and an air-combo hold (a lease) is stationary by definition.
	CameraMotion = {
		rule("Mounted"),
		rule("Flying"),
		rule("RootLocked"),
		rule("Grabbed"),
		rule("Frozen"),
	},
}

-- Whether one restraint holds on this body now.
function BodyRestraint.Has(humanoid: Humanoid, restraint: Restraint, now: number?): boolean
	local attribute = FLAG_ATTRIBUTE[restraint]
	if attribute then
		return humanoid:GetAttribute(attribute) == true
	end
	local derived = DERIVED[restraint]
	assert(derived ~= nil, `BodyRestraint: unknown restraint "{restraint}"`)
	return derived(humanoid, now)
end

-- The reason this body may not `verb` now, or nil when nothing in the verb's row holds. A nil humanoid is never restrained:
-- every consumer this replaced answered "allowed" for a body with no Humanoid and refused it elsewhere, for its own reason.
function BodyRestraint.Refusal(humanoid: Humanoid?, verb: Verb, now: number?): string?
	if humanoid == nil then
		return nil
	end
	local row = POLICY[verb]
	assert(row ~= nil, `BodyRestraint: unknown verb "{verb}"`)
	for _, entry in row do
		if BodyRestraint.Has(humanoid, entry.Restraint, now) then
			return entry.Reason
		end
	end
	return nil
end

-- Whether anything in the verb's row holds.
function BodyRestraint.Restrained(humanoid: Humanoid?, verb: Verb, now: number?): boolean
	return BodyRestraint.Refusal(humanoid, verb, now) ~= nil
end

-- The Attribute names a verb's flag restraints read, for a change-driven reader that mirrors them (RunSystem). Leases and derived
-- restraints are not included: they change with time, not with an Attribute write, and such a reader must ask them per tick.
function BodyRestraint.AttributesOf(verb: Verb): { string }
	local names: { string } = {}
	for _, entry in POLICY[verb] do
		local attribute = FLAG_ATTRIBUTE[entry.Restraint]
		if attribute then
			table.insert(names, attribute)
		end
	end
	return names
end

-- The verb's row, as (restraint, reason) pairs, for the matrix doc and specs.
function BodyRestraint.Row(verb: Verb): { Rule }
	return table.clone(POLICY[verb])
end

BodyRestraint.Verbs = table.freeze({
	"Swing",
	"Guard",
	"GuardRequest",
	"Evade",
	"Move",
	"Parkour",
	"LocalSwing",
	"Emote",
	"LockOn",
	"Judge",
	"Launch",
	"CameraMotion",
}) :: { Verb }

return BodyRestraint
