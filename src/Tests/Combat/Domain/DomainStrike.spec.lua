--!strict
-- Covers a realm's strike END TO END: Server/Combat/Domain/DomainEffects.lua delivering a real catalogue
-- move through the REAL HitboxEngine.LaunchVolley, judged by the REAL DefenseSystem and priced by the REAL
-- DamageSystem -- the "a realm routes damage through the existing pipeline" claim, asserted rather than
-- described. Also the engine seam's two options a swing never uses (exclusivity, the barrier slot) and the
-- damage layer reading a realm's rules off the defender.
--
-- Harness is DamageSystem.spec's: rigs built with Instance.new, the three layers stepped in boot order on
-- a synthetic clock, Init never called.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DomainEffects = require(ServerScriptService.Server.Combat.Domain.DomainEffects)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local ProjectileSimulator = require(ServerScriptService.Server.Combat.HitboxEngine.ProjectileSimulator)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local WEAPON = WeaponFixture.Install()[1]
local MOVE_ID = `default:{WEAPON}:Basic:1`
local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-domain-parry"

type Dummy = { Model: Model, Root: BasePart, Humanoid: Humanoid, Id: number }

local spawned: { Model } = {}

local function makeDummy(name: string, position: Vector3): Dummy
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = CFrame.new(position)
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

local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
	DamageSystem.Step(deltaTime, now)
end

local function run(clock: number, seconds: number): number
	for _ = 1, math.ceil(seconds / FRAME) do
		clock += FRAME
		step(FRAME, clock)
	end
	return clock
end

local function realPorts(): DomainEffects.Ports
	return {
		CatalogGet = function(moveId: string)
			return AttackCatalog.Get(moveId) :: any
		end,
		LaunchVolley = function(owner, definition, aim, powerLevel, now, options)
			return HitboxEngine.LaunchVolley(owner, definition, aim, powerLevel, now, options :: any)
		end,
		ExtendHitstun = DamageSystem.ExtendHitstun,
		DrainGuard = function(model, amount, now)
			DefenseSystem.DrainGuard(model, amount, now)
			return nil
		end,
		ThrowMove = function()
			return false, "NotInSpec"
		end,
		Impulse = function() end,
	}
end

local function strikeEffect(overrides: { [string]: any }?): DomainTypes.Effect
	local effect = DomainTypes.DefaultEffect() :: any
	effect.Kind = "Strike"
	effect.MoveId = MOVE_ID
	effect.Origin = "Above"
	effect.OriginDistance = 12
	effect.TravelSeconds = 0.3
	for key, value in overrides or {} do
		effect[key] = value
	end
	return effect
end

local function source(owner: Dummy, id: string?): DomainEffects.Source
	return { Id = id or "D-spec", Owner = owner.Model, Center = owner.Root.Position, Random = Random.new(1) }
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
		DamageSystem.Reset()
		DefenseSystem.Reset()
		HitboxEngine.Reset()
		ParryWindows.Reset()
		DomainEffects.ResetForTesting()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("A realm's strike, through the whole combat stack", function()
		it("lands the referenced move's own damage on its target, as the realm's owner", function()
			local owner = makeDummy("Owner", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -15))
			local before = target.Humanoid.Health
			local applied: { any } = {}
			local disconnect = DamageSystem.OnApplied(function(outcome, _result)
				table.insert(applied, outcome)
			end)

			local clock = os.clock()
			local reached =
				DomainEffects.Deliver(strikeEffect(), source(owner), { target.Model }, clock, 1, realPorts())
			expect(#reached).to.equal(1)
			run(clock, 1)
			disconnect()

			expect(target.Humanoid.Health).to.be.near(before - authoredDamage(), 1e-3)
			expect(#applied).to.equal(1)
			expect(applied[1].Attacker).to.equal(owner.Model)
			expect(applied[1].Report.DebugName).to.equal(MOVE_ID)
			expect(applied[1].Report.Projectile.DomainId).to.equal("D-spec")
		end)

		it("is pinned to its target: a body standing in the line is not struck", function()
			local owner = makeDummy("Owner", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -15))
			-- Directly under the strike's origin, between it and the target.
			local bystander = makeDummy("Bystander", Vector3.new(0, 11, -15))
			local bystanderBefore = bystander.Humanoid.Health

			local clock = os.clock()
			DomainEffects.Deliver(strikeEffect(), source(owner), { target.Model }, clock, 1, realPorts())
			run(clock, 1)

			expect(bystander.Humanoid.Health).to.equal(bystanderBefore)
			expect(target.Humanoid.Health < target.Humanoid.MaxHealth).to.equal(true)
		end)

		it("lands lighter from a contested realm", function()
			local owner = makeDummy("Owner", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -15))
			local before = target.Humanoid.Health
			local clock = os.clock()
			DomainEffects.Deliver(strikeEffect(), source(owner), { target.Model }, clock, 0.5, realPorts())
			run(clock, 1)
			expect(target.Humanoid.Health).to.be.near(before - authoredDamage() * 0.5, 1e-3)
		end)
	end)

	describe("DamageSystem reading a realm's rules", function()
		it("scales damage by the defender's DamageTaken rule while its lease holds", function()
			local owner = makeDummy("Owner", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -15))
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "DamageTaken", 2, nil)
			DomainRules.Publish(target.Humanoid, set, DomainRules.ServerNow() + 60, "D-spec")
			local before = target.Humanoid.Health

			local clock = os.clock()
			DomainEffects.Deliver(strikeEffect(), source(owner), { target.Model }, clock, 1, realPorts())
			run(clock, 1)
			expect(target.Humanoid.Health).to.be.near(before - authoredDamage() * 2, 1e-3)
		end)

		it("ignores a rule whose lease has already passed", function()
			local owner = makeDummy("Owner", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -15))
			local set = DomainRules.Empty()
			DomainRules.Apply(set, "DamageTaken", 2, nil)
			DomainRules.Publish(target.Humanoid, set, DomainRules.ServerNow() - 1, "D-spec")
			local before = target.Humanoid.Health

			local clock = os.clock()
			DomainEffects.Deliver(strikeEffect(), source(owner), { target.Model }, clock, 1, realPorts())
			run(clock, 1)
			expect(target.Humanoid.Health).to.be.near(before - authoredDamage(), 1e-3)
		end)
	end)

	describe("HitboxEngine's realm seam", function()
		it("ends a shot at the barrier slot's closed edge", function()
			local owner = makeDummy("Owner", Vector3.new(0, 5, 0))
			local projectile = ProjectileTypes.Defaults() :: any
			projectile.Speed = 60
			local definition = HitboxTypes.SanitizeDefinition({
				DebugName = "SpecShot",
				Shape = "Sphere",
				ActiveSeconds = 0.1,
				Projectile = projectile,
			})
			HitboxEngine.SetProjectileBarrier(function(_owner, _domainId, from, to)
				return from.Z > -10 and to.Z <= -10
			end)
			local clock = os.clock()
			local groupId, launched = HitboxEngine.LaunchVolley(
				owner.Model,
				definition,
				CFrame.lookAt(Vector3.new(0, 5, -2), Vector3.new(0, 5, -50)),
				1,
				clock,
				nil
			)
			expect(launched).to.equal(1)
			expect(groupId > 0).to.equal(true)
			run(clock, 0.5)
			local ids = ProjectileSimulator.LiveIds()
			expect(#ids).to.equal(0)
			local shot = ProjectileSimulator.Inspect(1)
			if shot then
				expect(shot.EndReason).to.equal("Barrier")
				expect(shot.Position.Z > -10.5).to.equal(true)
			end
			HitboxEngine.SetProjectileBarrier(nil)
		end)

		it("refuses to launch for an owner the engine does not know", function()
			local stranger = Instance.new("Model")
			table.insert(spawned, stranger)
			local definition = HitboxTypes.SanitizeDefinition({ Projectile = ProjectileTypes.Defaults() })
			local _, launched = HitboxEngine.LaunchVolley(stranger, definition, CFrame.identity, 1, os.clock(), nil)
			expect(launched).to.equal(0)
		end)
	end)
end
