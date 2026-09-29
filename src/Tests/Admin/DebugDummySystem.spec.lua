--!strict
-- Covers Server/Systems/DebugDummySystem.lua.
--
-- Driven through the REAL HitboxEngine, DefenseSystem and DamageSystem for the hit/billboard cases,
-- the same "a synthetic stand-in for any of those three would test the wiring rather than the
-- behaviour" reasoning DamageSystem.spec/GrabSystem.spec already give for their own dummies -- this
-- module's whole point is that a dummy it spawns is a REAL registered combatant, so a spec that faked
-- the registration would not actually prove that claim.
--
-- DebugDummySystem.Spawn is exercised directly (not via a hand-built Instance.new rig) for every case
-- below -- it is the exact function DevMenuSystem.handleSpawnDebugDummy calls in production, and
-- Players:CreateHumanoidModelFromDescription with an empty HumanoidDescription needs no asset upload
-- or network round trip (see that function's own header), so it is safe to call from a headless spec.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DebugDummySystem = require(ServerScriptService.Server.Systems.DebugDummySystem)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- A real roster weapon, because the ids below have to RESOLVE through AttackCatalog -- weapons are
-- models in Workspace.Weapons now (Shared/Combat/WeaponRoster.lua), so a spec that installs none gets
-- a catalogue with no weapon moves in it and every lookup returns nil.
local WEAPON = WeaponFixture.Install()[1]

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-debugdummy-parry"
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3
local MOVE_ID = `default:{WEAPON}:Basic:1`

-- Every attacker in this file is a plain hand-built Instance.new dummy, the same shape
-- DamageSystem.spec's own makeDummy uses -- the thing under test is the VICTIM (a real
-- DebugDummySystem.Spawn result), not the attacker, so the attacker only needs to be a legal
-- HitboxEngine/DefenseSystem combatant, not one of this module's own.
local spawnedAttackers: { Model } = {}

local function makeAttacker(position: Vector3, lookAt: Vector3): (Model, number)
	local model = Instance.new("Model")
	model.Name = "Attacker"

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
	table.insert(spawnedAttackers, model)

	local id = HitboxEngine.RegisterCombatant(model, root, humanoid)
	DefenseSystem.RegisterCombatant(model, root, humanoid, PARRY_ANIMATION)
	return model, id
end

local function makeDefinition(): HitboxTypes.AttackDefinition
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

local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
	DamageSystem.Step(deltaTime, now)
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		DamageSystem.Attach()
		DebugDummySystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, WINDOW_OPEN, WINDOW_CLOSE)
	end)

	afterEach(function()
		DebugDummySystem.Reset()
		DamageSystem.Reset()
		DefenseSystem.Reset()
		HitboxEngine.Reset()
		ParryWindows.Reset()
		for _, model in spawnedAttackers do
			model:Destroy()
		end
		table.clear(spawnedAttackers)
	end)

	describe("DebugDummySystem.Spawn", function()
		it("spawns a real combatant registered with HitboxEngine and DefenseSystem", function()
			local model = DebugDummySystem.Spawn(CFrame.new(0, 5, 0))

			expect(model).to.be.ok()
			local realModel = model :: Model
			expect(HitboxEngine.GetCombatantId(realModel)).never.to.equal(nil)
			expect(DefenseSystem.GetState(realModel)).to.equal("Neutral")
		end)

		it("spawns at the given CFrame", function()
			local spawnCFrame = CFrame.new(12, 5, -8)
			local model = DebugDummySystem.Spawn(spawnCFrame) :: Model

			local actual = model:GetPivot()
			expect(math.abs(actual.Position.X - spawnCFrame.Position.X) < 1e-2).to.equal(true)
			expect(math.abs(actual.Position.Y - spawnCFrame.Position.Y) < 1e-2).to.equal(true)
			expect(math.abs(actual.Position.Z - spawnCFrame.Position.Z) < 1e-2).to.equal(true)
		end)

		it("registers a Humanoid unanchored, so a Grab hold can actually carry it", function()
			-- The whole reason Grab "just works" against a debug dummy (see this module's own header)
			-- is that nothing here anchors the rig -- GrabSystem refuses to weld a grounded body into an
			-- attacker's assembly (it would pin the attacker instead), so this is the one property that
			-- would silently break Grab without ever failing loudly anywhere.
			local model = DebugDummySystem.Spawn(CFrame.new(0, 5, 0)) :: Model
			local rootPart = model:FindFirstChild("HumanoidRootPart") :: BasePart
			expect(rootPart.Anchored).to.equal(false)
		end)

		it("evicts the oldest active dummy once MaxActive is reached", function()
			LiveTuningContract.withRestore(function()
				Constants.Debug.TrainingDummy.MaxActive = 2

				local first = DebugDummySystem.Spawn(CFrame.new(0, 5, 0)) :: Model
				DebugDummySystem.Spawn(CFrame.new(10, 5, 0))
				expect(DebugDummySystem.ActiveCount()).to.equal(2)

				-- A third spawn must evict the first (oldest) rather than growing past MaxActive.
				DebugDummySystem.Spawn(CFrame.new(20, 5, 0))
				expect(DebugDummySystem.ActiveCount()).to.equal(2)
				expect(first.Parent).to.equal(nil)
				expect(HitboxEngine.GetCombatantId(first)).to.equal(nil)
			end, function()
				Constants.Debug.TrainingDummy.MaxActive = 5
			end)
		end)
	end)

	describe("DebugDummySystem.DespawnAll", function()
		it("removes and unregisters every active dummy", function()
			local first = DebugDummySystem.Spawn(CFrame.new(0, 5, 0)) :: Model
			local second = DebugDummySystem.Spawn(CFrame.new(10, 5, 0)) :: Model

			local count = DebugDummySystem.DespawnAll()

			expect(count).to.equal(2)
			expect(DebugDummySystem.ActiveCount()).to.equal(0)
			expect(first.Parent).to.equal(nil)
			expect(second.Parent).to.equal(nil)
			expect(HitboxEngine.GetCombatantId(first)).to.equal(nil)
			expect(HitboxEngine.GetCombatantId(second)).to.equal(nil)
		end)
	end)

	describe("DebugDummySystem.SetGuard / IsGuardEnabled", function()
		it("reflects the requested state", function()
			expect(DebugDummySystem.IsGuardEnabled()).to.equal(false)
			expect(DebugDummySystem.SetGuard(true)).to.equal(true)
			expect(DebugDummySystem.IsGuardEnabled()).to.equal(true)
			expect(DebugDummySystem.SetGuard(false)).to.equal(false)
			expect(DebugDummySystem.IsGuardEnabled()).to.equal(false)
		end)

		it("raises an already-active dummy's own guard state out of Neutral", function()
			local model = DebugDummySystem.Spawn(CFrame.new(0, 5, 0)) :: Model
			expect(DefenseSystem.GetState(model)).to.equal("Neutral")

			DebugDummySystem.SetGuard(true)

			expect(DefenseSystem.GetState(model)).never.to.equal("Neutral")
		end)

		it("seeds the current guard state onto a dummy spawned while it is already on", function()
			DebugDummySystem.SetGuard(true)
			local model = DebugDummySystem.Spawn(CFrame.new(0, 5, 0)) :: Model

			expect(DefenseSystem.GetState(model)).never.to.equal("Neutral")
		end)
	end)

	describe("DebugDummySystem -- billboard/event log", function()
		it("records a resolved Clean hit against a spawned dummy on its own billboard", function()
			local base = os.clock()
			local victim = DebugDummySystem.Spawn(CFrame.new(0, 5, -4)) :: Model
			local _attacker, attackerId = makeAttacker(Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))

			HitboxEngine.RequestAttack(attackerId, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local gui = victim:FindFirstChild("DebugDummyLog") :: BillboardGui
			local label = gui:FindFirstChild("Log") :: TextLabel
			expect(string.find(label.Text, "Clean") ~= nil).to.equal(true)
			expect(string.find(label.Text, MOVE_ID) ~= nil).to.equal(true)
		end)

		it("reflects live HP on the billboard once damage lands", function()
			local base = os.clock()
			local victim = DebugDummySystem.Spawn(CFrame.new(0, 5, -4)) :: Model
			local _attacker, attackerId = makeAttacker(Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local humanoid = victim:FindFirstChildOfClass("Humanoid") :: Humanoid

			HitboxEngine.RequestAttack(attackerId, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local gui = victim:FindFirstChild("DebugDummyLog") :: BillboardGui
			local label = gui:FindFirstChild("Log") :: TextLabel
			local expectedHp = `HP {math.floor(humanoid.Health)}`
			expect(string.find(label.Text, expectedHp, 1, true) ~= nil).to.equal(true)
		end)
	end)

	-- NOT COVERED HERE: onDummyDied/reviveInPlace (Humanoid.Died -> unregister -> task.delay ->
	-- destroy-and-respawn at the captured SpawnCFrame). Verified BY READING rather than by an
	-- automated case: a spiked-Health Humanoid:TakeDamage() against a rig built by this same
	-- DebugDummySystem.Spawn in this harness never raises Humanoid.Died at all, waited out past 2 real
	-- seconds (ruling out a timing flake, not just an under-generous wait) -- the run-in-roblox
	-- headless harness this suite runs under drives every OTHER spec's Humanoid state through plain
	-- Attribute/property reads and this stack's own synthetic Step(deltaTime, now) calls, never
	-- through the engine's own internal Death state-machine transition, and this is the first spec in
	-- the whole suite to depend on that transition actually firing. The wiring itself
	-- (humanoid.Died:Connect(function() onDummyDied(dummy) end) in spawnAt, and onDummyDied's own
	-- unregister-then-task.delay-then-reviveInPlace body) is the same shape this stack already trusts
	-- Humanoid.Died for nowhere else -- there is no rebuilt system elsewhere in this codebase that
	-- exercises Humanoid.Died in an automated spec to compare against either. A real Studio/live-server
	-- playtest is what actually proves this path; that is documented as unverified-by-automation in
	-- this feature's own final report rather than left silent.
end
