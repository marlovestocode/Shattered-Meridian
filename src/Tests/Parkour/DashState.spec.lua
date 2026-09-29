--!strict
-- Covers States/Dashing.lua -- its entry gate, its launch/steer/spring behaviour, and the tuning
-- relationships behind all three.
--
-- The CanEnter contexts are built by hand rather than driven through ParkourController, for the reason
-- Tests/Parkour/StateFacingGates.spec sets out at length: CanEnter is contractually side-effect free
-- (StateMachine.lua) and reads everything from the context it is handed, so a hand-built table is an
-- honest end-to-end assertion of the real predicate without a live character, a probe pass or a frame
-- loop. Every fixture below starts from a context that PASSES, and each test overrides only the field
-- it is about, so any refusal is unambiguous.
--
-- THE FLIGHT TESTS DRIVE REAL PER-FRAME UPDATE TICKS, one DeltaTime at a time, exactly as the real
-- controller does. That is not ceremony: the steer, the spring and the hang are all INTEGRATORS, and
-- each advances by exactly one step per call. Jumping straight to a large StateElapsed would produce
-- a number this state can never actually reach in play, and would pass against implementations that
-- are wrong every frame in between.
--
-- The tuning block at the bottom asserts RELATIONSHIPS between constants rather than their values.
-- Those relationships are the design -- "a dash must never cost speed", "the reported window covers
-- the flight", "the hang is a phase of the dash, not the whole of it" -- and every one of them is
-- invisible to a reader retuning a single number.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local InputBuffer = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.InputBuffer)
local States = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.States)

local DASH = ParkourConstants.Dash

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
-- LookVector as the fallback for a missing aim, and Exit reads AssemblyLinearVelocity -- a stub would
-- assert against our own arithmetic rather than the engine's.
local function makeRootPart(): BasePart
	local part = Instance.new("Part")
	part.Size = Vector3.new(2, 5, 1)
	part.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1))
	return part
end

-- Everything upstream of the gate under test, set to values that pass. Airborne by default -- Dash is
-- AIR-ONLY (CanEnter refuses outright while grounded, see States/Dashing.lua), so a fixture that is
-- meant to PASS has to already be off the ground. Tests of the grounded refusal override
-- Ground.Grounded explicitly.
local function makeContext(now: number): any
	return {
		RootPart = makeRootPart(),
		Now = now,
		DeltaTime = 1 / 60,
		StateElapsed = 0,
		CurrentStateId = "Falling",
		PreviousStateId = "Jumping",
		-- Present, and deliberately CROSSWISE to the default aim below. The dash does not read it at
		-- all any more; several tests assert exactly that by checking the launch ignores it.
		MoveIntent = Vector3.new(1, 0, 0),
		-- Level and forward. THE launch vector -- there is no quadrant and no pitch gate any more, so
		-- whatever this says is where the dash goes.
		AimDirection = Vector3.new(0, 0, -1),
		Momentum = 27,
		VerticalVelocity = 0,
		AirDashChain = 0,
		InCombat = false,
		Ground = { Grounded = false, NearGround = true, Distance = 0, Normal = Vector3.yAxis },
		AnimationVariant = nil,
		LandingSeverity = nil,
		FallHeight = 0,
		-- Zero (never chained) by default -- see States/WallLaunching.lua and
		-- Dash.WallLaunchChainExtraHangSeconds' own comments. Tests of the chain boost set this to a
		-- live deadline explicitly.
		WallLaunchDashBoostUntil = 0,
		Motor = {},
	}
end

-- Runs a real dash for `seconds` of frame-by-frame Update ticks, one DeltaTime per call. `onFrame`
-- observes each frame after the state has written to the motor. Returns the context so callers can
-- read its final state.
local function flyDash(context: any, seconds: number, onFrame: ((any, number) -> ())?): any
	local start = context.Now
	InputBuffer.PressDash(start)
	dashEnter(context, context.PreviousStateId)
	InputBuffer.Clear()

	local elapsed = 0
	while elapsed < seconds do
		elapsed += context.DeltaTime
		context.Now = start + elapsed
		context.StateElapsed = elapsed
		dashUpdate(context)
		if onFrame then
			onFrame(context, elapsed)
		end
	end
	return context
end

local function angleBetween(a: Vector3, b: Vector3): number
	return math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1))
end

-- The HORIZONTAL heading the dash is flying, read off the commanded velocity.
--
-- Flattened deliberately, and only safe because every steering fixture below aims LEVEL: past
-- Dash.AirHangSeconds the hang releases and the state starts integrating gravity into the commanded
-- vector, so the raw velocity direction pitches steadily downward for the rest of the flight. A test
-- that measured the raw direction over a full flight would be measuring gravity and calling it
-- steering. The steer's own authority is what these tests are about, so the vertical is dropped --
-- with level aims, travel has no vertical of its own for this to discard.
local function heading(context: any): Vector3
	local velocity = context.Motor.Velocity
	return Vector3.new(velocity.X, 0, velocity.Z).Unit
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
			-- Every named state is itself an airborne one -- Dash's own CanEnter refuses
			-- unconditionally while grounded (see the dedicated test below), so this has to be tested
			-- airborne or it would be passing for the wrong reason.
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
			dashEnter(context, "Falling")

			local retry = makeContext(now + 0.05)
			InputBuffer.PressDash(now + 0.05)
			local allowed, reason = Dashing.CanEnter(retry)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("DashCooldown")

			-- ONE cooldown constant now, where this used to have to reach for the longest of five
			-- per-direction rows.
			local later = now + DASH.CooldownSeconds + 0.01
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
			-- framework's AIRBORNE chaining move, Evading already owns the grounded dodge, and a burst
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
			-- ParkourConstants.CombatGate.BlockedStates does NOT list Dashing, on purpose (nor Evading):
			-- blocking either would take evasive movement away from a fighting player. This test
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

	describe("Dashing launch direction", function()
		-- THE REGRESSION GUARD FOR THIS ENTIRE REWRITE. The dash used to quantize onto one of four
		-- vectors off the body's facing, chosen by MoveIntent, with a fifth camera-aimed one that only
		-- unlocked past a 55-degree pitch gate. Every test in this block sets an aim that no quadrant
		-- could have produced and asserts the body goes there anyway -- and each one sets a MoveIntent
		-- pointing somewhere else entirely, because "the aim wins over the movement keys" is precisely
		-- the property that was not true before.
		local aims = {
			{ name = "level forward", aim = Vector3.new(0, 0, -1) },
			{ name = "level backward", aim = Vector3.new(0, 0, 1) },
			{ name = "level sideways", aim = Vector3.new(1, 0, 0) },
			{ name = "steeply up", aim = Vector3.new(0, 0.94, -0.34) },
			{ name = "steeply down", aim = Vector3.new(0, -0.94, -0.34) },
			{ name = "straight up", aim = Vector3.new(0, 1, 0) },
			{ name = "straight down", aim = Vector3.new(0, -1, 0) },
			-- The case no quadrant could express at all: an off-axis diagonal with pitch in it.
			{ name = "up-and-left diagonal", aim = Vector3.new(-0.6, 0.6, -0.53) },
		}

		for _, case in aims do
			it(`launches exactly along the aim -- {case.name}`, function()
				local context = makeContext(7000)
				context.AimDirection = case.aim
				-- Deliberately fighting the aim. A launch that reads this at all will fail below.
				context.MoveIntent = Vector3.new(0, 0, -1)
				flyDash(context, context.DeltaTime)

				local commanded = context.Motor.Velocity
				-- Frame one is inside the air hang, so the commanded vertical is the launch's own
				-- vertical component and nothing else -- no gravity term has been added yet. That is
				-- what lets this compare the raw direction rather than having to model the hang.
				expect(angleBetween(commanded, case.aim) < 0.01).to.equal(
					true,
					`{case.name}: commanded {tostring(commanded.Unit)} against aim {tostring(case.aim.Unit)}`
				)
			end)
		end

		it("ignores MoveIntent completely -- the same aim launches identically from any intent", function()
			-- Stated once directly, rather than only implied by the per-aim cases above: the four
			-- move-intent quadrants are gone, so intent cannot change the outcome by any amount.
			local intents = {
				Vector3.new(0, 0, -1),
				Vector3.new(0, 0, 1),
				Vector3.new(1, 0, 0),
				Vector3.new(-1, 0, 0),
				Vector3.zero,
			}
			local aim = Vector3.new(0.5, 0.5, -0.707)
			local reference: Vector3? = nil
			for index, intent in intents do
				local context = makeContext(7100 + index)
				context.AimDirection = aim
				context.MoveIntent = intent
				flyDash(context, context.DeltaTime)
				local commanded = context.Motor.Velocity
				if reference == nil then
					reference = commanded
				else
					expect(angleBetween(commanded, reference :: Vector3) < 1e-4).to.equal(
						true,
						`intent {index} steered the launch`
					)
				end
			end
		end)

		it("publishes the pitch band of the launch, not a body-relative direction", function()
			local bands = {
				{ aim = Vector3.new(0, 1, 0), band = "Up" },
				{ aim = Vector3.new(0, 0, -1), band = "Level" },
				{ aim = Vector3.new(0, -1, 0), band = "Down" },
			}
			for index, case in bands do
				local context = makeContext(7200 + index)
				context.AimDirection = case.aim
				InputBuffer.PressDash(context.Now)
				dashEnter(context, "Falling")
				expect(context.AnimationVariant).to.equal(case.band)
				InputBuffer.Clear()
			end
		end)

		it("holds the launch angle when the aim vector is unreadable", function()
			-- A zero aim is reachable for a frame during character bind. Falling back to the body's
			-- own look vector is the least surprising answer; producing a NaN direction is the one
			-- that would remove the character, since this vector is multiplied by a speed and written
			-- into a LinearVelocity constraint.
			local context = makeContext(7300)
			context.AimDirection = Vector3.zero
			flyDash(context, context.DeltaTime)
			local commanded = context.Motor.Velocity
			expect(commanded.Magnitude == commanded.Magnitude).to.equal(true, "NaN velocity")
			expect(commanded.Magnitude > 0).to.equal(true)
			expect(angleBetween(commanded, context.RootPart.CFrame.LookVector) < 0.01).to.equal(true)
		end)
	end)

	describe("Dashing steering", function()
		it("turns toward a moving aim, but never faster than the authored turn rate", function()
			-- Both halves matter and they fail in opposite directions. No turn at all is the frozen
			-- burst this replaced; an uncapped turn is a flying camera with a body attached, and the
			-- CAP is what makes the dash bank rather than pivot.
			local launchAim = Vector3.new(0, 0, -1)
			local steeredAim = Vector3.new(1, 0, 0) -- a full 90 degrees away
			local context = makeContext(7400)
			context.AimDirection = launchAim

			local maxRadiansPerSecond = math.rad(DASH.TurnDegreesPerSecond)
			flyDash(context, DASH.DurationSeconds / 2, function(ctx, elapsed)
				-- Swung onto the new aim immediately after the launch frame, so every subsequent
				-- frame is asking for the full 90 degrees at once.
				ctx.AimDirection = steeredAim
				local travel = heading(ctx)
				-- THE CAP. Measured from the LAUNCH direction against the total time elapsed, so an
				-- implementation that turned faster on any single frame is caught here even if it
				-- later settled onto the right heading.
				local turned = angleBetween(travel, launchAim)
				expect(turned <= maxRadiansPerSecond * elapsed + 1e-3).to.equal(
					true,
					`turned {math.deg(turned)} degrees in {elapsed}s`
				)
			end)

			-- THE OTHER HALF: it did actually turn, and by very close to the full budget. It does NOT
			-- arrive on a 90-degree swing, and must not -- see the arrival test below for why that is
			-- the design rather than a shortfall.
			local turned = angleBetween(heading(context), launchAim)
			expect(turned > maxRadiansPerSecond * (DASH.DurationSeconds / 2) * 0.9).to.equal(
				true,
				`only turned {math.deg(turned)} degrees against a budget of {DASH.TurnDegreesPerSecond / 2 * DASH.DurationSeconds}`
			)
		end)

		it("arrives exactly on an aim inside its turn budget", function()
			-- The other side of the cap: a turn the dash CAN afford has to land on the aim rather than
			-- approach it asymptotically. 30 degrees costs about 0.14s at the authored rate, well
			-- inside the full-authority window.
			local launchAim = Vector3.new(0, 0, -1)
			local steeredAim = Vector3.new(math.sin(math.rad(30)), 0, -math.cos(math.rad(30)))
			local context = makeContext(7420)
			context.AimDirection = launchAim
			flyDash(context, DASH.DurationSeconds / 2, function(ctx)
				ctx.AimDirection = steeredAim
			end)
			expect(angleBetween(heading(context), steeredAim) < 1e-3).to.equal(
				true,
				`ended {math.deg(angleBetween(heading(context), steeredAim))} degrees off an affordable aim`
			)
		end)

		it("cannot be reversed inside a single flight -- the cap is a real limit, not a smoothing", function()
			-- Dash.TurnDegreesPerSecond's own comment states the intent: enough authority to bank a
			-- dash around a corner, not enough to reverse one. The total available turn is the
			-- full-authority stretch plus HALF the release window (the taper is linear), and that
			-- budget being under 180 degrees is what makes a dash a commitment rather than a hover.
			local totalTurnDegrees = DASH.TurnDegreesPerSecond
				* ((DASH.DurationSeconds - DASH.SteerReleaseSeconds) + DASH.SteerReleaseSeconds / 2)
			expect(totalTurnDegrees < 180).to.equal(
				true,
				`a dash can turn {totalTurnDegrees} degrees, enough to reverse itself`
			)

			-- And the implementation agrees with that arithmetic: aiming a full 180 degrees back for
			-- the whole flight still leaves the dash pointed somewhere ahead of where it came from.
			local launchAim = Vector3.new(0, 0, -1)
			local context = makeContext(7440)
			context.AimDirection = launchAim
			flyDash(context, DASH.DurationSeconds, function(ctx)
				ctx.AimDirection = -launchAim
			end)
			local turned = math.deg(angleBetween(heading(context), launchAim))
			expect(turned <= totalTurnDegrees + 1).to.equal(true, `reversed {turned} degrees`)
		end)

		it("gives up all steering authority before the flight ends", function()
			-- Dash.SteerReleaseSeconds exists so the exit heading is committed and predictable: every
			-- downstream chain (the route-2 vault/mantle/wall-run/ledge pre-emptions, all of which
			-- gate on facing) inherits the final travel vector, and the last frame of a mouse sweep is
			-- the worst possible moment to sample.
			local context = makeContext(7500)
			context.AimDirection = Vector3.new(0, 0, -1)

			-- Measured PER FRAME rather than as a total drift from the release point. The taper is
			-- linear from full authority down to zero, so the release window legitimately integrates
			-- to about half a window's worth of turn -- roughly 11 degrees here. What must reach zero
			-- is the turn on the FINAL frame, and only a per-frame measurement can say that.
			local previous: Vector3? = nil
			local midFlightTurn = 0
			local finalTurn = 0
			flyDash(context, DASH.DurationSeconds, function(ctx, elapsed)
				-- A hard, continuous sweep for the whole flight -- maximum pressure on the taper.
				ctx.AimDirection = Vector3.new(1, 0, 0)
				local travel = heading(ctx)
				if previous then
					local turn = angleBetween(travel, previous :: Vector3)
					finalTurn = turn
					if elapsed < DASH.DurationSeconds - DASH.SteerReleaseSeconds then
						midFlightTurn = math.max(midFlightTurn, turn)
					end
				end
				previous = travel
			end)

			-- Mid-flight it was turning at the authored rate, so the taper below is a real release of
			-- authority rather than a dash that was never steering in the first place.
			local frameBudget = math.rad(DASH.TurnDegreesPerSecond) * context.DeltaTime
			expect(midFlightTurn > frameBudget * 0.9).to.equal(
				true,
				`never reached full authority: {math.deg(midFlightTurn)} degrees per frame`
			)
			-- And by the last frame it has none left. A tenth of a frame's budget is comfortably
			-- below anything the taper can still be granting at DurationSeconds.
			expect(finalTurn < frameBudget * 0.1).to.equal(
				true,
				`still turning {math.deg(finalTurn)} degrees on the final frame`
			)
		end)

		it("survives an aim flicked exactly antiparallel to the travel without producing a NaN", function()
			-- One hard mouse flick mid-dash reaches this, and the cross product ParkourMath.SteerToward
			-- rotates about is exactly zero there. A NaN in this vector does not error -- it is written
			-- into a LinearVelocity constraint and removes the character.
			local context = makeContext(7600)
			context.AimDirection = Vector3.new(0, 0, -1)
			flyDash(context, DASH.DurationSeconds / 2, function(ctx)
				ctx.AimDirection = Vector3.new(0, 0, 1)
				local velocity = ctx.Motor.Velocity
				expect(velocity.Magnitude == velocity.Magnitude).to.equal(true, "NaN velocity")
			end)
		end)

		it("faces where it is flying, and holds its yaw through a vertical dash", function()
			-- Facing follows LIVE travel now, where it used to be frozen at entry. The vertical case
			-- is the one that could go wrong loudly: a flattened straight-up travel vector is
			-- near-zero, and ParkourMotor.applyFacing's own early-return is what keeps that from
			-- becoming a snap to an arbitrary heading.
			local level = makeContext(7700)
			level.AimDirection = Vector3.new(1, 0, 0)
			flyDash(level, level.DeltaTime)
			expect(angleBetween(level.Motor.FaceDirection, Vector3.new(1, 0, 0)) < 0.01).to.equal(true)

			local vertical = makeContext(7710)
			vertical.AimDirection = Vector3.new(0, 1, 0)
			flyDash(vertical, vertical.DeltaTime)
			-- Flattened to nothing, which applyFacing reads as "hold what you have". The contract this
			-- asserts is that the state hands over a degenerate vector rather than a wrong one.
			expect(vertical.Motor.FaceDirection.Magnitude < 1e-3).to.equal(true)
		end)
	end)

	describe("Dashing speed spring", function()
		it("overshoots the launch target -- the overshoot is the mass cue", function()
			-- Dash.LaunchDamping is below 1 on purpose. If a retune drives it to 1 or above, the dash
			-- silently goes back to being a stamp with a ramp on it, and nothing else in the codebase
			-- would notice. Note the realized overshoot is small (about 1 percent at 60Hz) because
			-- FlightMath.SpringStep integrates implicitly -- see Dash.LaunchSpeed's own comment for
			-- the measured figures. This asserts the property, not a magnitude.
			local context = makeContext(7800)
			local peak = 0
			flyDash(context, DASH.DurationSeconds, function(ctx)
				peak = math.max(peak, ctx.Momentum)
			end)
			expect(peak > DASH.LaunchSpeed).to.equal(true, `peak {peak} never exceeded {DASH.LaunchSpeed}`)
		end)

		it("never breaches the speed ceiling, from any entry momentum", function()
			-- The clamp is what keeps the claim this state reports under
			-- Validation.MaxReportedSpeed -- see that constant's own header for the stuttering
			-- rejection failure it records having already happened once with the slide.
			for _, entry in { 0, 27, 60, DASH.LaunchSpeed, DASH.MaxSpeed } do
				local context = makeContext(7900 + entry)
				context.Momentum = entry
				flyDash(context, DASH.DurationSeconds, function(ctx)
					expect(ctx.Momentum <= DASH.MaxSpeed).to.equal(true, `entry {entry}: {ctx.Momentum}`)
					expect(ctx.Momentum >= 0).to.equal(true, `entry {entry}: {ctx.Momentum}`)
				end)
			end
		end)

		it("winds up rather than stamping -- frame one is not already at full speed", function()
			-- The single most direct statement of what replaced the old BurstPeak curve. That curve
			-- assigned its peak on frame one; a launch with no wind-up has no mass.
			local context = makeContext(8000)
			context.Momentum = 27
			flyDash(context, context.DeltaTime)
			expect(context.Momentum < DASH.LaunchSpeed).to.equal(true, `frame one already at {context.Momentum}`)
			expect(context.Momentum > 27).to.equal(true, "frame one did not accelerate at all")
		end)

		it("publishes the launch, not the exit speed, as the momentum the report will carry", function()
			-- ParkourController.reportTransition reads context.Momentum AFTER Enter runs, so this is
			-- what the server is told. Claiming the exit speed there would under-report the action by
			-- most of its own magnitude.
			local context = makeContext(8100)
			InputBuffer.PressDash(context.Now)
			dashEnter(context, "Falling")
			expect(context.Momentum).to.equal(DASH.LaunchSpeed)
			InputBuffer.Clear()
		end)
	end)

	describe("Dashing exit", function()
		local dashExit = assert(Dashing.Exit, "States/Dashing.lua must define Exit")

		it("never costs the player speed, from any entry momentum", function()
			-- THE RULE that made three of the old five directions strictly worse ways to travel. A
			-- chaining move that costs speed makes never pressing it the optimal play.
			for _, entry in { 0, 20, 27, 60, 94 } do
				local context = makeContext(8200 + entry)
				context.Momentum = entry
				flyDash(context, DASH.DurationSeconds)
				dashExit(context, "Falling")
				expect(context.Momentum >= entry).to.equal(true, `entry {entry} exited at {context.Momentum}`)
				expect(context.Momentum >= DASH.MinExitSpeed).to.equal(
					true,
					`entry {entry} exited below the floor at {context.Momentum}`
				)
			end
		end)

		it("leaves a standing dash moving", function()
			local context = makeContext(8300)
			context.Momentum = 0
			flyDash(context, DASH.DurationSeconds)
			dashExit(context, "Falling")
			expect(context.Momentum >= DASH.MinExitSpeed).to.equal(true)
		end)

		it("clears the animation variant so the next state resolves its own clip", function()
			local context = makeContext(8400)
			flyDash(context, DASH.DurationSeconds)
			dashExit(context, "Falling")
			expect(context.AnimationVariant).to.equal(nil)
		end)
	end)

	describe("Dashing air budget and the wall-launch chain", function()
		it("always spends an air charge -- every dash is airborne now", function()
			local context = makeContext(8500)
			InputBuffer.PressDash(context.Now)
			dashEnter(context, "Falling")
			expect(context.AirDashChain).to.equal(1)
			InputBuffer.Clear()
		end)

		it("cancels the fall's landing cost, exactly as a roll does", function()
			local context = makeContext(8600)
			context.LandingSeverity = "Hard"
			context.FallHeight = 40
			InputBuffer.PressDash(context.Now)
			dashEnter(context, "Landing")
			expect(context.LandingSeverity).to.equal(nil)
			expect(context.FallHeight).to.equal(0)
			InputBuffer.Clear()
		end)

		it("holds vertical velocity higher, for longer, when chained off a wall launch", function()
			-- Granted to ANY chained dash now, not only an upward one -- so this deliberately tests a
			-- LEVEL dash, which under the old quadrant rule would have received no boost at all.
			local function verticalVelocityAt(elapsedTarget: number, chained: boolean): number
				local now = 8700
				local context = makeContext(now)
				context.AimDirection = Vector3.new(0, 0, -1)
				context.WallLaunchDashBoostUntil = if chained then now + 10 else 0
				flyDash(context, elapsedTarget)
				return context.Motor.Velocity.Y
			end

			-- Between AirHangSeconds and AirHangSeconds + WallLaunchChainExtraHangSeconds: the
			-- ordinary hang has released into gravity by this point, but the chained one has not, so
			-- the chained case must still be commanding the higher, undecayed value.
			local target = DASH.AirHangSeconds + DASH.WallLaunchChainExtraHangSeconds / 2
			expect(verticalVelocityAt(target, true) > verticalVelocityAt(target, false)).to.equal(true)
		end)

		it("pins vertical velocity at zero for the whole hang", function()
			-- The rule that makes a dash CANCEL a fall. Tested from a fast descent, which is the case
			-- that would otherwise sag straight through the launch.
			local context = makeContext(8800)
			context.AimDirection = Vector3.new(0, 0, -1)
			context.VerticalVelocity = -80
			flyDash(context, DASH.AirHangSeconds * 0.5, function(ctx)
				expect(math.abs(ctx.Motor.Velocity.Y) < 1e-6).to.equal(true, `hang leaked {ctx.Motor.Velocity.Y}`)
			end)
		end)
	end)

	describe("Dash tuning", function()
		it("keeps the launch inside the validator's reported-speed ceiling", function()
			-- The failure this catches is the one ParkourConstants.Validation.MaxReportedSpeed's own
			-- header records having already happened once with the slide: a distance retune pushes the
			-- honest peak past the ceiling, and players on the top run gear start having their own
			-- movement rejected -- which reads in play as the character sticking and stuttering.
			local ceiling = ParkourConstants.Validation.MaxReportedSpeed
			expect(DASH.MaxSpeed < ceiling).to.equal(true)
			expect(ceiling / DASH.MaxSpeed >= 1.4).to.equal(true)
			-- The spring's target has to leave room for its own overshoot under the ceiling, or the
			-- clamp eats the mass cue rather than guarding an edge case.
			expect(DASH.LaunchSpeed < DASH.MaxSpeed).to.equal(true)
		end)

		it("never makes the dash the fastest thing in the game", function()
			expect(DASH.MaxSpeed <= ParkourConstants.Leap.MaxPlanarSpeed).to.equal(true)
		end)

		it("keeps the flight inside the window the server is told about", function()
			-- ParkourController.ACTION_DURATIONS derives the declared ownership window from
			-- MaxDurationSeconds. A flight longer than it would have its window force-expired
			-- server-side mid-air, which is the "player frozen" failure ParkourValidation documents.
			expect(DASH.DurationSeconds <= DASH.MaxDurationSeconds).to.equal(true)
			expect(DASH.DurationSeconds > 0).to.equal(true)
		end)

		it("keeps the cruise a phase of the flight rather than the whole of it", function()
			-- Past CruiseSeconds the spring's target drops to the exit speed and the same spring
			-- bleeds it off -- that tail IS the dash visibly settling. A cruise at or past the
			-- duration deletes the settle and hands off at full launch speed.
			expect(DASH.CruiseSeconds > 0).to.equal(true)
			expect(DASH.CruiseSeconds < DASH.DurationSeconds).to.equal(true)
		end)

		it("keeps the air hang a phase of the dash rather than the whole of it", function()
			expect(DASH.AirCharges >= 1).to.equal(true)
			expect(DASH.AirHangSeconds > 0).to.equal(true)
			expect(DASH.AirHangSeconds < DASH.DurationSeconds).to.equal(true)
		end)

		it("keeps the launch spring underdamped -- damping at or above 1 deletes the mass cue", function()
			expect(DASH.LaunchDamping > 0).to.equal(true)
			expect(DASH.LaunchDamping < 1).to.equal(true)
			expect(DASH.LaunchFrequency > 0).to.equal(true)
		end)

		it("leaves the steer a real but capped authority", function()
			-- Zero is the frozen burst this rewrite replaced; the release window has to fit inside
			-- the flight or the taper never actually completes before hand-off.
			expect(DASH.TurnDegreesPerSecond > 0).to.equal(true)
			expect(DASH.SteerReleaseSeconds > 0).to.equal(true)
			expect(DASH.SteerReleaseSeconds < DASH.DurationSeconds).to.equal(true)
		end)

		it("leaves a standing dash moving without making it worth taking for the speed", function()
			expect(DASH.MinExitSpeed > ParkourConstants.Locomotion.WalkSpeed).to.equal(true)
			expect(DASH.MinExitSpeed < ParkourConstants.Locomotion.SprintSpeed).to.equal(true)
			expect(DASH.ExitRetainFraction > 0).to.equal(true)
			expect(DASH.ExitRetainFraction <= 1).to.equal(true)
		end)

		it("names WallLaunching as a dash origin, so the wall-launch combo can actually chain", function()
			expect((DASH.AllowedFromStates :: { [string]: boolean }).WallLaunching).to.equal(true)
		end)

		it("keeps the wall-launch chain boost a real but modest addition to the hang", function()
			expect(DASH.WallLaunchChainExtraHangSeconds > 0).to.equal(true)
			expect(DASH.WallLaunchChainExtraHangSeconds < DASH.AirHangSeconds).to.equal(true)
		end)

		it("authors an animation slot for every pitch band", function()
			-- ParkourAnimator gives Dashing no STATE_CLIPS fallback on purpose (playing a rising clip
			-- for a dive reads worse than playing nothing), so a band with no key at all in
			-- AnimationIds would be permanently silent with nothing to notice it. A blank VALUE is
			-- fine and expected -- that is "not authored yet"; a missing KEY is not.
			for _, band in { "Up", "Level", "Down" } do
				expect(ParkourConstants.AnimationIds[`Dash{band}`]).to.be.ok(band)
			end
			-- The pitch bands are animation-only. A gameplay gate hiding in this constant is exactly
			-- what the rewrite removed.
			expect(DASH.AnimationPitchDegrees > 0).to.equal(true)
			expect(DASH.AnimationPitchDegrees < 90).to.equal(true)
		end)
	end)
end
