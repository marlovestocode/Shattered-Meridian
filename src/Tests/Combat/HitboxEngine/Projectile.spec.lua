--!strict
-- Covers projectile delivery in Server/Combat/HitboxEngine -- ProjectileSimulator, driven through the
-- engine's own RequestAttack/Step exactly as a thrown move is, against real Instances.
--
-- The dummies are the engine spec's: a Model, an anchored root, a Humanoid, all facing -Z. A shot spawns
-- two studs in front of its thrower and flies -Z unless a case says otherwise. Time is driven through
-- Step on a synthetic clock, a frame at a time, so a case says how far a shot has flown.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local ProjectileSimulator = require(ServerScriptService.Server.Combat.HitboxEngine.ProjectileSimulator)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

type HitReport = HitboxTypes.HitReport
type ProjectileEvent = ProjectileSimulator.ProjectileEvent

local FRAME = 1 / 60
local EPSILON = 1e-3

type Dummy = { Model: Model, Root: BasePart, Humanoid: Humanoid, Id: number }

local spawned: { Instance } = {}

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
	return {
		Model = model,
		Root = root,
		Humanoid = humanoid,
		Id = HitboxEngine.RegisterCombatant(model, root, humanoid),
	}
end

local function makeWall(position: Vector3): Part
	local wall = Instance.new("Part")
	wall.Name = "SpecWall"
	wall.Size = Vector3.new(30, 30, 1)
	wall.Anchored = true
	wall.CanCollide = true
	wall.CFrame = CFrame.new(position)
	wall.Parent = Workspace
	table.insert(spawned, wall)
	return wall
end

-- A projectile attack: no windup unless a case sets one, a short active window, the given spec over the
-- defaults.
local function projectileAttack(spec: { [string]: any }?, overrides: { [string]: any }?): HitboxTypes.AttackDefinition
	local projectile = ProjectileTypes.Defaults() :: any
	projectile.Speed = 100
	for key, value in pairs(spec or {}) do
		projectile[key] = value
	end
	local base: { [string]: any } = {
		DebugName = "SpecShot",
		Shape = "Sphere",
		BaseDimensions = { Radius = 1 },
		Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 1 },
		Offset = CFrame.new(0, 0, -2),
		AttachmentPart = "Root",
		WindupSeconds = 0,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0,
		LocksMovement = false,
		Projectile = projectile,
	}
	for key, value in pairs(overrides or {}) do
		base[key] = value
	end
	return (HitboxTypes.SanitizeDefinition(base))
end

local function captureHits(): ({ HitReport }, () -> ())
	local hits: { HitReport } = {}
	local disconnect = HitboxEngine.OnHit(function(report: HitReport)
		table.insert(hits, report)
	end)
	return hits, disconnect
end

local function captureEvents(): ({ ProjectileEvent }, () -> ())
	local events: { ProjectileEvent } = {}
	local disconnect = HitboxEngine.OnProjectileEvents(function(batch)
		for _, event in batch do
			table.insert(events, event)
		end
	end)
	return events, disconnect
end

-- Steps the engine `seconds` forward from `clock`, a frame at a time; returns the new clock.
local function run(clock: number, seconds: number): number
	for _ = 1, math.ceil(seconds / FRAME - 1e-6) do
		clock += FRAME
		HitboxEngine.Step(FRAME, clock)
	end
	return clock
end

local function throw(attacker: Dummy, definition: HitboxTypes.AttackDefinition): number
	local accepted = HitboxEngine.RequestAttack(attacker.Id, definition, 1, 0)
	assert(accepted, "the spec's attack was refused")
	return os.clock()
end

local function yawOf(direction: Vector3): number
	return math.deg(math.atan2(direction.X, -direction.Z))
end

return function()
	afterEach(function()
		HitboxEngine.Reset()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	describe("HitboxEngine -- projectile launch", function()
		it("launches the volley when the active window opens, not when the attack is requested", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local clock = throw(attacker, projectileAttack({}, { WindupSeconds = 0.2 }))
			expect(HitboxEngine.LiveProjectileCount()).to.equal(0)

			clock = run(clock, 0.1)
			expect(HitboxEngine.LiveProjectileCount()).to.equal(0)
			run(clock, 0.15)
			expect(HitboxEngine.LiveProjectileCount()).to.equal(1)
		end)

		it("flies a five-shot 30 degree fan at evenly spaced headings", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			local clock = throw(attacker, projectileAttack({ SpreadPattern = "Fan", Count = 5, SpreadAngle = 30 }))
			run(clock, FRAME)
			disconnect()

			local yaws: { number } = {}
			for _, event in events do
				if event.Kind == "Launch" then
					table.insert(yaws, yawOf(event.Velocity.Unit))
					expect(event.Owner).to.equal(attacker.Model)
					expect(event.MoveId).to.equal("SpecShot")
				end
			end
			table.sort(yaws)
			expect(#yaws).to.equal(5)
			for index, expected in { -15, -7.5, 0, 7.5, 15 } do
				expect(math.abs(yaws[index] - expected) < EPSILON).to.equal(true)
			end
		end)

		it("gives every shot of one volley its own id and the volley's shared group id", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			throw(attacker, projectileAttack({ SpreadPattern = "Fan", Count = 3 }))
			local second = makeDummy("Second", Vector3.new(50, 5, 0))
			throw(second, projectileAttack({ SpreadPattern = "Fan", Count = 2 }))
			run(os.clock(), FRAME)
			disconnect()

			local ids: { [number]: boolean } = {}
			local groups: { [Model]: number } = {}
			for _, event in events do
				if event.Kind == "Launch" then
					expect(ids[event.Id]).to.equal(nil)
					ids[event.Id] = true
					local owner = event.Owner :: Model
					groups[owner] = groups[owner] or event.GroupId
					expect(event.GroupId).to.equal(groups[owner])
				end
			end
			expect(groups[attacker.Model]).never.to.equal(groups[second.Model])
		end)
	end)

	describe("HitboxEngine -- projectile bodies (Shape)", function()
		it("reports a plain sphere's contact as a Sphere of its Size", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ Size = 1.5 })), 0.4)
			disconnect()
			expect(#hits).to.equal(1)
			expect(hits[1].Shape).to.equal("Sphere")
			expect(hits[1].Dimensions.Radius).to.equal(1.5)
		end)

		it("sweeps a wide slab through a target a sphere of the same Size would miss", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Beside", Vector3.new(4, 5, -20))

			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ Size = 1 })), 0.4)
			disconnect()
			expect(#hits).to.equal(0)

			HitboxEngine.Reset()
			local again = makeDummy("Attacker2", Vector3.new(0, 5, 0))
			makeDummy("Beside2", Vector3.new(4, 5, -20))
			local slabHits, disconnectSlab = captureHits()
			run(throw(again, projectileAttack({ Shape = "Box", Width = 12, Height = 6, Length = 1.5 })), 0.4)
			disconnectSlab()
			expect(#slabHits).to.equal(1)
			expect(slabHits[1].Shape).to.equal("Box")
			expect(slabHits[1].Dimensions.Width).to.equal(12)
		end)

		it("does not tunnel a thin shaped shot through a body between two steps", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -30))
			local hits, disconnect = captureHits()
			-- 400 studs/s is more than six studs a frame against a 0.6-stud body.
			run(throw(attacker, projectileAttack({ Shape = "Capsule", Size = 0.3, Length = 2, Speed = 400 })), 0.4)
			disconnect()
			expect(#hits).to.equal(1)
		end)

		it("sends a body only for a shot that is not a plain sphere", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(throw(attacker, projectileAttack({ Shape = "Wedge", Width = 3, Height = 1, Length = 5 })), 0.1)
			HitboxEngine.Reset()
			local again = makeDummy("Attacker2", Vector3.new(0, 5, 0))
			run(throw(again, projectileAttack({})), 0.1)
			disconnect()
			local wedgeLaunch, sphereLaunch
			for _, event in events do
				if event.Kind == "Launch" then
					if event.Body ~= nil then
						wedgeLaunch = event
					else
						sphereLaunch = event
					end
				end
			end
			expect(wedgeLaunch).to.be.ok()
			expect((wedgeLaunch :: any).Body.Shape).to.equal("Wedge")
			expect((wedgeLaunch :: any).Body.Length).to.equal(5)
			expect(sphereLaunch).to.be.ok()
		end)

		it("meets a wall with its tip, not its middle", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeWall(Vector3.new(0, 5, -20))
			local events, disconnect = captureEvents()
			run(throw(attacker, projectileAttack({ Shape = "Capsule", Size = 0.5, Length = 10 })), 0.5)
			disconnect()
			local ended: ProjectileEvent? = nil
			for _, event in events do
				if event.Kind == "End" and event.Reason == "World" then
					ended = event
				end
			end
			expect(ended).to.be.ok()
			-- The wall's near face is at z = -19.5. The shot's middle stops a tip's reach (5.5) short of it.
			local z = (ended :: ProjectileEvent).Position.Z
			expect(z > -15 and z < -13).to.equal(true)
		end)
	end)

	describe("HitboxEngine -- projectile contacts", function()
		it("reports a contact as an ordinary HitReport with the shot attached", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack()), 0.4)
			disconnect()

			expect(#hits).to.equal(1)
			local report = hits[1]
			expect(report.Attacker).to.equal(attacker.Model)
			expect(report.Target).to.equal(target.Model)
			expect(report.DebugName).to.equal("SpecShot")
			local projectile = report.Projectile :: ProjectileTypes.ProjectileContact
			expect(projectile).to.be.ok()
			expect(projectile.Parryable).to.equal(true)
			expect(projectile.StaggersOwner).to.equal(true)
			expect(projectile.DamageScale).to.equal(1)
			-- It came from the thrower's side: the source sits behind the contact along the flight.
			expect(projectile.SourcePosition.Z > report.ContactPosition.Z).to.equal(true)
			expect(projectile.Direction.Z < -0.99).to.equal(true)
			-- Not piercing: the first body ends it.
			expect(HitboxEngine.LiveProjectileCount()).to.equal(0)
		end)

		it("never hits its own thrower, even spawned inside the body", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({}, { Offset = CFrame.identity })), 0.3)
			disconnect()
			expect(#hits).to.equal(0)
		end)

		it("passes through MaxPierces targets when piercing, and stops at the first when not", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Near", Vector3.new(0, 5, -10))
			makeDummy("Far", Vector3.new(0, 5, -20))

			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ Piercing = true, MaxPierces = 1 })), 0.4)
			disconnect()
			expect(#hits).to.equal(2)
			expect(hits[1].Target.Name).to.equal("Near")
			expect(hits[2].Target.Name).to.equal("Far")

			HitboxEngine.Reset()
			local again = makeDummy("Attacker2", Vector3.new(0, 5, 0))
			local hitsAgain, disconnectAgain = captureHits()
			-- The two targets from the first half are still in Workspace but no longer registered, so a
			-- fresh pair stands in for them.
			makeDummy("Near2", Vector3.new(0, 5, -10))
			makeDummy("Far2", Vector3.new(0, 5, -20))
			run(throw(again, projectileAttack({ Piercing = false })), 0.4)
			disconnectAgain()
			expect(#hitsAgain).to.equal(1)
			expect(hitsAgain[1].Target.Name).to.equal("Near2")
		end)

		it("reports a CannotParry shot as unparryable", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Target", Vector3.new(0, 5, -10))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ ParryBehavior = "CannotParry" })), 0.3)
			disconnect()
			expect(#hits).to.equal(1)
			expect((hits[1].Projectile :: ProjectileTypes.ProjectileContact).Parryable).to.equal(false)
		end)

		it("homes onto a target its straight line would miss", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeDummy("Aside", Vector3.new(8, 5, -20))

			local hits, disconnect = captureHits()
			local clock = run(throw(attacker, projectileAttack({ Homing = false })), 0.5)
			expect(#hits).to.equal(0)

			HitboxEngine.RequestAttack(
				attacker.Id,
				projectileAttack({ Homing = true, HomingStrength = 360, HomingMaxAngle = 60, HomingRange = 60 }),
				1,
				0
			)
			run(clock, 0.6)
			disconnect()
			expect(#hits).to.equal(1)
			expect(hits[1].Target.Name).to.equal("Aside")
		end)
	end)

	describe("HitboxEngine -- projectiles and the world", function()
		it("ends a Destroy shot on a wall", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeWall(Vector3.new(0, 5, -15))
			local events, disconnect = captureEvents()
			run(throw(attacker, projectileAttack({ CollisionBehavior = "Destroy" })), 0.3)
			disconnect()

			local ended: ProjectileEvent? = nil
			for _, event in events do
				if event.Kind == "End" then
					ended = event
				end
			end
			expect(ended).to.be.ok()
			expect((ended :: ProjectileEvent).Reason).to.equal("World")
			expect((ended :: ProjectileEvent).Position.Z > -15).to.equal(true)
		end)

		it("bounces a Bounce shot back off a wall, MaxBounces times", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeWall(Vector3.new(0, 5, -15))
			local clock = throw(attacker, projectileAttack({ CollisionBehavior = "Bounce", MaxBounces = 1 }))
			local id = ProjectileSimulator.LiveIds()[1]
			run(clock, 0.2)

			local state = ProjectileSimulator.Inspect(id) :: { [string]: any }
			expect(state.Alive).to.equal(true)
			expect(state.BouncesLeft).to.equal(0)
			expect(state.Velocity.Z > 0).to.equal(true)
		end)

		it("passes a Continue shot straight through a wall", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			makeWall(Vector3.new(0, 5, -10))
			local target = makeDummy("Behind", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ CollisionBehavior = "Continue" })), 0.4)
			disconnect()
			expect(#hits).to.equal(1)
			expect(hits[1].Target).to.equal(target.Model)
		end)

		it("ends at its lifetime and at its range", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			-- Past the first attack's active window, so the second is not refused as Busy.
			local clock = run(throw(attacker, projectileAttack({ LifetimeSeconds = 0.1 })), 0.3)
			HitboxEngine.RequestAttack(attacker.Id, projectileAttack({ MaxRange = 5 }), 1, 0)
			run(clock, 0.2)
			disconnect()

			local reasons: { string } = {}
			for _, event in events do
				if event.Kind == "End" then
					table.insert(reasons, event.Reason :: string)
				end
			end
			expect(table.find(reasons, "Expired")).to.be.ok()
			expect(table.find(reasons, "Range")).to.be.ok()
		end)
	end)

	describe("HitboxEngine.ParryProjectile / PassProjectile", function()
		it("Reflect hands a parried shot to the parrier and sends it back at the thrower, scaled", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			local clock = run(
				throw(
					attacker,
					projectileAttack({
						ParryResponse = "Reflect",
						ReflectionDirection = "ToOwner",
						ReflectedDamageMultiplier = 2,
					})
				),
				0.3
			)
			expect(#hits).to.equal(1)
			local shot = hits[1].Projectile :: ProjectileTypes.ProjectileContact

			expect(HitboxEngine.ParryProjectile(shot.Id, target.Model, clock)).to.equal(true)
			run(clock, 0.4)
			disconnect()

			expect(#hits).to.equal(2)
			expect(hits[2].Attacker).to.equal(target.Model)
			expect(hits[2].Target).to.equal(attacker.Model)
			expect((hits[2].Projectile :: ProjectileTypes.ProjectileContact).DamageScale).to.equal(2)
		end)

		it("Reverse retraces the shot's path, owned by the parrier", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local target = makeDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			local clock = run(throw(attacker, projectileAttack({ ParryResponse = "Reverse" })), 0.3)
			local shot = hits[1].Projectile :: ProjectileTypes.ProjectileContact
			HitboxEngine.ParryProjectile(shot.Id, target.Model, clock)
			disconnect()

			local state = ProjectileSimulator.Inspect(shot.Id) :: { [string]: any }
			expect(state.Alive).to.equal(true)
			expect(state.Owner).to.equal(target.Model)
			expect(state.Velocity.Z > 99).to.equal(true)
		end)

		it("Destroy ends a shot still in flight", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local clock = throw(attacker, projectileAttack({ ParryResponse = "Destroy", Piercing = true }))
			local id = ProjectileSimulator.LiveIds()[1]
			local parrier = makeDummy("Parrier", Vector3.new(0, 5, -30))
			HitboxEngine.ParryProjectile(id, parrier.Model, clock)
			expect((ProjectileSimulator.Inspect(id) :: any).Alive).to.equal(false)
		end)

		it("ParryAll ends every shot of the volley still flying; ParryOne only the one parried", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local parrier = makeDummy("Parrier", Vector3.new(0, 5, -60))
			local clock = throw(
				attacker,
				projectileAttack({
					SpreadPattern = "Fan",
					Count = 3,
					ParryBehavior = "ParryAll",
					ParryResponse = "Destroy",
				})
			)
			clock = run(clock, FRAME)
			HitboxEngine.ParryProjectile(ProjectileSimulator.LiveIds()[1], parrier.Model, clock)
			clock = run(clock, FRAME)
			expect(HitboxEngine.LiveProjectileCount()).to.equal(0)

			-- Past the first attack's active window, so the second is not refused as Busy.
			clock = run(clock, 0.25)
			HitboxEngine.RequestAttack(
				attacker.Id,
				projectileAttack({
					SpreadPattern = "Fan",
					Count = 3,
					ParryBehavior = "ParryOne",
					ParryResponse = "Destroy",
				}),
				1,
				0
			)
			clock = run(clock, FRAME)
			HitboxEngine.ParryProjectile(ProjectileSimulator.LiveIds()[1], parrier.Model, clock)
			run(clock, FRAME)
			expect(HitboxEngine.LiveProjectileCount()).to.equal(2)
		end)

		it("PassProjectile lets an evaded shot fly on through to the next body", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local near = makeDummy("Near", Vector3.new(0, 5, -10))
			local far = makeDummy("Far", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			local clock = run(throw(attacker, projectileAttack()), 0.15)
			expect(#hits).to.equal(1)
			expect(hits[1].Target).to.equal(near.Model)

			HitboxEngine.PassProjectile((hits[1].Projectile :: ProjectileTypes.ProjectileContact).Id, near.Model, clock)
			run(clock, 0.3)
			disconnect()
			expect(#hits).to.equal(2)
			expect(hits[2].Target).to.equal(far.Model)
		end)

		it("forgets nothing it was asked about too early, and answers false for an unknown id", function()
			local parrier = makeDummy("Parrier", Vector3.new(0, 5, 0))
			expect(HitboxEngine.ParryProjectile(424242, parrier.Model, os.clock())).to.equal(false)
			expect(HitboxEngine.PassProjectile(424242, parrier.Model, os.clock())).to.equal(false)
		end)
	end)

	describe("ProjectileMotion agrees with the engine", function()
		it("launches exactly the shots Volley computes for the same aim", function()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0))
			local definition = projectileAttack({ SpreadPattern = "Radial", Count = 6, SpreadAngle = 40 })
			local events, disconnect = captureEvents()
			run(throw(attacker, definition), FRAME)
			disconnect()

			local expected =
				ProjectileMotion.Volley(definition.Projectile :: ProjectileTypes.ProjectileSpec, CFrame.new(0, 5, -2))
			local launches: { ProjectileEvent } = {}
			for _, event in events do
				if event.Kind == "Launch" then
					table.insert(launches, event)
				end
			end
			expect(#launches).to.equal(#expected)
			for index, launch in launches do
				local angle = ProjectileMotion.AngleBetween(launch.Velocity.Unit, expected[index].Direction)
				expect(angle < EPSILON).to.equal(true)
			end
		end)
	end)
end
