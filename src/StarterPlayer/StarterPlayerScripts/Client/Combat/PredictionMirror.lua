--!strict
--[[
	PredictionMirror.lua

	Owns: the client's read-only local mirror of its OWN action timeline -- the plain-number
	estimate of "would the server accept this press right now" that gates predicted action-start
	feedback (Constants.Combat.Prediction; CombatClient.lua is the only real consumer). Every field
	here is an ESTIMATE reconstructed from data the server already sends this client (the
	AttackStarted/MovementPerformed/BlockStarted confirm echoes and its own Combat_FeedbackEvent
	deliveries) plus shared Constants -- nothing here is authoritative, nothing here is ever sent
	back to the server, and no gameplay outcome ever reads it. A wrong estimate costs exactly one
	mispredicted animation start, which CombatClient rolls back on the Combat_ActionRejected echo or
	the prediction timeout; the server's own validation is untouched either way.

	Pure by construction: holds plain numbers only, every method takes `now` as a parameter, and it
	touches no Instances, services (beyond requiring Constants), or remotes -- CombatClient feeds
	events in and asks questions; this module never listens to anything itself. That purity is what
	makes it the one TestEZ-coverable piece of the prediction pass (Tests/Combat/
	PredictionMirror.spec.lua) -- the same extraction reasoning as Server/Combat/Movement.lua.

	What it deliberately does NOT mirror: ragdoll and disarm lockouts (no remote currently tells
	this client its own ragdoll/disarm expiry at prediction-useful fidelity -- a misprediction there
	is rare and the rollback path covers it) and the server's rate limiters (a legit press gated by
	the mirror's cooldown fields stays far below every budget). The mirror is intentionally
	conservative-by-omission: unknown state predicts optimistically and lets rollback handle the
	rare miss, per the plan decision recorded in Constants.Combat.Prediction's header.

	Does not own: WHETHER to fire the request (CombatClient always sends the request regardless of
	the mirror's verdict -- the server is the authority and the mirror could be stale), what a
	prediction looks like (CombatAnimator/SwingEffect), or rollback bookkeeping (CombatClient's
	pending-prediction table).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local CombatDebugNames = require(ReplicatedStorage.Shared.CombatDebugNames)

-- The three-way answer to "should this press predict its action-start feedback":
--   * "Predict"   -- every mirrored gate is open; play the feedback now.
--   * "Buffered"  -- too early, but close enough to the gate opening that the server's own input
--                    buffer will throw it (AttackInputBufferSeconds); do NOT predict -- the
--                    confirm echo will drive the (slightly later, correctly-timed) feedback,
--                    exactly as an unpredicted press does today.
--   * "NoPredict" -- a mirrored gate says the server will reject (or silently expire the buffer);
--                    send the request anyway, show nothing.
export type PredictVerdict = "Predict" | "Buffered" | "NoPredict"

export type PredictedSwing = {
	-- 1-based Basic stage the next M1 press will throw -- throw-based (mirror of basicSwingIndex),
	-- NOT landing-based, whenever IsFinisher is false; see PredictedSwing's own function header for
	-- why these two are now separate mirrored counters, matching the server-side split.
	StageIndex: number,
	-- True when the LANDING-based combo count (basicComboLanded) reached
	-- Constants.Combat.BasicComboLength - 1 -- the press is the finisher. Still purely landing-based,
	-- unlike StageIndex above -- whiffing can never mispredict a finisher into existence.
	IsFinisher: boolean,
}

local PredictionMirror = {}
PredictionMirror.__index = PredictionMirror

export type PredictionMirrorInstance = typeof(setmetatable(
	{} :: {
		basicAttackReadyAt: number,
		heavyAttackReadyAt: number,
		attackEndsAt: number,
		-- Throw-based mirror of CombatState.basicSwingIndex -- see PredictedSwing's own header for why
		-- this is now separate from the landing-based basicComboLanded below.
		basicSwingIndex: number,
		basicComboLanded: number,
		basicComboExpiry: number,
		parryCooldownExpiry: number,
		dashCooldownExpiry: number,
		dashPunchReadyAt: number,
		slideCooldownExpiry: number,
		-- Mirrors CombatState.movementCooldownExpiry -- shared between Dash and Slide server-side (see
		-- that field's own header). Without mirroring it, the client would predict a Dash right after
		-- a Slide (or vice versa) whenever the OTHER move's own cooldown alone happened to already be
		-- clear, even though the server's shared gate would still reject it -- a real, avoidable
		-- misprediction/rollback.
		movementCooldownExpiry: number,
		airSlamReadyAt: number,
		airComboActiveUntil: number,
		stunExpiry: number,
		postureBrokenExpiry: number,
	},
	PredictionMirror
))

-- Mirrors CombatSystem.lua's own advanceComboIndex formula for the Basic string
-- ((comboIndex % #stages) + 1), using Constants.Combat.BasicComboLength - 1 in place of #stages --
-- the mirror has no per-weapon Stages.Basic array to read, but that constant already assumes a
-- uniform stage count across both weapons (BasicComboLength's own header: "3 normal basic hits ...
-- + the finisher"), the same assumption IsFinisher's own check already relies on.
local function nextSwingIndex(current: number): number
	return (current % (Constants.Combat.BasicComboLength - 1)) + 1
end

function PredictionMirror.New(): PredictionMirrorInstance
	local self = {
		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		attackEndsAt = 0,
		basicSwingIndex = 0,
		basicComboLanded = 0,
		basicComboExpiry = 0,
		parryCooldownExpiry = 0,
		dashCooldownExpiry = 0,
		dashPunchReadyAt = 0,
		slideCooldownExpiry = 0,
		movementCooldownExpiry = 0,
		airSlamReadyAt = 0,
		airComboActiveUntil = 0,
		stunExpiry = 0,
		postureBrokenExpiry = 0,
	}
	return setmetatable(self, PredictionMirror)
end

-- Everything back to the fresh-spawn baseline -- CombatClient calls this on CharacterAdded, since
-- the server's createFreshState does the same for the authoritative copy on respawn.
function PredictionMirror.Reset(self: PredictionMirrorInstance): ()
	self.basicAttackReadyAt = 0
	self.heavyAttackReadyAt = 0
	self.attackEndsAt = 0
	self.basicSwingIndex = 0
	self.basicComboLanded = 0
	self.basicComboExpiry = 0
	self.parryCooldownExpiry = 0
	self.dashCooldownExpiry = 0
	self.dashPunchReadyAt = 0
	self.slideCooldownExpiry = 0
	self.movementCooldownExpiry = 0
	self.airSlamReadyAt = 0
	self.airComboActiveUntil = 0
	self.stunExpiry = 0
	self.postureBrokenExpiry = 0
end

--
-- Event feeds -- CombatClient calls these from its remote handlers. Each mirrors exactly what the
-- corresponding server commit does to the authoritative CombatState (see the named call sites).
--

-- Combat_AttackStarted: the server committed a throw (commitAndThrowAttack, OR
-- handleAirSlamRequest for the standalone jump+M1 attack) -- mirror the cooldown and the
-- windup+active+recovery commitment lock. A finisher throw also resets the basic string
-- server-side at THROW time (whether or not it later connects), so mirror that too. AirSlam is
-- special-cased throughout: it echoes through this SAME event (so CombatAnimator's
-- finisherTrackName resolution can be reused for its Downslam clip) but must never be mistaken for
-- a grounded Basic/Finisher throw -- it has its own cooldown field (airSlamReadyAt, never
-- basicAttackReadyAt) and never touches the M1 combo counter (it always carries FinisherVariant =
-- "Downslam" for animation purposes only, not because it's an M1 finisher).
--
-- A genuine, non-finisher Basic throw ALSO advances basicSwingIndex AND refreshes basicComboExpiry
-- here -- the server does both unconditionally at throw time, whiff or not (see CombatState.
-- basicSwingIndex's own header and CombatSystem.lua's own throw-selection comment: "Refresh the
-- window so the combo stays alive while the player is actively swinging"). Before basicSwingIndex
-- existed, OnOwnSwingConnected was the ONLY place that touched basicComboExpiry, which was harmless
-- because nothing observable depended on the window surviving a whiff -- now that a whiffed string's
-- STAGE still has to keep cycling, this echo has to refresh the window too, or a whiff-heavy string
-- would spuriously "lapse" back to stage 1 on the client while the server keeps it alive.
function PredictionMirror.OnAttackStarted(
	self: PredictionMirrorInstance,
	payload: Types.AttackStartedPayload,
	now: number
): ()
	local commitment = payload.WindupSeconds + payload.ActiveSeconds + payload.RecoverySeconds
	self.attackEndsAt = now + commitment
	-- CooldownSeconds is additive/optional on the payload -- fall back to the commitment span
	-- (every stage's Cooldown is tuned >= windup+active+recovery, so this under-estimates at
	-- worst, which only risks a rare extra rollback, never a stuck-conservative mirror).
	local cooldown = payload.CooldownSeconds or commitment
	local isAirSlam = payload.DebugName == "AirSlam"
	if isAirSlam then
		self.airSlamReadyAt = now + cooldown
	elseif payload.IsHeavy then
		self.heavyAttackReadyAt = now + cooldown
	else
		self.basicAttackReadyAt = now + cooldown
	end
	if payload.FinisherVariant ~= nil and not isAirSlam then
		self.basicSwingIndex = 0
		self.basicComboLanded = 0
		self.basicComboExpiry = 0
	elseif not isAirSlam and not payload.IsHeavy then
		-- Mirrors resetBasicComboIfLapsed's own ordering server-side: if THIS throw itself arrives
		-- after the window already lapsed (a real pause between presses, not just a whiff), the
		-- string resets to stage 1 before advancing -- without this, a late throw would blindly
		-- advance off a stale basicSwingIndex instead of restarting the cycle.
		if now > self.basicComboExpiry then
			self.basicSwingIndex = 0
			self.basicComboLanded = 0
		end
		self.basicSwingIndex = nextSwingIndex(self.basicSwingIndex)
		self.basicComboExpiry = now + Constants.Combat.ComboResetSeconds
	end
end

-- Combat_MovementPerformed: the server committed a Dash (Movement.ApplyDash) -- mirror the shared
-- commitment lock and Dash's own cooldown (constants the client already shares; the payload itself
-- only carries the commitment duration). ASSIGNED, not maxed, exactly like the server's own
-- ApplyDash -- this also collapses any conservative OnPredictionPending horizon (below) back down
-- to the authoritative value.
function PredictionMirror.OnMovementPerformed(
	self: PredictionMirrorInstance,
	durationSeconds: number,
	now: number,
	cooldownSeconds: number?
): ()
	self.attackEndsAt = now + durationSeconds
	-- CooldownSeconds is additive/optional on the payload (a back-dash's own longer
	-- DashBackCooldownSeconds, echoed by the server -- see Types.MovementPerformedPayload's own
	-- header) -- fall back to the plain constant if somehow absent, same "under-estimate at worst"
	-- shape OnAttackStarted's own cooldown fallback already uses.
	local cooldown = cooldownSeconds or Constants.Combat.DashCooldownSeconds
	self.dashCooldownExpiry = now + cooldown
	-- Shared with Slide server-side (CombatState.movementCooldownExpiry) -- mirror it here too so a
	-- Slide prediction right after this Dash correctly reads NoPredict instead of guessing Predict
	-- and getting rolled back.
	self.movementCooldownExpiry = now + cooldown
	-- durationSeconds here is the COMMITMENT duration (Types.MovementPerformedPayload.
	-- DurationSeconds's own header: "the attackEndsAt lock this action set"), not the movement/
	-- WalkSpeed-burst duration -- handleDashRequest sends commitmentSeconds, not durationSeconds,
	-- to this same payload field. DashPunch and DashHit both confirm through this same event
	-- (neither fires its own Combat_AttackStarted -- see CombatSystem.lua's throwDashPunch/
	-- throwDashHit header), but DashPunch is the only case whose commitment is
	-- DashFrontCommitmentSeconds (~0.77, derived from its own windup+active+recovery) -- distinct
	-- from a plain dash's DashCommitmentSeconds (0.28) and DashHit's DashHitCommitmentSeconds
	-- (0.32), so this is a reliable signal, whether or not the swing actually connected (a whiffed
	-- DashPunch still costs the real player their own 4-second cooldown server-side, so this
	-- mirrors it the same way regardless of hit outcome). Comparing against
	-- DashFrontDurationSeconds (0.28) instead -- an earlier version of this check -- was a bug:
	-- that constant coincidentally equals DashCommitmentSeconds (both 0.28), so it misfired on
	-- EVERY plain dash instead of only a genuine DashPunch throw.
	if durationSeconds == Constants.Combat.DashFrontCommitmentSeconds then
		self.dashPunchReadyAt = now + Constants.Combat.DashPunch.Cooldown
	end
end

-- Combat_SlidePerformed: the server committed a Slide (Movement.ApplySlide) -- mirror the shared
-- commitment lock and Slide's own cooldown, same ASSIGNED-not-maxed shape as OnMovementPerformed.
-- A dedicated event/method rather than overloading OnMovementPerformed -- see
-- Types.SlidePerformedPayload's own header for why.
function PredictionMirror.OnSlidePerformed(self: PredictionMirrorInstance, durationSeconds: number, now: number): ()
	self.attackEndsAt = now + durationSeconds
	self.slideCooldownExpiry = now + Constants.Combat.SlideCooldownSeconds
	-- Shared with Dash server-side (CombatState.movementCooldownExpiry) -- see OnMovementPerformed's
	-- own comment for why this is mirrored too.
	self.movementCooldownExpiry = now + Constants.Combat.SlideCooldownSeconds
end

-- CombatClient just PLAYED a predicted Basic/Heavy/Dash action-start and its request is now in
-- flight. Until the confirm echo (which overwrites with authoritative numbers), the reject echo,
-- or the prediction timeout resolves it, the shared commitment gate is held conservatively closed
-- -- otherwise a second press arriving inside the round-trip gap would ALSO evaluate "Predict"
-- (the mirror only learns about the first press when its echo lands) and two predicted
-- animations would overlap. BlockStart predictions don't call this: a block press sets no
-- commitment server-side, so there's nothing to hold closed.
function PredictionMirror.OnPredictionPending(self: PredictionMirrorInstance, now: number): ()
	self.attackEndsAt = math.max(self.attackEndsAt, now + Constants.Combat.Prediction.TimeoutSeconds)
end

-- Combat_BlockStarted: ParryWindowOpened == true means this press armed a parry window AND started
-- the parry cooldown server-side (handleBlockStart); false means the press was still on cooldown,
-- which tells the mirror nothing new (its own estimate already said so, or it was wrong in a
-- direction this event can't measure).
function PredictionMirror.OnBlockStarted(self: PredictionMirrorInstance, parryWindowOpened: boolean, now: number): ()
	if parryWindowOpened then
		self.parryCooldownExpiry = now + Constants.Combat.ParryCooldownSeconds
	end
end

-- The local player's own swing CONNECTED (Combat_FeedbackEvent Kind "Hit"/"Blocked" with
-- AttackerUserId == me) -- mirror the landing-based combo advance. Keyed off the stage's trailing
-- digit (Basic1 landing makes the count 1, etc.) as an ASSIGNMENT rather than an increment, which
-- makes multi-target swings (one feedback per struck target, same digit) naturally idempotent --
-- the same once-per-swing behavior startAttackSwing's hitLanded flag enforces server-side.
-- Non-Basic names (Finisher/DashPunch/Heavy stages) carry no trailing Basic-stage digit relevant
-- to this counter... but Heavy stages DO end in digits ("Heavy1"), so this must filter to
-- non-heavy explicitly rather than trusting the digit alone.
function PredictionMirror.OnOwnSwingConnected(
	self: PredictionMirrorInstance,
	attackDebugName: string?,
	isHeavy: boolean?,
	now: number
): ()
	if isHeavy or not attackDebugName then
		return
	end
	-- Air combo window (CombatSystem.lua's applyAirCombo, mirrored): DashPunch connecting STARTS
	-- the attacker's own airComboActiveUntil window; any later own-swing connect landing while that
	-- window is still open EXTENDS it -- the same AirborneSeconds refresh applyAirCombo's
	-- continuation branch applies server-side on every hit against the tracked airComboTarget. See
	-- IsInAirCombo's own header for why this window has to gate the client's AirSlam prediction the
	-- same way handleAttackRequest's inAirCombo check gates the server's.
	if attackDebugName == "DashPunch" or now <= self.airComboActiveUntil then
		self.airComboActiveUntil = now + Constants.Combat.AirCombo.AirborneSeconds
	end
	-- Shared/CombatDebugNames.lua -- the same trailing-digit extraction Client/FX/CombatAnimator.lua
	-- and ServerScriptService/Server/Combat/BotAnimator.lua both need too; see that module's own
	-- header for why this is one shared function, not three copies (this file used to reimplement
	-- the same regex inline).
	local stage = CombatDebugNames.SwingStageFromDebugName(attackDebugName)
	if not stage then
		return
	end
	self.basicComboLanded = math.min(stage, Constants.Combat.BasicComboLength - 1)
	self.basicComboExpiry = now + Constants.Combat.ComboResetSeconds
end

-- Any enemy swing RESOLVED against the local player (Hit/Blocked/Parried with TargetUserId == me)
-- -- wasUnmitigatedHit mirrors the universal hit reaction (HitStunDuration) an unmitigated hit
-- applies.
function PredictionMirror.OnResolvedAgainstMe(
	self: PredictionMirrorInstance,
	wasUnmitigatedHit: boolean,
	now: number
): ()
	if wasUnmitigatedHit then
		self.stunExpiry = math.max(self.stunExpiry, now + Constants.Combat.HitStunDuration)
	end
end

-- The local player's own attack got PARRIED (Kind "Parried" with AttackerUserId == me) -- mirror
-- the attacker-side parry punish stun (StunDuration). wasAirComboPriorityShift true means this
-- wasn't just a punish -- it also flipped attacker priority to the parrier (AirCombo.SwitchPriority,
-- Server/Combat/AirCombo.lua), so THIS player isn't attacking anyone anymore; their own mirrored
-- air-combo window has to end right now rather than linger until its original timeout, or the very
-- next M1 press would mispredict a standalone swing as a still-active combo continuation
-- (PredictionMirror.IsInAirCombo).
function PredictionMirror.OnMyAttackParried(
	self: PredictionMirrorInstance,
	now: number,
	wasAirComboPriorityShift: boolean?
): ()
	self.stunExpiry = math.max(self.stunExpiry, now + Constants.Combat.StunDuration)
	if wasAirComboPriorityShift then
		self.airComboActiveUntil = 0
	end
end

-- The local player's own PARRY just seized air-combo priority (Kind "Parried" with
-- AirComboPriorityShift == true and TargetUserId == me -- AirCombo.SwitchPriority, Server/Combat/
-- AirCombo.lua) -- mirror the EXTENDED window (AirborneSeconds + ParryHoldExtensionSeconds, the
-- guaranteed bonus a priority-switch parry adds on top of the normal continuation window) so the
-- very next M1 press predicts a combo-continuation swing (IsInAirCombo) instead of a standalone one.
-- Assigned, not maxed, like OnOwnSwingConnected's own DashPunch-start case -- this player wasn't
-- necessarily already inside their own mirrored window a moment ago (they may have been the VICTIM
-- of the very sequence they just seized), so a stale, unrelated airComboActiveUntil must never
-- survive as a floor under the fresh one.
function PredictionMirror.OnMyParrySeizedAirComboPriority(self: PredictionMirrorInstance, now: number): ()
	self.airComboActiveUntil = now
		+ Constants.Combat.AirCombo.AirborneSeconds
		+ Constants.Combat.AirCombo.ParryHoldExtensionSeconds
end

-- The local player's own posture BROKE (Kind "PostureBreak" with TargetUserId == me) -- mirror the
-- full posture-break lockout.
function PredictionMirror.OnMyPostureBroken(self: PredictionMirrorInstance, now: number): ()
	self.postureBrokenExpiry = math.max(self.postureBrokenExpiry, now + Constants.Combat.PostureBreakDuration)
end

-- Combat_WeaponChanged: a successful swap resets all three combo counters server-side
-- (handleSwapWeaponRequest) -- only the basic string matters to this mirror.
function PredictionMirror.OnWeaponChanged(self: PredictionMirrorInstance): ()
	self.basicSwingIndex = 0
	self.basicComboLanded = 0
	self.basicComboExpiry = 0
end

-- Combat_FeintPerformed: the server accepted a Feint (handleFeintRequest), replacing the cancelled
-- swing's own remaining commitment with the shorter Constants.Combat.Feint.RecoverySeconds -- ASSIGNED,
-- not maxed, same shape as OnMovementPerformed/OnSlidePerformed, so a follow-up press right after a
-- feint reads the real (shorter) gate instead of staying conservatively locked out for the original
-- swing's now-moot commitment. Feint has no predicted action-start of its own to record here (see
-- CombatClient.lua's Feint input branch for why it skips the predict/rollback pipeline entirely), so
-- this is the mirror's only touchpoint for it.
function PredictionMirror.OnFeintPerformed(self: PredictionMirrorInstance, recoverySeconds: number, now: number): ()
	self.attackEndsAt = now + recoverySeconds
end

--
-- Queries -- CombatClient calls these at press time.
--

-- The mirrored stun/posture-break lockouts every predictable action shares.
local function isLockedOut(self: PredictionMirrorInstance, now: number): boolean
	return now < self.stunExpiry or now < self.postureBrokenExpiry
end

-- The mirrored basic combo count with the lapse rule applied (resetBasicComboIfLapsed) -- read
-- without mutating so back-to-back queries at the same `now` agree.
local function effectiveComboLanded(self: PredictionMirrorInstance, now: number): number
	if now > self.basicComboExpiry then
		return 0
	end
	return self.basicComboLanded
end

-- Same lapse rule, same shared basicComboExpiry window, for the throw-based swing index --
-- resetBasicComboIfLapsed resets both counters together server-side, so a lapsed string mirrors
-- back to stage 1 here too, not just an un-armed Finisher.
local function effectiveSwingIndex(self: PredictionMirrorInstance, now: number): number
	if now > self.basicComboExpiry then
		return 0
	end
	return self.basicSwingIndex
end

-- Shared attack-verdict shape for Basic/Heavy: full lockouts say NoPredict; an open gate says
-- Predict; a gate that opens within the server's own attack input buffer says Buffered (the press
-- will still throw -- via the buffer flush -- so predicting NOW would play the feedback early and
-- double it when the echo arrives). A gate further out than the buffer window also says NoPredict:
-- the server buffers the press but it expires before the gate opens, producing nothing.
local function evaluateAttack(self: PredictionMirrorInstance, readyAt: number, now: number): PredictVerdict
	if isLockedOut(self, now) then
		return "NoPredict"
	end
	local gateOpensAt = math.max(readyAt, self.attackEndsAt)
	if now >= gateOpensAt then
		return "Predict"
	end
	if gateOpensAt - now <= Constants.Combat.AttackInputBufferSeconds then
		return "Buffered"
	end
	return "NoPredict"
end

function PredictionMirror.EvaluateBasic(self: PredictionMirrorInstance, now: number): PredictVerdict
	return evaluateAttack(self, self.basicAttackReadyAt, now)
end

function PredictionMirror.EvaluateHeavy(self: PredictionMirrorInstance, now: number): PredictVerdict
	return evaluateAttack(self, self.heavyAttackReadyAt, now)
end

-- Which Basic stage/finisher a press accepted at `now` would throw (commitAndThrowAttack's own
-- stage selection, mirrored) -- what CombatAnimator.PlayPredictedSwing plays. Finisher eligibility
-- stays landing-based (effectiveComboLanded); which stage animation a non-finisher press shows is
-- now throw-based (effectiveSwingIndex/nextSwingIndex), matching the server-side split -- see
-- PredictedSwing's own type header.
function PredictionMirror.PredictedSwing(self: PredictionMirrorInstance, now: number): PredictedSwing
	local nextLandedStage = effectiveComboLanded(self, now) + 1
	if nextLandedStage >= Constants.Combat.BasicComboLength then
		return { StageIndex = nextLandedStage, IsFinisher = true }
	end
	return { StageIndex = nextSwingIndex(effectiveSwingIndex(self, now)), IsFinisher = false }
end

-- The Dash press: its own mirrored cooldown -- the server REJECTS a cooldown-gated Dash rather
-- than falling back to anything else, so the mirror must too. Dash has no server-side input
-- buffer (yet -- Phase 3 of the smoothing plan adds one; revisit the Buffered verdict here then).
-- isAttemptedFrontDash is CombatClient's own mirror of handleDashRequest's attemptedFrontDash
-- (double-tap-forward AND would resolve as a front dash) -- since DashPunch's cooldown only ever
-- gates a front dash. When true and DashPunch's own mirrored cooldown hasn't cleared, this
-- predicts NoPredict too -- handleDashRequest fully rejects that press (no fallback to DashHit),
-- so predicting the punch's animation here would just get rolled back a moment later, exactly the
-- flinch-and-cancel this mirror exists to avoid.
function PredictionMirror.EvaluateDash(
	self: PredictionMirrorInstance,
	now: number,
	isAttemptedFrontDash: boolean
): PredictVerdict
	if isLockedOut(self, now) or now < self.attackEndsAt then
		return "NoPredict"
	end
	if now < self.dashCooldownExpiry then
		return "NoPredict"
	end
	-- Shared with Slide server-side -- see movementCooldownExpiry's own header.
	if now < self.movementCooldownExpiry then
		return "NoPredict"
	end
	if isAttemptedFrontDash and now < self.dashPunchReadyAt then
		return "NoPredict"
	end
	return "Predict"
end

-- The Slide press: chained off Sprint, so it predicts NoPredict outright unless the LOCAL client
-- believes its own Sprint key is currently held (isSprinting -- CombatClient's own plain local
-- boolean, mirroring the isAttemptedFrontDash parameter EvaluateDash already takes: pure local
-- input state the client knows synchronously, not something reconstructed from a server echo).
-- The server independently re-checks CombatState.sprinting regardless of what this predicts. No
-- server-side input buffer for Slide either (same as Dash) -- two-verdict shape.
function PredictionMirror.EvaluateSlide(
	self: PredictionMirrorInstance,
	now: number,
	isSprinting: boolean
): PredictVerdict
	if not isSprinting then
		return "NoPredict"
	end
	if isLockedOut(self, now) or now < self.attackEndsAt then
		return "NoPredict"
	end
	if now < self.slideCooldownExpiry then
		return "NoPredict"
	end
	-- Shared with Dash server-side -- see movementCooldownExpiry's own header.
	if now < self.movementCooldownExpiry then
		return "NoPredict"
	end
	return "Predict"
end

-- The jump+M1 press while airborne (handleAirSlamRequest's own gate, mirrored): its own cooldown,
-- no server-side input buffer (same as Dash -- a too-early press just rejects, see
-- handleAirSlamRequest's own header), and the shared commitment lock like every other predictable
-- attack. CombatClient only calls this when the LOCAL character is currently airborne -- see
-- CombatClient.lua's BasicAttack input branch.
function PredictionMirror.EvaluateAirSlam(self: PredictionMirrorInstance, now: number): PredictVerdict
	if isLockedOut(self, now) or now < self.attackEndsAt then
		return "NoPredict"
	end
	if now < self.airSlamReadyAt then
		return "NoPredict"
	end
	return "Predict"
end

-- Whether the local player is currently inside their own mirrored air-combo window
-- (airComboActiveUntil, fed by OnOwnSwingConnected's own header) -- mirrors
-- handleAttackRequest's inAirCombo exemption server-side. CombatClient must check this BEFORE
-- treating a BasicAttack press as airborne-for-AirSlam: HoldAloft parks the attacker's own body
-- off the ground for the whole juggle, so the raw isAirborne signal alone can't tell "just
-- jumped" apart from "mid-combo," and predicting Downslam for a press meant to continue the
-- juggle would show the wrong swing until the confirm echo's crossfade corrects it.
function PredictionMirror.IsInAirCombo(self: PredictionMirrorInstance, now: number): boolean
	return now <= self.airComboActiveUntil
end

-- Whether a Block press right now would arm a parry window (handleBlockStart's parryAvailable
-- gate, mirrored) -- drives the local-only parry press cue. The block STANCE itself stays
-- unconditionally client-predicted (CombatAnimator.PlayBlockHold's own header); this only gates
-- the "your parry actually armed" acknowledgment.
function PredictionMirror.PredictParryAvailable(self: PredictionMirrorInstance, now: number): boolean
	if isLockedOut(self, now) or now < self.attackEndsAt then
		return false
	end
	return now >= self.parryCooldownExpiry
end

return PredictionMirror
