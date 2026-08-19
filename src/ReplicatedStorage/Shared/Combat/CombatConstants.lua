--!strict
--[[
	CombatConstants.lua

	Owns: the hand-authored combat content and physics-feel numbers every weapon/finisher/dash/air
	attack in the game is built from -- MaxHealth/MaxPosture and block mitigation, the Basic/Heavy/
	Finisher move catalog per weapon (Weapons), the three standalone attacks (DashPunch/DashHit/
	AirSlam), the air-combo juggle window (AirCombo), finisher/ragdoll launch physics (Finisher/
	Ragdoll), and the wired-but-unauthored animation/sound registrations (AnimationIds/Sound) that go
	with all of it. Extracted from Shared/Constants.lua (formerly Constants.Combat) for two reasons,
	not one:

	  * IT IS THE MOVE CREATION SYSTEM'S OWN LIVE DATA, not settled canon. Server/Combat/
	    DefaultMoveRegistry.lua's ApplyEdit/Reset mutate Weapons[...].Stages/DashPunch/DashHit/AirSlam
	    directly, BY REFERENCE, from the Move Editor's live admin remotes -- so this table is read and
	    rewritten by a real system at runtime, in a live server, not just hand-edited between deploys.
	    A module named "Constants" holding something a running server rewrites is exactly the surprise
	    docs/architecture/2026-08-audit.md section 5's "Constants facade/replication split" finding
	    (3.4) called out.
	  * IT MATCHES THE PRECEDENT THE REST OF COMBAT ALREADY SET. AttackConstants.lua/DamageConstants.lua/
	    DefenseConstants.lua/HitboxEngineConstants.lua each already left Shared/Constants.lua as their
	    own standalone module, specifically so each layer "is a module, and a module that can be added
	    or removed without editing the game's central constants table is the concrete form of that
	    claim" (AttackConstants.lua's own header). This was the one remaining piece of the pre-rewrite
	    CombatSystem.lua's own config that hadn't followed suit -- not overlooked, just not forced until
	    DefaultMoveRegistry.lua's live-tuning need made the runtime-mutation problem concrete.

	Does not own: the Attack layer's cross-move relationship tunables (AttackConstants.lua), hitstun/
	combo-window length (DamageConstants.lua), stagger/parry (DefenseConstants.lua), or contact
	detection (HitboxEngineConstants.lua) -- see each of those files' own "Does not own" for why a
	per-move number never lives there. What IS here is precisely the per-move content those four files
	all point at instead of restating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

-- DashPunch's own Windup/Active/Recovery seconds, factored out to local variables so
-- DashFrontCommitmentSeconds (below, in the main CombatConstants table) can be DERIVED from
-- these instead of hand-duplicating their sum -- a Lua table constructor can't reference its own
-- other keys, hence the locals rather than just pointing at CombatConstants.DashPunch.*. Before
-- this, DashFrontCommitmentSeconds was a separately-typed literal (0.45) that had to be manually
-- kept equal to WindupSeconds+ActiveSeconds+RecoverySeconds every time any of the three changed --
-- exactly the kind of duplicated tunable engineering-standards.md's "one source of truth per
-- value" exists to prevent. Retuning DashPunch's timing now automatically keeps the front-dash
-- commitment lock in sync -- no separate number to remember to update.
-- Windup/Active dialed in via the (since moved into the Move Editor's "Default" moves section)
-- live attack tuner (Server/Combat/DefaultMoveRegistry.lua) and copied back here as the new file
-- defaults -- Windup=0.4 means the punch
-- now visibly winds up for a beat AFTER the front-lunge movement burst itself has already finished
-- (DashFrontDurationSeconds is still 0.28, shorter than this Windup), rather than the hitbox
-- riding along for virtually the whole dash the way the original 0.02/0.26 split did. Recovery
-- wasn't part of that live-tuning pass and is left at its prior value.
local DashPunchWindupSeconds = 0.4
local DashPunchActiveSeconds = 0.2
local DashPunchRecoverySeconds = 0.17

-- DashHit's own timing, same "locals so a derived commitment constant can reference them" reason
-- as DashPunch's own three above -- see DashHitCommitmentSeconds' own header. DashHit is the
-- SEPARATE, lighter attack every plain forward dash throws (handleDashRequest) -- distinct from
-- DashPunch, which only throws on a genuine double-tap-forward and additionally opens the air
-- combo. Windup covers most of the dash's travel (so the hitbox doesn't appear before the dash has
-- actually closed any distance), Active is a brief window right at the tail -- "a hitbox spawns at
-- the end of the attack" -- and Recovery is short, matching a plain dash's own low-commitment feel.
local DashHitWindupSeconds = 0.350
local DashHitActiveSeconds = 0.10
local DashHitRecoverySeconds = 0.08

-- Shared Offset for DashPunch, DashHit, AND AirSlam -- one local so retuning it can't let the
-- three drift out of sync with each other. All three sample the hitbox off the attacker's own hand
-- (HitboxResolver's AttackerTrackedPart, resolved by CombatSystem.lua's resolveAttackHandPart)
-- rather than a fixed offset from the root part's center.
--
-- Was CFrame.new(0, 0, -1) paired with a 7-stud-deep box (half-reach 3.5): that undersized nudge
-- left the box's BACK half sitting 2.5 studs BEHIND the hand -- i.e. bleeding back through the
-- attacker's own torso and out the far side, since the hand itself sits barely forward of the root
-- at all (mostly offset sideways, not forward). Read (correctly) as "the hitbox spawns on my own
-- character instead of in front of it." The box's front edge (the actual usable reach) was fine at
-- 4.5 studs forward of the hand -- only the rear half was broken -- so this fix re-derives the
-- offset to keep that SAME 4.5-stud front reach while pulling the back edge up to just barely in
-- front of the hand (-0.25, matching the Weapons hitboxes' own front-loaded convention below). Paired
-- with each definition's Size.Z shrinking from 7 to 4.25 (half-reach 2.125) to match -- the box is
-- now front-loaded instead of hand-centered. A tuning number per combat-philosophy.md's Tuning
-- process -- adjust freely after a playtest (MoveRegistryManager's own CLAMP_MIN/MAX_OFFSET_STUDS,
-- reused by Server/Combat/DefaultMoveRegistry.lua's Validate-backed ApplyEdit, already cover a much
-- wider range than this for the Move Editor's live Default-move tuner).
local HandTrackedOffset = CFrame.new(0, 0, -2.375)

-- CombatSystem's first-pass technical tunables (software-architecture.md's CombatSystem
-- ownership row; combat-philosophy.md for the Lock-on/Block/Parry/Posture feel these numbers
-- serve). These are engineering defaults chosen to make the state machine work correctly, NOT a
-- balance pass -- per combat-philosophy.md's Tuning process, numeric values here can move freely
-- without design ceremony. What's NOT free to move without flagging it as a design decision: the
-- systems these numbers belong to (lock-on, block/parry/posture) -- see that doc's "Established
-- systems" list.
local CombatConstants = {
	-- Vitals. Health and Posture are the game's only two vitals -- Stamina was removed (the Sekiro-
	-- grade reference point in combat-philosophy.md has no stamina; posture, not stamina, is the
	-- resource that turns sustained pressure into an opening). Actions are gated by cooldowns +
	-- the attackEndsAt commitment lock, and posture, not by a stamina budget.
	MaxHealth = 100,
	MaxPosture = 100,

	-- Mitigation while actively blocking: multiplies incoming health damage (lower = safer).
	-- Posture is left at 1.0 (neutral) deliberately -- an earlier 1.5x here made a routine 4-hit
	-- combo posture-break a blocking defender almost exactly at the combo's end (guaranteed
	-- guard-break followed by PostureBreakDuration's fully-exposed window, erasing the HP savings
	-- block was supposed to provide). Block should never be strictly worse than not blocking; if a
	-- posture *risk* for blocking turns out to be wanted after playtesting, revisit with a small
	-- value like 1.1 rather than reintroducing 1.5.
	BlockDamageMultiplier = 0.25,
	BlockPostureMultiplier = 1.0,

	-- THE PARRY/BLOCK CONFIG THAT USED TO LIVE HERE HAS MOVED, and was not merely deleted.
	--
	-- ParryWindowSeconds/ParryCooldownSeconds/ParryPunishPostureDamage/ParryPingCompensationMaxSeconds/
	-- GuardOpenSeconds/GuardResetSeconds were config for the deleted CombatSystem's parry. Every one of
	-- them is now owned by Shared/Defense/DefenseConstants.lua, or by the animation asset:
	--
	--   * The parry WINDOW is no longer a constant anywhere. It comes from ParryWindowOpen/
	--     ParryWindowClose markers authored on the parry clip (Shared/Defense/ParryWindows.lua), so
	--     retiming a parry is retiming the animation and nothing else.
	--   * The ping refund survives as DefenseConstants.Parry.PingCompensationMaxSeconds, at the same
	--     0.12 -- it is a latency correction, not a window length, so it is still a constant.
	--   * The parried attacker's punish is DefenseConstants.Stagger.DurationSeconds. Note it is 1.5s
	--     where GuardOpenSeconds was 0.6 -- and that 0.6 was DERIVED, not guessed: sized to cover
	--     reaction plus one-way latency plus the slowest weapon's own windup (Primary Basic1, 0.31,
	--     still live below) so the parrier got exactly ONE guaranteed follow-up, with a hard upper
	--     bound near 0.75 past which a Secondary user's second swing also lands inside the window.
	--     The derivation is recorded here because the constant that carried it is gone.
	--   * The anti-turtle cost is DefenseConstants.Parry.MinUnguardedSeconds, at the same 0.3.
	--   * The parry's REWARD is guard rather than posture damage (DefenseConstants.Guard.ParryRestore);
	--     nothing in the Defense System applies damage of any kind.
	--
	-- Left as a pointer rather than as dead fields, because orphaned config reads as live and gets
	-- retuned by someone who then cannot find what their change did.

	-- How long a combo chain (consecutive attacks within this window of each other) stays alive
	-- before resetting to stage 1. Per-stage timing/damage/cooldown now live in Hitboxes.Basic/
	-- Heavy below, not here -- see that table's header for why. This is the BASIC finisher combo's
	-- window (CombatState.basicComboExpiry) and the client's post-attack jump lockout; the Heavy
	-- throw-combo has its own window below -- see HeavyComboResetSeconds for why they had to split.
	ComboResetSeconds = 1.5,
	-- MaxComboStacks (was 5) removed: CombatSystem.lua's advanceComboIndex now wraps the throw-combo
	-- counter over the weapon's own authored stage count instead of clamping it at a fixed ceiling
	-- unrelated to that count. See that function's own header for why the clamp was a stage lockout
	-- rather than a bound.

	-- HeavyComboResetSeconds/BasicComboLength/AttackInputBufferSeconds/Feint/Prediction (combo timing,
	-- input buffering, Feint, and client-side action-start prediction) were removed alongside the rest
	-- of the combat system -- every reader of these (CombatSystem.lua, PredictionMirror.lua,
	-- CombatClient.lua's own predict/rollback path) is gone. Server/Combat/Movement.lua and
	-- Server/Combat/DefaultMoveRegistry.lua, the two Combat/ modules kept on disk, read neither.

	-- Finisher physics (Server/Combat/RagdollController.lua applies these; CombatSystem.lua picks the
	-- variant at the 4th hit). The finisher's damage/reach/timing are the Hitboxes.Finisher swing
	-- below; THIS table is only the knockback each variant applies to a target the finisher lands on
	-- cleanly. A blocked finisher deals its (heavy) posture damage but never launches -- guarding is
	-- the counter, per combat-philosophy.md's "no true unblockable." Variant is chosen server-side
	-- (HitResolution.SelectFinisherVariant): holding space -> Uppercut; else -> Normal (a grounded
	-- final hit with no launch, so the input is never dead). Downslam is NOT chosen from this path
	-- anymore -- it used to be the "airborne, not holding space" branch here, but that's now fully
	-- superseded by the standalone AirSlam attack below (jump + M1 at any time, no combo required):
	-- since AirSlam intercepts every Basic-attack press made while airborne before the M1 combo/
	-- finisher logic ever runs, the M1 finisher can only ever be thrown while grounded, so the
	-- airborne branch could never fire again and was removed as dead code. Downslam's own knockback
	-- profile below is unchanged -- it's just invoked by AirSlam now instead. First-pass technical
	-- values, free to tune.
	Finisher = {
		Uppercut = {
			-- Launch speed (studs/sec) applied to the target, then ragdolled for the window below.
			-- 90 was vÂ² = 2gh territory (~20 stud peak height, absurdly high for a normal Humanoid) --
			-- 55 peaks around 7-8 studs, still a dramatic launch without leaving the screen.
			LaunchUpVelocity = 55,
			-- Horizontal component, away from the attacker (RagdollController.LaunchAndRagdoll
			-- computes the direction from the attacker's rootPart to the target's) -- an UPPERCUT, so
			-- this stays small and mostly-vertical is the point; it's here only to keep the target from
			-- dropping back down in the exact spot it launched from, not to send it flying backward.
			-- 35 was way too much horizontal carry over ~2.5s of hangtime -- dropped hard.
			LaunchHorizontalVelocity = 8,
			-- Angular velocity (rad/sec) applied around the horizontal axis perpendicular to the
			-- launch direction, biasing the ragdoll's natural tumble backward so it's very likely to
			-- come down on its back rather than a random/face-down landing -- a bias, not a forced
			-- landing snap (RagdollController deliberately never CFrame-snaps a ballsocket-jointed
			-- ragdoll; see SlamToGround's own comment on why that reads as a teleport jerk).
			LaunchBackwardSpin = 6,
			RagdollSeconds = 2.5,
		},
		-- Hard downward launch that drives an airborne target back into the floor, with a briefer
		-- knockdown than the uppercut (a slam ends on the ground, it isn't a long airborne float).
		-- Consumed today by HitResolution.ApplyFinisherPhysics's "Downslam" branch -- the standalone
		-- AirSlam attack (CombatConstants.AirSlam) always throws with FinisherVariant = "Downslam",
		-- reusing this exact knockback profile rather than a duplicate one. See this table's own
		-- header for why the M1 finisher itself no longer produces this variant.
		Downslam = {
			SlamDownVelocity = 140,
			KnockdownSeconds = 1.25,
			-- Angular velocity (rad/sec) biasing the ragdoll's tumble face-first into the ground, so a
			-- downslam reads as a genuine face-plant instead of a random/back-first drop -- the
			-- downward-launch counterpart of Uppercut's own LaunchBackwardSpin above (Server/Combat/
			-- RagdollController.SlamToGround applies this the same way LaunchAndRagdoll applies
			-- LaunchBackwardSpin: a bias on the ragdoll's angular velocity at launch, never a forced
			-- CFrame snap -- see that function's own header for why a snap is off the table entirely
			-- for a ballsocket-jointed ragdoll). Tuned noticeably higher than LaunchBackwardSpin (6):
			-- Uppercut's tumble has the whole ~2.5s of RagdollSeconds hangtime to settle into its
			-- backward bias before landing, where a downslam's SlamDownVelocity (140 studs/s) drives
			-- the target into the floor almost immediately -- the rotation needs to develop much
			-- faster to read as a deliberate pitch rather than a body that was still mid-tumble when
			-- it hit.
			FaceDownSpin = 9,
		},
		Normal = {
			-- Grounded, not holding space: no launch/ragdoll, just a heavier finishing blow -- extra
			-- hitstun on top of the swing's own damage/posture so the 4th hit still feels conclusive.
			--
			-- MUST stay meaningfully above CombatConstants.HitStunDuration (0.6) or this variant does
			-- nothing at all. resolveHitAgainstTarget applies it as
			-- `math.max(stunExpiry, now + ExtraStunSeconds)` AFTER the ordinary hit path has already set
			-- `stunExpiry = now + HitStunDuration` -- it's a FLOOR, not an addition. At the previous 0.6
			-- the two were identical, so the max was a no-op and a "Normal" finisher was mechanically a
			-- Basic3 that happened to deal more damage. That made the variant choice fake: holding jump
			-- for the Uppercut was unconditionally correct, since Uppercut bought a 2.5s ragdoll and
			-- Normal bought nothing.
			--
			-- 1.1 gives Normal +0.5s of lockout over an ordinary hit. Deliberately far short of
			-- Uppercut's 2.5s ragdoll, because the two variants buy different things and should trade
			-- off rather than rank: Uppercut removes more agency but launches the target away and ends
			-- your pressure, Normal keeps them grounded and in front of you. Stun (unlike ragdoll) does
			-- not gate BlockStart -- see ACTION_GATES -- so the target can still guard the follow-up,
			-- which is what keeps this inside "everything is defendable."
			ExtraStunSeconds = 1.1,
		},
	},

	-- Vulnerability windows. PostureBreakDuration is how long a posture-broken target stays fully
	-- exposed (posture pinned at 0, guard bypassed). StunDuration is the shorter lockout applied
	-- to an attacker who gets parried -- a separate concept from posture break, not a reuse of it.
	PostureBreakDuration = 3,
	StunDuration = 1,

	-- Universal hit reaction: a much lighter, symmetric version of the attacker-only parry punish
	-- above -- whichever side takes an unmitigated (non-blocked, non-parried) hit gets a real,
	-- felt interruption. Reuses the exact same stunExpiry gate StunDuration extends (via math.max,
	-- so it never shortens a harsher parry/posture-break lockout already in effect) plus a short
	-- movement clip. This ALSO gates Basic/Heavy/Dash/Slide/SwapWeapon (ACTION_GATES, same table
	-- as Basic/Heavy) -- eating a hit means you can't attack again or freely disengage for a
	-- moment. Previously 0.15s, which read as no lockout at all in practice -- shorter than a
	-- human's reaction time plus the network round trip, so by the time a real player's response
	-- reached the server the window had already cleared and every action went through as if
	-- nothing had happened. Previously retuned to roughly match a quick Basic1 swing's own
	-- WindupSeconds (0.31) -- since raised again to 0.6 (from 0.35) because that still wasn't
	-- enough to survive an actual COMBO: the real minimum gap between two consecutively landed
	-- hits is RecoverySeconds(stage N) + WindupSeconds(stage N+1), and the worst case across both
	-- weapons' full Basic->Finisher chains is 0.48s (Primary Basic3->Finisher: Recovery 0.20 +
	-- Finisher Windup 0.28), with Heavy's 2-stage wraparound (Heavy1->Heavy2: Recovery 0.35 + Windup
	-- 0.20 = 0.55) even higher. A 0.35s stun let it lapse mid-combo -- the victim's stun expired
	-- before the next hit could land, opening a real window to counter-attack/dash/slide out
	-- despite still being "in" a 4-hit combo. 0.6 clears every transition on both weapons with
	-- margin, while staying well below StunDuration (1, the parry-punish lockout) and
	-- PostureBreakDuration (3) so it isn't a disproportionate change outside combo either. One
	-- shared constant, not a second "combo-only" tunable -- the values aren't different enough in
	-- kind to justify a second number, and the existing math.max at the write site already
	-- guarantees a harsher pre-existing lockout is never shortened by this.
	--
	-- BlockStart is deliberately NOT in the gated-actions list above (see ACTION_GATES.BlockStart's
	-- own comment in CombatSystem.lua) -- direct playtest feedback was that being stun-locked out of
	-- even ATTEMPTING Block/Parry against combo hits 2-4 after eating hit 1 left zero counterplay,
	-- contradicting combat-philosophy.md's "real parry window" reference point. A stunned player can
	-- still raise Block/try to Parry (and still whiff on bad timing like any other parry); they just
	-- can't attack back or Dash/Slide/swap weapons away for free.
	HitStunDuration = 0.6,

	-- How long a player is considered "in combat" after their last real exchange with an opponent --
	-- refreshed (assigned forward, not math.max'd -- this is a coarser signal than the specific
	-- lockouts above, so a fresh trigger should always reset the full duration) only by an actual
	-- hit/parry/air-tech exchange against a real opponent (player or training bot), never by merely
	-- throwing a swing or opening Block -- see CombatState.inCombatUntil's own header for the full
	-- trigger list and why. Not tied to any single action's own timing (attackEndsAt, stunExpiry,
	-- etc.) -- this is a general-purpose "still fighting" signal any current or future system can
	-- read off Types.CombatSnapshot.InCombat, independent of what specific action caused it.
	InCombatDurationSeconds = 5,
	-- CombatSystem's own explicit baseline (Roblox's Humanoid default already happens to be 16,
	-- though this codebase no longer relies on that coincidence) -- CombatSystem now owns setting/
	-- restoring WalkSpeed so HitSlowMultiplier below has a known value to multiply and restore to.
	-- Lowered from 16 to 10 (retuned alongside DefaultBonusWalkSpeed below to land the default
	-- resting speed at 18, down from 24) -- tuning, not design, per combat-philosophy.md's Tuning
	-- process; every multiplier tier (Sprint/Dash, all computed off base+bonus in
	-- Movement.ComputeDesiredWalkSpeed) scales down proportionally with it.
	BaseWalkSpeed = 10,
	-- Additive speed bonus applied on top of BaseWalkSpeed via a "BonusWalkSpeed" Attribute on each
	-- player's own Humanoid (Movement.ComputeDesiredWalkSpeed reads it; onCharacterAdded seeds it at
	-- spawn) rather than a flat Constants number, per luau-coding-standards.md's Attribute-API
	-- convention for per-instance runtime data -- this is meant to be driven per-player later by
	-- race/bloodline stat systems (progression-systems.md), not stay a single global forever. For
	-- now every player just gets this same default (10 + 8 = 18 effective base), a flat first-pass
	-- speed bump -- tuning, not design, per combat-philosophy.md's Tuning process. Left at 8 (not
	-- retuned) when BaseWalkSpeed above dropped -- this placeholder's own value isn't the thing
	-- being retuned here, only the resulting default speed.
	DefaultBonusWalkSpeed = 8,
	-- The "can't just run away" factor: every unmitigated hit clips WalkSpeed to base * this
	-- multiplier for HitSlowDuration (Movement.ComputeDesiredWalkSpeed's hit-slow tier -- below
	-- dash, above sprint). 0.6/0.3s (was ~14.4 studs/sec off a 24 base, barely slower than a brisk
	-- walk) let a hit target just hold their sprint key and disengage immediately. 0.25/0.5s (~6
	-- studs/sec, a near-crawl for half a second) gives the attacker a real follow-up window without
	-- fully rooting the target in place -- tuning, not design, per combat-philosophy.md's Tuning
	-- process.
	HitSlowMultiplier = 0.25,
	HitSlowDuration = 0.5,

	-- The MoveDirection magnitude below which there's no meaningful held movement input -- one shared
	-- threshold for every "is this character actually being steered right now" check in the codebase.
	-- Was FOUR independently hand-typed 0.1 literals that had to agree by coincidence: this module's
	-- own ResolveDashDirection/IsMoving below (gates Slide's "must be genuinely moving" reject and
	-- picks which direction a Dash throws/animates as), and client-side in Client/FX/CombatAnimator.
	-- lua's own LOCOMOTION_THRESHOLD (resolveDashDirection's animation pick, and the Walking/Running
	-- loop eligibility evaluator) and Client/FX/MovementVFX.lua's own LOCOMOTION_THRESHOLD (the
	-- sprint-dust trickle's "moving" gate) -- Movement.IsMoving's own comment literally flagged its
	-- 0.1 as "the same 0.1 magnitude threshold ResolveDashDirection above already uses inline" before
	-- this field existed, which is exactly the kind of duplication-by-coincidence engineering-
	-- standards.md's one-source-of-truth rule exists to close: a deliberate retune of "what counts as
	-- movement" would otherwise require remembering all four sites instead of changing one number.
	MovementInputMagnitudeThreshold = 0.1,

	-- Float-safety "is this vector effectively zero" epsilon -- gates a .Unit call from ever running
	-- on a near-zero-magnitude vector (HitResolution.lua's arc/line-of-sight checks, CombatSystem.
	-- lua's bot-facing update). Distinct from MinDirectionMagnitude below -- this is a pure
	-- floating-point-safety guard, not a "meaningfully non-zero direction" gameplay threshold.
	ZeroVectorEpsilon = 1e-3,
	-- "Is this horizontal direction meaningfully non-zero" threshold (RagdollController.lua's
	-- LaunchAndRagdoll) -- larger than ZeroVectorEpsilon above on purpose, a different concept at a
	-- different call site, not the same number renamed.
	MinDirectionMagnitude = 0.01,

	-- Neutral-game movement tunables (CombatSystem.lua's handleDashRequest for Dash). CombatSystem
	-- itself is gone (the combat rewrite deleted it) and nothing currently drives Dash's WalkSpeed
	-- burst through Server/Combat/Movement.ComputeDesiredWalkSpeed as a result -- see
	-- Server/Systems/RunSystem.lua's own boot-order comment in Main.server.lua for the confirmed
	-- "nothing wrote WalkSpeed at all" state this left behind.
	--
	-- Dash is a single proactive key (no i-frames, a low-stakes spacing tool meant to be used often
	-- in the neutral game): a quick WalkSpeed burst, limited by its own cooldown + commitment lock,
	-- not any resource (Stamina is gone).
	--
	-- SPRINT/THE RUN TIER USED TO LIVE HERE TOO (SprintSpeedMultiplier, SprintStage2*) and has fully
	-- moved out -- Shared/Run/RunConstants.lua now owns every run-stage number (a THREE-stage ladder,
	-- not the two-stage one these fields used to describe) and Server/Systems/RunSystem.lua is the
	-- live WalkSpeed authority for it. See RunConstants.lua's own "SEPARATE FROM CombatConstants ON
	-- PURPOSE" header for why. There is now exactly one place the run's stage numbers live; retuning
	-- the run never touches this file. (The fields that used to sit here were dead weight, not a
	-- second live copy: Server/Combat/Movement.lua's sprint functions that read them had no caller
	-- left once CombatSystem was deleted, same as Dash's burst above.)
	--
	-- Numbers here are first-pass technical tunables, free to move without design ceremony per
	-- combat-philosophy.md's Tuning process.
	DashSpeedMultiplier = 2.2,
	-- Seconds the Dash WalkSpeed burst is active -- a quick step, not a sustained evade.
	DashDurationSeconds = 0.22,
	-- Brief post-burst recovery, reusing the shared attackEndsAt commitment lock (slightly longer
	-- than DashDurationSeconds -- window > burst). No new attack, block, sprint-speed, or dash
	-- starts until it elapses.
	DashCommitmentSeconds = 0.28,
	-- A low-stakes cooldown: Dash is meant to be used often in the neutral game, not a high-value
	-- defensive cooldown. Still governs Front/Left/Right -- see DashBackCooldownSeconds below for
	-- why Back specifically does not share this pace anymore.
	DashCooldownSeconds = 0.8,

	-- Backward-specific Dash tuning (Movement.ApplyDash's isBackDash parameter, resolved from
	-- Movement.ResolveDashDirection == "Back"). Slide can no longer move backward at all
	-- (handleSlideRequest's own header), but Dash still can -- a neutral repositioning tool needs
	-- SOME way to create distance defensively. Playtest report, though: with Back sharing the exact
	-- same speed/cooldown as every other direction, pure backward-dash-spam became "the movement
	-- meta" on its own -- a single back-dash also covered noticeably more distance than felt
	-- intentional ("falls too far backwards"). Front/Left/Right are completely untouched by this --
	-- Dash's forward/lateral use (closing distance, sidestepping mid-fight) isn't the "running"
	-- problem this targets, only using it to retreat is. Same DashDurationSeconds/
	-- DashCommitmentSeconds as every other non-front direction -- only the speed and the cooldown
	-- differ, so recovery/commitment feel stays consistent across directions.
	-- Lower than DashSpeedMultiplier (2.2) -- same burst duration, shorter distance covered.
	DashBackSpeedMultiplier = 1.5,
	-- Double DashCooldownSeconds -- a deliberate, occasional defensive option again, not a
	-- spammable retreat (mirrors the reasoning SlideCooldownSeconds already documents for Slide).
	DashBackCooldownSeconds = 1.6,

	-- A Dash resolved as "Front" (Movement.ResolveDashDirection, mirrored client-side in
	-- CombatAnimator.lua for the DashFront clip) AND reported as a double-tap
	-- (CombatSystem.lua's handleDashRequest -- see that function's own header for the client-trust
	-- tier this hint uses, and why the real safety net is DashPunch.Cooldown below, not verifying
	-- the tap itself) is a lunging punch attempt, not a plain reposition -- it travels slightly
	-- farther than a Back/Left/Right dash and throws the DashPunch hitbox below (once
	-- DashPunch.Cooldown also clears), timed to land right as the burst ends.
	DashFrontDurationSeconds = 0.28,
	-- Derived from DashPunch's own WindupSeconds+ActiveSeconds+RecoverySeconds (the locals just
	-- above this table) rather than a hand-typed duplicate -- a front dash's commitment lock has to
	-- span the whole punch, not just the movement burst, or the player could act again mid-swing.
	-- See those locals' own header for the sync bug this replaced.
	DashFrontCommitmentSeconds = DashPunchWindupSeconds + DashPunchActiveSeconds + DashPunchRecoverySeconds,
	-- Same derivation as DashFrontCommitmentSeconds just above, for DashHit -- the plain forward
	-- dash's own (lighter, non-launching) attack. Unlike DashPunch, DashHit does NOT get its own
	-- longer movement burst (handleDashRequest still applies the plain DashDurationSeconds/
	-- DashSpeedMultiplier for it -- it's not a bigger lunge, just an ordinary dash that happens to
	-- leave a hit at the end), so only the commitment lock needs a dedicated value here, long enough
	-- to cover the hitbox's own active+recovery tail past the plain DashCommitmentSeconds above.
	DashHitCommitmentSeconds = DashHitWindupSeconds + DashHitActiveSeconds + DashHitRecoverySeconds,

	-- Slide: chained off Sprint (Movement.IsMoving must also be true) -- a bigger, committed WalkSpeed
	-- burst than Dash, built the exact same way (Movement.ApplySlide mirrors Movement.ApplyDash). No
	-- hitbox, no damage/posture damage -- mirrors plain Dash, never DashPunch/DashHit. Dash and Slide
	-- can never be simultaneously active (both lock the shared attackEndsAt commitment). They DO
	-- share one cooldown pool though (CombatState.movementCooldownExpiry, checked/set by both
	-- handleDashRequest and handleSlideRequest alongside each move's own individual cooldown below) --
	-- without that, alternating Dash and Slide let a player retreat almost twice as often as either
	-- move's own designed cooldown alone permits, since two independent cooldown pools running in
	-- parallel renew faster than one (a real playtest-found "dash tech": chain-pressing both keys
	-- instead of waiting out either move's own cooldown). First-pass technical tunables, free to
	-- move without design ceremony per combat-philosophy.md's Tuning process.
	SlideSpeedMultiplier = 2.0,
	-- Seconds the Slide WalkSpeed burst is active.
	SlideDurationSeconds = 0.35,
	-- Brief post-burst recovery, reusing the shared attackEndsAt commitment lock -- longer than Dash's
	-- own (0.28s) since a slide is a bigger, more committed movement than a step.
	SlideCommitmentSeconds = 0.45,
	-- Steeper than Dash's 0.8s -- Slide is chained off Sprint (already a bigger investment than a
	-- neutral Dash press) so it's meant to be a deliberate, occasional burst, not a spammable one.
	SlideCooldownSeconds = 1.2,

	-- The front-dash punch's own HitboxAttackDefinition (Server/Combat/HitboxResolver.lua consumes
	-- this the same way it consumes any Weapons[...].Stages entry, via a dedicated throwDashPunch in
	-- CombatSystem.lua rather than commitAndThrowAttack -- a dash-punch is its own move, not an M1
	-- string stage, so it deliberately never touches basicComboLanded). Damage/PostureDamage/Size
	-- copied from Primary's Basic1 ("since its a punch," same weight as an ordinary first hit); see
	-- HandTrackedOffset's own header for Offset specifically.
	--
	-- WindupSeconds/ActiveSeconds (see the locals above this table) were retuned via a live
	-- playtest pass to 0.4/0.2 -- unlike the original 0.02/0.26 split, the active window (roughly
	-- [0.4, 0.6]) now starts AFTER the front-lunge movement burst itself has already finished
	-- (DashFrontDurationSeconds is still 0.28, shorter than this Windup) rather than tracking the
	-- attacker for virtually the whole dash. HitboxResolver.performSample still re-reads the
	-- tracked pose fresh every sample (the attacker's own hand, per resolveAttackHandPart -- see
	-- HitboxResolver.SwingConfig.AttackerTrackedPart's own header) -- with the attacker already
	-- stopped by the time the window opens, this reads as a beat of wind-up followed by the punch
	-- flashing out, rather than a hitbox riding along with the lunge itself. RecoverySeconds (0.17,
	-- untouched by this pass) is the only part that exists purely as post-move commitment, not
	-- hitbox presence. The three feed DashFrontCommitmentSeconds directly above now, so they can
	-- never drift out of sync with it.
	--
	-- Cooldown is a REAL gate (CombatState.dashPunchReadyAt, set by throwDashPunch), not
	-- documentation -- it used to be unread, with the punch actually gated only by Dash's own much
	-- cheaper dashCooldownExpiry (0.8s), which under-priced a move that deals damage/posture AND
	-- opens the air combo relative to a plain reposition. Raised to 4s after a playtest pass (was
	-- 1.6s) -- DashPunch is a gap-closer, a damage/posture hit, AND a combo-starter in one move, so
	-- a full 4-second commitment between throws is what actually made it read as the rare,
	-- deliberate double-tap-forward commitment it's meant to be rather than a spammable option. A
	-- tuning number per combat-philosophy.md's Tuning process -- adjust freely after another pass.
	DashPunch = {
		DebugName = "DashPunch",
		WindupSeconds = DashPunchWindupSeconds,
		ActiveSeconds = DashPunchActiveSeconds,
		RecoverySeconds = DashPunchRecoverySeconds,
		-- X/Y match the same "slightly bigger than the player" pass applied to every other melee
		-- hitbox. Z shrunk from 7 to 4.25 -- see HandTrackedOffset's own header for why: the old
		-- 7-stud depth was mostly wasted bleeding back through the attacker's own body, not real
		-- forward reach, once paired with the re-derived Offset above.
		Size = Vector3.new(6, 6.5, 4.25),
		Offset = HandTrackedOffset,
		Damage = 8,
		PostureDamage = 10,
		Cooldown = 4,
		ArcDegrees = 100,
		-- 1, NOT the 3 every other multi-target hitbox uses -- DashPunch is a LAUNCHER, and both
		-- weapons' own Finishers already establish the rule this now follows ("a launcher commits to
		-- one foe, not a crowd-clear", see each Finisher's MaxTargets = 1). At 3 this was the single
		-- worst agency violation in the game: AirCombo.Apply tracks exactly ONE airComboTarget
		-- (CombatState.AirCombo.airComboTarget), so victims 2 and 3 were held aloft at HoverHeight for
		-- the full AirborneSeconds with no continuation hit ever able to land on them (only the ONE
		-- tracked victim ever gets a fresh Basic hit or a follow-up hold refresh) -- they'd just hang
		-- there until the hold's own timer lapsed, with no attacker action able to affect them either
		-- way. Fixing the count is the correct fix rather than teaching the air combo to track N
		-- victims: juggling three people at once was never the intent.
		MaxTargets = 1,
	},

	-- DashHit's own HitboxAttackDefinition -- the plain forward dash's own attack
	-- (CombatSystem.lua's throwDashHit/handleDashRequest), thrown on EVERY dash that resolves
	-- "Front" and ISN'T already throwing DashPunch (i.e. every plain forward Q/ButtonB dash, not
	-- just a double-tapped one). Deliberately a separate, lighter move from DashPunch, not a
	-- reskin of it: DashPunch is the rarer, deliberate double-tap commitment that opens the air
	-- combo; DashHit is what an ordinary forward dash "always has strapped to the end of it" --
	-- weaker damage/posture, one fewer max target, and no air-combo hook at all (its DebugName never
	-- matches applyAirCombo's "DashPunch" launch condition -- see that function's own header). Same
	-- Size/Offset/ArcDegrees as DashPunch (a punch's physical reach doesn't need to differ by how it
	-- was triggered -- both also hand-tracked, see HandTrackedOffset's own header and
	-- CombatSystem.lua's resolveAttackHandPart); Damage/PostureDamage/MaxTargets scaled down to
	-- reflect that this is the free, always-available version, not the cooldown-gated,
	-- double-tap-earned one. No separate cooldown field of its own -- gated purely by Dash's own
	-- DashCooldownSeconds (0.8s) the same way DashPunch originally was before it needed a stricter
	-- one; DashHit doesn't need DashPunch's stricter gate since it doesn't open the air combo and
	-- deals meaningfully less damage.
	DashHit = {
		DebugName = "DashHit",
		WindupSeconds = DashHitWindupSeconds,
		ActiveSeconds = DashHitActiveSeconds,
		RecoverySeconds = DashHitRecoverySeconds,
		-- Same "slightly bigger than the player" pass as DashPunch (identical Size/Offset by design
		-- -- see this definition's own header for why the two share physical reach, and
		-- HandTrackedOffset's own header for why Z is 4.25 rather than the old 7).
		Size = Vector3.new(6, 6.5, 4.25),
		Offset = HandTrackedOffset,
		Damage = 5,
		PostureDamage = 6,
		Cooldown = 0.8,
		ArcDegrees = 100,
		MaxTargets = 2,
	},

	-- AirSlam's own HitboxAttackDefinition -- pressing Basic Attack (M1) while airborne, at ANY time
	-- (no M1 combo prerequisite), throws this standalone move instead of continuing the grounded
	-- Basic string -- see CombatSystem.lua's handleAirSlamRequest/throwAirSlam, modeled directly on
	-- DashPunch/DashHit just above (a real move thrown via onSwingHitCandidate directly, never
	-- startAttackSwing, so it can never touch basicComboLanded/basicAttackReadyAt -- landing or
	-- whiffing an air slam has zero effect on the grounded M1 string, and vice versa). A clean
	-- (non-blocked, non-parried) hit always resolves with FinisherVariant = "Downslam"
	-- (HitResolution.ApplyFinisherPhysics), reusing Finisher.Downslam's own SlamToGround knockback
	-- and letting CombatAnimator's existing finisherTrackName("Downslam") resolution pick the
	-- animation -- no separate physics/animation plumbing needed for this move.
	--
	-- Own real cooldown (CombatState.airSlamReadyAt), same "a move that hits hard AND launches needs
	-- a real gate, not a free spam option" reasoning as DashPunch.Cooldown's own header -- jumping is
	-- free (no Stamina), so without this a player could throw one on every hop. Damage/PostureDamage
	-- sit between a Basic3 and a Heavy1 (a committed, telegraphed hit, not a routine combo stage);
	-- hand-tracked Offset (see HandTrackedOffset's own header) and a taller Size than a ground swing
	-- since the attacker is airborne and the target is typically at or near ground level.
	-- First-pass technical values, free to tune per combat-philosophy.md's Tuning process.
	AirSlam = {
		DebugName = "AirSlam",
		WindupSeconds = 0.35,
		ActiveSeconds = 0.22,
		RecoverySeconds = 0.3,
		-- Scaled with every other melee hitbox's "slightly bigger than the player" pass -- kept
		-- taller than a level swing's own 6.5 (it's an overhead slam, needs more vertical reach
		-- toward a target typically below the attacker). Z shrunk from 7 to 4.25, same
		-- HandTrackedOffset fix as DashPunch/DashHit (see that local's own header) -- AirSlam shared
		-- the identical "bleeds behind the attacker" bug since it shares the same tracked-hand Offset.
		Size = Vector3.new(6, 7, 4.25),
		Offset = HandTrackedOffset,
		Damage = 14,
		PostureDamage = 16,
		Cooldown = 3,
		ArcDegrees = 100,
		MaxTargets = 1,
	},

	-- Air combo: a DashPunch that connects (unmitigated -- Block stops it, same rule as every
	-- finisher) holds BOTH the target AND the attacker in the air together (AirCombo.Apply). While
	-- CombatState.airComboExpiry hasn't lapsed, the attacker's own subsequent Basic (M1) hits landing
	-- on that SAME target continue the juggle -- refreshing the hold below -- up to MaxHits total, at
	-- which point the final hit slams them into the ground for bonus damage instead of holding them
	-- up again. A real player target stays LIVE the whole sequence (full Motor6D/Humanoid control,
	-- Block/Parry-capable -- see AirCombo.lua's own header); a training-dummy target stays fully
	-- ragdolled, no defend concept to preserve. Bot targets never reach this at all -- bots can't be
	-- juggled (CombatState.airComboTarget is typed Player?, never a bot).
	AirCombo = {
		-- Dummy-target only, as of this pass -- a real player target stays live-held from impact (no
		-- launch velocity/tumble at all, see AirCombo.Apply's own header for why); a training dummy
		-- still gets this pop + backward spin to sell the hit landing before RagdollController.
		-- HoldAloft's own AlignPosition takes over.
		LaunchHorizontalVelocity = 4,
		LaunchBackwardSpin = 4,
		-- How long both combatants stay locked into the sequence per launch or hold-refresh --
		-- reused for EVERYTHING that needs to agree on "how long until this sequence naturally ends
		-- without another landed hit": the target's ragdoll recovery window, RagdollController.
		-- HoldAloft's own hold duration, AND (as of this value) CombatState.airComboExpiry's own
		-- continuation deadline (applyAirCombo's `now + cfg.AirborneSeconds`) -- those three used to
		-- be governed by two DIFFERENT constants (this one plus a separate, SHORTER WindowSeconds),
		-- which meant a hit that landed physically in time (target still visibly held) could still
		-- get silently rejected as "too late" for combo-continuation purposes -- read as "we fall
		-- before I finish the combo" even on a hit that looked like it connected. One constant means
		-- that gap can't reopen. Bumped from 1.4 -- real swing windup + human reaction time to a
		-- landed hit ate more of the old, tighter budget than intended; the target is fully ragdolled/
		-- held the whole time regardless; a bit more slack costs the defender nothing extra.
		AirborneSeconds = 1.8,
		-- Guaranteed EXTRA hold time (on top of AirborneSeconds, not a replacement for it) a
		-- priority-switch parry grants -- see AirCombo.SwitchPriority's own header (Server/Combat/
		-- AirCombo.lua). A continuation-hit Parry against an already-tracked air-combo target flips
		-- who's attacking instead of just ending the sequence; this is the reward for pulling off that
		-- harder, correctly-timed defensive read, on top of the punish/disarm resolveHitAgainstTarget's
		-- Parry branch already applies to the (now-victim) attacker. Deliberately does not apply to
		-- parrying the OPENING DashPunch itself -- that stays a plain punish with no launch, see
		-- SwitchPriority's own call site (CombatSystem.lua's resolveHitAgainstTarget) for the exact
		-- isTrackedContinuation gate. A rally of back-and-forth priority-switch parries can chain
		-- indefinitely, each one re-adding this same bonus on top of the base window.
		ParryHoldExtensionSeconds = 2,
		-- How high above their hit-time position the TARGET rises and then STOPS -- a fixed world
		-- position (RagdollController.HoldAloft pins them there via AlignPosition), not a launch
		-- velocity + gravity estimate. This replaced a velocity/FloatGravityFraction-based float
		-- (v0 = 75 studs/sec, 45% net gravity) that was tuned assuming a ~14-stud peak but actually
		-- settles far higher (v0^2 / (2 * netGravity) works out closer to 30+ studs at those numbers)
		-- -- getting float kinematics exactly right is inherently fiddly, and re-launching on every
		-- continuation hit compounded the error hit-over-hit (each relaunch reset velocity from an
		-- ALREADY-elevated position, so a fast combo ratcheted the target higher and higher instead of
		-- settling at one height) -- read as "it just keeps going up and never comes back down, I
		-- can't hit him." Pinning to an exact position sidesteps both failure modes by construction:
		-- one rise, one height, held there for follow-ups, full stop, regardless of tuning or how many
		-- continuation hits land. See HoldAloft's own header.
		HoverHeight = 12,
		-- AlignPosition.MaxVelocity (studs/sec) for the target's rise to HoverHeight. Paced to a
		-- readable FLIGHT, not a snap: at ~12 studs of rise this is ~0.4s up. Deliberately close to the
		-- attacker's ChaseSpeed below so the two ascend TOGETHER (the whole point of the air combo is
		-- launching both up in formation) -- if these two drift far apart the faster body leaves the
		-- slower one out of swing range mid-rise and early continuation hits whiff. Was 60 (a fast zip
		-- that read as a snap up rather than a launch you fly alongside).
		HoverRiseSpeed = 30,
		-- AlignPosition.Responsiveness for the target's rise -- see ChaseResponsiveness below for what
		-- this knob actually does; left at a snappy value here since the target's rise already reads
		-- as a launch via LaunchAndRagdoll's own tumble/spin (LaunchBackwardSpin above), unlike the
		-- attacker's own motion which had nothing else selling "flight" until ChaseResponsiveness.
		HoverResponsiveness = 25,
		-- Total hits in the sequence including the DashPunch launcher itself -- e.g. 4 means launcher
		-- + 2 continuations + 1 slam. Capped deliberately small: combat-philosophy.md's "no true
		-- unblockable/unparryable without a telegraphed cost" -- the sequence itself stays short
		-- rather than open-ended, the same reasoning that already caps the M1 string at
		-- BasicComboLength before forcing a Finisher. (This previously also pointed at a
		-- TechWindowSeconds field "below" for the target's escape option; no such field exists
		-- anywhere in the codebase and no air-tech is implemented, so the short sequence length is
		-- currently the ONLY thing bounding a victim's helplessness here.)
		MaxHits = 4,
		-- The attacker's OWN positioning -- see RagdollController.HoldAloft's header for why a fixed-
		-- point AlignPosition pin (not a one-time launch velocity, and -- as of this value -- not a
		-- live per-Heartbeat re-target either) is what actually closes the gap and holds it: the
		-- attacker keeps full Humanoid control to keep swinging, and Roblox's own Humanoid movement
		-- handling fights/cancels an externally-set velocity almost immediately once ownership is back
		-- with the client -- a single impulse never actually closed the distance, which is why "we
		-- weren't floating next to each other." Studs/sec cap on how fast the hold can move them.
		-- Paced to a readable FLIGHT up to the target, matched to HoverRiseSpeed above so attacker and
		-- target ascend together in formation (see that field). Was 55 -- once the hold stopped sagging
		-- (gravity is now cancelled, see ChaseResponsiveness/ensureGravityCancel), that high a cap ran
		-- the attacker up the ~8-10 stud rise in ~0.15s, which read as a SNAP, not "flying to them." At
		-- ~22 studs/sec the same rise is ~0.4s -- a visible flight that arrives about when the target
		-- settles. Lower this further for a floatier ascent, raise it back toward 55 for a snappier one.
		ChaseSpeed = 22,
		-- AlignPosition.Responsiveness for the attacker's chase -- how aggressively it converts
		-- position error into target velocity. The original 25 (same value AlignPosition's own
		-- default-ish "snappy" range) made a short gap basically resolve in one physics step once
		-- MaxForce = math.huge could supply whatever force that demanded -- read as "teleporting up,"
		-- not flying. 10 makes the velocity ramp up over several frames instead of jumping straight to
		-- ChaseSpeed, which is what actually reads as a rise/flight rather than a snap -- ChaseSpeed
		-- above still caps how fast that ramp tops out, so it stays quick overall.
		-- IMPORTANT: this soft value only holds the attacker at the right spot because the attacker's
		-- hold now CANCELS GRAVITY (RagdollController.ensureGravityCancel, triggered by passing
		-- liveBodyFacePoint to the attacker's HoldAloft calls). Without that, a soft Responsiveness
		-- against a LIVE body's own gravity settles well BELOW the target Position -- the "float down,
		-- never reach them" bug -- so if the gravity-cancel is ever removed, this must go back up
		-- (~25) or the sag returns.
		ChaseResponsiveness = 10,
		-- How far back (studs, horizontal) the chase parks the attacker from the target, instead of
		-- pulling all the way to the target's exact point -- converging to zero distance put the
		-- target directly overhead (both are solid, colliding bodies, and the target is the higher of
		-- the two), read as "he's on my head, not in front of me." 3.5 sits inside a Basic swing's own
		-- forward reach (Weapons.Primary.Stages.Basic's Offset = -3, Size.Z = 6, i.e. 0-6 studs in
		-- front of the attacker) so a continuation hit's hitbox reliably contains the target once the
		-- chase settles, instead of guessing a distance unrelated to the hitbox that's supposed to
		-- land on it.
		ChaseStandoffDistance = 3.5,
		-- Below this horizontal magnitude, the away-from-target standoff direction falls back to a
		-- fixed world direction instead of normalizing a near-zero vector (DashPunch's own Offset/Size
		-- means the real degenerate case essentially never happens in practice).
		MinStandoffDirectionMagnitude = 0.5,
		-- How far below the target's hover height the chase parks the attacker's root -- a small gap
		-- (not zero, not level) so the target visually reads as "up and ahead" rather than exactly
		-- level, while staying well inside a Basic swing's own vertical reach (Size.Y = 5 centered on
		-- the attacker's own root, i.e. +/-2.5 studs) so it doesn't undershoot the hitbox at the other
		-- extreme.
		ChaseBelowTargetOffset = 1.5,
		-- The finisher slam (the hit that reaches MaxHits) -- reuses Downslam-style physics
		-- (RagdollController.SlamToGround) rather than a new mechanic. Bonus damage is on top of
		-- that hit's own normal Basic-stage damage, not a replacement for it -- "a little extra
		-- damage for smacking the ground."
		SlamDownVelocity = 85,
		SlamKnockdownSeconds = 1.25,
		SlamBonusDamage = 6,
		-- Same face-down tumble bias as Finisher.Downslam.FaceDownSpin (see that field's own header for
		-- the mechanism) -- kept as its own independently-tunable number rather than a shared reference
		-- since this slam's own SlamDownVelocity (85) already differs from Finisher.Downslam's (140),
		-- the same "each context keeps its own copy even where values happen to start equal" reasoning
		-- Constants.Debug.DevMenu's confirm-window constants already document.
		FaceDownSpin = 9,
	},

	-- Locomotion animation ids -- read generically by Client/FX/CombatAnimator.lua's BindCharacter
	-- loop (whatever's in this table gets a template built and loaded, nothing hardcodes the name
	-- list) -- see that module's own header. Every combat-specific id that used to live here
	-- (Swing1-3, Heavy1-2, Uppercut/Downslam/FinisherNormal, BlockHold, ParryFlash, DashFront/Back/
	-- Left/Right/DashPunch, Slide, Hit1-3/HitGeneric, PostureBreakStagger, Feint) was removed
	-- alongside the rest of the combat system -- CombatAnimator.lua no longer has any code path that
	-- would resolve them, and BotAnimator.lua (the other former consumer) is gone entirely.
	AnimationIds = {
		-- Walking/Running are a pair -- CombatAnimator.lua's locomotion evaluator crossfades
		-- between them on the same fade duration as sprint toggles, and stops whichever is
		-- playing on a hard interrupt (the character stops moving).
		Walking = "rbxassetid://92817463622620",
		Running = "rbxassetid://134203885804635",
		-- The SECOND run stage's own clip (Constants.Attributes.SprintStage == 2). Blank until a real
		-- full-stride run is authored -- and blank is a supported, shipped state, not a stub: the
		-- locomotion evaluator falls through to Running above when this has no id, so stage 2 still
		-- reads as a different gear through Constants.Run.Animation.PlaybackSpeeds, the FOV pull
		-- and the stage-2 footstep/onset audio. Paste an id here and the clip swaps in with no code
		-- change, the same wired-but-unauthored convention FlightConstants.AnimationIds uses.
		RunningStage2 = "rbxassetid://95107102086715",
		-- The THIRD run stage's own clip (Constants.Attributes.SprintStage == 3). USER-SUPPLIED, not
		-- yet authored -- this codebase never guesses an asset id (see CombatAudio.lua/VitalIcon.lua's
		-- headers). Blank until pasted in, same convention as RunningStage2 above: the locomotion
		-- evaluator falls through to RunningStage2 (then, if that's also blank, to Running) when this
		-- has no id, so stage 3 still reads as a distinct gear through
		-- Constants.Run.Animation.PlaybackSpeeds alone until a real clip lands. That PlaybackSpeeds[3]
		-- rate (1.5x) was tuned for THAT fallback -- once a real clip is pasted here, dial it back
		-- toward 1 (see that field's own comment), or the clip will read as sped-up/cartoonish.
		RunningStage3 = "rbxassetid://126596518578942",
	} :: { [string]: string },

	-- PostureRegenPerSecond/HealthRegen/LockOnRange/ParryTellBroadcastRadius/MaxTrackedOpponents/
	-- PassiveVitalsSyncInterval/FeedbackHeadOffset were removed alongside the rest of the combat
	-- system -- every reader
	-- (CombatSystem.lua, CombatClient.lua, HitResolution.lua) is gone, and
	-- src/StarterPlayer/StarterCharacterScripts/Health.server.lua (the one file that still mentions
	-- HealthRegen) only ever referenced it in a comment, never read it.

	-- DebugHitboxes/Hitboxes (swept melee hitbox geometry/scheduling and its Studio debug-Part
	-- cosmetics) were removed alongside the rest of the combat system -- their one reader,
	-- Server/Combat/HitboxResolver.lua, is gone. HitboxShapes.lua's own FIELD_SPECS comments still
	-- cross-reference Hitboxes.MaxCandidateRadius by name for historical context (why its Max=500 was
	-- chosen), but never actually read the constant.

	-- Two weapon loadout slots (combat-philosophy.md's "Established systems" list names "weapon
	-- switching with swap cooldown" alongside Lock-on/Block/Parry/Posture as already-canon). Each
	-- weapon owns its own Basic/Heavy/Finisher stage arrays (Types.HitboxAttackDefinition, same
	-- shape Hitboxes.Basic/Heavy/Finisher used before this table existed) -- CombatSystem.lua's
	-- selectAttackDefinition reads Weapons[state.equippedWeaponId].Stages instead of a single flat
	-- table, and RequestSwapWeapon (SwapCooldownSeconds below) toggles which one is active.
	-- Deliberately NOT a reskin: Secondary trades Primary's longer reach and higher per-hit damage
	-- for faster windup/cooldown and comparable-or-higher posture-damage-per-second, a genuine
	-- posture-hunting/tempo alternative to Primary's damage race -- combat-philosophy.md's Balance
	-- Principle #2 ("expand a kit's decision space, not just its damage"). First-pass technical
	-- values, not a balance pass; see combat-philosophy.md's Tuning process. Basic/Heavy each hold
	-- one entry per combo stage -- CombatSystem.lua wraps the attacker's comboIndex over however
	-- many stages are listed, so adding a stage is a data-only change, no code change.
	--
	-- Cooldown vs. WindupSeconds+ActiveSeconds+RecoverySeconds: every stage below sets Cooldown to
	-- (at most) its own full swing timeline, never longer. With no animation system yet (every
	-- swing's windup/active/recovery is currently invisible -- see CombatClient.lua's
	-- Combat_AttackStarted listener), a Cooldown longer than the swing's own timeline creates
	-- "dead time" where the swing has already finished but the next one still can't start, with
	-- nothing visible to explain why -- reads as unresponsive input, not a deliberate pause. Keeping
	-- Cooldown <= the timeline means attackEndsAt (the commitment lock, always exactly the timeline)
	-- is the true binding constraint, never Cooldown layering extra wait time on top of it.
	Weapons = {
		-- Which weapon a fresh CombatState starts equipped with (CombatTypes.lua's createFreshState/
		-- onCharacterAdded) -- also the only weapon training bots ever use (BotState has no
		-- equippedWeaponId field; see handleSwapWeaponRequest's own comment for why bot
		-- weapon-switching is out of scope).
		Default = "Primary" :: Types.WeaponId,
		-- Minimum seconds between accepted RequestSwapWeapon calls -- long enough that swap-spamming
		-- can't be used as an exploit or evasive tool, short enough to be a real mid-fight option,
		-- matching combat-philosophy.md's framing of the swap cooldown's purpose ("prevents instant
		-- weapon-cycling as a combo exploit").
		SwapCooldownSeconds = 4,

		Primary = {
			DisplayName = "Longsword",
			Stages = {
				Basic = {
					{
						DebugName = "Basic1",
						-- WindupSeconds retuned to 0.31 -- confirmed via live Studio playtest (dev menu's
						-- Hitbox Timing tab) that all three M1 stages read as landing on-swing at this
						-- value against the real swing clips, replacing the old placeholder-era 0.08.
						WindupSeconds = 0.31,
						ActiveSeconds = 0.22,
						RecoverySeconds = 0.14,
						-- Sizes across every stage/weapon retuned "slightly bigger than the player" (a
						-- standard R15 character is ~2x2x1 HumanoidRootPart, ~5-6 studs tall): height
						-- flattened to a single generous 6.5 across every melee stage (was
						-- inconsistently as low as 4 on Secondary, undershooting a standing target), and
						-- every X/reach-offset scaled x1.2 off the old values, preserving the existing
						-- relative growth between combo stages.
						--
						-- Z (reach) then cut by another ~35% across EVERY stage of BOTH weapons in one
						-- pass (this comment applies to that whole pass, not just Basic1) -- a live
						-- playtest screenshot showed Basic1's swing box reaching a full 7 studs forward
						-- (flush against the root, Offset always exactly -Size.Z/2 -- see
						-- Hitboxes.MaxCandidateRadius's own comment for that convention), roughly 3-4x a
						-- standing character's own body depth, well past what a sword swing should
						-- plausibly reach. Every Size.Z/Offset pair below is scaled by the same ~0.65
						-- factor so relative combo-stage growth (Basic < Heavy < Finisher) and the
						-- Secondary-vs-Primary reach ratio both stay exactly as designed -- only the
						-- absolute scale shrank. X/Y untouched.
						Size = Vector3.new(6, 6.5, 4.5),
						Offset = CFrame.new(0, 0, -2.25),
						-- 6.5 flat on every Basic stage of every weapon -- DamageSystem.applyOutcome pins an
						-- M1's combo-pricing stage to 1 (ComboMultiplier(1) == 1), so this authored number IS
						-- the number a player takes, unscaled, every single M1 regardless of string position.
						Damage = 6.5,
						PostureDamage = 10,
						Cooldown = 0.44,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Basic2",
						WindupSeconds = 0.31,
						ActiveSeconds = 0.22,
						RecoverySeconds = 0.16,
						Size = Vector3.new(6, 6.5, 4.5),
						Offset = CFrame.new(0, 0, -2.25),
						Damage = 6.5,
						PostureDamage = 10,
						Cooldown = 0.47,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Basic3",
						WindupSeconds = 0.31,
						ActiveSeconds = 0.24,
						RecoverySeconds = 0.20,
						Size = Vector3.new(6.5, 6.5, 5.25),
						Offset = CFrame.new(0, 0, -2.625),
						Damage = 6.5,
						PostureDamage = 12,
						Cooldown = 0.54,
						ArcDegrees = 110,
						MaxTargets = 3,
					},
				},

				-- A single swing, not a string -- Heavy intentionally holds exactly one stage (array of
				-- one, not a bare table) so DefaultMoveRegistry/SwingSequencer's generic per-stage
				-- machinery still applies with zero special-casing; every Heavy press just keeps
				-- resolving back to this same stage, the same "one past the end wraps to 1" rule any
				-- other string follows. There used to be a second stage; it never received an authored
				-- animation and only added a second, harder-hitting swing on the same telegraph, so it
				-- was cut rather than finished.
				Heavy = {
					{
						DebugName = "Heavy",
						WindupSeconds = 0.600,
						ActiveSeconds = 0.22,
						-- 0.55, up from 0.35 (docs/architecture/2026-08-audit.md section 6.1/3.4) -- funds the
						-- Cooldown cut below out of a longer whiff/block punish window instead of a free
						-- reduction, so a missed Heavy stays risky.
						RecoverySeconds = 0.55,
						Size = Vector3.new(7, 6.5, 5.5),
						Offset = CFrame.new(0, 0, -2.75),
						Damage = 12,
						PostureDamage = 22,
						-- 1.37, down from 3.00 -- restores the "Cooldown == Windup+Active+Recovery" invariant
						-- this table's own header requires, matching Secondary's own Heavy stage
						-- (DaggerHeavy.Cooldown ~= its own timeline). At 3.00 the heavy button was dead
						-- ~1.63s AFTER the swing had visibly ended, with nothing on screen explaining why --
						-- reads as unresponsive input, not a deliberate pause.
						Cooldown = 1.37,
						ArcDegrees = 120,
						MaxTargets = 4,
					},
				},

				-- The M1 combo finisher (reached at BasicComboLength). Its own hitbox category, NOT
				-- a Basic stage, so training bots (which cycle Basic) never throw it and the Basic
				-- string stays a plain 3-stage combo. A single definition, not an array -- there is
				-- one finisher swing per weapon; the three variants (uppercut/downslam/normal)
				-- differ in the knockback applied on a clean hit (CombatConstants.Finisher above),
				-- not in the swing geometry. Deliberately telegraphed: a longer Windup than any
				-- Basic stage so it reads (combat-philosophy.md's "reads beat reflexes"), a longer
				-- Recovery so a whiffed or blocked finisher is punishable, and MaxTargets = 1 (a
				-- launcher commits to one foe, not a crowd-clear).
				Finisher = {
					DebugName = "Finisher",
					WindupSeconds = 0.28,
					ActiveSeconds = 0.18,
					RecoverySeconds = 0.45,
					Size = Vector3.new(7, 6.5, 5.5),
					Offset = CFrame.new(0, 0, -2.75),
					Damage = 20,
					PostureDamage = 35,
					Cooldown = 0.9,
					ArcDegrees = 110,
					MaxTargets = 1,
				},
			},
		},

		-- Faster, shorter-reach, lower-per-hit-damage alternative to Primary -- see this table's own
		-- header for the design intent. Roughly: ~75% of Primary's windup/cooldown (faster tempo),
		-- ~85% of Primary's reach (Size/Offset), ~70% of Primary's per-hit Damage, but PostureDamage
		-- held close to Primary's -- net higher posture-damage-per-second despite lower raw damage.
		Secondary = {
			DisplayName = "Dual Daggers",
			Stages = {
				Basic = {
					{
						DebugName = "Dagger1",
						-- 0.16, up from 0.06. Secondary's own header promises "~75% of Primary's windup",
						-- but Primary's Basics were retuned 0.08 -> 0.31 in a live playtest pass and
						-- Secondary was never brought along, leaving it at ~20% of Primary rather than 75%.
						-- The result was a de facto true unparryable: a 60ms windup, over a network, against
						-- a 30Hz hitbox sampler, cannot be reacted to at all, which combat-philosophy.md's
						-- Balance Principle 3 forbids without an explicit telegraphed cost. It also made
						-- Feint (legal only inside windup) mechanically nonexistent on this weapon.
						--
						-- The added windup is funded mostly out of RecoverySeconds rather than bolted onto
						-- the front, so the total timeline barely moves (0.33 -> 0.35) and Secondary keeps
						-- its fast tempo and its roughly-75%-of-Primary cooldown ratio. What changed is the
						-- SHAPE of the swing: more of it is readable telegraph, less is endlag. The
						-- trade-off is a shorter whiff-punish window, accepted because an unreactable
						-- attack is the worse failure. Cooldown stays exactly Windup+Active+Recovery, the
						-- invariant this table's header states and every stage here already satisfied.
						-- Kept strictly under DaggerFinisher's 0.22 so the finisher remains the most
						-- telegraphed swing in the kit, as every other weapon's finisher is.
						--
						-- Still owed: a live Studio playtest pass on these three stages, the same one
						-- Primary's Basics got when they moved 0.08 -> 0.31.
						WindupSeconds = 0.16,
						ActiveSeconds = 0.11,
						RecoverySeconds = 0.08,
						-- Z cut ~35% same as Primary above -- see Basic1's own comment for why.
						Size = Vector3.new(5, 6.5, 3.75),
						Offset = CFrame.new(0, 0, -1.875),
						Damage = 6.5,
						PostureDamage = 9,
						Cooldown = 0.35,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Dagger2",
						-- See Dagger1's WindupSeconds header for why this rose from 0.07 and why the
						-- recovery fell to pay for it. Cooldown stays Windup+Active+Recovery.
						WindupSeconds = 0.17,
						ActiveSeconds = 0.11,
						RecoverySeconds = 0.09,
						Size = Vector3.new(5, 6.5, 3.75),
						Offset = CFrame.new(0, 0, -1.875),
						Damage = 6.5,
						PostureDamage = 9,
						Cooldown = 0.37,
						ArcDegrees = 100,
						MaxTargets = 3,
					},
					{
						DebugName = "Dagger3",
						-- See Dagger1's WindupSeconds header for why this rose from 0.08 and why the
						-- recovery fell to pay for it. Cooldown stays Windup+Active+Recovery.
						WindupSeconds = 0.18,
						ActiveSeconds = 0.12,
						RecoverySeconds = 0.11,
						Size = Vector3.new(5.5, 6.5, 4.25),
						Offset = CFrame.new(0, 0, -2.125),
						Damage = 6.5,
						PostureDamage = 11,
						Cooldown = 0.41,
						ArcDegrees = 110,
						MaxTargets = 3,
					},
				},

				-- Single-stage, same as Primary's own Heavy above -- see that field's own header for why
				-- (a cut second stage, not a stub waiting to be authored).
				Heavy = {
					{
						DebugName = "DaggerHeavy",
						WindupSeconds = 0.14,
						ActiveSeconds = 0.17,
						RecoverySeconds = 0.27,
						Size = Vector3.new(6, 6.5, 4.5),
						Offset = CFrame.new(0, 0, -2.25),
						Damage = 13,
						PostureDamage = 20,
						Cooldown = 0.58,
						ArcDegrees = 120,
						MaxTargets = 4,
					},
				},

				Finisher = {
					DebugName = "DaggerFinisher",
					WindupSeconds = 0.22,
					ActiveSeconds = 0.14,
					RecoverySeconds = 0.35,
					Size = Vector3.new(6, 6.5, 4.5),
					Offset = CFrame.new(0, 0, -2.25),
					Damage = 14,
					PostureDamage = 32,
					Cooldown = 0.68,
					ArcDegrees = 110,
					MaxTargets = 1,
				},
			},
		},
	},

	-- BallSocketConstraint cone/twist limits Server/Combat/RagdollController.lua applies to every
	-- non-Root joint while ragdolled -- loose enough to read as floppy, tight enough that limbs
	-- don't invert into a spiky mess. First-pass values; purely cosmetic, safe to tune. Were
	-- module-local constants in RagdollController.lua; moved here per luau-coding-standards.md's
	-- "no magic numbers in system logic," matching every other physics/hitbox tunable's home.
	Ragdoll = {
		BallSocketUpperAngle = 45,
		BallSocketTwistLowerAngle = -45,
		BallSocketTwistUpperAngle = 45,
		-- Rotational friction (stud * mass * stud / s^2) on every ragdoll ball socket. A frictionless
		-- socket has nothing to bleed energy into, so a limb that gets kicked by a landing impact keeps
		-- swinging on essentially forever -- the "spaghetti flail that never settles" look. Friction is
		-- what makes a ragdoll come to REST at a natural pose within a second or so of landing instead
		-- of twitching for its whole knockdown window. Deliberately modest: too high reads as a stiff
		-- mannequin that barely reacts to the hit at all. Dropped to zero during the recovery blend
		-- (RecoverBlendSeconds below) so it never fights the limbs' own return to rest pose.
		BallSocketFrictionTorque = 15,
		-- Elasticity every ragdoll part is forced to for as long as it's limp, overriding whatever its
		-- material (or the ground/terrain/grass it lands on) would otherwise contribute -- Roblox
		-- resolves a collision's bounce from BOTH surfaces' Elasticity (weighted by ElasticityWeight,
		-- Average by default), so a real material's non-zero default was enough, at the speeds a
		-- finisher launch or a wall-drop actually lands at, to visibly bounce/launch a body back off
		-- the ground it just fell onto -- which is what read as "flying" on landing, distinct from the
		-- mid-air launch itself. RagdollElasticityWeight is set far above any ordinary surface's own
		-- weight (Roblox materials default to 1) specifically so this zero wins the combine regardless
		-- of what the character lands on.
		RagdollElasticity = 0,
		RagdollElasticityWeight = 100,
		-- Hard ceiling (studs/s) on any linear velocity RagdollController writes onto a body. Nothing
		-- authored today comes close (the biggest is Finisher.Downslam's 140), so this never bites on a
		-- tuned move -- it exists so an authored Move Creation System knockback (Types.
		-- HitboxAttackDefinition.Knockback is designer-editable at runtime via the Move Editor) can't
		-- fat-finger a body clean off the map. A ragdoll that leaves the play space can't be recovered
		-- into anything meaningful, so this is a containment guard, not a feel knob.
		MaxLaunchSpeed = 250,
		-- Smooth recovery ("blend") -- how long the body spends physically folding back to its rest pose
		-- BEFORE the Motor6Ds are re-enabled, instead of snapping there in one frame. Re-enabling a
		-- Motor6D instantly teleports its limb from wherever physics left it to wherever the animation
		-- says it should be; from a sprawled ragdoll that is a large, very visible pop on every client.
		-- During this window each joint gets an AlignOrientation easing it back toward the pose captured
		-- at ragdoll time while the socket's own cone/twist limits tighten toward zero, so by the time
		-- the motors come back the limbs are already within a few degrees of where the motors would put
		-- them and the handoff is invisible. All of it is real physics on a server-owned assembly, so it
		-- replicates to every client -- a script-side Motor6D.Transform lerp would NOT (Transform is
		-- evaluated per-client by each Animator, so a server write to it is never seen by anyone else).
		--
		-- Long enough to read as "picking myself up," short enough that it never eats into the authored
		-- RagdollSeconds/KnockdownSeconds an attacker is counting on: the blend runs AFTER that window
		-- expires, so it is added lockout, which is why it stays well under a quarter second of feel.
		RecoverBlendSeconds = 0.35,
		-- AlignOrientation.Responsiveness the per-joint recovery drives ramp UP to across the blend
		-- (eased in as alpha^2 from 0, so the fold-back starts as a gentle gather rather than an
		-- immediate yank the instant the window opens). Higher = limbs snap to rest pose sooner within
		-- the blend; lower = a looser, more gradual gather that may not fully arrive before the motors
		-- re-enable.
		RecoverJointResponsiveness = 30,
		-- Same ramp, for the single AlignOrientation that brings the root assembly (HRP + LowerTorso)
		-- back upright during the blend. Softer than the joints' own value on purpose: this rotates the
		-- heaviest part of the body and the CAMERA follows it, so an aggressive gain here reads as the
		-- view being wrenched upright. Yaw is preserved (the body stands up facing wherever it landed),
		-- only pitch/roll are corrected.
		RecoverUprightResponsiveness = 20,
		-- What the ball sockets' cone/twist limits tighten TO by the end of the blend (degrees, from
		-- BallSocketUpperAngle/BallSocketTwist*Angle above). Not zero -- a hard 0 makes the solver fight
		-- itself against unavoidable float error on the last step -- just small enough that the residual
		-- error the motors have to absorb on re-enable is below what the eye can catch.
		RecoverEndAngle = 5,
		-- Settle-aware recovery (RagdollController.isSettled / Update). A knockdown's authored window
		-- is "how long they're down", but a real launch spends much of that window still IN THE AIR --
		-- a timer-only recovery therefore opened the stand-up blend mid-flight, so the body folded
		-- itself upright while still travelling and landed neatly on its feet, which reads as the
		-- knockback being shrugged off. Recovery now additionally waits for the body to actually stop
		-- moving. Speed (studs/s) at or below which a limp body counts as done moving: comfortably
		-- above the residual jitter a settled ragdoll keeps from its own ball-socket friction, well
		-- below any speed a body is still meaningfully travelling at.
		RecoverSettleSpeed = 6,
		-- Hard cap on that extra wait, measured from the authored window's own expiry. Bounds the one
		-- failure mode the wait introduces -- a body that never comes to rest (knocked into a
		-- bottomless fall, onto a conveyor, into geometry the solver keeps nudging) would otherwise
		-- stay limp forever. Long enough to cover a full finisher launch's remaining hangtime, short
		-- enough that a caller mirroring this module's timer (see RagdollController.RemainingSeconds)
		-- never drifts by a gameplay-relevant amount.
		RecoverSettleMaxSeconds = 0.75,
		-- Below this horizontal distance between the air-combo hold position and the face-toward
		-- point, ensureFaceOrientation skips re-aligning rather than pointing at a near-zero look
		-- vector (the degenerate "target directly overhead" case).
		FaceAlignToleranceStuds = 0.05,
		-- ensureFaceOrientation's AlignOrientation eases toward its face-point at this Responsiveness
		-- (RigidityEnabled = false, MaxTorque = math.huge -- same soft-constraint pairing HoldAloft's
		-- own AlignPosition already uses for position) instead of snapping instantly. A rigid lock read
		-- fine for the ORIGINAL air-combo design (only ever a small correction -- an attacker already
		-- entering roughly facing the target they just DashPunched), but AirCombo.SwitchPriority can
		-- now re-point a body that was facing ANY direction a moment ago (the new victim was mid-swing,
		-- not necessarily aligned with the new attacker) -- an instant, potentially large re-facing
		-- whips the third-person camera (which follows the character's own back) around with it,
		-- reading as the camera lurching to stare at whoever's now attacking instead of smoothly
		-- panning to keep watching the player's own back through the turn.
		--
		-- 50, not the original 10 -- a SwitchPriority re-facing is routinely close to a full 180 (the
		-- parrier and the puncher were facing each other, so each now needs to reverse), and 10 was
		-- tuned only against the ORIGINAL design's small corrections. At that gain a big turn crawled
		-- so slowly it read as "doesn't turn to face the opponent at all" rather than a smooth pan --
		-- indistinguishable, over the few seconds someone actually watches it, from stuck facing the
		-- old direction. MaxTorque is already math.huge (uncapped authority), so raising Responsiveness
		-- doesn't fight that -- it's purely how quickly the constraint spends that authority. 50 still
		-- reads as a deliberate turn, not a snap, for the ORIGINAL small-correction case, while actually
		-- completing a big SwitchPriority re-facing within a fraction of a second instead of many.
		FaceOrientationResponsiveness = 50,
		-- Ground-aware slam clamping (RagdollController.SlamToGround / resolveGroundClearance) -- fixes
		-- "the downslam launches the target INTO THE AIR instead of into the floor." A slam writes its
		-- DownVelocity onto EVERY BasePart, and AirSlam only ever requires the ATTACKER to be airborne
		-- (CombatConstants.AirSlam / CombatSystem.isAirborneForAirSlam), so the overwhelmingly common
		-- downslam target is someone STANDING ON THE GROUND -- feet already in contact with the floor.
		-- Injecting a large downward velocity into a body that has nowhere to fall drives every part
		-- through the floor surface on the very first physics step (at 140 studs/s that's 2.33 studs per
		-- 1/60s step, deeper than the parts are tall), and Roblox's penetration recovery then ejects them
		-- back out hard -- each ball-socketed limb resolving in its own direction, which is precisely what
		-- read as the body rocketing upward and flipping the instant it was hit. A slam only has anywhere
		-- to GO if there's real clearance beneath the target, so the applied speed is scaled to that.
		--
		-- How far down resolveGroundClearance looks for a floor. A miss (nothing within range -- slammed
		-- out over a void or off a cliff) means there's nothing to hit and so nothing to clamp against:
		-- the full authored DownVelocity applies unscaled.
		SlamGroundCheckDistance = 512,
		-- The clamp itself: usable drop distance / this = the fastest the body may travel without
		-- outrunning the solver's ability to resolve contact. 1/15s is roughly four physics steps of
		-- headroom, so even at the clamped speed a part covers well under its own height per step. A
		-- target with a full 12-stud air-combo HoverHeight beneath them still clears the authored 140
		-- outright (12 / (1/15) = 180) and slams at full force -- this only ever bites on a target who
		-- genuinely has no room to fall.
		SlamPenetrationGuardSeconds = 1 / 15,
		-- Floor on the clamped result, so a slam on an already-grounded target still reads as a real
		-- physical pop rather than a silent collapse -- the ragdoll itself, independent of whether
		-- Client/FX/SlamImpactVFX.BeginWatch's own detection catches it (see
		-- SlamImmediateImpactDropStuds below for that half of the story). First pass shipped this at a
		-- bare 25 -- just past Constants.FX.SlamImpact.FastFallSpeedThreshold (20 studs/s) -- and it
		-- read as barely any hit at all (RagdollController.SlamToGround's own FaceDownSpin is
		-- deliberately NOT gated by this same clearance clamp, so the pitch was never the missing
		-- piece; the velocity floor was). 50 is still well clear of the tunnel-through-the-floor regime
		-- the SlamPenetrationGuardSeconds clamp above exists to avoid (0.83 studs of travel per physics
		-- step, versus a HumanoidRootPart's own ~2-stud height, and the Ragdoll collision group /
		-- buildRagdollJoints' pose-capture fix already removed the two mechanisms -- self-collision
		-- explosion and rest-pose joint snapping -- that actually caused a grounded slam to eject
		-- upward in the first place, so this floor is no longer fighting those). Purely a feel tunable
		-- -- raise or lower freely.
		SlamMinDownVelocity = 50,
		-- Usable-drop distance (studs, from resolveSlamScale's own clearance math) at or below which
		-- RagdollController.SlamToGround reports the impact as IMMEDIATE rather than something the
		-- client should watch for. This exists because Client/FX/SlamImpactVFX.BeginWatch's own
		-- fall-then-arrest detection is a Heartbeat-rate poll (~60Hz) of REPLICATED velocity, and a
		-- clamped-to-near-zero slam (the common case: a target already standing on the ground, which
		-- is most Downslam finishers and most standalone AirSlams) travels its entire clamped drop and
		-- fully arrests within a SINGLE physics step -- often within a single Heartbeat interval, and
		-- sometimes within a single network replication snapshot, meaning the transient fast-falling
		-- velocity the poll is looking for may never be sampled, or may never even be sent to the
		-- client at all. No amount of client-side polling can reliably catch a transition that fast --
		-- the server already knows definitively (via this exact clearance calculation) that contact is
		-- essentially instantaneous, so it says so directly instead of making the client guess. A
		-- target with real height on them (a genuine multi-frame fall) stays well above this and keeps
		-- using the existing velocity-poll detection, which works fine for that case. 1.5 is comfortably
		-- inside "no meaningful fall to observe" (SlamPenetrationGuardSeconds's own 1/15s guard already
		-- caps a body at this range to a few studs/sec) while staying well clear of a genuine short hop.
		SlamImmediateImpactDropStuds = 1.5,
	},

	-- RemoteNames (every RemoteEvent CombatSystem.lua owned) was removed alongside the rest of the
	-- combat system -- every remote it named was created exclusively by CombatSystem.lua's own Init(),
	-- which no longer runs. HotbarMoveClient.lua/HotbarBindings.lua's own header still references
	-- RequestFireHotbarMove by name for historical context; that module was also removed (see
	-- Client/Combat/HotbarBindings.lua's own header on the surviving data-only half).

	-- Combat sound effects (Client/FX/CombatAudio.lua's registered names). RESTORED: this table, and
	-- CombatAudio.lua itself, were removed alongside the rest of the combat system and are being
	-- rebuilt now as the P0 out of a combat-feel audit -- CombatAudio.lua's own header has the full
	-- account. Every SoundId below is still "" except Swing.Basic (the M1 punch, now a real supplied
	-- asset) -- this codebase never guesses an asset id (see CombatAudio.lua's own header, and
	-- AnimationIds.RunningStage3 above for the identical convention on the animation side), so the rest
	-- of CombatAudio.lua stays fully wired and silent until real assets are pasted in for them too.
	-- SoundManager.Play already no-ops safely on an empty SoundId, so shipping this costs nothing but a
	-- debug log line per swing/impact still missing one.
	Sound = {
		-- The swing whoosh, keyed by AttackKind. Only Basic/Heavy are registered -- deliberately, the
		-- same "Hotbar is absent rather than zeroed" call AttackConstants.Presentation.SwingLunge.ByKind
		-- already makes for its own per-kind table: an authored Move-Editor move earning its own swing
		-- identity later is a real possibility, and a shared placeholder here now would be one more
		-- "one system, two configs" trap to unwind then. CombatAudio.PlaySwing is silent for Hotbar.
		Swing = {
			Basic = { SoundId = "rbxassetid://123533685284641", Volume = 0.5 } :: Constants.SoundDefinition,
			-- Slightly louder than Basic -- a heavy swing commits harder, and the sound should say so
			-- before the hit does, the same reasoning AttackConstants.Presentation.SwingLunge's own
			-- "further and longer than a Basic" comment gives for the step.
			Heavy = { SoundId = "", Volume = 0.65 } :: Constants.SoundDefinition,
		} :: { [string]: Constants.SoundDefinition },

		-- How long AFTER the windup ends the swing sound plays, per AttackKind -- same shape and same
		-- job as AttackConstants.Presentation.SwingLunge.ByKind's own DelaySeconds, and deliberately
		-- read through that pair's DelayFor by Client/FX/CombatAudio.lua rather than reimplemented: a
		-- sound fired the instant the button goes down is playing before the arm has moved, which reads
		-- as detached from the swing the same way an un-delayed lunge step reads as a shove rather than
		-- a punch (see that table's own header for the fuller argument -- it applies here unchanged).
		-- 0 starts the sound the frame the windup ends, i.e. exactly when the arm actually comes
		-- through -- the honest starting point until someone has actually listened and wants it moved
		-- earlier or later.
		SwingDelaySeconds = {
			Basic = 0,
			Heavy = 0,
		} :: { [string]: number },

		-- Landed-contact stingers, keyed by the outcome (DefenseTypes.OutcomeKind) rather than by move
		-- -- an impact sound answers "what kind of hit was that," which the outcome already says
		-- regardless of which weapon or stage landed it. Clean/Backstab/Trade share ONE registered
		-- sound: the brief that restored this only asked Blocked/Parried/GuardBroken to carry their own
		-- distinct identity (a duller thud, a standout skill cue, a heavier consequence), and
		-- Backstab/Trade already get their own visual answer (the shake presets, the banner) -- a
		-- fourth/fifth placeholder registration here now would be effort with no asset to point it at
		-- yet. Split out later by giving either its own key; nothing else has to change.
		--
		-- PoolSize > 1 on the sounds that can genuinely re-trigger before their own predecessor
		-- finishes -- a landed string throws Clean roughly every 0.3-0.6s at Basic-string cadence (see
		-- AttackConstants.Sequence's own stage-gap comment), comfortably inside a one-shot stinger's
		-- natural length. Parried/GuardBroken are rarer, at-most-once-per-exchange events and need less
		-- headroom.
		Impact = {
			Clean = { SoundId = "", Volume = 0.7, PoolSize = 3 } :: Constants.SoundDefinition,
			-- Its own registration rather than a quieter Clean -- "distinct, duller" is the brief, and a
			-- shared sample pitched down only approximates that; a real asset can be pointed here
			-- without touching the ordinary hit sound at all.
			Blocked = { SoundId = "", Volume = 0.55, PoolSize = 3 } :: Constants.SoundDefinition,
			-- THE STANDOUT CUE. A parry is the hardest defensive read in the system
			-- (DefenseConstants.Parry's own MinUnguardedSeconds/lockout machinery exists because it is
			-- the option worth gatekeeping) and the one outcome this codebase already treats as
			-- deserving unmistakable feedback -- see CameraShake's own asymmetry, where Parried is the
			-- one Attacker preset as loud as its Defender counterpart. Its own registration, own pool,
			-- so landing one never competes with an ordinary hit for the same Sound instance.
			Parried = { SoundId = "", Volume = 0.85, PoolSize = 2 } :: Constants.SoundDefinition,
			-- Heavier than Blocked, not a louder Clean -- a guard break is a real opening
			-- (DefenseStateMachine.BreakGuard), and DamageConstants.Guard's own header already treats it
			-- as a distinct, consequential moment rather than a bigger version of an ordinary hit.
			GuardBroken = { SoundId = "", Volume = 0.9, PoolSize = 2 } :: Constants.SoundDefinition,
		} :: { [string]: Constants.SoundDefinition },

		-- A few percent of per-play pitch variation, shared across every sound above -- the identical
		-- "identical sample on a metronome" fix Client/FX/RunAudio.lua's own PitchJitter documents,
		-- applied once here instead of per-sound since nothing about combat's stingers needs a
		-- different amount per name the way Run's per-stage cadence does.
		PitchJitter = 0.05,
	},
}

return CombatConstants
