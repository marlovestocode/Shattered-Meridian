--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
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
			airTechWindowExpiry = true,
			airTechReadyAt = true,
			airComboSuspendedUntil = true,
			airComboSuspendedWithAttacker = true,
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

		alive = true,
		blocking = false,
		deathConfirmed = false,

		lockOnTarget = nil,

		inCombatUntil = 0,
		recentOpponents = {},

		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		airSlamReadyAt = 0,
		attackEndsAt = 0,
		activeActionKind = "None",
		currentSwingWindupEndsAt = 0,
		swingCancelled = false,
		comboIndex = 0,
		comboExpiry = 0,
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
			airTechWindowExpiry = 0,
			airTechReadyAt = 0,
			airComboSuspendedUntil = 0,
			airComboSuspendedWithAttacker = nil,
		},
	}
	return Fixtures.applyNestedOverrides(state, overrides, SUB_STATE_GROUPS) :: CombatState
end

-- A spy AirComboTarget adapter backed by a real Humanoid/Model/Part (RagdollController's own calls
-- need real Instances) -- records which closures fired and mirrors state onto a plain table the
-- same way CombatSystem.lua's own player-target adapter mirrors onto a CombatState, so assertions
-- can inspect it without depending on RagdollController's own internal physics bookkeeping.
local function makeTarget(overrides: { [string]: any }?): (AirComboTarget, { [string]: any })
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
		openAirTechWindowCalls = 0,
		setRagdollExpiryCalls = {} :: { number },
		applyDamageCalls = {} :: { number },
	}

	local target: AirComboTarget = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		player = nil,
		clearBlocking = function()
			spy.clearBlockingCalls += 1
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
		openAirTechWindow = function()
			spy.openAirTechWindowCalls += 1
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
		it("DashPunch starts a new sequence: launches the target and holds the attacker", function()
			local attackerState = makeCombatState()
			local target, spy = makeTarget()

			AirCombo.Apply(nil :: any, attackerState, target, "DashPunch", 100)

			expect(spy.setAsAirComboTargetCalls).to.equal(1)
			expect(spy.openAirTechWindowCalls).to.equal(1)
			expect(spy.clearBlockingCalls).to.equal(1)
			expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(attackerState.AirCombo.airComboHoverPosition).to.never.equal(nil)
			expect(attackerState.AirCombo.airComboChaseOffset).to.never.equal(nil)
			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
			expect(#spy.setRagdollExpiryCalls).to.equal(1)
		end)

		it("a continuation hit on the current target extends the sequence without re-launching", function()
			local attackerState = makeCombatState({
				airComboHitCount = 1,
				airComboExpiry = 200,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
			})
			local target, spy = makeTarget({ isCurrentAirComboTarget = true })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", 100)

			expect(attackerState.AirCombo.airComboHitCount).to.equal(2)
			expect(spy.openAirTechWindowCalls).to.equal(1)
			expect(spy.clearAirComboTargetCalls).to.equal(0)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(100 + Constants.Combat.AirCombo.AirborneSeconds)
		end)

		it("ignores a hit against a target that isn't the currently-tracked one", function()
			local attackerState = makeCombatState({ airComboHitCount = 1, airComboExpiry = 200 })
			local target, spy = makeTarget({ isCurrentAirComboTarget = false })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", 100)

			expect(attackerState.AirCombo.airComboHitCount).to.equal(1)
			expect(#spy.setRagdollExpiryCalls).to.equal(0)
		end)

		it("ignores a hit once the sequence has already expired", function()
			local attackerState = makeCombatState({ airComboHitCount = 1, airComboExpiry = 50 })
			local target, _spy = makeTarget({ isCurrentAirComboTarget = true })

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", 100)

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

			AirCombo.Apply(nil :: any, attackerState, target, "Basic1", 100)

			expect(spy.clearAirComboTargetCalls).to.equal(1)
			expect(#spy.applyDamageCalls).to.equal(1)
			expect(spy.applyDamageCalls[1]).to.equal(Constants.Combat.AirCombo.SlamBonusDamage)
			expect(attackerState.AirCombo.airComboHitCount).to.equal(0)
			expect(attackerState.AirCombo.airComboExpiry).to.equal(0)
			expect(attackerState.AirCombo.airComboHoverPosition).to.equal(nil)
			expect(attackerState.AirCombo.airComboChaseOffset).to.equal(nil)
			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(0)
		end)
	end)

	describe("AirCombo.EndSuspendedExchange", function()
		it("zeroes the victim's suspended bookkeeping", function()
			local victimState = makeCombatState({
				airComboSuspendedUntil = 200,
				airComboSuspendedWithAttacker = {} :: any,
			})

			AirCombo.EndSuspendedExchange(nil :: any, victimState, nil, nil)

			expect(victimState.AirCombo.airComboSuspendedUntil).to.equal(0)
			expect(victimState.AirCombo.airComboSuspendedWithAttacker).to.equal(nil)
		end)

		it("also zeroes the attacker's chase-expiry when an attacker state is given", function()
			local victimState = makeCombatState()
			local attackerState = makeCombatState({ airComboChaseExpiry = 200 })

			AirCombo.EndSuspendedExchange(nil :: any, victimState, nil, attackerState)

			expect(attackerState.AirCombo.airComboChaseExpiry).to.equal(0)
		end)

		it("is safe to call with a nil attacker (the attacker already left/died)", function()
			local victimState = makeCombatState({ airComboSuspendedUntil = 200 })

			AirCombo.EndSuspendedExchange(nil :: any, victimState, nil, nil)

			expect(victimState.AirCombo.airComboSuspendedUntil).to.equal(0)
		end)
	end)

	describe("AirCombo.HandleAirTechRequest / HandleSuspendedCounterPunchRequest (via Hooks)", function()
		local feedbackCalls: { Types.CombatFeedbackPayload }
		local vitalsCalls: number
		local postureBreakCalls: number
		local combatStatesByPlayer: { [Player]: CombatState }

		beforeEach(function()
			feedbackCalls = {}
			vitalsCalls = 0
			postureBreakCalls = 0
			combatStatesByPlayer = {}
			AirCombo.Init({
				IsDefensiveRateLimited = function()
					return false
				end,
				GetCombatState = function(player)
					return combatStatesByPlayer[player]
				end,
				FindAirComboAttacker = function(victimPlayer, now)
					for player, state in pairs(combatStatesByPlayer) do
						if state.AirCombo.airComboTarget == victimPlayer and now <= state.AirCombo.airComboExpiry then
							return player, state
						end
					end
					return nil, nil
				end,
				SendVitals = function()
					vitalsCalls += 1
				end,
				SendFeedback = function(_player, payload)
					table.insert(feedbackCalls, payload)
				end,
				TriggerPostureBreak = function()
					postureBreakCalls += 1
				end,
			})
		end)

		it("HandleAirTechRequest rejects a victim who isn't currently juggled", function()
			local victim = {} :: any
			combatStatesByPlayer[victim] = makeCombatState()

			AirCombo.HandleAirTechRequest(victim)

			expect(#feedbackCalls).to.equal(0)
		end)

		it("HandleAirTechRequest succeeds, suspends both sides, and punishes the attacker", function()
			local victim = {} :: any
			local attacker = {} :: any
			local victimState = makeCombatState({ airTechWindowExpiry = os.clock() + 10 })
			local attackerState = makeCombatState({
				airComboTarget = victim,
				airComboExpiry = os.clock() + 10,
				airComboHoverPosition = Vector3.new(0, 10, 0),
				airComboChaseOffset = Vector3.new(0, 0, 5),
			})
			combatStatesByPlayer[victim] = victimState
			combatStatesByPlayer[attacker] = attackerState

			AirCombo.HandleAirTechRequest(victim)

			expect(victimState.AirCombo.airComboSuspendedUntil > 0).to.equal(true)
			expect(victimState.AirCombo.airComboSuspendedWithAttacker).to.equal(attacker)
			expect(attackerState.AirCombo.airComboTarget).to.equal(nil)
			expect(vitalsCalls > 0).to.equal(true)
			expect(#feedbackCalls > 0).to.equal(true)
			-- Proximity InCombat extension's input (CombatState.recentOpponents) -- a successful
			-- air-tech is a real player-vs-player exchange, same as a landed hit, so both sides get
			-- stamped exactly like resolveHitAgainstTarget's own inCombatUntil refresh.
			expect(victimState.recentOpponents[attacker] ~= nil).to.equal(true)
			expect(attackerState.recentOpponents[victim] ~= nil).to.equal(true)
		end)

		it(
			"HandleSuspendedCounterPunchRequest stamps recentOpponents on both sides when the attacker is live",
			function()
				local victim = {} :: any
				local attacker = {} :: any
				local victimState = makeCombatState({
					airComboSuspendedUntil = os.clock() + 10,
					airComboSuspendedWithAttacker = attacker,
				})
				local attackerHumanoid = Instance.new("Humanoid")
				attackerHumanoid.MaxHealth = 500
				attackerHumanoid.Health = 500
				local attackerState = makeCombatState({ humanoid = attackerHumanoid })
				combatStatesByPlayer[attacker] = attackerState

				AirCombo.HandleSuspendedCounterPunchRequest(victim, victimState, os.clock())

				expect(victimState.recentOpponents[attacker] ~= nil).to.equal(true)
				expect(attackerState.recentOpponents[victim] ~= nil).to.equal(true)
			end
		)

		it("HandleSuspendedCounterPunchRequest ends the exchange even if the attacker already left", function()
			local victim = {} :: any
			local goneAttacker = {} :: any
			local victimState = makeCombatState({
				airComboSuspendedUntil = os.clock() + 10,
				airComboSuspendedWithAttacker = goneAttacker,
			})
			-- goneAttacker has no entry in combatStatesByPlayer -- GetCombatState returns nil.

			AirCombo.HandleSuspendedCounterPunchRequest(victim, victimState, os.clock())

			expect(victimState.AirCombo.airComboSuspendedUntil).to.equal(0)
			expect(postureBreakCalls).to.equal(0)
		end)
	end)
end
