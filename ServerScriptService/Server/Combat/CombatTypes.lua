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

-- Internal, mutable per-player state. Never returned directly to a caller -- CombatSystem.
-- GetCombatState returns a read-only Types.CombatSnapshot projection instead.
export type CombatState = {
	player: Player,
	character: Model?,
	humanoid: Humanoid?,
	rootPart: BasePart?,
	humanoidDiedConnection: RBXScriptConnection?,

	maxHealth: number,
	posture: number,
	maxPosture: number,

	alive: boolean,
	blocking: boolean,
	deathConfirmed: boolean,

	lockOnTarget: Player?,

	parryWindowExpiry: number,
	parryCooldownExpiry: number,
	stunExpiry: number,
	postureBrokenExpiry: number,
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
	-- request handler reads it) -- its first real consumer is the HUD's combat-state badge (see
	-- inCombatSynced below), a read-only presentation signal, not a rule.
	inCombatUntil: number,
	-- The InCombat value (now < inCombatUntil) last sent to this player's client over
	-- Combat_InCombatChanged. onHeartbeat compares the live value against this and only fires the
	-- remote on a transition, the same "sync bookkeeping flag, write only on change" shape as
	-- finisherReadySynced/rootControlLockedSynced above.
	inCombatSynced: boolean,
	-- Timestamp before which humanoid.WalkSpeed stays clipped to Constants.Combat.BaseWalkSpeed *
	-- HitSlowMultiplier after landing an unmitigated hit -- see onHeartbeat's restore check. Not
	-- used by DummyState/BotState: neither moves under its own WalkSpeed (a bot's position is
	-- driven directly, per onHeartbeat's bot loop), so the movement half of the hit reaction only
	-- applies to a real player's CombatState.
	hitSlowExpiry: number,

	-- Neutral-game movement (Movement.lua's handleSprintStart/Stop; Dash's own handleDashRequest).
	-- `sprinting` is a held intent flag (a raised WalkSpeed only actually applies when
	-- Movement.computeDesiredWalkSpeed allows it); dashWindowExpiry is the Dash WalkSpeed-burst
	-- window, dashCooldownExpiry gates the next Dash.
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
	-- rejects unless state.sprinting is already true. Not on BotState/DummyState, same as every other
	-- dash/sprint field on this type -- see Movement.lua's own header.
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
	-- Timestamp before which a new AirSlam throw is on cooldown (Constants.Combat.AirSlam.Cooldown,
	-- CombatSystem.lua's handleAirSlamRequest/throwAirSlam) -- the standalone "jump + M1" attack, own
	-- real cooldown for the same reason dashPunchReadyAt above has one (a move that hits hard AND
	-- launches can't be a free-spam option just because jumping costs nothing). Deliberately separate
	-- from basicAttackReadyAt/basicComboLanded -- an air slam is thrown directly via
	-- onSwingHitCandidate (never commitAndThrowAttack/startAttackSwing), so it never touches the
	-- grounded M1 combo's state either direction. Not on BotState/DummyState: bots never jump (no
	-- movement AI, see Types.TrainingBotWeights' Reposition comment) and a dummy never attacks.
	airSlamReadyAt: number,

	-- Timestamps (os.clock()) before which a new attack of that category is rejected. Set at throw
	-- time to now + the just-selected Types.HitboxAttackDefinition's Cooldown -- replaces a flat
	-- per-category cooldown constant now that cooldown is per combo-stage (Constants.Combat.
	-- Hitboxes.Basic/Heavy).
	basicAttackReadyAt: number,
	heavyAttackReadyAt: number,
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
	-- attackEndsAt commitment lock but each keep their own window field (Dash's dashWindowExpiry,
	-- Slide's slideWindowExpiry) -- see CombatActionKind's own header for why this exists.
	activeActionKind: CombatActionKind,
	-- Feint (RequestFeint/CombatSystem.lua's handleFeintRequest, right-click): the two fields backing
	-- it. currentSwingWindupEndsAt is set to now + definition.WindupSeconds at the SAME throw sites
	-- that set attackEndsAt (commitAndThrowAttack, handleAirSlamRequest -- deliberately NOT
	-- handleDashRequest's DashPunch/DashHit branches, see handleFeintRequest's own header for why
	-- those stay out of scope) -- a Feint request is legal exactly while now < this timestamp, i.e.
	-- the swing is still telegraphing and hasn't gone active yet. swingCancelled is what actually
	-- stops the hitbox: set true by a successful Feint, read by startAttackSwing/throwAirSlam's own
	-- IsStillValid closures (HitboxResolver.Update ends a swing the instant IsStillValid returns
	-- false, before its next sample) -- the same mechanism that already ends a swing on a mid-flight
	-- stun/posture-break, reused rather than teaching HitboxResolver a separate cancel concept. Reset
	-- (windup timestamp refreshed, cancelled flag cleared) at every fresh throw so a stale
	-- cancellation from a PREVIOUS swing can never carry over onto a new one.
	currentSwingWindupEndsAt: number,
	swingCancelled: boolean,
	-- comboIndex/comboExpiry are the throw-based combo counter for HEAVY attacks (wraps over the
	-- Heavy stages). The BASIC (M1) combo is separate and landing-based: basicComboLanded counts how
	-- many basic hits have connected in a row (0-3), and the next M1 becomes the Finisher once it
	-- reaches Constants.Combat.BasicComboLength - 1 landed hits. Kept apart from comboIndex so a
	-- whiff can't advance the basic string (only a connect does -- see startAttackSwing's OnHit) and
	-- so mixing basic/heavy doesn't cross-contaminate the two counters.
	comboIndex: number,
	comboExpiry: number,
	basicComboLanded: number,
	basicComboExpiry: number,
	-- The finisher-ready value (basicComboLanded >= BasicComboLength - 1) last sent to this player's
	-- client over Combat_ComboStateChanged. onHeartbeat compares the live value against this and only
	-- fires the remote on a transition, so the client can suppress its jump on the 4th hit without a
	-- per-tick remote. Purely a sync bookkeeping flag; never gates any server-side combat decision.
	finisherReadySynced: boolean,
	-- The "RootControlLocked" Humanoid Attribute value last written for this player -- true while
	-- now < ragdollExpiry (a finisher/DashPunch ragdoll is tumbling this player's own body) OR
	-- now < airComboChaseExpiry (RagdollController.HoldAloft has a rigid AlignOrientation/
	-- AlignPosition pin on this player as the air-combo attacker). onHeartbeat compares the live
	-- value against this and only writes the Attribute on a transition, same "sync bookkeeping
	-- flag, write only on change" shape as finisherReadySynced just above -- see syncRootControlLocked.
	-- Consumed client-side by Client/Camera/ShiftLockCamera.lua, which stops forcing this player's
	-- own rootPart rotation to camera yaw while the server is authoritatively driving that rotation
	-- itself -- without this, shift-lock's per-frame CFrame write fought the server's hold/ragdoll on
	-- the OWNING client's own screen only (remote viewers never run shift-lock for someone else's
	-- character), which is why the attacker's own view of an air-combo flight looked different from
	-- how it looked to everyone else. An Attribute, not a remote, matching the existing "Flying"
	-- (FlightController.lua) / "BonusWalkSpeed" (Movement.lua) pattern for server-truth the local
	-- client's own presentation layer needs to react to.
	rootControlLockedSynced: boolean,
	-- Timestamp before which this player is ragdolled by a finisher (uppercut/downslam) and cannot
	-- act -- gates handleAttackRequest/handleBlockStart/handleDashRequest/handleSprintStart the same
	-- way stunExpiry does. Set when a finisher lands (HitResolution.Resolve); the physical recovery
	-- is owned by Server/Combat/RagdollController.lua on the same timer, so the lockout and the
	-- stand-up stay in lockstep. Not on DummyState/BotState: a dummy has no actions to lock out (it's
	-- ragdolled physically only), and bot targets are never ragdolled (their position is driven).
	ragdollExpiry: number,
	-- Timestamp before which this player cannot throw a Basic or Heavy attack -- set when their
	-- Heavy attack gets Parried (HitResolution.ShouldDisarm/ApplyDisarm, called from every
	-- resolveHit* function in CombatSystem.lua). Deliberately does NOT block Block/Parry/Dash/
	-- Sprint/LockOn -- a disarmed player isn't helpless, just can't deal damage, which is what
	-- keeps this from violating gameplay-philosophy.md's anti-lockout rule (a short, fixed,
	-- always-recoverable window, same shape as postureBrokenExpiry, not an interactive "find your
	-- weapon" punishment). On BotState too: a bot can throw Heavy attacks and get Parried by its
	-- owner exactly like a real opponent. Not on DummyState: a dummy never attacks.
	disarmedUntil: number,

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

	-- Air combo -- CombatSystem.lua's throwDashPunch launches the target AND this player into the
	-- air together; a landed M1 Basic hit against the SAME target while the sequence is still open
	-- continues the juggle (re-launches the target, extends the window) instead of throwing a fresh
	-- one. airComboTarget is who this player is currently juggling (nil = no active sequence);
	-- airComboHitCount is how many hits have landed so far, including the DashPunch launcher itself
	-- (capped at Constants.Combat.AirCombo.MaxHits -- the last hit at the cap slams the target down
	-- instead of re-launching, see continueAirCombo); airComboExpiry is the timestamp by which the
	-- NEXT hit must land against airComboTarget or the sequence lapses (the target just falls and
	-- ragdoll-recovers normally, same as an ordinary Uppercut). Only meaningful on a real player's
	-- CombatState -- bots never dash (Movement.lua's own header: bots never touch Dash/Sprint
	-- fields), so a bot can never be the ATTACKER side of an air combo.
	airComboTarget: Player?,
	-- Same sequence, against a training dummy instead of a real player -- a solo-testable version
	-- of the same mechanic (CombatSystem.lua's applyAirComboAgainstDummy), tracked on its own field
	-- rather than widening airComboTarget's type, since a Model (dummyStates lookup) and a Player
	-- (combatStates lookup) need genuinely different state resolution at the call site. A player is
	-- only ever mid-sequence against ONE of these two at a time in practice, but both exist so
	-- neither call site needs to guess which kind of target the other one meant.
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
	-- applyAirCombo/applyAirComboAgainstDummy, zeroed alongside every RagdollController.ClearHold
	-- call on their rootPart). Network ownership alone doesn't stop this player's own held WASD from
	-- commanding Humanoid movement on the server -- that fight against the hold's pull is exactly
	-- what read as "we aren't floating next to each other" (see HoldAloft's own header); this field
	-- is what actually silences that competing input instead of just aspiring to.
	airComboChaseExpiry: number,
	-- Air-tech escape (double-tap-W while held in someone ELSE's air combo -- see CombatSystem.lua's
	-- handleAirTechRequest). Opened for a short window at every point THIS player is launched/
	-- re-launched as an air-combo target (applyAirCombo's own DashPunch-start and continuation
	-- branches, via the AirComboTarget adapter's openAirTechWindow), closed on consumption or lapse.
	-- 0 = no window open.
	airTechWindowExpiry: number,
	-- Cooldown after a MISTIMED air-tech attempt (a request made while genuinely juggled, but outside
	-- airTechWindowExpiry) -- prevents spamming the remote hoping to get lucky. NOT set for a request
	-- made while not juggled at all (nothing to spam-prevent there -- see handleAirTechRequest). Also
	-- set on a SUCCESSFUL tech, so escaping isn't a zero-cost, infinitely-repeatable counter to the
	-- attacker's own DashPunch/chase investment.
	airTechReadyAt: number,
	-- Timestamp until which a SUCCESSFULLY-teched player stays suspended alongside the attacker --
	-- un-ragdolled (conscious, rigid-held, same live-body treatment RagdollController.HoldAloft
	-- already gives the attacker) but not yet dropped back to normal footing. While active: Block is
	-- freely available (ragdollExpiry was already cleared by the tech, and this state never sets it),
	-- and a Basic-attack press redirects to a one-shot counter-punch (handleAttackRequest's own
	-- interception, mirroring how an ordinary airborne press redirects to AirSlam) instead of the
	-- grounded M1 string -- gated on the attacker NOT currently mid-swing ("only if the attacker
	-- isn't hitting them"). Ends on: a landed counter-punch (any outcome), a normal hit resolving
	-- against this player from anyone (resolveHitAgainstTarget), this window elapsing unresolved
	-- (onHeartbeat), or either side dying/leaving -- see endSuspendedAirComboExchange. 0 = not
	-- suspended. Not on BotState/DummyState -- a bot can't be juggled (it's never the air-combo
	-- attacker's target in the relevant sense) and a dummy never blocks/counter-punches.
	airComboSuspendedUntil: number,
	-- Who this player is suspended alongside, while airComboSuspendedUntil is active -- needed
	-- because a successful tech clears the ATTACKER's own airComboTarget (ending their free-combo
	-- privilege), so there is no longer a reverse pointer from the attacker's side once the exchange
	-- becomes mutual. nil whenever airComboSuspendedUntil is 0.
	airComboSuspendedWithAttacker: Player?,

	-- Admin-only invulnerability (DevMenuSystem.lua's SetGodmode, gated behind
	-- Constants.Debug.DevMenu's whitelist same as every other dev action) -- when true,
	-- resolveHitAgainstTarget/resolveHitFromBotAgainstPlayer zero the damage/posture a landing hit
	-- would otherwise apply to THIS player, but the swing still resolves/connects normally
	-- otherwise (feedback, hit reactions, etc. all still fire) -- a debug toggle, not a new
	-- combat-legal defense layer, so it deliberately isn't threaded through
	-- HitResolution.ClassifyDefense alongside Parry/Block.
	godmode: boolean,

	-- Saved Humanoid.AutoRotate value from before SetPlayerFlying quieted the controller for
	-- Collide mode's physics constraints (see that function's own header) -- nil until flight has
	-- been toggled at least once for this life; restored verbatim on flight-off rather than assuming
	-- true.
	savedFlightAutoRotate: boolean?,

	-- Admin-only movement lock (DevMenuSystem.lua's SetTargetFrozen) -- deliberately survives
	-- respawn (onCharacterAdded re-seeds the mirrored "Frozen" Attribute), same "admin-granted
	-- state, not a per-life transient" precedent as godmode above. The actual WalkSpeed-to-0 effect
	-- is Movement.ComputeDesiredWalkSpeed reading the Attribute directly (same shape as Flying), not
	-- this field -- this field exists purely so onCharacterAdded knows whether to re-seed that
	-- Attribute (and re-zero JumpPower) onto a fresh Humanoid instance.
	frozen: boolean,
	-- Humanoid.JumpPower captured the moment Frozen flips true, so unfreezing restores whatever was
	-- actually in effect rather than assuming a hardcoded default -- nil until frozen has been
	-- toggled at least once for this life, same shape as savedFlightAutoRotate above.
	savedJumpPower: number?,

	-- Admin-only WalkSpeed multiplier (DevMenuSystem.lua's SetTargetSpeedMultiplier) -- mirrored
	-- onto a "SpeedMultiplier" Humanoid Attribute that Movement.ComputeDesiredWalkSpeed reads as a
	-- scale on `base`, before Dash/Slide/Sprint's own multipliers apply on top -- same "per-player
	-- Humanoid Attribute" shape BonusWalkSpeed already uses. This field is the respawn-persistence
	-- record (same reasoning as frozen above); the real gameplay read is the Attribute. Defaults to
	-- 1 (no change).
	speedMultiplier: number,

	-- Admin-only invisibility (DevMenuSystem.lua's SetTargetInvisible) -- CombatSystem.
	-- SetPlayerInvisible applies Transparency directly to every BasePart/Decal of the character;
	-- this field is what onCharacterAdded re-checks to re-apply that to a FRESH character after a
	-- respawn (a Humanoid Attribute mirror exists too, purely for DevMenuClient's live UI, but the
	-- character-destroying respawn is exactly why this needs its own persisted field, not just an
	-- Attribute read).
	invisible: boolean,

	lastVitalsSyncTime: number,
	pendingKillerUserId: number?,
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

return {}
