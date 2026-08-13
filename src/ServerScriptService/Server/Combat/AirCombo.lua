--!strict
--[[
	AirCombo.lua

	Owns: the air-combo state machine -- the DashPunch-launched juggle sequence (Apply,
	CombatState.airComboTarget/airComboDummyTarget/airComboHitCount/airComboExpiry/
	airComboHoverPosition/airComboChaseOffset/airComboChaseExpiry/airComboHeldExpiry -- see each
	field's own header in CombatTypes.lua). Moved out of CombatSystem.lua (Chief Architect's
	decomposition audit) as its own Server/Combat/ sibling -- this is, by a wide margin, the most
	complex state machine CombatSystem.lua used to own directly, and it already had its own dedicated
	Constants.Combat.AirCombo config table before this extraction (kept associated here: every tunable
	this module reads lives under that one name).

	Also owns the priority-switch redesign (SwitchPriority) -- a continuation-hit Parry against an
	already-tracked air-combo target flips who's attacking instead of just ending the sequence: the
	parrier becomes the new attacker and starts juggling whoever they just parried, with a guaranteed
	extra Constants.Combat.AirCombo.ParryHoldExtensionSeconds on top of the normal window. Deliberately
	excludes a parried OPENING DashPunch, which stays a plain punish with no launch -- see
	SwitchPriority's own header and its one call site (CombatSystem.lua's resolveHitAgainstTarget) for
	the exact isTrackedContinuation gate. ReleaseSequence is the shared "cleanly force-end a live
	sequence" cleanup both SwitchPriority's own third-party guard and CombatSystem.lua's
	disconnect-handling call sites (releaseAirComboVictimOf/releaseAirComboAttackerOf) build on, so
	there is exactly one implementation of that cleanup rather than three near-copies.

	The victim of a DashPunch juggle stays LIVE the whole sequence (RagdollController.HoldAloft's
	liveBodyFacePoint treatment, the same non-ragdoll hold the attacker's own body already used) --
	they keep full Motor6D/Humanoid control and can Block/Parry a continuation swing exactly like any
	other hit (ClassifyDefense in CombatSystem.lua's resolveHitAgainstTarget runs against it
	unchanged; a Parry punishes the attacker and simply doesn't extend the hold, a Block eats reduced
	damage/posture, same as always), they just can't move/attack/dash/swap themselves (ACTION_GATES.
	HeldAloft) -- "stuck where the game moves them, but never helpless." Retired, as of this pass, in
	favor of that: the old air-tech escape (a scripted double-tap-W counter that converted a helpless
	ragdoll into a separate "suspended exchange" state with its own one-shot counter-punch) -- a
	ragdolled victim needed a bespoke escape hatch because it structurally COULDN'T Block/Parry; a
	live-held one doesn't need a separate mechanic when the real one already works. A training-dummy
	target has no defend concept at all (DummyState carries no `blocking` field) and stays fully
	ragdolled for the whole sequence exactly as before -- see AirCombo.Apply's own header for how it
	tells the two apart.

	Apply is pure with respect to CombatSystem.lua's own private world -- it takes every
	CombatState/AirComboTarget it touches as explicit parameters and mutates only those, plus
	RagdollController's own physics calls -- so DummyCombat.lua's ResolveHit can call it directly (via
	the CombatSystem.Init()-registered ApplyAirCombo hook) with no new coupling.

	Does not own: the M1 combo/finisher itself, hit classification (HitResolution.ClassifyDefense is
	what actually lets a held victim Block/Parry a continuation swing -- this module never touches
	it), or any request gating -- CombatSystem.lua's own checkCommonPreconditions/ACTION_GATES stay
	exactly where they are.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CombatTypes = require(script.Parent.CombatTypes)
local RagdollController = require(script.Parent.RagdollController)

local AirCombo = {}

type CombatState = CombatTypes.CombatState
type AirComboTarget = CombatTypes.AirComboTarget

-- The fresh/cleared shape of a CombatState.AirCombo sub-state -- called from CombatSystem.lua's own
-- createFreshState (initial construction) and onCharacterAdded's respawn reset (a wholesale
-- replacement of state.AirCombo rather than a field-by-field reset, so a respawn can never leave a
-- stale field behind that this constructor's own defaults don't already cover). This is the one
-- constructor CombatVitalsState/MovementState don't get -- see CombatTypes.AirComboState's own header
-- for why AirCombo.lua specifically owns this shape while character-lifecycle timing (WHEN a fresh
-- one gets built) still belongs to CombatSystem.lua.
function AirCombo.CreateState(): CombatTypes.AirComboState
	return {
		airComboTarget = nil,
		airComboDummyTarget = nil,
		airComboHitCount = 0,
		airComboExpiry = 0,
		airComboHoverPosition = nil,
		airComboChaseOffset = nil,
		airComboChaseExpiry = 0,
		airComboHeldExpiry = 0,
	}
end

-- Air combo (Constants.Combat.AirCombo, CombatState.AirCombo.airComboTarget/airComboDummyTarget/
-- airComboHitCount/airComboExpiry -- see those fields' own headers). Called from CombatSystem.lua's
-- resolveHitAgainstTarget/DummyCombat.lua's ResolveHit for any unmitigated (non-Block) Basic-category
-- hit against a real player or training-dummy target -- never for Heavy or the M1 finisher, see each
-- call site's own gate. Two shapes:
--   - debugName == "DashPunch" OR startsAirCombo: STARTS a new sequence. startsAirCombo is
--     Types.HitboxAttackDefinition.Knockback.StartsAirCombo, threaded through by name from each call
--     site's own `definition` -- an authored Move Creation System move opts into the exact same
--     launcher treatment DashPunch has always had, purely additively (every existing definition's
--     Knockback is nil or StartsAirCombo-less, so this is always false for them). Holds the target
--     near a fixed hover point and the attacker's own body (RagdollController.HoldAloft) at a fixed
--     standoff point near them so they end up together.
--   - Any other Basic hit landing on the attacker's OWN tracked air-combo target, while
--     airComboExpiry hasn't lapsed: CONTINUES the sequence (refreshes both holds/the window) or, once
--     airComboHitCount reaches Constants.Combat.AirCombo.MaxHits, ENDS it with a ground slam + bonus
--     damage instead of a re-hold.
--
-- Unified across a real player target and a training-dummy target via the `target: AirComboTarget`
-- adapter (CombatTypes.lua) built by each call site -- see that type's own header for what each
-- closure hides. `target.player` (nil for a dummy) is also what THIS function itself branches on to
-- pick the target's own physical treatment: a real player stays LIVE the whole sequence (HoldAloft's
-- liveBodyFacePoint treatment -- full Motor6D/Humanoid control, Block/Parry-capable, see this file's
-- own header for why), a dummy stays fully ragdolled exactly as before (RagdollController.
-- LaunchAndRagdoll -- no defend concept to preserve, and changing a solo practice target's feel is
-- out of scope for this pass). Player-vs-dummy is still the only two shapes this covers -- a hit
-- against a bot target never reaches this function at all (BotCombat.lua's ResolveHitAgainstBot
-- doesn't call it; bots never dash so can never be the ATTACKER side of an air combo either, per
-- CombatState.airComboTarget's own header).
function AirCombo.Apply(
	attackerPlayer: Player,
	attackerState: CombatState,
	target: AirComboTarget,
	debugName: string,
	startsAirCombo: boolean,
	now: number
): ()
	local cfg = Constants.Combat.AirCombo

	-- A lethal hit already ran Humanoid.Died/confirmDeath SYNCHRONOUSLY (TakeDamage fires it inline,
	-- before this function is ever called by resolveHitAgainstTarget/DummyCombat's ResolveHit) --
	-- never (re)launch or (re)hold a corpse. Mirrors HitResolution.ApplyFinisherPhysics's own
	-- `Health <= 0` guard (see that function's header: "a corpse should go through Roblox's own death
	-- handling, not fight a ragdoll we'd immediately have to recover"). Without this, a killing
	-- CONTINUATION hit (the target was already this attacker's tracked air-combo target) fell through
	-- into the branch below anyway and re-pinned BOTH bodies with another full AirborneSeconds
	-- HoldAloft -- the corpse hangs frozen at the hover point instead of dropping, and the (living)
	-- attacker stays stuck at WalkSpeed 0/RootControlLocked until the stale hold's own timer lapses. A
	-- non-continuation (DashPunch-start) lethal hit just returns here with nothing to clean up --
	-- isCurrentAirComboTarget() is false since this target was never set as the tracked one.
	if target.humanoid.Health <= 0 then
		if target.isCurrentAirComboTarget() then
			RagdollController.ClearHold(target.rootPart, target.player)
			if attackerState.rootPart then
				RagdollController.ClearHold(attackerState.rootPart, attackerPlayer)
			end
			attackerState.AirCombo.airComboChaseExpiry = 0
			target.clearAirComboTarget()
			attackerState.AirCombo.airComboHitCount = 0
			attackerState.AirCombo.airComboExpiry = 0
			attackerState.AirCombo.airComboHoverPosition = nil
			attackerState.AirCombo.airComboChaseOffset = nil
		end
		return
	end

	if debugName == "DashPunch" or startsAirCombo then
		target.setAsAirComboTarget()
		attackerState.AirCombo.airComboHitCount = 1
		attackerState.AirCombo.airComboExpiry = now + cfg.AirborneSeconds

		-- Vertical motion is owned entirely by HoldAloft below -- see Constants.Combat.AirCombo.
		-- HoverHeight's own header for why a launch velocity + gravity estimate got replaced.
		local hoverPosition = target.rootPart.Position + Vector3.new(0, cfg.HoverHeight, 0)
		attackerState.AirCombo.airComboHoverPosition = hoverPosition

		-- Standoff offset: how far back + down the attacker's own hold parks them from the target's
		-- hover point, instead of holding them at the exact same point -- see CombatState.
		-- airComboChaseOffset's own header. Direction is away from the target, back toward wherever
		-- the attacker was actually standing when the punch landed (their real approach direction);
		-- falls back to a fixed world direction on the rare near-zero-distance case (DashPunch's own
		-- Offset/Size means this essentially never happens in practice) instead of normalizing a
		-- near-zero vector. Computed BEFORE the target's own hold below (not after, as it used to be)
		-- so the target's own live-body facing (below) can point at this same fixed point.
		local attackerRoot = attackerState.rootPart
		local chaseOffset: Vector3? = nil
		if attackerRoot then
			local awayFromTarget = Vector3.new(
				attackerRoot.Position.X - target.rootPart.Position.X,
				0,
				attackerRoot.Position.Z - target.rootPart.Position.Z
			)
			local standoffDirection = if awayFromTarget.Magnitude
					> Constants.Combat.AirCombo.MinStandoffDirectionMagnitude
				then awayFromTarget.Unit
				else Vector3.new(0, 0, 1)
			chaseOffset = standoffDirection * cfg.ChaseStandoffDistance - Vector3.new(0, cfg.ChaseBelowTargetOffset, 0)
			attackerState.AirCombo.airComboChaseOffset = chaseOffset
		end

		if target.player then
			-- A real player stays LIVE the whole sequence: HoldAloft's liveBodyFacePoint treatment
			-- keeps their Motor6D/Humanoid control intact (gravity-cancelled, controller-quieted, only
			-- their POSITION pinned) instead of ragdolling them -- this is what actually lets them
			-- Block/Parry a continuation swing (ACTION_GATES.HeldAloft exempts BlockStart; a genuine
			-- ragdoll structurally couldn't hold a guard at all). No launch-velocity pop/tumble-spin
			-- here (unlike the dummy branch below) -- an explicit impulse fights the SAME rootPart's
			-- gravity-cancel VectorForce/AlignPosition the instant HoldAloft below applies them; the
			-- rise from HoldAloft's own HoverRiseSpeed/HoverResponsiveness alone already reads as a
			-- launch (see RagdollController.HoldAloft's own header). Faces the attacker's fixed hold
			-- point (hoverPosition + chaseOffset) so the threat stays readable/blockable in the right
			-- direction -- the mirror image of the attacker facing the target's hoverPosition below.
			-- Held-lockout only follows a pin that actually exists -- see HoldAloft's own header on
			-- why its return value matters: writing this unconditionally (as this file used to)
			-- freezes a player at WalkSpeed 0/RootControlLocked (ACTION_GATES.HeldAloft) even on a
			-- call that failed to build any physical constraint holding them up at all.
			local held = RagdollController.HoldAloft(target.rootPart, target.player, {
				Position = hoverPosition,
				DurationSeconds = cfg.AirborneSeconds,
				MaxSpeed = cfg.HoverRiseSpeed,
				Responsiveness = cfg.HoverResponsiveness,
				LiveBodyFacePoint = if chaseOffset
					then hoverPosition + chaseOffset
					else attackerRoot and attackerRoot.Position or nil,
			})
			if held then
				target.setHeldExpiry(now + cfg.AirborneSeconds)
			end
		else
			-- Training dummy: no defend concept at all (DummyState has no `blocking` field) -- keep the
			-- original ragdoll-and-launch treatment. Horizontal pop + tumble spin sell the hit landing
			-- (AlignPosition only constrains position, not rotation, so neither fights the hold below).
			RagdollController.LaunchAndRagdoll(
				target.model,
				target.humanoid,
				target.rootPart,
				target.player,
				attackerState.rootPart,
				{
					UpVelocity = 0,
					HorizontalVelocity = cfg.LaunchHorizontalVelocity,
					BackwardSpin = cfg.LaunchBackwardSpin,
					RagdollSeconds = cfg.AirborneSeconds,
				}
			)
			RagdollController.HoldAloft(target.rootPart, target.player, {
				Position = hoverPosition,
				DurationSeconds = cfg.AirborneSeconds,
				MaxSpeed = cfg.HoverRiseSpeed,
				Responsiveness = cfg.HoverResponsiveness,
			})
			target.setRagdollExpiry(now + cfg.AirborneSeconds)
		end

		if attackerRoot and chaseOffset then
			-- The attacker's own hold -- see RagdollController.HoldAloft's own header for why this is
			-- the SAME mechanism the target's hover uses (a fixed-point AlignPosition pin) rather than
			-- a separate live-tracking chase: once the target settles, there's nothing left to
			-- continuously re-track, and holding the attacker to a fixed point too is what avoids the
			-- "snap up snap up" jerk a per-Heartbeat re-target caused.
			local attackerHeld = RagdollController.HoldAloft(attackerRoot, attackerPlayer, {
				Position = hoverPosition + chaseOffset,
				DurationSeconds = cfg.AirborneSeconds,
				MaxSpeed = cfg.ChaseSpeed,
				Responsiveness = cfg.ChaseResponsiveness,
				-- The target's hover position. Marks this as the attacker's LIVE (non-ragdolled) hold:
				-- cancels gravity so the soft pin doesn't sag ("float down"), quiets the Humanoid so the
				-- rise doesn't stutter ("stages of height"), and points the attacker at the target so
				-- continuation swings keep landing (not "OutsideArc"). See RagdollController.HoldAloft.
				LiveBodyFacePoint = hoverPosition,
			})
			-- See AirComboState.airComboChaseExpiry's own header -- without this, the player's own held
			-- WASD keeps fighting the hold's pull for the whole window instead of riding along. Only set
			-- when the chase pin actually exists -- see HoldAloft's own header on why its return value
			-- matters (a failed pin here would otherwise still WalkSpeed-lock the attacker to nothing).
			if attackerHeld then
				attackerState.AirCombo.airComboChaseExpiry = now + cfg.AirborneSeconds
			end
		end
		return
	end

	if not target.isCurrentAirComboTarget() or now > attackerState.AirCombo.airComboExpiry then
		return
	end

	attackerState.AirCombo.airComboHitCount += 1

	if attackerState.AirCombo.airComboHitCount >= cfg.MaxHits then
		-- Slam finisher -- the sequence ends here regardless of whether the target survives it.
		-- Clear the still-active hold first -- a lingering upward AlignPosition pin fighting the
		-- slam's own downward velocity would read as a weaker slam than intended.
		RagdollController.ClearHold(target.rootPart, target.player)
		local immediateGroundImpact = RagdollController.SlamToGround(
			target.model,
			target.humanoid,
			target.rootPart,
			target.player,
			attackerState.rootPart,
			{
				DownVelocity = cfg.SlamDownVelocity,
				FaceDownSpin = cfg.FaceDownSpin,
				KnockdownSeconds = cfg.SlamKnockdownSeconds,
			}
		)
		target.setRagdollExpiry(now + cfg.SlamKnockdownSeconds)
		target.clearBlocking()

		-- Fired the instant the slam's own physics actually lands, regardless of whether the bonus
		-- damage below then kills the target -- a killing slam still physically hits the ground and
		-- should still show the impact. See AirComboTarget.onGroundSlam's own header (CombatTypes.lua)
		-- for why this landed hit's own "Hit" feedback event (already sent by the caller before this
		-- function ever ran) can't carry the signal that triggers SlamImpactVFX itself.
		if target.onGroundSlam then
			target.onGroundSlam(immediateGroundImpact)
		end

		-- Same godmode rule as every other damage source -- see HitResolution.IsGodmode's own header
		-- (folded into `applyDamage` for a player target; a dummy has no godmode concept at all).
		target.applyDamage(cfg.SlamBonusDamage)

		-- The attacker lands normally once the sequence is over -- clear their own hold too, same
		-- reasoning as the target's hold clear above (also hands their movement control back
		-- immediately instead of waiting out the rest of the window).
		if attackerState.rootPart then
			RagdollController.ClearHold(attackerState.rootPart, attackerPlayer)
		end
		-- ClearHold only hands back network ownership -- per its own header, it never touches this
		-- field, so it has to be zeroed right here or the player stays pinned at WalkSpeed 0 for
		-- whatever's left of the original window even though the pull already stopped.
		attackerState.AirCombo.airComboChaseExpiry = 0

		target.clearAirComboTarget()
		attackerState.AirCombo.airComboHitCount = 0
		attackerState.AirCombo.airComboExpiry = 0
		attackerState.AirCombo.airComboHoverPosition = nil
		attackerState.AirCombo.airComboChaseOffset = nil
	else
		-- Keep them locked into the hold/lockout window for the next hit -- no re-launch, no velocity
		-- touch at all: HoldAloft below already has them settled at the right height. The player
		-- branch's own setHeldExpiry moved below, alongside the hold it actually depends on -- see
		-- that HoldAloft call's own comment.
		if not target.player then
			-- Dummy only -- extends the RagdollController ragdoll-recovery timer WITHOUT touching
			-- velocity/constraints/ownership (a live-held player was never registered in that table at
			-- all, so this would be a harmless no-op for one, but skipping it documents the split).
			RagdollController.ExtendRagdoll(target.model, cfg.AirborneSeconds)
			target.setRagdollExpiry(now + cfg.AirborneSeconds)
		end
		-- Refresh both holds at their SAME original points -- never freshly-computed ones, see
		-- AirComboState.airComboHoverPosition/airComboChaseOffset's own headers for why that's what
		-- keeps the height/spacing fixed across continuation hits instead of ratcheting up.
		if attackerState.AirCombo.airComboHoverPosition then
			local targetHeld = RagdollController.HoldAloft(target.rootPart, target.player, {
				Position = attackerState.AirCombo.airComboHoverPosition,
				DurationSeconds = cfg.AirborneSeconds,
				MaxSpeed = cfg.HoverRiseSpeed,
				Responsiveness = cfg.HoverResponsiveness,
				-- Live-body facing refresh for a player target only -- see the DashPunch-start branch's
				-- own comment for why this points at the attacker's fixed hold point. nil for a dummy
				-- (stays ragdolled -- no facing to maintain).
				LiveBodyFacePoint = if target.player and attackerState.AirCombo.airComboChaseOffset
					then attackerState.AirCombo.airComboHoverPosition + attackerState.AirCombo.airComboChaseOffset
					else nil,
			})
			-- Held-lockout only follows a pin that actually exists -- see HoldAloft's own header on why
			-- its return value matters (a failed refresh here used to keep a player frozen regardless).
			if targetHeld and target.player then
				target.setHeldExpiry(now + cfg.AirborneSeconds)
			end
		end
		if
			attackerState.rootPart
			and attackerState.AirCombo.airComboHoverPosition
			and attackerState.AirCombo.airComboChaseOffset
		then
			local attackerHeld = RagdollController.HoldAloft(attackerState.rootPart, attackerPlayer, {
				Position = attackerState.AirCombo.airComboHoverPosition + attackerState.AirCombo.airComboChaseOffset,
				DurationSeconds = cfg.AirborneSeconds,
				MaxSpeed = cfg.ChaseSpeed,
				Responsiveness = cfg.ChaseResponsiveness,
				-- The target's stored hover position -- same live-body treatment (gravity-cancel + rigid
				-- hold + face-the-target) as the initial hold above.
				LiveBodyFacePoint = attackerState.AirCombo.airComboHoverPosition,
			})
			-- Same refresh as the hold above -- see AirComboState.airComboChaseExpiry's own header. Same
			-- HoldAloft-return-value gate as every other WalkSpeed-locking write in this file.
			if attackerHeld then
				attackerState.AirCombo.airComboChaseExpiry = now + cfg.AirborneSeconds
			end
		end
		attackerState.AirCombo.airComboExpiry = now + cfg.AirborneSeconds
	end
end

-- Force-ends attackerState's own currently-tracked air-combo sequence, if one is actually live (a
-- target set AND now <= airComboExpiry) -- releases the held victim's own physical hold + held-
-- lockout (when victimState is supplied) AND this attacker's own physical chase-hold, then zeroes
-- every AirCombo field on the attacker's side a live sequence populates. Returns whether a live
-- sequence actually existed to release (false is a harmless no-op for every caller).
--
-- Three call sites share this one implementation instead of three near-copies of the same cleanup:
--   - CombatSystem.lua's releaseAirComboVictimOf (a disconnecting ATTACKER) -- passes the departing
--     victim's own CombatState so their hold gets released too.
--   - CombatSystem.lua's releaseAirComboAttackerOf (a disconnecting VICTIM) -- passes nil for
--     victimState; the departing victim's own physical/state cleanup is already handled by
--     onCharacterRemoving/onPlayerRemoving's own lifecycle for THAT player, this call only needs to
--     fix the attacker's side of the relationship.
--   - CombatSystem.lua's resolveHitAgainstTarget, as SwitchPriority's own third-party guard: a
--     parrier who's ABOUT to become the new attacker of one sequence might already be mid-chase as
--     the attacker of a completely different, unrelated one (Constants.Combat.AirCombo.
--     airComboChaseExpiry doesn't gate ACTION_GATES.HeldAloft, so a player mid-chase-as-attacker is
--     still hittable/parryable by someone else) -- that stale sequence has to be force-ended before
--     SwitchPriority overwrites their AirCombo table, or its own victim would be stranded mid-air
--     with no attacker left to track them. Resolved in CombatSystem.lua rather than inside
--     SwitchPriority itself: only that System can look up a stale third party's own CombatState by
--     Player (this module stays pure w.r.t. CombatSystem's private world -- see this file's own
--     header and CombatSystem.Init's own comment on why AirCombo.lua takes no lookup hooks).
function AirCombo.ReleaseSequence(
	attackerPlayer: Player,
	attackerState: CombatState,
	victimState: CombatState?,
	now: number
): boolean
	local heldVictim = attackerState.AirCombo.airComboTarget
	if not heldVictim or now > attackerState.AirCombo.airComboExpiry then
		return false
	end

	if victimState and victimState.character then
		RagdollController.Recover(victimState.character)
		if victimState.rootPart then
			RagdollController.ClearHold(victimState.rootPart, heldVictim)
		end
		victimState.Vitals.ragdollExpiry = 0
		victimState.AirCombo.airComboHeldExpiry = 0
	end

	-- The attacker's own physical chase-hold -- harmless to clear even when their character is about
	-- to be destroyed anyway (a disconnecting attacker), and load-bearing when it isn't (the
	-- third-party guard above): without this, the stale AlignPosition's own MaxVelocity/
	-- Responsiveness (tuned for whichever role -- hover or chase -- it was PREVIOUSLY holding) would
	-- survive into a fresh HoldAloft call's "refresh in place" branch instead of being rebuilt fresh
	-- for its NEW role, see RagdollController.HoldAloft's own header for that refresh-vs-rebuild split.
	if attackerState.rootPart then
		RagdollController.ClearHold(attackerState.rootPart, attackerPlayer)
	end

	attackerState.AirCombo.airComboTarget = nil
	attackerState.AirCombo.airComboHitCount = 0
	attackerState.AirCombo.airComboExpiry = 0
	attackerState.AirCombo.airComboHoverPosition = nil
	attackerState.AirCombo.airComboChaseOffset = nil
	attackerState.AirCombo.airComboChaseExpiry = 0

	return true
end

-- Priority switch: a continuation-hit Parry against an already-airborne, already-tracked air-combo
-- target flips who's attacking instead of just ending the sequence. CombatSystem.lua's Parry branch
-- in resolveHitAgainstTarget is the ONLY call site, gated on its own isTrackedContinuation check --
-- never reached for a parried OPENING DashPunch (attackerState.AirCombo.airComboTarget isn't set to
-- targetPlayer until AFTER a DashPunch already lands, so a parry on the punch itself never satisfies
-- that gate), which is what keeps a parried opener a plain punish with no launch, per
-- combat-philosophy.md's confirmed scope for this redesign.
--
-- newAttackerPlayer/newAttackerState is the parrier, seizing priority; oldAttackerPlayer/
-- oldAttackerState is whoever just threw (and had parried) the continuation hit, becoming the new
-- held victim. Both sides get direct CombatState access (unlike Apply's own `target: AirComboTarget`
-- adapter) -- the old-attacker side can never be a training dummy (a dummy never attacks, so it can
-- never be the ATTACKER side of a sequence in the first place, per CombatState.airComboTarget's own
-- header), so there is no player-vs-dummy ambiguity here for an adapter to abstract over, and the
-- migration below needs to read AND write the OLD attacker's stored hoverPosition/chaseOffset
-- anchors directly -- fields the AirComboTarget adapter's fixed shape doesn't expose at all.
--
-- Reuses the SAME two fixed anchors (H = the sequence's ORIGINAL airComboHoverPosition, C = its
-- ORIGINAL airComboChaseOffset) every continuation hit already refreshes onto instead of recomputing
-- either one -- see those fields' own headers in CombatTypes.lua. A switch swaps WHICH PLAYER'S
-- ROOTPART IS PINNED TO WHICH POINT (new victim -> H, new attacker -> H + C) rather than moving
-- either point, which is what keeps a long back-and-forth rally spatially anchored to the original
-- DashPunch impact instead of ratcheting upward/outward with every trade -- the exact same
-- "reuse, never recompute" reasoning Apply's own continuation branch already documents.
--
-- Every switch adds Constants.Combat.AirCombo.ParryHoldExtensionSeconds on top of the normal
-- AirborneSeconds window (both sides' timers, so a rally of trades keeps BOTH players airborne
-- longer with every exchange) -- the reward for the harder, correctly-timed defensive read a
-- continuation parry requires, on top of the punish/disarm resolveHitAgainstTarget's Parry branch
-- already applies to the newly-demoted attacker. Caller's responsibility, not this function's: force-
-- ending any pre-existing, UNRELATED sequence newAttackerState might already be running as an
-- attacker elsewhere -- see ReleaseSequence's own header for why that guard has to live in
-- CombatSystem.lua instead of here.
function AirCombo.SwitchPriority(
	newAttackerPlayer: Player,
	newAttackerState: CombatState,
	oldAttackerPlayer: Player,
	oldAttackerState: CombatState,
	now: number
): ()
	-- Defensive re-check, mirroring Apply's own continuation gate (`not target.isCurrentAirComboTarget()
	-- or now > attackerState.AirCombo.airComboExpiry`) -- resolveHitAgainstTarget's own
	-- isTrackedContinuation already verified this before throwing the switch, but this module never
	-- trusts a caller-computed invariant it can cheaply re-verify itself.
	if
		oldAttackerState.AirCombo.airComboTarget ~= newAttackerPlayer
		or now > oldAttackerState.AirCombo.airComboExpiry
	then
		return
	end

	local oldAttackerCharacter = oldAttackerState.character
	local oldAttackerHumanoid = oldAttackerState.humanoid
	local oldAttackerRoot = oldAttackerState.rootPart
	local newAttackerRoot = newAttackerState.rootPart
	if not oldAttackerCharacter or not oldAttackerHumanoid or not oldAttackerRoot or not newAttackerRoot then
		return
	end

	-- Same corpse guard Apply itself opens with -- a parry punish never deals health damage (only
	-- posture), but a same-tick death from an unrelated source must never be handed a fresh hold.
	if oldAttackerHumanoid.Health <= 0 then
		return
	end

	-- H/C -- see this function's own header. Both are read directly off the OLD attacker's own
	-- CombatState (the sequence's existing record of them -- state ownership never moved until this
	-- migration, see AirComboState's own header on why the ATTACKER side is where these anchors live).
	local hoverPosition = oldAttackerState.AirCombo.airComboHoverPosition
	local chaseOffset = oldAttackerState.AirCombo.airComboChaseOffset
	if not hoverPosition or not chaseOffset then
		return
	end

	local cfg = Constants.Combat.AirCombo
	local extendedExpiry = now + cfg.AirborneSeconds + cfg.ParryHoldExtensionSeconds
	local extendedDuration = extendedExpiry - now

	-- Old attacker -> new victim: live-held at H, facing the new attacker's own point (H + C) -- the
	-- SAME live-body treatment (Motor6D/Humanoid control intact, Block/Parry-capable) Apply's own
	-- DashPunch-start/continuation branches already give a real-player target. math.max, never
	-- assigned, matching every other airComboHeldExpiry writer (CombatTypes.AirComboState.
	-- airComboHeldExpiry's own header) -- only when the pin actually exists, same HoldAloft-return
	-- gate as every other held-lockout write (see HoldAloft's own header for why).
	local oldAttackerHeld = RagdollController.HoldAloft(oldAttackerRoot, oldAttackerPlayer, {
		Position = hoverPosition,
		DurationSeconds = extendedDuration,
		MaxSpeed = cfg.HoverRiseSpeed,
		Responsiveness = cfg.HoverResponsiveness,
		LiveBodyFacePoint = hoverPosition + chaseOffset,
	})
	if oldAttackerHeld then
		oldAttackerState.AirCombo.airComboHeldExpiry =
			math.max(oldAttackerState.AirCombo.airComboHeldExpiry, extendedExpiry)
	end

	-- New attacker -> takes over the chase pin at H + C, facing H -- the same live-body chase
	-- treatment Apply's own attacker-side hold uses. If newAttackerState was itself the held victim a
	-- moment ago, this is what physically frees their body from that pin (HoldAloft's own
	-- "refresh-in-place" branch handles a rootPart that's already pinned by rebuilding it fresh for
	-- this new role -- see ReleaseSequence's own header on why a stale hold's tuning can't just be
	-- refreshed in place across a role change; a victim's own hold never carries that risk since it's
	-- being pinned FRESH here regardless).
	local newAttackerHeld = RagdollController.HoldAloft(newAttackerRoot, newAttackerPlayer, {
		Position = hoverPosition + chaseOffset,
		DurationSeconds = extendedDuration,
		MaxSpeed = cfg.ChaseSpeed,
		Responsiveness = cfg.ChaseResponsiveness,
		LiveBodyFacePoint = hoverPosition,
	})

	-- Full migration -- old attacker's own tracking clears (they're not attacking anyone now); new
	-- attacker inherits the sequence at hit count 1, mirroring what a genuine DashPunch-start already
	-- does (every "possession" of the juggle gets the same MaxHits budget).
	oldAttackerState.AirCombo.airComboTarget = nil
	oldAttackerState.AirCombo.airComboHitCount = 0
	oldAttackerState.AirCombo.airComboExpiry = 0
	oldAttackerState.AirCombo.airComboHoverPosition = nil
	oldAttackerState.AirCombo.airComboChaseOffset = nil
	-- Load-bearing, not cosmetic: ClearHold only hands back network ownership, it never touches this
	-- field (RagdollController.ClearHold's own header) -- without zeroing it here, Movement.
	-- ComputeDesiredWalkSpeed keeps the old attacker pinned at WalkSpeed 0 for whatever's left of the
	-- ORIGINAL window even though their own pull just stopped (they're a live-held victim now, with
	-- airComboHeldExpiry above doing that job instead).
	oldAttackerState.AirCombo.airComboChaseExpiry = 0

	newAttackerState.AirCombo.airComboTarget = oldAttackerPlayer
	newAttackerState.AirCombo.airComboHitCount = 1
	newAttackerState.AirCombo.airComboExpiry = extendedExpiry
	newAttackerState.AirCombo.airComboHoverPosition = hoverPosition
	newAttackerState.AirCombo.airComboChaseOffset = chaseOffset
	-- Same HoldAloft-return gate as the old attacker's own held-lockout above: only WalkSpeed-lock the
	-- new attacker to a chase pin that actually exists.
	newAttackerState.AirCombo.airComboChaseExpiry = if newAttackerHeld then extendedExpiry else 0
	-- Load-bearing: clears ACTION_GATES.HeldAloft (CombatTypes.AirComboState.airComboHeldExpiry's own
	-- header) so the new attacker -- who may have been the held victim themselves a moment ago -- can
	-- act immediately instead of waiting out whatever was left of their own stale held-lockout timer.
	newAttackerState.AirCombo.airComboHeldExpiry = 0
end

return AirCombo
