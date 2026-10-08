--!strict
-- Covers the combat evade: States/Evading.lua's gate, its direction and held facing, the glide it drives,
-- and its exit. It is COMBAT ONLY: CanEnter refuses unless the InCombat Attribute is set, and the glide
-- itself never branches on it (the roll it replaced did, which is what made players roll into the floor).
--
-- Contexts are built by hand, for the reason Tests/Parkour/DashState.spec sets out: the state reads what
-- it needs off the context it is handed, so a hand-built table is an honest assertion of the real code
-- without a live character or a frame loop. Every fixture starts from one that PASSES, and each test
-- overrides only the field it is about.
--
-- THE EVADE COOLDOWN IS MODULE STATE (States/Evading.lua's), and it survives between tests -- so every
-- test takes its own `now` far enough ahead of the last that no earlier evade's cooldown is still live.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)
local EvadeMotion = require(ReplicatedStorage.Shared.Combat.EvadeMotion)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local InputBuffer = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.InputBuffer)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local Evading = findDefinition("Evading")
local evadeEnter = assert(Evading.Enter, "States/Evading.lua must define Enter")
local evadeExit = assert(Evading.Exit, "States/Evading.lua must define Exit")

local clock = 9000
local function nextNow(): number
	clock += 10
	return clock
end

-- A real BasePart: Enter reads RootPart.CFrame for the facing, and Exit reads AssemblyLinearVelocity.
-- Facing -Z, the engine's own default forward.
local function makeRootPart(): BasePart
	local part = Instance.new("Part")
	part.Size = Vector3.new(2, 5, 1)
	part.CFrame = CFrame.lookAt(Vector3.new(0, 10, 0), Vector3.new(0, 10, -1))
	return part
end

-- Standing still on flat ground, not in combat.
local function makeContext(now: number): any
	return {
		RootPart = makeRootPart(),
		Now = now,
		DeltaTime = 1 / 60,
		StateElapsed = 0,
		CurrentStateId = "Idle",
		PreviousStateId = "Walking",
		MoveIntent = Vector3.zero,
		MoveDirection = Vector3.zero,
		AimDirection = Vector3.new(0, 0, -1),
		Momentum = 0,
		PlanarSpeed = 0,
		VerticalVelocity = 0,
		SprintHeld = false,
		SprintStage = 0,
		InCombat = false,
		CombatCommitted = false,
		ApexHeight = 10,
		FallHeight = 0,
		LandingSeverity = nil,
		AnimationVariant = nil,
		Ground = {
			Grounded = true,
			NearGround = true,
			Distance = 0,
			Normal = Vector3.yAxis,
			SlopeAngle = 0,
			FrictionScale = 1,
		},
		Obstacle = { Found = false },
		Motor = {},
	}
end

-- A context with a buffered press, in combat, ready to pass CanEnter.
local function pressedContext(): any
	local now = nextNow()
	InputBuffer.PressEvade(now)
	local context = makeContext(now)
	context.InCombat = true
	return context
end

return function()
	afterEach(function()
		InputBuffer.Clear()
	end)

	describe("Evading.CanEnter", function()
		it("accepts a buffered press from a grounded, uncommitted character", function()
			expect((Evading.CanEnter(pressedContext()))).to.equal(true)
		end)

		it("refuses outside combat -- the evade is a fighting move only", function()
			local context = pressedContext()
			context.InCombat = false
			local ok, reason = Evading.CanEnter(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotInCombat")
		end)

		it("accepts a Dash-key (Q) press on the ground in combat -- Q is the combat dash", function()
			local now = nextNow()
			InputBuffer.PressDash(now)
			local context = makeContext(now)
			context.InCombat = true
			expect((Evading.CanEnter(context))).to.equal(true)
		end)

		it("refuses a Dash-key press outside combat -- Q on the ground does nothing out of a fight", function()
			local now = nextNow()
			InputBuffer.PressDash(now)
			local context = makeContext(now)
			context.InCombat = false
			local ok, reason = Evading.CanEnter(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotInCombat")
		end)

		it("spends BOTH presses on entry, so one Q cannot evade and then air-dash", function()
			local now = nextNow()
			InputBuffer.PressDash(now)
			InputBuffer.PressEvade(now)
			local context = makeContext(now)
			context.InCombat = true
			Evading.Enter(context)
			expect(InputBuffer.PeekDash(now)).to.equal(false)
			expect(InputBuffer.PeekEvade(now)).to.equal(false)
		end)

		it("refuses with no press", function()
			local ok, reason = Evading.CanEnter(makeContext(nextNow()))
			expect(ok).to.equal(false)
			expect(reason).to.equal("NoEvadeInput")
		end)

		it("refuses out of the player's own swing or a stun", function()
			local context = pressedContext()
			context.CombatCommitted = true
			local ok, reason = Evading.CanEnter(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("CombatCommitted")
		end)

		it("refuses in the air -- the evade is a ground move with no landing window", function()
			local context = pressedContext()
			context.CurrentStateId = "Falling"
			context.Ground.Grounded = false
			expect((Evading.CanEnter(context))).to.equal(false)
		end)

		it("refuses from a state that is not on the allowed list", function()
			local context = pressedContext()
			context.CurrentStateId = "Jumping"
			local ok, reason = Evading.CanEnter(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotAllowedFromThisState")
		end)

		it("accepts out of a slide, by pre-emption", function()
			local context = pressedContext()
			context.CurrentStateId = "Sliding"
			expect((Evading.CanEnter(context))).to.equal(true)
		end)

		it("refuses again until the cooldown has passed", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			local again = makeContext(context.Now + EvadeConstants.CooldownSeconds * 0.5)
			again.InCombat = true
			InputBuffer.PressEvade(again.Now)
			local ok, reason = Evading.CanEnter(again)
			expect(ok).to.equal(false)
			expect(reason).to.equal("EvadeCooldown")

			local later = makeContext(context.Now + EvadeConstants.CooldownSeconds + 0.01)
			later.InCombat = true
			InputBuffer.PressEvade(later.Now)
			expect((Evading.CanEnter(later))).to.equal(true)
		end)
	end)

	describe("Evading.Enter", function()
		it("spends the press", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			expect(InputBuffer.PeekEvade(context.Now)).to.equal(false)
		end)

		it("glides straight back with no input held", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			expect(context.AnimationVariant).to.equal("Back")
		end)

		it("glides along held input, keeping the facing", function()
			local context = pressedContext()
			context.MoveIntent = Vector3.new(-1, 0, 0)
			evadeEnter(context, "Idle")
			expect(context.AnimationVariant).to.equal("Left")
		end)

		it("leaves a landing's dip and shake behind", function()
			local context = pressedContext()
			context.CurrentStateId = "Landing"
			context.LandingSeverity = "Hard"
			context.FallHeight = 30
			evadeEnter(context, "Landing")
			expect(context.LandingSeverity).to.equal(nil)
			expect(context.FallHeight).to.equal(0)
		end)
	end)

	describe("Evading.Update", function()
		it("drives the shared glide curve, upright, facing held", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			context.StateElapsed = 0.05
			expect(Evading.Update(context)).to.equal(nil)
			local motor = context.Motor
			expect(motor.Mode).to.equal("Velocity")
			expect(motor.HipHeightDelta).to.equal(0)
			expect(math.abs(motor.DesiredSpeed - EvadeMotion.SpeedAt(0.05)) < 1e-6).to.equal(true)
			-- Facing held at -Z while gliding back (+Z).
			expect(motor.FaceDirection:Dot(Vector3.new(0, 0, -1)) > 0.99).to.equal(true)
			expect(motor.Velocity.Z > 0).to.equal(true)
		end)

		-- The "evade sinks into the ground" regression. A grounded glide that commands any vertical at the
		-- drive's force overpowers the Humanoid's hip support and buries the R6 legs; horizontal-only leaves
		-- standing height to the Humanoid.
		it("never commands the vertical while grounded, so the body stays at standing height", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			context.StateElapsed = 0.01
			Evading.Update(context)
			expect(context.Motor.PlanarOnly).to.equal(true)
			expect(context.Motor.Velocity.Y).to.equal(0)
			expect(context.Motor.HipHeightDelta).to.equal(0)
		end)

		it("leaves the vertical axis to gravity off an edge", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			context.Ground.Grounded = false
			context.StateElapsed = 0.1
			Evading.Update(context)
			expect(context.Motor.PlanarOnly).to.equal(true)
		end)

		it("ends into ground locomotion when the glide is over", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			context.StateElapsed = EvadeConstants.DurationSeconds
			expect(Evading.Update(context)).to.equal("Idle")
		end)

		it("ends into Falling when the glide ran off an edge", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			context.Ground.Grounded = false
			context.StateElapsed = EvadeConstants.DurationSeconds
			expect(Evading.Update(context)).to.equal("Falling")
		end)
	end)

	describe("Evading.Exit", function()
		it("hands back nothing of its own with no input held", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			evadeExit(context, "Idle")
			expect(context.Momentum).to.equal(0)
			expect(context.Motor.Mode).to.equal("Humanoid")
			expect(context.AnimationVariant).to.equal(nil)
		end)

		it("hands back walking pace along held input", function()
			local context = pressedContext()
			evadeEnter(context, "Idle")
			context.MoveIntent = Vector3.new(0, 0, -1)
			evadeExit(context, "Walking")
			expect(context.Momentum).to.equal(ParkourConstants.Locomotion.WalkSpeed)
			expect(context.Motor.Velocity.Z < 0).to.equal(true)
		end)
	end)
end
