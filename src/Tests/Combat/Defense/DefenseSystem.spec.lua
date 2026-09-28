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

	describe("DefenseSystem -- a guard waits for a committed body", function()
		-- Before this, a guard could be raised mid-swing and both ran at once: the swing's hitbox stayed
		-- live while its thrower blocked. The press is HELD, not refused -- the guard comes up the frame
		-- the body is free, provided the key is still down.
		it("holds a guard pressed mid-swing and raises it once the swing is over", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			step(FRAME, base + FRAME)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")

			step(FRAME, base + 0.3)
			expect(DefenseSystem.GetState(fighter.Model)).never.to.equal("Neutral")
		end)

		it("refuses a fresh swing while a held guard is waiting", function()
			-- The key is down: the swing that ends the commitment must not be followed by another one
			-- ahead of the guard the player is still asking for.
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)

			local canAttack, reason = DefenseSystem.CanAttack(fighter.Model)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Guarding")
		end)

		it("forgets a held guard whose key came up before the swing ended", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			DefenseSystem.SetBlocking(fighter.Model, false, base + FRAME)
			step(FRAME, base + 0.3)

			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")
			expect((DefenseSystem.CanAttack(fighter.Model))).to.equal(true)
		end)

		it("holds a guard pressed while stunned until the stun ends", function()
			-- HitstunUntil is the damage layer's published stun (AttributeConstants) -- the seam this layer
			-- reads because it may not require the layer above it.
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))
			fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

			DefenseSystem.SetBlocking(fighter.Model, true, base)
			step(FRAME, base + 0.2)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")

			step(FRAME, base + 0.6)
			expect(DefenseSystem.GetState(fighter.Model)).never.to.equal("Neutral")
		end)

		it("raises the guard at once for a body nothing commits", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(fighter.Model, true, base)
			expect(DefenseSystem.GetState(fighter.Model)).never.to.equal("Neutral")
		end)
	end)

	describe("DefenseSystem -- the roll's evade frames", function()
		local EVADE = DefenseConstants.Evade

		it("resolves a contact inside the window as Evaded, costing nothing and cancelling nothing", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			-- Opened far enough back that the contact below lands mid-window, clear of the startup.
			expect(DefenseSystem.BeginEvade(defender.Model, base - EVADE.StartupSeconds - 0.02)).to.equal(true)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Evaded")
			expect(outcomes[1].GuardDelta).to.equal(0)
			local guard, guardMax = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.equal(guardMax)
			-- Unlike a parry, the swing carries on -- the defender was simply not there.
			expect(HitboxEngine.GetAttackState(attacker.Id)).never.to.equal("Idle")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Neutral")
		end)

		it("does not let the same swing re-hit once the window has closed", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.BeginEvade(defender.Model, base - EVADE.StartupSeconds - 0.02)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			-- Well past the evade window, the swing still active and the defender still inside it.
			step(FRAME, base + 1)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Evaded")
		end)

		it("is hit during the startup -- pressing roll as the swing lands is too late", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.BeginEvade(defender.Model, base + FRAME * 0.5)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("refuses mid-swing -- no rolling out of your own attack", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)

			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Committed")
		end)

		it("refuses while stunned", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))
			fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Committed")
			expect((DefenseSystem.BeginEvade(fighter.Model, base + 0.6))).to.equal(true)
		end)

		it("refuses while staggered", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")

			local ok, reason = DefenseSystem.BeginEvade(attacker.Model, base + 2 * FRAME)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Staggered")
		end)

		it("refuses while grabbed or mounted", function()
			local base = os.clock()
			local grabbed = makeDummy("Grabbed", Vector3.new(0, 5, 0))
			grabbed.Humanoid:SetAttribute("Grabbed", true)
			local ok, reason = DefenseSystem.BeginEvade(grabbed.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Restrained")

			local mounted = makeDummy("Mounted", Vector3.new(10, 5, 0))
			mounted.Humanoid:SetAttribute("Mounted", true)
			expect((DefenseSystem.BeginEvade(mounted.Model, base))).to.equal(false)
		end)

		it("refuses inside its own cooldown", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))
			expect(DefenseSystem.BeginEvade(fighter.Model, base)).to.equal(true)
			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base + 0.1)
			expect(ok).to.equal(false)
			expect(reason).to.equal("EvadeCooldown")
		end)

		it("drops a raised guard and a deferred one", function()
			local base = os.clock()
			local fighter = makeDummy("Fighter", Vector3.new(0, 5, 0))
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Blocking")

			expect(DefenseSystem.BeginEvade(fighter.Model, base + 1)).to.equal(true)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")
			expect((DefenseSystem.CanAttack(fighter.Model))).to.equal(true)
		end)

		it("reports an unregistered model rather than erroring", function()
			local model = Instance.new("Model")
			local ok, reason = DefenseSystem.BeginEvade(model, os.clock())
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotRegistered")
			model:Destroy()
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

		it("parries on the default clip's window when a weapon's own clip carries none", function()
			-- A weapon that authored a PARRY clip with no markers used to lose its parry entirely.
			local base = os.clock()
			DefenseSystem.SetDefaultParryAnimation(PARRY_ANIMATION)

			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.SetParryAnimation(defender.Model, "rbxassetid://spec-unmarked-weapon-parry")

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
		end)

		it("still only blocks when neither the clip nor the default has a window", function()
			local base = os.clock()
			ParryWindows.Reset()
			DefenseSystem.SetDefaultParryAnimation(PARRY_ANIMATION)

			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(outcomes[1].Kind).to.equal("Blocked")
		end)
	end)

	describe("DefenseConstants.RegisteredParryWindows", function()
		it("arms the shipped parry clip, so a timed block press really parries", function()
			-- The parry was unreachable in play until this table existed: the shipped clip carries no
			-- marker pair, and ParryWindows fails closed. These are what DefenseSystem.Init registers.
			ParryWindows.Reset()
			for animationId, window in DefenseConstants.RegisteredParryWindows do
				expect(ParryWindows.Register(animationId, window.Open, window.Close, window.RecoveryEnd)).to.equal(true)
			end
			expect(ParryWindows.IsArmed(DefenseConstants.ParryAnimationId)).to.equal(true)
			local armed = ParryWindows.Get(DefenseConstants.ParryAnimationId) :: any
			expect(armed.Close > armed.Open).to.equal(true)
		end)
	end)

	-- The seam per-weapon parry clips arrive through. Server/Main.server.lua subscribes to
	-- AttackRequestSystem.OnWeaponChanged and calls SetParryAnimation with
	-- WeaponDefenseAnimations.GetParry(weaponId), so a weapon swap is a WINDOW swap -- these cases are
	-- what keep that true. See that function's own header for why the wiring lives in the boot script.
	describe("DefenseSystem -- SetParryAnimation", function()
		-- Opens later than PARRY_ANIMATION's 0, so which clip is armed is observable from the state
		-- alone: a window open at 0 chains through Raising within the press, one open later does not.
		local LATE_ANIMATION = "rbxassetid://spec-parry-late"

		-- The two halves are separate cases on separate bodies rather than one press-swap-press
		-- sequence, because releasing inside a LIVE window deliberately does not close it (a released
		-- tap can still parry) -- so a second press on the same body would hit Press's own "already
		-- guarding" early return and report the first window's state, proving nothing about the swap.
		it("arms the spawn-time clip's window when nothing has re-pointed it", function()
			local base = os.clock()
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- PARRY_ANIMATION's window opens at 0, so the press chains through Raising within the call.
			DefenseSystem.SetBlocking(defender.Model, true, base)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("ParryWindow")
		end)

		it("arms the window of the clip it was pointed at, not the one it registered with", function()
			local base = os.clock()
			ParryWindows.Register(LATE_ANIMATION, 0.2, 0.5)
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- Same press, same instant, on a body re-pointed at a clip whose window opens 0.2s in: still
			-- Raising rather than live. The ONLY difference from the case above is the swapped clip.
			DefenseSystem.SetParryAnimation(defender.Model, LATE_ANIMATION)
			DefenseSystem.SetBlocking(defender.Model, true, base)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Raising")
		end)

		-- A weapon with no PARRY clip of its own resolves to a blank id rather than to nothing, so this
		-- is a real argument the boot wiring can pass, not a defensive check against a caller mistake.
		it("fail-closes on a blank id -- the guard still raises, no window opens", function()
			local base = os.clock()
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetParryAnimation(defender.Model, "")
			DefenseSystem.SetBlocking(defender.Model, true, base)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Blocking")
		end)

		-- The boot subscription fires on character bind, which can beat this System's own
		-- PlayerLifecycle registration. Silently ignoring an unregistered model is what makes that
		-- ordering a non-issue rather than a race to get right.
		it("ignores a model it has no registration for", function()
			local stray = Instance.new("Model")
			stray.Name = "Unregistered"
			stray.Parent = Workspace
			table.insert(spawned, stray)

			expect(function()
				DefenseSystem.SetParryAnimation(stray, PARRY_ANIMATION)
			end).never.to.throw()
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
