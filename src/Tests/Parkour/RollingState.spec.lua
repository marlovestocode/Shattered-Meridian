--!strict
-- Covers the roll: StateSupport.CanRoll (the one gate every route into Rolling asks), the two route-1
-- entries that used to skip it (Sliding's roll-out, Falling's contact frame), the late landing roll's
-- momentum refund, the ceiling hold, direction, facing, and the exit's momentum.
--
-- Contexts are built by hand, for the reason Tests/Parkour/DashState.spec sets out: every state here
-- reads what it needs off the context it is handed, so a hand-built table is an honest end-to-end
-- assertion of the real code without a live character or a frame loop. Every fixture starts from one
-- that PASSES, and each test overrides only the field it is about.
--
-- THE ROLL COOLDOWN IS MODULE STATE (StateSupport's), and it survives between tests -- so every test
-- takes its own `now` far enough ahead of the last that no earlier roll's cooldown is still live.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local InputBuffer = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.InputBuffer)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)
local StateSupport = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States.StateSupport)

local ROLL = ParkourConstants.Roll

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local Rolling = findDefinition("Rolling")
local Sliding = findDefinition("Sliding")
local Falling = findDefinition("Falling")
local Landing = findDefinition("Landing")
local rollEnter = assert(Rolling.Enter, "States/Rolling.lua must define Enter")
local rollExit = assert(Rolling.Exit, "States/Rolling.lua must define Exit")
local landingEnter = assert(Landing.Enter, "States/Landing.lua must define Enter")

local clock = 5000
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

-- Standing still on flat ground, not in combat, nothing overhead.
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
		CeilingClear = true,
		ApexHeight = 10,
		FallHeight = 0,
		LandingSeverity = nil,
		AnimationVariant = nil,
		PreLandingMomentum = nil,
		LandedAt = nil,
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

-- Runs Rolling.Update one DeltaTime at a time until it returns a transition or `maxSeconds` passes.
-- Returns the transition and the elapsed time it came at.
local function runRoll(context: any, maxSeconds: number): (string?, number)
	local start = context.Now
	local elapsed = 0
	while elapsed < maxSeconds do
		elapsed += context.DeltaTime
		context.Now = start + elapsed
		context.StateElapsed = elapsed
		local result = Rolling.Update(context)
		if result then
			return result, elapsed
		end
	end
	return nil, elapsed
end

return function()
	afterEach(function()
		InputBuffer.Clear()
	end)

	describe("StateSupport.CanRoll", function()
		it("accepts a buffered roll from a grounded, uncommitted character", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local ok, reason = StateSupport.CanRoll(makeContext(now))
			expect(reason).to.equal(nil)
			expect(ok).to.equal(true)
		end)

		it("allows a roll in combat -- it is the grounded dodge", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.InCombat = true
			expect(ParkourConstants.CombatGate.BlockedStates.Rolling).to.equal(nil)
			expect((StateSupport.CanRoll(context))).to.equal(true)
		end)

		it("refuses while committed to a swing or a stun", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.CombatCommitted = true
			local ok, reason = StateSupport.CanRoll(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("CombatCommitted")
		end)

		it("refuses inside the cooldown and accepts once it has passed", function()
			local now = nextNow()
			StateSupport.NoteRollStarted(now)
			InputBuffer.PressRoll(now + 0.1)
			local ok, reason = StateSupport.CanRoll(makeContext(now + 0.1))
			expect(ok).to.equal(false)
			expect(reason).to.equal("RollCooldown")

			local later = now + ROLL.CooldownSeconds + 0.01
			InputBuffer.PressRoll(later)
			expect((StateSupport.CanRoll(makeContext(later)))).to.equal(true)
		end)

		it("refuses in the air, however close the ground is", function()
			-- The old CanEnter admitted an airborne roll while merely NearGround, which is how a landing
			-- roll came to start in the air and float.
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.CurrentStateId = "Falling"
			context.Ground.Grounded = false
			context.Ground.NearGround = true
			local ok, reason = StateSupport.CanRoll(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotGrounded")
		end)

		it("refuses from a state not on the allowed list", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.CurrentStateId = "WallRunning"
			local ok, reason = StateSupport.CanRoll(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotAllowedFromThisState")
		end)

		it("widens only for a caller that passes the landing window", function()
			-- A press older than the shared action buffer but inside the landing window: dead to an
			-- ordinary ask, live to the contact frame's.
			expect(ROLL.LandingWindowSeconds > ParkourConstants.Assists.ActionBufferSeconds).to.equal(true)
			local now = nextNow()
			local age = (ROLL.LandingWindowSeconds + ParkourConstants.Assists.ActionBufferSeconds) / 2
			InputBuffer.PressRoll(now - age)
			local context = makeContext(now)
			expect((StateSupport.CanRoll(context))).to.equal(false)
			expect((StateSupport.CanRoll(context, ROLL.LandingWindowSeconds))).to.equal(true)
		end)

		it("is what Rolling.CanEnter answers with", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.CombatCommitted = true
			local ok, reason = Rolling.CanEnter(context)
			expect(ok).to.equal(false)
			expect(reason).to.equal("CombatCommitted")
		end)
	end)

	describe("Route-1 entries into Rolling", function()
		local function slidingContext(now: number): any
			local context = makeContext(now)
			context.CurrentStateId = "Sliding"
			context.Momentum = 30
			context.PlanarSpeed = 30
			context.MoveDirection = Vector3.new(0, 0, -1)
			context.StateElapsed = 0.05
			return context
		end

		it("rolls out of a slide when the roll is available", function()
			local now = nextNow()
			InputBuffer.PressSlide(now)
			InputBuffer.PressRoll(now)
			expect(Sliding.Update(slidingContext(now))).to.equal("Rolling")
		end)

		it("does NOT roll out of a slide inside the roll cooldown", function()
			-- The bypass this closes: Sliding's exit used to ask only the combat gate, so slide -> roll
			-- ignored the roll's cooldown entirely.
			local now = nextNow()
			StateSupport.NoteRollStarted(now - 0.1)
			InputBuffer.PressSlide(now)
			InputBuffer.PressRoll(now)
			expect(Sliding.Update(slidingContext(now))).never.to.equal("Rolling")
		end)

		it("turns a landing into a roll on the contact frame, with no severity published", function()
			local now = nextNow()
			-- Pressed just before touchdown, and older than the shared action buffer -- only the landing
			-- window admits it.
			InputBuffer.PressRoll(now - (ROLL.LandingWindowSeconds - 0.005))
			local context = makeContext(now)
			context.CurrentStateId = "Falling"
			context.ApexHeight = 60 -- a hard fall's worth of drop
			context.Momentum = 34
			context.PlanarSpeed = 34
			expect(Falling.Update(context)).to.equal("Rolling")
			expect(context.LandingSeverity).to.equal(nil)
			expect(context.FallHeight).to.equal(0)
		end)

		it("still lands normally with no roll pressed", function()
			local now = nextNow()
			local context = makeContext(now)
			context.CurrentStateId = "Falling"
			context.ApexHeight = 60
			expect(Falling.Update(context)).to.equal("Landing")
			expect(context.LandingSeverity).never.to.equal(nil)
		end)
	end)

	describe("Rolling.Enter", function()
		it("refunds the landing cut for a late roll inside the window", function()
			local now = nextNow()
			local context = makeContext(now)
			context.Momentum = 40
			context.LandingSeverity = "Hard"
			landingEnter(context, "Falling")
			expect(context.Momentum < 40).to.equal(true)

			context.Now = now + ROLL.LandingWindowSeconds * 0.5
			InputBuffer.PressRoll(context.Now)
			context.CurrentStateId = "Rolling"
			rollEnter(context, "Landing")
			expect(context.Momentum).to.equal(40)
			expect(context.PreLandingMomentum).to.equal(nil)
			expect(context.LandedAt).to.equal(nil)
		end)

		it("does not refund a roll taken after the window", function()
			local now = nextNow()
			local context = makeContext(now)
			context.Momentum = 40
			context.LandingSeverity = "Hard"
			landingEnter(context, "Falling")
			local afterCut = context.Momentum

			context.Now = now + ROLL.LandingWindowSeconds + 0.05
			InputBuffer.PressRoll(context.Now)
			rollEnter(context, "Landing")
			-- The roll's own burst floor still applies; the refund does not.
			expect(context.Momentum).to.equal(math.max(afterCut, ROLL.Speed))
		end)

		it("rolls where the player is steering, not where they were moving", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.MoveDirection = Vector3.new(0, 0, -1) -- sprinting forward
			context.PlanarSpeed = 30
			context.MoveIntent = Vector3.new(1, 0, 0) -- stick already pulled right
			rollEnter(context, "Sprinting")
			Rolling.Update(context)
			local velocity = context.Motor.Velocity
			local planar = Vector3.new(velocity.X, 0, velocity.Z).Unit
			expect(planar.X > 0.99).to.equal(true)
		end)

		it("keeps its facing in combat and reads as a sideways roll", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.InCombat = true
			context.MoveIntent = Vector3.new(-1, 0, 0) -- left of a -Z facing
			rollEnter(context, "Idle")
			expect(context.AnimationVariant).to.equal("Left")
			Rolling.Update(context)
			local face = context.Motor.FaceDirection
			expect(face.Z < -0.99).to.equal(true)
		end)

		it("turns into the roll out of combat", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.MoveIntent = Vector3.new(1, 0, 0)
			rollEnter(context, "Idle")
			expect(context.AnimationVariant).to.equal("Forward")
			Rolling.Update(context)
			expect(context.Motor.FaceDirection.X > 0.99).to.equal(true)
		end)

		it("starts the shared cooldown, so no route can chain a second roll", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			rollEnter(makeContext(now), "Idle")
			InputBuffer.PressRoll(now + 0.1)
			local ok, reason = StateSupport.CanRoll(makeContext(now + 0.1))
			expect(ok).to.equal(false)
			expect(reason).to.equal("RollCooldown")
		end)
	end)

	describe("Rolling.Update", function()
		it("drives the horizontal plane only once it has left the ground", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.MoveIntent = Vector3.new(0, 0, -1)
			rollEnter(context, "Walking")
			Rolling.Update(context)
			expect(context.Motor.PlanarOnly).to.equal(false)
			expect(context.Motor.Velocity.Y < 0).to.equal(true) -- the surface stick

			context.Ground.Grounded = false
			Rolling.Update(context)
			expect(context.Motor.PlanarOnly).to.equal(true)
		end)

		it("ends on time when nothing is overhead", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			rollEnter(context, "Idle")
			local result, at = runRoll(context, ROLL.DurationSeconds + 0.2)
			expect(result).to.equal("Idle")
			expect(at >= ROLL.DurationSeconds).to.equal(true)
			expect(at < ROLL.DurationSeconds + 0.05).to.equal(true)
		end)

		it("hands a dead-end ceiling hold to the slide within the cap", function()
			-- The softlock: under a ceiling with nowhere to go, this used to hold forever.
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.CeilingClear = false
			rollEnter(context, "Idle")
			local cap = ROLL.DurationSeconds + ROLL.MaxCeilingHoldSeconds
			local result, at = runRoll(context, cap + 0.5)
			expect(result).to.equal("Sliding")
			expect(at <= cap + context.DeltaTime * 1.5).to.equal(true)
		end)

		it("crawls in the held direction while the ceiling holds it", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.CeilingClear = false
			context.MoveIntent = Vector3.new(0, 0, -1)
			rollEnter(context, "Idle")
			runRoll(context, ROLL.DurationSeconds + 0.1)
			expect(context.Momentum).to.equal(ROLL.CrawlSpeed)
		end)
	end)

	describe("Rolling.Exit", function()
		it("returns the momentum it was entered with, not the roll's burst", function()
			-- A roll from a standstill used to hand 30 studs/s into Idle -- faster than walking.
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			rollEnter(context, "Idle")
			expect(context.Momentum).to.equal(ROLL.Speed)
			rollExit(context, "Idle")
			expect(context.Momentum).to.equal(0)
		end)

		it("floors at walking pace while a direction is held", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.MoveIntent = Vector3.new(0, 0, -1)
			rollEnter(context, "Idle")
			rollExit(context, "Walking")
			expect(context.Momentum).to.equal(ParkourConstants.Locomotion.WalkSpeed)
		end)

		it("carries a sprint's momentum through", function()
			local now = nextNow()
			InputBuffer.PressRoll(now)
			local context = makeContext(now)
			context.Momentum = 34
			context.MoveIntent = Vector3.new(0, 0, -1)
			rollEnter(context, "Sprinting")
			rollExit(context, "Sprinting")
			expect(context.Momentum).to.equal(34 * ROLL.ExitRetainFraction)
		end)
	end)

	describe("Roll tuning relationships", function()
		it("never crouches deeper than the slide it can hand a ceiling hold to", function()
			-- A slide standing taller than the roll it inherited would stand up into the very geometry
			-- the roll was ducking. See Roll.HipHeightDelta's own comment.
			expect(ROLL.HipHeightDelta <= ParkourConstants.Slide.HipHeightDelta).to.equal(true)
		end)
	end)
end
