--!strict
-- Covers what the defence layer does with a PROJECTILE contact (Server/Combat/Defense/DefenseSystem.lua's
-- projectile seam): the existing parry judges it, and the shot -- not the thrower's swing -- takes the
-- answer, unless the move chose the existing parry's own response.
--
-- The harness is DefenseSystem.spec's: real engine, real defence layer, anchored dummies facing each other
-- four studs apart, both Stepped in Main.server.lua's order on a synthetic clock. A shot spawns two studs
-- in front of the thrower and reaches the defender inside the first frame.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type DefenseOutcome = DefenseTypes.DefenseOutcome

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-projectile-parry"

type Dummy = { Model: Model, Root: BasePart, Humanoid: Humanoid, Id: number }

local spawned: { Model } = {}

local function makeDummy(name: string, position: Vector3, lookAt: Vector3): Dummy
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = CFrame.lookAt(position, lookAt)
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

local function shot(spec: { [string]: any }): HitboxTypes.AttackDefinition
	local projectile = ProjectileTypes.Defaults() :: any
	projectile.Speed = 100
	for key, value in pairs(spec) do
		projectile[key] = value
	end
	return (
		HitboxTypes.SanitizeDefinition({
			DebugName = "SpecShot",
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

local function captureOutcomes(): ({ DefenseOutcome }, () -> ())
	local outcomes: { DefenseOutcome } = {}
	local disconnect = DefenseSystem.OnResolved(function(outcome: DefenseOutcome)
		table.insert(outcomes, outcome)
	end)
	return outcomes, disconnect
end

local function step(now: number): ()
	HitboxEngine.Step(FRAME, now)
	DefenseSystem.Step(FRAME, now)
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, 0, 0.3)
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

	-- The pair every case uses: the thrower at the origin facing -Z, the defender four studs ahead facing
	-- back at them, guard raised on the first frame so a parry window is live.
	local function standOff(): (Dummy, Dummy, number)
		local base = os.clock()
		local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
		local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
		DefenseSystem.SetBlocking(defender.Model, true, base)
		return attacker, defender, base
	end

	describe("DefenseSystem -- parrying a projectile", function()
		it("answers the shot, not the thrower: their swing runs on and they are not staggered", function()
			local attacker, _, base = standOff()
			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, shot({ ParryResponse = "Destroy" }), 1, 1)
			step(base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
			expect(outcomes[1].Report.Projectile).to.be.ok()
			expect(HitboxEngine.GetAttackState(attacker.Id)).never.to.equal("Idle")
			expect(DefenseSystem.GetState(attacker.Model)).never.to.equal("Staggered")
			expect(HitboxEngine.LiveProjectileCount()).to.equal(0)
		end)

		it("ExistingParry punishes the thrower exactly as a parried swing does", function()
			local attacker, _, base = standOff()
			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, shot({ ParryResponse = "ExistingParry" }), 1, 1)
			step(base + FRAME)
			disconnect()

			expect(outcomes[1].Kind).to.equal("Parried")
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
		end)

		it("CannotParry meets a live parry window as the guard it also is", function()
			local attacker, _, base = standOff()
			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, shot({ ParryBehavior = "CannotParry" }), 1, 1)
			step(base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Blocked")
			expect(DefenseSystem.GetState(attacker.Model)).never.to.equal("Staggered")
		end)

		it("Reflect sends the parried shot back as the parrier's, to land on its thrower", function()
			local attacker, defender, base = standOff()
			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(
				attacker.Id,
				shot({ ParryResponse = "Reflect", ReflectionDirection = "ToOwner" }),
				1,
				1
			)
			local now = base
			for _ = 1, 10 do
				now += FRAME
				step(now)
			end
			disconnect()

			expect(outcomes[1].Kind).to.equal("Parried")
			local returned: DefenseOutcome? = nil
			for _, outcome in outcomes do
				if outcome.Attacker == defender.Model and outcome.Defender == attacker.Model then
					returned = outcome
				end
			end
			expect(returned).to.be.ok()
			expect((returned :: DefenseOutcome).Kind).to.equal("Clean")
		end)

		it("never makes a projectile contact a Trade", function()
			-- Both fire at each other and both guard: two parried shots, each answered on its shot.
			local base = os.clock()
			local alpha = makeDummy("Alpha", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local beta = makeDummy("Beta", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.SetBlocking(alpha.Model, true, base)
			DefenseSystem.SetBlocking(beta.Model, true, base)
			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(alpha.Id, shot({ ParryResponse = "Destroy" }), 1, 1)
			HitboxEngine.RequestAttack(beta.Id, shot({ ParryResponse = "Destroy" }), 1, 1)
			step(base + FRAME)
			disconnect()

			for _, outcome in outcomes do
				expect(outcome.Kind).never.to.equal("Trade")
			end
		end)
	end)
end
