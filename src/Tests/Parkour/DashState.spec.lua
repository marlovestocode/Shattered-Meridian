--!strict
-- Covers States/Dashing.lua's entry gate and the tuning table behind it.
--
-- The CanEnter contexts are built by hand rather than driven through ParkourController, for the reason
-- Tests/Parkour/StateFacingGates.spec sets out at length: CanEnter is contractually side-effect free
-- (StateMachine.lua) and reads everything from the context it is handed, so a hand-built table is an
-- honest end-to-end assertion of the real predicate without a live character, a probe pass or a frame
-- loop. Every fixture below starts from a context that PASSES, and each test overrides only the field
-- it is about, so any refusal is unambiguous.
--
-- The tuning block at the bottom asserts RELATIONSHIPS between constants rather than their values.
-- Those relationships are the design -- "a back dash is defensive", "a front dash never costs
-- momentum", "the reported window covers the longest direction" -- and every one of them is
-- invisible to a reader retuning a single number.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local RunLadder = require(ReplicatedStorage.Shared.Run.RunLadder)
local InputBuffer = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.InputBuffer)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local DASH = ParkourConstants.Dash
-- Asked of the ladder rather than written out, so a fourth gear added to RunConstants.Stages
-- automatically tightens the ceiling assertion below instead of leaving it checking a stale gear.
local RUN_TOP_GEAR_SPEED = ParkourConstants.Locomotion.WalkSpeed * RunLadder.SpeedMultiplier(RunLadder.MaxStage())

local function findDefinition(id: string)
	for _, definition in States do
		if definition.Id == id then
			return definition
		end
	end
	error(`no state definition registered for {id}`)
end

local Dashing = findDefinition("Dashing")
-- Enter is optional on StateDefinition, so it is pulled out through an assert rather than called off
-- the definition table -- which keeps this file honest under --!strict and turns "somebody deleted
-- Enter" into a clear failure here rather than a nil-call three tests down.
local dashEnter = assert(Dashing.Enter, "States/Dashing.lua must define Enter")
local dashUpdate = assert(Dashing.Update, "States/Dashing.lua must define Update")

-- A real BasePart for the same reason StateFacingGates builds one: Enter reads RootPart.CFrame's
-- LookVector and RightVector to resolve the quadrant, and a stub would assert against our own
-- arithmetic rather than the engine's.
local function makeRootPart(): BasePart
	local part = Instance.new("Part")
	part.Size = Vector3.new(2, 5, 1)
	part.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1))
	return part
end

-- Everything upstream of the gate under test, set to values that pass. Airborne by default -- Dash is
-- AIR-ONLY (CanEnter refuses outright while grounded, see States/Dashing.lua), so a fixture that is
-- meant to PASS has to already be off the ground. Tests of the grounded refusal override Ground.Grounded
-- explicitly.
local function makeContext(now: number): any
	return {
		RootPart = makeRootPart(),
		Now = now,
		DeltaTime = 1 / 60,
		StateElapsed = 0,
		CurrentStateId = "Falling",
		PreviousStateId = "Jumping",
		MoveIntent = Vector3.new(0, 0, -1),
		-- Level, matching the fixture's facing (-Z) -- keeps every existing test resolving one of the
		-- four facing-relative quadrants exactly as before. Tests of the Up quadrant override this.
		AimDirection = Vector3.new(0, 0, -1),
		Momentum = 27,
		VerticalVelocity = 0,
		AirDashChain = 0,
		InCombat = false,
		Ground = { Grounded = false, NearGround = true, Distance = 0, Normal = Vector3.yAxis },
		AnimationVariant = nil,
		LandingSeverity = nil,
		FallHeight = 0,
		-- Zero (never chained) by default -- see States/WallLaunching.lua and Dash.WallLaunchChainExtraHangSeconds'
		-- own comments. Tests of the chain boost set this to a live deadline explicitly.
		WallLaunchDashBoostUntil = 0,
		Motor = {},
	}
end

return function()
	describe("Dashing.CanEnter", function()
		-- Every test presses at its own `now`, and the cooldown is module state that survives between
		-- them, so each one moves far enough forward that no previous test's cooldown is still live.
		local clock = 1000
		local function nextNow(): number
			clock += 10
			return clock
		end

		it("accepts from every state Dash.AllowedFromStates names", function()
			-- Every named state is itself an airborne one now (Jumping, Falling) -- Dash's own
			-- CanEnter refuses unconditionally while grounded (see the dedicated test below), so this
			-- has to be tested airborne or it would be passing for the wrong reason.
			for stateId in DASH.AllowedFromStates :: { [string]: boolean } do
				local now = nextNow()
				local context = makeContext(now)
				context.CurrentStateId = stateId
				context.Ground.Grounded = false
				InputBuffer.PressDash(now)
				local allowed, reason = Dashing.CanEnter(context)
				expect(allowed).to.equal(true, `{stateId}: {tostring(reason)}`)
			end
			InputBuffer.Clear()
		end)

		it("refuses from a state the table does not name", function()
			local now = nextNow()
			local context = makeContext(now)
			context.CurrentStateId = "WallRunning"
			InputBuffer.PressDash(now)
			local allowed, reason = Dashing.CanEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NotAllowedFromThisState")
			InputBuffer.Clear()
		end)

		it("refuses with no buffered press", function()
			InputBuffer.Clear()
			local allowed, reason = Dashing.CanEnter(makeContext(nextNow()))
			expect(allowed).to.equal(false)
			expect(reason).to.equal("NoDashInput")
		end)

		it("does not consume the press -- CanEnter is a pure predicate", function()
			-- The overlay calls CanEnter on every registered state on a timer. A consuming predicate
			-- would eat the player's dash presses for as long as ParkourDebug was open, which is
			-- precisely when it is hardest to attribute -- see InputBuffer.lua's Peek/Consume contract.
			local now = nextNow()
			InputBuffer.PressDash(now)
			for index = 1, 5 do
				expect(Dashing.CanEnter(makeContext(now))).to.equal(true, `call {index}`)
			end
			InputBuffer.Clear()
		end)

		it("refuses a second dash inside the cooldown, and allows one after it", function()
			local now = nextNow()
			local context = makeContext(now)
			InputBuffer.PressDash(now)
			expect(Dashing.CanEnter(context)).to.equal(true)
			dashEnter(context, "Sprinting")

			local retry = makeContext(now + 0.05)
			InputBuffer.PressDash(now + 0.05)
			local allowed, reason = Dashing.CanEnter(retry)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("DashCooldown")

			-- Past the longest cooldown of any direction, so this holds whichever quadrant the fixture
			-- happened to resolve to.
			local later = now + DASH.Directions.Back.CooldownSeconds + 0.01
			local afterwards = makeContext(later)
			InputBuffer.PressDash(later)
			expect(Dashing.CanEnter(afterwards)).to.equal(true)
			InputBuffer.Clear()
		end)

		it("refuses an air dash once the charge is spent", function()
			local now = nextNow()
			local context = makeContext(now)
			context.CurrentStateId = "Falling"
			context.Ground.Grounded = false
			context.AirDashChain = DASH.AirCharges
			InputBuffer.PressDash(now)
			local allowed, reason = Dashing.CanEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("AirDashesExhausted")
			InputBuffer.Clear()
		end)

		it("refuses unconditionally while grounded, regardless of cooldown, input, or air charge", function()
			-- Pressing Q while standing on solid ground used to still fire a dash (with the
			-- SurfaceStickSpeed bias in Update dragging the body along the floor) -- Dash is the
			-- framework's AIRBORNE chaining move, Rolling already owns the grounded dodge, and a burst
			-- that fights the surface the whole way reads as a bug, not a mechanic. This must hold even
			-- with every other gate wide open.
			local now = nextNow()
			local context = makeContext(now)
			context.Ground.Grounded = true
			context.AirDashChain = 0
			InputBuffer.PressDash(now)
			local allowed, reason = Dashing.CanEnter(context)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("MustBeAirborne")
			InputBuffer.Clear()
		end)

		it("still accepts while in combat -- the dash is deliberately not combat-gated", function()
			-- ParkourConstants.CombatGate.BlockedStates lists Rolling but NOT Dashing, on purpose:
			-- blocking both would leave a fighting player with no evasive movement at all. This test
			-- is the record of that being a decision rather than an omission -- if Dashing is ever
			-- added to that roster, this is the test that should be rewritten to say so.
			local now = nextNow()
			local context = makeContext(now)
			context.InCombat = true
			InputBuffer.PressDash(now)
			expect(Dashing.CanEnter(context)).to.equal(true)
			InputBuffer.Clear()
		end)
	end)

	describe("Dashing.Enter", function()
		it("resolves the quadrant off body facing and publishes it as the animation variant", function()
			local now = 5000
			local context = makeContext(now)
			-- Facing -Z, intent +Z: a back dash. Facing is what decides, not the world axis.
			context.MoveIntent = Vector3.new(0, 0, 1)
			InputBuffer.PressDash(now)
			dashEnter(context, "Sprinting")
			expect(context.AnimationVariant).to.equal("Back")
			InputBuffer.Clear()
		end)

		it("replaces a forward dash with Up when airborne and the camera is pitched steeply up", function()
			local now = 5050
			local context = makeContext(now)
			context.CurrentStateId = "Falling"
			context.Ground.Grounded = false
			-- No directional intent, so the quadrant would otherwise resolve to Front -- exactly the
			-- case Dash.UpPitchDegrees exists to redirect.
			context.MoveIntent = Vector3.zero
			context.AimDirection = Vector3.new(0, 1, 0)
			InputBuffer.PressDash(now)
			dashEnter(context, "Falling")
			expect(context.AnimationVariant).to.equal("Up")
			InputBuffer.Clear()
		end)

		it("leaves a back/left/right dash alone even while airborne and looking straight up", function()
			-- ParkourMath.DashQuadrant's own header: the pitch gate only ever replaces FRONT. A player
			-- retreating from something must not have that retreat redirected into the sky just because
			-- they happened to be looking up while climbing.
			local now = 5060
			local context = makeContext(now)
			context.CurrentStateId = "Falling"
			context.Ground.Grounded = false
			context.MoveIntent = Vector3.new(0, 0, 1)
			context.AimDirection = Vector3.new(0, 1, 0)
			InputBuffer.PressDash(now)
			dashEnter(context, "Falling")
			expect(context.AnimationVariant).to.equal("Back")
			InputBuffer.Clear()
		end)

		it("always spends an air charge -- every dash is airborne now", function()
			local now = 5100
			local context = makeContext(now)
			InputBuffer.PressDash(now)
			dashEnter(context, "Falling")
			expect(context.AirDashChain).to.equal(1)
			InputBuffer.Clear()
		end)

		it("holds an Up dash's vertical velocity higher, for longer, when chained off a wall launch", function()
			-- Simulates real frame-by-frame Update ticks rather than jumping straight to a StateElapsed
			-- -- the hang's gravity integration (Dashing.lua's Update) only advances one DeltaTime per
			-- call, exactly like the real controller drives it, so a single big timestep would not
			-- exercise the same code path a live frame loop does.
			local function verticalVelocityAt(elapsedTarget: number, chained: boolean): number
				local now = 6000
				local context = makeContext(now)
				context.MoveIntent = Vector3.zero
				context.AimDirection = Vector3.new(0, 1, 0)
				context.WallLaunchDashBoostUntil = if chained then now + 10 else 0
				InputBuffer.PressDash(now)
				dashEnter(context, "Falling")
				expect(context.AnimationVariant).to.equal("Up")

				local elapsed = 0
				while elapsed < elapsedTarget do
					elapsed += context.DeltaTime
					context.Now = now + elapsed
					context.StateElapsed = elapsed
					dashUpdate(context)
				end
				InputBuffer.Clear()
				return context.Motor.Velocity.Y
			end

			-- Between DASH.UpAirHangSeconds (0.2) and DASH.UpAirHangSeconds + WallLaunchChainExtraHangSeconds
			-- (0.35): the ordinary hang has already released into gravity by this point, but the chained
			-- one has not, so the chained case must still be commanding the higher, undecayed value.
			local target = DASH.UpAirHangSeconds + DASH.WallLaunchChainExtraHangSeconds / 2
			local plain = verticalVelocityAt(target, false)
			local chained = verticalVelocityAt(target, true)
			expect(chained > plain).to.equal(true)
		end)

		it("cancels the fall's landing cost, exactly as a roll does", function()
			local now = 5200
			local context = makeContext(now)
			context.LandingSeverity = "Hard"
			context.FallHeight = 40
			InputBuffer.PressDash(now)
			dashEnter(context, "Landing")
			expect(context.LandingSeverity).to.equal(nil)
			expect(context.FallHeight).to.equal(0)
			InputBuffer.Clear()
		end)

		it("publishes the peak, not the exit speed, as the momentum the report will carry", function()
			-- ParkourController.reportTransition reads context.Momentum AFTER Enter runs, so this is
			-- what the server is told. Claiming the exit speed there would under-report the action by
			-- most of its own magnitude.
			local now = 5300
			local context = makeContext(now)
			InputBuffer.PressDash(now)
			dashEnter(context, "Sprinting")
			expect(context.Momentum > 27).to.equal(true)
			expect(context.Momentum <= DASH.MaxSpeed).to.equal(true)
			InputBuffer.Clear()
		end)
	end)

	describe("Dash tuning", function()
		it("keeps the peak inside the validator's reported-speed ceiling from any entry speed", function()
			-- The failure this catches is the one ParkourConstants.Validation.MaxReportedSpeed's own
			-- header records having already happened once with the slide: a distance retune pushes the
			-- honest peak past the ceiling, and players on the top run gear start having their own
			-- movement rejected -- which reads in play as the character sticking and stuttering.
			local ceiling = ParkourConstants.Validation.MaxReportedSpeed
			expect(DASH.MaxSpeed < ceiling).to.equal(true)
			expect(ceiling / DASH.MaxSpeed >= 1.4).to.equal(true)
			for name, tuning in DASH.Directions do
				local endSpeed = math.max(RUN_TOP_GEAR_SPEED * tuning.ExitRetainFraction, DASH.MinExitSpeed)
				local peak =
					ParkourMath.BurstPeak(tuning.DistanceStuds, tuning.DurationSeconds, endSpeed, DASH.MaxSpeed)
				expect(peak < ceiling).to.equal(true, name)
			end
		end)

		it("never makes the dash the fastest thing in the game", function()
			expect(DASH.MaxSpeed <= ParkourConstants.Leap.MaxPlanarSpeed).to.equal(true)
		end)

		it("keeps every direction inside the window the server is told about", function()
			-- ParkourController.ACTION_DURATIONS derives the declared ownership window from
			-- MaxDurationSeconds. A direction longer than it would have its window force-expired
			-- server-side mid-burst, which is the "player frozen" failure ParkourValidation documents.
			for name, tuning in DASH.Directions do
				expect(tuning.DurationSeconds <= DASH.MaxDurationSeconds).to.equal(true, name)
				expect(tuning.DurationSeconds > 0).to.equal(true, name)
				expect(tuning.DistanceStuds > 0).to.equal(true, name)
			end
		end)

		it("makes the defensive directions actually defensive", function()
			-- Three numbers saying the same thing, because a back dash that is merely a shorter front
			-- dash becomes a strictly better way to travel and the movement meta collapses into
			-- backward hopping -- which the deleted combat system's own DashBackCooldownSeconds (1.6
			-- against a 0.8 front) is this codebase's record of having already paid for.
			local front, back = DASH.Directions.Front, DASH.Directions.Back
			expect(back.CooldownSeconds > front.CooldownSeconds).to.equal(true)
			expect(back.DistanceStuds < front.DistanceStuds).to.equal(true)
			expect(back.ExitRetainFraction < front.ExitRetainFraction).to.equal(true)
		end)

		it("mirrors the sides exactly -- a better side to dash is a bug, not a mechanic", function()
			local left, right = DASH.Directions.Left, DASH.Directions.Right
			expect(left.DistanceStuds).to.equal(right.DistanceStuds)
			expect(left.DurationSeconds).to.equal(right.DurationSeconds)
			expect(left.CooldownSeconds).to.equal(right.CooldownSeconds)
			expect(left.ExitRetainFraction).to.equal(right.ExitRetainFraction)
		end)

		it("never charges the front dash any momentum", function()
			-- The chaining direction. If it cost speed, the optimal play at any real pace would be to
			-- never press it, and the whole state would be dead weight beside Rolling.
			expect(DASH.Directions.Front.ExitRetainFraction).to.equal(1)
		end)

		it("leaves a standing dash moving without making it worth taking for the speed", function()
			expect(DASH.MinExitSpeed > ParkourConstants.Locomotion.WalkSpeed).to.equal(true)
			expect(DASH.MinExitSpeed < ParkourConstants.Locomotion.SprintSpeed).to.equal(true)
		end)

		it("keeps the air hang a phase of the dash rather than the whole of it", function()
			expect(DASH.AirCharges >= 1).to.equal(true)
			expect(DASH.AirHangSeconds > 0).to.equal(true)
			for name, tuning in DASH.Directions do
				local hangSeconds = if name == "Up" then DASH.UpAirHangSeconds else DASH.AirHangSeconds
				expect(hangSeconds < tuning.DurationSeconds).to.equal(true, name)
			end
		end)

		it("gives Up more oomph and a longer hang than an ordinary air dash", function()
			-- The launch has to visibly outdo a flat dash to read as powerful rather than as a stumble
			-- upward, and it has to hang at its peak longer than the other four or gravity reasserts
			-- itself the instant the burst ends -- see States/Dashing.lua's Enter for how both feed
			-- into the actual velocity curve.
			expect(DASH.Directions.Up.DistanceStuds > DASH.Directions.Front.DistanceStuds).to.equal(true)
			expect(DASH.UpAirHangSeconds > DASH.AirHangSeconds).to.equal(true)
			-- Everything else about Up matches Front -- it is the SAME chaining privilege, merely
			-- redirected by the camera, not a strictly better or worse move.
			expect(DASH.Directions.Up.CooldownSeconds).to.equal(DASH.Directions.Front.CooldownSeconds)
			expect(DASH.Directions.Up.ExitRetainFraction).to.equal(DASH.Directions.Front.ExitRetainFraction)
		end)

		it("names WallLaunching as a dash origin, so the wall-launch combo can actually chain", function()
			expect((DASH.AllowedFromStates :: { [string]: boolean }).WallLaunching).to.equal(true)
		end)

		it("keeps the wall-launch chain boost a real but modest addition to Up's own hang", function()
			expect(DASH.WallLaunchChainExtraHangSeconds > 0).to.equal(true)
			expect(DASH.WallLaunchChainExtraHangSeconds < DASH.UpAirHangSeconds).to.equal(true)
		end)

		it("authors an animation slot for every direction", function()
			-- ParkourAnimator gives Dashing no STATE_CLIPS fallback on purpose (playing a front-dash
			-- clip for a back dash reads worse than playing nothing), so a direction with no key at
			-- all in AnimationIds would be permanently silent with nothing to notice it. A blank
			-- VALUE is fine and expected -- that is "not authored yet"; a missing KEY is not.
			for name in DASH.Directions do
				expect(ParkourConstants.AnimationIds[`Dash{name}`]).to.be.ok(name)
			end
		end)
	end)
end
