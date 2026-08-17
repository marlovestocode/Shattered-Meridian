--!strict
-- Covers Server/Combat/Defense/DefenseSystem.lua -- the two-pass resolution, against the real engine.
--
-- Needs a Workspace, like HitboxEngine.spec and for the same reason: the point of this module is that
-- it classifies contacts a live engine found on live bodies, and a synthetic stand-in for that would
-- test the wiring rather than the behaviour. The dummies are built with Instance.new exactly as that
-- spec builds its own -- the deleted DummyCombat/TrainingBotSystem are neither needed nor available,
-- and the engine accepting a bare Model/root/Humanoid is itself part of the contract.
--
-- Time is driven through Step(deltaTime, now) on BOTH modules, in the same order Main.server.lua
-- guarantees at runtime (engine first, defence second). Nothing here sleeps. Init() is deliberately
-- never called: it would connect a real Heartbeat that raced these synthetic Steps, which is exactly
-- why Attach() exists separately.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)

type DefenseOutcome = DefenseTypes.DefenseOutcome

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-parry"
-- Opens on the press so a case does not have to advance time just to arm; closes late enough that a
-- case can choose to sit inside the window or step past it.
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3

type Dummy = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Id: number,
}

local spawned: { Model } = {}

-- Anchored, so every positional assertion here is not a race against gravity.
local function makeDummy(name: string, position: Vector3, lookAt: Vector3?): Dummy
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = if lookAt then CFrame.lookAt(position, lookAt) else CFrame.new(position)
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(spawned, model)

	local id = HitboxEngine.RegisterCombatant(model, root, humanoid)
	DefenseSystem.RegisterCombatant(model, root, humanoid, PARRY_ANIMATION)
	return { Model = model, Root = root, Humanoid = humanoid, Id = id }
end

local function makeDefinition(overrides: { [string]: any }?): HitboxTypes.AttackDefinition
	local base: { [string]: any } = {
		DebugName = "SpecSwing",
		Shape = "Box",
		BaseDimensions = { Width = 4, Height = 6, Length = 6 },
		Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 8 },
		-- Four studs in front of the attacker (-Z is forward), so the volume sits ahead of the body.
		Offset = CFrame.new(0, 0, -4),
		AttachmentPart = "Root",
		WindupSeconds = 0,
		ActiveSeconds = 5,
		RecoverySeconds = 0,
		LocksMovement = false,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return (HitboxTypes.SanitizeDefinition(base))
end

local function captureOutcomes(): ({ DefenseOutcome }, () -> ())
	local outcomes: { DefenseOutcome } = {}
	local disconnect = DefenseSystem.OnResolved(function(outcome: DefenseOutcome)
		table.insert(outcomes, outcome)
	end)
	return outcomes, disconnect
end

-- One frame, in the order Main.server.lua guarantees: the engine fills the batch during its
-- substeps, then defence arbitrates and applies it.
local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, WINDOW_OPEN, WINDOW_CLOSE)
	end)

	afterEach(function()
		DefenseSystem.Reset()
		HitboxEngine.Reset()
		ParryWindows.Reset()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("DefenseSystem -- parrying", function()
		it("cancels the attacker's swing and staggers them", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
			-- The engine's own CancelAttack path ran, so the swing is over and the body released.
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
		end)

		it("restores the defender's guard", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local guard, guardMax = DefenseSystem.GetGuard(defender.Model)
			-- Already full, so the restore is clamped -- the assertion worth making is that a parry
			-- never COSTS guard, which a mis-signed delta would.
			expect(guard).to.equal(guardMax)
		end)

		it("forbids the staggered attacker from attacking again", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local canAttack, reason = DefenseSystem.CanAttack(attacker.Model)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Staggered")
		end)
	end)

	describe("DefenseSystem -- blocking", function()
		it("drains guard on a blocked hit", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			-- Past the window's close, so the guard is genuinely up rather than still parrying.
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Blocked")
			local guard = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.be.near(DefenseConstants.Guard.Max - DefenseConstants.Guard.DrainPerPowerLevel, 1e-3)
		end)

		it("reports a hit to a blocking defender's back as a Backstab", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			-- Facing AWAY from the attacker -- the block covers nothing behind it.
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, -20))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Backstab")
			-- A backstab beats the block outright, so it costs no guard.
			expect(outcomes[1].GuardDelta).to.equal(0)
		end)

		it("reports an unguarded hit as Clean", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)
	end)

	describe("DefenseSystem -- trading", function()
		it("collapses mutual parries in one Step into a single Trade on each side", function()
			local base = os.clock()
			local alpha = makeDummy("Alpha", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local beta = makeDummy("Beta", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(alpha.Model, true, base)
			DefenseSystem.SetBlocking(beta.Model, true, base)
			HitboxEngine.RequestAttack(alpha.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(beta.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(2)
			expect(outcomes[1].Kind).to.equal("Trade")
			expect(outcomes[2].Kind).to.equal("Trade")
			-- Neither is punished: both read correctly.
			expect(DefenseSystem.GetState(alpha.Model)).never.to.equal("Staggered")
			expect(DefenseSystem.GetState(beta.Model)).never.to.equal("Staggered")
		end)

		it("moves neither guard, so a trade cannot be farmed to refill", function()
			local base = os.clock()
			local alpha = makeDummy("Alpha", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local beta = makeDummy("Beta", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(alpha.Model, true, base)
			DefenseSystem.SetBlocking(beta.Model, true, base)
			HitboxEngine.RequestAttack(alpha.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(beta.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(outcomes[1].GuardDelta).to.equal(0)
			expect(outcomes[2].GuardDelta).to.equal(0)
		end)
	end)

	describe("DefenseSystem -- two-pass resolution", function()
		it("classifies a contact against the window state at its OWN SampleTime", function()
			-- THE case a single end-of-frame pass gets wrong. The window opens partway through a long
			-- frame; the contact lands at a substep BEFORE it opened. Resolved against the state at
			-- frame end this reads as Parried, which is a parry for a hit that arrived first.
			local base = os.clock()
			ParryWindows.Reset()
			ParryWindows.Register(PARRY_ANIMATION, 0.05, 0.3)

			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			DefenseSystem.SetBlocking(defender.Model, true, base)
			-- A long frame, so its substeps straddle the window's opening at base + 0.05. The engine
			-- treats `now` as the END of the frame, so the earliest substep lands well before it.
			step(0.2, base + 0.1)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].SampleTime < base + 0.05).to.equal(true)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("bounds the cancel residual at the frame the parry landed in", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			-- Cancels apply in pass 2, so the parried swing keeps sampling for the rest of ITS frame.
			-- What must hold is that it is over by the next one -- the same one-frame bound the engine
			-- already accepts for a callback-started follow-up swing.
			local outcomes, disconnect = captureOutcomes()
			step(FRAME, base + 2 * FRAME)
			step(FRAME, base + 3 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(0)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)
	end)

	describe("DefenseSystem -- fail-closed", function()
		it("blocks without parrying when no window is registered for the animation", function()
			local base = os.clock()
			ParryWindows.Reset()

			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			-- The press still raised the guard; it simply never opened a window.
			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Blocked")
			expect(DefenseSystem.GetState(attacker.Model)).never.to.equal("Staggered")
		end)
	end)

	describe("DefenseSystem -- registration", function()
		it("reports an unregistered target's contacts as Clean rather than dropping them", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.UnregisterCombatant(defender.Model)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			-- The damage layer must still see every contact.
			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)
	end)
end
