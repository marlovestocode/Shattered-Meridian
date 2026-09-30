--!strict
--[[
	GrabTypes.lua

	Owns: the shapes the Grab layer is written in -- the throw request (carries nothing, the same
	"no geometry, only which button was pressed" contract AttackTypes.AttackRequest documents for the
	attack layer) and the hold-state cue both participants are told about (GrabHoldChangedPayload).

	Deliberately NOT a section of Shared/Types.lua, for the same reason AttackTypes.lua/DamageTypes.lua/
	DefenseTypes.lua are not: this system is a module, and a module whose types live somewhere else is
	one that cannot be removed without unpicking that somewhere else.

	Does not own: the authored per-move grab numbers (MoveTypes.MoveGrabConfig, produced by the Move
	Creation System), the tunables (GrabConstants.lua), or the hold/flight state machine itself
	(Server/Combat/Grab/GrabSystem.lua).
]]

local GrabTypes = {}

-- How a held body is carried -- one entry of GrabConstants.Modes each, which is where every number a
-- mode means lives (where the hand goes, which point of the victim it closes on, how the body hangs).
-- Authored per move (MoveTypes.MoveGrabConfig.Mode); nil on a config reads as "Collar", the only mode
-- there was before modes existed, so a move saved before this field still holds exactly as it did.
export type GrabMode = "Collar" | "Head" | "Drag" | "HeadDrag"

-- Which side of a hold this payload describes -- the same event fires to both participants (mirroring
-- DamageTypes.CombatFeedback's own Attacker/Defender split) so each client can show its own cue
-- ("HOLDING -- [G] to throw" for the attacker, "GRABBED" for the victim) without either one having to
-- infer its role by comparing Model references.
export type GrabRole = "Attacker" | "Victim"

-- Server -> both participants, on every hold starting and ending (a throw, an auto-release past
-- HoldSeconds, or a disconnect cleanup). Active = false carries no other field meaningful -- the same
-- "one payload, one shape, the false case just means less of it" convention CombatFeedback's own
-- optional fields already use.
export type GrabHoldChangedPayload = {
	Role: GrabRole,
	Active: boolean,
}

return GrabTypes
