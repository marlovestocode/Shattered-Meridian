--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CombatTypes = require(ServerScriptService.Server.Combat.CombatTypes)
local AirCombo = require(ServerScriptService.Server.Combat.AirCombo)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

type CombatState = CombatTypes.CombatState
type AirComboTarget = CombatTypes.AirComboTarget

-- Which flat override keys (the calling convention every test below already uses, e.g.
-- { airComboHitCount = 1 }) redirect into which nested CombatState sub-table -- see
-- Fixtures.applyNestedOverrides's own header. Mirrors CombatTypes.CombatVitalsState/MovementState/
-- AirComboState's own field lists exactly; kept local to this spec file the same way makeCombatState's
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
			dashWindowExpiry = true,
			dashCooldownExpiry = true,
			dashIsBackward = true,
			dashPunchReadyAt = true,
			slideWindowExpiry = true,
			slideCooldownExpiry = true,
			movementCooldownExpiry = true,
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

local function makeCombatState(overrides: { [string]: any }?): CombatState
	local character = Instance.new("Model")
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = character

	local state = {
		player = nil :: any,
		character = character,
		humanoid = nil,
		rootPart = rootPart,
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
			dashWindowExpiry = 0,
			dashCooldownExpiry = 0,
			dashIsBackward = false,
			dashPunchReadyAt = 0,
			slideWindowExpiry = 0,
			slideCooldownExpiry = 0,
			movementCooldownExpiry = 0,
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

-- A spy AirComboTarget adapter backed by a real Humanoid/Model/Part (RagdollController's own calls
-- need real Instances) -- records which closures fired and mirrors state onto a plain table the
-- same way CombatSystem.lua's own player-target adapter mirrors onto a CombatState, so assertions
-- can inspect it without depending on RagdollController's own internal physics bookkeeping.
-- `player` mirrors what a real call site passes for AirComboTarget.player -- nil (the default) makes
-- this a DUMMY-shaped target (AirCombo.Apply's own ragdoll-and-launch branch); a non-nil value (a
-- bare table stands in for a Player, same "fakePlayer = {} :: any" convention this file's sibling
-- specs already use) makes it a real-player-shaped target (the live-body-hold branch).
local function makeTarget(overrides: { [string]: any }?, player: any?): (AirComboTarget, { [string]: any })
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 500
	humanoid.Health = 500
	humanoid.Parent = model
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = model

	local spy = {
		isCurrentAirComboTarget = true,
		setAsAirComboTargetCalls = 0,
		clearAirComboTargetCalls = 0,
		clearBlockingCalls = 0,
		setHeldExpiryCalls = {} :: { number },
		setRagdollExpiryCalls = {} :: { number },
		applyDamageCalls = {} :: { number },
		onGroundSlamCalls = 0,
	}

	local target: AirComboTarget = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		player = player,
		clearBlocking = function()
			spy.clearBlockingCalls += 1
		end,
		setHeldExpiry = function(expiry: number)
			table.insert(spy.setHeldExpiryCalls, expiry)
		end,
		setRagdollExpiry = function(expiry: number)
			table.insert(spy.setRagdollExpiryCalls, expiry)
		end,
		isCurrentAirComboTarget = function()
			return spy.isCurrentAirComboTarget
		end,
		setAsAirComboTarget = function()
			spy.setAsAirComboTargetCalls += 1
		end,
		clearAirComboTarget = function()
			spy.clearAirComboTargetCalls += 1
		end,
		applyDamage = function(amount: number)
			table.insert(spy.applyDamageCalls, amount)
		end,
		onGroundSlam = function()
			spy.onGroundSlamCalls += 1
		end,
	}
	if overrides then
		for key, value in pairs(overrides) do
			(spy :: any)[key] = value
		end
	end
	return target, spy
end

return function()
	describe("AirCombo.Apply", function()
		it("DashPunch starts a new sequence against a dummy: ragdolls the target and holds the attacker", function()
			local attackerState = makeCombatState()
			local target, spy = makeTarget()

			AirCombo.Apply(nil :: any, attackerState, target, "DashPunch", false, 100)

			expect(spy.setAsAirComboTargetCalls).to.equal(1)
			-- No live-body concept for a dummy -- ragdolled via setRagdollExpiry, never held.
			expect(#spy.setRagdollExpiryCalls).to.equal(1)
			expect(#spy.setHeldExpiryCalls).to.equal(0)
			-- clearBlocking is never called at DashPunch-start -- a dummy has no `blocking` field to
			-- clear in the first place, and a real player target must NOT have it force-cleared either
			-- (see the live-body test below) -- see AirCombo.Apply's own header for why this call was
			-- retired entirely rather than kept dummy-only.
			expect(spy.clearBlockingCalls).to.equal(0)
			expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(attackerState.AirCombo.airComboHoverPosition).to.never.equal(nil)
			expect(attackerState.AirCombo.airComboChaseOffset).to.never.equal(nil)
			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			-- onGroundSlam is the MaxHits slam finisher's own signal (see AirComboTarget.onGroundSlam's
			-- own header) -- must never fire on a launch that isn't the sequence-ending slam.
			expect(spy.onGroundSlamCalls).to.equal(0)
		end)

		it("DashPunch starts a new sequence against a real player: holds them LIVE instead of ragdolling", function()
			local fakePlayer = {} :: any
			local attackerState = makeCombatState()
			local target, spy = makeTarget(nil, fakePlayer)

			AirCombo.Apply(nil :: any, attackerState, target, "DashPunch", false, 100)

			-- Live-body hold (keeps Motor6D/Humanoid control, Block/Parry-capable) instead of a
			-- genuine incapacitating ragdoll -- see AirComboState.airComboHeldExpiry's own header.
			expect(#spy.setHeldExpiryCalls).to.equal(1)
			expect(spy.setHeldExpiryCalls[1]).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(#spy.setRagdollExpiryCalls).to.equal(0)
			-- The victim must NOT have their guard force-dropped -- they need to be able to
			-- Block/Parry a continuation swing exactly like any other hit.
			expect(spy.clearBlockingCalls).to.equal(0)
			expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(spy.onGroundSlamCalls).to.equal(0)
		end)

		it(
			"a custom move with startsAirCombo=true starts a new sequence exactly like DashPunch, on a debug name that isn't DashPunch",
			function()
				local attackerState = makeCombatState()
				local target, spy = makeTarget()

				AirCombo.Apply(nil :: any, attackerState, target, "CustomMove_some-move-1234", true, 100)

				expect(spy.setAsAirComboTargetCalls).to.equal(1)
				expect(#spy.setRagdollExpiryCalls).to.equal(1)
				expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
				expect(attackerState.AirCombo.airComboExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			end
		)

		it(
			"a Basic hit with startsAirCombo=false never starts a sequence on its own (must be a continuation)",
			function()
				local attackerState = makeCombatState()
				local target, spy = makeTarget({ isCurrentAirComboTarget = false })

				AirCombo.Apply(nil :: any, attackerState, target, "CustomMove_some-move-1234", false, 100)

				expect(spy.setAsAirComboTargetCalls).to.equal(0)
				expect(attackerState.AirCombo.airComboHitCount).to.equal(0)
			end
		)

		it("a continuation hit on the current dummy target extends the sequence without re-launching", function()
			local attackerState = makeCombatState({
				airComboHitCount = 1,
				airComboExpiry = 200,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
			})
			local target, spy = makeTarget({ isCurrentAirComboTarget = true })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)

			expect(attackerState.AirCombo.airComboHitCount).to.equal(2)
			expect(#spy.setRagdollExpiryCalls).to.equal(1)
			expect(#spy.setHeldExpiryCalls).to.equal(0)
			expect(spy.clearAirComboTargetCalls).to.equal(0)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(spy.onGroundSlamCalls).to.equal(0)
		end)

		it("a continuation hit on the current LIVE (player) target refreshes the hold, never ragdolls them", function()
			local fakePlayer = {} :: any
			local attackerState = makeCombatState({
				airComboHitCount = 1,
				airComboExpiry = 200,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
			})
			local target, spy = makeTarget({ isCurrentAirComboTarget = true }, fakePlayer)

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)

			expect(attackerState.AirCombo.airComboHitCount).to.equal(2)
			expect(#spy.setHeldExpiryCalls).to.equal(1)
			expect(spy.setHeldExpiryCalls[1]).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(#spy.setRagdollExpiryCalls).to.equal(0)
			expect(spy.clearBlockingCalls).to.equal(0)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(spy.onGroundSlamCalls).to.equal(0)
		end)

		it("ignores a hit against a target that isn't the currently-tracked one", function()
			local attackerState = makeCombatState({ airComboHitCount = 1, airComboExpiry = 200 })
			local target, spy = makeTarget({ isCurrentAirComboTarget = false })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)

			expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
			expect(#spy.setRagdollExpiryCalls).to.equal(0)
		end)

		it("ignores a hit once the sequence has already expired", function()
			local attackerState = makeCombatState({ airComboHitCount = 1, airComboExpiry = 50 })
			local target, _spy = makeTarget({ isCurrentAirComboTarget = true })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)

			expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
		end)

		it("ends the sequence with a slam once MaxHits is reached", function()
			local attackerState = makeCombatState({
				airComboHitCount = Constants.Combat.AirCombo.MaxHits - 1,
				airComboExpiry = 200,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
			})
			local target, spy = makeTarget({ isCurrentAirComboTarget = true })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)

			expect(spy.clearAirComboTargetCalls).to.equal(1)
			expect(#spy.applyDamageCalls).to.equal(1)
			expect(spy.applyDamageCalls[1]).to.equal(Constants.Combat.AirCombo.SlamBonusDamage)
			expect(attackerState.AirCombo.airComboHitCount).to.equal(0)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(0)
			expect(attackerState.AirCombo.airComboHoverPosition).to.equal(nil)
			expect(attackerState.AirCombo.airComboChaseOffset).to.equal(nil)
			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(0)
			-- Regression: the slam's own ground-impact VFX (Client/FX/SlamImpactVFX.lua) used to never
			-- play for the air-combo's own MaxHits finisher -- the landed hit's Combat_FeedbackEvent is
			-- built with FinisherVariant == nil BEFORE AirCombo.Apply ever runs (reaching this code path
			-- at all requires that), so nothing downstream ever told the client to watch for the ground
			-- impact. onGroundSlam is the fix: fired exactly once, exactly here, right when
			-- RagdollController.SlamToGround actually lands the blow.
			expect(spy.onGroundSlamCalls).to.equal(1)
		end)

		it(
			"ends the sequence with a genuine ragdoll slam even for a LIVE (player) target -- the finisher is not defendable",
			function()
				local fakePlayer = {} :: any
				local attackerState = makeCombatState({
					airComboHitCount = Constants.Combat.AirCombo.MaxHits - 1,
					airComboExpiry = 200,
					airComboHoverPosition = Vector3.new(0, 10, 0),
					airComboChaseOffset = Vector3.new(0, 0, 5),
				})
				local target, spy = makeTarget({ isCurrentAirComboTarget = true }, fakePlayer)

				AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)

				-- The MaxHits slam always fully ragdolls the target (setRagdollExpiry), regardless of
				-- whether they were live-held for the rest of the sequence -- the sequence-ending
				-- knockdown itself was never in scope to change.
				expect(#spy.setRagdollExpiryCalls).to.equal(1)
				expect(#spy.setHeldExpiryCalls).to.equal(0)
				expect(spy.clearBlockingCalls).to.equal(1)
				expect(spy.onGroundSlamCalls).to.equal(1)
			end
		)

		it("does not error when onGroundSlam is omitted, matching the dummy-target adapter's real shape", function()
			-- DummyCombat.lua's own adapter leaves this field nil (a dummy has no TargetUserId for
			-- SlamImpactVFX to track) -- AirCombo.lua's own `if target.onGroundSlam then` guard must
			-- tolerate that on the exact code path that calls it.
			local attackerState = makeCombatState({
				airComboHitCount = Constants.Combat.AirCombo.MaxHits - 1,
				airComboExpiry = 200,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
			})
			local target, _spy = makeTarget({ isCurrentAirComboTarget = true })
			local targetAny = target :: any
			targetAny.onGroundSlam = nil

			expect(function()
				AirCombo.Apply(nil :: any, attackerState, target, "Basic1", false, 100)
			end).never.to.throw()
		end)
	end)

	-- CombatSystem.lua's releaseAirComboVictimOf (called from both onPlayerRemoving's disconnect
	-- path and confirmDeath, for a departing/dying ATTACKER) is a thin wrapper around this function --
	-- see that call site's own header. It's the orchestrator glue that isn't independently testable
	-- (this project's own convention -- see src/Tests/Combat's sibling specs), so this covers the pure
	-- state machine underneath it directly instead: does ReleaseSequence actually tear down both
	-- sides of a live sequence, leave a non-live one untouched, and tolerate a victim whose own
	-- CombatState is unavailable (nil, e.g. a training-dummy target or a victim whose character has
	-- already been torn down).
	describe("AirCombo.ReleaseSequence", function()
		it("returns false and leaves both sides untouched when there is no tracked target", function()
			local attackerState = makeCombatState()
			local victimState = makeCombatState({ ragdollExpiry = 50 })

			local released = AirCombo.ReleaseSequence(nil :: any, attackerState, victimState, 100)

			expect(released).to.equal(false)
			expect(victimState.Vitals.ragdollExpiry).to.equal(50)
		end)

		it("returns false and leaves both sides untouched once the sequence has already expired", function()
			local fakeVictim = {} :: any
			local attackerState = makeCombatState({ airComboTarget = fakeVictim, airComboExpiry = 50 })
			local victimState = makeCombatState({ airComboHeldExpiry = 200 })

			local released = AirCombo.ReleaseSequence(nil :: any, attackerState, victimState, 100)

			expect(released).to.equal(false)
			-- Early-return guard: a lapsed-but-not-yet-cleared entry is left exactly as found rather
			-- than force-cleared, matching Apply's own identical expiry check.
			expect(attackerState.AirCombo.airComboTarget).to.equal(fakeVictim)
			expect(victimState.AirCombo.airComboHeldExpiry).to.equal(200)
		end)

		it("releases a live sequence: clears every AirCombo tracking field on the attacker's own side", function()
			local fakeVictim = {} :: any
			local attackerState = makeCombatState({
				airComboTarget = fakeVictim,
				airComboHitCount = 2,
				airComboExpiry = 200,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
				airComboChaseExpiry = 200,
			})

			local released = AirCombo.ReleaseSequence(nil :: any, attackerState, nil, 100)

			expect(released).to.equal(true)
			expect(attackerState.AirCombo.airComboTarget).to.equal(nil)
			expect(attackerState.AirCombo.airComboHitCount).to.equal(0)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(0)
			expect(attackerState.AirCombo.airComboHoverPosition).to.equal(nil)
			expect(attackerState.AirCombo.airComboChaseOffset).to.equal(nil)
			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(0)
		end)

		it(
			"when victimState is supplied (the departing/dying-ATTACKER shape), also releases the held victim's own physical hold and held-lockout",
			function()
				local fakeVictim = {} :: any
				local victimState = makeCombatState({ ragdollExpiry = 300, airComboHeldExpiry = 300 })
				local attackerState = makeCombatState({
					airComboTarget = fakeVictim,
					airComboExpiry = 200,
					airComboHoverPosition = Vector3.new(0, 10, 0),
					airComboChaseOffset = Vector3.new(0, 0, 5),
				})

				local released = AirCombo.ReleaseSequence(nil :: any, attackerState, victimState, 100)

				expect(released).to.equal(true)
				expect(victimState.Vitals.ragdollExpiry).to.equal(0)
				expect(victimState.AirCombo.airComboHeldExpiry).to.equal(0)
			end
		)

		it(
			"still fully releases the attacker's own side when the victim's character is already gone (a victim mid-teardown)",
			function()
				local fakeVictim = {} :: any
				local victimState = makeCombatState({ ragdollExpiry = 300, airComboHeldExpiry = 300 })
				victimState.character = nil
				local attackerState = makeCombatState({
					airComboTarget = fakeVictim,
					airComboExpiry = 200,
					airComboHoverPosition = Vector3.new(0, 10, 0),
					airComboChaseOffset = Vector3.new(0, 0, 5),
				})

				expect(function()
					AirCombo.ReleaseSequence(nil :: any, attackerState, victimState, 100)
				end).never.to.throw()
				expect(attackerState.AirCombo.airComboTarget).to.equal(nil)
			end
		)
	end)
end
