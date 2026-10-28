--!strict
-- Covers the ragdoll end to end: the authored block (Shared/Ragdoll/RagdollTypes), the pure decisions
-- (Shared/Ragdoll/RagdollRules), the runtime on a real R6 rig (Server/Combat/Ragdoll/RagdollSystem + RagdollRig),
-- and a ragdolling move landing through the REAL engine, defence and damage layers.
--
-- Time is driven through Step(now); Init is never called (Attach exists so a spec can subscribe without a
-- Heartbeat). Physics does not run in the test place, so the cases assert what the system WRITES -- motors,
-- sockets, Attributes, claims, phases and the throw -- not where a body falls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local BodyRestraint = require(ReplicatedStorage.Shared.Combat.BodyRestraint)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local GrabSystem = require(ServerScriptService.Server.Combat.Grab.GrabSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local RagdollConstants = require(ReplicatedStorage.Shared.Ragdoll.RagdollConstants)
local RagdollRules = require(ReplicatedStorage.Shared.Ragdoll.RagdollRules)
local RagdollSystem = require(ServerScriptService.Server.Combat.Ragdoll.RagdollSystem)
local RagdollTypes = require(ReplicatedStorage.Shared.Ragdoll.RagdollTypes)
local RootControl = require(ServerScriptService.Server.Combat.RootControl)
local CombatHarness = require(ServerScriptService.Tests.TestHelpers.CombatHarness)
local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

local WEAPON = WeaponFixture.Install()[1]
local MOVE_ID = `default:{WEAPON}:Basic:1`
local FRAME = 1 / 60

local spawnR6 = CombatHarness.Spawner({ R6 = true })

local function spec(overrides: { [string]: any }?): RagdollTypes.RagdollSpec
	local value = RagdollTypes.Defaults()
	for key, field in overrides or {} do
		(value :: any)[key] = field
	end
	return value
end

local function contact(kind: string, lethal: boolean?, airborne: boolean?): RagdollRules.Contact
	return { Kind = kind, Lethal = lethal == true, Airborne = airborne == true }
end

local function motorsEnabled(model: Model): (number, number)
	local on, off = 0, 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Name ~= "RootJoint" then
			if descendant.Enabled then
				on += 1
			else
				off += 1
			end
		end
	end
	return on, off
end

local function enabledSockets(model: Model): number
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BallSocketConstraint") and descendant.Enabled then
			count += 1
		end
	end
	return count
end

return function()
	afterEach(function()
		CombatHarness.Reset()
		MoveRegistryManager.Init()
		Rig.DestroyAll()
	end)

	describe("RagdollTypes", function()
		it("seeds every field at its default and validates its own defaults unchanged", function()
			local defaults = RagdollTypes.Defaults()
			local validated = RagdollTypes.Validate(defaults)
			expect(validated).to.be.ok()
			for _, field in RagdollTypes.Fields do
				expect((validated :: any)[field.Name]).to.equal(field.Default)
			end
		end)

		it("clamps numbers, fills absent fields and raises a ceiling below the floor", function()
			local validated =
				RagdollTypes.Validate({ Push = 9999, Lift = -9999, DurationSeconds = 4, MaxSeconds = 1 }) :: any
			expect(validated.Push).to.equal(RagdollTypes.Limits.Push.Max)
			expect(validated.Lift).to.equal(RagdollTypes.Limits.Lift.Min)
			expect(validated.MaxSeconds).to.equal(4)
			expect(validated.Tumble).to.equal(RagdollTypes.Defaults().Tumble)
		end)

		it("rejects a trigger that does not exist, a wrong type and NaN", function()
			for _, bad in { { Trigger = "Sometimes" }, { RecoverOnSettle = 1 }, { Push = 0 / 0 }, { Push = "fast" }, 7 } do
				local validated, reason = RagdollTypes.Validate(bad)
				expect(validated).to.equal(nil)
				expect(reason).to.equal("InvalidRagdoll")
			end
		end)

		it("copies only schema fields", function()
			local source = spec() :: any
			source.Junk = true
			expect((RagdollTypes.Copy(source) :: any).Junk).to.equal(nil)
		end)

		it("applies a preset's values and leaves the rest", function()
			local value = spec({ Bounce = 0.77 })
			RagdollTypes.ApplyPreset(value, RagdollTypes.PresetById("Slam") :: any)
			expect(value.Lift).to.equal(-80)
			expect(value.Trigger).to.equal("Hit")
			expect(value.Bounce).to.equal(0.3)
			local execution = spec()
			RagdollTypes.ApplyPreset(execution, RagdollTypes.PresetById("Execution") :: any)
			expect(execution.Trigger).to.equal("Lethal")
			expect(execution.Friction).to.equal(RagdollTypes.Defaults().Friction)
		end)

		it("round-trips through the move's wire encoding and refuses a ragdoll beside a launcher", function()
			local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
			move.Ragdoll = spec({ Push = 12 })
			local wire = MoveTypes.ToWire(move)
			expect(wire.Ragdoll.Push).to.equal(12)
			wire.Author, wire.CreatedAt, wire.UpdatedAt = "Spec", 0, 0
			local validated = MoveRegistryManager.Validate(wire)
			expect(validated).to.be.ok()
			expect((validated :: any).Ragdoll.Push).to.equal(12)

			local launcher = table.clone(wire)
			launcher.Knockback = { UpVelocity = 10, HorizontalVelocity = 10, StartsAirCombo = true }
			local _, launcherReason = MoveRegistryManager.Validate(launcher)
			expect(launcherReason).to.equal("LauncherCannotRagdoll")
		end)
	end)

	describe("RagdollRules", function()
		it("fires each trigger on exactly its contacts", function()
			expect(RagdollRules.Triggers(spec({ Trigger = "Hit" }), contact("Clean"))).to.equal(true)
			expect(RagdollRules.Triggers(spec({ Trigger = "Hit" }), contact("Blocked"))).to.equal(false)
			expect(RagdollRules.Triggers(spec({ Trigger = "Lethal" }), contact("Clean"))).to.equal(false)
			expect(RagdollRules.Triggers(spec({ Trigger = "Lethal" }), contact("Clean", true))).to.equal(true)
			expect(RagdollRules.Triggers(spec({ Trigger = "Airborne" }), contact("Clean", false, true))).to.equal(true)
			expect(RagdollRules.Triggers(spec({ Trigger = "GuardBreak" }), contact("Clean"))).to.equal(false)
			expect(RagdollRules.Triggers(spec({ Trigger = "GuardBreak" }), contact("GuardBroken"))).to.equal(true)
			expect(RagdollRules.Triggers(spec({ Trigger = "Backstab" }), contact("Backstab"))).to.equal(true)
			expect(RagdollRules.Triggers(spec({ Trigger = "Hit" }), contact("Parried", true))).to.equal(false)
		end)

		it("refuses an immune body and a chain past its cap, but never a killing blow", function()
			local humanoid = Rig.Dummy("Admits").Humanoid
			local now = 100
			expect(RagdollRules.Admits(humanoid, now)).to.equal(true)

			humanoid:SetAttribute(AttributeConstants.RagdollImmuneUntil, now + 1)
			local admitted, reason = RagdollRules.Admits(humanoid, now)
			expect(admitted).to.equal(false)
			expect(reason).to.equal("Immune")
			expect(RagdollRules.Resolve(spec(), contact("Clean"), humanoid, now)).to.equal(nil)
			expect(RagdollRules.Resolve(spec(), contact("Clean", true), humanoid, now)).to.be.ok()

			humanoid:SetAttribute(AttributeConstants.RagdollImmuneUntil, nil)
			humanoid:SetAttribute(AttributeConstants.Ragdolled, true)
			humanoid:SetAttribute(AttributeConstants.RagdollChainEndsAt, now + 1)
			expect(RagdollRules.Admits(humanoid, now)).to.equal(true)
			local chained, chainReason = RagdollRules.Admits(humanoid, now + 2)
			expect(chained).to.equal(false)
			expect(chainReason).to.equal("Chained")
		end)

		it("falls back to the death spec only on a lethal landed hit", function()
			local humanoid = Rig.Dummy("Death").Humanoid
			expect(RagdollRules.Resolve(nil, contact("Clean"), humanoid, 0)).to.equal(nil)
			local resolved = RagdollRules.Resolve(nil, contact("Clean", true), humanoid, 0)
			if RagdollConstants.Death.Enabled then
				expect(resolved).to.equal(RagdollConstants.Death.Spec)
			else
				expect(resolved).to.equal(nil)
			end
			expect(RagdollRules.Resolve(nil, contact("Blocked", true), humanoid, 0)).to.equal(nil)
		end)

		it("throws away from the hit with a backflip, and clamps the throw", function()
			local linear, angular =
				RagdollRules.Impulse(spec({ Push = 40, Lift = 10, Tumble = 5, Twist = 0 }), Vector3.new(0, 0, 3), nil)
			expect(linear.Z).to.be.near(40, 1e-4)
			expect(linear.Y).to.be.near(10, 1e-4)
			-- The top of the body (+Y from the centre) moves along the throw: a backflip for a defender facing the hit.
			expect(angular:Cross(Vector3.yAxis).Z > 0).to.equal(true)

			local fast = RagdollRules.Impulse(
				spec({ Push = 220, Lift = 160, KnockbackScale = 3 }),
				Vector3.xAxis,
				Vector3.new(500, 0, 0)
			)
			expect(fast.Magnitude <= RagdollConstants.Limits.MaxLinearSpeed + 1e-3).to.equal(true)
		end)

		it("carries the move's launch by KnockbackScale", function()
			local linear = RagdollRules.Impulse(
				spec({ Push = 0, Lift = 0, KnockbackScale = 0.5 }),
				Vector3.zero,
				Vector3.new(0, 20, 40)
			)
			expect(linear.Y).to.be.near(10, 1e-4)
			expect(linear.Z).to.be.near(20, 1e-4)
		end)

		it("narrows joints and raises friction with stiffness, and tightens toward the final angle", function()
			local class = RagdollRules.JointClassOf("Left Shoulder")
			local limp = RagdollRules.JointLimits(class, 0)
			local stiff = RagdollRules.JointLimits(class, 1)
			expect(limp).to.equal(class.UpperAngle)
			expect(stiff < limp).to.equal(true)
			expect(RagdollRules.FrictionTorque(1) > RagdollRules.FrictionTorque(0)).to.equal(true)
			expect(RagdollRules.TightenedAngle(-80, 1)).to.equal(-RagdollConstants.Recovery.FinalAngleDegrees)
			expect(RagdollRules.TightenedAngle(80, 0)).to.equal(80)
		end)
	end)

	describe("RagdollSystem on an R6 body", function()
		it("takes the body limp, claims it, and hands it back standing where it stood", function()
			local body = Rig.R6("Ragdolled", Vector3.new(0, 10, 0))
			local home = body.Root.CFrame
			local now = 50
			local value = spec({ DurationSeconds = 0.5, RecoverOnSettle = false, GetUpSeconds = 0.2 })

			expect(RagdollSystem.Begin(body.Model, value, Vector3.new(0, 10, 30), Vector3.xAxis, false, now)).to.equal(
				true
			)
			local on, off = motorsEnabled(body.Model)
			expect(on).to.equal(0)
			expect(off > 0).to.equal(true)
			expect(enabledSockets(body.Model)).to.equal(off)
			expect(body.Humanoid:GetAttribute(AttributeConstants.Ragdolled)).to.equal(true)
			expect(body.Humanoid.PlatformStand).to.equal(true)
			expect(body.Humanoid.RequiresNeck).to.equal(false)
			expect(RootControl.IsClaimed(body.Humanoid, RootControl.Owners.Ragdoll)).to.equal(true)
			expect(body.Root.Anchored).to.equal(false)
			expect(BodyRestraint.Refusal(body.Humanoid, "Swing")).to.equal("Ragdolled")
			expect(BodyRestraint.Refusal(body.Humanoid, "Evade")).to.equal("Ragdolled")

			RagdollSystem.Step(now + 0.25)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("Limp")
			RagdollSystem.Step(now + 0.5)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("GettingUp")
			RagdollSystem.Step(now + 0.75)
			expect(RagdollSystem.IsRagdolled(body.Model)).to.equal(false)

			on, off = motorsEnabled(body.Model)
			expect(off).to.equal(0)
			expect(on > 0).to.equal(true)
			expect(enabledSockets(body.Model)).to.equal(0)
			expect(body.Humanoid:GetAttribute(AttributeConstants.Ragdolled)).to.equal(nil)
			expect(body.Humanoid:GetAttribute(AttributeConstants.RagdollImmuneUntil)).to.be.near(
				now + 0.75 + RagdollConstants.Rules.ImmunitySeconds,
				1e-6
			)
			expect(body.Humanoid.PlatformStand).to.equal(false)
			expect(RootControl.IsClaimed(body.Humanoid)).to.equal(false)
			expect(body.Root.Anchored).to.equal(true)
			if RagdollConstants.Recovery.ReturnAnchoredHome then
				expect((body.Root.Position - home.Position).Magnitude < 1e-3).to.equal(true)
			end
		end)

		it("waits for rest when asked to, and gets up at MaxSeconds if it never comes", function()
			local body = Rig.R6("Settling", Vector3.new(10, 10, 0))
			local now = 10
			RagdollSystem.Begin(
				body.Model,
				spec({ DurationSeconds = 0.5, MaxSeconds = 2, RecoverOnSettle = true }),
				Vector3.zero,
				Vector3.zero,
				false,
				now
			)
			-- The body is never at rest while a spinning velocity is written every poll.
			for t = now + 0.5, now + 1.9, 0.05 do
				body.Root.AssemblyAngularVelocity = Vector3.new(0, 20, 0)
				RagdollSystem.Step(t)
				expect(RagdollSystem.PhaseOf(body.Model)).to.equal("Limp")
			end
			RagdollSystem.Step(now + 2)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("GettingUp")
		end)

		it("refreshes a limp body without moving its chain cap, and abandons a get-up to do it", function()
			local body = Rig.R6("Refreshed", Vector3.new(20, 10, 0))
			local now = 5
			local value = spec({ DurationSeconds = 0.4, RecoverOnSettle = false })
			RagdollSystem.Begin(body.Model, value, Vector3.zero, Vector3.zero, false, now)
			local cap = body.Humanoid:GetAttribute(AttributeConstants.RagdollChainEndsAt)
			RagdollSystem.Step(now + 0.4)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("GettingUp")

			RagdollSystem.Begin(body.Model, value, Vector3.new(0, 30, 0), Vector3.zero, false, now + 0.45)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("Limp")
			expect(body.Humanoid:GetAttribute(AttributeConstants.RagdollChainEndsAt)).to.equal(cap)
			RagdollSystem.Step(now + 0.6)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("Limp")
		end)

		it("never gets a killing blow's corpse up", function()
			local body = Rig.R6("Corpse", Vector3.new(30, 10, 0))
			RagdollSystem.Begin(
				body.Model,
				spec({ DurationSeconds = 0.2, RecoverOnSettle = false }),
				Vector3.zero,
				Vector3.zero,
				true,
				0
			)
			RagdollSystem.Step(5)
			expect(RagdollSystem.PhaseOf(body.Model)).to.equal("Corpse")
			expect(body.Humanoid.BreakJointsOnDeath).to.equal(false)
		end)

		it("throws every part with the body's spin about the root", function()
			local body = Rig.R6("Thrown", Vector3.new(40, 10, 0))
			RagdollSystem.Begin(body.Model, spec(), Vector3.new(0, 0, 25), Vector3.new(4, 0, 0), false, 0)
			expect((body.Root.AssemblyLinearVelocity - Vector3.new(0, 0, 25)).Magnitude < 1e-3).to.equal(true)
			local head = body.Model:FindFirstChild("Head") :: BasePart
			local expected = Vector3.new(0, 0, 25) + Vector3.new(4, 0, 0):Cross(head.Position - body.Root.Position)
			expect((head.AssemblyLinearVelocity - expected).Magnitude < 1e-2).to.equal(true)
		end)
	end)

	describe("a ragdolling move landing through the combat stack", function()
		local function grabDefinition(): HitboxTypes.AttackDefinition
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

		local function hit(fields: { [string]: any }?): (CombatHarness.Dummy, { [string]: any })
			local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
			for key, value in fields or {} do
				(move :: any)[key] = value
			end
			MoveRegistryManager.Upsert(move)

			DefenseSystem.Attach()
			DamageSystem.Attach()
			RagdollSystem.Attach()
			local seen: { [string]: any } = {}
			local disconnect = DamageSystem.OnApplied(function(_outcome, result)
				seen.Ragdoll = result.Ragdoll
				seen.Launch = result.Launch
			end)
			local base = os.clock()
			local attacker = spawnR6("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnR6("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local definition = grabDefinition()
			HitboxEngine.RequestAttack(attacker.Id :: number, definition, 1, 1)
			HitboxEngine.Step(FRAME, base + FRAME)
			DefenseSystem.Step(FRAME, base + FRAME)
			DamageSystem.Step(FRAME, base + FRAME)
			disconnect()
			return defender, seen
		end

		it("ragdolls the defender when the move carries the block", function()
			local defender, seen = hit({ Ragdoll = spec() })
			expect(seen.Ragdoll).to.be.ok()
			expect(RagdollSystem.IsRagdolled(defender.Model)).to.equal(true)
			expect(defender.Humanoid:GetAttribute(AttributeConstants.Ragdolled)).to.equal(true)
		end)

		it("does nothing new for a move without one that does not kill", function()
			local defender, seen = hit(nil)
			expect(seen.Ragdoll).to.equal(nil)
			expect(RagdollSystem.IsRagdolled(defender.Model)).to.equal(false)
		end)

		it("never ragdolls a grab hit, and ragdolls the body on the throw instead", function()
			local grab: MoveTypes.MoveGrabConfig = {
				HoldSeconds = 2,
				ThrowUpVelocity = 10,
				ThrowHorizontalVelocity = 20,
				ThrowImpactDamage = 0,
				ThrowSelfDamage = 0,
			}
			GrabSystem.Attach()
			local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
			move.Grab = grab
			move.Ragdoll = spec({ KnockbackScale = 1, Push = 0, Lift = 0, Tumble = 0 })
			MoveRegistryManager.Upsert(move)
			DefenseSystem.Attach()
			DamageSystem.Attach()
			RagdollSystem.Attach()

			local base = os.clock()
			local attacker = spawnR6("Thrower", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnR6("Thrown", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)
			HitboxEngine.RequestAttack(attacker.Id :: number, grabDefinition(), 1, 1)
			HitboxEngine.Step(FRAME, base + FRAME)
			DefenseSystem.Step(FRAME, base + FRAME)
			DamageSystem.Step(FRAME, base + FRAME)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(true)
			expect(RagdollSystem.IsRagdolled(defender.Model)).to.equal(false)

			expect(GrabSystem.Throw(attacker.Model, base + 2 * FRAME)).to.equal(true)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(true)
			expect(RagdollSystem.IsRagdolled(defender.Model)).to.equal(true)
			-- The throw's own velocity is the launch the ragdoll carried (KnockbackScale 1, nothing added).
			expect(defender.Root.AssemblyLinearVelocity.Y).to.be.near(10, 1e-3)

			-- The flight ends (its safety timeout here; physics does not run), and leaves the limp body to the ragdoll.
			GrabSystem.Step(FRAME, base + 60)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(false)
			expect(defender.Humanoid:GetAttribute(AttributeConstants.Grabbed)).to.equal(nil)
			expect(defender.Humanoid.PlatformStand).to.equal(true)
			expect(RootControl.IsClaimed(defender.Humanoid, RootControl.Owners.Ragdoll)).to.equal(true)
			expect(RootControl.IsClaimed(defender.Humanoid, RootControl.Owners.GrabVictim)).to.equal(false)
		end)

		it("leaves a defender standing when the move only ragdolls the blow that kills", function()
			local defender, seen = hit({ Ragdoll = spec({ Trigger = "Lethal" }) })
			expect(seen.Ragdoll).to.equal(nil)
			expect(seen.Launch).to.equal(nil)
			expect(RagdollSystem.IsRagdolled(defender.Model)).to.equal(false)
		end)
	end)
end
