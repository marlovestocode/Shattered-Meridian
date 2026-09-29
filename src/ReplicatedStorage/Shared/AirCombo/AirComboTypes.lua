--!strict
--[[
	AirComboTypes.lua

	Owns: the shapes the air combo is written in -- the published phase, every reason a combo can end, the
	role a move plays in the air, and the per-combo record the machine keeps. Pure data; everything that
	gives it meaning is Server/Combat/AirCombo/AirComboMachine.lua.

	Standalone for the reason DamageTypes/GrabTypes are: a system whose types live somewhere else is one
	that cannot be removed without unpicking that somewhere else.
]]

local AirComboTypes = {}

-- The AirComboPhase Attribute's values (Constants.Attributes.AirComboPhase). Rising/Held/Finishing while
-- a combo runs; the rest are END states, published for Timing.PhaseLingerSeconds so a spectator can read
-- how it ended.
export type Phase = "Rising" | "Held" | "Finishing" | "Parried" | "Dropped" | "Recovering" | "Slammed" | "Spiked"

-- Every way a combo ends (docs B1's table). One End(reason) in the machine; each reason maps to one end
-- phase for the victim.
export type EndReason =
	"Finished" -- a finisher landed
	| "Parried" -- the victim parried an air hit or a finisher
	| "Dropped" -- ContinueBy passed with no in-time swing in flight
	| "Interrupted" -- the attacker took a Clean/Backstab/GuardBroken hit from anyone
	| "SpacingFail" -- the attacker stayed out of its slot past the grace (server audit)
	| "Timeout" -- the hard MaxComboSeconds cap
	| "Aborted" -- a participant died, despawned, disconnected, was grabbed or mounted

-- What a move id is in the air. Derived from the id scheme (DefaultMoveRegistry's
-- default:{weapon}:Launcher / :Air:{n} / :AirFinisher:{kind}), never authored.
export type FinisherKind = "Slam" | "Spike"
export type MoveRole = {
	Role: "Launcher" | "Air" | "Finisher",
	-- Air only: which beat of the string (1..StringLength).
	Beat: number?,
	-- Finisher only.
	Finisher: FinisherKind?,
}

-- The press modifier an AttackRequest may carry (AttackTypes.AttackRequest.Modifier). "Up" is Space held at
-- the press. The server decides whether it means anything, so a forged modifier can only ask for a
-- launcher the string already earned.
export type Modifier = "Up"

-- What the attack layer needs to resolve a press into an air move: present only while this combatant is a
-- live combo's attacker.
export type AirResolveContext = {
	AirHitsLanded: number,
}

-- One combo, as the pure machine keeps it. Times are the server's os.clock(), the clock every combat System
-- here runs on; AirComboSystem converts to GetServerTimeNow only when it publishes.
export type Combo = {
	LaunchedAt: number,
	Phase: Phase,
	-- The one shared deadline. See AirComboConstants.Timing.
	ContinueBy: number,
	-- Extended past ContinueBy while an in-time swing is still in flight: until that swing's active window
	-- ends. 0 when none is.
	GraceUntil: number,
	AirHitsLanded: number,
	-- Set once a finisher has been THROWN (Phase Finishing); the string cannot continue past it.
	FinisherThrown: boolean,
	Ended: EndReason?,
	EndedAt: number?,
}

return AirComboTypes
