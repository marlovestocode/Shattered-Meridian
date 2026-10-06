--!strict
--[[
	DefenseTypes.lua

	Owns: the shapes the Defense System is written in -- the states a defender can be in, the kinds of
	outcome a contact can resolve to, the window a parry is live for, and the outcome record itself.

	Deliberately NOT a section of Shared/Types.lua, for the same reason
	Shared/HitboxEngine/HitboxTypes.lua is not one: this system is a module. It can be dropped in or
	pulled out without editing the game's central type file, and a system whose types live somewhere
	else is one that cannot be removed without unpicking that somewhere else.

	Everything here is data. No Instances are referenced by any type in this file except through
	DefenseOutcome's passthrough of the originating HitReport -- which is the engine's shape, not
	this system's, and is carried rather than interpreted.

	Does not own: what any outcome MEANS in damage (nothing in this system applies damage -- see
	DefenseSystem.lua's header), nor the tunables (DefenseConstants.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

local DefenseTypes = {}

-- THE DEFENDER'S STATES.
--
-- Seven, not the five the plan's diagram showed, and the two extra are both real rather than
-- decorative:
--
--   * Raising exists because ParryStart is an authored offset from the START of the clip, and
--     nothing says it is zero. The stretch between the press and that marker is a genuine phase in
--     which the player has committed but nothing is live yet -- it is the block's raise time, and
--     pretending it away would mean either arming the parry early (a window the animation does not
--     show) or delaying the press (input latency the player would feel). When Open is authored at 0
--     this phase has zero duration and chains straight through within the same call, the same way
--     AttackStateMachine handles a zero-second windup.
--
--   * ParryRecovery is the whiffed-tap lockout. See DefenseStateMachine for why it is entered only
--     on the released branch.
export type DefenseState =
	"Neutral"
	| "Raising"
	| "ParryWindow"
	| "Blocking"
	| "ParryRecovery"
	| "Staggered"
	| "GuardBroken"

-- What a contact turned out to be. The whole output vocabulary of this system.
--
-- Trade is deliberately NOT producible by OutcomeResolver.Resolve, which classifies one report in
-- isolation and cannot see a second one. It is produced only by ArbitrateTrades and ArbitrateClashes,
-- which run over a whole frame's batch -- see DefenseSystem.lua's two-pass header. A resolver that could return Trade
-- would be a resolver that had to know about the batch, which is exactly the coupling keeping it
-- pure avoids.
export type OutcomeKind =
	"Clean" -- nothing stopped it
	| "Blocked" -- inside the block arc, guard held
	| "GuardBroken" -- inside the arc, guard emptied on this hit
	| "Backstab" -- blocking, but struck from the rear hemisphere
	| "Parried" -- landed inside the defender's live parry window
	| "Trade" -- two swings met: mutual parries in one batch, or a clash (DefenseConstants.Clash)
	| "Evaded" -- landed inside the defender's roll evade window (DefenseConstants.Evade)

-- The two authored times that define a parry, plus the recovery a whiff costs.
--
-- All three are offsets in SECONDS FROM THE START OF THE CLIP, not absolute times -- the same
-- convention the animation markers themselves use, so a window read off an asset and a window
-- declared by ParryWindows.Register are the same kind of number and can never be mixed up.
--
-- Source records where this window came from, purely so ValidateAll can report a registration that
-- authored markers have shadowed. Nothing gates on it.
export type ParryWindow = {
	Open: number,
	Close: number,
	RecoveryEnd: number,
	Source: "Markers" | "Registered" | "Override",
}

-- One resolved contact. Everything a damage layer needs, with none of its decisions made.
--
-- Carries the originating HitReport whole rather than copying fields out of it: a consumer that
-- wants ComboStage, the live Dimensions or the contact position should read the engine's own record
-- rather than a partial transcription of it that could fall behind the engine's shape.
export type DefenseOutcome = {
	Kind: OutcomeKind,
	Report: HitboxTypes.HitReport,
	Attacker: Model,
	Defender: Model,
	-- Horizontal angle between the defender's facing and the direction the attacker was in, in
	-- degrees. 0 is dead ahead, 180 directly behind. This is the number every directional rule in
	-- the system is expressed against -- see OutcomeResolver.BearingDegrees.
	BearingDegrees: number,
	-- The defender's state at the contact's SampleTime, which on a subdivided frame is not
	-- necessarily the state they are in when this outcome is delivered. Recorded so a consumer never
	-- has to re-derive it and get a different answer.
	DefenderStateAtContact: DefenseState,
	-- Guard after this contact was applied, and the signed change that got it there. GuardDelta is
	-- negative for a drain, positive for a parry's restore, and zero for a Trade or a Clean hit.
	Guard: number,
	GuardDelta: number,
	-- The engine's substep clock for the contact. Copied up from the report because ordering
	-- outcomes is the single most common thing a consumer will want to do with a batch of them.
	SampleTime: number,
	-- Only ever true alongside Kind "Parried": the contact landed within
	-- DefenseConstants.PerfectParry.WindowSeconds of the window going live. Optional so every outcome a
	-- spec builds by hand still typechecks as "not perfect".
	Perfect: boolean?,
	-- Only ever true alongside Kind "Trade": the trade was two SWINGS meeting (DefenseConstants.Clash), not
	-- two parries. Both swings were cancelled -- the defender's too -- so the attack layer keeps BOTH
	-- players' strings, not just the attacker's.
	Clash: boolean?,
}

-- What OutcomeResolver.Resolve is given. Primitives only -- no Instances, no clock, no services --
-- which is what makes the resolver table-driven testable with no rig at all. DefenseSystem does
-- every Instance read and hands the results in.
export type ResolveInput = {
	DefenderState: DefenseState,
	BearingDegrees: number,
	PowerLevel: number,
	Guard: number,
	GuardMax: number,
	-- Whether the guard was actually held at the contact's SampleTime. Separate from DefenderState
	-- because a STAGGERED defender may still block (the brief is explicit), so the state alone does
	-- not say whether a contact was covered.
	BlockHeld: boolean,
	-- Whether the contact landed inside the defender's live, unspent parry window. Computed by
	-- DefenseStateMachine.IsParryLiveAt rather than inferred from DefenderState, because ping
	-- compensation extends the window past the state's own transition to Blocking.
	ParryLive: boolean,
	-- True once something earlier in this same batch has already consumed the defender's parry.
	-- Being surrounded is supposed to be dangerous: one window stops one attack.
	ParryConsumed: boolean,
	-- Whether the contact landed inside the defender's roll evade window
	-- (DefenseStateMachine.IsEvadingAt). Optional so a caller that predates evasion -- every existing
	-- resolver spec builds this table by hand -- reads as "not evading" rather than failing to typecheck.
	Evading: boolean?,
	-- The defender's guard does NOTHING for this contact -- held in an air combo, stunned on the ground
	-- (DefenseConstants.StunParry), or standing in a realm with NoBlock. A guard that would have blocked lets the
	-- hit through as Clean, and there is no backstab, since a backstab exists only because a guard was up. A live
	-- parry still counts. Optional: absent is "the guard works".
	GuardDisabled: boolean?,
}

-- What it returns. Kind plus the guard arithmetic, so the caller applies rather than recomputes.
export type ResolveResult = {
	Kind: OutcomeKind,
	Guard: number,
	GuardDelta: number,
	-- Whether this contact spent the defender's parry window. Only ever true alongside Kind
	-- "Parried".
	ConsumesParry: boolean,
}

-- A classified-but-not-yet-applied contact, the unit pass 1 produces and pass 2 consumes. Internal
-- to DefenseSystem, exported so the spec can build one without reaching into that module.
export type PendingContact = {
	Report: HitboxTypes.HitReport,
	Attacker: Model,
	Defender: Model,
	BearingDegrees: number,
	DefenderStateAtContact: DefenseState,
	Result: ResolveResult,
	SampleTime: number,
	-- See DefenseOutcome.Perfect. Classified in pass 1 at the contact's own SampleTime, like everything
	-- else about the contact, and carried unchanged to pass 2.
	Perfect: boolean?,
	-- Whether the DEFENDER's own swing was in its Active window with a volume reaching the attacker at the
	-- contact (HitboxEngine.ActiveSwingReaches). Measured in pass 1, at the substep the contact was found;
	-- read by OutcomeResolver.ArbitrateClashes. Only ever set on a Clean melee contact.
	DefenderSwingReaches: boolean?,
	-- Set by ArbitrateClashes on a contact it turned into a clash. See DefenseOutcome.Clash.
	Clash: boolean?,
}

-- The Defense_StateChanged payload, server -> the defending client. One shape for both ends, so the
-- server's writer (DefenseSystem.notifyClient) and its readers (Client/Defense/DefenseClient.lua, and
-- Client/UI/State/ClientState.lua for Guard/GuardMax) cannot drift apart.
--
--   State/Guard/GuardMax -- the posture, and the guard pool the HUD's posture tile renders.
--   FaceTowards          -- sent only on a parry: the attacker's position, for the client's facing snap.
--   Window               -- the parry window a press would arm RIGHT NOW (clip-relative seconds, before
--                           any rally shrink), or absent when none would. On every push, so the client's
--                           arming prediction always runs on the timing the server will judge with --
--                           including a per-weapon clip's authored markers, which the client never reads.
--   Press                -- the server's verdict on one press: the id the client sent with it, and
--                           whether it armed a parry. Only on the push answering that press.
export type PressVerdict = {
	Id: number,
	Armed: boolean,
}

export type WindowShape = {
	Open: number,
	Close: number,
	RecoveryEnd: number,
}

export type StatePayload = {
	State: DefenseState,
	Guard: number,
	GuardMax: number,
	FaceTowards: Vector3?,
	Window: WindowShape?,
	Press: PressVerdict?,
}

return DefenseTypes
