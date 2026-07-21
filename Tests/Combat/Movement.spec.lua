--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CombatTypes = require(ServerScriptService.Server.Combat.CombatTypes)
local Movement = require(ServerScriptService.Server.Combat.Movement)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

type CombatState = CombatTypes.CombatState

-- Builds a minimal CombatState fixture with every timing field defaulted to "not active" (0), so
-- each test only needs to set the handful of fields it cares about. Not a real Player/Humanoid --
-- ComputeDesiredWalkSpeed never touches those fields, only the timing/flag ones.
local function makeState(overrides: { [string]: any }?): CombatState
	local state = {
		player = nil :: any,
		character = nil,
		humanoid = nil,
		rootPart = nil,
		humanoidDiedConnection = nil,

		maxHealth = Constants.Combat.MaxHealth,
		posture = Constants.Combat.MaxPosture,
		maxPosture = Constants.Combat.MaxPosture,

		alive = true,
		blocking = false,
		deathConfirmed = false,

		lockOnTarget = nil,

		parryWindowExpiry = 0,
		parryCooldownExpiry = 0,
		stunExpiry = 0,
		postureBrokenExpiry = 0,
		hitSlowExpiry = 0,

		sprinting = false,
		dashWindowExpiry = 0,
		dashCooldownExpiry = 0,
		dashIsBackward = false,
		dashPunchReadyAt = 0,
		slideWindowExpiry = 0,
		slideCooldownExpiry = 0,
		movementCooldownExpiry = 0,

		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		attackEndsAt = 0,
		comboIndex = 0,
		comboExpiry = 0,
		basicComboLanded = 0,
		basicComboExpiry = 0,
		finisherReadySynced = false,
		rootControlLockedSynced = false,
		ragdollExpiry = 0,
		disarmedUntil = 0,

		equippedWeaponId = Constants.Combat.Weapons.Default,
		weaponSwapReadyAt = 0,

		airComboHitCount = 0,
		airComboExpiry = 0,
		airComboChaseExpiry = 0,

		lastVitalsSyncTime = 0,
		pendingKillerUserId = nil,
	}
	return Fixtures.applyOverrides(state, overrides) :: CombatState
end

return function()
	describe("Movement.ComputeDesiredWalkSpeed", function()
		local base = Constants.Combat.BaseWalkSpeed

		it("returns base speed with no active effects", function()
			local state = makeState()
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("adds the humanoid's BonusWalkSpeed attribute on top of base", function()
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.BonusWalkSpeed, 8)
			local state = makeState({ humanoid = humanoid })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base + 8)
		end)

		it("ignores a non-number BonusWalkSpeed attribute and a missing humanoid", function()
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.BonusWalkSpeed, "not a number")
			local stateWithBadAttribute = makeState({ humanoid = humanoid })
			expect(Movement.ComputeDesiredWalkSpeed(stateWithBadAttribute, 100)).to.equal(base)

			local stateWithNoHumanoid = makeState({ humanoid = nil })
			expect(Movement.ComputeDesiredWalkSpeed(stateWithNoHumanoid, 100)).to.equal(base)
		end)

		it("prioritizes Flying over every other effect, including air-combo chase", function()
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.Flying, true)
			local state = makeState({
				humanoid = humanoid,
				airComboChaseExpiry = 200,
				dashWindowExpiry = 200,
				hitSlowExpiry = 200,
				sprinting = true,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(0)
		end)

		it("does not pin to zero for Flying=false", function()
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.Flying, false)
			local state = makeState({ humanoid = humanoid, sprinting = true })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.SprintSpeedMultiplier)
		end)

		it("prioritizes air-combo chase over every other effect", function()
			-- While RagdollController.HoldAloft owns this player's positioning via AlignPosition
			-- (CombatSystem.lua's applyAirCombo), WalkSpeed must be silenced outright -- a nonzero
			-- speed here would let the player's own held WASD fight the pull, see
			-- CombatState.airComboChaseExpiry's own header for the "we aren't floating next to each
			-- other" bug this priority exists to prevent.
			local state = makeState({
				airComboChaseExpiry = 200,
				dashWindowExpiry = 200,
				hitSlowExpiry = 200,
				sprinting = true,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(0)
		end)

		it("treats an expired air-combo chase window as inactive", function()
			local state = makeState({ airComboChaseExpiry = 50 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("prioritizes dash over hit-slow and sprint", function()
			local state = makeState({
				dashWindowExpiry = 200,
				hitSlowExpiry = 200,
				sprinting = true,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.DashSpeedMultiplier)
		end)

		it("uses DashBackSpeedMultiplier instead of DashSpeedMultiplier while dashIsBackward is true", function()
			local state = makeState({
				dashWindowExpiry = 200,
				dashIsBackward = true,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(
				base * Constants.Combat.DashBackSpeedMultiplier
			)
		end)

		it("prioritizes slide over hit-slow and sprint", function()
			local state = makeState({
				slideWindowExpiry = 200,
				hitSlowExpiry = 200,
				sprinting = true,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.SlideSpeedMultiplier)
		end)

		it("prioritizes dash over slide when both windows happen to be open", function()
			local state = makeState({
				dashWindowExpiry = 200,
				slideWindowExpiry = 200,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.DashSpeedMultiplier)
		end)

		it("treats an expired slide window as inactive", function()
			local state = makeState({ slideWindowExpiry = 50 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("prioritizes hit-slow over sprint", function()
			local state = makeState({
				hitSlowExpiry = 200,
				sprinting = true,
			})
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.HitSlowMultiplier)
		end)

		it("applies sprint only when free to move", function()
			local state = makeState({ sprinting = true })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.SprintSpeedMultiplier)
		end)

		it("does not apply sprint while blocking", function()
			local state = makeState({ sprinting = true, blocking = true })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("does not apply sprint while committed to an attack", function()
			local state = makeState({ sprinting = true, attackEndsAt = 200 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("does not apply sprint while stunned", function()
			local state = makeState({ sprinting = true, stunExpiry = 200 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("does not apply sprint while posture-broken", function()
			local state = makeState({ sprinting = true, postureBrokenExpiry = 200 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)

		it("treats an expired window as inactive", function()
			local state = makeState({ dashWindowExpiry = 50 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
		end)
	end)

	describe("Movement.ApplyDash", function()
		it("ApplyDash(isFrontDash=false) opens the plain dash window, cancels blocking", function()
			local state = makeState({ blocking = true })
			Movement.ApplyDash(state, 100, false, false)
			expect(state.dashWindowExpiry).to.equal(100 + Constants.Combat.DashDurationSeconds)
			expect(state.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
			expect(state.movementCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
			expect(state.attackEndsAt).to.equal(100 + Constants.Combat.DashCommitmentSeconds)
			expect(state.dashIsBackward).to.equal(false)
			expect(state.blocking).to.equal(false)
		end)

		it("ApplyDash(isFrontDash=true) uses the longer front-lunge duration/commitment", function()
			local state = makeState({ blocking = true })
			Movement.ApplyDash(state, 100, true, false)
			expect(state.dashWindowExpiry).to.equal(100 + Constants.Combat.DashFrontDurationSeconds)
			expect(state.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
			expect(state.attackEndsAt).to.equal(100 + Constants.Combat.DashFrontCommitmentSeconds)
			expect(state.blocking).to.equal(false)
		end)

		it("ApplyDash shares movementCooldownExpiry with Slide (closes the interleave loophole)", function()
			local state = makeState({ slideCooldownExpiry = 50 })
			Movement.ApplyDash(state, 100, false, false)
			-- A Slide fired 100 seconds after this Dash must still be gated by the SHARED cooldown,
			-- even though slideCooldownExpiry (50) has long since cleared on its own.
			expect(state.movementCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
		end)

		it(
			"ApplyDash(isBackDash=true) uses the longer back-dash cooldown for both dashCooldownExpiry and the shared gate, and flags dashIsBackward",
			function()
				local state = makeState()
				Movement.ApplyDash(state, 100, false, true)
				expect(state.dashIsBackward).to.equal(true)
				expect(state.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashBackCooldownSeconds)
				expect(state.movementCooldownExpiry).to.equal(100 + Constants.Combat.DashBackCooldownSeconds)
				-- Duration/commitment stay the SAME as every other non-front direction -- only speed
				-- (read by ComputeDesiredWalkSpeed) and cooldown differ for backward.
				expect(state.dashWindowExpiry).to.equal(100 + Constants.Combat.DashDurationSeconds)
				expect(state.attackEndsAt).to.equal(100 + Constants.Combat.DashCommitmentSeconds)
			end
		)

		it("ApplyDash(isBackDash=false) leaves dashIsBackward false and uses the plain cooldown", function()
			local state = makeState({ dashIsBackward = true })
			Movement.ApplyDash(state, 100, false, false)
			expect(state.dashIsBackward).to.equal(false)
			expect(state.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
		end)
	end)

	describe("Movement.ApplySlide", function()
		it("opens the slide window, its own cooldown, the commitment lock, and cancels blocking", function()
			local state = makeState({ blocking = true })
			Movement.ApplySlide(state, 100)
			expect(state.slideWindowExpiry).to.equal(100 + Constants.Combat.SlideDurationSeconds)
			expect(state.slideCooldownExpiry).to.equal(100 + Constants.Combat.SlideCooldownSeconds)
			expect(state.movementCooldownExpiry).to.equal(100 + Constants.Combat.SlideCooldownSeconds)
			expect(state.attackEndsAt).to.equal(100 + Constants.Combat.SlideCommitmentSeconds)
			expect(state.blocking).to.equal(false)
		end)

		it("ApplySlide shares movementCooldownExpiry with Dash (closes the interleave loophole)", function()
			local state = makeState({ dashCooldownExpiry = 50 })
			Movement.ApplySlide(state, 100)
			-- A Dash fired 100 seconds after this Slide must still be gated by the SHARED cooldown,
			-- even though dashCooldownExpiry (50) has long since cleared on its own.
			expect(state.movementCooldownExpiry).to.equal(100 + Constants.Combat.SlideCooldownSeconds)
		end)
	end)

	describe("Movement.IsMoving", function()
		it("returns false when the state has no humanoid", function()
			local state = makeState({ humanoid = nil })
			expect(Movement.IsMoving(state)).to.equal(false)
		end)

		it("returns false for a freshly-constructed Humanoid with zero MoveDirection", function()
			-- Same headless-test limitation ResolveDashDirection's own stationary-press test
			-- documents: a Humanoid with no real rig defaults MoveDirection to Vector3.zero without
			-- needing Humanoid:Move(), which is enough to exercise the magnitude < 0.1 branch.
			local humanoid = Instance.new("Humanoid")
			local state = makeState({ humanoid = humanoid })
			expect(Movement.IsMoving(state)).to.equal(false)
		end)
	end)

	describe("Movement.ResolveDashDirection", function()
		it("returns nil when the state has no humanoid (never a front dash without one)", function()
			local state = makeState({ humanoid = nil, rootPart = Instance.new("Part") })
			expect(Movement.ResolveDashDirection(state)).to.equal(nil)
		end)

		it("returns nil when the state has no rootPart", function()
			local state = makeState({ humanoid = Instance.new("Humanoid"), rootPart = nil })
			expect(Movement.ResolveDashDirection(state)).to.equal(nil)
		end)

		it("returns nil when MoveDirection has no meaningful magnitude (stationary Dash press)", function()
			-- A freshly-constructed Humanoid's MoveDirection defaults to Vector3.zero without
			-- needing a full character rig or a Move() call -- exercises the magnitude < 0.1
			-- branch without depending on Humanoid:Move()'s behavior outside a real rig, which
			-- this headless test place can't reliably set up. nil (not "Front") is the whole point
			-- of this branch -- see ResolveDashDirection's own header: a stationary press must not
			-- be treated as a front dash, or it throws DashPunch's hitbox for free with no actual
			-- dash having closed the distance.
			local humanoid = Instance.new("Humanoid")
			local rootPart = Instance.new("Part")
			local state = makeState({ humanoid = humanoid, rootPart = rootPart })
			expect(Movement.ResolveDashDirection(state)).to.equal(nil)
		end)
	end)

	describe("Movement.SetSprinting", function()
		it("sets the sprinting flag", function()
			local state = makeState()
			Movement.SetSprinting(state, true)
			expect(state.sprinting).to.equal(true)
			Movement.SetSprinting(state, false)
			expect(state.sprinting).to.equal(false)
		end)
	end)
end
