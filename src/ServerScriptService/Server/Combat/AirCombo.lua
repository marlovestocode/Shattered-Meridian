--!strict
--[[
	AirCombo.lua

	Owns: the air-combo/air-tech state machine -- the DashPunch-launched juggle sequence (Apply,
	CombatState.airComboTarget/airComboDummyTarget/airComboHitCount/airComboExpiry/
	airComboHoverPosition/airComboChaseOffset/airComboChaseExpiry -- see each field's own header in
	CombatTypes.lua), ending a successfully-teched suspended exchange cleanly (EndSuspendedExchange),
	the suspended victim's one-shot counter-punch (HandleSuspendedCounterPunchRequest), and the
	double-tap-W air-tech escape itself (HandleAirTechRequest). Moved out of CombatSystem.lua (Chief
	Architect's decomposition audit) as its own Server/Combat/ sibling -- this is, by a wide margin,
	the most complex state machine CombatSystem.lua used to own directly, and it already had its own
	dedicated Constants.Combat.AirCombo config table before this extraction (kept associated here:
	every tunable this module reads lives under that one name).

	Apply and EndSuspendedExchange are pure with respect to CombatSystem.lua's own private world --
	both take every CombatState/AirComboTarget they touch as explicit parameters and mutate only
	those, plus RagdollController's own physics calls -- so DummyCombat.lua's ResolveHit can call
	Apply directly (via the CombatSystem.Init()-registered ApplyAirCombo hook it already had before
	this extraction; only what THAT hook points to changed) with no new coupling.
	HandleSuspendedCounterPunchRequest/HandleAirTechRequest are request-handler-shaped, so (matching
	DummyCombat.lua/BotCombat.lua's own Init-registered Hooks pattern) they reach CombatSystem.lua's
	private feedback/vitals/posture-break infrastructure and rate limiter through Hooks, registered
	once via Init before any remote is wired -- see that type's own comment for the full one-way-
	dependency reasoning.

	Does not own: the reverse-scan helpers that need direct iteration over the COMPLETE combatStates
	dict (findAirComboAttacker -- "who is currently juggling this victim," clearSuspendedReferencesTo
	-- "drop every victim suspended with this now-gone attacker") -- those stay in CombatSystem.lua,
	the only place that owns combatStates itself, and are exposed to this module only through the
	narrow FindAirComboAttacker hook (a single lookup, not the whole table). Does not own the M1
	combo/finisher itself, hit classification, or any request gating beyond what
	HandleAirTechRequest/HandleSuspendedCounterPunchRequest need directly -- CombatSystem.lua's own
	checkCommonPreconditions/ACTION_GATES stay exactly where they are (air-tech deliberately bypasses
	them entirely -- see HandleAirTechRequest's own header for why).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local CombatTypes = require(script.Parent.CombatTypes)
local HitResolution = require(script.Parent.HitResolution)
local RagdollController = require(script.Parent.RagdollController)
local FeedbackPayload = require(script.Parent.FeedbackPayload)

local logger = Logger.scope("AirCombo")

local AirCombo = {}

type CombatState = CombatTypes.CombatState
type AirComboTarget = CombatTypes.AirComboTarget

-- Same "received/rejected/accepted" trail convention CombatSystem.lua's own request handlers use --
-- reimplemented locally (not shared) since it's a handful of lines with zero state, the same
-- "own tiny logging helpers, don't reach into a sibling for them" choice DevMenuSystem.lua already
-- makes independently of CombatSystem.lua.
local function logReceived(action: string, player: Player, extra: { [string]: unknown }?): ()
	local fields: { [string]: unknown } = { player = player.Name, userId = player.UserId, action = action }
	if extra then
		for key, value in pairs(extra) do
			fields[key] = value
		end
	end
	logger:debug("Request received", fields)
end

local function logRejected(action: string, player: Player, reason: string, extra: { [string]: unknown }?): ()
	local fields: { [string]: unknown } =
		{ player = player.Name, userId = player.UserId, action = action, reason = reason }
	if extra then
		for key, value in pairs(extra) do
			fields[key] = value
		end
	end
	logger:debug("Request rejected", fields)
end

local function logAccepted(action: string, player: Player, extra: { [string]: unknown }?): ()
	local fields: { [string]: unknown } = { player = player.Name, userId = player.UserId, action = action }
	if extra then
		for key, value in pairs(extra) do
			fields[key] = value
		end
	end
	logger:debug("Request accepted", fields)
end

-- Injected access to CombatSystem.lua's own private world -- see this file's header for why these
-- stay callbacks instead of a back-reference require. Registered once via Init (called from
-- CombatSystem.Init(), before any remote is wired) -- the same pattern DummyCombat.lua/BotCombat.lua
-- already establish, for the same reasoning (every real caller here runs well after boot).
export type Hooks = {
	IsDefensiveRateLimited: (Player) -> boolean,
	GetCombatState: (Player) -> CombatState?,
	-- "Who is currently juggling this victim" -- CombatSystem.lua's own findAirComboAttacker, which
	-- needs direct iteration over the complete combatStates dict this module never gets.
	FindAirComboAttacker: (Player, number) -> (Player?, CombatState?),
	SendVitals: (Player, CombatState) -> (),
	SendFeedback: (Player, Types.CombatFeedbackPayload) -> (),
	TriggerPostureBreak: (Player, CombatState, Player?) -> (),
}

local hooks: Hooks? = nil

function AirCombo.Init(newHooks: Hooks): ()
	hooks = newHooks
end

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
		airTechWindowExpiry = 0,
		airTechReadyAt = 0,
		airComboSuspendedUntil = 0,
		airComboSuspendedWithAttacker = nil,
	}
end

-- Air combo (Constants.Combat.AirCombo, CombatState.AirCombo.airComboTarget/airComboDummyTarget/
-- airComboHitCount/airComboExpiry -- see those fields' own headers). Called from CombatSystem.lua's
-- resolveHitAgainstTarget/DummyCombat.lua's ResolveHit for any unmitigated (non-Block) Basic-category
-- hit against a real player or training-dummy target -- never for Heavy or the M1 finisher, see each
-- call site's own gate. Two shapes:
--   - debugName == "DashPunch": STARTS a new sequence. Launches the target (ragdolled, via the same
--     RagdollController.LaunchAndRagdoll a finisher uses) and holds the attacker's own body (NOT
--     ragdolled -- RagdollController.HoldAloft) at a fixed standoff point near them so they end up
--     together.
--   - Any other Basic hit landing on the attacker's OWN tracked air-combo target, while
--     airComboExpiry hasn't lapsed: CONTINUES the sequence (re-launches the target, refreshes the
--     window) or, once airComboHitCount reaches Constants.Combat.AirCombo.MaxHits, ENDS it with a
--     ground slam + bonus damage instead of a re-launch.
--
-- Unified across a real player target and a training-dummy target via the `target: AirComboTarget`
-- adapter (CombatTypes.lua) built by each call site -- see that type's own header for what each
-- closure hides. Player-vs-dummy is still the only two shapes this covers -- a hit against a bot
-- target never reaches this function at all (BotCombat.lua's ResolveHitAgainstBot doesn't call it;
-- bots never dash so can never be the ATTACKER side of an air combo either, per CombatState.
-- airComboTarget's own header).
function AirCombo.Apply(
	attackerPlayer: Player,
	attackerState: CombatState,
	target: AirComboTarget,
	debugName: string,
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

	if debugName == "DashPunch" then
		target.setAsAirComboTarget()
		target.openAirTechWindow()
		attackerState.AirCombo.airComboHitCount = 1
		attackerState.AirCombo.airComboExpiry = now + cfg.AirborneSeconds

		-- Vertical motion is owned entirely by HoldAloft below now -- see Constants.Combat.AirCombo.
		-- HoverHeight's own header for why a launch velocity + gravity estimate got replaced.
		-- Horizontal pop + tumble spin stay: neither fights a position hold (AlignPosition only
		-- constrains position, not rotation), and they're what makes entering the hold read as a hit
		-- landing rather than a teleport.
		RagdollController.LaunchAndRagdoll(
			target.model,
			target.humanoid,
			target.rootPart,
			target.player,
			attackerState.rootPart,
			0,
			cfg.LaunchHorizontalVelocity,
			cfg.LaunchBackwardSpin,
			cfg.AirborneSeconds
		)
		local hoverPosition = target.rootPart.Position + Vector3.new(0, cfg.HoverHeight, 0)
		attackerState.AirCombo.airComboHoverPosition = hoverPosition
		RagdollController.HoldAloft(
			target.rootPart,
			target.player,
			hoverPosition,
			cfg.AirborneSeconds,
			cfg.HoverRiseSpeed,
			cfg.HoverResponsiveness
		)
		target.setRagdollExpiry(now + cfg.AirborneSeconds)
		-- A launched target can't keep holding guard while airborne and limp -- same rule a
		-- finisher's own launch already applies. No-op for a dummy (never blocks).
		target.clearBlocking()

		local attackerRoot = attackerState.rootPart
		if attackerRoot then
			-- Standoff offset: how far back + down the attacker's own hold parks them from the
			-- target's hover point, instead of holding them at the exact same point -- see
			-- CombatState.airComboChaseOffset's own header. Direction is away from the target, back
			-- toward wherever the attacker was actually standing when the punch landed (their real
			-- approach direction); falls back to a fixed world direction on the rare near-zero-
			-- distance case (DashPunch's own Offset/Size means this essentially never happens in
			-- practice) instead of normalizing a near-zero vector.
			local awayFromTarget = Vector3.new(
				attackerRoot.Position.X - target.rootPart.Position.X,
				0,
				attackerRoot.Position.Z - target.rootPart.Position.Z
			)
			local standoffDirection = if awayFromTarget.Magnitude
					> Constants.Combat.AirCombo.MinStandoffDirectionMagnitude
				then awayFromTarget.Unit
				else Vector3.new(0, 0, 1)
			local chaseOffset = standoffDirection * cfg.ChaseStandoffDistance
				- Vector3.new(0, cfg.ChaseBelowTargetOffset, 0)
			attackerState.AirCombo.airComboChaseOffset = chaseOffset

			-- The attacker's own hold -- see RagdollController.HoldAloft's own header for why this is
			-- the SAME mechanism the target's hover uses (a fixed-point AlignPosition pin) rather than
			-- a separate live-tracking chase: once the target settles, there's nothing left to
			-- continuously re-track, and holding the attacker to a fixed point too is what avoids the
			-- "snap up snap up" jerk a per-Heartbeat re-target caused.
			RagdollController.HoldAloft(
				attackerRoot,
				attackerPlayer,
				hoverPosition + chaseOffset,
				cfg.AirborneSeconds,
				cfg.ChaseSpeed,
				cfg.ChaseResponsiveness,
				-- liveBodyFacePoint = the target's hover position. Marks this as the attacker's LIVE
				-- (non-ragdolled) hold: cancels gravity so the soft pin doesn't sag ("float down"),
				-- quiets the Humanoid so the rise doesn't stutter ("stages of height"), and points the
				-- attacker at the target so continuation swings keep landing (not "OutsideArc"). See
				-- RagdollController.HoldAloft.
				hoverPosition
			)
			-- See AirComboState.airComboChaseExpiry's own header -- without this, the player's own held
			-- WASD keeps fighting the hold's pull for the whole window instead of riding along.
			attackerState.AirCombo.airComboChaseExpiry = now + cfg.AirborneSeconds
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
		RagdollController.SlamToGround(
			target.model,
			target.humanoid,
			target.player,
			cfg.SlamDownVelocity,
			cfg.SlamKnockdownSeconds
		)
		target.setRagdollExpiry(now + cfg.SlamKnockdownSeconds)
		target.clearBlocking()

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
		-- Keep them locked into the ragdoll/lockout window for the next hit -- no re-launch, no
		-- velocity touch at all: HoldAloft below already has them settled at the right height, and
		-- both re-launching and even a zero-velocity "launch" are exactly what ExtendRagdoll avoids by
		-- touching only the timer.
		RagdollController.ExtendRagdoll(target.model, cfg.AirborneSeconds)
		target.setRagdollExpiry(now + cfg.AirborneSeconds)
		-- Fresh air-tech opportunity on every continuation hit, not just the initial launch.
		target.openAirTechWindow()
		-- Refresh both holds at their SAME original points -- never freshly-computed ones, see
		-- AirComboState.airComboHoverPosition/airComboChaseOffset's own headers for why that's what
		-- keeps the height/spacing fixed across continuation hits instead of ratcheting up.
		if attackerState.AirCombo.airComboHoverPosition then
			RagdollController.HoldAloft(
				target.rootPart,
				target.player,
				attackerState.AirCombo.airComboHoverPosition,
				cfg.AirborneSeconds,
				cfg.HoverRiseSpeed,
				cfg.HoverResponsiveness
			)
		end
		if
			attackerState.rootPart
			and attackerState.AirCombo.airComboHoverPosition
			and attackerState.AirCombo.airComboChaseOffset
		then
			RagdollController.HoldAloft(
				attackerState.rootPart,
				attackerPlayer,
				attackerState.AirCombo.airComboHoverPosition + attackerState.AirCombo.airComboChaseOffset,
				cfg.AirborneSeconds,
				cfg.ChaseSpeed,
				cfg.ChaseResponsiveness,
				-- liveBodyFacePoint = the target's stored hover position -- same live-body treatment
				-- (gravity-cancel + rigid hold + face-the-target) as the initial hold above.
				attackerState.AirCombo.airComboHoverPosition
			)
			-- Same refresh as the hold above -- see AirComboState.airComboChaseExpiry's own header.
			attackerState.AirCombo.airComboChaseExpiry = now + cfg.AirborneSeconds
		end
		attackerState.AirCombo.airComboExpiry = now + cfg.AirborneSeconds
	end
end

-- Ends a successfully-teched suspended exchange (CombatState.airComboSuspendedUntil/
-- airComboSuspendedWithAttacker -- see HandleAirTechRequest's own header for how this state is
-- entered) and drops BOTH bodies back to normal footing. Reuses RagdollController.ClearHold on each
-- rootPart -- the same call the ordinary MaxHits-slam end-of-sequence path already uses, which
-- already reverses HoldAloft's live-body treatment (exitRigidHold) and restores network ownership,
-- so nothing new is needed here beyond zeroing the CombatState bookkeeping. Called from
-- CombatSystem.lua's confirmDeath/resolveHitAgainstTarget/onHeartbeat/onBotSwingHitCandidate/
-- clearSuspendedReferencesTo, and from this module's own HandleSuspendedCounterPunchRequest.
-- `attackerState` is nil-safe -- the attacker may have already left/died.
function AirCombo.EndSuspendedExchange(
	victimPlayer: Player,
	victimState: CombatState,
	attackerPlayer: Player?,
	attackerState: CombatState?
): ()
	if victimState.rootPart then
		RagdollController.ClearHold(victimState.rootPart, victimPlayer)
	end
	if attackerState and attackerState.rootPart then
		RagdollController.ClearHold(attackerState.rootPart, attackerPlayer)
	end
	victimState.AirCombo.airComboSuspendedUntil = 0
	victimState.AirCombo.airComboSuspendedWithAttacker = nil
	if attackerState then
		attackerState.AirCombo.airComboChaseExpiry = 0
	end
end

-- The suspended victim's own one-shot counter-punch -- redirected here from CombatSystem.lua's
-- handleAttackRequest's Basic-attack path while CombatState.airComboSuspendedUntil is active (see
-- that field's own header). Deliberately NOT hitbox-timed like a real swing: the "target" of this
-- punch is a specific known entity (airComboSuspendedWithAttacker), not found via arc/overlap
-- sampling, so it resolves instantly -- the same "nothing to time a window against" shape the
-- air-tech's own punish already uses. Always ends the suspended exchange afterward regardless of
-- outcome (hit/blocked/parried) -- a one-shot make-or-break moment, not a repeatable option.
function AirCombo.HandleSuspendedCounterPunchRequest(player: Player, state: CombatState, now: number): ()
	assert(hooks, "AirCombo.Init must run before any suspended counter-punch request can resolve")
	local attackerPlayer = state.AirCombo.airComboSuspendedWithAttacker
	local attackerState = if attackerPlayer then hooks.GetCombatState(attackerPlayer) else nil
	if not attackerPlayer or not attackerState or not attackerState.alive then
		-- The attacker already left/died mid-exchange -- just drop the victim back to normal footing.
		AirCombo.EndSuspendedExchange(player, state, attackerPlayer, attackerState)
		logRejected("BasicAttack", player, "SuspendedAttackerGone")
		return
	end

	-- "Only if the attacker is not hitting them" -- the attacker's own commitment lock is the same
	-- signal every OTHER action already reads to mean "currently mid-swing."
	if now < attackerState.attackEndsAt then
		logRejected("BasicAttack", player, "AttackerStillSwinging")
		return
	end

	local attackerHumanoid = attackerState.humanoid
	if not attackerHumanoid then
		AirCombo.EndSuspendedExchange(player, state, attackerPlayer, attackerState)
		logRejected("BasicAttack", player, "AttackerMissingHumanoid")
		return
	end

	-- Still fully parryable/blockable by the attacker -- everything stays parryable, including this.
	local defenseKind = HitResolution.ClassifyDefense(
		now,
		attackerState.Vitals.postureBrokenExpiry,
		attackerState.Vitals.parryWindowExpiry,
		attackerState.blocking
	)

	if defenseKind == "Parry" then
		attackerState.Vitals.parryWindowExpiry = 0
		HitResolution.ApplyParryPunish(state.Vitals, now)
		hooks.SendVitals(player, state)
		local parryPayload = FeedbackPayload.Build("Parried", player, attackerPlayer, nil, nil, false)
		hooks.SendFeedback(player, parryPayload)
		hooks.SendFeedback(attackerPlayer, parryPayload)
	else
		local damageMultiplier = if defenseKind == "Block" then Constants.Combat.BlockDamageMultiplier else 1
		local postureMultiplier = if defenseKind == "Block" then Constants.Combat.BlockPostureMultiplier else 1
		local finalDamage = Constants.Combat.AirCombo.SuspendedCounterDamage * damageMultiplier
		local finalPosture = Constants.Combat.AirCombo.SuspendedCounterPostureDamage * postureMultiplier
		if HitResolution.IsGodmode(attackerState) then
			finalDamage = 0
			finalPosture = 0
		end

		local wasPostureBroken = now < attackerState.Vitals.postureBrokenExpiry
		attackerState.Vitals.posture = math.max(0, attackerState.Vitals.posture - finalPosture)
		if attackerHumanoid.Health - finalDamage <= 0 then
			attackerState.pendingKillerUserId = player.UserId
		end
		if finalDamage > 0 then
			attackerHumanoid:TakeDamage(finalDamage)
		end
		hooks.SendVitals(attackerPlayer, attackerState)

		local kind: Types.CombatFeedbackKind = if defenseKind == "Block" then "Blocked" else "Hit"
		local hitPayload = FeedbackPayload.Build(
			kind,
			player,
			attackerPlayer,
			finalDamage,
			finalPosture,
			false,
			nil,
			"SuspendedCounter"
		)
		hooks.SendFeedback(player, hitPayload)
		hooks.SendFeedback(attackerPlayer, hitPayload)

		if attackerState.Vitals.posture <= 0 and not wasPostureBroken then
			hooks.TriggerPostureBreak(attackerPlayer, attackerState, player)
			hooks.SendVitals(attackerPlayer, attackerState)
		end
	end

	state.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	attackerState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	HitResolution.StampRecentOpponent(state, attackerPlayer, now)
	HitResolution.StampRecentOpponent(attackerState, player, now)

	AirCombo.EndSuspendedExchange(player, state, attackerPlayer, attackerState)
	logAccepted("BasicAttack", player, { attack = "SuspendedCounter", defended = defenseKind })
end

-- Double-tap-W air-tech: the victim of someone ELSE's air-combo juggle attempts to break the hold.
-- Deliberately does NOT go through CombatSystem.lua's checkCommonPreconditions/ACTION_GATES -- this
-- is the one action that must work WHILE ragdolled (that's the entire point:
-- combat-philosophy.md's "no true unblockable/unparryable without a telegraphed cost" means the
-- juggle itself needs a real counter). Still rate-limited (the SAME shared defensive budget
-- Dash/BlockStart use, via hooks.IsDefensiveRateLimited) and still requires a live CombatState.
--
-- Not itself a parryable exchange -- a defense against a defenseless state, the same way a Parry's
-- own attacker-punish isn't itself something the attacker can defend against. See
-- HitResolution.ApplyParryPunish's own header for why the punish logic is shared, not duplicated,
-- with a genuine Parry.
function AirCombo.HandleAirTechRequest(player: Player): ()
	assert(hooks, "AirCombo.Init must run before any air-tech request can resolve")
	logReceived("AirTech", player)

	if hooks.IsDefensiveRateLimited(player) then
		logRejected("AirTech", player, "RateLimited")
		return
	end
	local state = hooks.GetCombatState(player)
	if not state or not state.alive then
		logRejected("AirTech", player, "NoCombatState")
		return
	end

	local now = os.clock()
	if now < state.AirCombo.airTechReadyAt then
		logRejected("AirTech", player, "TechCooldownActive", { remainingSeconds = state.AirCombo.airTechReadyAt - now })
		return
	end

	local attackerPlayer, attackerState = hooks.FindAirComboAttacker(player, now)
	if not attackerPlayer or not attackerState then
		-- Not actually juggled right now -- nothing to spam-prevent, so no cooldown is set.
		logRejected("AirTech", player, "NotJuggled")
		return
	end

	if now > state.AirCombo.airTechWindowExpiry then
		-- Genuinely mistimed: was juggled, missed the window. Cooldown applies -- see
		-- Constants.Combat.AirCombo.TechCooldownSeconds' own header for why.
		state.AirCombo.airTechReadyAt = now + Constants.Combat.AirCombo.TechCooldownSeconds
		logRejected("AirTech", player, "MistimedWindow")
		return
	end

	-- Success: this is a REAL parry, not a full escape -- convert the hold into a suspended, mutual
	-- exchange rather than dropping either body. Capture the fixed hold points BEFORE clearing the
	-- attacker's own air-combo bookkeeping below (those fields are what the points are computed from).
	local holdPosition = attackerState.AirCombo.airComboHoverPosition
	local chaseOffset = attackerState.AirCombo.airComboChaseOffset
	local attackerRootPart = attackerState.rootPart
	local cfg = Constants.Combat.AirCombo

	-- Un-ragdoll the victim's JOINTS only (ballsocket -> Motor6D reversal) -- ownership/controller
	-- state stays exactly as a ragdoll left it until the HoldAloft refresh just below re-applies the
	-- live-body treatment. See RagdollController.RecoverJointsOnly's own header for why the full
	-- Recover() would break this (hands ownership back to the player mid-hold).
	if state.character then
		RagdollController.RecoverJointsOnly(state.character)
	end
	-- Refresh the victim's OWN hold with a liveBodyFacePoint now supplied (previously nil, a ragdoll
	-- hold) -- this is what actually applies enterRigidHold/gravity-cancel/face-orientation, the SAME
	-- live-body treatment the attacker's own hold already uses, via HoldAloft's existing refresh-in-
	-- place path (see that function's own header).
	if state.rootPart and holdPosition and attackerRootPart then
		RagdollController.HoldAloft(
			state.rootPart,
			player,
			holdPosition,
			cfg.SuspendedSeconds,
			cfg.HoverRiseSpeed,
			cfg.HoverResponsiveness,
			attackerRootPart.Position
		)
	end
	-- Keep the ATTACKER suspended alongside them too (per design: "keep them in the air suspended
	-- WITH the attacker," not drop either body) -- refresh their existing hold to the same
	-- SuspendedSeconds window so it doesn't expire out from under the victim mid-exchange.
	if attackerRootPart and holdPosition and chaseOffset then
		RagdollController.HoldAloft(
			attackerRootPart,
			attackerPlayer,
			holdPosition + chaseOffset,
			cfg.SuspendedSeconds,
			cfg.ChaseSpeed,
			cfg.ChaseResponsiveness,
			holdPosition
		)
		attackerState.AirCombo.airComboChaseExpiry = now + cfg.SuspendedSeconds
	end

	state.Vitals.ragdollExpiry = 0
	state.AirCombo.airTechWindowExpiry = 0
	-- A successful tech is NOT free -- see TechCooldownSeconds' own header: a zero-cost, infinitely
	-- repeatable escape + attacker punish would make the air-combo's own investment (DashPunch
	-- cooldown, chase commitment) worthless.
	state.AirCombo.airTechReadyAt = now + Constants.Combat.AirCombo.TechCooldownSeconds
	state.blocking = false
	state.AirCombo.airComboSuspendedUntil = now + cfg.SuspendedSeconds
	state.AirCombo.airComboSuspendedWithAttacker = attackerPlayer

	-- Ends the attacker's FREE auto-combo privilege -- any further attack they throw at this player
	-- now resolves as a normal swing (arc/LOS/ClassifyDefense all apply), not a guaranteed
	-- continuation hit against a helpless ragdoll. This is what makes "allowed to Block" meaningful.
	attackerState.AirCombo.airComboTarget = nil
	attackerState.AirCombo.airComboHitCount = 0
	attackerState.AirCombo.airComboExpiry = 0
	attackerState.AirCombo.airComboHoverPosition = nil
	attackerState.AirCombo.airComboChaseOffset = nil

	HitResolution.ApplyParryPunish(attackerState.Vitals, now)
	state.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	attackerState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	HitResolution.StampRecentOpponent(state, attackerPlayer, now)
	HitResolution.StampRecentOpponent(attackerState, player, now)
	hooks.SendVitals(attackerPlayer, attackerState)

	local payload = FeedbackPayload.Build("AirTechEscaped", attackerPlayer, player, nil, nil, false)
	hooks.SendFeedback(attackerPlayer, payload)
	hooks.SendFeedback(player, payload)

	if attackerState.Vitals.posture <= 0 then
		hooks.TriggerPostureBreak(attackerPlayer, attackerState, player)
		hooks.SendVitals(attackerPlayer, attackerState)
	end

	logAccepted("AirTech", player, { attacker = attackerPlayer.Name })
end

return AirCombo
