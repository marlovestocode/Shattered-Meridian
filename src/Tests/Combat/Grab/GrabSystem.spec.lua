--!strict
-- Covers Server/Combat/Grab/GrabSystem.lua.
--
-- Driven through the REAL HitboxEngine, DefenseSystem and DamageSystem, on rigs built with
-- Instance.new exactly as DamageSystem.spec's own makeDummy does -- the point of this module is that
-- it begins a hold off a contact a live engine found, a live defence layer classified and a live
-- damage layer priced (including resolving a Grab profile), and a synthetic stand-in for any of those
-- three would test the wiring rather than the behaviour.
--
-- Time is driven through Step(deltaTime, now) on all FOUR modules, in the order Main.server.lua
-- guarantees at runtime: engine, defence, damage, grab. Nothing here sleeps. Init() is deliberately
-- never called on any of them -- it would connect real Heartbeats racing these synthetic Steps, which
-- is exactly why Attach() exists separately -- see DamageSystem.spec.lua's own header for the same
-- reasoning applied one layer down.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local GrabSystem = require(ServerScriptService.Server.Combat.Grab.GrabSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-grab-parry"
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3

-- Same DebugName every case throws, same reasoning DamageSystem.spec's own MOVE_ID has: the only key
-- the damage layer (and therefore GrabSystem, one layer further out) has for looking an attack back up
-- is this string.
local MOVE_ID = "default:Primary:Basic:1"

-- A short, easy-to-cross hold so "auto-releases past HoldSeconds" doesn't need an enormous synthetic
-- time skip, and throw velocities small enough that a spec asserting on state (never on real physics
-- settling) doesn't need to care what they resolve to.
local GRAB_CONFIG: MoveTypes.MoveGrabConfig = {
	AttachOffset = CFrame.new(),
	HoldSeconds = 0.2,
	ThrowUpVelocity = 10,
	ThrowHorizontalVelocity = 10,
	ThrowImpactDamage = 5,
	ThrowSelfDamage = 5,
}

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

-- Same "spec's own big, long-lived, easy-to-land geometry against a real MoveId" split
-- DamageSystem.spec's makeDefinition uses, for the identical reason: the engine runs whatever volume
-- it is handed, the damage (and now grab) layers price/react to it by name alone.
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

-- One frame, in the order Main.server.lua guarantees -- engine, defence, damage, grab.
local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
	DamageSystem.Step(deltaTime, now)
	GrabSystem.Step(deltaTime, now)
end

-- Publishes a custom move over the Default id carrying GRAB_CONFIG, the same "clone the Default
-- projection, overwrite one field, Upsert it live" pattern DamageSystem.spec's own overrideMove uses.
local function overrideMoveWithGrab(): ()
	local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
	move.Grab = GRAB_CONFIG
	MoveRegistryManager.Upsert(move)
end

-- A Clean hit against two dummies facing each other, with the Grab-carrying move already live.
local function throwGrabHit(base: number): (Dummy, Dummy)
	overrideMoveWithGrab()
	local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
	local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
	HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
	step(FRAME, base + FRAME)
	return attacker, defender
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		DamageSystem.Attach()
		GrabSystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, WINDOW_OPEN, WINDOW_CLOSE)
	end)

	afterEach(function()
		GrabSystem.Reset()
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

	describe("GrabSystem -- beginning a hold", function()
		it("begins a hold when a Clean hit carries a Grab profile", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(true)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(true)
		end)

		it("marks the victim Grabbed and root-control-locked, and the attacker Grabbing", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			expect(attacker.Humanoid:GetAttribute(Constants.Attributes.Grabbing)).to.equal(true)
			expect(defender.Humanoid:GetAttribute(Constants.Attributes.Grabbed)).to.equal(true)
			expect(defender.Humanoid:GetAttribute(Constants.Attributes.RootControlLocked)).to.equal(true)
		end)

		it("never begins a hold at all when the move carries no Grab profile", function()
			-- No overrideMoveWithGrab call -- the shipped Default move's own Grab is nil, so this is
			-- the ordinary case every ordinary Basic hit already goes through.
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(false)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(false)
		end)

		it("does not begin a second hold for an attacker who is already holding someone", function()
			local base = os.clock()
			local attacker, firstVictim = throwGrabHit(base)
			local secondVictim = makeDummy("SecondDefender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- The same attacker lands a second Grab-carrying hit while still holding the first victim.
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + 2 * FRAME)

			expect(GrabSystem.IsHeld(firstVictim.Model)).to.equal(true)
			expect(GrabSystem.IsHeld(secondVictim.Model)).to.equal(false)
		end)
	end)

	describe("GrabSystem.CanAttack", function()
		it("refuses a holding attacker's own next attack", function()
			local base = os.clock()
			local attacker = throwGrabHit(base)

			local canAttack, reason = GrabSystem.CanAttack(attacker.Model, base + FRAME)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Grabbing")
		end)

		it("refuses the held victim's own next attack", function()
			local base = os.clock()
			local _attacker, defender = throwGrabHit(base)

			local canAttack, reason = GrabSystem.CanAttack(defender.Model, base + FRAME)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Grabbed")
		end)

		it("leaves an uninvolved third party free to attack", function()
			local base = os.clock()
			throwGrabHit(base)
			local bystander = makeDummy("Bystander", Vector3.new(20, 5, 0), Vector3.new(20, 5, -4))

			expect(GrabSystem.CanAttack(bystander.Model, base + FRAME)).to.equal(true)
		end)
	end)

	describe("GrabSystem -- the hold's own safety timer", function()
		it("auto-releases and returns control once HoldSeconds elapses with no Throw", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			local after = base + FRAME + GRAB_CONFIG.HoldSeconds + FRAME
			step(FRAME, after)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(false)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(false)
			expect(defender.Humanoid:GetAttribute(Constants.Attributes.Grabbed)).to.equal(nil)
			expect(attacker.Humanoid:GetAttribute(Constants.Attributes.Grabbing)).to.equal(nil)
			expect(defender.Humanoid.PlatformStand).to.equal(false)
		end)

		it("lets both sides attack again once the hold has auto-released", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			local after = base + FRAME + GRAB_CONFIG.HoldSeconds + FRAME
			step(FRAME, after)

			expect(GrabSystem.CanAttack(attacker.Model, after)).to.equal(true)
			expect(GrabSystem.CanAttack(defender.Model, after)).to.equal(true)
		end)
	end)

	describe("GrabSystem.Throw", function()
		it("clears the hold and marks the victim in flight", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			local accepted, reason = GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(accepted).to.equal(true)
			expect(reason).to.equal(nil)
			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(false)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(false)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(true)
		end)

		it("clears the attacker's Grabbing Attribute but keeps the victim's Grabbed one through flight", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(attacker.Humanoid:GetAttribute(Constants.Attributes.Grabbing)).to.equal(nil)
			expect(defender.Humanoid:GetAttribute(Constants.Attributes.Grabbed)).to.equal(true)
		end)

		it("lets the former attacker throw a new attack immediately", function()
			local base = os.clock()
			local attacker = throwGrabHit(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(GrabSystem.CanAttack(attacker.Model, base + 2 * FRAME)).to.equal(true)
		end)

		it("refuses a Throw from a combatant who is not holding anyone", function()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))

			local accepted, reason = GrabSystem.Throw(attacker.Model, base)

			expect(accepted).to.equal(false)
			expect(reason).to.equal("NotHolding")
		end)
	end)
end
