--!strict
-- Covers knockback end to end except the two lines no headless place can reach (the Players lookup in
-- KnockbackAudit's adapter, and a real client's physics step):
--   * Shared/Damage/Knockback.lua -- which way, how hard, and the audit's pure judgements;
--   * Client/Combat/KnockbackClient.lua -- the hold curve and the per-frame velocity it writes;
--   * Server/Combat/Damage/KnockbackAudit.lua -- the detector, through its resolved-identity seam;
--   * Server/Combat/Damage/DamageSystem.lua -- that a real landed hit resolves DamageResult.Launch and
--     launches a server-owned body, driven through the real HitboxEngine and DefenseSystem.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local Knockback = require(ReplicatedStorage.Shared.Damage.Knockback)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local KnockbackAudit = require(ServerScriptService.Server.Combat.Damage.KnockbackAudit)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local KnockbackClient = require(StarterPlayer.StarterPlayerScripts.Client.Combat.KnockbackClient)

local BOUNDS = DamageConstants.Knockback
local AUDIT = BOUNDS.Audit

local WEAPON = WeaponFixture.Install()[1]
local MOVE_ID = `default:{WEAPON}:Basic:1`
local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-knockback-parry"

local function knock(horizontal: number, up: number): MoveTypes.MoveKnockback
	return { HorizontalVelocity = horizontal, UpVelocity = up, RagdollSeconds = 0 }
end

return function()
	describe("Knockback.LaunchVelocity", function()
		it("carries the defender away from the attacker, flattened, at the authored speeds", function()
			local launch = Knockback.LaunchVelocity(
				Vector3.new(0, 0, 0),
				Vector3.new(0, 3, -10),
				Vector3.new(1, 0, 0),
				knock(40, 20)
			) :: Vector3
			expect(launch).to.be.ok()
			expect(launch.X).to.be.near(0, 1e-4)
			expect(launch.Z).to.be.near(-40, 1e-4)
			expect(launch.Y).to.be.near(20, 1e-4)
		end)

		it("knocks a backstabbed defender forward -- away from the blade, whatever either faces", function()
			local launch = Knockback.LaunchVelocity(
				Vector3.new(0, 0, 5),
				Vector3.new(0, 0, 0),
				Vector3.new(0, 0, -1),
				knock(30, 0)
			) :: Vector3
			expect(launch.Z).to.be.near(-30, 1e-4)
		end)

		it("falls back to the attacker's facing when the two stand on one vertical line", function()
			local launch = Knockback.LaunchVelocity(
				Vector3.new(0, 10, 0),
				Vector3.new(0, 0, 0),
				Vector3.new(1, -1, 0),
				knock(30, 0)
			) :: Vector3
			expect(launch.X).to.be.near(30, 1e-4)
		end)

		it("clamps a mis-authored launch to the safety bounds", function()
			local launch = Knockback.LaunchVelocity(
				Vector3.zero,
				Vector3.new(10, 0, 0),
				Vector3.zAxis,
				knock(9000, 9000)
			) :: Vector3
			expect(launch.X).to.be.near(BOUNDS.MaxHorizontalVelocity, 1e-4)
			expect(launch.Y).to.be.near(BOUNDS.MaxUpVelocity, 1e-4)
		end)

		it("is nil for a move that authors no knock, and treats junk as zero", function()
			expect(Knockback.LaunchVelocity(Vector3.zero, Vector3.xAxis, Vector3.zAxis, knock(0, 0))).to.equal(nil)
			expect(Knockback.LaunchVelocity(Vector3.zero, Vector3.xAxis, Vector3.zAxis, knock(-10, 0 / 0))).to.equal(
				nil
			)
			local pureLift =
				Knockback.LaunchVelocity(Vector3.zero, Vector3.xAxis, Vector3.zAxis, knock(0, 25)) :: Vector3
			expect(pureLift.X).to.equal(0)
			expect(pureLift.Y).to.equal(25)
		end)
	end)

	describe("Knockback audit judgements", function()
		it("only audits launches too strong to confuse with running", function()
			expect(Knockback.IsAuditable(Vector3.new(AUDIT.MinHorizontalVelocity - 1, 50, 0))).to.equal(false)
			expect(Knockback.IsAuditable(Vector3.new(AUDIT.MinHorizontalVelocity, 0, 0))).to.equal(true)
		end)

		it("measures speed along the launch only -- sideways running does not count", function()
			local launch = Vector3.new(60, 10, 0)
			expect(Knockback.SpeedAlong(launch, Vector3.new(0, 0, 50))).to.be.near(0, 1e-4)
			expect(Knockback.SpeedAlong(launch, Vector3.new(30, -5, 0))).to.be.near(30, 1e-4)
			expect(Knockback.SpeedAlong(launch, Vector3.new(-20, 0, 0))).to.be.near(-20, 1e-4)
		end)

		it("complies at the configured fraction of the launch", function()
			local launch = Vector3.new(60, 0, 0)
			expect(Knockback.Complied(launch, 60 * AUDIT.ComplianceFraction)).to.equal(true)
			expect(Knockback.Complied(launch, 60 * AUDIT.ComplianceFraction - 0.1)).to.equal(false)
		end)
	end)

	describe("KnockbackClient", function()
		it("holds the horizontal launch, decaying to nothing over HoldSeconds", function()
			local flat = Vector3.new(40, 0, 0)
			expect(KnockbackClient.HorizontalAt(flat, 0.2, 0).X).to.be.near(40, 1e-4)
			expect(KnockbackClient.HorizontalAt(flat, 0.2, 0.1).X).to.be.near(20, 1e-4)
			expect(KnockbackClient.HorizontalAt(flat, 0.2, 0.2)).to.equal(Vector3.zero)
			expect(KnockbackClient.HorizontalAt(flat, 0.2, -0.01)).to.equal(Vector3.zero)
		end)

		it("writes the launch's lift once, then carries the body's own vertical velocity", function()
			local launch = Vector3.new(40, 25, 0)
			local first = KnockbackClient.VelocityAt(launch, 0.2, 0, true, Vector3.new(3, -8, 0))
			expect(first.Y).to.equal(25)
			expect(first.X).to.be.near(40, 1e-4)
			local later = KnockbackClient.VelocityAt(launch, 0.2, 0.1, false, Vector3.new(3, 12, 0))
			expect(later.Y).to.equal(12)
			expect(later.X).to.be.near(20, 1e-4)
		end)
	end)

	describe("KnockbackAudit", function()
		local player: any
		local root: Part

		beforeEach(function()
			KnockbackAudit.Reset()
			player = { Name = "Launched", UserId = 4242 }
			root = Instance.new("Part")
		end)

		afterEach(function()
			KnockbackAudit.Reset()
			root:Destroy()
		end)

		local strong = Vector3.new(AUDIT.MinHorizontalVelocity * 2, 20, 0)

		it("does not audit a weak launch", function()
			expect(KnockbackAudit.Begin(player, root, Vector3.new(5, 30, 0), 0)).to.equal(false)
			expect(KnockbackAudit.IsPending(player)).to.equal(false)
		end)

		it("passes a client that honoured the launch at any sample", function()
			KnockbackAudit.Begin(player, root, strong, 0)
			expect(KnockbackAudit.Sample(player, Vector3.zero, 0.05)).to.equal(nil)
			expect(KnockbackAudit.Sample(player, strong, 0.2)).to.equal("Complied")
			expect(KnockbackAudit.IsPending(player)).to.equal(false)
		end)

		it("fails a client that stood its ground for the whole window", function()
			KnockbackAudit.Begin(player, root, strong, 0)
			expect(KnockbackAudit.Sample(player, Vector3.new(0, 0, 16), 0.5)).to.equal(nil)
			expect(KnockbackAudit.Sample(player, Vector3.new(0, 0, 16), AUDIT.SampleSeconds)).to.equal("Failed")
		end)

		it("judges only the latest launch", function()
			KnockbackAudit.Begin(player, root, strong, 0)
			KnockbackAudit.Begin(player, root, -strong, 0.1)
			-- Honouring the FIRST launch's direction is not honouring the one that replaced it.
			expect(KnockbackAudit.Sample(player, strong, 0.2)).to.equal(nil)
			expect(KnockbackAudit.Sample(player, -strong, 0.3)).to.equal("Complied")
		end)

		it("flags once, only after a pattern of failures inside the window", function()
			for index = 1, AUDIT.FailuresBeforeFlag - 1 do
				expect(KnockbackAudit.RecordFailure(player, index)).to.equal(false)
			end
			expect(KnockbackAudit.RecordFailure(player, AUDIT.FailuresBeforeFlag)).to.equal(true)
			expect(KnockbackAudit.RecordFailure(player, AUDIT.FailuresBeforeFlag + 1)).to.equal(false)
		end)

		it("forgets failures that fall out of the window", function()
			for index = 1, AUDIT.FailuresBeforeFlag - 1 do
				KnockbackAudit.RecordFailure(player, index)
			end
			expect(KnockbackAudit.RecordFailure(player, AUDIT.WindowSeconds + 100)).to.equal(false)
		end)

		it("drops everything about a player who leaves", function()
			KnockbackAudit.Begin(player, root, strong, 0)
			KnockbackAudit.ReleasePlayer(player)
			expect(KnockbackAudit.IsPending(player)).to.equal(false)
			expect(KnockbackAudit.Sample(player, strong, 0.1)).to.equal(nil)
		end)
	end)

	describe("DamageSystem resolves and applies the launch", function()
		local spawned: { Model } = {}
		local captured: { any } = {}
		local disconnect: (() -> ())? = nil

		local function makeDummy(name: string, position: Vector3, lookAt: Vector3, anchored: boolean)
			local model = Instance.new("Model")
			model.Name = name
			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Size = Vector3.new(2, 2, 1)
			root.Anchored = anchored
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

		local function definition(): HitboxTypes.AttackDefinition
			return (
				HitboxTypes.SanitizeDefinition({
					DebugName = MOVE_ID,
					Shape = "Box",
					BaseDimensions = { Width = 4, Height = 6, Length = 6 },
					Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 8 },
					Offset = CFrame.new(0, 0, -4),
					AttachmentPart = "Root",
					WindupSeconds = 0,
					ActiveSeconds = 5,
					RecoverySeconds = 0,
					LocksMovement = false,
				})
			)
		end

		local function authorKnock(k: MoveTypes.MoveKnockback?): ()
			local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
			move.Knockback = k
			MoveRegistryManager.Upsert(move)
		end

		local function step(now: number): ()
			HitboxEngine.Step(FRAME, now)
			DefenseSystem.Step(FRAME, now)
			DamageSystem.Step(FRAME, now)
		end

		beforeEach(function()
			DefenseSystem.Attach()
			DamageSystem.Attach()
			ParryWindows.Register(PARRY_ANIMATION, 0, 0.3)
			table.clear(captured)
			disconnect = DamageSystem.OnApplied(function(outcome, result)
				table.insert(captured, { Kind = outcome.Kind, Launch = result.Launch })
			end)
		end)

		afterEach(function()
			if disconnect then
				disconnect()
				disconnect = nil
			end
			DamageSystem.Reset()
			DefenseSystem.Reset()
			HitboxEngine.Reset()
			ParryWindows.Reset()
			MoveRegistryManager.Init()
			for _, model in spawned do
				model:Destroy()
			end
			table.clear(spawned)
		end)

		it("puts the launch on DamageResult before OnApplied subscribers see it", function()
			authorKnock(knock(40, 15))
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), true)

			HitboxEngine.RequestAttack(attacker.Id, definition(), 1, 1)
			step(os.clock() + FRAME)

			expect(#captured).to.equal(1)
			local launch = captured[1].Launch :: Vector3
			expect(launch).to.be.ok()
			expect(launch.Z).to.be.near(-40, 1e-3)
			expect(launch.Y).to.be.near(15, 1e-3)
		end)

		it("launches a server-owned body on the server", function()
			authorKnock(knock(40, 15))
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)

			HitboxEngine.RequestAttack(attacker.Id, definition(), 1, 1)
			step(os.clock() + FRAME)

			local velocity = defender.Root.AssemblyLinearVelocity
			expect(velocity.Z < -1).to.equal(true)
		end)

		it("resolves no launch for a move that authors none", function()
			authorKnock(nil)
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), true)

			HitboxEngine.RequestAttack(attacker.Id, definition(), 1, 1)
			step(os.clock() + FRAME)

			expect(#captured).to.equal(1)
			expect(captured[1].Launch).to.equal(nil)
		end)

		it("resolves no launch for a hit the defender's guard held", function()
			authorKnock(knock(40, 15))
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), true)

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(base + 0.3 + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, definition(), 1, 1)
			step(base + 0.3 + 2 * FRAME)

			expect(#captured).to.equal(1)
			expect(captured[1].Kind).to.equal("Blocked")
			expect(captured[1].Launch).to.equal(nil)
		end)
	end)
end
