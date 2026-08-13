--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local PredictionMirror = require(StarterPlayer.StarterPlayerScripts.Client.Combat.PredictionMirror) :: any

-- A representative Basic-stage echo (Primary Basic1's real numbers don't matter to the mirror's
-- logic -- only that cooldown > windup+active+recovery > AttackInputBufferSeconds holds, which
-- every real stage satisfies and these do too).
local function basicStarted(finisherVariant: Types.FinisherVariant?): Types.AttackStartedPayload
	return {
		IsHeavy = false,
		DebugName = "Basic1",
		WindupSeconds = 0.1,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.15,
		CooldownSeconds = 0.5,
		WeaponId = "Primary" :: Types.WeaponId,
		FinisherVariant = finisherVariant,
	}
end

local function heavyStarted(): Types.AttackStartedPayload
	return {
		IsHeavy = true,
		DebugName = "Heavy1",
		WindupSeconds = 0.2,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.35,
		CooldownSeconds = 0.75,
		WeaponId = "Primary" :: Types.WeaponId,
		FinisherVariant = nil,
	}
end

-- The standalone AirSlam attack's own echo -- DebugName = "AirSlam", FinisherVariant = "Downslam"
-- (for CombatAnimator's finisherTrackName resolution only, not because it's an M1 finisher -- see
-- Constants.Combat.AirSlam's own header).
local function airSlamStarted(): Types.AttackStartedPayload
	return {
		IsHeavy = false,
		DebugName = "AirSlam",
		WindupSeconds = 0.35,
		ActiveSeconds = 0.22,
		RecoverySeconds = 0.3,
		CooldownSeconds = 3,
		WeaponId = "Primary" :: Types.WeaponId,
		FinisherVariant = "Downslam" :: Types.FinisherVariant,
	}
end

return function()
	-- Fixed epoch well past 0 so a fresh mirror's zeroed fields can't accidentally sit inside any
	-- test's `now`.
	local T = 1000

	describe("PredictionMirror.EvaluateBasic", function()
		it("predicts on a fresh mirror", function()
			local mirror = PredictionMirror.New()
			expect(mirror:EvaluateBasic(T)).to.equal("Predict")
		end)

		it("returns NoPredict immediately after a throw (gate further out than the buffer)", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:EvaluateBasic(T + 0.05)).to.equal("NoPredict")
		end)

		it("returns Buffered when the gate opens within AttackInputBufferSeconds", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			-- Gate opens at T + 0.5 (cooldown > commitment); the buffer window is 0.2 wide.
			local pressAt = T + 0.5 - Constants.Combat.AttackInputBufferSeconds + 0.01
			expect(mirror:EvaluateBasic(pressAt)).to.equal("Buffered")
		end)

		it("returns NoPredict just outside the buffer window (the server-side buffer would expire)", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			local pressAt = T + 0.5 - Constants.Combat.AttackInputBufferSeconds - 0.01
			expect(mirror:EvaluateBasic(pressAt)).to.equal("NoPredict")
		end)

		it("predicts again once the cooldown fully clears", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:EvaluateBasic(T + 0.5)).to.equal("Predict")
		end)

		it("falls back to the commitment span when the echo carries no CooldownSeconds", function()
			local mirror = PredictionMirror.New()
			local payload = basicStarted(nil)
			payload.CooldownSeconds = nil
			mirror:OnAttackStarted(payload, T)
			-- Commitment = 0.45; past that the mirror must open even without the cooldown field.
			expect(mirror:EvaluateBasic(T + 0.46)).to.equal("Predict")
		end)

		it("is locked out by a mirrored parry punish stun, then recovers", function()
			local mirror = PredictionMirror.New()
			mirror:OnMyAttackParried(T)
			expect(mirror:EvaluateBasic(T + Constants.Combat.StunDuration - 0.05)).to.equal("NoPredict")
			expect(mirror:EvaluateBasic(T + Constants.Combat.StunDuration + 0.05)).to.equal("Predict")
		end)

		it("is locked out by a mirrored posture break", function()
			local mirror = PredictionMirror.New()
			mirror:OnMyPostureBroken(T)
			expect(mirror:EvaluateBasic(T + 0.1)).to.equal("NoPredict")
			expect(mirror:EvaluateBasic(T + Constants.Combat.PostureBreakDuration + 0.05)).to.equal("Predict")
		end)

		it("is locked out by a mirrored hit-stun from taking an unmitigated hit", function()
			local mirror = PredictionMirror.New()
			mirror:OnResolvedAgainstMe(true, T)
			expect(mirror:EvaluateBasic(T + Constants.Combat.HitStunDuration - 0.05)).to.equal("NoPredict")
			expect(mirror:EvaluateBasic(T + Constants.Combat.HitStunDuration + 0.05)).to.equal("Predict")
		end)

		it("is not locked out by a resolution against me that dealt no hit (block/parry)", function()
			local mirror = PredictionMirror.New()
			mirror:OnResolvedAgainstMe(false, T)
			expect(mirror:EvaluateBasic(T + 0.01)).to.equal("Predict")
		end)
	end)

	describe("PredictionMirror.EvaluateHeavy", function()
		it("tracks the heavy cooldown independently of basic", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(heavyStarted(), T)
			-- Heavy gate = max(heavyReadyAt = T+0.75, attackEndsAt = T+0.75) -- blocked...
			expect(mirror:EvaluateHeavy(T + 0.1)).to.equal("NoPredict")
			-- ...while Basic is gated only by the shared commitment (attackEndsAt = T+0.75), so at
			-- T+0.6 the basic gate is 0.15 away -> inside the buffer window.
			expect(mirror:EvaluateBasic(T + 0.6)).to.equal("Buffered")
			expect(mirror:EvaluateHeavy(T + 0.75)).to.equal("Predict")
		end)
	end)

	describe("PredictionMirror.PredictedSwing", function()
		it("starts at stage 1, not a finisher", function()
			local mirror = PredictionMirror.New()
			local swing = mirror:PredictedSwing(T)
			expect(swing.StageIndex).to.equal(1)
			expect(swing.IsFinisher).to.equal(false)
		end)

		-- StageIndex is throw-based (advances on every CONFIRMED throw, whiff or not) -- mirrors
		-- CombatState.basicSwingIndex server-side. IsFinisher stays landing-based (OnOwnSwingConnected)
		-- -- see the two tests below.
		it("advances the stage on every confirmed throw, whether or not it connects", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:PredictedSwing(T + 0.1).StageIndex).to.equal(2)
			mirror:OnAttackStarted(basicStarted(nil), T + 0.1)
			expect(mirror:PredictedSwing(T + 0.2).StageIndex).to.equal(3)
			mirror:OnAttackStarted(basicStarted(nil), T + 0.2)
			expect(mirror:PredictedSwing(T + 0.3).StageIndex).to.equal(1)
		end)

		it("never reaches the finisher from throws alone, no matter how many whiffs are confirmed", function()
			local mirror = PredictionMirror.New()
			local now = T
			for _ = 1, 10 do
				mirror:OnAttackStarted(basicStarted(nil), now)
				now += 0.1
			end
			expect(mirror:PredictedSwing(now).IsFinisher).to.equal(false)
		end)

		it("flags the finisher once 3 hits have actually landed", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("Basic1", false, T)
			mirror:OnOwnSwingConnected("Basic2", false, T + 0.2)
			mirror:OnOwnSwingConnected("Basic3", false, T + 0.4)
			local swing = mirror:PredictedSwing(T + 0.5)
			expect(swing.StageIndex).to.equal(Constants.Combat.BasicComboLength)
			expect(swing.IsFinisher).to.equal(true)
		end)

		it("is idempotent across multi-target feedback for the same swing", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("Basic1", false, T)
			mirror:OnOwnSwingConnected("Basic1", false, T + 0.01)
			mirror:OnOwnSwingConnected("Basic2", false, T + 0.2)
			-- Two DISTINCT landed stages (Basic1, Basic2) despite Basic1 firing twice -- if the double
			-- feedback had double-counted, this would already read Finisher one landed hit early.
			expect(mirror:PredictedSwing(T + 0.3).IsFinisher).to.equal(false)
			mirror:OnOwnSwingConnected("Basic3", false, T + 0.4)
			expect(mirror:PredictedSwing(T + 0.5).IsFinisher).to.equal(true)
		end)

		it("ignores heavy connects even though their names end in digits", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("Heavy1", true, T)
			mirror:OnOwnSwingConnected("Heavy1", true, T + 0.1)
			mirror:OnOwnSwingConnected("Heavy1", true, T + 0.2)
			expect(mirror:PredictedSwing(T + 0.3).IsFinisher).to.equal(false)
		end)

		it("ignores connects with no trailing digit (finisher/dash-punch)", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("Finisher", false, T)
			mirror:OnOwnSwingConnected("DashPunch", false, T)
			expect(mirror:PredictedSwing(T + 0.1).IsFinisher).to.equal(false)
		end)

		it("keeps the stage cycling across a whiffed string (basicComboExpiry refreshed at throw time)", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			-- Wait most (not all) of the window before the next throw -- if OnAttackStarted didn't
			-- refresh basicComboExpiry, this would already read as lapsed (stage 1) instead of 2.
			local secondThrowAt = T + Constants.Combat.ComboResetSeconds - 0.1
			mirror:OnAttackStarted(basicStarted(nil), secondThrowAt)
			expect(mirror:PredictedSwing(secondThrowAt + 0.05).StageIndex).to.equal(3)
		end)

		it("lapses the stage back to 1 after ComboResetSeconds with no further throw", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:PredictedSwing(T + Constants.Combat.ComboResetSeconds + 0.05).StageIndex).to.equal(1)
		end)

		it("resets to stage 1 if the next throw itself arrives after the window already lapsed", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T) -- stage 1 thrown
			mirror:OnAttackStarted(basicStarted(nil), T + 0.1) -- stage 2 thrown
			-- A real pause -- past ComboResetSeconds since the last throw's own refreshed expiry --
			-- before the NEXT throw's own confirm echo arrives.
			local resumedAt = T + 0.1 + Constants.Combat.ComboResetSeconds + 0.1
			mirror:OnAttackStarted(basicStarted(nil), resumedAt)
			-- The resumed throw itself becomes stage 1 (post-lapse-reset advance); the mirror now
			-- predicts stage 2 for the FOLLOWING press.
			expect(mirror:PredictedSwing(resumedAt + 0.05).StageIndex).to.equal(2)
		end)

		it("lapses the finisher gate back to needing 3 fresh landed hits after ComboResetSeconds", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("Basic2", false, T)
			expect(mirror:PredictedSwing(T + Constants.Combat.ComboResetSeconds + 0.05).IsFinisher).to.equal(false)
		end)

		it("resets at finisher THROW time, mirroring the server", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("Basic3", false, T)
			mirror:OnAttackStarted(basicStarted("Uppercut"), T + 0.1)
			local swing = mirror:PredictedSwing(T + 0.2)
			expect(swing.StageIndex).to.equal(1)
			expect(swing.IsFinisher).to.equal(false)
		end)

		it("resets on weapon swap, mirroring handleSwapWeaponRequest", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			mirror:OnOwnSwingConnected("Basic2", false, T + 0.1)
			mirror:OnWeaponChanged()
			local swing = mirror:PredictedSwing(T + 0.2)
			expect(swing.StageIndex).to.equal(1)
			expect(swing.IsFinisher).to.equal(false)
		end)
	end)

	describe("PredictionMirror.EvaluateDash", function()
		it("predicts on a fresh mirror", function()
			local mirror = PredictionMirror.New()
			expect(mirror:EvaluateDash(T, false)).to.equal("Predict")
		end)

		it("rejects (not falls back) when Dash's own cooldown is active", function()
			local mirror = PredictionMirror.New()
			mirror:OnMovementPerformed(Constants.Combat.DashCommitmentSeconds, T)
			-- Past the commitment, still inside Dash's cooldown -> NoPredict.
			local pressAt = T + Constants.Combat.DashCommitmentSeconds + 0.05
			expect(mirror:EvaluateDash(pressAt, false)).to.equal("NoPredict")
		end)

		it("predicts again once Dash's cooldown fully clears", function()
			local mirror = PredictionMirror.New()
			mirror:OnMovementPerformed(Constants.Combat.DashCommitmentSeconds, T)
			expect(mirror:EvaluateDash(T + Constants.Combat.DashCooldownSeconds + 0.05, false)).to.equal("Predict")
		end)

		it(
			"mirrors an echoed CooldownSeconds (a back-dash's own longer cooldown) instead of assuming the plain constant",
			function()
				local mirror = PredictionMirror.New()
				mirror:OnMovementPerformed(
					Constants.Combat.DashCommitmentSeconds,
					T,
					Constants.Combat.DashBackCooldownSeconds
				)
				-- Past the plain DashCooldownSeconds, but still inside the longer echoed back-dash cooldown.
				local pastPlainCooldown = T + Constants.Combat.DashCooldownSeconds + 0.05
				expect(mirror:EvaluateDash(pastPlainCooldown, false)).to.equal("NoPredict")
				expect(mirror:EvaluateDash(T + Constants.Combat.DashBackCooldownSeconds + 0.05, false)).to.equal(
					"Predict"
				)
			end
		)

		it("is NoPredict right after a Slide even though Dash's OWN cooldown alone would already allow it", function()
			-- Regression test for the interleave loophole: Slide's cooldown (1.2s) outlasts Dash's own
			-- (0.8s), so pressing Dash shortly after a Slide would read Predict if only dashCooldownExpiry
			-- were checked -- the shared movementCooldownExpiry must catch this too.
			local mirror = PredictionMirror.New()
			mirror:OnSlidePerformed(Constants.Combat.SlideCommitmentSeconds, T)
			local pressAt = T + Constants.Combat.DashCooldownSeconds + 0.05
			expect(mirror:EvaluateDash(pressAt, false)).to.equal("NoPredict")
		end)

		it("does not mistake a plain dash's commitment for a DashPunch throw", function()
			-- Regression test: DashFrontDurationSeconds (0.28) coincidentally equals
			-- DashCommitmentSeconds (0.28) -- a plain dash's own commitment -- which once made this
			-- signal misfire "DashPunch" on every ordinary dash instead of only a genuine throw. A
			-- double-tap-forward press right after a PLAIN dash confirm must still predict normally
			-- (DashPunch's own cooldown was never actually armed).
			local mirror = PredictionMirror.New()
			mirror:OnMovementPerformed(Constants.Combat.DashCommitmentSeconds, T)
			local pressAt = T + Constants.Combat.DashCooldownSeconds + 0.05
			expect(mirror:EvaluateDash(pressAt, true)).to.equal("Predict")
		end)

		it("is gated by the shared commitment lock", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:EvaluateDash(T + 0.1, false)).to.equal("NoPredict")
		end)

		it("rejects a double-tap-forward press while DashPunch's own cooldown is active", function()
			local mirror = PredictionMirror.New()
			-- DashFrontCommitmentSeconds is handleDashRequest's own signal (via commitmentSeconds,
			-- what actually lands in the MovementPerformed payload's DurationSeconds field) that
			-- this confirmed Dash was specifically a DashPunch throw (see OnMovementPerformed's own
			-- comment) -- distinct from a plain dash's DashCommitmentSeconds.
			mirror:OnMovementPerformed(Constants.Combat.DashFrontCommitmentSeconds, T)
			-- Past Dash's own (shorter) base cooldown, still inside DashPunch's own 4s cooldown.
			local pressAt = T + Constants.Combat.DashCooldownSeconds + 0.05
			expect(mirror:EvaluateDash(pressAt, true)).to.equal("NoPredict")
		end)

		it("still predicts a non-double-tap forward dash while DashPunch is on cooldown", function()
			local mirror = PredictionMirror.New()
			mirror:OnMovementPerformed(Constants.Combat.DashFrontCommitmentSeconds, T)
			local pressAt = T + Constants.Combat.DashCooldownSeconds + 0.05
			expect(mirror:EvaluateDash(pressAt, false)).to.equal("Predict")
		end)

		it("predicts a double-tap-forward press again once DashPunch's own cooldown clears", function()
			local mirror = PredictionMirror.New()
			mirror:OnMovementPerformed(Constants.Combat.DashFrontCommitmentSeconds, T)
			local pressAt = T + Constants.Combat.DashPunch.Cooldown + 0.05
			expect(mirror:EvaluateDash(pressAt, true)).to.equal("Predict")
		end)
	end)

	describe("PredictionMirror.EvaluateSlide", function()
		it("is NoPredict on a fresh mirror when not sprinting", function()
			local mirror = PredictionMirror.New()
			expect(mirror:EvaluateSlide(T, false)).to.equal("NoPredict")
		end)

		it("predicts on a fresh mirror while sprinting", function()
			local mirror = PredictionMirror.New()
			expect(mirror:EvaluateSlide(T, true)).to.equal("Predict")
		end)

		it("rejects (not falls back) when Slide's own cooldown is active", function()
			local mirror = PredictionMirror.New()
			mirror:OnSlidePerformed(Constants.Combat.SlideCommitmentSeconds, T)
			local pressAt = T + Constants.Combat.SlideCommitmentSeconds + 0.05
			expect(mirror:EvaluateSlide(pressAt, true)).to.equal("NoPredict")
		end)

		it("predicts again once Slide's own cooldown fully clears", function()
			local mirror = PredictionMirror.New()
			mirror:OnSlidePerformed(Constants.Combat.SlideCommitmentSeconds, T)
			expect(mirror:EvaluateSlide(T + Constants.Combat.SlideCooldownSeconds + 0.05, true)).to.equal("Predict")
		end)

		it("is gated by Dash's own (shorter) cooldown pace via the shared cooldown, not blocked longer", function()
			-- Other direction from EvaluateDash's own interleave test above: Dash's cooldown (0.8s) is
			-- SHORTER than Slide's own (1.2s), so a Slide attempted right after a Dash is correctly
			-- gated by the shared cooldown only until DASH's own pace clears, not held out for the full
			-- 1.2s a bare Slide-after-Slide would cost -- the shared gate uses whichever move was JUST
			-- used, never inflating a cheaper move's own cost onto the other.
			local mirror = PredictionMirror.New()
			mirror:OnMovementPerformed(Constants.Combat.DashCommitmentSeconds, T)
			expect(mirror:EvaluateSlide(T + Constants.Combat.DashCooldownSeconds - 0.05, true)).to.equal("NoPredict")
			expect(mirror:EvaluateSlide(T + Constants.Combat.DashCooldownSeconds + 0.05, true)).to.equal("Predict")
		end)

		it("is gated by the shared commitment lock", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:EvaluateSlide(T + 0.1, true)).to.equal("NoPredict")
		end)

		it("is locked out by a mirrored hit-stun", function()
			local mirror = PredictionMirror.New()
			mirror:OnResolvedAgainstMe(true, T)
			expect(mirror:EvaluateSlide(T + Constants.Combat.HitStunDuration - 0.05, true)).to.equal("NoPredict")
			expect(mirror:EvaluateSlide(T + Constants.Combat.HitStunDuration + 0.05, true)).to.equal("Predict")
		end)
	end)

	describe("PredictionMirror.EvaluateAirSlam", function()
		it("predicts on a fresh mirror", function()
			local mirror = PredictionMirror.New()
			expect(mirror:EvaluateAirSlam(T)).to.equal("Predict")
		end)

		it("returns NoPredict immediately after a throw (own cooldown, no buffer)", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(airSlamStarted(), T)
			expect(mirror:EvaluateAirSlam(T + 0.05)).to.equal("NoPredict")
		end)

		it("predicts again once AirSlam's own cooldown fully clears", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(airSlamStarted(), T)
			expect(mirror:EvaluateAirSlam(T + 3 + 0.05)).to.equal("Predict")
		end)

		it("does not stomp the Basic combo mirror -- AirSlam is fully independent", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			mirror:OnOwnSwingConnected("Basic2", false, T + 0.05)
			mirror:OnAttackStarted(airSlamStarted(), T + 0.1)
			-- The grounded M1 combo state (both the landed count and the swing-index cycle) is
			-- untouched by an air slam throw (unlike a real M1 finisher, which resets both) -- still
			-- mid-string once the shared commitment lock AirSlam's own throw armed (T + 0.1 + 0.87
			-- commitment) clears.
			local afterCommitment = T + 0.1 + 0.35 + 0.22 + 0.3 + 0.05
			local swing = mirror:PredictedSwing(afterCommitment)
			expect(swing.IsFinisher).to.equal(false)
			expect(swing.StageIndex).to.equal(2)
			expect(mirror:EvaluateBasic(afterCommitment)).to.equal("Predict")
		end)

		it("is gated by the shared commitment lock", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:EvaluateAirSlam(T + 0.1)).to.equal("NoPredict")
		end)

		it("is locked out by a mirrored hit-stun", function()
			local mirror = PredictionMirror.New()
			mirror:OnResolvedAgainstMe(true, T)
			expect(mirror:EvaluateAirSlam(T + Constants.Combat.HitStunDuration - 0.05)).to.equal("NoPredict")
			expect(mirror:EvaluateAirSlam(T + Constants.Combat.HitStunDuration + 0.05)).to.equal("Predict")
		end)
	end)

	describe("PredictionMirror.IsInAirCombo", function()
		it("is false on a fresh mirror", function()
			local mirror = PredictionMirror.New()
			expect(mirror:IsInAirCombo(T)).to.equal(false)
		end)

		it("opens the window when a DashPunch connects", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("DashPunch", false, T)
			expect(mirror:IsInAirCombo(T + 0.1)).to.equal(true)
			expect(mirror:IsInAirCombo(T + Constants.Combat.AirCombo.AirborneSeconds + 0.05)).to.equal(false)
		end)

		it("extends the window on a later own-swing connect while it's still open", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("DashPunch", false, T)
			-- A follow-up Basic connect landing well before the original window lapses refreshes it
			-- by another full AirborneSeconds, mirroring applyAirCombo's continuation branch.
			local followUpAt = T + Constants.Combat.AirCombo.AirborneSeconds - 0.1
			mirror:OnOwnSwingConnected("Basic1", false, followUpAt)
			expect(mirror:IsInAirCombo(T + Constants.Combat.AirCombo.AirborneSeconds + 0.05)).to.equal(true)
			expect(mirror:IsInAirCombo(followUpAt + Constants.Combat.AirCombo.AirborneSeconds + 0.05)).to.equal(false)
		end)

		it("does not open the window from an own-swing connect once the previous window already lapsed", function()
			local mirror = PredictionMirror.New()
			mirror:OnOwnSwingConnected("DashPunch", false, T)
			local afterLapse = T + Constants.Combat.AirCombo.AirborneSeconds + 0.5
			mirror:OnOwnSwingConnected("Basic1", false, afterLapse)
			expect(mirror:IsInAirCombo(afterLapse + 0.01)).to.equal(false)
		end)
	end)

	describe("PredictionMirror.PredictParryAvailable", function()
		it("is available on a fresh mirror", function()
			local mirror = PredictionMirror.New()
			expect(mirror:PredictParryAvailable(T)).to.equal(true)
		end)

		it("mirrors the parry cooldown armed by a confirmed parry window", function()
			local mirror = PredictionMirror.New()
			mirror:OnBlockStarted(true, T)
			expect(mirror:PredictParryAvailable(T + 0.5)).to.equal(false)
			expect(mirror:PredictParryAvailable(T + Constants.Combat.ParryCooldownSeconds + 0.05)).to.equal(true)
		end)

		it("learns nothing from a plain-block confirmation", function()
			local mirror = PredictionMirror.New()
			mirror:OnBlockStarted(false, T)
			expect(mirror:PredictParryAvailable(T + 0.01)).to.equal(true)
		end)

		it("is unavailable during the shared commitment lock", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			expect(mirror:PredictParryAvailable(T + 0.1)).to.equal(false)
		end)
	end)

	describe("PredictionMirror.OnPredictionPending", function()
		it("holds the shared commitment gate closed during the round-trip gap", function()
			local mirror = PredictionMirror.New()
			mirror:OnPredictionPending(T)
			expect(mirror:EvaluateBasic(T + 0.05)).to.equal("NoPredict")
			expect(mirror:EvaluateDash(T + 0.05, false)).to.equal("NoPredict")
			expect(mirror:PredictParryAvailable(T + 0.05)).to.equal(false)
		end)

		it("is collapsed back down by the authoritative movement echo", function()
			local mirror = PredictionMirror.New()
			mirror:OnPredictionPending(T)
			-- The Dash confirm echo assigns the real (shorter) commitment over the pending horizon.
			mirror:OnMovementPerformed(Constants.Combat.DashCommitmentSeconds, T + 0.02)
			local afterCommit = T + 0.02 + Constants.Combat.DashCommitmentSeconds + 0.01
			expect(mirror:EvaluateBasic(afterCommit)).to.equal("Predict")
		end)
	end)

	describe("PredictionMirror.OnFeintPerformed", function()
		it("shortens the shared commitment lock to the feint's own recovery", function()
			local mirror = PredictionMirror.New()
			-- A real Basic swing's own commitment (0.45s total), in effect at the moment the feint
			-- lands. Probed via EvaluateDash, not EvaluateBasic/EvaluateHeavy -- Dash's own gate is a
			-- hard `now < attackEndsAt` check with no separate per-move cooldown to re-gate on and no
			-- input-buffer window to complicate the boundary (RecoverySeconds, 0.15s, is shorter than
			-- AttackInputBufferSeconds, 0.2s, so a Basic/Heavy probe would read "Buffered" rather than
			-- "NoPredict" for most of this window) -- isolating exactly what OnFeintPerformed changed.
			mirror:OnAttackStarted(basicStarted(nil), T)
			mirror:OnFeintPerformed(Constants.Combat.Feint.RecoverySeconds, T + 0.02)
			-- Still gated for the tiny recovery window right after the feint...
			expect(mirror:EvaluateDash(T + 0.02 + 0.01, false)).to.equal("NoPredict")
			-- ...but open again well before the ORIGINAL swing's own (much longer) commitment would
			-- have cleared, proving this assigned the shorter value rather than leaving the longer one
			-- in place or maxing against it.
			expect(mirror:EvaluateDash(T + 0.02 + Constants.Combat.Feint.RecoverySeconds + 0.01, false)).to.equal(
				"Predict"
			)
		end)

		it(
			"assigns rather than extends -- a feint recovery shorter than time-already-elapsed still opens the gate",
			function()
				local mirror = PredictionMirror.New()
				mirror:OnPredictionPending(T)
				mirror:OnFeintPerformed(Constants.Combat.Feint.RecoverySeconds, T + 0.5)
				expect(mirror:EvaluateBasic(T + 0.5 + Constants.Combat.Feint.RecoverySeconds + 0.01)).to.equal(
					"Predict"
				)
			end
		)
	end)

	describe("PredictionMirror.Reset", function()
		it("returns every gate to the fresh-spawn baseline", function()
			local mirror = PredictionMirror.New()
			mirror:OnAttackStarted(basicStarted(nil), T)
			mirror:OnAttackStarted(airSlamStarted(), T)
			mirror:OnMyAttackParried(T)
			mirror:OnMyPostureBroken(T)
			mirror:OnOwnSwingConnected("Basic2", false, T)
			mirror:OnResolvedAgainstMe(false, T)
			mirror:OnSlidePerformed(Constants.Combat.SlideCommitmentSeconds, T)
			mirror:Reset()
			expect(mirror:EvaluateBasic(T + 0.01)).to.equal("Predict")
			expect(mirror:PredictedSwing(T + 0.01).StageIndex).to.equal(1)
			expect(mirror:EvaluateDash(T + 0.01, false)).to.equal("Predict")
			expect(mirror:EvaluateAirSlam(T + 0.01)).to.equal("Predict")
			expect(mirror:EvaluateSlide(T + 0.01, true)).to.equal("Predict")
		end)
	end)
end
