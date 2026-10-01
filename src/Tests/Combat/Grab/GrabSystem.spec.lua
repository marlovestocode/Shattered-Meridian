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

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local GrabRig = require(ReplicatedStorage.Shared.Grab.GrabRig)
local GrabSystem = require(ServerScriptService.Server.Combat.Grab.GrabSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- A real roster weapon, because the ids below have to RESOLVE through AttackCatalog -- weapons are
-- models in Workspace.Weapons now (Shared/Combat/WeaponRoster.lua), so a spec that installs none gets
-- a catalogue with no weapon moves in it and every lookup returns nil.
local WEAPON = WeaponFixture.Install()[1]

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-grab-parry"
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3

-- Same DebugName every case throws, same reasoning DamageSystem.spec's own MOVE_ID has: the only key
-- the damage layer (and therefore GrabSystem, one layer further out) has for looking an attack back up
-- is this string.
local MOVE_ID = `default:{WEAPON}:Basic:1`

-- A short, easy-to-cross hold so "auto-releases past HoldSeconds" doesn't need an enormous synthetic
-- time skip, and throw velocities small enough that a spec asserting on state (never on real physics
-- settling) doesn't need to care what they resolve to.
local GRAB_CONFIG: MoveTypes.MoveGrabConfig = {
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

-- Anchored by default so a rig with no floor under it stays put. A would-be grab VICTIM must be built
-- unanchored (`anchored = false`): GrabSystem refuses to weld a grounded body into an attacker's
-- assembly, since that would pin the attacker rather than lift the victim.
local function makeDummy(name: string, position: Vector3, lookAt: Vector3?, anchored: boolean?): Dummy
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = anchored ~= false
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
local function overrideMoveWithGrab(config: MoveTypes.MoveGrabConfig?): ()
	local move = MoveTypes.Clone(DefaultMoveRegistry.Get(MOVE_ID) :: any)
	move.Grab = config or GRAB_CONFIG
	MoveRegistryManager.Upsert(move)
end

-- A Clean hit against two dummies facing each other, with the Grab-carrying move already live.
local function throwGrabHit(base: number, config: MoveTypes.MoveGrabConfig?): (Dummy, Dummy)
	overrideMoveWithGrab(config)
	local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
	local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)
	HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
	step(FRAME, base + FRAME)
	return attacker, defender
end

local function holdWeldOf(defender: Dummy): Weld?
	return defender.Model:FindFirstChild(GrabConstants.Hold.WeldName, true) :: Weld?
end

-- A real R6 body (Torso, arms, head, Motor6Ds) for the cases that are about the rig rather than the
-- state machine -- the bare root-only dummies above deliberately exercise GrabRig's fallback instead.
-- Anchored root for the holder only, so neither falls while a case runs; the victim must be unanchored.
local function makeR6(name: string, position: Vector3, lookAt: Vector3, anchored: boolean): Dummy
	local model =
		Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R6)
	model.Name = name
	model:PivotTo(CFrame.lookAt(position, lookAt))
	local root = model.PrimaryPart :: BasePart
	root.Anchored = anchored
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	model.Parent = Workspace
	table.insert(spawned, model)
	local id = HitboxEngine.RegisterCombatant(model, root, humanoid)
	DefenseSystem.RegisterCombatant(model, root, humanoid, PARRY_ANIMATION)
	return { Model = model, Root = root, Humanoid = humanoid, Id = id }
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
			local secondVictim = makeDummy("SecondDefender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)

			-- The same attacker lands a second Grab-carrying hit while still holding the first victim.
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + 2 * FRAME)

			expect(GrabSystem.IsHeld(firstVictim.Model)).to.equal(true)
			expect(GrabSystem.IsHeld(secondVictim.Model)).to.equal(false)
		end)
	end)

	describe("GrabSystem -- the hold itself", function()
		it("falls back to root-to-root, at R6 numbers, for a rig with no arm, torso or head", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			local weld = holdWeldOf(defender)
			expect(weld).to.be.ok()
			local found = weld :: Weld
			local mode = GrabConstants.ModeOf(nil)
			local hold = GrabConstants.Hold
			expect(found.Part0).to.equal(attacker.Root)
			expect(found.Part1).to.equal(defender.Root)
			expect(found.C0).to.equal(CFrame.new(hold.FallbackShoulder + mode.Arm * hold.FallbackReach) * mode.Body)
			expect(found.C1).to.equal(CFrame.new(hold.FallbackGrips[mode.GripAt]))
			-- No arm was posed, so there is none for the client to pin.
			expect(attacker.Model:GetAttribute(hold.ArmAttribute)).to.equal(nil)
		end)

		it("welds a real rig's torso to the holder's HAND, with the hand pointed along the mode's arm", function()
			overrideMoveWithGrab()
			local base = os.clock()
			local attacker = makeR6("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			local defender = makeR6("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)
			local shoulder = (attacker.Model:FindFirstChild("Torso") :: BasePart):FindFirstChild(
					"Right Shoulder"
				) :: Motor6D
			local restC0 = shoulder.C0

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local weld = holdWeldOf(defender) :: Weld
			expect(weld).to.be.ok()
			expect(weld.Part0).to.equal(attacker.Model:FindFirstChild("Right Arm"))
			expect(weld.Part1).to.equal(defender.Model:FindFirstChild("Torso"))
			expect(attacker.Model:GetAttribute(GrabConstants.Hold.ArmAttribute)).to.equal("Right")

			-- The posed arm, read back through the rig's own joints: its hand tip lies along the mode's Arm
			-- from the shoulder joint -- the tip correction working on a real R6 arm, not in theory.
			local rest = GrabRig.RestInRoot(attacker.Model, attacker.Root)
			local torso = shoulder.Part0 :: BasePart
			local jointPosition = (rest[torso] * restC0).Position
			local arm = shoulder.Part1 :: BasePart
			local tip = rest[arm] * Vector3.new(0, -arm.Size.Y * 0.5, 0)
			local direction = (tip - jointPosition).Unit
			expect(direction:Dot(GrabConstants.ModeOf(nil).Arm) > 0.999).to.equal(true)

			-- And the grip point on the victim's torso is ON that tip, through the weld.
			local torsoOfVictim = defender.Model:FindFirstChild("Torso") :: BasePart
			local gripInHand = weld.C0 * weld.C1:Inverse() * GrabRig.GripLocal(torsoOfVictim, "Collar")
			local gripInRoot = rest[arm] * gripInHand
			expect((gripInRoot - tip).Magnitude < 1e-3).to.equal(true)

			-- What gets pinned against the run/walk cycle is the torso joint as well as the arm: a pinned arm
			-- on an animated torso still swings the hand.
			local pinned = GrabRig.HoldJoints(attacker.Model, attacker.Root, "Right") :: { Motor6D }
			local rootJoint = attacker.Root:FindFirstChild("RootJoint")
			expect(table.find(pinned, shoulder)).to.be.ok()
			expect(table.find(pinned, rootJoint :: any)).to.be.ok()
			expect(#pinned).to.equal(2)

			-- Released: the shoulder is exactly as it was.
			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)
			expect(shoulder.C0).to.equal(restC0)
		end)

		it("makes the held body massless and moves it into the hold's collision group", function()
			local base = os.clock()
			local _attacker, defender = throwGrabHit(base)

			expect(defender.Root.Massless).to.equal(true)
			expect(defender.Root.CollisionGroup).to.equal(GrabConstants.Hold.CollisionGroup)
		end)

		it("tags both bodies for the hold pose", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			expect(CollectionService:HasTag(attacker.Model, GrabConstants.Hold.HolderTag)).to.equal(true)
			expect(CollectionService:HasTag(defender.Model, GrabConstants.Hold.HeldTag)).to.equal(true)
		end)

		it("tells clients the victim's hold mode, defaulting a config that names none to Collar", function()
			local base = os.clock()
			local _attacker, defender = throwGrabHit(base)

			expect(defender.Model:GetAttribute(GrabConstants.Hold.ModeAttribute)).to.equal(GrabConstants.DefaultMode)
			-- No VictimAnimation authored, so the client pose owns the victim's hands.
			expect(defender.Model:GetAttribute(GrabConstants.Hold.VictimAnimatedAttribute)).to.equal(nil)
		end)

		it("holds by the config's own mode", function()
			local dragConfig = table.clone(GRAB_CONFIG)
			dragConfig.Mode = "Drag"
			local base = os.clock()
			local _attacker, defender = throwGrabHit(base, dragConfig)

			expect(defender.Model:GetAttribute(GrabConstants.Hold.ModeAttribute)).to.equal("Drag")
			local drag = GrabConstants.Modes.Drag
			local hold = GrabConstants.Hold
			expect((holdWeldOf(defender) :: Weld).C0).to.equal(
				CFrame.new(hold.FallbackShoulder + drag.Arm * hold.FallbackReach) * drag.Body
			)
		end)

		it("clears the tags and the grip the moment the hold ends", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(CollectionService:HasTag(attacker.Model, GrabConstants.Hold.HolderTag)).to.equal(false)
			expect(CollectionService:HasTag(defender.Model, GrabConstants.Hold.HeldTag)).to.equal(false)
			expect(attacker.Model:GetAttribute(GrabConstants.Hold.ArmAttribute)).to.equal(nil)
			expect(defender.Model:GetAttribute(GrabConstants.Hold.ModeAttribute)).to.equal(nil)
		end)

		it("never grabs a victim that is anchored", function()
			overrideMoveWithGrab()
			local base = os.clock()
			local attacker = makeDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = makeDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			expect(GrabSystem.IsHeld(defender.Model)).to.equal(false)
			expect(defender.Humanoid.PlatformStand).to.equal(false)
		end)

		it("releases the hold, and restores the body, the frame its weld goes missing", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)
			local originalGroup = "Default"

			local weld = holdWeldOf(defender) :: Weld
			weld:Destroy()
			step(FRAME, base + 2 * FRAME)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(false)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(false)
			expect(defender.Root.Massless).to.equal(false)
			expect(defender.Root.CollisionGroup).to.equal(originalGroup)
			expect(defender.Humanoid.PlatformStand).to.equal(false)
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
			expect(holdWeldOf(defender)).to.equal(nil)
			expect(defender.Root.Massless).to.equal(false)
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

		it("breaks the weld and gives the body its own mass and collision back for the flight", function()
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(holdWeldOf(defender)).to.equal(nil)
			expect(defender.Root.Massless).to.equal(false)
			expect(defender.Root.CollisionGroup).to.equal("Default")
			-- Still the flight's until it lands.
			expect(defender.Humanoid.PlatformStand).to.equal(true)
		end)

		it("lands on, and damages, a bystander the thrown body reaches", function()
			-- Registered AFTER GrabSystem was required, which is the case the combatant filter used to
			-- miss: it copied the tagged list once at module load and never saw anyone registered later.
			local base = os.clock()
			local attacker, defender = throwGrabHit(base)
			-- Within Impact.CollisionRadiusStuds of the victim wherever the weld left it -- this spec
			-- does not simulate physics, so it may still be at its own spawn or already on its mark --
			-- and a clear stud outside makeDefinition's still-active 4-wide box, so the attacker's own
			-- swing cannot land on it first.
			local bystander = makeDummy("Bystander", Vector3.new(4, 5, -2), Vector3.new(0, 5, -2))
			local healthBefore = bystander.Humanoid.Health

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)
			step(FRAME, base + 3 * FRAME)

			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(false)
			expect(bystander.Humanoid.Health).to.equal(healthBefore - GRAB_CONFIG.ThrowImpactDamage)
			expect(defender.Humanoid:GetAttribute(Constants.Attributes.Grabbed)).to.equal(nil)
			expect(defender.Humanoid.PlatformStand).to.equal(false)
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

	-- Real R6 rigs, because the throw clip plays through AnimationManager on the holder's own Animator.
	-- The id never resolves to a real asset here, so its Length stays 0 and nothing but the clock
	-- this spec drives (GrabSystem's own deadline) can end the clip within a case: the launch-on-finish
	-- path itself is AnimationManager's, and is covered by its own spec.
	describe("GrabSystem.Throw -- with a ThrowAnimation", function()
		local THROW_CONFIG: MoveTypes.MoveGrabConfig = table.clone(GRAB_CONFIG)
		THROW_CONFIG.ThrowAnimation = "rbxassetid://1"

		local function throwGrabHitR6(base: number): (Dummy, Dummy)
			overrideMoveWithGrab(THROW_CONFIG)
			local attacker = makeR6("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			local defender = makeR6("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			return attacker, defender
		end

		it("keeps the victim welded in the hand while the clip plays", function()
			local base = os.clock()
			local attacker, defender = throwGrabHitR6(base)

			local accepted = GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(accepted).to.equal(true)
			expect(GrabSystem.IsThrowing(attacker.Model)).to.equal(true)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(true)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(false)
			expect(holdWeldOf(defender)).to.be.ok()
		end)

		it("refuses a second press while the first throw's clip is still playing", function()
			local base = os.clock()
			local attacker = throwGrabHitR6(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)
			local accepted, reason = GrabSystem.Throw(attacker.Model, base + 3 * FRAME)

			expect(accepted).to.equal(false)
			expect(reason).to.equal("AlreadyThrowing")
		end)

		it("hands the holder's arm to the clip but keeps the victim's hold pose", function()
			overrideMoveWithGrab(THROW_CONFIG)
			local base = os.clock()
			local attacker = makeR6("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			local defender = makeR6("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)
			local shoulder = (attacker.Model:FindFirstChild("Torso") :: BasePart):FindFirstChild(
					"Right Shoulder"
				) :: Motor6D
			local restC0 = shoulder.C0
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(shoulder.C0 == restC0).to.equal(false)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(shoulder.C0).to.equal(restC0)
			expect(CollectionService:HasTag(attacker.Model, GrabConstants.Hold.HolderTag)).to.equal(false)
			expect(attacker.Model:GetAttribute(GrabConstants.Hold.ArmAttribute)).to.equal(nil)
			expect(CollectionService:HasTag(defender.Model, GrabConstants.Hold.HeldTag)).to.equal(true)
		end)

		it("is not released by HoldSeconds once the throw is committed", function()
			local base = os.clock()
			local attacker, defender = throwGrabHitR6(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)
			step(FRAME, base + 2 * FRAME + GRAB_CONFIG.HoldSeconds + FRAME)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(true)
			expect(GrabSystem.IsHeld(defender.Model)).to.equal(true)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(false)
		end)

		it("launches the victim itself if the clip's finish never arrives", function()
			local base = os.clock()
			local attacker, defender = throwGrabHitR6(base)
			local throwing = GrabConstants.Throw

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)
			step(FRAME, base + 2 * FRAME + throwing.MaxClipSeconds + throwing.DeadlineGraceSeconds + FRAME)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(false)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(true)
			expect(holdWeldOf(defender)).to.equal(nil)
		end)

		it("hands the victim's arms to their thrown clip from the press, while still held", function()
			local config: MoveTypes.MoveGrabConfig = table.clone(THROW_CONFIG)
			config.VictimThrowAnimation = "rbxassetid://2"
			overrideMoveWithGrab(config)
			local base = os.clock()
			local attacker = makeR6("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4), true)
			local defender = makeR6("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0), false)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			-- No held clip authored, so the client pose owns the victim's hands during the hold.
			expect(defender.Model:GetAttribute(GrabConstants.Hold.VictimAnimatedAttribute)).to.equal(nil)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)

			expect(GrabSystem.IsHeld(defender.Model)).to.equal(true)
			expect(defender.Model:GetAttribute(GrabConstants.Hold.VictimAnimatedAttribute)).to.equal(true)
		end)

		it("releases rather than throws when the victim dies mid-clip", function()
			local base = os.clock()
			local attacker, defender = throwGrabHitR6(base)

			GrabSystem.Throw(attacker.Model, base + 2 * FRAME)
			defender.Humanoid.Health = 0
			step(FRAME, base + 3 * FRAME)

			expect(GrabSystem.IsHolding(attacker.Model)).to.equal(false)
			expect(GrabSystem.IsInFlight(defender.Model)).to.equal(false)
		end)
	end)
end
