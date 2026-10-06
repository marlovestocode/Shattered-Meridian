--!strict
-- Covers Server/Combat/Damage/DamageSystem.lua -- the whole stack, end to end.
--
-- Driven through the REAL HitboxEngine and the REAL DefenseSystem, on rigs built with Instance.new
-- exactly as DefenseSystem.spec and HitboxEngine.spec build theirs. The point of this module is that
-- it prices contacts a live engine found and a live defence layer classified, and a synthetic stand-in
-- for either would test the wiring rather than the behaviour.
--
-- Time is driven through Step(deltaTime, now) on all THREE modules, in the order Main.server.lua
-- guarantees at runtime: engine, defence, damage. Nothing here sleeps. Init() is deliberately never
-- called on any of them -- it would connect real Heartbeats racing these synthetic Steps, which is
-- exactly why Attach() exists separately.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- A real roster weapon, because the ids below have to RESOLVE through AttackCatalog -- weapons are
-- models in Workspace.Weapons now (Shared/Combat/WeaponRoster.lua), so a spec that installs none gets
-- a catalogue with no weapon moves in it and every lookup returns nil.
local WEAPON = WeaponFixture.Install()[1]

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-damage-parry"
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3

-- The definition thrown by every case carries this as its DebugName, because that is the only key the
-- damage layer has for looking an attack back up. A DebugName that is not a MoveId resolves to nothing
-- and the whole layer silently deals zero -- which is itself one of the cases below.
local MOVE_ID = `default:{WEAPON}:Basic:1`

-- The stun MOVE_ID (a Basic stage) inflicts. Read off the catalogue rather than DamageConstants.HitstunFor: a
-- stage with a next stage LINKS (DamageConstants.Hitstun.LinkBasicString), so its stun is derived from the
-- string's own timeline and only the catalogue knows it.
local function stunSeconds(): number
	local entry = AttackCatalog.Get(MOVE_ID)
	assert(entry ~= nil, "the spec weapon's Basic 1 must be catalogued")
	return (entry :: any).Profile.HitstunSeconds or DamageConstants.HitstunFor(WEAPON, "Basic")
end

type Dummy = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Id: number,
}

local spawned: { Model } = {}

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

-- Geometry is the spec's own (big, long-lived, easy to land) while the NAME is a real MoveId. That
-- split is deliberate and is exactly the seam under test: the engine runs whatever volume it is
-- handed, and the damage layer prices it from the catalogue by name alone.
local function makeDefinition(overrides: { [string]: any }?): HitboxTypes.AttackDefinition
	local base: { [string]: any } = {
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
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return (HitboxTypes.SanitizeDefinition(base))
end

-- A swing that cannot touch anybody: a tiny volume parked 40 studs BEHIND the attacker (+Z is
-- backward in local space).
--
-- Used by the hitstun cases so a defender can be genuinely mid-swing without that swing landing on
-- anyone. Turning the defender around instead would work geometrically and be wrong for the test:
-- facing away puts the incoming hit in their rear hemisphere, so the outcome becomes a Backstab rather
-- than the Clean or Blocked hit the case is actually about.
local function makeMissingDefinition(): HitboxTypes.AttackDefinition
	return makeDefinition({
		Offset = CFrame.new(0, 0, 40),
		BaseDimensions = { Width = 1, Height = 1, Length = 1 },
	})
end

-- One frame, in the order Main.server.lua guarantees.
local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
	DamageSystem.Step(deltaTime, now)
end

-- Authored numbers read from the catalogue rather than hardcoded, so retuning a move in Constants.lua
-- does not break assertions that are not about its balance.
local function authored(): (number, number)
	local entry = AttackCatalog.Get(MOVE_ID) :: any
	return entry.Profile.Damage, entry.Profile.PostureDamage
end

-- Publishes a custom move over the Default id, for the cases that need an authored number the shipped
-- tuning does not happen to provide (a one-hit guard break, a zero-posture move).
local function overrideMove(fields: { [string]: any }): ()
	local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
	for key, value in fields do
		(move :: any)[key] = value
	end
	MoveRegistryManager.Upsert(move)
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		DamageSystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, WINDOW_OPEN, WINDOW_CLOSE)
	end)

	afterEach(function()
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

	describe("DamageSystem -- a clean hit", function()
		it("removes the move's authored damage from the defender's health", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local damage = authored()
			local before = defender.Humanoid.Health

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(defender.Humanoid.Health).to.be.near(before - damage, 1e-3)
		end)

		it("does not shadow-track health -- Humanoid.Health stays the only authority", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- Moved out from under the system entirely. A layer keeping its own pool would overwrite
			-- this on the next hit; one delegating to TakeDamage subtracts from whatever it finds.
			defender.Humanoid.Health = 50
			local damage = authored()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(defender.Humanoid.Health).to.be.near(50 - damage, 1e-3)
		end)

		it("deals nothing at all when the attack is not in the catalogue", function()
			-- The failure mode the DebugName seam exists to prevent, asserted so it stays a known
			-- outcome rather than a mystery: engine works, defence works, nobody takes damage.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local before = defender.Humanoid.Health

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ DebugName = "not-a-move-id" }), 1, 1)
			step(FRAME, base + FRAME)

			expect(defender.Humanoid.Health).to.equal(before)
		end)
	end)

	describe("DamageSystem -- guard as the posture pool", function()
		it("drains guard from a defender who never blocked at all", function()
			-- THE WHOLE POINT OF GUARD DOUBLING AS POSTURE. DefenseSystem alone only ever moves guard
			-- while a player is actively blocking, so on its own it cannot touch someone who never
			-- raises a guard. This is the half that can.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local _, posture = authored()

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local guard = DefenseSystem.GetGuard(defender.Model)
			local expected = DefenseConstants.Guard.Max - posture * DamageConstants.Guard.PressurePerPostureDamage
			expect(guard).to.be.near(expected, 1e-3)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Neutral")
		end)

		it("breaks the guard when the pressure empties it, opening the defender up", function()
			overrideMove({ PostureDamage = DefenseConstants.Guard.Max + 10 })

			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			-- The posture break IS the existing guard break -- no new state, no second HUD number.
			expect(DefenseSystem.GetState(defender.Model)).to.equal("GuardBroken")
			expect(DefenseSystem.GetGuard(defender.Model)).to.equal(0)
		end)

		it("charges a blocked hit once, not twice", function()
			-- DefenseSystem already priced the block through GuardMeter.DrainFor. If this layer drained
			-- again, blocking would silently cost double what its own tuning says.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			local guard = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.be.near(DefenseConstants.Guard.Max - DefenseConstants.Guard.DrainPerPowerLevel, 1e-3)
		end)

		it("costs a blocking defender no health", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local before = defender.Humanoid.Health

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			expect(defender.Humanoid.Health).to.equal(before)
		end)
	end)

	describe("DamageSystem -- hitstun", function()
		it("gates the defender out of attacking", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local canAttack, reason = DamageSystem.CanAttack(defender.Model, base + FRAME)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Hitstun")
		end)

		it("knocks the defender out of a run for exactly the hitstun", function()
			-- RunSystem reads CombatBusyUntil as "a combat action is committing this body" and forces the
			-- run ladder to 0 until it passes -- the same seam a thrown swing uses. Asserted on the
			-- Attribute, which is the whole contract between the two layers.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			expect(defender.Humanoid:GetAttribute("CombatBusyUntil")).to.equal(nil)

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local busyUntil = defender.Humanoid:GetAttribute("CombatBusyUntil")
			expect(busyUntil).to.be.a("number")
			expect(busyUntil).to.be.near(base + FRAME + stunSeconds(), 0.05)
		end)

		it("publishes the stun on its own Attribute for the defence layer", function()
			-- DefenseSystem holds a guard press until this passes, and reads it rather than CombatBusyUntil
			-- because that one also carries swing commitments that end early when a swing is cancelled.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			expect(defender.Humanoid:GetAttribute("HitstunUntil")).to.equal(nil)

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local stunnedUntil = defender.Humanoid:GetAttribute("HitstunUntil")
			expect(stunnedUntil).to.be.a("number")
			expect(stunnedUntil).to.be.near(base + FRAME + stunSeconds(), 0.05)
		end)

		it("does not stop the run of a defender whose guard held", function()
			-- A blocking defender is already walking (RunSystem gates on a raised guard), and a hit that
			-- grants no hitstun has no lockout to publish.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			expect(defender.Humanoid:GetAttribute("CombatBusyUntil")).to.equal(nil)
		end)

		it("clears on its own once the lockout elapses", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local after = base + FRAME + stunSeconds()
			expect(DamageSystem.CanAttack(defender.Model, after)).to.equal(true)
		end)

		it("ends the moment the defender parries their way out of it", function()
			-- DefenseConstants.StunParry: a parry landed from inside a stun frees the parrier on the spot, so the
			-- punish is theirs to take rather than a wait for the stun to run out.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local second = makeDummy("Second", Vector3.new(0.5, 5, 0), Vector3.new(0.5, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(DamageSystem.CanAttack(defender.Model, base + 2 * FRAME)).to.equal(false)

			DefenseSystem.SetBlocking(defender.Model, true, base + 2 * FRAME)
			HitboxEngine.RequestAttack(second.Id, makeDefinition(), 1, 1)
			step(FRAME, base + 3 * FRAME)

			expect(DefenseSystem.GetState(second.Model)).to.equal("Staggered")
			expect(DamageSystem.CanAttack(defender.Model, base + 3 * FRAME + 1e-3)).to.equal(true)
			local stunnedUntil = defender.Humanoid:GetAttribute("HitstunUntil")
			expect(stunnedUntil <= base + 3 * FRAME + 1e-3).to.equal(true)
		end)

		it("cancels the defender's own in-flight swing", function()
			-- THE MECHANIC THAT MAKES A COUNTER-HIT A REAL ANSWER. Before it, only a parry cancelled a
			-- swing, and only the attacker's -- a player struck mid-combo simply kept swinging.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- Mid-swing, but swinging at nothing -- so the exchange stays one-directional and this is a
			-- clean counter-hit rather than a mutual trade.
			HitboxEngine.RequestAttack(defender.Id, makeMissingDefinition(), 1, 1)
			expect(HitboxEngine.GetAttackState(defender.Id)).never.to.equal("Idle")

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(HitboxEngine.GetAttackState(defender.Id)).to.equal("Idle")
		end)

		it("leaves a blocked defender's swing alone", function()
			-- A block answers the hit, so it must not also cost the defender the swing they were
			-- throwing. Only a hit that actually got through interrupts.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)

			HitboxEngine.RequestAttack(defender.Id, makeMissingDefinition(), 1, 1)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			expect(HitboxEngine.GetAttackState(defender.Id)).never.to.equal("Idle")
		end)
	end)

	describe("DamageSystem -- a clash", function()
		it("cancels both swings and hurts nobody, symmetrically", function()
			-- Two Clean hits on each other in one batch are ONE exchange (DefenseConstants.Clash), resolved
			-- as a Trade. This used to be a double hit -- both stunned, both damaged -- and anything a frame
			-- apart went to whoever the server heard first. Neither side wins a clash: both lose the swing,
			-- neither takes a hit.
			local base = os.clock()
			local alpha = makeDummy("Alpha", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local beta = makeDummy("Beta", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(alpha.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(beta.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(HitboxEngine.GetAttackState(alpha.Id)).to.equal("Idle")
			expect(HitboxEngine.GetAttackState(beta.Id)).to.equal("Idle")
			expect(DamageSystem.IsHitstunned(alpha.Model, base + FRAME)).to.equal(false)
			expect(DamageSystem.IsHitstunned(beta.Model, base + FRAME)).to.equal(false)
			expect(alpha.Humanoid.Health).to.be.near(100, 1e-3)
			expect(beta.Humanoid.Health).to.be.near(100, 1e-3)
		end)

		it("reports a defender's active volume as reaching only when it covers the attacker", function()
			-- The measurement the clash's second rule reads (HitboxEngine.ActiveSwingReaches): a blade that is
			-- out and pointed at the attacker reaches; one swinging at nothing does not, which is what keeps
			-- the counter-hit above a counter-hit rather than a clash.
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local bystander = makeDummy("Bystander", Vector3.new(30, 5, 0), Vector3.new(30, 5, -4))

			HitboxEngine.RequestAttack(defender.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(bystander.Id, makeMissingDefinition(), 1, 1)

			expect(HitboxEngine.ActiveSwingReaches(defender.Id, attacker.Model, 0)).to.equal(true)
			expect(HitboxEngine.ActiveSwingReaches(bystander.Id, attacker.Model, 0)).to.equal(false)
			expect(HitboxEngine.ActiveSwingReaches(attacker.Id, defender.Model, 0)).to.equal(false)
		end)
	end)

	describe("DamageSystem -- combo escalation", function()
		it("advances on a landed hit", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(DamageSystem.GetComboStage(attacker.Model, base + FRAME)).to.equal(1)

			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + 2 * FRAME)
			expect(DamageSystem.GetComboStage(attacker.Model, base + 2 * FRAME)).to.equal(2)
		end)

		it("grants no credit at all for a blocked hit", function()
			-- The deliberate call over partial credit: a defender who raises a guard deserves an
			-- unambiguous answer to "did that work".
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			expect(DamageSystem.GetComboStage(attacker.Model, base + WINDOW_CLOSE + 2 * FRAME)).to.equal(1)
		end)
	end)

	describe("DamageSystem -- a parry", function()
		it("costs the defender no health and no guard", function()
			-- DefenseSystem has already cancelled the swing and staggered the attacker. This layer
			-- moves nothing on top of that.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local before = defender.Humanoid.Health

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
			expect(defender.Humanoid.Health).to.equal(before)
			expect(DamageSystem.IsHitstunned(defender.Model, base + FRAME)).to.equal(false)
		end)
	end)

	describe("DamageSystem -- attacker lunge", function()
		it("starts a forced-forward window for the attacker on a landed M1 hit", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(DamageSystem.IsLunging(attacker.Model, base + FRAME)).to.equal(true)
		end)

		it("clears on its own once DamageConstants.AttackerLunge.DurationSeconds elapses", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local after = base + FRAME + DamageConstants.AttackerLunge.DurationSeconds
			expect(DamageSystem.IsLunging(attacker.Model, after)).to.equal(false)
		end)

		it("never starts a window at all for a Parried attacker -- nothing of their swing connected", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
			expect(DamageSystem.IsLunging(attacker.Model, base + FRAME)).to.equal(false)
		end)

		it("does not start a window for a Heavy or Finisher landing, only a Basic (M1) string", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition({ DebugName = `default:{WEAPON}:Heavy:1` }), 1, 1)
			step(FRAME, base + FRAME)

			expect(DamageSystem.IsLunging(attacker.Model, base + FRAME)).to.equal(false)
		end)

		it("still gives the attacker a window on a Blocked hit -- their swing still connected", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			expect(DamageSystem.IsLunging(attacker.Model, base + WINDOW_CLOSE + 2 * FRAME)).to.equal(true)
		end)

		it("respects DamageConstants.AttackerLunge.Enabled as a kill switch", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			LiveTuningContract.withRestore(function()
				DamageConstants.AttackerLunge.Enabled = false
				HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
				step(FRAME, base + FRAME)
				expect(DamageSystem.IsLunging(attacker.Model, base + FRAME)).to.equal(false)
			end, function()
				DamageConstants.AttackerLunge.Enabled = true
			end)
		end)
	end)

	describe("DamageSystem.ApplyImpact", function()
		-- A thrown body landing (GrabSystem): health removed outside any swing, credited to the thrower.
		it("removes the health and announces it, credited to the attacker, before the write", function()
			local base = os.clock()
			local thrower = makeDummy("Thrower", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local bystander = makeDummy("Bystander", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local before = bystander.Humanoid.Health

			local seen: { any } = {}
			local disconnect = DamageSystem.OnApplied(function(outcome, result)
				table.insert(seen, {
					Attacker = outcome.Attacker,
					Defender = outcome.Defender,
					DebugName = outcome.Report.DebugName,
					Damage = result.Damage,
					HealthAtCallback = bystander.Humanoid.Health,
				})
			end)
			local dealt = DamageSystem.ApplyImpact(thrower.Model, bystander.Model, 15, base)
			disconnect()

			expect(dealt).to.equal(15)
			expect(bystander.Humanoid.Health).to.be.near(before - 15, 1e-6)
			expect(#seen).to.equal(1)
			expect(seen[1].Attacker).to.equal(thrower.Model)
			expect(seen[1].Defender).to.equal(bystander.Model)
			expect(seen[1].DebugName).to.equal(DamageConstants.Impact.DebugName)
			expect(seen[1].HealthAtCallback).to.equal(before)
		end)

		it("stuns nothing and leaves the target free to swing", function()
			local base = os.clock()
			local thrower = makeDummy("Thrower", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local bystander = makeDummy("Bystander", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DamageSystem.ApplyImpact(thrower.Model, bystander.Model, 15, base)

			expect(DamageSystem.CanAttack(bystander.Model, base + FRAME)).to.equal(true)
			expect(bystander.Humanoid:GetAttribute("HitstunUntil")).to.equal(nil)
		end)

		it("deals nothing to a dead target or for a non-positive amount", function()
			local base = os.clock()
			local thrower = makeDummy("Thrower", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local bystander = makeDummy("Bystander", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			expect(DamageSystem.ApplyImpact(thrower.Model, bystander.Model, 0, base)).to.equal(0)
			bystander.Humanoid.Health = 0
			expect(DamageSystem.ApplyImpact(thrower.Model, bystander.Model, 15, base)).to.equal(0)
		end)
	end)

	describe("DamageSystem.OnApplied", function()
		it("fires before the health write, so a death is still attributable", function()
			-- Humanoid:TakeDamage raises Humanoid.Died synchronously, so a subscriber notified
			-- afterwards would always learn who dealt the killing blow strictly AFTER PlayerDeathSystem
			-- had already fired the death with no killer. This ordering is what leaves kill attribution
			-- a pure follow-up in that module rather than a restructuring of this one.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local healthAtCallback: number? = nil
			local seenAttacker: Model? = nil
			local disconnect = DamageSystem.OnApplied(function(outcome, _result)
				healthAtCallback = defender.Humanoid.Health
				seenAttacker = outcome.Attacker
			end)

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(seenAttacker).to.equal(attacker.Model)
			expect(healthAtCallback).to.equal(100)
			expect(defender.Humanoid.Health < 100).to.equal(true)
		end)
	end)
end
