--!strict
--[[
	CombatTypes.lua

	Owns: the type declarations for CombatSystem.lua's per-entity mutable state --
	CombatState/BotState/DummyState -- shared only among CombatSystem.lua and its own
	Server/Combat/ siblings (HitResolution.lua, Movement.lua) so those files can type their
	function signatures under --!strict without redeclaring the same shape locally. This is
	internal to CombatSystem's own ownership, not a system boundary: nothing outside
	Server/Combat/ requires this module, and CombatSystem.lua's Public API block still returns only
	Types.CombatSnapshot projections -- software-architecture.md's "no system reaches into another
	system's internals directly" governs *other Systems* (Main.server.lua, DevMenuSystem.lua,
	TrainingBotSystem.lua), none of which touch this file. Mirrors why ReplicatedStorage/Shared/
	Types.lua exists ("shared types live in Types.lua and are imported, never redefined locally"),
	scoped one level down to Combat's own files instead of the whole codebase.

	Does not own: any value or mutable state -- this file is types only, no runtime table lives
	here. The actual combatStates/botStates/dummyStates tables stay in CombatSystem.lua, which
	remains the only place these types are ever constructed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

-- Every commitment-consuming action tags itself here through the ONE shared mutator
-- (CombatSystem.lua's setActiveAction) at the same moment it commits attackEndsAt/its own
-- movement-burst window. Not itself a new legality gate -- attackEndsAt/the window fields remain
-- the actual timing authority -- its job is to make "starting action B force-closes action A's own
-- window fields" a single, reviewable, structurally-enforced step instead of relying on each
-- action's Duration/Commitment tuning happening to outlast the other's window (the Dash/Slide
-- overlap this exists to fix).
-- "CustomMove" (Move Creation System, CombatSystem.ThrowCustomMove) is the ONE, permanent action
-- kind every authored move routes through, keyed by MoveId (MoveRegistryManager.lua) rather than
-- earning its own CombatActionKind member per move -- see MoveRegistryManager.lua's own header for
-- why this is the fix for the closed-union-per-move problem every other standalone attack
-- (DashPunch/DashHit/AirSlam) still has.
export type CombatActionKind =
	"None"
	| "Basic"
	| "Heavy"
	| "AirSlam"
	| "Dash"
	| "DashPunch"
	| "DashHit"
	| "Slide"
	| "Feint"
	| "BlockStart"
	| "CustomMove"

-- CombatState's own decomposition (2026-07, Chief Architect's follow-up to the AdminOverrideState
-- extraction): CombatVitalsState/MovementState/AirComboState below are what's left of the original
-- flat ~50-field CombatState once its fields are grouped by concern -- health/posture/defensive-
-- timing state, neutral-game Dash/Slide/Sprint state, and the air-combo juggle state machine,
-- respectively. Nested as nemed fields ON CombatState (`state.Vitals.posture`, not a second
-- Player-keyed table CombatSystem.lua looks up separately) rather than mirroring AdminOverrideState's
-- own fully-standalone table -- deliberately NOT the same shape, for a real reason: AdminOverrideState
-- is read ONLY through Humanoid Attributes everywhere outside AdminActionSystem.lua itself (zero
-- other call sites ever touch overrideStates[player] directly), so giving it a fully independent
-- table with its own Players.CharacterAdded lifecycle hook was genuinely zero-risk. Vitals/Movement/
-- AirCombo are the opposite: they're read and written directly, by field, from CombatSystem.lua's own
-- hot request-handling/hit-resolution paths AND from Movement.lua's ComputeDesiredWalkSpeed (which
-- alone spans all three groups plus core fields every single Heartbeat tick). Splitting them into
-- separate top-level Player-keyed tables would force every one of those call sites to thread 2-4
-- separate table references through instead of one `state`, and would risk exactly the kind of
-- respawn-ordering bug class this codebase has already paid for once (see onCharacterAdded's own
-- reset block) if a second, independent per-player lifecycle hook were introduced for any one of
-- them. Nesting keeps a single per-player CombatState (and therefore a single combatStates lookup,
-- a single character-lifecycle owner: CombatSystem.lua's own onCharacterAdded/onCharacterRemoving)
-- while still giving each concern its own named, independently-documented, independently-testable
-- type -- the actual cohesion problem the original audit flagged, without inventing a wrapper the
-- hot path would pay for. See each sub-type's own header for what it owns.
--
-- AirComboState is the one exception granted a constructor of its own (AirCombo.CreateState(),
-- called from CombatSystem.lua's createFreshState/onCharacterAdded) -- it's the largest, most
-- self-contained cluster (matching both the original audit and the Chief Architect's own framing),
-- and AirCombo.lua is already the sole module that mutates it as business logic (CombatSystem.lua's
-- own touches are limited to construction, the onHeartbeat suspended-timeout check, and character-
-- lifecycle reset/cleanup -- the same "orchestration only" role it already plays for every other
-- Server/Combat/ sibling). CombatVitalsState/MovementState get no such constructor: no single
-- Server/Combat/ sibling owns "vitals" or "neutral movement" construction as its primary purpose
-- (HitResolution.lua is explicitly pure/stateless; Movement.lua owns mutation, not a canonical
-- "fresh state" shape), so those two stay plain table literals inside CombatSystem.lua's own
-- createFreshState, exactly like the whole CombatState already was before this decomposition.

-- Health/posture/defensive-timing state -- health itself lives on Humanoid.Health (this System's
-- only two vitals are Health and Posture, see CombatSystem.lua's own header), so `maxHealth` here is
-- just the ceiling CombatSystem.lua pins Humanoid.MaxHealth to. Posture, its break-exposure window,
-- and every timing field that represents a physical consequence of being hit or of attempting to
-- defend (parry availability, stun, the post-hit WalkSpeed clip, disarm, a finisher's ragdoll
-- lockout) live here -- as opposed to MovementState (neutral-game positioning) or the core
-- CombatState fields below (combo/weapon/lock-on bookkeeping that isn't itself a vitals concept).
-- Not on BotState/DummyState -- both carry their own equivalent flat fields (BotState mirrors most
-- of these; DummyState only posture/postureBrokenExpiry, see each type's own header) rather than
-- nesting, since neither is being decomposed by this pass.
export type CombatVitalsState = {
	maxHealth: number,
	posture: number,
	maxPosture: number,
	-- Timestamp before which this player is posture-broken (fully exposed -- every defense
	-- classification returns "None" while now < postureBrokenExpiry, see HitResolution.
	-- ClassifyDefense) and gates handleAttackRequest/handleBlockStart/handleDashRequest/
	-- handleSlideRequest/handleSwapWeaponRequest via ACTION_GATES.PostureBroken.
	postureBrokenExpiry: number,
	-- Block/Parry are the same physical input (handleBlockStart) -- parryWindowExpiry is the short
	-- window after a press during which an incoming hit classifies as a Parry rather than a plain
	-- Block; parryCooldownExpiry gates how soon the NEXT press can open a fresh window at all (a
	-- press that's still on this cooldown still starts a plain block, it just can't parry).
	parryWindowExpiry: number,
	parryCooldownExpiry: number,
	-- Universal hit-reaction lockout (Constants.Combat.HitStunDuration on a landed hit,
	-- StunDuration on a Parry punish) -- gates every action category via ACTION_GATES.Stun except
	-- BlockStart (see ACTION_GATES' own header for why Block/Parry stays available through a stun).
	-- math.max'd, never shortened, by every writer.
	stunExpiry: number,
	-- Timestamp before which humanoid.WalkSpeed stays clipped to Constants.Combat.BaseWalkSpeed *
	-- HitSlowMultiplier after landing an unmitigated hit -- see onHeartbeat's restore check. Not
	-- used by DummyState/BotState: neither moves under its own WalkSpeed (a bot's position is
	-- driven directly, per onHeartbeat's bot loop), so the movement half of the hit reaction only
	-- applies to a real player's CombatState.
	hitSlowExpiry: number,
	-- Timestamp before which this player cannot throw a Basic or Heavy attack -- set when their
	-- Heavy attack gets Parried (HitResolution.ShouldDisarm/ApplyDisarm, called from every
	-- resolveHit* function in CombatSystem.lua). Deliberately does NOT block Block/Parry/Dash/
	-- Sprint/LockOn -- a disarmed player isn't helpless, just can't deal damage, which is what
	-- keeps this from violating gameplay-philosophy.md's anti-lockout rule (a short, fixed,
	-- always-recoverable window, same shape as postureBrokenExpiry, not an interactive "find your
	-- weapon" punishment). On BotState too: a bot can throw Heavy attacks and get Parried by its
	-- owner exactly like a real opponent. Not on DummyState: a dummy never attacks.
	disarmedUntil: number,
	-- Timestamp before which this player is ragdolled by a finisher (uppercut/downslam) and cannot
	-- act -- gates handleAttackRequest/handleBlockStart/handleDashRequest/handleSprintStart the same
	-- way stunExpiry does. Set when a finisher lands (HitResolution.ApplyFinisherPhysics); the
	-- physical recovery is owned by Server/Combat/RagdollController.lua on the same timer, so the
	-- lockout and the stand-up stay in lockstep. Not on DummyState/BotState: a dummy has no actions
	-- to lock out (it's ragdolled physically only), and bot targets are never ragdolled (their
	-- position is driven).
	ragdollExpiry: number,
}

-- Neutral-game movement state (Movement.lua's own ApplyDash/ApplySlide/SetSprinting mutate these;
-- Movement.ComputeDesiredWalkSpeed reads them every Heartbeat tick). Scoped to Sprint/Dash/Slide
-- specifically -- AirSlam's own airSlamReadyAt stays a core CombatState field instead (it's an
-- attack-shaped cooldown structurally identical to basicAttackReadyAt/heavyAttackReadyAt, thrown
-- directly by CombatSystem.lua's own handleAirSlamRequest, and Movement.lua never touches it at
-- all -- unlike every field below, which Movement.lua's own functions read or write). Not on
-- BotState/DummyState: neither has dash/sprint fields (bots never touch neutral-game movement, a
-- dummy never acts at all) -- see Movement.lua's own header.
export type MovementState = {
	-- Held intent flag (a raised WalkSpeed only actually applies when
	-- Movement.ComputeDesiredWalkSpeed allows it); set by handleSprintStart/Stop.
	sprinting: boolean,
	dashWindowExpiry: number,
	dashCooldownExpiry: number,
	-- Whether the CURRENTLY active dashWindowExpiry burst is a backward one (Movement.
	-- ResolveDashDirection resolved "Back" at throw time) -- read by Movement.ComputeDesiredWalkSpeed
	-- while now < dashWindowExpiry to pick DashBackSpeedMultiplier instead of the plain
	-- DashSpeedMultiplier. See DashBackSpeedMultiplier/DashBackCooldownSeconds' own header in
	-- Constants.lua for why backward specifically is tuned down from every other direction.
	dashIsBackward: boolean,
	-- Timestamp before which a new front dash-punch (the DashPunch hitbox thrown off a double-tap-
	-- forward Dash) is on cooldown. Independent of dashCooldownExpiry: on this cooldown, the Dash
	-- press still resolves to a plain reposition (a Dash press always does something) but throws no
	-- hitbox. Set by throwDashPunch, the same "this move has its own real cooldown" pattern as
	-- basicAttackReadyAt/heavyAttackReadyAt -- DashPunch deals damage and posture damage and can
	-- open the air combo, so it needs an attack-shaped cooldown of its own instead of silently
	-- riding on Dash's own much cheaper movement cooldown (see Constants.Combat.DashPunch.
	-- Cooldown's own header).
	--
	-- This is also what makes it SAFE that handleDashRequest still trusts a client-reported "was
	-- this a double-tap" hint (rawViaDoubleTapForward) for gating the punch package, the same trust
	-- tier as handleAttackRequest's holdingJump -- a dishonest client claiming double-tap on every
	-- press gets AT MOST one punch per Constants.Combat.DashPunch.Cooldown, identical to an honest
	-- player double-tapping that often. An earlier pass here tried to make "double-tap" a fact the
	-- SERVER derives (comparing two consecutive accepted Dash timestamps) instead of trusting the
	-- client at all -- it didn't work: CombatClient.lua's double-tap-W listener only ever sends ONE
	-- RequestDash per gesture (the first press just arms a local timer, never reaches the server),
	-- so the server had nothing to compare against and the punch never threw. It was also
	-- structurally unreachable even for two genuine Dash-keybind presses, since Dash's own
	-- DashCooldownSeconds (0.8s) rejects a second Dash before DoubleTapDashWindowSeconds (0.3s) ever
	-- elapses. This cooldown field is what actually closes the exploit; verifying the tap itself
	-- isn't necessary once the payoff is bounded.
	dashPunchReadyAt: number,
	-- Slide (Movement.ApplySlide/CombatSystem.lua's handleSlideRequest) -- mirrors
	-- dashWindowExpiry/dashCooldownExpiry exactly (a WalkSpeed-burst window + its own cooldown), but
	-- chained off `sprinting` above rather than its own standalone trigger key: handleSlideRequest
	-- rejects unless state.Movement.sprinting is already true.
	slideWindowExpiry: number,
	slideCooldownExpiry: number,
	-- Shared cooldown BOTH Dash and Slide check and set (in addition to each move's own individual
	-- cooldown above) -- closes a real playtest-found loophole: with only dashCooldownExpiry/
	-- slideCooldownExpiry as two INDEPENDENT pools, alternating the two keys let a player retreat
	-- almost twice as often as either move's own designed cooldown alone permits (whichever pool
	-- happened to be ready fired, so the effective renewal rate was roughly the FASTER of the two,
	-- not either one's own pacing). Set to now + the JUST-USED move's own cooldown constant
	-- (Constants.Combat.DashCooldownSeconds or SlideCooldownSeconds) on every accepted Dash/Slide,
	-- checked by both handlers before their own individual cooldown check -- using either move now
	-- gates the other at that move's own designed pace, not the cheaper of the two.
	movementCooldownExpiry: number,
	-- Move Creation System lunge grant (MoveDefinition.Movement, CombatSystem.ThrowCustomMove ->
	-- Movement.ApplyCustomMoveLunge) -- reuses the Dash-burst SHAPE (a fixed-speed WalkSpeed window,
	-- its own priority tier in Movement.ComputeDesiredWalkSpeed) rather than Dash's own state
	-- fields, since a lunge is authored per-move data, not a fixed neutral-game action. No cooldown
	-- field of its own -- the move's own Cooldown (CombatState.customMoveReadyAt) already gates how
	-- often a new lunge can be granted at all, the same way Dash needs no SECOND cooldown beyond
	-- dashCooldownExpiry. customMoveLungeSpeed is an absolute WalkSpeed (LungeDistanceStuds /
	-- LungeDurationSeconds), not a multiplier on base like Dash/Slide's own tiers -- an authored
	-- move specifies how far/how fast directly, there is no "base" lunge speed to scale.
	customMoveLungeWindowExpiry: number,
	customMoveLungeSpeed: number,
}

-- The air-combo state machine -- the DashPunch-launched juggle sequence (AirCombo.Apply). By a wide
-- margin the largest, most self-contained cluster of the original CombatState (per both the
-- original decomposition audit and the Chief Architect's own framing) --
-- see AirCombo.CreateState for why this one sub-state gets a constructor of its own, unlike Vitals/
-- Movement above. Only meaningful on a real player's CombatState -- bots never dash (Movement.lua's
-- own header: bots never touch Dash/Sprint fields), so a bot can never be the ATTACKER side of an
-- air combo, and DummyState only ever appears as the TARGET side (via airComboDummyTarget below,
-- never has a sub-state of its own).
export type AirComboState = {
	-- Air combo -- CombatSystem.lua's throwDashPunch launches the target AND this player into the
	-- air together; a landed M1 Basic hit against the SAME target while the sequence is still open
	-- continues the juggle (re-launches the target, extends the window) instead of throwing a fresh
	-- one. airComboTarget is who this player is currently juggling (nil = no active sequence);
	-- airComboHitCount is how many hits have landed so far, including the DashPunch launcher itself
	-- (capped at Constants.Combat.AirCombo.MaxHits -- the last hit at the cap slams the target down
	-- instead of re-launching, see AirCombo.Apply); airComboExpiry is the timestamp by which the
	-- NEXT hit must land against airComboTarget or the sequence lapses (the target just falls and
	-- ragdoll-recovers normally, same as an ordinary Uppercut).
	airComboTarget: Player?,
	-- Same sequence, against a training dummy instead of a real player -- a solo-testable version
	-- of the same mechanic (DummyCombat.lua's ResolveHit), tracked on its own field rather than
	-- widening airComboTarget's type, since a Model (dummyStates lookup) and a Player (combatStates
	-- lookup) need genuinely different state resolution at the call site. A player is only ever
	-- mid-sequence against ONE of these two at a time in practice, but both exist so neither call
	-- site needs to guess which kind of target the other one meant.
	airComboDummyTarget: Model?,
	airComboHitCount: number,
	airComboExpiry: number,
	-- The fixed world point (targetRoot.Position + Constants.Combat.AirCombo.HoverHeight, computed
	-- ONCE when DashPunch lands) that RagdollController.HoldAloft pins the target at for the rest of
	-- this sequence. Every continuation hit reuses this SAME point instead of recomputing one --
	-- recomputing from wherever the target currently is would let a fast combo ratchet them higher
	-- with every landed hit (the exact "keeps going up and never comes back down" bug HoverHeight's
	-- own header in Constants.lua describes). nil whenever airComboTarget/airComboDummyTarget is nil.
	airComboHoverPosition: Vector3?,
	-- The world-space offset (standoff distance back + a small distance down, away from the target,
	-- computed ONCE from the attacker's own position relative to the target when DashPunch lands --
	-- see Constants.Combat.AirCombo.ChaseStandoffDistance/ChaseBelowTargetOffset's own headers) added
	-- to airComboHoverPosition to get the fixed point RagdollController.HoldAloft pins the ATTACKER
	-- at, so they park at swinging range next to the target instead of converging on the target's
	-- exact point (which read as "he's on my head, not in front of me"). Reused verbatim by every
	-- continuation hit's HoldAloft refresh, same reuse-not-recompute reasoning as
	-- airComboHoverPosition above. nil whenever airComboTarget/airComboDummyTarget is nil.
	airComboChaseOffset: Vector3?,
	-- Timestamp until which Movement.ComputeDesiredWalkSpeed pins this player's WalkSpeed to 0,
	-- because RagdollController.HoldAloft currently has server-authoritative AlignPosition control
	-- of their rootPart (set alongside every HoldAloft call made for the ATTACKER side in
	-- AirCombo.Apply, zeroed alongside every RagdollController.ClearHold call on their rootPart).
	-- Network ownership alone doesn't stop this player's own held WASD from commanding Humanoid
	-- movement on the server -- that fight against the hold's pull is exactly what read as "we
	-- aren't floating next to each other" (see RagdollController.HoldAloft's own header); this field
	-- is what actually silences that competing input instead of just aspiring to.
	airComboChaseExpiry: number,
	-- The VICTIM-side mirror of airComboChaseExpiry above: timestamp until which THIS player -- as
	-- the TARGET of someone else's DashPunch juggle -- is held live (RagdollController.HoldAloft's
	-- liveBodyFacePoint treatment: gravity-cancelled, Motor6D/Humanoid control intact, position
	-- pinned) rather than ragdolled. Set (via math.max) alongside every HoldAloft call AirCombo.Apply
	-- makes for a real-player target (the DashPunch-start branch and every continuation hit), zeroed
	-- alongside every ClearHold on this player's own rootPart. Gates ACTION_GATES.HeldAloft (every
	-- category except BlockStart/LockOn -- combat-philosophy.md's "everything should be defendable"
	-- means a held victim keeps the one action that matters, Block/Parry, while staying locked out of
	-- attacking/repositioning/swapping same as before) and Movement.ComputeDesiredWalkSpeed (pins
	-- WalkSpeed to 0 for the same reason airComboChaseExpiry does on the attacker's side -- a held
	-- player's own WASD must not fight the hold). Deliberately separate from Vitals.ragdollExpiry --
	-- that field stays reserved for a GENUINE incapacitating ragdoll (a finisher/the air-combo's own
	-- MaxHits slam), which still gates BlockStart too, unlike this one. Not on BotState/DummyState --
	-- a bot can't be juggled and a dummy has no live-body concept at all (DummyState's own
	-- AirComboTarget adapter stays fully ragdolled the whole sequence, see AirComboTarget.
	-- setHeldExpiry's own header).
	airComboHeldExpiry: number,
}

-- Internal, mutable per-player state. Never returned directly to a caller -- CombatSystem.
-- GetCombatState returns a read-only Types.CombatSnapshot projection instead.
export type CombatState = {
	player: Player,
	character: Model?,
	humanoid: Humanoid?,
	rootPart: BasePart?,
	humanoidDiedConnection: RBXScriptConnection?,
	-- Mirrors humanoidDiedConnection's own lifecycle (reconnected onto the fresh Humanoid every
	-- onCharacterAdded, disconnected in onCharacterRemoving/onPlayerRemoving) -- the server-side
	-- listener that stamps genuineJumpAirborne below off the replicated Humanoid's own
	-- HumanoidStateType transitions. See genuineJumpAirborne's own header for why this needs a
	-- live StateChanged connection instead of a point-in-time GetState() read.
	humanoidStateChangedConnection: RBXScriptConnection?,

	alive: boolean,
	blocking: boolean,
	deathConfirmed: boolean,

	lockOnTarget: Player?,

	-- Timestamp until which this player is considered "in combat" -- a coarser, general-purpose
	-- "still fighting" signal any current or future system can read off Types.CombatSnapshot.
	-- InCombat, independent of which specific action caused it. Refreshed (assigned forward, not
	-- math.max'd) ONLY by an actual exchange with a real opponent: a hit landing/being received
	-- against another player, a hit against a training bot (a real, adversarial combat participant
	-- that attacks/blocks/parries back -- see BotState's own header) in either direction, a
	-- suspended-counter exchange, or a parry-punish/air-tech escape -- see each of those call sites
	-- for the exact list. Deliberately NOT refreshed just by throwing a swing (whiffed or not),
	-- opening Block with nobody attacking, or hitting a training DUMMY (never fights back, purely
	-- solo practice) -- "throw a punch" alone isn't "actively fighting somebody," per direct
	-- feedback that an earlier pass got this wrong. Still not a legality gate for anything today (no
	-- request handler reads it) -- its first real consumer is the HUD's combat-state badge, a
	-- read-only presentation signal, not a rule. Kept as a core (not Vitals/Movement/AirCombo) field
	-- -- it's fed by hit resolution, air-tech, AND the suspended counter-punch alike, so it doesn't
	-- cleanly belong to any one sub-state.
	--
	-- The InCombat value (now < inCombatUntil) last sent to this player's client over
	-- Combat_InCombatChanged used to live here as its own inCombatSynced bookkeeping flag (compared
	-- every onHeartbeat tick, fired the remote only on a transition) -- moved to a Shared/
	-- ChangeNotifier instance (2026-07, Chief Architect's follow-up to the CombatVitalsState/
	-- MovementState/AirComboState split): this field's ONLY purpose was remembering what was last
	-- reported, identical in shape to finisherReadySynced/rootControlLockedSynced, which used to live
	-- here too -- three hand-rolled copies of the same "compare, store, fire on change" check, now one
	-- shared, generic, narrowly-scoped helper instead. See CombatSystem.lua's own
	-- inCombatNotifier/finisherReadyNotifier/rootControlLockedNotifier and ChangeNotifier.lua's header
	-- for the full reasoning on why this is infra, not gameplay state.
	inCombatUntil: number,

	-- INPUT to the proximity-based inCombatUntil refresh (CombatSystem.lua's
	-- refreshInCombatFromProximity, called every onHeartbeat tick) -- never itself the in-combat
	-- signal, inCombatUntil above remains that. Stamped `recentOpponents[otherPlayer] = now`
	-- (HitResolution.StampRecentOpponent) at the exact same sites that already refresh inCombatUntil
	-- for a player-vs-player exchange (CombatSystem.lua's resolveHitAgainstTarget, both sides),
	-- capped at Constants.Combat.MaxTrackedOpponents. Deliberately NOT lockOnTarget: lock-on is a
	-- player-chosen aiming concept (you can lock someone you've never fought, or unlock mid-duel),
	-- wrong for "who have I actually traded with lately." Deliberately NOT on BotState -- a bot is a
	-- Model-keyed BotState, not a Player, so it structurally can't hold a `recentOpponents[Player]`
	-- entry; bot exchanges keep refreshing the human's inCombatUntil exactly as today, just without
	-- this proximity extension (not a regression -- bots never had one).
	recentOpponents: { [Player]: number },

	-- Timestamps (os.clock()) before which a new attack of that category is rejected. Set at throw
	-- time to now + the just-selected Types.HitboxAttackDefinition's Cooldown -- replaces a flat
	-- per-category cooldown constant now that cooldown is per combo-stage (Constants.Combat.
	-- Hitboxes.Basic/Heavy).
	basicAttackReadyAt: number,
	heavyAttackReadyAt: number,
	-- Timestamp before which a new AirSlam throw is on cooldown (Constants.Combat.AirSlam.Cooldown,
	-- CombatSystem.lua's handleAirSlamRequest/throwStandaloneAttack) -- the standalone "jump + M1"
	-- attack, own real cooldown for the same reason MovementState.dashPunchReadyAt has one (a move
	-- that hits hard AND launches can't be a free-spam option just because jumping costs nothing).
	-- Kept as a core field rather than moved into MovementState -- unlike Dash/Slide/Sprint, Movement.
	-- lua never reads or writes this field at all; it's an attack-shaped cooldown structurally
	-- identical to basicAttackReadyAt/heavyAttackReadyAt above, just gating an airborne attack instead
	-- of a grounded one. Deliberately separate from basicAttackReadyAt/basicComboLanded -- an air slam
	-- is thrown directly via onSwingHitCandidate (never commitAndThrowAttack/startAttackSwing), so it
	-- never touches the grounded M1 combo's state either direction. Not on BotState/DummyState: bots
	-- never jump (no movement AI, see Types.TrainingBotWeights' Reposition comment) and a dummy never
	-- attacks.
	airSlamReadyAt: number,
	-- Per-move cooldown for the Move Creation System's CustomMove path (CombatSystem.
	-- ThrowCustomMove), keyed by MoveId rather than one fixed field per move the way
	-- basicAttackReadyAt/airSlamReadyAt are -- an authored move's own MoveDefinition.Cooldown has
	-- no fixed field to live in the way Basic/Heavy/AirSlam's do, since the set of MoveIds is open-
	-- ended and admin-authored rather than a small fixed roster known at compile time. Not on
	-- BotState/DummyState: bots never throw a custom move (only MoveEditorSystem.TestFireMove
	-- reaches ThrowCustomMove, always against the calling admin's own CombatState) and a dummy
	-- never attacks.
	customMoveReadyAt: { [string]: number },
	-- Whether the CURRENT airborne stretch originated from a genuine, deliberate jump input, as
	-- opposed to becoming airborne for an incidental reason -- DashPunch's own dash residue carrying
	-- the player off a ledge after the air-combo window already lapsed, ordinary knockback/hitstun,
	-- parry recoil, a finisher's own launch/ragdoll, or simply walking off a ledge with no jump input
	-- at all. isAirborneForAirSlam (CombatSystem.lua) used to treat Humanoid:GetState() == Jumping OR
	-- Freefall (or FloorMaterial == Air) as sufficient on its own to throw the standalone AirSlam
	-- ("Downslam") attack -- but Freefall/FloorMaterial==Air is true for EVERY one of those incidental
	-- cases too, not just a real jump, so a player who became airborne any of those other ways got a
	-- free Downslam on their very next Basic-attack press. This field is what actually distinguishes
	-- them: set true the instant the server-replicated Humanoid transitions INTO
	-- Enum.HumanoidStateType.Jumping (humanoidStateChangedConnection above, hooked in
	-- onCharacterAdded) -- the one HumanoidStateType transition Roblox's own character controller
	-- fires ONLY from a genuine jump request, never from external velocity/WalkSpeed-driven ground
	-- movement carrying a player off an edge (that transitions straight to Freefall, skipping Jumping
	-- entirely) and never from a ragdoll launch (PlatformStand blocks the Humanoid state machine from
	-- ever reaching Jumping while ragdolled). Cleared back to false the instant that same listener
	-- observes a transition to any state OTHER than Jumping/Freefall -- landed, ragdolled/Physics,
	-- held aloft, swimming, climbing, whatever -- so the flag only ever certifies the single unbroken
	-- stretch between "this player jumped" and "this player stopped being airborne for any reason,"
	-- never a second, later airborne stretch caused by something else entirely. Freefall itself is
	-- deliberately left untouched by that listener: it's both the natural continuation of an
	-- already-credited jump (ascent transitions Jumping -> Freefall on its own, mid-arc) AND the exact
	-- state produced by every incidental-airborne case above, which is fine precisely because this
	-- field was never set true for those in the first place. isAirborneForAirSlam now requires this
	-- field alongside its existing physical checks -- see that function's own header. Reset to false
	-- on every respawn (resetTransientCombatState) since a fresh spawn starts grounded with no jump in
	-- flight. Not on BotState/DummyState: bots never jump (no movement AI, see
	-- Types.TrainingBotWeights' Reposition comment) and a dummy never attacks.
	genuineJumpAirborne: boolean,
	-- Timestamp before which the player is "attacking" (windup+active+recovery of their current
	-- swing, set at throw time to now + Windup+Active+Recovery). This is the single global
	-- per-player commitment lock: no new attack, block, dash, or parry request is accepted while
	-- now < attackEndsAt, regardless of category -- a player mid-swing can't also start blocking or
	-- interrupt into an unrelated attack. Independent of basic/heavyAttackReadyAt, which gate
	-- *cooldown* (can be tuned longer than the swing itself); this gates *commitment* and is always
	-- code-enforced rather than assumed from tuning. handleDashRequest also sets this (to
	-- DashCommitmentSeconds, its own brief post-burst recovery) rather than inventing a parallel
	-- commitment field -- see that handler's own header for why.
	attackEndsAt: number,
	-- Which commitment-consuming action is currently active, set by the single shared mutator
	-- CombatSystem.lua's setActiveAction at the same call sites that already set attackEndsAt/a
	-- movement window. Structurally guarantees mutual exclusion between actions that share the
	-- attackEndsAt commitment lock but each keep their own window field (Dash's
	-- Movement.dashWindowExpiry, Slide's Movement.slideWindowExpiry) -- see CombatActionKind's own
	-- header for why this exists.
	activeActionKind: CombatActionKind,
	-- Feint (RequestFeint/CombatSystem.lua's handleFeintRequest, right-click): the two fields backing
	-- it. currentSwingWindupEndsAt is set to now + definition.WindupSeconds at the SAME throw sites
	-- that set attackEndsAt (commitAndThrowAttack, handleAirSlamRequest -- deliberately NOT
	-- handleDashRequest's DashPunch/DashHit branches, see handleFeintRequest's own header for why
	-- those stay out of scope) -- a Feint request is legal exactly while now < this timestamp, i.e.
	-- the swing is still telegraphing and hasn't gone active yet. swingCancelled is what actually
	-- stops the hitbox: set true by a successful Feint, read by startAttackSwing/throwStandaloneAttack's
	-- own IsStillValid closures (HitboxResolver.Update ends a swing the instant IsStillValid returns
	-- false, before its next sample) -- the same mechanism that already ends a swing on a mid-flight
	-- stun/posture-break, reused rather than teaching HitboxResolver a separate cancel concept. Reset
	-- (windup timestamp refreshed, cancelled flag cleared) at every fresh throw so a stale
	-- cancellation from a PREVIOUS swing can never carry over onto a new one.
	currentSwingWindupEndsAt: number,
	swingCancelled: boolean,
	-- comboIndex/comboExpiry are the throw-based combo counter for HEAVY attacks (wraps over the
	-- Heavy stages). The BASIC (M1) string splits WHICH STAGE ANIMATION plays from WHETHER THE
	-- FINISHER IS REACHABLE, deliberately two different counters:
	--   * basicSwingIndex is throw-based, exactly like Heavy's comboIndex -- it advances on every M1
	--     press, whiff or not, wrapping over the Basic stages (see selectAttackDefinition/
	--     advanceComboIndex, both already generic over isHeavy). This is what lets a player see/feel
	--     stage 2/3 of the string even while whiffing, instead of being stuck replaying stage 1 until
	--     something connects.
	--   * basicComboLanded stays landing-based -- it counts how many basic hits have connected in a
	--     row (0-3), and the next M1 becomes the Finisher once it reaches Constants.Combat.
	--     BasicComboLength - 1 landed hits. This is the ONE gate that still requires a connect (only a
	--     connect advances it -- see startAttackSwing's OnHit): the Finisher is a stun/launcher, so
	--     whiffing must never fast-track it, even now that whiffing DOES advance basicSwingIndex.
	-- Kept as two separate fields so mixing basic/heavy, or a whiff mid-string, can never
	-- cross-contaminate "what does the next swing look like" with "am I allowed to launch yet."
	comboIndex: number,
	comboExpiry: number,
	basicSwingIndex: number,
	basicComboLanded: number,
	basicComboExpiry: number,
	-- The finisher-ready value (basicComboLanded >= BasicComboLength - 1) sent to this player's client
	-- over Combat_ComboStateChanged only on a transition, so the client can suppress its jump on the
	-- 4th hit without a per-tick remote -- tracked by CombatSystem.lua's own finisherReadyNotifier
	-- (Shared/ChangeNotifier) rather than a `finisherReadySynced` field that used to live here; see
	-- inCombatUntil's own header for the full reasoning on why this moved to ChangeNotifier.
	--
	-- The "RootControlLocked" Humanoid Attribute (true while now < Vitals.ragdollExpiry or now <
	-- AirCombo.airComboChaseExpiry -- a finisher/DashPunch ragdoll or RagdollController.HoldAloft's
	-- rigid pin currently owns this player's own rootPart) is written only on a transition the same
	-- way, via CombatSystem.lua's rootControlLockedNotifier -- consumed client-side by
	-- Client/Camera/ShiftLockCamera.lua, which stops forcing this player's own rootPart rotation to
	-- camera yaw while the server is authoritatively driving that rotation itself.

	-- Which of Constants.Combat.Weapons this player currently fights with (RequestSwapWeapon /
	-- handleSwapWeaponRequest) -- selectAttackDefinition reads Basic/Heavy/Finisher stage arrays
	-- from Constants.Combat.Weapons[equippedWeaponId].Stages instead of a single flat table. Not on
	-- BotState/DummyState: bots stay on Constants.Combat.Weapons.Default permanently (see
	-- handleSwapWeaponRequest's own header for why bot weapon-switching is out of scope), and a
	-- dummy never attacks at all.
	equippedWeaponId: Types.WeaponId,
	-- Timestamp before which a new RequestSwapWeapon is rejected (Constants.Combat.Weapons.
	-- SwapCooldownSeconds) -- long enough that swap-spamming can't be used as an exploit or evasive
	-- tool, short enough to be a real mid-fight option.
	weaponSwapReadyAt: number,

	-- Input buffering: an attack request rejected ONLY for being too early (CooldownActive or
	-- AlreadyAttacking -- see handleAttackRequest) while every other gate was already satisfied is
	-- remembered here instead of being silently dropped, and thrown automatically once the gate
	-- that blocked it clears (onHeartbeat's buffer-flush check), as long as it's still within
	-- Constants.Combat.AttackInputBufferSeconds of the original press. Without this, a press landing
	-- a few frames before the previous swing's cooldown/commitment clears -- extremely easy to do
	-- with no animation to pace clicks against -- reads as "I have to click twice," not a
	-- deliberate rule. Every other gate (alive/stun/posture-broken/ragdoll/disarm) is re-checked
	-- again at flush time, since state can change during the buffered window (e.g. getting parried
	-- mid-buffer should cancel it, not force the attack through a fresh stun). nil = nothing
	-- buffered. Not on BotState/DummyState: bots decide their own timing in TrainingBotSystem's AI
	-- loop (no human reaction-time mismatch to smooth over), and a dummy never attacks.
	bufferedAttack: { IsHeavy: boolean, HoldingJump: boolean, ExpiresAt: number }?,

	-- Godmode/Frozen/SpeedMultiplier/Invisible (and the Flying/FlightCollide toggle) used to live
	-- here as CombatState fields -- moved to AdminActionSystem.lua's own AdminOverrideState (2026-07,
	-- Chief Architect's CombatSystem.lua decomposition audit): they're admin-only overrides, not
	-- combat-resolution state, and threading them through this type made every real combat code path
	-- (onHeartbeat, every resolveHit* function) carry fields irrelevant to 99.9% of players.
	-- CombatSystem.lua's own godmode check now reads the mirrored "Godmode" Humanoid Attribute
	-- directly (see resolveHitAgainstTarget's isGodmode helper) -- the exact pattern Movement.
	-- ComputeDesiredWalkSpeed already established for Frozen/SpeedMultiplier/Flying, just extended to
	-- the one admin field CombatSystem's own hit resolution needs to read.

	lastVitalsSyncTime: number,
	pendingKillerUserId: number?,

	Vitals: CombatVitalsState,
	Movement: MovementState,
	AirCombo: AirComboState,
}

-- A training dummy is a real hittable combat participant (swings resolve against it exactly like
-- a player -- arc/LOS/dedup all apply, posture break and death both work), just not a Player, so
-- it gets its own much simpler parallel state -- no parry/lock-on/combo, since it never
-- attacks, blocks, or parries. Deliberately NOT folded into CombatState: that type and every
-- function keyed off `Player` stays exactly as-is (respawn-safe, rate-limited, etc.); dummies are
-- purely additive. Only DevMenuSystem.lua can create one, via CombatSystem.SpawnTrainingDummy.
export type DummyState = {
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	spawnCFrame: CFrame,
	maxHealth: number,
	posture: number,
	maxPosture: number,
	postureBrokenExpiry: number,
	alive: boolean,
	deathConfirmed: boolean,
	humanoidDiedConnection: RBXScriptConnection?,
	-- Timestamp (os.clock()) at which a finisher-launched dummy is returned to its spawn point and
	-- healed, so it's a clean repeatable combo target (0 = not pending a reset). Set in
	-- HitResolution.Resolve to after the ragdoll recovers; acted on in onHeartbeat's dummy loop.
	ragdollResetAt: number,
}

-- A training bot is a real combat participant that actually fights -- unlike DummyState, it
-- carries almost the full CombatState feature set, mirrored here rather than reusing CombatState
-- itself since that type and every function keyed off it stays exactly as-is (dummies/bots are
-- purely additive). Deliberately no `lockOnTarget` field -- a bot only ever fights its one owner,
-- there's nothing to lock onto. `ownerPlayer` is who spawned it and the only Player it will ever
-- target or be targeted for.
export type BotState = {
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	spawnCFrame: CFrame,
	ownerPlayer: Player,
	humanoidDiedConnection: RBXScriptConnection?,

	maxHealth: number,
	posture: number,
	maxPosture: number,

	alive: boolean,
	blocking: boolean,
	deathConfirmed: boolean,

	parryWindowExpiry: number,
	parryCooldownExpiry: number,
	stunExpiry: number,
	postureBrokenExpiry: number,

	basicAttackReadyAt: number,
	heavyAttackReadyAt: number,
	attackEndsAt: number,
	comboIndex: number,
	comboExpiry: number,
	-- See CombatState.disarmedUntil's own comment -- a bot can throw Heavy attacks and get Parried
	-- by its owner exactly like a real opponent, so it needs the same disarm lockout.
	disarmedUntil: number,

	pendingKillerUserId: number?,
}

-- The air-combo target adapter (CombatSystem.lua's resolveHitAgainstTarget/DummyCombat.lua's
-- ResolveHit build one of these, AirCombo.lua's Apply consumes it) -- unifies a real player target
-- and a training-dummy target behind one shape so the air-combo state machine only needs to be
-- written once. Exported here (rather than kept local to whichever module currently owns the
-- applyAirCombo logic) since CombatTypes.lua is exactly where a type shared across Server/Combat/
-- siblings belongs -- see this file's own header.
--   - `player` is nil for a dummy (RagdollController's own calls already accept a nil Player for a
--     non-player body -- this just threads that through instead of duplicating each call twice).
--   - `clearBlocking`/`setAsAirComboTarget`/`clearAirComboTarget`/`isCurrentAirComboTarget` hide
--     which underlying field gets touched -- CombatState.blocking/airComboTarget for a player vs. a
--     no-op/CombatState.airComboDummyTarget for a dummy (DummyState itself has no `blocking` field
--     at all -- a dummy never blocks).
--   - `setHeldExpiry` (the DashPunch-start/continuation-hit hold) hides which timer gets pinned and
--     how -- CombatState.AirCombo.airComboHeldExpiry via math.max for a player (live-body: keeps
--     Motor6D/Humanoid control, stays Block/Parry-capable -- ACTION_GATES.HeldAloft exempts
--     BlockStart -- see that field's own header), a no-op for a dummy (AirCombo.Apply branches on
--     `player ~= nil` to decide live-body vs. ragdoll treatment in the first place, so a dummy's own
--     implementation is never actually called -- present only so the adapter table literal satisfies
--     this type under --!strict).
--   - `setRagdollExpiry` hides which timer field gets pinned for a GENUINE incapacitating ragdoll --
--     CombatState.Vitals.ragdollExpiry via math.max for a player, DummyState.ragdollResetAt via a
--     flat overwrite plus Constants.Debug.TrainingDummy.LaunchResetBufferSeconds for a dummy (a
--     dummy has no lockout to preserve, just a respawn timer, and needs the extra buffer so you see
--     it get up before it resets). Called by AirCombo.Apply's MaxHits slam finisher for EVERY target
--     regardless of player/dummy (the sequence-ending knockdown is a real ragdoll either way), and by
--     the dummy-only branch of DashPunch-start/continuation (a dummy has no live-body concept at all,
--     see setHeldExpiry above).
--   - `applyDamage` hides the slam-finisher's bonus-damage application -- godmode check +
--     kill-attribution + sendVitals for a player, a plain TakeDamage for a dummy (no godmode
--     concept, no vitals stream to sync).
--   - `onGroundSlam` (optional) fires the instant AirCombo.Apply's MaxHits branch calls
--     RagdollController.SlamToGround -- the ONE thing the landed hit's own Combat_FeedbackEvent
--     (already sent by resolveHitAgainstTarget/DummyCombat.ResolveHit before AirCombo.Apply even
--     runs, since reaching this branch at all requires finisherVariant == nil) structurally cannot
--     carry: which finisher variant the juggle just ended on. Without a SEPARATE signal, the
--     client-side ground-impact payoff (Client/FX/SlamImpactVFX.lua, driven off Types.
--     CombatFeedbackPayload.FinisherVariant == "Downslam") never fires for this slam specifically --
--     it already works for the M1 finisher's own Downslam and the standalone AirSlam attack, both of
--     which set FinisherVariant on their one natural feedback event. The player-target adapter
--     (CombatSystem.lua's resolveHitAgainstTarget) wires this to send that second, distinct
--     "GroundSlam"-kind event; the dummy-target adapter (DummyCombat.lua) leaves it nil -- a dummy
--     has no TargetUserId for SlamImpactVFX to resolve a character from, so there's no client-side
--     watch to trigger regardless (see that module's own header). The bool it's called with is
--     RagdollController.SlamToGround's own `immediateGroundImpact` return, threaded straight through
--     onto the GroundSlam feedback payload (Types.CombatFeedbackPayload.ImmediateGroundImpact) --
--     see that field's own header for why the client needs this told to it rather than inferred.
-- Player-vs-dummy is still the only two shapes this covers -- a hit against a bot target never
-- reaches the air-combo state machine at all (BotCombat.lua's ResolveHitAgainstBot doesn't call it;
-- bots never dash so can never be the ATTACKER side of an air combo either, per CombatState.
-- airComboTarget's own header).
export type AirComboTarget = {
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	-- nil for a dummy (no client of its own) -- forwarded straight into the RagdollController calls
	-- below, which already accept a nil Player for exactly this case. Also what AirCombo.Apply itself
	-- branches on to pick live-body-hold vs. ragdoll-and-launch treatment for this target.
	player: Player?,
	clearBlocking: () -> (),
	setHeldExpiry: (number) -> (),
	setRagdollExpiry: (number) -> (),
	isCurrentAirComboTarget: () -> boolean,
	setAsAirComboTarget: () -> (),
	clearAirComboTarget: () -> (),
	applyDamage: (number) -> (),
	onGroundSlam: ((boolean) -> ())?,
}

return {}
