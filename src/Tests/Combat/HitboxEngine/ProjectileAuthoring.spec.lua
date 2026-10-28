--!strict
-- Covers the 2026-10-26 projectile authoring expansion (docs/architecture/2026-10-26-move-creator-projectile-
-- expansion.md): the schema's compatibility, budget, recipes and warnings (ProjectileTypes); the formation,
-- wave, weave, homing-window, intercept and falloff math (ProjectileMotion); and, through the engine's own
-- RequestAttack/Step exactly as a thrown move runs, waves and their cancellation, range modes, the return,
-- re-hits, the proximity fuse, target spawns, and the deferred end effects (burst, split) against the
-- defence layer's verdicts.
--
-- The dummies are Projectile.spec's: anchored, facing -Z; a shot spawns two studs in front of its thrower.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local ProjectileSimulator = require(ServerScriptService.Server.Combat.HitboxEngine.ProjectileSimulator)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local CombatHarness = require(ServerScriptService.Tests.TestHelpers.CombatHarness)
local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)

type HitReport = HitboxTypes.HitReport
type ProjectileEvent = ProjectileSimulator.ProjectileEvent
type Spec = ProjectileTypes.ProjectileSpec
type Dummy = CombatHarness.Dummy

local FRAME = 1 / 60
local EPSILON = 1e-3

local spawnDummy = CombatHarness.Spawner({ Defense = false })

-- The fields this expansion added: an "old record" is the defaults with every one of these removed.
local NEW_FIELDS = {
	"Columns",
	"FormationRadius",
	"ConvergeDistance",
	"WaveCount",
	"WaveIntervalSeconds",
	"ShotIntervalSeconds",
	"WaveRollDegrees",
	"WaveAim",
	"AlternateSides",
	"SpawnFrom",
	"SpawnHeight",
	"HeightFrom",
	"RangeMode",
	"MinSpeed",
	"MaxSpeed",
	"WeaveDegrees",
	"WeaveFrequency",
	"WeavePlane",
	"WeaveMirrored",
	"ReturnAfterSeconds",
	"ReturnTurnRate",
	"HomingDelaySeconds",
	"HomingDurationSeconds",
	"LeadTarget",
	"RehitSeconds",
	"ProximityRadius",
	"FalloffStartStuds",
	"FalloffMinScale",
	"ExplodeOn",
	"ExplosionRadius",
	"ExplosionDamageScale",
	"ExplosionScope",
	"SplitOn",
	"SplitCount",
	"SplitPattern",
	"SplitAngle",
	"SplitSpeedScale",
	"SplitGenerations",
}

local function spec(overrides: { [string]: any }?): Spec
	local built = ProjectileTypes.Defaults() :: any
	for key, value in pairs(overrides or {}) do
		built[key] = value
	end
	return built :: Spec
end

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or EPSILON)
end

local function nearVector(a: Vector3, b: Vector3, tolerance: number?): boolean
	return (a - b).Magnitude <= (tolerance or EPSILON)
end

-- Degrees right of straight ahead (-Z).
local function yawOf(direction: Vector3): number
	return math.deg(math.atan2(direction.X, -direction.Z))
end

-- A projectile attack over the defaults (Projectile.spec's builder): no windup, a half-second active
-- window, no recovery.
local function projectileAttack(fields: { [string]: any }?, overrides: { [string]: any }?): HitboxTypes.AttackDefinition
	local projectile = ProjectileTypes.Defaults() :: any
	projectile.Speed = 100
	for key, value in pairs(fields or {}) do
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
		ActiveSeconds = 0.5,
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

local function run(clock: number, seconds: number): number
	for _ = 1, math.ceil(seconds / FRAME - 1e-6) do
		clock += FRAME
		HitboxEngine.Step(FRAME, clock)
	end
	return clock
end

-- `run`, with the defence layer's place in the frame: every contact on `target` is handed to `verdict`
-- AFTER the engine's step that reported it, as DefenseSystem's own CombatTick phase would.
local function runJudged(
	clock: number,
	seconds: number,
	target: Model,
	verdict: (contact: ProjectileTypes.ProjectileContact, at: number) -> ()
): number
	local queued: { HitReport } = {}
	local disconnect = HitboxEngine.OnHit(function(report: HitReport)
		local contact = report.Projectile
		if contact and not contact.Blast and report.Target == target then
			table.insert(queued, report)
		end
	end)
	for _ = 1, math.ceil(seconds / FRAME - 1e-6) do
		clock += FRAME
		HitboxEngine.Step(FRAME, clock)
		for _, report in queued do
			verdict(report.Projectile :: ProjectileTypes.ProjectileContact, report.SampleTime)
		end
		table.clear(queued)
	end
	disconnect()
	return clock
end

local function throw(attacker: Dummy, definition: HitboxTypes.AttackDefinition): number
	local accepted = HitboxEngine.RequestAttack(attacker.Id :: number, definition, 1, 0)
	assert(accepted, "the spec's attack was refused")
	return os.clock()
end

local function eventsOf(events: { ProjectileEvent }, kind: string): { ProjectileEvent }
	local found = {}
	for _, event in events do
		if event.Kind == kind then
			table.insert(found, event)
		end
	end
	return found
end

local function endReasons(events: { ProjectileEvent }): { string }
	local reasons = {}
	for _, event in eventsOf(events, "End") do
		table.insert(reasons, event.Reason :: string)
	end
	return reasons
end

local function hitsOn(hits: { HitReport }, model: Model, blast: boolean?): number
	local count = 0
	for _, hit in hits do
		local contact = hit.Projectile :: ProjectileTypes.ProjectileContact
		if hit.Target == model and (blast == nil or (contact.Blast == true) == blast) then
			count += 1
		end
	end
	return count
end

return function()
	afterEach(function()
		HitboxEngine.Reset()
		Rig.DestroyAll()
	end)

	describe("ProjectileTypes -- compatibility, budget and recipes", function()
		it("loads a record saved before the expansion with every new field at its default", function()
			local old = ProjectileTypes.Defaults() :: any
			for _, name in NEW_FIELDS do
				old[name] = nil
			end
			old.SpreadPattern = "Fan"
			old.Count = 5
			local loaded, reason = ProjectileTypes.Validate(old)
			expect(reason).to.equal(nil)
			local defaults = ProjectileTypes.Defaults() :: any
			for _, name in NEW_FIELDS do
				expect((loaded :: any)[name]).to.equal(defaults[name])
			end
			local budget = ProjectileTypes.Budget(loaded :: Spec)
			expect(budget.Waves).to.equal(1)
			expect(budget.Shots).to.equal(5)
			expect(budget.CastSeconds).to.equal(0)
			-- The global cap every shot was clamped to before MaxSpeed existed.
			expect(ProjectileMotion.MotionOf(loaded :: Spec).MaxSpeed).to.equal(ProjectileTypes.Limits.Speed.Max)
		end)

		it("names every new field in the schema exactly once", function()
			for _, name in NEW_FIELDS do
				local seen = 0
				for _, field in ProjectileTypes.Fields do
					if field.Name == name then
						seen += 1
					end
				end
				expect(seen).to.equal(1)
			end
		end)

		it("refuses a cast past its shot budget or its time budget, by name", function()
			local _, overShots = ProjectileTypes.Validate(spec({ SpreadPattern = "Fan", Count = 32, WaveCount = 12 }))
			expect(overShots).to.equal("ProjectileOverBudget")
			local _, overSplit =
				ProjectileTypes.Validate(spec({ SplitOn = "Always", SplitCount = 16, SplitGenerations = 2 }))
			expect(overSplit).to.equal("ProjectileOverBudget")
			local _, tooLong = ProjectileTypes.Validate(spec({ WaveCount = 12, WaveIntervalSeconds = 2 }))
			expect(tooLong).to.equal("ProjectileCastTooLong")
			local fine, none = ProjectileTypes.Validate(spec({ WaveCount = 4, WaveIntervalSeconds = 0.5 }))
			expect(none).to.equal(nil)
			expect(fine).to.be.ok()
		end)

		it("counts every split generation at its fullest", function()
			local budget = ProjectileTypes.Budget(spec({ SplitOn = "Impact", SplitCount = 3, SplitGenerations = 2 }))
			expect(budget.Shots).to.equal(1 + 3 + 9)
		end)

		it("normalises a min speed above the max rather than refusing it", function()
			local loaded = ProjectileTypes.Validate(spec({ MinSpeed = 300, MaxSpeed = 100 })) :: Spec
			expect(loaded.MinSpeed).to.equal(100)
		end)

		it("rejects an option that does not exist on a new enum", function()
			local _, reason = ProjectileTypes.Validate(spec({ ExplodeOn = "Sometimes" }))
			expect(reason).to.equal("InvalidProjectile")
		end)

		it("validates every recipe, inside its limits and caps, keeping the body and the parry", function()
			for _, recipe in ProjectileTypes.Recipes do
				expect(ProjectileTypes.RecipeById(recipe.Id)).to.equal(recipe)
				for name, value in recipe.Values do
					expect(ProjectileTypes.IsBehaviourField(name)).to.equal(true)
					local range = ProjectileTypes.Limits[name]
					if range and typeof(value) == "number" then
						expect(value >= range.Min and value <= range.Max).to.equal(true)
					end
				end
				local target = spec({ Shape = "Capsule", Size = 0.3, Length = 3.5, ParryResponse = "Reflect" })
				ProjectileTypes.ApplyRecipe(target, recipe)
				local loaded, reason = ProjectileTypes.Validate(target)
				expect(reason).to.equal(nil)
				for name, value in recipe.Values do
					expect(((loaded :: any) :: { [string]: any })[name]).to.equal(value)
				end
				expect(target.Shape).to.equal("Capsule")
				expect(target.Length).to.equal(3.5)
				expect(target.ParryResponse).to.equal("Reflect")
			end
		end)

		it("resets what an earlier recipe set when a later one is applied", function()
			local target = spec()
			ProjectileTypes.ApplyRecipe(target, ProjectileTypes.RecipeById("Spiral") :: ProjectileTypes.Recipe)
			expect(target.WaveCount).to.equal(8)
			ProjectileTypes.ApplyRecipe(target, ProjectileTypes.RecipeById("Bolt") :: ProjectileTypes.Recipe)
			expect(target.WaveCount).to.equal(1)
			expect(target.SpreadPattern).to.equal("Single")
		end)

		it("warns about settings that cannot take effect, and only the stagger note on the defaults", function()
			expect(#ProjectileTypes.Warnings(spec())).to.equal(1)
			local function warns(fields: { [string]: any }, fragment: string): boolean
				for _, note in ProjectileTypes.Warnings(spec(fields)) do
					if string.find(note, fragment, 1, true) then
						return true
					end
				end
				return false
			end
			expect(warns({ SpreadPattern = "Fan", Count = 3, ConvergeDistance = 20 }, "Converge has no effect")).to.equal(
				true
			)
			expect(warns({ ReturnAfterSeconds = 3, LifetimeSeconds = 2 }, "never comes back")).to.equal(true)
			expect(warns({ RehitSeconds = 0.5 }, "Re-hit needs Piercing")).to.equal(true)
			expect(warns({ SpreadPattern = "Circle", Count = 4 }, "zero radius")).to.equal(true)
			expect(warns({ ExplodeOn = "Impact", ExplosionScope = "SplitOnly" }, "no shot ever bursts")).to.equal(true)
		end)

		it("classifies end reasons into the triggers", function()
			expect(ProjectileTypes.Triggers("Impact", "Hit")).to.equal(true)
			expect(ProjectileTypes.Triggers("Impact", "Proximity")).to.equal(true)
			expect(ProjectileTypes.Triggers("Impact", "Range")).to.equal(false)
			expect(ProjectileTypes.Triggers("Expire", "Expired")).to.equal(true)
			expect(ProjectileTypes.Triggers("Always", "World")).to.equal(true)
			for _, reason in { "Parried", "Barrier", "Returned", "Owner" } do
				expect(ProjectileTypes.Triggers("Always", reason)).to.equal(false)
			end
			expect(ProjectileTypes.Triggers("Never", "Hit")).to.equal(false)
		end)
	end)

	describe("ProjectileMotion -- formations and waves", function()
		local aim = CFrame.identity

		it("lays a Grid out in centred rows, a short last row centred under the others", function()
			local shots =
				ProjectileMotion.Volley(spec({ SpreadPattern = "Grid", Count = 5, Columns = 3, Spacing = 2 }), aim)
			local expected = {
				Vector3.new(-2, 1, 0),
				Vector3.new(0, 1, 0),
				Vector3.new(2, 1, 0),
				Vector3.new(-1, -1, 0),
				Vector3.new(1, -1, 0),
			}
			expect(#shots).to.equal(5)
			for index, shot in shots do
				expect(nearVector(shot.Origin, expected[index])).to.equal(true)
				expect(nearVector(shot.Direction, Vector3.new(0, 0, -1))).to.equal(true)
			end
		end)

		it("puts a Circle on its radius, every shot flying parallel", function()
			local shots =
				ProjectileMotion.Volley(spec({ SpreadPattern = "Circle", Count = 4, FormationRadius = 3 }), aim)
			expect(#shots).to.equal(4)
			for _, shot in shots do
				expect(near(Vector3.new(shot.Origin.X, shot.Origin.Y, 0).Magnitude, 3)).to.equal(true)
				expect(near(shot.Origin.Z, 0)).to.equal(true)
				expect(nearVector(shot.Direction, Vector3.new(0, 0, -1))).to.equal(true)
			end
		end)

		it("starts a ring of emitters out along each shot's own heading", function()
			local shots = ProjectileMotion.Volley(
				spec({ SpreadPattern = "Fan", Count = 4, SpreadAngle = 360, FormationRadius = 4 }),
				aim
			)
			for _, shot in shots do
				expect(near(shot.Origin.Magnitude, 4)).to.equal(true)
				expect(nearVector(shot.Origin.Unit, shot.Direction)).to.equal(true)
			end
		end)

		it("converges every shot of a row through one point down the aim", function()
			local focus = Vector3.new(0, 0, -20)
			local shots = ProjectileMotion.Volley(
				spec({ SpreadPattern = "Horizontal", Count = 3, Spacing = 4, ConvergeDistance = 20 }),
				aim
			)
			for _, shot in shots do
				local toFocus = focus - shot.Origin
				expect(shot.Direction:Cross(toFocus.Unit).Magnitude < EPSILON).to.equal(true)
				expect(shot.Direction:Dot(toFocus) > 0).to.equal(true)
			end
		end)

		it("rolls each wave further round the aim -- the spiral", function()
			local rolled = spec({ SpreadPattern = "Circle", Count = 2, FormationRadius = 3, WaveRollDegrees = 90 })
			local first = ProjectileMotion.Volley(rolled, aim, 1)[1]
			local second = ProjectileMotion.Volley(rolled, aim, 2)[1]
			expect(nearVector(first.Origin, Vector3.new(3, 0, 0))).to.equal(true)
			expect(nearVector(second.Origin, Vector3.new(0, 3, 0))).to.equal(true)
		end)

		it("orders a cast's shots by fire time and mirrors every second wave", function()
			local cast = ProjectileMotion.Cast(
				spec({
					SpreadPattern = "Fan",
					Count = 2,
					WaveCount = 3,
					WaveIntervalSeconds = 0.2,
					ShotIntervalSeconds = 0.05,
					AlternateSides = true,
				}),
				CFrame.new(1, 0, 0),
				CFrame.new(-1, 0, 0)
			)
			local times = { 0, 0.05, 0.2, 0.25, 0.4, 0.45 }
			expect(#cast).to.equal(6)
			for index, shot in cast do
				expect(near(shot.At, times[index])).to.equal(true)
				expect(near(shot.Origin.X, if shot.Wave == 2 then -1 else 1)).to.equal(true)
			end
		end)

		it("mirrors an offset's right/left, yaw and roll, keeping up, forward and pitch", function()
			local offset = CFrame.new(1, 2, 3) * CFrame.Angles(0, math.rad(30), 0)
			local mirrored = ProjectileMotion.MirrorOffset(offset)
			expect(nearVector(mirrored.Position, Vector3.new(-1, 2, 3))).to.equal(true)
			local look, mirroredLook = offset.LookVector, mirrored.LookVector
			expect(nearVector(mirroredLook, Vector3.new(-look.X, look.Y, look.Z))).to.equal(true)
			expect(nearVector(mirrored.UpVector, offset.UpVector)).to.equal(true)
		end)
	end)

	describe("ProjectileMotion -- flight", function()
		it("raises a spawn along world up whatever its rotation, from the ground when it has one", function()
			local tilted = CFrame.new(1, 2, 3) * CFrame.Angles(math.rad(80), 0, 0)
			local raised = ProjectileMotion.Raise(spec({ SpawnHeight = 5 }), tilted)
			expect(nearVector(raised.Position, Vector3.new(1, 7, 3))).to.equal(true)
			expect(nearVector(raised.LookVector, tilted.LookVector)).to.equal(true)
			local grounded = ProjectileMotion.Raise(spec({ SpawnHeight = 5, HeightFrom = "Ground" }), tilted, -10)
			expect(near(grounded.Position.Y, -5)).to.equal(true)
			local noGround = ProjectileMotion.Raise(spec({ SpawnHeight = 5, HeightFrom = "Ground" }), tilted, nil)
			expect(near(noGround.Position.Y, 7)).to.equal(true)
		end)

		it("leads a moving target to where the shot meets it", function()
			local velocity = Vector3.new(10, 0, 0)
			local direction = ProjectileMotion.Intercept(Vector3.zero, Vector3.new(0, 0, -20), velocity, 40) :: Vector3
			expect(direction).to.be.ok()
			local t = -20 / (40 * direction.Z)
			expect(t > 0).to.equal(true)
			expect(near(direction.X * 40 * t, 10 * t, 1e-2)).to.equal(true)
			expect(ProjectileMotion.Intercept(Vector3.zero, Vector3.new(0, 0, -20), Vector3.new(0, 0, -50), 40)).to.equal(
				nil
			)
		end)

		it("weaves to the same heading at any step size", function()
			local motion = ProjectileMotion.MotionOf(spec({ WeaveDegrees = 30, WeaveFrequency = 1 }))
			local function headingAfter(steps: number): Vector3
				local position, velocity = Vector3.zero, Vector3.new(0, 0, -10)
				local dt = 0.25 / steps
				for step = 0, steps - 1 do
					position, velocity = ProjectileMotion.Integrate(position, velocity, motion, dt, nil, step * dt)
				end
				return velocity.Unit
			end
			local fine, coarse = headingAfter(60), headingAfter(3)
			-- A quarter period: the weave is at its full 30 degrees.
			expect(near(math.abs(yawOf(fine)), 30, 1e-2)).to.equal(true)
			expect(nearVector(fine, coarse, 1e-4)).to.equal(true)
		end)

		it("weaves the other way when mirrored, and up and down in the vertical plane", function()
			local plain = ProjectileMotion.MotionOf(spec({ WeaveDegrees = 20, WeaveFrequency = 1 }))
			local mirrored = ProjectileMotion.MotionOf(spec({ WeaveDegrees = 20, WeaveFrequency = 1 }), true)
			local vertical =
				ProjectileMotion.MotionOf(spec({ WeaveDegrees = 20, WeaveFrequency = 1, WeavePlane = "Vertical" }))
			local start = Vector3.new(0, 0, -10)
			local _, a = ProjectileMotion.Integrate(Vector3.zero, start, plain, 0.25, nil, 0)
			local _, b = ProjectileMotion.Integrate(Vector3.zero, start, mirrored, 0.25, nil, 0)
			local _, c = ProjectileMotion.Integrate(Vector3.zero, start, vertical, 0.25, nil, 0)
			expect(near(a.X, -b.X)).to.equal(true)
			expect(math.abs(a.X) > 1).to.equal(true)
			expect(math.abs(c.Y) > 1).to.equal(true)
			expect(near(c.X, 0)).to.equal(true)
		end)

		it("homes only inside its delay/duration window", function()
			local motion = ProjectileMotion.MotionOf(spec({
				Homing = true,
				HomingStrength = 360,
				HomingDelaySeconds = 0.5,
				HomingDurationSeconds = 0.2,
			}))
			local toward = Vector3.new(100, 0, 0)
			local start = Vector3.new(0, 0, -10)
			local _, before = ProjectileMotion.Integrate(Vector3.zero, start, motion, 0.1, toward, 0.1)
			local _, during = ProjectileMotion.Integrate(Vector3.zero, start, motion, 0.1, toward, 0.6)
			local _, after = ProjectileMotion.Integrate(Vector3.zero, start, motion, 0.1, toward, 0.8)
			expect(near(before.X, 0)).to.equal(true)
			expect(during.X > 1).to.equal(true)
			expect(near(after.X, 0)).to.equal(true)
		end)

		it("keeps a decelerating shot at its min speed", function()
			local motion = ProjectileMotion.MotionOf(spec({ Acceleration = -100, MinSpeed = 15 }))
			local _, velocity = ProjectileMotion.Integrate(Vector3.zero, Vector3.new(0, 0, -20), motion, 1, nil, 0)
			expect(near(velocity.Magnitude, 15)).to.equal(true)
		end)

		it("falls damage off linearly from its start to max range", function()
			local falling = spec({ MaxRange = 100, FalloffStartStuds = 20, FalloffMinScale = 0.5 })
			expect(ProjectileMotion.Falloff(falling, 10)).to.equal(1)
			expect(near(ProjectileMotion.Falloff(falling, 60), 0.75)).to.equal(true)
			expect(near(ProjectileMotion.Falloff(falling, 100), 0.5)).to.equal(true)
			expect(ProjectileMotion.Falloff(spec({ MaxRange = 100, FalloffStartStuds = 20 }), 90)).to.equal(1)
		end)

		it("draws a returning shot's path back toward where it started", function()
			local returning = spec({ Speed = 40, LifetimeSeconds = 3, ReturnAfterSeconds = 0.4, ReturnTurnRate = 1080 })
			local points =
				ProjectileMotion.Path(returning, { Origin = Vector3.zero, Direction = Vector3.new(0, 0, -1) }, 1000, 60)
			local farthest = 0
			for _, point in points do
				farthest = math.max(farthest, point.Magnitude)
			end
			expect(farthest > 10).to.equal(true)
			expect(points[#points].Magnitude < farthest / 2).to.equal(true)
		end)
	end)

	describe("HitboxEngine -- waves", function()
		it("fires every wave as one cast, one GroupId, on its interval", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			local clock =
				throw(attacker, projectileAttack({ WaveCount = 3, WaveIntervalSeconds = 0.1, LifetimeSeconds = 2 }))
			clock = run(clock, 0.05)
			expect(#eventsOf(events, "Launch")).to.equal(1)
			clock = run(clock, 0.1)
			expect(#eventsOf(events, "Launch")).to.equal(2)
			run(clock, 0.15)
			disconnect()
			local launches = eventsOf(events, "Launch")
			expect(#launches).to.equal(3)
			for _, launch in launches do
				expect(launch.GroupId).to.equal(launches[1].GroupId)
			end
		end)

		it("fires no more waves once the swing is interrupted", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			local clock = run(throw(attacker, projectileAttack({ WaveCount = 4, WaveIntervalSeconds = 0.2 })), FRAME)
			expect(ProjectileSimulator.PendingCount()).to.equal(3)
			HitboxEngine.CancelAttack(attacker.Id :: number, "SpecInterrupt", clock)
			expect(ProjectileSimulator.PendingCount()).to.equal(0)
			run(clock, 1)
			disconnect()
			expect(#eventsOf(events, "Launch")).to.equal(1)
		end)

		it("fires the rest of the waves after a swing that completes", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack(
						{ WaveCount = 3, WaveIntervalSeconds = 0.2, LifetimeSeconds = 2 },
						{ ActiveSeconds = 0.05 }
					)
				),
				0.6
			)
			disconnect()
			expect(#eventsOf(events, "Launch")).to.equal(3)
		end)

		it("staggers the shots of one wave", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			local clock = run(
				throw(attacker, projectileAttack({ SpreadPattern = "Fan", Count = 3, ShotIntervalSeconds = 0.1 })),
				FRAME
			)
			expect(#eventsOf(events, "Launch")).to.equal(1)
			run(clock, 0.3)
			disconnect()
			expect(#eventsOf(events, "Launch")).to.equal(3)
		end)

		it("fires every second wave from the mirrored spawn", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack(
						{ WaveCount = 2, WaveIntervalSeconds = 0.05, AlternateSides = true },
						{ Offset = CFrame.new(2, 0, -2) }
					)
				),
				0.15
			)
			disconnect()
			local launches = eventsOf(events, "Launch")
			expect(#launches).to.equal(2)
			expect(near(launches[1].Position.X, 2, 0.05)).to.equal(true)
			expect(near(launches[2].Position.X, -2, 0.05)).to.equal(true)
		end)

		it("drops a dead thrower's waves", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			local clock = run(throw(attacker, projectileAttack({ WaveCount = 3, WaveIntervalSeconds = 0.1 })), FRAME)
			attacker.Humanoid.Health = 0
			run(clock, 0.5)
			disconnect()
			expect(#eventsOf(events, "Launch")).to.equal(1)
			expect(ProjectileSimulator.PendingCount()).to.equal(0)
		end)
	end)

	describe("HitboxEngine -- range, return, re-hits and fuses", function()
		it("measures a Displacement range as the straight distance from the spawn", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(throw(attacker, projectileAttack({ RangeMode = "Displacement", MaxRange = 10 })), 0.3)
			disconnect()
			local ended = eventsOf(events, "End")[1]
			expect(ended.Reason).to.equal("Range")
			expect(near((ended.Position - Vector3.new(0, 5, -2)).Magnitude, 10, 0.05)).to.equal(true)
		end)

		it("comes back to its thrower, striking on the way out and on the way back", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -8))
			local hits, disconnectHits = captureHits()
			local events, disconnectEvents = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack({
						Speed = 60,
						Size = 3,
						LifetimeSeconds = 3,
						ReturnAfterSeconds = 0.3,
						ReturnTurnRate = 1440,
						Piercing = true,
						MaxPierces = 4,
						CollisionBehavior = "Continue",
					})
				),
				1.5
			)
			disconnectHits()
			disconnectEvents()
			expect(hitsOn(hits, target.Model)).to.equal(2)
			expect(hitsOn(hits, attacker.Model)).to.equal(0)
			expect(table.find(endReasons(events), "Returned")).to.be.ok()
			local turned = false
			for _, update in eventsOf(events, "Update") do
				if update.Reason == "Return" then
					turned = true
					expect(update.Motion).to.be.ok()
				end
			end
			expect(turned).to.equal(true)
		end)

		it("strikes a body again only after its re-hit time", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -4))
			local hits, disconnect = captureHits()
			local lingering =
				{ Speed = 3, Size = 2, LifetimeSeconds = 1, Piercing = true, MaxPierces = 20, RehitSeconds = 0.2 }
			run(throw(attacker, projectileAttack(lingering)), 1.1)
			disconnect()
			expect(hitsOn(hits, target.Model) >= 3).to.equal(true)

			HitboxEngine.Reset()
			local again = spawnDummy("Attacker2", Vector3.new(0, 5, 0))
			local secondTarget = spawnDummy("Target2", Vector3.new(0, 5, -4))
			local onceHits, disconnectOnce = captureHits()
			run(
				throw(
					again,
					projectileAttack({ Speed = 3, Size = 2, LifetimeSeconds = 1, Piercing = true, MaxPierces = 20 })
				),
				1.1
			)
			disconnectOnce()
			expect(hitsOn(onceHits, secondTarget.Model)).to.equal(1)
		end)

		it("ends on its proximity fuse before it touches anybody", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			spawnDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnectHits = captureHits()
			local events, disconnectEvents = captureEvents()
			run(throw(attacker, projectileAttack({ ProximityRadius = 6 })), 0.4)
			disconnectHits()
			disconnectEvents()
			expect(#hits).to.equal(0)
			local ended = eventsOf(events, "End")[1]
			expect(ended.Reason).to.equal("Proximity")
			expect(ended.Position.Z > -16).to.equal(true)
		end)

		it("prices a contact by how far the shot had flown", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			spawnDummy("Target", Vector3.new(0, 5, -30))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ MaxRange = 40, FalloffStartStuds = 0, FalloffMinScale = 0.5 })), 0.5)
			disconnect()
			expect(#hits).to.equal(1)
			local scale = (hits[1].Projectile :: ProjectileTypes.ProjectileContact).DamageScale
			expect(scale < 0.75 and scale > 0.6).to.equal(true)
		end)

		it("lifts the spawn along world up by its spawn height", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(throw(attacker, projectileAttack({ SpawnHeight = 10 })), FRAME)
			disconnect()
			local launch = eventsOf(events, "Launch")[1]
			expect(nearVector(launch.Position, Vector3.new(0, 15, -2), 0.05)).to.equal(true)
			-- Only the spawn moves: it still flies where the body faces.
			expect(nearVector(launch.Velocity.Unit, Vector3.new(0, 0, -1))).to.equal(true)
		end)

		it("measures a Ground spawn height from the floor under the spawn point", function()
			local floor = Instance.new("Part")
			floor.Name = "SpecFloor"
			floor.Size = Vector3.new(100, 1, 100)
			floor.Anchored = true
			floor.CanCollide = true
			floor.CFrame = CFrame.new(0, 0, 0)
			floor.Parent = Workspace
			Rig.Track(floor)
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(throw(attacker, projectileAttack({ HeightFrom = "Ground", SpawnHeight = 1 })), FRAME)
			disconnect()
			local launch = eventsOf(events, "Launch")[1]
			-- The floor's top is at y = 0.5.
			expect(near(launch.Position.Y, 1.5, 0.05)).to.equal(true)
		end)

		it("spawns above a target and fires down onto it", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnectHits = captureHits()
			local events, disconnectEvents = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack(
						{ SpawnFrom = "Target", SpawnDirection = "Target", HomingRange = 60, HomingMaxAngle = 60 },
						{ Offset = CFrame.new(0, 20, 0) }
					)
				),
				0.5
			)
			disconnectHits()
			disconnectEvents()
			local launch = eventsOf(events, "Launch")[1]
			expect(nearVector(launch.Position, Vector3.new(0, 25, -20), 0.05)).to.equal(true)
			expect(launch.Velocity.Unit.Y < -0.99).to.equal(true)
			expect(hitsOn(hits, target.Model)).to.equal(1)
		end)
	end)

	describe("HitboxEngine -- end effects", function()
		local bursting = { ExplodeOn = "Impact", ExplosionRadius = 8, ExplosionDamageScale = 0.5 }

		it("bursts on impact the frame after, striking bystanders once and the direct target not again", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -20))
			local bystander = spawnDummy("Bystander", Vector3.new(4, 5, -20))
			local faraway = spawnDummy("Faraway", Vector3.new(40, 5, -20))
			local hits, disconnectHits = captureHits()
			local events, disconnectEvents = captureEvents()
			run(throw(attacker, projectileAttack(bursting)), 0.5)
			disconnectHits()
			disconnectEvents()

			expect(hitsOn(hits, target.Model)).to.equal(1)
			expect(hitsOn(hits, target.Model, true)).to.equal(0)
			expect(hitsOn(hits, bystander.Model, true)).to.equal(1)
			expect(hitsOn(hits, faraway.Model)).to.equal(0)
			for _, hit in hits do
				local contact = hit.Projectile :: ProjectileTypes.ProjectileContact
				if contact.Blast then
					expect(contact.Parryable).to.equal(false)
					expect(contact.StaggersOwner).to.equal(false)
					expect(near(contact.DamageScale, 0.5, 0.01)).to.equal(true)
				end
			end
			-- The direct contact strictly before the blast: the burst waited for the next frame.
			expect(hits[1].Target).to.equal(target.Model)
			expect(hits[2].SampleTime >= hits[1].SampleTime).to.equal(true)
			local ended = eventsOf(events, "End")
			expect(#ended).to.equal(1)
			expect(ended[1].Reason).to.equal("Hit")
			expect(ended[1].Burst).to.equal(8)
		end)

		it("does not burst a shot the defence layer let pass (an evade)", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -20))
			local bystander = spawnDummy("Bystander", Vector3.new(4, 5, -20))
			local hits, disconnectHits = captureHits()
			runJudged(throw(attacker, projectileAttack(bursting)), 0.6, target.Model, function(contact, at)
				HitboxEngine.PassProjectile(contact.Id, target.Model, at)
			end)
			disconnectHits()
			expect(hitsOn(hits, target.Model)).to.equal(1)
			expect(hitsOn(hits, bystander.Model, true)).to.equal(0)
		end)

		it("defuses a shot a Destroy parry ended, before its burst", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -20))
			local bystander = spawnDummy("Bystander", Vector3.new(4, 5, -20))
			local hits, disconnectHits = captureHits()
			local events, disconnectEvents = captureEvents()
			local destroyed = table.clone(bursting) :: { [string]: any }
			destroyed.ParryResponse = "Destroy"
			runJudged(throw(attacker, projectileAttack(destroyed)), 0.6, target.Model, function(contact, at)
				HitboxEngine.ParryProjectile(contact.Id, target.Model, at)
			end)
			disconnectHits()
			disconnectEvents()
			expect(hitsOn(hits, bystander.Model, true)).to.equal(0)
			expect(endReasons(events)[1]).to.equal("Parried")
		end)

		it("splits when its range runs out, every child one generation on and in the same cast", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack({
						MaxRange = 10,
						SplitOn = "Expire",
						SplitCount = 3,
						SplitPattern = "Fan",
						SplitAngle = 60,
					})
				),
				0.6
			)
			disconnect()
			local launches = eventsOf(events, "Launch")
			expect(#launches).to.equal(4)
			for _, launch in launches do
				expect(launch.GroupId).to.equal(launches[1].GroupId)
			end
			for index = 2, 4 do
				local state = ProjectileSimulator.Inspect(launches[index].Id)
				if state then
					expect(state.Generation).to.equal(1)
				end
			end
			-- The children start where the parent's range ran out.
			expect(near((launches[2].Position - Vector3.new(0, 5, -2)).Magnitude, 10, 0.1)).to.equal(true)
		end)

		it("never lets a split child strike the body its parent just struck", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local target = spawnDummy("Target", Vector3.new(0, 5, -20))
			local hits, disconnect = captureHits()
			run(throw(attacker, projectileAttack({ SplitOn = "Impact", SplitCount = 3, SplitAngle = 0 })), 0.6)
			disconnect()
			expect(hitsOn(hits, target.Model)).to.equal(1)
		end)

		it("stops splitting at its generation limit", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack({
						MaxRange = 4,
						SplitOn = "Always",
						SplitCount = 2,
						SplitGenerations = 3,
						SplitAngle = 90,
					})
				),
				1
			)
			disconnect()
			expect(#eventsOf(events, "Launch")).to.equal(1 + 2 + 4 + 8)
			expect(ProjectileSimulator.LiveCount()).to.equal(0)
		end)

		it("bursts only the split shots of a cluster bomb", function()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0))
			local events, disconnect = captureEvents()
			run(
				throw(
					attacker,
					projectileAttack({
						MaxRange = 5,
						SplitOn = "Expire",
						SplitCount = 2,
						SplitAngle = 90,
						ExplodeOn = "Always",
						ExplosionScope = "SplitOnly",
					})
				),
				0.8
			)
			disconnect()
			local bursts = 0
			for _, ended in eventsOf(events, "End") do
				if ended.Burst ~= nil then
					bursts += 1
				end
			end
			expect(bursts).to.equal(2)
		end)
	end)
end
