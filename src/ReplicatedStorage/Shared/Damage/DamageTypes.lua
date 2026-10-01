--!strict
--[[
	DamageTypes.lua

	Owns: the shapes the Damage System is written in -- what one resolved contact costs (DamageResult),
	how deep into a string an attacker currently is (ComboEscalationState), what an attack looks like
	once the Move Creation System has been projected onto the engine (AttackCatalogEntry), and the
	payload both participants get told about it (CombatFeedback).

	Deliberately NOT a section of Shared/Types.lua, for the same reason DefenseTypes.lua and
	HitboxTypes.lua are not: this system is a module. A system whose types live somewhere else is one
	that cannot be removed without unpicking that somewhere else.

	Everything here is data. The only Instances any of it references are the two combatants on the
	feedback payload, and those are carried rather than interpreted.

	Does not own: what any of it MEANS in play (DamageResolver decides, DamageSystem applies), the
	tunables (DamageConstants.lua), or the authored per-move numbers (MoveTypes.DamageProfile, which is
	produced by the Move Creation System and only aliased here).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local DamageTypes = {}

-- Aliased rather than redefined. DamageProfile is PRODUCED by MoveTypes.ToEngineAttackDefinition, so
-- that file is where it has to live -- defining it here and having MoveTypes require this module would
-- make the Move Creation System depend on the damage layer, and the authoring pipeline is supposed to
-- be usable without one. Re-exported so a consumer of this system finds the whole vocabulary on one
-- module.
export type DamageProfile = MoveTypes.DamageProfile

-- One authored move, resolved into the two things the combat stack needs from it: the geometry the
-- engine runs, and the numbers this layer applies. Produced by AttackCatalog.
--
-- Deliberately holds both halves rather than being split into two lookups. They come from one
-- MoveDefinition and one projection, so keeping them together means there is no way to resolve an
-- attack's shape and its damage from two different versions of the same move.
export type AttackCatalogEntry = {
	MoveId: string,
	Definition: HitboxTypes.AttackDefinition,
	Profile: DamageProfile,
	-- Carried through from the authored move for the attack layer's benefit. Nothing in the damage
	-- layer reads it -- a cooldown gates whether a swing may START, which is a request-side question.
	Cooldown: number,
	-- Same "carried for the layer above" reasoning as Cooldown, for the authored clip. "" when the
	-- move has none, which is every Default move today (DefaultMoveRegistry's own header on why a
	-- Default move's AnimationId is always blank).
	--
	-- It rides on the catalogue entry rather than being looked up separately by the attack layer so
	-- that a move's geometry, its damage, its cooldown and its clip all come from ONE resolution of
	-- ONE MoveDefinition -- the same reason this record holds both halves of the projection instead of
	-- being split into two lookups. A second lookup at throw time could straddle a Move Editor edit
	-- and pair one version's timing with another version's animation.
	AnimationId: string,
	-- The speed the clip must play at for Definition's timeline to line up with it -- the weapon's own
	-- WeaponSpeed, 1 for anything without one. Same "carried for the layer above" reasoning again: it
	-- was used to build Definition's timings, so it has to ship with them.
	PlaybackSpeed: number,
	-- The swing's weight class (MoveTypes.PowerLevelOf), handed to HitboxEngine.RequestAttack. Carried
	-- here rather than on Definition because the engine takes PowerLevel as a per-swing argument, not a
	-- property of the geometry -- see HitboxTypes' own header on why it stays an opaque number there.
	PowerLevel: number,
	-- Whether this move may be feinted (MoveTypes.IsFeintable). Read by AttackRequestSystem.Feint.
	Feintable: boolean,
	-- Whether this move opens a realm (MoveTypes.IsDomain). Only its PRESENCE rides here: the attack layer
	-- asks "is this a domain cast" for its own two gates (one realm per caster, a realm's SealDomains rule)
	-- and nothing more. The realm itself is Server/Combat/Domain/DomainSystem's to read off the registry.
	IsDomain: boolean,
	-- The move whose clip this one borrows (Shared/Attack/AttackAnimations' BORROWED_FROM), or nil when it
	-- plays its own. A borrowed clip is retimed to the move rather than the move to the clip, so anything
	-- reading the clip's marker for THIS move must read it under the lender's id -- the Move Editor's
	-- readout is the one reader today. Nothing in combat reads it after Get.
	BorrowedFrom: string?,
}

-- How deep into an unbroken string an attacker is. Landing-based, and NOT the same counter as "which
-- move throws next" -- see ComboEscalation.lua's header for why those were always two numbers.
--
-- A flat record with an expiry timestamp rather than a state machine: this is never queried
-- retroactively ("what was your stage at time t"), only read fresh at the next hit, so the segment
-- history DefenseStateMachine needs would be machinery solving a problem this state does not have.
export type ComboEscalationState = {
	Stage: number,
	-- Absolute time the string lapses. Extended by every landed hit, never shortened.
	WindowExpiresAt: number,
}

-- What one contact costs, decided by DamageResolver and applied by DamageSystem. Pure data: nothing
-- here is applied by the act of computing it, which is what lets the resolver be table-driven
-- testable with no rig at all.
export type DamageResult = {
	Kind: DefenseTypes.OutcomeKind,
	-- Health to remove from the defender. Already scaled by combo stage and any outcome multiplier --
	-- the caller applies this number, it does not re-derive it.
	Damage: number,
	-- Guard (= posture, see DamageConstants.Guard) to drain from the defender. Zero for outcomes
	-- DefenseSystem has already charged against the same pool, so no contact is priced twice.
	GuardDrain: number,
	-- Seconds of hitstun for the defender, and the signal to cancel their own in-flight swing. Zero
	-- for any outcome that should not interrupt them.
	HitstunSeconds: number,
	-- Whether this hit escalates the ATTACKER's string. False for anything a defender answered
	-- successfully -- landing on a raised guard denies escalation credit.
	AdvancesCombo: boolean,
	-- Resolved, never applied. This layer decides THAT a hit knocks back and by how much; the physics
	-- rig that would apply it is the deleted RagdollController's territory and nothing rebuilds it
	-- here. Carried so the eventual consumer does not have to re-resolve it.
	Knockback: MoveTypes.MoveKnockback?,
	-- Same "resolved, never applied here" contract as Knockback above -- Server/Combat/Grab/
	-- GrabSystem.lua is the eventual consumer, subscribing to DamageSystem.OnApplied rather than this
	-- layer reaching into it. Set in the same Clean/Backstab/GuardBroken branches Knockback is.
	Grab: MoveTypes.MoveGrabConfig?,
	-- The world-space launch this hit gives the defender, or nil. NOT set by DamageResolver, which has no
	-- positions -- DamageSystem computes it from Knockback above and both combatants' roots
	-- (Shared/Damage/Knockback.LaunchVelocity) and writes it here BEFORE OnApplied fires, so every
	-- subscriber reads the one launch that was actually applied. Always nil when Grab is set: a grab is
	-- what happens INSTEAD of ordinary knockback (GrabSystem.lua's header).
	Launch: Vector3?,
}

-- Fired to both participants once per resolved contact. Everything each side needs to present the
-- hit, and nothing either could act on -- the outcome is already decided by the time this leaves the
-- server.
export type CombatFeedback = {
	Kind: DefenseTypes.OutcomeKind,
	-- Which side the receiving client is on. Sent rather than left to the client to work out by
	-- comparing its own character against the two models below: the same event is delivered to two
	-- different players and means something different to each, so saying which is cheaper and less
	-- error-prone than every client re-deriving it.
	Role: "Attacker" | "Defender",
	Attacker: Model,
	Defender: Model,
	Damage: number,
	GuardDrain: number,
	-- The attacker's stage AFTER this hit was applied, so a HUD reading it never shows a stale value.
	ComboStage: number,
	-- The MoveId that landed, via HitReport.DebugName. What a client uses to pick a hit effect or a
	-- reaction animation per move rather than per outcome kind.
	MoveId: string,
	ContactPosition: Vector3,
	-- The launch to apply to the RECEIVING client's own body -- set on the Defender copy only, and only
	-- when the defender is a player (a server-owned body is launched on the server). Carried on this
	-- event rather than a remote of its own because the defender's client must start it AFTER the
	-- hit-stop freeze this same event triggers, and two remotes have no ordering guarantee.
	Knockback: Vector3?,
	-- The spacing push for the RECEIVING client's own body (DamageConstants.Spacing), on either role's copy:
	-- the defender slid back, or the attacker following a hit / rebounding off a block. Horizontal only,
	-- and only when that side is a player. Carried here for Knockback's ordering reason.
	Push: Vector3?,
	-- True on a Blocked contact that left the defender's guard CRACKING (DefenseConstants.GuardCrack) --
	-- the cue for the heavier, hotter block sparks. Carried here rather than read off the
	-- GuardCrack tag on arrival, for the same no-ordering-guarantee reason Knockback is: the
	-- block that crosses the line would otherwise throw ordinary sparks half the time.
	GuardCracking: boolean?,
	-- True on a PERFECT parry (DefenseTypes.DefenseOutcome.Perfect) -- the cue for the heavier clash.
	Perfect: boolean?,
	-- The contact's part in an air combo, for the heavier presentation (Client/FX/AirComboFX.lua): "Launch",
	-- "Hit" (an air beat), "Finisher", or "Clash" (an air parry -- its own effect, distinct from a ground
	-- parry). Set by the air combo's damage hook (DamageSystem.SetAirComboHook); nil for every other contact.
	AirCombo: string?,
	-- The stun this contact put the RECEIVING client under, on the Defender copy only: it varies by move
	-- (DamageConstants.Hitstun.ByWeapon), so the client's own stun mirror cannot assume the shared length.
	HitstunSeconds: number?,
}

return DamageTypes
