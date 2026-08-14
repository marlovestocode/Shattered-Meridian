--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local CombatTypes = require(ServerScriptService.Server.Combat.CombatTypes)
local Movement = require(ServerScriptService.Server.Combat.Movement)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

type CombatState = CombatTypes.CombatState

-- Which flat override keys (the calling convention every test below already uses, e.g.
-- { dashWindowExpiry = 200 }) redirect into which nested CombatState sub-table -- see
-- Fixtures.applyNestedOverrides's own header. Mirrors CombatTypes.CombatVitalsState/MovementState/
-- AirComboState's own field lists exactly; kept local to this spec file the same way makeState's
-- base table literal already is (Fixtures.lua stays type-agnostic).
local SUB_STATE_GROUPS = {
	{
		SubtableKey = "Vitals",
		Fields = {
			maxHealth = true,
			posture = true,
			maxPosture = true,
			postureBrokenExpiry = true,
			parryWindowExpiry = true,
			parryCooldownExpiry = true,
			guardOpenExpiry = true,
			stunExpiry = true,
			hitSlowExpiry = true,
			disarmedUntil = true,
			ragdollExpiry = true,
		},
	},
	{
		SubtableKey = "Movement",
		Fields = {
			sprinting = true,
			sprintChargeSeconds = true,
			sprintStage = true,
			dashWindowExpiry = true,
			dashCooldownExpiry = true,
			dashIsBackward = true,
			dashPunchReadyAt = true,
			slideWindowExpiry = true,
			slideCooldownExpiry = true,
			movementCooldownExpiry = true,
			customMoveLungeWindowExpiry = true,
			customMoveLungeSpeed = true,
		},
	},
	{
		SubtableKey = "AirCombo",
		Fields = {
			airComboTarget = true,
			airComboDummyTarget = true,
			airComboHitCount = true,
			airComboExpiry = true,
			airComboHoverPosition = true,
			airComboChaseOffset = true,
			airComboChaseExpiry = true,
			airComboHeldExpiry = true,
		},
	},
}

-- Builds a minimal CombatState fixture with every timing field defaulted to "not active" (0), so
-- each test only needs to set the handful of fields it cares about. Not a real Player/Humanoid --
-- ComputeDesiredWalkSpeed never touches those fields, only the timing/flag ones. Overrides are still
-- flat (e.g. { dashWindowExpiry = 200 }) even though CombatState nests that field under `.Movement`
-- now -- see SUB_STATE_GROUPS/Fixtures.applyNestedOverrides above.
local function makeState(overrides: { [string]: any }?): CombatState
	local state = {
		player = nil :: any,
		character = nil,
		humanoid = nil,
		rootPart = nil,
		humanoidDiedConnection = nil,
		humanoidStateChangedConnection = nil,

		alive = true,
		blocking = false,
		deathConfirmed = false,

		lockOnTarget = nil,

		inCombatUntil = 0,
		recentOpponents = {},

		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		airSlamReadyAt = 0,
		customMoveReadyAt = {},
		genuineJumpAirborne = false,
		attackEndsAt = 0,
		activeActionKind = "None",
		currentSwingWindupEndsAt = 0,
		swingCancelled = false,
		comboIndex = 0,
		comboExpiry = 0,
		basicSwingIndex = 0,
		basicComboLanded = 0,
		basicComboExpiry = 0,

		equippedWeaponId = Constants.Combat.Weapons.Default,
		weaponSwapReadyAt = 0,
		bufferedAttack = nil,

		lastVitalsSyncTime = 0,
		pendingKillerUserId = nil,

		Vitals = {
			maxHealth = Constants.Combat.MaxHealth,
			posture = Constants.Combat.MaxPosture,
			maxPosture = Constants.Combat.MaxPosture,
			postureBrokenExpiry = 0,
			parryWindowExpiry = 0,
			parryCooldownExpiry = 0,
			guardOpenExpiry = 0,
			stunExpiry = 0,
			hitSlowExpiry = 0,
			disarmedUntil = 0,
			ragdollExpiry = 0,
		},
		Movement = {
			sprinting = false,
			sprintChargeSeconds = 0,
			sprintStage = 0,
			dashWindowExpiry = 0,
			dashCooldownExpiry = 0,
			dashIsBackward = false,
			dashPunchReadyAt = 0,
			slideWindowExpiry = 0,
			slideCooldownExpiry = 0,
			movementCooldownExpiry = 0,
			customMoveLungeWindowExpiry = 0,
			customMoveLungeSpeed = 0,
		},
		AirCombo = {
			airComboTarget = nil,
			airComboDummyTarget = nil,
			airComboHitCount = 0,
			airComboExpiry = 0,
			airComboHoverPosition = nil,
			airComboChaseOffset = nil,
			airComboChaseExpiry = 0,
			airComboHeldExpiry = 0,
		},
	}
	return Fixtures.applyNestedOverrides(state, overrides, SUB_STATE_GROUPS) :: CombatState
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
			expect(state.Movement.dashWindowExpiry).to.equal(100 + Constants.Combat.DashDurationSeconds)
			expect(state.Movement.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
			expect(state.Movement.movementCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
			expect(state.attackEndsAt).to.equal(100 + Constants.Combat.DashCommitmentSeconds)
			expect(state.Movement.dashIsBackward).to.equal(false)
			expect(state.blocking).to.equal(false)
		end)

		it("ApplyDash(isFrontDash=true) uses the longer front-lunge duration/commitment", function()
			local state = makeState({ blocking = true })
			Movement.ApplyDash(state, 100, true, false)
			expect(state.Movement.dashWindowExpiry).to.equal(100 + Constants.Combat.DashFrontDurationSeconds)
			expect(state.Movement.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
			expect(state.attackEndsAt).to.equal(100 + Constants.Combat.DashFrontCommitmentSeconds)
			expect(state.blocking).to.equal(false)
		end)

		it("ApplyDash shares movementCooldownExpiry with Slide (closes the interleave loophole)", function()
			local state = makeState({ slideCooldownExpiry = 50 })
			Movement.ApplyDash(state, 100, false, false)
			-- A Slide fired 100 seconds after this Dash must still be gated by the SHARED cooldown,
			-- even though slideCooldownExpiry (50) has long since cleared on its own.
			expect(state.Movement.movementCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
		end)

		it(
			"ApplyDash(isBackDash=true) uses the longer back-dash cooldown for both dashCooldownExpiry and the shared gate, and flags dashIsBackward",
			function()
				local state = makeState()
				Movement.ApplyDash(state, 100, false, true)
				expect(state.Movement.dashIsBackward).to.equal(true)
				expect(state.Movement.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashBackCooldownSeconds)
				expect(state.Movement.movementCooldownExpiry).to.equal(100 + Constants.Combat.DashBackCooldownSeconds)
				-- Duration/commitment stay the SAME as every other non-front direction -- only speed
				-- (read by ComputeDesiredWalkSpeed) and cooldown differ for backward.
				expect(state.Movement.dashWindowExpiry).to.equal(100 + Constants.Combat.DashDurationSeconds)
				expect(state.attackEndsAt).to.equal(100 + Constants.Combat.DashCommitmentSeconds)
			end
		)

		it("ApplyDash(isBackDash=false) leaves dashIsBackward false and uses the plain cooldown", function()
			local state = makeState({ dashIsBackward = true })
			Movement.ApplyDash(state, 100, false, false)
			expect(state.Movement.dashIsBackward).to.equal(false)
			expect(state.Movement.dashCooldownExpiry).to.equal(100 + Constants.Combat.DashCooldownSeconds)
		end)
	end)

	describe("Movement.ApplySlide", function()
		it("opens the slide window, its own cooldown, the commitment lock, and cancels blocking", function()
			local state = makeState({ blocking = true })
			Movement.ApplySlide(state, 100)
			expect(state.Movement.slideWindowExpiry).to.equal(100 + Constants.Combat.SlideDurationSeconds)
			expect(state.Movement.slideCooldownExpiry).to.equal(100 + Constants.Combat.SlideCooldownSeconds)
			expect(state.Movement.movementCooldownExpiry).to.equal(100 + Constants.Combat.SlideCooldownSeconds)
			expect(state.attackEndsAt).to.equal(100 + Constants.Combat.SlideCommitmentSeconds)
			expect(state.blocking).to.equal(false)
		end)

		it("ApplySlide shares movementCooldownExpiry with Dash (closes the interleave loophole)", function()
			local state = makeState({ dashCooldownExpiry = 50 })
			Movement.ApplySlide(state, 100)
			-- A Dash fired 100 seconds after this Slide must still be gated by the SHARED cooldown,
			-- even though dashCooldownExpiry (50) has long since cleared on its own.
			expect(state.Movement.movementCooldownExpiry).to.equal(100 + Constants.Combat.SlideCooldownSeconds)
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
			expect(state.Movement.sprinting).to.equal(true)
			Movement.SetSprinting(state, false)
			expect(state.Movement.sprinting).to.equal(false)
		end)
	end)

	-- Regression coverage for the "a slide/dash escapes a hit" defensive exploit -- see
	-- Movement.EndMovementBursts' own header. ComputeDesiredWalkSpeed ranks the Dash and Slide tiers
	-- above hit-slow, so without this cancellation a burst that began a frame before a hit kept its
	-- full multiplier and HitSlowMultiplier ("the can't just run away factor") was defeatable on
	-- reaction.
	describe("Movement.EndMovementBursts", function()
		local now = 100

		it("leaves an active slide alone when nothing is interrupting", function()
			local state = makeState({ slideWindowExpiry = now + 1 })
			expect(Movement.EndMovementBursts(state, now)).to.equal(false)
			expect(state.Movement.slideWindowExpiry).to.equal(now + 1)
		end)

		for _, case in ipairs({
			{ Field = "stunExpiry", Label = "stunned" },
			{ Field = "postureBrokenExpiry", Label = "posture-broken" },
			{ Field = "ragdollExpiry", Label = "ragdolled" },
		}) do
			it(`ends an active slide when the player is {case.Label}`, function()
				local state = makeState({ slideWindowExpiry = now + 1, [case.Field] = now + 1 })
				expect(Movement.EndMovementBursts(state, now)).to.equal(true)
				expect(state.Movement.slideWindowExpiry).to.equal(0)
			end)

			it(`ends an active dash when the player is {case.Label}`, function()
				local state = makeState({ dashWindowExpiry = now + 1, [case.Field] = now + 1 })
				expect(Movement.EndMovementBursts(state, now)).to.equal(true)
				expect(state.Movement.dashWindowExpiry).to.equal(0)
			end)
		end

		it("ends an active burst while pinned as the air-combo attacker", function()
			local state = makeState({ dashWindowExpiry = now + 1, airComboChaseExpiry = now + 1 })
			expect(Movement.EndMovementBursts(state, now)).to.equal(true)
			expect(state.Movement.dashWindowExpiry).to.equal(0)
		end)

		it("drops the burst's speed tier immediately, falling through to hit-slow", function()
			-- The end-to-end property the fix exists for: before it, this same state resolved to
			-- base * SlideSpeedMultiplier (a faster-than-normal escape) despite the player having just
			-- been hit and stunned.
			local state = makeState({
				slideWindowExpiry = now + 1,
				stunExpiry = now + 1,
				hitSlowExpiry = now + 1,
			})
			Movement.EndMovementBursts(state, now)
			-- Bare BaseWalkSpeed, no BonusWalkSpeed term: the fixture has humanoid = nil, so
			-- ComputeDesiredWalkSpeed's attribute reads are skipped and bonus/multiplier stay 0/1 --
			-- the same convention the ComputeDesiredWalkSpeed tests above already use.
			local base = Constants.Combat.BaseWalkSpeed
			expect(Movement.ComputeDesiredWalkSpeed(state, now)).to.equal(base * Constants.Combat.HitSlowMultiplier)
		end)

		it("does not refund the cooldown -- the burst was still spent", function()
			local state = makeState({
				slideWindowExpiry = now + 1,
				slideCooldownExpiry = now + 5,
				movementCooldownExpiry = now + 5,
				stunExpiry = now + 1,
			})
			Movement.EndMovementBursts(state, now)
			expect(state.Movement.slideCooldownExpiry).to.equal(now + 5)
			expect(state.Movement.movementCooldownExpiry).to.equal(now + 5)
		end)

		it("reports no work done when no burst is active, even while interrupted", function()
			local state = makeState({ stunExpiry = now + 1 })
			expect(Movement.EndMovementBursts(state, now)).to.equal(false)
		end)

		it("is idempotent across repeated ticks", function()
			local state = makeState({ slideWindowExpiry = now + 1, stunExpiry = now + 2 })
			expect(Movement.EndMovementBursts(state, now)).to.equal(true)
			expect(Movement.EndMovementBursts(state, now)).to.equal(false)
		end)
	end)

	-- Regression coverage for the "free Downslam after becoming airborne for any incidental reason"
	-- exploit -- see CombatState.genuineJumpAirborne's own header (CombatTypes.lua) and this
	-- function's own header for the full mechanism. CombatSystem.lua's isAirborneForAirSlam used to
	-- treat Humanoid:GetState() == Freefall (or FloorMaterial == Air) as sufficient on its own to
	-- throw AirSlam/"Downslam" -- but Freefall is exactly what a player reaches after a DashPunch's
	-- own dash residue carries them off a ledge, after ordinary hit knockback, after parry recoil, or
	-- from simply walking off an edge with no jump ever pressed, not just from a genuine jump. These
	-- tests exercise the pure state-transition decision directly (no live Humanoid instance needed --
	-- the whole point of extracting it here instead of leaving it inline in CombatSystem.lua's
	-- StateChanged connection, the same "pure function, thin call site" split HitResolution.
	-- ApplyParryPunish/ApplyDisarm already use).
	describe("Movement.ComputeGenuineJumpAirborne", function()
		it("credits a genuine jump the instant Jumping is entered, regardless of the previous value", function()
			expect(Movement.ComputeGenuineJumpAirborne(false, Enum.HumanoidStateType.Jumping)).to.equal(true)
			expect(Movement.ComputeGenuineJumpAirborne(true, Enum.HumanoidStateType.Jumping)).to.equal(true)
		end)

		it("leaves Freefall alone -- it never CREDITS a jump on its own", function()
			-- The core regression case: falling off a ledge, DashPunch's own dash residue carrying a
			-- player over an edge, and ordinary knockback/parry-recoil drift all land the Humanoid in
			-- Freefall with NO preceding Jumping transition. Without a genuine jump already credited,
			-- Freefall must never flip the flag true on its own.
			expect(Movement.ComputeGenuineJumpAirborne(false, Enum.HumanoidStateType.Freefall)).to.equal(false)
		end)

		it("leaves Freefall alone -- it never REVOKES an already-credited jump either", function()
			-- The ascent of a genuine jump transitions Jumping -> Freefall on its own past the apex;
			-- that continuation must not un-credit the jump that's still legitimately in progress.
			expect(Movement.ComputeGenuineJumpAirborne(true, Enum.HumanoidStateType.Freefall)).to.equal(true)
		end)

		for _, case in ipairs({
			{ State = Enum.HumanoidStateType.Landed, Label = "Landed" },
			{ State = Enum.HumanoidStateType.Running, Label = "Running" },
			{ State = Enum.HumanoidStateType.RunningNoPhysics, Label = "RunningNoPhysics" },
			{ State = Enum.HumanoidStateType.GettingUp, Label = "GettingUp" },
			{ State = Enum.HumanoidStateType.Physics, Label = "Physics (ragdoll/held-aloft)" },
			{ State = Enum.HumanoidStateType.Swimming, Label = "Swimming" },
			{ State = Enum.HumanoidStateType.Climbing, Label = "Climbing" },
			{ State = Enum.HumanoidStateType.Seated, Label = "Seated" },
		}) do
			it(`clears an already-credited jump on transition to {case.Label}`, function()
				expect(Movement.ComputeGenuineJumpAirborne(true, case.State)).to.equal(false)
			end)

			it(`leaves an uncredited flag false on transition to {case.Label}`, function()
				expect(Movement.ComputeGenuineJumpAirborne(false, case.State)).to.equal(false)
			end)
		end

		it("round-trips a realistic jump-and-land sequence back to false", function()
			local airborne = false
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Jumping)
			expect(airborne).to.equal(true)
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Freefall)
			expect(airborne).to.equal(true)
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Landed)
			expect(airborne).to.equal(false)
		end)

		it("round-trips a post-DashPunch ledge fall -- Freefall with no Jumping never credits AirSlam", function()
			-- The exact bug report scenario: grounded (Running), DashPunch's own dash residue carries
			-- the player off a ledge (Running -> Freefall directly, no Jumping in between), then they
			-- land. The flag must stay false through the whole stretch.
			local airborne = false
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Running)
			expect(airborne).to.equal(false)
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Freefall)
			expect(airborne).to.equal(false)
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Landed)
			expect(airborne).to.equal(false)
		end)

		it("revokes a stale credit the instant a mid-air ragdoll/hold takes over", function()
			-- A player genuinely jumped (credited), then got launched into a finisher ragdoll or an
			-- air-combo hold mid-air (Physics state) -- that airborne stretch is no longer "falling
			-- from my own jump," it's someone else's knockback/hold, so the credit must not survive
			-- into whatever happens after the ragdoll/hold ends.
			local airborne = Movement.ComputeGenuineJumpAirborne(false, Enum.HumanoidStateType.Jumping)
			expect(airborne).to.equal(true)
			airborne = Movement.ComputeGenuineJumpAirborne(airborne, Enum.HumanoidStateType.Physics)
			expect(airborne).to.equal(false)
		end)
	end)

	-- The Parkour System's two additions to this module. Both need a REAL Humanoid, unlike every
	-- describe above -- they read Humanoid Attributes, which is deliberately how the Parkour System
	-- influences this resolver without touching CombatSystem's private state (see
	-- Constants.Attributes.ParkourVelocityOwned's own header). A bare Instance.new("Humanoid") is
	-- enough: nothing here reads a property the character rig would supply.
	describe("Movement -- Parkour System integration", function()
		local function makeHumanoidState(attributes: { [string]: any }?, overrides: { [string]: any }?): CombatState
			local humanoid = Instance.new("Humanoid")
			if attributes then
				for name, value in attributes do
					humanoid:SetAttribute(name, value)
				end
			end
			local state = makeState(overrides)
			state.humanoid = humanoid
			return state
		end

		local base = Constants.Combat.BaseWalkSpeed + Constants.Combat.DefaultBonusWalkSpeed

		describe("ComputeDesiredWalkSpeed -- ParkourVelocityOwned tier", function()
			it("pins WalkSpeed to zero while parkour owns velocity", function()
				local state = makeHumanoidState({
					[Constants.Attributes.BonusWalkSpeed] = Constants.Combat.DefaultBonusWalkSpeed,
					[Constants.Attributes.ParkourVelocityOwned] = true,
				})
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(0)
			end)

			it("outranks sprint -- a slide must not have a raised WalkSpeed fighting its drive", function()
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourVelocityOwned] = true,
				}, { sprinting = true })
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(0)
			end)

			it("has no effect once released", function()
				local state = makeHumanoidState({
					[Constants.Attributes.BonusWalkSpeed] = Constants.Combat.DefaultBonusWalkSpeed,
					[Constants.Attributes.ParkourVelocityOwned] = false,
				})
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base)
			end)
		end)

		describe("ComputeParkourSpeedFloor", function()
			it("returns zero with no humanoid at all", function()
				expect(Movement.ComputeParkourSpeedFloor(makeState(), 100)).to.equal(0)
			end)

			it("returns zero when the attributes were never set", function()
				expect(Movement.ComputeParkourSpeedFloor(makeHumanoidState(), 100)).to.equal(0)
			end)

			it("returns the full floor at the instant the carry begins", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = 30,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				})
				expect(Movement.ComputeParkourSpeedFloor(state, 100)).to.equal(30)
			end)

			it("decays linearly across the carry window", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = 30,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				})
				local halfway = Movement.ComputeParkourSpeedFloor(state, 100 + carry * 0.5)
				expect(math.abs(halfway - 15) < 0.01).to.equal(true)
			end)

			it("returns zero at and past the expiry", function()
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = 30,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100,
				})
				expect(Movement.ComputeParkourSpeedFloor(state, 100)).to.equal(0)
				expect(Movement.ComputeParkourSpeedFloor(state, 200)).to.equal(0)
			end)

			it("caps an absurd reported floor independently of the network validator", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local cap = ParkourConstants.Locomotion.SprintSpeed
					* ParkourConstants.Locomotion.MomentumCarryMaxMultiplier
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = 100000,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				})
				expect(Movement.ComputeParkourSpeedFloor(state, 100)).to.equal(cap)
			end)

			it("returns zero for a NaN floor rather than propagating NaN into WalkSpeed", function()
				-- A NaN WalkSpeed pins the character in place with no error anywhere -- the exact class of
				-- silent failure worth a guard.
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = 0 / 0,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 200,
				})
				expect(Movement.ComputeParkourSpeedFloor(state, 100)).to.equal(0)
			end)

			it("returns zero for a non-positive floor", function()
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = -5,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 200,
				})
				expect(Movement.ComputeParkourSpeedFloor(state, 100)).to.equal(0)
			end)
		end)

		describe("ComputeDesiredWalkSpeed -- momentum carry placement", function()
			it("raises the base tier to the carried floor", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.BonusWalkSpeed] = Constants.Combat.DefaultBonusWalkSpeed,
					[Constants.Attributes.ParkourSpeedFloor] = 40,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				})
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(40)
			end)

			it("never LOWERS a speed the ordinary tiers already granted", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.BonusWalkSpeed] = Constants.Combat.DefaultBonusWalkSpeed,
					[Constants.Attributes.ParkourSpeedFloor] = 1,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				}, { sprinting = true })
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(
					base * Constants.Combat.SprintSpeedMultiplier
				)
			end)

			it("cannot peek through hit-slow -- parkour must never outrun the consequences of a hit", function()
				-- The single most important placement decision in this integration: the carry is applied
				-- only to the two free-movement tiers, so every early-returning tier above it (hit-slow,
				-- stun, posture break, commitment, air-combo hold, freeze, flight) is unaffected.
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.BonusWalkSpeed] = Constants.Combat.DefaultBonusWalkSpeed,
					[Constants.Attributes.ParkourSpeedFloor] = 46,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				}, { hitSlowExpiry = 200 })
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.HitSlowMultiplier)
			end)

			it("cannot peek through an admin freeze", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.Frozen] = true,
					[Constants.Attributes.ParkourSpeedFloor] = 46,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				})
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(0)
			end)

			it("cannot peek through an air-combo hold", function()
				local carry = ParkourConstants.Locomotion.MomentumCarrySeconds
				local state = makeHumanoidState({
					[Constants.Attributes.ParkourSpeedFloor] = 46,
					[Constants.Attributes.ParkourSpeedFloorExpiry] = 100 + carry,
				}, { airComboHeldExpiry = 200 })
				expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(0)
			end)
		end)

		describe("Movement.SmoothWalkSpeed", function()
			it("ramps upward at the acceleration rate rather than snapping", function()
				local result = Movement.SmoothWalkSpeed(10, 27, 0.05)
				expect(result > 10).to.equal(true)
				expect(result < 27).to.equal(true)
			end)

			it("ramps downward at the deceleration rate", function()
				local result = Movement.SmoothWalkSpeed(40, 18, 0.05)
				expect(result < 40).to.equal(true)
				expect(result > 18).to.equal(true)
			end)

			it("uses a slower rate downward than upward, so earned speed lingers", function()
				local up = Movement.SmoothWalkSpeed(20, 40, 0.05) - 20
				local down = 20 - Movement.SmoothWalkSpeed(20, 0.01, 0.05)
				expect(up > down).to.equal(true)
			end)

			it("arrives exactly at the target when the gap is within one frame's step", function()
				expect(Movement.SmoothWalkSpeed(26.99, 27, 0.5)).to.equal(27)
			end)

			it("snaps instantly to zero -- every hard stop must apply on the frame it is applied", function()
				-- A freeze, a flight, an emote lock, an air-combo hold or parkour taking velocity all
				-- resolve to zero, and easing into any of them would leave the character drifting after a
				-- lockdown.
				expect(Movement.SmoothWalkSpeed(40, 0, 0.016)).to.equal(0)
			end)

			it("snaps instantly OUT of zero, so a released player can move at once", function()
				expect(Movement.SmoothWalkSpeed(0, 27, 0.016)).to.equal(27)
			end)

			it("holds current for a zero or negative deltaTime rather than dividing by it", function()
				expect(Movement.SmoothWalkSpeed(20, 27, 0)).to.equal(20)
				expect(Movement.SmoothWalkSpeed(20, 27, -1)).to.equal(20)
			end)

			it("converges on the target across repeated frames", function()
				local speed = 5
				for _ = 1, 120 do
					speed = Movement.SmoothWalkSpeed(speed, 27, 1 / 60)
				end
				expect(speed).to.equal(27)
			end)
		end)
	end)

	-- THE TWO-STAGE RUN. The mechanic splits into two pure functions (the charge clock and the stage
	-- resolver) plus one thin Attribute-reading call site, which is exactly the split that makes it
	-- testable without a live character -- the same reason ComputeDesiredWalkSpeed/SmoothWalkSpeed
	-- above are separate from CombatSystem's heartbeat.
	describe("Movement.IsSprintTierActive", function()
		it("is true for a plain held sprint with nothing else going on", function()
			expect(Movement.IsSprintTierActive(makeState({ sprinting = true }), 100)).to.equal(true)
		end)

		it("is false without the held intent", function()
			expect(Movement.IsSprintTierActive(makeState(), 100)).to.equal(false)
		end)

		it("is false while blocking, mid-commitment, stunned or posture-broken", function()
			expect(Movement.IsSprintTierActive(makeState({ sprinting = true, blocking = true }), 100)).to.equal(false)
			expect(Movement.IsSprintTierActive(makeState({ sprinting = true, attackEndsAt = 200 }), 100)).to.equal(
				false
			)
			expect(Movement.IsSprintTierActive(makeState({ sprinting = true, stunExpiry = 200 }), 100)).to.equal(false)
			expect(Movement.IsSprintTierActive(makeState({ sprinting = true, postureBrokenExpiry = 200 }), 100)).to.equal(
				false
			)
		end)
	end)

	describe("Movement.ComputeSprintCharge", function()
		local threshold = Constants.Combat.SprintStage2ThresholdSeconds

		it("accrues one second of charge per second of running", function()
			expect(Movement.ComputeSprintCharge(0, 0.5, true, false)).to.equal(0.5)
			expect(Movement.ComputeSprintCharge(2, 0.25, true, false)).to.equal(2.25)
		end)

		it("caps the charge at the threshold, so a long run cannot be banked", function()
			expect(Movement.ComputeSprintCharge(threshold - 0.1, 5, true, false)).to.equal(threshold)
			expect(Movement.ComputeSprintCharge(threshold, 5, true, false)).to.equal(threshold)
		end)

		it("decays faster than it builds when the sprint tier is not being granted", function()
			local decayed = Movement.ComputeSprintCharge(4, 1, false, false)
			expect(decayed).to.equal(4 - Constants.Combat.SprintChargeDecayMultiplier)
			expect(decayed < 4).to.equal(true)
		end)

		it("never decays below zero", function()
			expect(Movement.ComputeSprintCharge(0.1, 10, false, false)).to.equal(0)
		end)

		it("HOLDS the charge while a parkour action owns velocity -- a vault mid-run is not a stop", function()
			-- Neither accruing nor decaying: a wall-run is not running, but it must not cost a player
			-- the stride they already earned. See Constants.Combat.SprintStage2SpeedMultiplier's header.
			expect(Movement.ComputeSprintCharge(5, 1, false, true)).to.equal(5)
			expect(Movement.ComputeSprintCharge(5, 1, true, true)).to.equal(5)
		end)

		it("holds for a zero or negative deltaTime rather than accruing or decaying off it", function()
			expect(Movement.ComputeSprintCharge(3, 0, true, false)).to.equal(3)
			expect(Movement.ComputeSprintCharge(3, -1, false, false)).to.equal(3)
		end)
	end)

	describe("Movement.ResolveSprintStage", function()
		local threshold = Constants.Combat.SprintStage2ThresholdSeconds
		local sustainFloor = threshold * Constants.Combat.SprintStage2SustainFraction

		it("is stage 0 whenever sprint is not held, whatever the charge", function()
			expect(Movement.ResolveSprintStage(2, threshold, false)).to.equal(0)
			expect(Movement.ResolveSprintStage(1, 0, false)).to.equal(0)
		end)

		it("is stage 1 while sprinting below the threshold", function()
			expect(Movement.ResolveSprintStage(1, threshold - 0.01, true)).to.equal(1)
			expect(Movement.ResolveSprintStage(0, 0, true)).to.equal(1)
		end)

		it("reaches stage 2 only at a full charge", function()
			expect(Movement.ResolveSprintStage(1, threshold, true)).to.equal(2)
		end)

		it("holds stage 2 through a dip that a fresh entry would not clear -- the flicker guard", function()
			-- Entering needs the full threshold; staying only needs SprintStage2SustainFraction of it,
			-- so one frame of a gate flickering cannot replay the onset whoosh and the clip crossfade.
			local dipped = (threshold + sustainFloor) / 2
			expect(Movement.ResolveSprintStage(2, dipped, true)).to.equal(2)
			expect(Movement.ResolveSprintStage(1, dipped, true)).to.equal(1)
		end)

		it("drops out of stage 2 once the charge falls below the sustain floor", function()
			expect(Movement.ResolveSprintStage(2, sustainFloor - 0.01, true)).to.equal(1)
		end)
	end)

	describe("Movement.UpdateSprintStage", function()
		-- MoveDirection is engine-driven and cannot be written on a bare Humanoid, so Movement.IsMoving
		-- is always false here -- which is exactly the "not accruing" branch these tests need. The
		-- accrual side is covered directly through ComputeSprintCharge above.
		it("decays a standing player's charge and drops the stage back to 1", function()
			local state = makeState({ sprinting = true, sprintChargeSeconds = 7, sprintStage = 2 })
			local stage = Movement.UpdateSprintStage(state, 100, 3)
			expect(state.Movement.sprintChargeSeconds < 7).to.equal(true)
			expect(stage).to.equal(1)
			expect(state.Movement.sprintStage).to.equal(1)
		end)

		it("freezes the charge while ParkourVelocityOwned is set", function()
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.ParkourVelocityOwned, true)
			local state = makeState({
				humanoid = humanoid,
				sprinting = true,
				sprintChargeSeconds = 5,
				sprintStage = 1,
			})
			Movement.UpdateSprintStage(state, 100, 1)
			expect(state.Movement.sprintChargeSeconds).to.equal(5)
		end)

		it("does NOT freeze the charge for a lockout, even one that also owns velocity", function()
			-- Flying with the sprint key held is not running, and the parkour freeze must not be a way
			-- to preserve a stride across it.
			local humanoid = Instance.new("Humanoid")
			humanoid:SetAttribute(Constants.Attributes.ParkourVelocityOwned, true)
			humanoid:SetAttribute(Constants.Attributes.Flying, true)
			local state = makeState({
				humanoid = humanoid,
				sprinting = true,
				sprintChargeSeconds = 5,
				sprintStage = 1,
			})
			Movement.UpdateSprintStage(state, 100, 1)
			expect(state.Movement.sprintChargeSeconds < 5).to.equal(true)
		end)

		it("resolves stage 0 the moment sprint is released", function()
			local state = makeState({ sprinting = false, sprintChargeSeconds = 7, sprintStage = 2 })
			expect(Movement.UpdateSprintStage(state, 100, 1 / 60)).to.equal(0)
		end)
	end)

	describe("Movement.ComputeDesiredWalkSpeed run stages", function()
		local base = Constants.Combat.BaseWalkSpeed

		it("uses the stage-1 multiplier at stage 1", function()
			local state = makeState({ sprinting = true, sprintStage = 1 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.SprintSpeedMultiplier)
		end)

		it("uses the stage-2 multiplier at stage 2", function()
			local state = makeState({ sprinting = true, sprintStage = 2 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(
				base * Constants.Combat.SprintStage2SpeedMultiplier
			)
		end)

		it("grants no sprint speed at all at stage 2 while the tier's own gates say no", function()
			-- The stage is not a licence: a stage-2 runner who blocks, swings, is stunned or is
			-- posture-broken is on base speed like anyone else, which is what keeps the faster tier out
			-- of a fight entirely. See Constants.Combat.SprintStage2SpeedMultiplier's own header.
			expect(
				Movement.ComputeDesiredWalkSpeed(makeState({ sprinting = true, sprintStage = 2, blocking = true }), 100)
			).to.equal(base)
			expect(
				Movement.ComputeDesiredWalkSpeed(
					makeState({ sprinting = true, sprintStage = 2, stunExpiry = 200 }),
					100
				)
			).to.equal(base)
		end)

		it("still loses to hit-slow, so stage 2 cannot outrun the consequences of being hit", function()
			local state = makeState({ sprinting = true, sprintStage = 2, hitSlowExpiry = 200 })
			expect(Movement.ComputeDesiredWalkSpeed(state, 100)).to.equal(base * Constants.Combat.HitSlowMultiplier)
		end)
	end)
end
