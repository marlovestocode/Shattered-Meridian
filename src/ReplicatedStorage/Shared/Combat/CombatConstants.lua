--!strict
--[[
	CombatConstants.lua

	Owns: the hand-authored combat content and physics-feel numbers every weapon/finisher/dash/air
	attack in the game is built from -- MaxHealth/MaxPosture and block mitigation, the Basic/Heavy/
	Finisher move catalog per weapon (Weapons) -- the air combo's Launcher/Air/AirFinisher moves among
	them -- the two standalone attacks (DashPunch/DashHit), finisher/ragdoll launch physics (Finisher/
	Ragdoll), and the wired-but-unauthored animation/sound registrations (AnimationIds/Sound) that go
	with all of it. Extracted from Shared/Constants.lua (formerly Constants.Combat) for two reasons,
	not one:

	  * IT IS THE MOVE EDITOR'S DEFAULT CONTENT, not settled canon. Every stage here is a "Default"
	    move an admin can retune live (Server/Combat/DefaultMoveRegistry.lua). Since the 2026-09-29
	    rebuild that retune is an OVERRIDE LAYERED ON TOP of these tables rather than a write into
	    them -- nothing at runtime mutates this module any more -- but it is still content a live
	    server re-shapes, which is why it lives apart from the game's central constants.
	  * IT MATCHES THE PRECEDENT THE REST OF COMBAT ALREADY SET. AttackConstants.lua/DamageConstants.lua/
	    DefenseConstants.lua/HitboxEngineConstants.lua each already left Shared/Constants.lua as their
	    own standalone module, specifically so each layer "is a module, and a module that can be added
	    or removed without editing the game's central constants table is the concrete form of that
	    claim" (AttackConstants.lua's own header). This was the one remaining piece of the pre-rewrite
	    CombatSystem.lua's own config that hadn't followed suit.

	Does not own: the Attack layer's cross-move relationship tunables (AttackConstants.lua), hitstun/
	combo-window length (DamageConstants.lua), stagger/parry (DefenseConstants.lua), or contact
	detection (HitboxEngineConstants.lua) -- see each of those files' own "Does not own" for why a
	per-move number never lives there. What IS here is precisely the per-move content those four files
	all point at instead of restating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)

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

-- THE WEAPON SWING HITBOX -- one config block, referenced by every Basic/Heavy/Finisher stage below
-- and by the two modules that decide where a swing's volume is anchored. Exposed on the table as
-- CombatConstants.Weapons.SwingHitbox; kept as a module-local as well for the same reason
-- DashPunchWindupSeconds is one -- a Lua table constructor cannot reference its own other keys.
--
-- THESE ARE HOUSE DEFAULTS, NOT THE FINAL WORD. Every field below is overridable per weapon, off
-- Attributes on the weapon's own build in Workspace.Weapons -- see Shared/Combat/WeaponRoster.lua's
-- HITBOX_ATTRIBUTE_NAMES for the Attribute names and where they may sit. A weapon that sets none of
-- them swings exactly this. Retuning here therefore moves every weapon that has not opted out, which
-- is the point: it is the house sword, and the roster is built from it.
--
-- WHY IT EXISTS. A weapon swing used to be anchored to, and sized off, the equipped weapon's own
-- "Blade" part (AttachmentPart == "Weapon" plus HitboxTypes.AttackDefinition.SizeFromAttachmentPart).
-- That made the hitbox exactly as good as the mesh: a thin blade is a thin hitbox, the volume swept
-- along with the weapon so what it covered depended on which frame of the swing clip you were on, and
-- every weapon in the roster read differently for reasons no player could see. Mode == "BodyBox"
-- replaces all of that with ONE honest volume in front of the ATTACKER.
--
-- "AFTER A WINDUP" NEEDS NO FIELD HERE. AttackStateMachine only ever enters Active from Windup, so a
-- stage's own WindupSeconds already is the delay before this box exists -- retune that per stage (or
-- put a "Hit" marker on the clip's impact frame -- Shared/Attack/AttackWindows.lua), not this table.
local SWING_HITBOX = {
	-- "BodyBox" -- every weapon stage anchors to the attacker's HumanoidRootPart and uses the Size and
	--             Offset below verbatim.
	-- "Blade"   -- the previous behaviour: anchor to the equipped weapon's Blade part and take the
	--             swing's dimensions from that part's own live Size. The per-stage Size/Offset lines
	--             below go vestigial in that mode, read only by the Move Editor's readout.
	-- Read by Server/Combat/DefaultMoveRegistry.lua (which anchor it hands the engine) and by
	-- Shared/Combat/WeaponRoster.lua (whether WeaponReach still scales the box).
	Mode = "BodyBox" :: "BodyBox" | "Blade",

	-- Studs. X is how wide the swing is, Y how tall, Z how far it reaches. 8x8 on X/Z is deliberately
	-- generous against a character's own ~2x1-stud footprint: this is a volume a player is meant to be
	-- able to READ and step out of, not a precise edge. Y is 8 rather than the stages' old 6.5 so one
	-- box covers a jumping target without a second authored case.
	Size = Vector3.new(8, 8, 8),

	-- Root-local pose the box is CENTRED on. -Z is forward (the engine's convention throughout -- see
	-- HitboxTypes.lua's LOCAL SPACE CONVENTION header), and a Box straddles its offset rather than
	-- growing forward from it, so the forward number wants to be about Size.Z/2 for the box's back face
	-- to sit flush against the attacker instead of swallowing them. At -4 with Size.Z == 8 the box
	-- spans 0..8 studs in front of the root. Push it further out for a swing that should not catch
	-- someone already inside your guard.
	Offset = CFrame.new(0, 0, -4),

	-- Whether a weapon model's own WeaponReach Attribute still scales this box's X/Z and its forward
	-- offset (Shared/Combat/WeaponRoster.applyReach). FALSE means every weapon in the roster swings the
	-- exact same volume and reach becomes a damage/speed-only distinction, which is most of the point
	-- of a fixed box -- one shape every player learns once. Flip to true to let a long weapon genuinely
	-- out-range a short one again. Inert in "Blade" mode, where reach reaches the swing through
	-- SizeMultiplier instead.
	ScaleWithWeaponReach = false,

	-- Seconds of EXTRA delay before the hitbox goes live, ON TOP of the swinging stage's own
	-- WindupSeconds. Zero here because the house timings were already playtested against the house
	-- clips; this exists for a weapon whose arc connects later than the baseline's does, and it is
	-- almost always a per-weapon answer rather than a house one.
	--
	-- Additive rather than a replacement, and applied at the very END of the chain
	-- (Server/Combat/AttackCatalog.Get, after the animation-marker override) -- see
	-- WeaponRoster.HITBOX_ATTRIBUTE_NAMES.SpawnDelay for why it cannot be folded into WindupSeconds
	-- any earlier without a marked clip silently eating it.
	SpawnDelaySeconds = 0,
}

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
-- process -- adjust freely after a playtest (Constants.MoveEditor.Limits.OffsetStuds, which the Move
-- Editor's Default-move overrides are clamped to, already covers a much wider range than this).
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
	-- CombatClient.lua's own predict/rollback path) is gone. Server/Combat/DefaultMoveRegistry.lua,
	-- the Combat/ module kept on disk, reads neither. (Server/Combat/Movement.lua was the other, and
	-- has since been deleted -- it had had no caller since the combat rewrite.)

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

	-- InCombatDurationSeconds MOVED to Shared/Engagement/EngagementConstants.TagDurationSeconds. It
	-- described how long a player stays "in combat" after their last real exchange, and it sat here at
	-- 5 with no reader at all from the combat teardown (which deleted CombatSystem.lua, its only
	-- consumer) until Server/Combat/Engagement/EngagementSystem.lua was built. It lives next to that
	-- system now, per the standalone-constants split AttackConstants/DamageConstants/DefenseConstants/
	-- GrabConstants already keep. The value did not change; only its home did.
	-- CombatSystem's own explicit baseline (Roblox's Humanoid default already happens to be 16,
	-- though this codebase no longer relies on that coincidence) -- CombatSystem now owns setting/
	-- restoring WalkSpeed so HitSlowMultiplier below has a known value to multiply and restore to.
	-- Lowered from 16 to 10 (retuned alongside DefaultBonusWalkSpeed below to land the default
	-- resting speed at 18, down from 24) -- tuning, not design, per combat-philosophy.md's Tuning
	-- process; every multiplier tier computed off base+bonus scales down proportionally with it. That
	-- is the run ladder in Server/Systems/RunSystem.lua today -- Dash's own burst tier below is one of
	-- the ones nothing drives any more.
	BaseWalkSpeed = 10,
	-- Additive speed bonus applied on top of BaseWalkSpeed via a "BonusWalkSpeed" Attribute on each
	-- player's own Humanoid (Server/Systems/RunSystem.lua reads it, and its own onCharacterAdded seeds
	-- it at spawn) rather than a flat Constants number, per luau-coding-standards.md's Attribute-API
	-- convention for per-instance runtime data -- this is meant to be driven per-player later by
	-- race/bloodline stat systems (progression-systems.md), not stay a single global forever. For
	-- now every player just gets this same default (10 + 8 = 18 effective base), a flat first-pass
	-- speed bump -- tuning, not design, per combat-philosophy.md's Tuning process. Left at 8 (not
	-- retuned) when BaseWalkSpeed above dropped -- this placeholder's own value isn't the thing
	-- being retuned here, only the resulting default speed.
	DefaultBonusWalkSpeed = 8,
	-- The "can't just run away" factor: every unmitigated hit clips WalkSpeed to base * this
	-- multiplier for HitSlowDuration. NOTHING APPLIES THIS TODAY -- the hit-slow tier lived in the
	-- deleted Server/Combat/Movement.lua, and Server/Systems/RunSystem.lua's resolver has no
	-- equivalent; combat reaches WalkSpeed only through Constants.Attributes.CombatBusyUntil, which
	-- zeroes the run's charge rather than clipping speed. The tuned pair below is kept because the
	-- reasoning it records is still the design intent, not because anything reads it. 0.6/0.3s (was ~14.4 studs/sec off a 24 base, barely slower than a brisk
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
	-- sprint-dust trickle's "moving" gate) -- the deleted Movement.IsMoving's own comment literally
	-- flagged its 0.1 as "the same 0.1 magnitude threshold ResolveDashDirection above already uses
	-- inline" before this field existed, which is exactly the kind of duplication-by-coincidence engineering-
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
	-- itself is gone (the combat rewrite deleted it), and Server/Combat/Movement.lua -- the resolver
	-- that would have applied the burst -- has since been deleted too, having had no caller since.
	-- Nothing drives Dash's WalkSpeed burst today; Server/Systems/RunSystem.lua owns WalkSpeed and has
	-- no dash tier.
	--
	-- Dash is a single proactive key (no i-frames, a low-stakes spacing tool meant to be used often
	-- in the neutral game): a quick WalkSpeed burst, limited by its own cooldown + commitment lock,
	-- not any resource (Stamina is gone).
	--
	-- SPRINT/THE RUN TIER USED TO LIVE HERE TOO (SprintSpeedMultiplier, SprintStage2*) and has fully
	-- moved out -- Shared/Run/RunConstants.lua now owns every run-stage number, as an ordered array of
	-- stage records rather than the flat per-stage fields these were, and Server/Systems/RunSystem.lua
	-- is the live WalkSpeed authority for it. See RunConstants.lua's own "SEPARATE FROM CombatConstants ON
	-- PURPOSE" header for why. There is now exactly one place the run's stage numbers live; retuning
	-- the run never touches this file. (The fields that used to sit here were dead weight, not a
	-- second live copy: Movement.lua's sprint functions that read them had no caller left once
	-- CombatSystem was deleted, same as Dash's burst above -- and that file has since been deleted
	-- outright for exactly the reason this parenthesis half-noticed.)
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

	-- Backward-specific Dash tuning (the deleted Movement.ApplyDash's isBackDash parameter, resolved
	-- from its ResolveDashDirection == "Back" -- neither exists any more; see DashSpeedMultiplier). Slide can no longer move backward at all
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

	-- A Dash resolved as "Front" (by the deleted Movement.ResolveDashDirection, mirrored client-side
	-- in CombatAnimator.lua for the DashFront clip) AND reported as a double-tap
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

	-- Slide: chained off Sprint (the deleted Movement.IsMoving had to be true too) -- a bigger,
	-- committed WalkSpeed burst than Dash, built the exact same way (ApplySlide mirrored ApplyDash in
	-- that same deleted file; neither the burst nor its resolver exists today -- see Dash above). No
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
	-- Size/Offset as DashPunch (a punch's physical reach doesn't need to differ by how it
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
		MaxTargets = 2,
	},

	-- AirSlam (the standalone jump + M1 slam) and AirCombo (the deleted AirCombo.lua's juggle window) used to
	-- live here. Both are retired: the air combo is Server/Combat/AirCombo/AirComboSystem.lua now, with its own
	-- constants (Shared/AirCombo/AirComboConstants.lua) and its own moves (Weapons.Baseline.Stages.Launcher/Air/
	-- AirFinisher below). What the old tables got right was kept there -- the 3.5-stud standoff, the 1.5-stud
	-- below-offset, a hover pinned to a point rather than a launch estimate, and ONE shared deadline for hold
	-- and continuation -- and what they got wrong was left behind: the parry-hold extension, the priority
	-- switch, and a 12-stud hover too high to follow. AirSlam's authored numbers seed the Slam finisher.

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
		-- The tighter armed-run clip. It changes only the drawn weapon's pose; it never changes movement
		-- speed. Blank is supported: CombatAnimator falls back to Running above when it has no id.
		RunningStage2 = "rbxassetid://134203885804635",
	} :: { [string]: string },

	-- PostureRegenPerSecond/HealthRegen/LockOnRange/ParryTellBroadcastRadius/MaxTrackedOpponents/
	-- PassiveVitalsSyncInterval/FeedbackHeadOffset were removed alongside the rest of the combat
	-- system -- every reader
	-- (CombatSystem.lua, CombatClient.lua, HitResolution.lua) is gone, and
	-- src/StarterPlayer/StarterCharacterScripts/Health.server.lua (the one file that still mentions
	-- HealthRegen) only ever referenced it in a comment, never read it.

	-- DebugHitboxes/Hitboxes (swept melee hitbox geometry/scheduling and its Studio debug-Part
	-- cosmetics) were removed alongside the rest of the combat system -- their one reader,
	-- Server/Combat/HitboxResolver.lua, is gone.

	-- ONE WEAPON IN HAND AT A TIME, drawn from an open roster (combat-philosophy.md's "Established
	-- systems" list names "weapon switching with swap cooldown" alongside Lock-on/Block/Parry/Posture
	-- as already-canon). The roster itself is NOT here: it is the set of models in Workspace.Weapons,
	-- read at boot by Shared/Combat/WeaponRoster.lua, each weapon deep-copying the Baseline stages
	-- below and scaling them by its own Studio Attributes. This table holds the one authored move set
	-- they are all built from, and nothing about which weapons exist.
	--
	-- Basic/Heavy each hold one entry per combo stage -- SwingSequencer wraps the attacker's stage
	-- index over however many are listed, so widening a string stays a data-only change.
	--
	-- Balance intent per combat-philosophy.md's Balance Principle #2 ("expand a kit's decision space,
	-- not just its damage") is now a per-weapon question answered by that weapon's own four
	-- Attributes -- a posture-hunting tempo weapon and a damage-race weapon are two models with
	-- different WeaponSpeed/WeaponDamage/WeaponPostureDamage, not two hand-authored stage tables.
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
		-- Minimum seconds between accepted RequestSwapWeapon calls -- long enough that swap-spamming
		-- can't be used as an exploit or evasive tool, short enough to be a real mid-fight option,
		-- matching combat-philosophy.md's framing of the swap cooldown's purpose ("prevents instant
		-- weapon-cycling as a combo exploit").
		SwapCooldownSeconds = 4,

		-- BARE FISTS -- the one weapon every combatant owns without ever picking anything up
		-- (Server/Combat/Weapon/WeaponInventorySystem.lua seeds it into a fresh record's Owned/Order,
		-- selected by default) and the one entry in the roster with no Workspace.Weapons model at all
		-- (Shared/Combat/WeaponRoster.lua synthesizes it from these four multipliers the same way a
		-- Studio-authored weapon's own Attributes would). No model also means no Handle for
		-- WeaponModelRegistry to find, so WeaponModels.Build("Fists") returns nil and WeaponVisualSystem
		-- equips no Tool at all -- an empty hand, which is the whole point.
		--
		-- Tuned as a quick, short, weak alternative to a blade -- retune freely: meaningfully less reach
		-- than even the old hardcoded Secondary sword (0.85) since a fist has no blade length at all, and
		-- faster than either (1.4) since a punch commits far less body than a swing. Kept only modestly
		-- faster so the animation has a little more weight than the original rapid punches.
		--
		-- DAMAGE IS AUTHORED AS WHAT A PUNCH DEALS, NOT AS A MULTIPLIER, and that is a fix. It used to be
		-- `Damage = 2` -- a multiplier on the house sword, so every Basic punch dealt 6.5 x 2 = 13, twice
		-- a sword's, while the comment above it claimed 0.5. A multiplier is the right mechanism (it keeps
		-- Heavy/Finisher in proportion) and the wrong thing to TYPE: nobody reading "2" knows it means 13.
		-- So the number here is the Basic hit, and Shared/Combat/WeaponRoster.lua derives the multiplier
		-- from it against Baseline's own Basic stage 1. Heavy scales in proportion (12 -> ~7.4).
		-- Tests/Combat/WeaponRoster.spec.lua (Fists case) holds the resolved hit to this number.
		Fists = {
			BasicHitDamage = 4,
			PostureDamage = 0.65,
			Reach = 0.3,
			Speed = 1.5,
		},

		-- The one place a weapon swing's volume, reach and anchor are configured. Defined as SWING_HITBOX
		-- at the top of this file (a table constructor can't reference its own keys) and re-exported here
		-- so DefaultMoveRegistry/WeaponRoster read it by its public name. Read its header before retuning:
		-- Mode is the switch between the body box and the old blade-anchored behaviour.
		SwingHitbox = SWING_HITBOX,

		-- THE HOUSE SWORD -- the one authored move set every weapon in the roster is built from.
		--
		-- There is no list of weapons in this file any more. Weapons are models in Workspace.Weapons,
		-- discovered at boot by Shared/Combat/WeaponRoster.lua, and each one deep-copies these stages
		-- and scales them by its own four Attributes (WeaponDamage/WeaponPostureDamage/WeaponReach/
		-- WeaponSpeed). What used to be the hardcoded Primary/Secondary pair is now: Primary IS this
		-- baseline, and Secondary -- the faster, shorter-reach, lower-per-hit-damage alternative -- is
		-- reproducible as a model with WeaponSpeed ~1.33, WeaponReach ~0.85, WeaponDamage ~0.7 and
		-- WeaponPostureDamage ~1.0, which is exactly the tuning relationship its own comment described
		-- in prose. Deleting that second hand-authored copy is what makes a THIRD weapon free.
		--
		-- What the Move Editor's Default moves are built from: WeaponRoster builds each weapon's own copy,
		-- DefaultMoveRegistry projects those copies (never writing them) and layers an admin's overrides
		-- on top, so an admin retunes one weapon without touching another, and retuning this baseline
		-- changes only what the NEXT boot builds from.
		Baseline = {
			DisplayName = "Sword",
			-- EVERY Size/Offset BELOW NOW COMES FROM SWING_HITBOX, and which SPACE that Offset is in depends
			-- on SWING_HITBOX.Mode -- read this before retuning any of them.
			--
			-- In the shipped "BodyBox" mode both are root-local and literal: the box is SWING_HITBOX.Size,
			-- centred on SWING_HITBOX.Offset in the attacker's own root space, opened once the stage's
			-- WindupSeconds elapses. Everything in the paragraph below describes "Blade" mode instead, which
			-- is what these stages did before and what flipping Mode restores: Server/Combat/
			-- DefaultMoveRegistry.lua anchors every stage here AttachmentPart == "Weapon" (its own
			-- weaponAnchor), which HitboxEngine.resolveAttachmentPart resolves to the
			-- equipped weapon's own "Blade" part when the model has one (falling back to Handle, then to
			-- RightHand, then to the root for a weapon authored without one -- see that function's own
			-- header). MoveTypes.ToEngineAttackDefinition also sets SizeFromAttachmentPart for every stage
			-- projected from here, so Size below is VESTIGIAL for a weapon with a real Blade part -- it is
			-- read only by the Move Editor's readout (DefaultMoveRegistry's projection)
			-- and by the fallback case where resolution missed the Blade entirely, never by a normal swing.
			-- Offset is still live either way: it composes against the resolved part's OWN local space now,
			-- so CFrame.new() (identity) means "centred exactly on the Blade" rather than "N studs in front
			-- of the root" the way it used to. Left at identity throughout rather than re-guessed per stage,
			-- since this baseline has no one Blade model to calibrate a nudge against -- an admin tuning a
			-- specific weapon that reads as offset (its mesh's own pivot sitting at the hilt rather than the
			-- centre, say) can still nudge that weapon's Offset from the Move Editor, as an override.
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
						-- The shared body box (SWING_HITBOX at the top of this file), not a per-stage volume any
						-- more -- this stage was Vector3.new(6, 6.5, 4.5) with an identity blade-local Offset. Typing a
						-- literal back in here still gives ONE stage its own volume; the shared value is the
						-- default so five stages across every weapon can't quietly drift apart.
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						-- 6.5 flat on every Basic stage of every weapon -- DamageSystem.applyOutcome pins an
						-- M1's combo-pricing stage to 1 (ComboMultiplier(1) == 1), so this authored number IS
						-- the number a player takes, unscaled, every single M1 regardless of string position.
						Damage = 6.5,
						PostureDamage = 10,
						Cooldown = 0.44,
						MaxTargets = 3,
					},
					{
						DebugName = "Basic2",
						WindupSeconds = 0.31,
						ActiveSeconds = 0.22,
						RecoverySeconds = 0.16,
						-- Shared body box; was Vector3.new(6, 6.5, 4.5).
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 6.5,
						PostureDamage = 10,
						Cooldown = 0.47,
						MaxTargets = 3,
					},
					{
						DebugName = "Basic3",
						WindupSeconds = 0.31,
						ActiveSeconds = 0.24,
						RecoverySeconds = 0.20,
						-- Shared body box; was Vector3.new(6.5, 6.5, 5.25).
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 6.5,
						PostureDamage = 12,
						Cooldown = 0.54,
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
						-- Shared body box; was Vector3.new(7, 6.5, 5.5).
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 12,
						PostureDamage = 22,
						-- 1.37, down from 3.00 -- restores the "Cooldown == Windup+Active+Recovery" invariant
						-- this table's own header requires, matching Secondary's own Heavy stage
						-- (DaggerHeavy.Cooldown ~= its own timeline). At 3.00 the heavy button was dead
						-- ~1.63s AFTER the swing had visibly ended, with nothing on screen explaining why --
						-- reads as unresponsive input, not a deliberate pause.
						Cooldown = 1.37,
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
					-- Shared body box; was Vector3.new(7, 6.5, 5.5).
					Size = SWING_HITBOX.Size,
					Offset = SWING_HITBOX.Offset,
					Damage = 20,
					PostureDamage = 35,
					Cooldown = 0.9,
					MaxTargets = 1,
				},

				-- THE AIR COMBO'S MOVES (docs/design/air-combat-and-evade.md, B3), built per weapon exactly like
				-- the stages above and tunable from the Move Editor like them. The windups ARE the design:
				-- the parry read an air string lives on is "0.02-0.22s after the windup becomes visible", so a
				-- windup changed here changes whether an air hit is read or reacted to. The scaling RULES
				-- (air-hit falloff, finisher per-hit bonus) are not here -- AirComboConstants.Damage.
				--
				-- The LAUNCHER: Space + M1 while the Basic string is live at stage >= 2 with a landed combo >=
				-- 2 (AirComboConstants.Launcher). A readable 0.42s windup -- reaction-parryable, balanced by
				-- its mix-up against Basic 3 and Heavy -- and a 0.35s recovery, so a blocked or whiffed
				-- launcher is punishable. Blockable, parryable and evadeable like any move.
				Launcher = {
					DebugName = "Launcher",
					WindupSeconds = 0.42,
					ActiveSeconds = 0.2,
					RecoverySeconds = 0.35,
					Size = SWING_HITBOX.Size,
					Offset = SWING_HITBOX.Offset,
					Damage = 7,
					PostureDamage = 10,
					Cooldown = 0.97,
					MaxTargets = 1,
				},
				-- The three air beats. 0.22s windups: a read, not a reaction. 0.16s recovery, so the next
				-- beat is ready ~0.2s after a hit lands (AirComboConstants.Timing's on-beat press).
				Air = {
					{
						DebugName = "Air1",
						WindupSeconds = 0.22,
						ActiveSeconds = 0.18,
						RecoverySeconds = 0.16,
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 4,
						PostureDamage = 6,
						Cooldown = 0.56,
						MaxTargets = 1,
					},
					{
						DebugName = "Air2",
						WindupSeconds = 0.22,
						ActiveSeconds = 0.18,
						RecoverySeconds = 0.16,
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 4,
						PostureDamage = 6,
						Cooldown = 0.56,
						MaxTargets = 1,
					},
					{
						DebugName = "Air3",
						WindupSeconds = 0.22,
						ActiveSeconds = 0.18,
						RecoverySeconds = 0.16,
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 4,
						PostureDamage = 6,
						Cooldown = 0.56,
						MaxTargets = 1,
					},
				},
				-- The two cash-outs. Slower than an air beat on purpose (0.40 / 0.34) and therefore
				-- REACTABLE: cashing out raw into a waiting victim gets parried, so a finisher has to be set
				-- up by conditioning -- the route-choice tension. What each one DOES is AirComboConstants.Slam
				-- / .Spike; the damage below is the base their per-hit bonus grows from.
				AirFinisher = {
					Slam = {
						DebugName = "AirSlamFinisher",
						WindupSeconds = 0.40,
						ActiveSeconds = 0.2,
						RecoverySeconds = 0.3,
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 8,
						PostureDamage = 12,
						Cooldown = 0.9,
						MaxTargets = 1,
					},
					Spike = {
						DebugName = "AirSpikeFinisher",
						WindupSeconds = 0.34,
						ActiveSeconds = 0.2,
						RecoverySeconds = 0.3,
						Size = SWING_HITBOX.Size,
						Offset = SWING_HITBOX.Offset,
						Damage = 6,
						PostureDamage = 10,
						Cooldown = 0.84,
						MaxTargets = 1,
					},
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
		-- tuned move -- it exists so a knockback authored in the Move Editor (MoveTypes.MoveKnockback)
		-- can't fat-finger a body clean off the map. A ragdoll that leaves the play space can't be recovered
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
	-- FlightConstants.AnimationIds for the identical convention on the animation side), so the rest
	-- of CombatAudio.lua stays fully wired and silent until real assets are pasted in for them too.
	-- SoundManager.Play already no-ops safely on an empty SoundId, so shipping this costs nothing but a
	-- debug log line per swing/impact still missing one.
	Sound = {
		-- The swing whoosh, keyed by AttackKind. Only Basic/Heavy are registered -- deliberately, the
		-- same "Hotbar is absent rather than zeroed" call AttackConstants.Presentation.SwingLunge.ByKind
		-- already makes for its own per-kind table: an authored Move-Editor move earning its own swing
		-- identity later is a real possibility, and a shared placeholder here now would be one more
		-- "one system, two configs" trap to unwind then. CombatAudio.PlaySwing is silent for Hotbar.
		--
		-- THIS TABLE IS ALSO THE GATE FOR THE PER-WEAPON OVERRIDE. A weapon that authored its own whoosh
		-- in SFX/Swing (Shared/Combat/WeaponSounds.lua) wins over whichever entry below applies -- but
		-- CombatAudio only consults the weapon at all for a kind that HAS an entry here, so "is this
		-- kind a weapon swing" stays one switch rather than two lists that could quietly disagree. Give
		-- Hotbar an entry and it opts into both layers at the same moment.
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
			Clean = { SoundId = "rbxassetid://78167398013554", Volume = 0.7, PoolSize = 3 } :: Constants.SoundDefinition,
			-- Its own registration rather than a quieter Clean -- "distinct, duller" is the brief, and a
			-- shared sample pitched down only approximates that; a real asset can be pointed here
			-- without touching the ordinary hit sound at all.
			Blocked = { SoundId = "rbxassetid://136811265205147", Volume = 0.55, PoolSize = 3 } :: Constants.SoundDefinition,
			-- THE STANDOUT CUE. A parry is the hardest defensive read in the system
			-- (DefenseConstants.Parry's own MinUnguardedSeconds/lockout machinery exists because it is
			-- the option worth gatekeeping) and the one outcome this codebase already treats as
			-- deserving unmistakable feedback -- see CameraShake's own asymmetry, where Parried is the
			-- one Attacker preset as loud as its Defender counterpart. Its own registration, own pool,
			-- so landing one never competes with an ordinary hit for the same Sound instance.
			Parried = { SoundId = "rbxassetid://131206760792389", Volume = 0.85, PoolSize = 2 } :: Constants.SoundDefinition,
			-- Heavier than Blocked, not a louder Clean -- a guard break is a real opening
			-- (DefenseStateMachine.BreakGuard), and DamageConstants.Guard's own header already treats it
			-- as a distinct, consequential moment rather than a bigger version of an ordinary hit.
			GuardBroken = { SoundId = "rbxassetid://132492701741331", Volume = 0.9, PoolSize = 2 } :: Constants.SoundDefinition,
			-- THE DODGER'S HALF of an evade: a bright whiff, the sound of a blade cutting air right where
			-- you were. Played on the defender's client only -- see EvadedAttacker below for the other
			-- half, and CombatAudio.PlayEvaded for the split.
			Evaded = { SoundId = "rbxassetid://117848751549656", Volume = 0.75, PoolSize = 2 } :: Constants.SoundDefinition,
		} :: { [string]: Constants.SoundDefinition },

		-- The ATTACKER's half of an evade -- a muted whiff. Deliberately quieter and duller than the
		-- dodger's: the dodge is the dodger's moment, and the attacker's cue only has to say "that went
		-- through nothing" without rewarding the swing that missed.
		EvadedAttacker = { SoundId = "rbxassetid://126172687057831", Volume = 0.8, PoolSize = 2 } :: Constants.SoundDefinition,

		-- The feint cue, on the feinting player's own client when the server confirms the cancel
		-- (Attack_Cancelled). Short and breathy -- a weight pulled back, not a strike.
		Feint = { SoundId = "", Volume = 0.5 } :: Constants.SoundDefinition,

		-- A few percent of per-play pitch variation, shared across every sound above -- the identical
		-- "identical sample on a metronome" fix Client/FX/RunAudio.lua's own PitchJitter documents,
		-- applied once here instead of per-sound since nothing about combat's stingers needs a
		-- different amount per name the way Run's per-stage cadence does.
		PitchJitter = 0.05,
	},
}

return CombatConstants
