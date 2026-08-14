--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local CombatTypes = require(ServerScriptService.Server.Combat.CombatTypes)
local BotCombat = require(ServerScriptService.Server.Combat.BotCombat)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

type CombatState = CombatTypes.CombatState
type BotState = CombatTypes.BotState

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

local function makeBotState(overrides: { [string]: any }?): BotState
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = Constants.Combat.MaxHealth
	humanoid.Health = Constants.Combat.MaxHealth
	humanoid.Parent = model
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Parent = model

	local state = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		spawnCFrame = CFrame.new(),
		ownerPlayer = nil :: any,
		humanoidDiedConnection = nil,

		maxHealth = Constants.Combat.MaxHealth,
		posture = Constants.Combat.MaxPosture,
		maxPosture = Constants.Combat.MaxPosture,

		alive = true,
		blocking = false,
		deathConfirmed = false,

		parryWindowExpiry = 0,
		parryCooldownExpiry = 0,
		guardOpenExpiry = 0,
		stunExpiry = 0,
		postureBrokenExpiry = 0,

		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		attackEndsAt = 0,
		comboIndex = 0,
		comboExpiry = 0,
		disarmedUntil = 0,

		pendingKillerUserId = nil,
	}
	return Fixtures.applyOverrides(state, overrides) :: BotState
end

-- Which flat override keys (the calling convention every test below already uses, e.g.
-- { posture = 50 }) redirect into which nested CombatState sub-table -- see Fixtures.
-- applyNestedOverrides's own header. Mirrors CombatTypes.CombatVitalsState/MovementState/
-- AirComboState's own field lists exactly; kept local to this spec file the same way
-- makeCombatState's base table literal already is (Fixtures.lua stays type-agnostic).
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

return function()
	local fakePlayer = {} :: any
	local feedbackCalls: { { Player: Player, Payload: Types.CombatFeedbackPayload } }
	local vitalsCalls: number
	local postureBreakCalls: { { Player: Player, AttackerPlayer: Player? } }

	beforeEach(function()
		feedbackCalls = {}
		vitalsCalls = 0
		postureBreakCalls = {}
		BotCombat.Init({
			SendFeedback = function(player, payload)
				table.insert(feedbackCalls, { Player = player, Payload = payload })
			end,
			SendVitals = function(_player, _state)
				vitalsCalls += 1
			end,
			TriggerPlayerPostureBreak = function(player, _state, attackerPlayer)
				table.insert(postureBreakCalls, { Player = player, AttackerPlayer = attackerPlayer })
			end,
		})
	end)

	describe("BotCombat.ResolveHitAgainstBot", function()
		it("deals damage to the bot and returns true for a plain hit", function()
			local botState = makeBotState()
			local attackerState = makeCombatState()
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })

			local connected =
				BotCombat.ResolveHitAgainstBot(fakePlayer, attackerState, botState, definition, false, nil)

			expect(connected).to.equal(true)
			expect(botState.posture).to.equal(Constants.Combat.MaxPosture - 20)
			expect(botState.humanoid.Health).to.equal(Constants.Combat.MaxHealth - 10)
			expect(#feedbackCalls).to.equal(1)
			expect(feedbackCalls[1].Payload.Kind).to.equal("Hit")
		end)

		it("returns false and punishes the attacker when the bot parries", function()
			local botState = makeBotState({ parryWindowExpiry = os.clock() + 5 })
			local attackerState = makeCombatState({ posture = 50 })
			local definition = makeDefinition()

			local connected =
				BotCombat.ResolveHitAgainstBot(fakePlayer, attackerState, botState, definition, false, nil)

			expect(connected).to.equal(false)
			expect(attackerState.Vitals.posture).to.equal(50 - Constants.Combat.ParryPunishPostureDamage)
			expect(attackerState.Vitals.stunExpiry > 0).to.equal(true)
			expect(vitalsCalls > 0).to.equal(true)
			expect(feedbackCalls[1].Payload.Kind).to.equal("Parried")
		end)

		it("posture-breaks the attacker when a parry punish drops their posture to zero", function()
			local botState = makeBotState({ parryWindowExpiry = os.clock() + 5 })
			local attackerState = makeCombatState({ posture = Constants.Combat.ParryPunishPostureDamage })
			local definition = makeDefinition()

			BotCombat.ResolveHitAgainstBot(fakePlayer, attackerState, botState, definition, false, nil)

			expect(#postureBreakCalls).to.equal(1)
			expect(postureBreakCalls[1].Player).to.equal(fakePlayer)
		end)

		it("triggers the bot's own posture break once its posture crosses zero", function()
			local botState = makeBotState({ posture = 15 })
			local attackerState = makeCombatState()
			local definition = makeDefinition({ Damage = 0, PostureDamage = 20 })

			BotCombat.ResolveHitAgainstBot(fakePlayer, attackerState, botState, definition, false, nil)

			expect(botState.posture).to.equal(0)
			expect(botState.postureBrokenExpiry > 0).to.equal(true)
			expect(#feedbackCalls).to.equal(2)
			expect(feedbackCalls[2].Payload.Kind).to.equal("PostureBreak")
		end)

		it("applies a Block's damage/posture multipliers", function()
			local botState = makeBotState({ blocking = true })
			local attackerState = makeCombatState()
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })

			BotCombat.ResolveHitAgainstBot(fakePlayer, attackerState, botState, definition, false, nil)

			expect(botState.humanoid.Health).to.equal(
				Constants.Combat.MaxHealth - (10 * Constants.Combat.BlockDamageMultiplier)
			)
		end)
	end)

	describe("BotCombat.ResolveHitFromBotAgainstPlayer", function()
		local function makeLiveTargetState(overrides: { [string]: any }?): CombatState
			local character = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.MaxHealth = Constants.Combat.MaxHealth
			humanoid.Health = Constants.Combat.MaxHealth
			humanoid.Parent = character
			return makeCombatState(Fixtures.applyOverrides({ character = character, humanoid = humanoid }, overrides))
		end

		it("deals damage to the real player target and sends vitals + feedback", function()
			local botState = makeBotState()
			local targetState = makeLiveTargetState()
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })

			BotCombat.ResolveHitFromBotAgainstPlayer(botState, fakePlayer, targetState, definition, false)

			expect(targetState.Vitals.posture).to.equal(Constants.Combat.MaxPosture - 20)
			expect((targetState.humanoid :: Humanoid).Health).to.equal(Constants.Combat.MaxHealth - 10)
			expect(vitalsCalls > 0).to.equal(true)
			expect(feedbackCalls[1].Payload.Kind).to.equal("Hit")
		end)

		it("zeroes damage/posture when the target's Godmode Attribute is set", function()
			local botState = makeBotState()
			local targetState = makeLiveTargetState();
			(targetState.humanoid :: Humanoid):SetAttribute(Constants.Attributes.Godmode, true)
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })

			BotCombat.ResolveHitFromBotAgainstPlayer(botState, fakePlayer, targetState, definition, false)

			expect(targetState.Vitals.posture).to.equal(Constants.Combat.MaxPosture)
			expect((targetState.humanoid :: Humanoid).Health).to.equal(Constants.Combat.MaxHealth)
		end)

		it("on a Parry, punishes the bot itself and never touches the target's vitals", function()
			local botState = makeBotState()
			local targetState = makeLiveTargetState({ parryWindowExpiry = os.clock() + 5 })
			local definition = makeDefinition()

			BotCombat.ResolveHitFromBotAgainstPlayer(botState, fakePlayer, targetState, definition, false)

			expect(botState.posture).to.equal(Constants.Combat.MaxPosture - Constants.Combat.ParryPunishPostureDamage)
			expect(botState.stunExpiry > 0).to.equal(true)
			expect(vitalsCalls).to.equal(0)
			expect(feedbackCalls[1].Payload.Kind).to.equal("Parried")
		end)
	end)

	describe("BotCombat.SpawnBot / GetLiveBotState / GetOwnedAliveBots / DespawnBot", function()
		it("creates a live, alive bot reachable through every accessor, then despawns cleanly", function()
			local owner = fakePlayer
			local model, failureReason = BotCombat.SpawnBot(owner, CFrame.new(0, 100, 0))
			expect(failureReason).to.equal(nil)
			expect(model).to.never.equal(nil)

			local botModel = model :: Model
			local state = BotCombat.GetLiveBotState(botModel)
			expect(state).to.never.equal(nil)
			expect((state :: BotState).alive).to.equal(true)

			local foundOwned = false
			for _, ownedState in ipairs(BotCombat.GetOwnedAliveBots(owner)) do
				if ownedState.model == botModel then
					foundOwned = true
				end
			end
			expect(foundOwned).to.equal(true)

			expect(BotCombat.DespawnBot(botModel)).to.equal(true)
			expect(BotCombat.GetLiveBotState(botModel)).to.equal(nil)
			expect(BotCombat.DespawnBot(botModel)).to.equal(false)
		end)
	end)
end
