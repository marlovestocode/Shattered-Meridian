--!strict
-- Covers Server/Combat/TrainingBot/TrainingBotSystem.lua.
--
-- End to end through the REAL HitboxEngine, DefenseSystem, DamageSystem and AttackRequestSystem --
-- the claim this module makes is that the bot fights through exactly the entry points a player does,
-- so the only honest test is one where its swings land and its parries resolve in the live stack,
-- with nothing stubbed between its decision and the outcome.
--
-- Time is driven through each module's Step(deltaTime, now) in the order Main.server.lua guarantees
-- (engine, defence, damage, attack, bot). No Init() is called: it would connect real Heartbeats racing
-- these synthetic Steps -- the same reason every combat spec uses Attach() instead.
--
-- The bot is spawned through TrainingBotSystem.Spawn -- the function DevMenuSystem calls -- and its root
-- is then ANCHORED, because a headless test place has no floor: an unanchored rig falls away from its
-- target and turns every contact into a flake. Anchoring changes nothing under test (the engine samples
-- the root's CFrame either way), and the brain's Random is re-seeded so the fight is deterministic.
--
-- The harness has no Players, so every fight is pointed with SetTarget -- the same seam that lets two
-- bots be pointed at each other.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackRequestSystem = require(ServerScriptService.Server.Combat.Attack.AttackRequestSystem)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local TrainingBotConstants = require(ReplicatedStorage.Shared.TrainingBot.TrainingBotConstants)
local TrainingBotSystem = require(ServerScriptService.Server.Combat.TrainingBot.TrainingBotSystem)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

-- Installed once for the whole VM and never removed -- see WeaponFixture's own header on why a per-spec
-- Remove tears the roster out from under other files.
WeaponFixture.Install()

local FRAME = 1 / 60
local ORIGIN = Vector3.new(0, 500, 0)

local opponents: { Model } = {}

-- A plain hand-built opponent, the same shape every combat spec's makeDummy uses: an anchored root, a
-- Humanoid, registered with the engine and the defence layer. Stands `distance` studs in front of the
-- bot, facing it.
local function makeOpponent(distance: number): Model
	local model = Instance.new("Model")
	model.Name = "Opponent"

	local position = ORIGIN + Vector3.new(0, 0, -distance)
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = CFrame.lookAt(position, ORIGIN)
	root.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.MaxHealth = 1000
	humanoid.Health = 1000
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(opponents, model)

	HitboxEngine.RegisterCombatant(model, root, humanoid)
	DefenseSystem.RegisterCombatant(model, root, humanoid, DefenseConstants.ParryAnimationId)
	return model
end

-- Spawns a bot at ORIGIN facing -Z (toward every opponent above), anchored and seeded.
local function spawnBot(style: string, difficulty: string, seed: number): Model
	local model = TrainingBotSystem.Spawn(CFrame.lookAt(ORIGIN, ORIGIN + Vector3.new(0, 0, -1)), style, difficulty, nil)
	assert(model, "TrainingBotSystem.Spawn returned nil")
	local root = CharacterUtil.RootOf(model)
	assert(root, "bot has no root")
	root.Anchored = true
	local brain = TrainingBotSystem.GetBrain(model)
	assert(brain, "bot has no brain")
	brain.Rng = Random.new(seed)
	return model
end

local function step(now: number): ()
	HitboxEngine.Step(FRAME, now)
	DefenseSystem.Step(FRAME, now)
	DamageSystem.Step(FRAME, now)
	AttackRequestSystem.Step(FRAME, now)
	TrainingBotSystem.Step(FRAME, now)
end

type Recorded = { Kind: string, Attacker: Model, Defender: Model }

return function()
	local recorded: { Recorded } = {}
	local disconnect: (() -> ())? = nil

	beforeEach(function()
		DefenseSystem.Attach()
		DamageSystem.Attach()
		TrainingBotSystem.Attach()
		-- The window every combatant here parries with: the house clip, registered exactly as
		-- DefenseSystem.Init registers it in a live server.
		ParryWindows.Register(DefenseConstants.ParryAnimationId, 0, 0.2)
		table.clear(recorded)
		disconnect = DamageSystem.OnApplied(function(outcome, _result)
			table.insert(recorded, { Kind = outcome.Kind, Attacker = outcome.Attacker, Defender = outcome.Defender })
		end)
	end)

	afterEach(function()
		if disconnect then
			disconnect()
			disconnect = nil
		end
		TrainingBotSystem.Reset()
		AttackRequestSystem.Reset()
		DamageSystem.Reset()
		DefenseSystem.Reset()
		HitboxEngine.Reset()
		ParryWindows.Reset()
		for _, model in opponents do
			model:Destroy()
		end
		table.clear(opponents)
	end)

	describe("TrainingBotSystem -- spawning", function()
		it("spawns a real, armed, R6 combatant", function()
			local model = spawnBot("FullFight", "Adept", 1)
			expect(model:FindFirstChild("Torso")).to.be.ok()
			expect(HitboxEngine.GetCombatantId(model)).to.be.ok()
			expect(DefenseSystem.IsRegistered(model)).to.equal(true)
			expect(AttackRequestSystem.GetWeapon(model)).to.equal(WeaponRoster.Default())
			local humanoid = CharacterUtil.HumanoidOf(model) :: Humanoid
			expect(humanoid.MaxHealth).to.equal(TrainingBotConstants.Config.MaxHealth)
			expect(humanoid.AutoRotate).to.equal(false)
		end)

		it("evicts the oldest past MaxActive, and DespawnAll clears every one", function()
			local first = spawnBot("FullFight", "Adept", 1)
			for index = 2, TrainingBotConstants.Config.MaxActive + 1 do
				spawnBot("FullFight", "Adept", index)
			end
			expect(TrainingBotSystem.ActiveCount()).to.equal(TrainingBotConstants.Config.MaxActive)
			expect(first.Parent).to.equal(nil)
			expect(HitboxEngine.GetCombatantId(first)).to.equal(nil)

			expect(TrainingBotSystem.DespawnAll()).to.equal(TrainingBotConstants.Config.MaxActive)
			expect(TrainingBotSystem.ActiveCount()).to.equal(0)
		end)

		it("fights with the weapon it was spawned with, and falls back for one the roster does not know", function()
			local picked = WeaponRoster.FISTS_ID
			local armed = TrainingBotSystem.Spawn(CFrame.new(ORIGIN), "FullFight", "Adept", nil, picked) :: Model
			expect(AttackRequestSystem.GetWeapon(armed)).to.equal(picked)

			local fallback =
				TrainingBotSystem.Spawn(CFrame.new(ORIGIN), "FullFight", "Adept", nil, "NotAWeapon") :: Model
			expect(AttackRequestSystem.GetWeapon(fallback)).to.equal(WeaponRoster.Default())
		end)

		it("falls back to the default preset for an unknown name rather than failing", function()
			local model = TrainingBotSystem.Spawn(CFrame.new(ORIGIN), "NotAStyle", "NotADifficulty", nil)
			expect(model).to.be.ok()
			local brain = TrainingBotSystem.GetBrain(model :: Model)
			expect(brain).to.be.ok()
			expect((brain :: any).Style).to.equal(TrainingBotConstants.Styles[TrainingBotConstants.DefaultStyle])
		end)
	end)

	describe("TrainingBotSystem -- fighting through the real stack", function()
		it("lands its swings on a target in reach", function()
			local bot = spawnBot("AttackOnly", "Master", 21)
			local opponent = makeOpponent(4)
			TrainingBotSystem.SetTarget(bot, opponent)

			local now = 100
			for _ = 1, 60 * 4 do
				now += FRAME
				step(now)
			end

			local landed = 0
			for _, outcome in recorded do
				if outcome.Attacker == bot and outcome.Defender == opponent then
					landed += 1
				end
			end
			expect(landed > 0).to.equal(true)
			local humanoid = CharacterUtil.HumanoidOf(opponent) :: Humanoid
			expect(humanoid.Health < humanoid.MaxHealth).to.equal(true)
		end)

		it("reads a real Heavy off the attack layer and parries it", function()
			local bot = spawnBot("ParryOnly", "Master", 5)
			local opponent = makeOpponent(4)
			TrainingBotSystem.SetTarget(bot, opponent)

			local now = 200
			-- A beat of neutral first, so the bot has a target and a settled frame before the swing.
			for _ = 1, 10 do
				now += FRAME
				step(now)
			end
			local accepted = AttackRequestSystem.Throw(opponent, { Kind = "Heavy" }, false, now)
			expect(accepted).to.equal(true)
			-- What the bot reads: the move, when it started, that it is a Heavy.
			local view = AttackRequestSystem.GetInFlight(opponent)
			expect(view).to.be.ok()
			expect((view :: any).PowerLevel >= 2).to.equal(true)

			for _ = 1, 90 do
				now += FRAME
				step(now)
			end

			local parried = false
			for _, outcome in recorded do
				if outcome.Kind == "Parried" and outcome.Defender == bot and outcome.Attacker == opponent then
					parried = true
				end
			end
			expect(parried).to.equal(true)
		end)

		it("a BlockOnly bot blocks the same Heavy instead", function()
			local bot = spawnBot("BlockOnly", "Master", 5)
			local opponent = makeOpponent(4)
			TrainingBotSystem.SetTarget(bot, opponent)

			local now = 300
			for _ = 1, 10 do
				now += FRAME
				step(now)
			end
			expect(AttackRequestSystem.Throw(opponent, { Kind = "Heavy" }, false, now)).to.equal(true)
			for _ = 1, 90 do
				now += FRAME
				step(now)
			end

			local kinds: { string } = {}
			for _, outcome in recorded do
				if outcome.Defender == bot then
					table.insert(kinds, outcome.Kind)
				end
			end
			expect(table.concat(kinds, ",")).to.equal("Blocked")
		end)

		it("learns from the contacts its own swings make", function()
			local bot = spawnBot("AttackOnly", "Master", 33)
			local opponent = makeOpponent(4)
			TrainingBotSystem.SetTarget(bot, opponent)
			-- The opponent holds its guard the whole time: every contact is Blocked.
			DefenseSystem.SetBlocking(opponent, true, 400)

			local brain = TrainingBotSystem.GetBrain(bot) :: any
			local before = brain.Habits.Block
			local now = 400
			for _ = 1, 60 * 4 do
				now += FRAME
				step(now)
			end
			expect(brain.Habits.Block > before).to.equal(true)
		end)
	end)

	describe("AttackRequestSystem.GetInFlight", function()
		it("is nil for a combatant that is not swinging", function()
			local opponent = makeOpponent(4)
			expect(AttackRequestSystem.GetInFlight(opponent)).to.equal(nil)
		end)

		it("goes nil again once the swing is over", function()
			local opponent = makeOpponent(4)
			local now = 500
			expect(AttackRequestSystem.Throw(opponent, { Kind = "Basic" }, false, now)).to.equal(true)
			local view = AttackRequestSystem.GetInFlight(opponent)
			expect(view).to.be.ok()
			expect((view :: any).StartedAt).to.equal(now)
			for _ = 1, 60 * 3 do
				now += FRAME
				step(now)
			end
			expect(AttackRequestSystem.GetInFlight(opponent)).to.equal(nil)
		end)
	end)
end
