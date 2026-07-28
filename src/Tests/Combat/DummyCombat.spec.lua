--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local CombatTypes = require(ServerScriptService.Server.Combat.CombatTypes)
local DummyCombat = require(ServerScriptService.Server.Combat.DummyCombat)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

type CombatState = CombatTypes.CombatState
type DummyState = CombatTypes.DummyState

local function makeDefinition(overrides: { [string]: any }?): Types.HitboxAttackDefinition
	local definition = {
		DebugName = "TestAttack",
		WindupSeconds = 0.1,
		ActiveSeconds = 0.1,
		RecoverySeconds = 0.1,
		Size = Vector3.new(5, 5, 5),
		Offset = CFrame.new(0, 0, -3),
		Damage = 10,
		PostureDamage = 20,
		Cooldown = 0.5,
		ArcDegrees = 100,
		MaxTargets = 3,
	}
	return Fixtures.applyOverrides(definition, overrides) :: Types.HitboxAttackDefinition
end

-- Minimal real Instances (no real Player needed -- ResolveHit never touches Player.Character,
-- only the Model/Humanoid/BasePart it's handed) -- same "construct bare Instances, skip the
-- Player" trick Movement.spec.lua/HitResolution.spec.lua already use.
local function makeDummyState(overrides: { [string]: any }?): DummyState
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 500
	humanoid.Health = 500
	humanoid.Parent = model
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = model

	local state = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		spawnCFrame = CFrame.new(),
		maxHealth = 500,
		posture = 100,
		maxPosture = 100,
		postureBrokenExpiry = 0,
		alive = true,
		deathConfirmed = false,
		humanoidDiedConnection = nil,
		ragdollResetAt = 0,
	}
	return Fixtures.applyOverrides(state, overrides) :: DummyState
end

-- Which flat override keys (the calling convention every test below already uses) redirect into
-- which nested CombatState sub-table -- see Fixtures.applyNestedOverrides's own header. Mirrors
-- CombatTypes.CombatVitalsState/MovementState/AirComboState's own field lists exactly; kept local
-- to this spec file the same way makeAttackerState's base table literal already is (Fixtures.lua
-- stays type-agnostic).
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

local function makeAttackerState(overrides: { [string]: any }?): CombatState
	local state = {
		player = nil :: any,
		character = nil,
		humanoid = nil,
		rootPart = nil,
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

return function()
	describe("DummyCombat.ResolveHit", function()
		local feedbackCalls: { { Player: Player, Payload: Types.CombatFeedbackPayload } }
		local airComboCalls: number

		beforeEach(function()
			feedbackCalls = {}
			airComboCalls = 0
			DummyCombat.Init({
				SendFeedback = function(player, payload)
					table.insert(feedbackCalls, { Player = player, Payload = payload })
				end,
				ApplyAirCombo = function(_attackerPlayer, _attackerState, _target, _debugName, _now)
					airComboCalls += 1
				end,
			})
		end)

		local fakePlayer = {} :: any

		it("deals damage and posture, and dispatches a Hit feedback payload", function()
			local dummyState = makeDummyState()
			local attackerState = makeAttackerState()
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, false, nil)

			expect(dummyState.posture).to.equal(80)
			expect(dummyState.humanoid.Health).to.equal(490)
			expect(#feedbackCalls).to.equal(1)
			expect(feedbackCalls[1].Payload.Kind).to.equal("Hit")
			expect(feedbackCalls[1].Payload.DamageAmount).to.equal(10)
		end)

		it("opens the air combo for a clean Basic hit", function()
			local dummyState = makeDummyState()
			local attackerState = makeAttackerState()
			local definition = makeDefinition()

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, false, nil)

			expect(airComboCalls).to.equal(1)
		end)

		it("never opens the air combo for a Heavy hit", function()
			local dummyState = makeDummyState()
			local attackerState = makeAttackerState()
			local definition = makeDefinition()

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, true, nil)

			expect(airComboCalls).to.equal(0)
		end)

		it("never opens the air combo for a finisher hit", function()
			local dummyState = makeDummyState()
			local attackerState = makeAttackerState()
			local definition = makeDefinition()

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, false, "Normal")

			expect(airComboCalls).to.equal(0)
		end)

		it("triggers a posture break and its own feedback once posture crosses zero", function()
			local dummyState = makeDummyState({ posture = 15 })
			local attackerState = makeAttackerState()
			local definition = makeDefinition({ Damage = 0, PostureDamage = 20 })

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, false, nil)

			expect(dummyState.posture).to.equal(0)
			expect(dummyState.postureBrokenExpiry > 0).to.equal(true)
			expect(#feedbackCalls).to.equal(2)
			expect(feedbackCalls[2].Payload.Kind).to.equal("PostureBreak")
		end)

		it("does not re-trigger a posture break that's already active", function()
			local dummyState = makeDummyState({ posture = 0, postureBrokenExpiry = os.clock() + 5 })
			local attackerState = makeAttackerState()
			local definition = makeDefinition({ Damage = 5, PostureDamage = 0 })

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, false, nil)

			expect(#feedbackCalls).to.equal(1)
			expect(feedbackCalls[1].Payload.Kind).to.equal("Hit")
		end)

		it("schedules a respawn reset after a finisher ragdoll lands", function()
			local dummyState = makeDummyState()
			local attackerState = makeAttackerState()
			local definition = makeDefinition()

			DummyCombat.ResolveHit(fakePlayer, attackerState, dummyState, definition, false, "Uppercut")

			expect(dummyState.ragdollResetAt > 0).to.equal(true)
		end)
	end)

	describe("DummyCombat.SpawnDummy / GetDummyState / GetAliveDummies", function()
		it("creates a live, alive dummy reachable through both accessors", function()
			local model, failureReason = DummyCombat.SpawnDummy(CFrame.new(0, 100, 0))
			expect(failureReason).to.equal(nil)
			expect(model).to.never.equal(nil)

			local dummyModel = model :: Model
			local state = DummyCombat.GetDummyState(dummyModel)
			expect(state).to.never.equal(nil)
			expect((state :: DummyState).alive).to.equal(true)

			local foundInAliveList = false
			for _, aliveState in ipairs(DummyCombat.GetAliveDummies()) do
				if aliveState.model == dummyModel then
					foundInAliveList = true
				end
			end
			expect(foundInAliveList).to.equal(true)

			dummyModel:Destroy()
		end)
	end)
end
