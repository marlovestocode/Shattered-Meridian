--!strict
-- Covers ONE VOLLEY, ONE HIT PER BODY and ParryAll (Server/Combat/HitboxEngine/ProjectileSimulator.lua's
-- header) END TO END: a multi-shot cast thrown through the REAL HitboxEngine, judged by the REAL
-- DefenseSystem and priced by the REAL DamageSystem. The bug these pin: a five-shot cast landed five priced
-- Clean hits (five combo steps) on one Debug Dummy, and a ParryAll volley's other shots had all ended on
-- the parrier in the frame before the parry could reach them.
--
-- Harness is DamageSystem.spec's: the three layers stepped in boot order on a synthetic clock, Init never
-- called, and a real catalogue MoveId as the definition's DebugName so the damage layer prices it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local ProjectileSimulator = require(ServerScriptService.Server.Combat.HitboxEngine.ProjectileSimulator)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local CombatHarness = require(ServerScriptService.Tests.TestHelpers.CombatHarness)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type Dummy = CombatHarness.Dummy

local WEAPON = WeaponFixture.Install()[1]
local MOVE_ID = `default:{WEAPON}:Basic:1`
local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-volley-parry"

local spawnDummy = CombatHarness.Spawner({ ParryAnimation = PARRY_ANIMATION })

-- A cast of `spec` over the defaults, named as a real move so the damage layer prices it. Five shots in a
-- tight parallel row by default: every one of them reaches a body standing in front of the thrower.
local function volley(spec: { [string]: any }?): HitboxTypes.AttackDefinition
	local projectile = ProjectileTypes.Defaults() :: any
	projectile.Speed = 100
	projectile.Count = 5
	projectile.SpreadPattern = "Horizontal"
	projectile.Spacing = 0.25
	for key, value in spec or {} do
		projectile[key] = value
	end
	return (
		HitboxTypes.SanitizeDefinition({
			DebugName = MOVE_ID,
			Shape = "Sphere",
			BaseDimensions = { Radius = 1 },
			Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 1 },
			Offset = CFrame.new(0, 0, -2),
			AttachmentPart = "Root",
			WindupSeconds = 0,
			ActiveSeconds = 0.5,
			RecoverySeconds = 0,
			LocksMovement = false,
			Projectile = projectile,
		})
	)
end

local function step(now: number): ()
	HitboxEngine.Step(FRAME, now)
	DefenseSystem.Step(FRAME, now)
	DamageSystem.Step(FRAME, now)
end

local function run(clock: number, seconds: number): number
	for _ = 1, math.ceil(seconds / FRAME - 1e-6) do
		clock += FRAME
		step(clock)
	end
	return clock
end

local function captureOutcomes(): ({ DefenseOutcome }, () -> ())
	local outcomes: { DefenseOutcome } = {}
	local disconnect = DefenseSystem.OnResolved(function(outcome: DefenseOutcome)
		table.insert(outcomes, outcome)
	end)
	return outcomes, disconnect
end

local function captureApplied(): ({ DefenseOutcome }, () -> ())
	local applied: { DefenseOutcome } = {}
	local disconnect = DamageSystem.OnApplied(function(outcome: DefenseOutcome, _result)
		table.insert(applied, outcome)
	end)
	return applied, disconnect
end

local function on(outcomes: { DefenseOutcome }, model: Model): { DefenseOutcome }
	local found: { DefenseOutcome } = {}
	for _, outcome in outcomes do
		if outcome.Defender == model then
			table.insert(found, outcome)
		end
	end
	return found
end

local function authoredDamage(): number
	return (AttackCatalog.Get(MOVE_ID) :: any).Profile.Damage
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		DamageSystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, 0, 0.3)
	end)

	afterEach(function()
		CombatHarness.Teardown()
	end)

	describe("A multi-shot volley -- one hit per body", function()
		it("lands a five-shot cast on an open body once: one Clean contact, one damage application", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -10))
			local target = spawnDummy("Target", Vector3.new(0, 5, -10), Vector3.new(0, 5, 0))
			local before = target.Humanoid.Health
			local outcomes, disconnectOutcomes = captureOutcomes()
			local applied, disconnectApplied = captureApplied()

			HitboxEngine.RequestAttack(attacker.Id, volley(), 1, 1)
			run(os.clock(), 0.6)
			disconnectOutcomes()
			disconnectApplied()

			local struck = on(outcomes, target.Model)
			expect(#struck).to.equal(1)
			expect(struck[1].Kind).to.equal("Clean")
			expect(#on(applied, target.Model)).to.equal(1)
			expect(target.Humanoid.Health).to.be.near(before - authoredDamage(), 1e-3)
		end)

		it("counts every wave of the cast as the same volley", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -10))
			local target = spawnDummy("Target", Vector3.new(0, 5, -10), Vector3.new(0, 5, 0))
			local outcomes, disconnect = captureOutcomes()

			HitboxEngine.RequestAttack(
				attacker.Id,
				volley({ Count = 2, WaveCount = 3, WaveIntervalSeconds = 0.1 }),
				1,
				1
			)
			run(os.clock(), 0.8)
			disconnect()

			expect(#on(outcomes, target.Model)).to.equal(1)
		end)

		it("still strikes each OTHER body it reaches once", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -10))
			local left = spawnDummy("Left", Vector3.new(-3.6, 5, -10), Vector3.new(0, 5, 0))
			local right = spawnDummy("Right", Vector3.new(3.6, 5, -10), Vector3.new(0, 5, 0))
			local outcomes, disconnect = captureOutcomes()

			HitboxEngine.RequestAttack(attacker.Id, volley({ SpreadPattern = "Fan", SpreadAngle = 40 }), 1, 1)
			run(os.clock(), 0.6)
			disconnect()

			expect(#on(outcomes, left.Model)).to.equal(1)
			expect(#on(outcomes, right.Model)).to.equal(1)
		end)
	end)

	describe("A multi-shot volley -- parrying it", function()
		-- The thrower at the origin facing -Z, the defender four studs ahead facing back, guard raised so a
		-- parry window is live when the first shot arrives.
		local function standOff(): (Dummy, Dummy, number)
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.SetBlocking(defender.Model, true, base)
			return attacker, defender, base
		end

		it("ParryAll: one parry neutralises every shot of the volley, and nothing else reaches the parrier", function()
			local attacker, defender, base = standOff()
			local before = defender.Humanoid.Health
			local outcomes, disconnectOutcomes = captureOutcomes()
			local applied, disconnectApplied = captureApplied()

			HitboxEngine.RequestAttack(
				attacker.Id,
				volley({ ParryBehavior = "ParryAll", ParryResponse = "Destroy" }),
				1,
				1
			)
			local clock = run(base, 2 * FRAME)
			expect(HitboxEngine.LiveProjectileCount()).to.equal(0)
			run(clock, 0.5)
			disconnectOutcomes()
			disconnectApplied()

			local struck = on(outcomes, defender.Model)
			expect(#struck).to.equal(1)
			expect(struck[1].Kind).to.equal("Parried")
			for _, outcome in on(applied, defender.Model) do
				expect(outcome.Kind).to.equal("Parried")
			end
			expect(defender.Humanoid.Health).to.equal(before)
		end)

		it("ParryAll drops the volley's waves not yet fired", function()
			local attacker, defender, base = standOff()
			local outcomes, disconnect = captureOutcomes()

			HitboxEngine.RequestAttack(
				attacker.Id,
				volley({
					Count = 2,
					WaveCount = 4,
					WaveIntervalSeconds = 0.1,
					ParryBehavior = "ParryAll",
					ParryResponse = "Destroy",
				}),
				1,
				1
			)
			local clock = run(base, 2 * FRAME)
			expect(ProjectileSimulator.PendingCount()).to.equal(0)
			run(clock, 0.6)
			disconnect()

			expect(#on(outcomes, defender.Model)).to.equal(1)
			expect(on(outcomes, defender.Model)[1].Kind).to.equal("Parried")
		end)

		it("ParryAll + Reflect turns the whole volley back, and lands it on its thrower once", function()
			local attacker, defender, base = standOff()
			local outcomes, disconnect = captureOutcomes()

			HitboxEngine.RequestAttack(
				attacker.Id,
				volley({ ParryBehavior = "ParryAll", ParryResponse = "Reflect", ReflectionDirection = "ToOwner" }),
				1,
				1
			)
			run(base, 0.6)
			disconnect()

			expect(#on(outcomes, defender.Model)).to.equal(1)
			local returned = on(outcomes, attacker.Model)
			expect(#returned).to.equal(1)
			expect(returned[1].Attacker).to.equal(defender.Model)
		end)

		it("ParryOne answers one shot, and the rest of the volley still cannot strike the parrier", function()
			local attacker, defender, base = standOff()
			local before = defender.Humanoid.Health
			local outcomes, disconnect = captureOutcomes()

			HitboxEngine.RequestAttack(
				attacker.Id,
				volley({ ParryBehavior = "ParryOne", ParryResponse = "Destroy" }),
				1,
				1
			)
			run(base, 0.6)
			disconnect()

			local struck = on(outcomes, defender.Model)
			expect(#struck).to.equal(1)
			expect(struck[1].Kind).to.equal("Parried")
			expect(defender.Humanoid.Health).to.equal(before)
		end)
	end)
end
