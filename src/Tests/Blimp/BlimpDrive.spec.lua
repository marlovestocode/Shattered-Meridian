--!strict
-- Covers Server/Blimp/BlimpDrive.lua -- the whole of a blimp's actual flight behaviour.
--
-- No Instances, no Workspace, no waiting: that module deliberately touches nothing but numbers (see its
-- own header), which is what makes "does astern really cost more than ahead" and "does the altitude band
-- hold" answerable here rather than only by flying one around in Studio. Time is passed in as deltaTime,
-- so a case that needs ten seconds of flight runs six hundred steps and finishes instantly.
--
-- What is NOT covered here, and cannot be: the weld, the prompts, the constraints and the arm pose all
-- need real Instances and a real character. Those are exercised by playing the game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BlimpDrive = require(ServerScriptService.Server.Blimp.BlimpDrive)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local FRAME = 1 / 60

-- A deliberately plain tuning rather than BlimpConstants.Drive itself: every expectation below is
-- arithmetic on these numbers, and reading them off the live constants would turn a retune into a test
-- failure that says nothing. The two altitude bounds are the exception -- those are the behaviour under
-- test, so they are chosen to be easy to cross.
local function tuning(overrides: { [string]: number }?): BlimpTypes.DriveTuning
	local base: BlimpTypes.DriveTuning = {
		ForwardYawRadians = 0,
		CruiseSpeed = 40,
		ReverseSpeed = 10,
		Acceleration = 20,
		TurnRate = 1,
		TurnAcceleration = 4,
		ClimbSpeed = 20,
		ClimbAcceleration = 40,
		BankRadiansPerTurnRate = 0.5,
		MinAltitude = 50,
		MaxAltitude = 200,
	}
	if overrides then
		for key, value in overrides do
			(base :: any)[key] = value
		end
	end
	return base
end

local function intentOf(throttle: number, steer: number, lift: number): BlimpTypes.DriveIntent
	return { Throttle = throttle, Steer = steer, Lift = lift }
end

local function run(
	state: BlimpTypes.DriveState,
	intent: BlimpTypes.DriveIntent,
	config: BlimpTypes.DriveTuning,
	seconds: number
): BlimpTypes.DriveState
	local current = state
	local steps = math.floor(seconds / FRAME)
	for _ = 1, steps do
		current = BlimpDrive.Step(current, intent, config, FRAME)
	end
	return current
end

return function()
	describe("NewState", function()
		it("parks at rest where it is given", function()
			local state = BlimpDrive.NewState(CFrame.new(10, 100, -20))
			expect(state.Speed).to.equal(0)
			expect(state.YawRate).to.equal(0)
			expect(state.ClimbRate).to.equal(0)
			expect(state.Target.Position.Y).to.equal(100)
		end)

		it("flattens a tilted origin so the hull does not start being righted", function()
			-- A builder placing a blimp by eye leaves it pitched and rolled. The target must come out
			-- upright regardless, or the constraints spend the first seconds of the server correcting a
			-- pose nobody asked about.
			local tilted = CFrame.new(0, 100, 0) * CFrame.Angles(math.rad(20), math.rad(45), math.rad(15))
			local state = BlimpDrive.NewState(tilted)
			expect(math.abs(state.Target.UpVector.Y - 1) < 1e-4).to.equal(true)
		end)
	end)

	describe("SanitizeHelmInput", function()
		it("accepts the pilot's two held axes", function()
			local helm = BlimpDrive.SanitizeHelmInput({ Steer = -1, Lift = 1 })
			expect(helm).to.be.ok()
			expect((helm :: BlimpTypes.HelmInput).Steer).to.equal(-1)
			expect((helm :: BlimpTypes.HelmInput).Lift).to.equal(1)
		end)

		it("clamps an out-of-range axis rather than rejecting the packet", function()
			-- Same reasoning as SanitizeIntent's: refusing the whole packet leaves the LAST good input
			-- latched, which is a worse outcome than pinning the axis this one was asking for.
			local helm = BlimpDrive.SanitizeHelmInput({ Steer = 50, Lift = -50 })
			expect((helm :: BlimpTypes.HelmInput).Steer).to.equal(1)
			expect((helm :: BlimpTypes.HelmInput).Lift).to.equal(-1)
		end)

		it("rejects a malformed payload", function()
			expect(BlimpDrive.SanitizeHelmInput(nil)).to.never.be.ok()
			expect(BlimpDrive.SanitizeHelmInput({ Steer = 0 })).to.never.be.ok()
			expect(BlimpDrive.SanitizeHelmInput({ Steer = 0 / 0, Lift = 0 })).to.never.be.ok()
		end)

		it("carries no throttle at all", function()
			-- The load-bearing property of this whole shape: a client cannot assert a speed, because
			-- the wire has nowhere to put one. A Throttle field here that the server was contractually
			-- obliged to ignore is exactly the kind of dead wire field that gets read by accident.
			local helm = BlimpDrive.SanitizeHelmInput({ Steer = 1, Lift = 1, Throttle = 1 })
			expect((helm :: any).Throttle).to.never.be.ok()
		end)
	end)

	describe("Step with a landing floor override", function()
		it("descends below the authored floor when one is given", function()
			-- Drive.MinAltitude exists to stop a PILOT burying the hull in terrain. An unattended
			-- landing has to get under it, or a ship descending onto a mountain stops dead in mid-air
			-- at that altitude and hangs there.
			local config = tuning({ MinAltitude = 100, MaxAltitude = 500 })
			local state = BlimpDrive.NewState(CFrame.new(0, 200, 0))
			for _ = 1, 60 * 20 do
				state = BlimpDrive.Step(state, intentOf(0, 0, -1), config, FRAME, 40)
			end
			expect(state.Target.Position.Y < 100).to.equal(true)
			expect(state.Target.Position.Y >= 40 - 1e-3).to.equal(true)
		end)

		it("comes to rest ON the override rather than passing through it", function()
			local config = tuning({ MinAltitude = 100, MaxAltitude = 500 })
			local state = BlimpDrive.NewState(CFrame.new(0, 200, 0))
			for _ = 1, 60 * 30 do
				state = BlimpDrive.Step(state, intentOf(0, 0, -1), config, FRAME, 40)
			end
			expect(math.abs(state.Target.Position.Y - 40) < 1e-3).to.equal(true)
			-- Zeroed, not merely clamped -- otherwise a hull that sat on its floor for a minute would
			-- get a minute of stored ascent the instant a new pilot pulled up.
			expect(state.ClimbRate).to.equal(0)
		end)

		it("leaves the authored floor in force when no override is given", function()
			local config = tuning({ MinAltitude = 100, MaxAltitude = 500 })
			local state = BlimpDrive.NewState(CFrame.new(0, 200, 0))
			for _ = 1, 60 * 20 do
				state = BlimpDrive.Step(state, intentOf(0, 0, -1), config, FRAME)
			end
			expect(math.abs(state.Target.Position.Y - 100) < 1e-3).to.equal(true)
		end)

		it("never lets an absurd override push the hull UP through its own ceiling", function()
			-- Reachable on terrain taller than MaxAltitude. Handed to math.clamp as a min greater than
			-- its max, the result is the MAX -- silently teleporting the hull to the ceiling instead of
			-- landing it -- which is why the floor is bounded before use.
			local config = tuning({ MinAltitude = 100, MaxAltitude = 500 })
			local state = BlimpDrive.NewState(CFrame.new(0, 200, 0))
			state = BlimpDrive.Step(state, intentOf(0, 0, -1), config, FRAME, 9000)
			expect(state.Target.Position.Y <= 500 + 1e-3).to.equal(true)
		end)
	end)

	describe("SanitizeIntent", function()
		it("accepts a well-formed payload", function()
			local intent = BlimpDrive.SanitizeIntent({ Throttle = 1, Steer = -1, Lift = 0 })
			expect(intent).to.be.ok()
			expect((intent :: BlimpTypes.DriveIntent).Throttle).to.equal(1)
			expect((intent :: BlimpTypes.DriveIntent).Steer).to.equal(-1)
		end)

		it("clamps an out-of-range axis rather than rejecting the packet", function()
			-- See SanitizeIntent's own comment: rejecting would leave the LAST good intent latched, which
			-- is a worse outcome than pinning the liar to full ahead.
			local intent = BlimpDrive.SanitizeIntent({ Throttle = 50, Steer = -900, Lift = 3 })
			expect(intent).to.be.ok()
			expect((intent :: BlimpTypes.DriveIntent).Throttle).to.equal(1)
			expect((intent :: BlimpTypes.DriveIntent).Steer).to.equal(-1)
			expect((intent :: BlimpTypes.DriveIntent).Lift).to.equal(1)
		end)

		it("refuses a non-table, a missing axis and a non-number axis", function()
			expect(BlimpDrive.SanitizeIntent("full ahead")).to.equal(nil)
			expect(BlimpDrive.SanitizeIntent(nil)).to.equal(nil)
			expect(BlimpDrive.SanitizeIntent({ Throttle = 1, Steer = 0 })).to.equal(nil)
			expect(BlimpDrive.SanitizeIntent({ Throttle = 1, Steer = 0, Lift = "up" })).to.equal(nil)
		end)

		it("refuses NaN and infinity", function()
			-- The case that matters most: a NaN axis propagates into Target and the constraints stop being
			-- able to solve at all, which presents as a blimp frozen solid for the rest of the round.
			expect(BlimpDrive.SanitizeIntent({ Throttle = 0 / 0, Steer = 0, Lift = 0 })).to.equal(nil)
			expect(BlimpDrive.SanitizeIntent({ Throttle = math.huge, Steer = 0, Lift = 0 })).to.equal(nil)
			expect(BlimpDrive.SanitizeIntent({ Throttle = 0, Steer = -math.huge, Lift = 0 })).to.equal(nil)
		end)
	end)

	describe("Step", function()
		it("ramps toward cruise speed instead of reaching it at once", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 100, 0))
			local afterOneFrame = BlimpDrive.Step(state, intentOf(1, 0, 0), config, FRAME)
			expect(afterOneFrame.Speed > 0).to.equal(true)
			expect(afterOneFrame.Speed < config.CruiseSpeed).to.equal(true)

			-- CruiseSpeed 40 at Acceleration 20 is a two-second run-up; three seconds is comfortably past.
			local atCruise = run(state, intentOf(1, 0, 0), config, 3)
			expect(math.abs(atCruise.Speed - config.CruiseSpeed) < 1e-3).to.equal(true)
		end)

		it("holds astern to its own much lower ceiling", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 100, 0))
			local reversing = run(state, intentOf(-1, 0, 0), config, 3)
			expect(math.abs(reversing.Speed + config.ReverseSpeed) < 1e-3).to.equal(true)
		end)

		it("coasts to a stop on a neutral intent rather than stopping dead", function()
			local config = tuning()
			local moving = run(BlimpDrive.NewState(CFrame.new(0, 100, 0)), intentOf(1, 0, 0), config, 3)
			local oneFrameOff = BlimpDrive.Step(moving, intentOf(0, 0, 0), config, FRAME)
			expect(oneFrameOff.Speed > 0).to.equal(true)
			expect(oneFrameOff.Speed < moving.Speed).to.equal(true)

			local stopped = run(moving, intentOf(0, 0, 0), config, 3)
			expect(math.abs(stopped.Speed) < 1e-3).to.equal(true)
		end)

		it("travels along its own heading, not along a world axis", function()
			local config = tuning()
			-- Facing +X. A hull that integrated in world space would drift on Z here.
			local facingX = CFrame.lookAt(Vector3.new(0, 100, 0), Vector3.new(1, 100, 0))
			local flown = run(BlimpDrive.NewState(facingX), intentOf(1, 0, 0), config, 2)
			expect(flown.Target.Position.X > 10).to.equal(true)
			expect(math.abs(flown.Target.Position.Z) < 1e-3).to.equal(true)
		end)

		it("travels along the authored bow, not along the root part's raw facing", function()
			-- The regression that produced "the controls are reversed" on the first real blimp: the root
			-- mesh was modelled facing the opposite way to the ship, so the hull flew backwards.
			local config = tuning({ ForwardYawRadians = math.pi })
			local facingX = CFrame.lookAt(Vector3.new(0, 100, 0), Vector3.new(1, 100, 0))
			local flown = run(BlimpDrive.NewState(facingX), intentOf(1, 0, 0), config, 2)
			-- Root faces +X, bow correction is 180 degrees, so full ahead must travel -X.
			expect(flown.Target.Position.X < -10).to.equal(true)
		end)

		it("keeps steering correct regardless of the bow correction", function()
			-- The correction applies to TRAVEL only. If it leaked into the yaw input, fixing a backwards
			-- blimp would break its steering in the same motion.
			local config = tuning({ ForwardYawRadians = math.pi })
			local turned = run(BlimpDrive.NewState(CFrame.new(0, 100, 0)), intentOf(0, 1, 0), config, 1)
			expect(turned.YawRate > 0).to.equal(true)
			expect(turned.Target.LookVector.X > 0).to.equal(true)
		end)

		it("turns starboard on a positive steer axis", function()
			local config = tuning()
			-- Facing -Z (Roblox's default look direction). Turning right from there heads toward +X.
			local state = BlimpDrive.NewState(CFrame.new(0, 100, 0))
			local turned = run(state, intentOf(0, 1, 0), config, 1)
			expect(turned.YawRate > 0).to.equal(true)
			expect(turned.Target.LookVector.X > 0).to.equal(true)
		end)

		it("stays upright through a sustained turn", function()
			-- The integrator's Target must never accumulate roll -- the bank is presentation only. A turn
			-- that banked the target would leave the hull leaning after the turn ended.
			local config = tuning()
			local turned = run(BlimpDrive.NewState(CFrame.new(0, 100, 0)), intentOf(1, 1, 0), config, 8)
			expect(math.abs(turned.Target.UpVector.Y - 1) < 1e-4).to.equal(true)
		end)

		it("holds the altitude ceiling and does not bank climb against it", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 190, 0))
			local pinned = run(state, intentOf(0, 0, 1), config, 10)
			expect(pinned.Target.Position.Y).to.equal(config.MaxAltitude)
			-- Zeroed, not merely clamped: a stored climb rate would become a burst of descent the moment
			-- the pilot let go. See Step's own comment.
			expect(pinned.ClimbRate).to.equal(0)
		end)

		it("holds the altitude floor", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 60, 0))
			local grounded = run(state, intentOf(0, 0, -1), config, 10)
			expect(grounded.Target.Position.Y).to.equal(config.MinAltitude)
			expect(grounded.ClimbRate).to.equal(0)
		end)

		it("keeps a blimp moored below its own floor exactly where it is", function()
			-- The registration rule in BlimpSystem lowers MinAltitude to the spawn altitude for this case.
			-- Asserted here because the consequence lives in this module: with the floor seeded that way, a
			-- parked blimp must not creep upward on a neutral intent.
			local config = tuning({ MinAltitude = 5 })
			local parked = run(BlimpDrive.NewState(CFrame.new(0, 5, 0)), intentOf(0, 0, 0), config, 5)
			expect(parked.Target.Position.Y).to.equal(5)
		end)

		it("clamps a hitched frame instead of teleporting through it", function()
			local config = tuning()
			local atCruise = run(BlimpDrive.NewState(CFrame.new(0, 100, 0)), intentOf(1, 0, 0), config, 3)
			-- A ten-second stall. Integrated whole it would move the target 400 studs.
			local afterHitch = BlimpDrive.Step(atCruise, intentOf(1, 0, 0), config, 10)
			local travelled = (afterHitch.Target.Position - atCruise.Target.Position).Magnitude
			expect(travelled < config.CruiseSpeed * 0.3).to.equal(true)
		end)

		it("is a no-op on a zero or negative delta", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 100, 0))
			expect(BlimpDrive.Step(state, intentOf(1, 0, 0), config, 0)).to.equal(state)
			expect(BlimpDrive.Step(state, intentOf(1, 0, 0), config, -1)).to.equal(state)
		end)

		it("does not mutate the state it was given", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 100, 0))
			BlimpDrive.Step(state, intentOf(1, 1, 1), config, FRAME)
			expect(state.Speed).to.equal(0)
			expect(state.YawRate).to.equal(0)
			expect(state.ClimbRate).to.equal(0)
		end)
	end)

	describe("PresentationCFrame", function()
		it("adds no roll when the hull is not turning", function()
			local config = tuning()
			local state = BlimpDrive.NewState(CFrame.new(0, 100, 0))
			local presented = BlimpDrive.PresentationCFrame(state, config)
			expect(math.abs(presented.UpVector.Y - 1) < 1e-6).to.equal(true)
		end)

		it("banks into a starboard turn and unwinds completely when it ends", function()
			local config = tuning()
			local turning = run(BlimpDrive.NewState(CFrame.new(0, 100, 0)), intentOf(1, 1, 0), config, 3)
			local banked = BlimpDrive.PresentationCFrame(turning, config)
			-- Starboard turn drops the starboard side: the right vector tips below horizontal.
			expect(banked.RightVector.Y < -0.01).to.equal(true)

			-- The whole reason the bank is derived rather than stored -- straightening out leaves nothing
			-- behind to unwind.
			local straightened = run(turning, intentOf(1, 0, 0), config, 3)
			local level = BlimpDrive.PresentationCFrame(straightened, config)
			expect(math.abs(level.RightVector.Y) < 1e-3).to.equal(true)
		end)
	end)

	describe("ClampLead", function()
		-- Covers the bug this exists to close: a blimp blocked from moving (a player wedged against the
		-- hull, holding a movement key) lets Target march forward unopposed while the hull sits still,
		-- banking a position error with no ceiling until the block clears and the constraint discharges
		-- it as one enormous corrective velocity. See BlimpSystem.onHeartbeatTick for the one call site.
		it("passes a target back unchanged when it is within the bound", function()
			local target = CFrame.new(10, 100, 0)
			local clamped = BlimpDrive.ClampLead(target, Vector3.new(0, 100, 0), 50)
			-- Same value, not merely an equal one -- the caller uses this identity to decide whether it
			-- has anything to write back into Drive at all.
			expect(clamped).to.equal(target)
		end)

		it("passes a target back unchanged exactly at the bound", function()
			local target = CFrame.new(50, 100, 0)
			local clamped = BlimpDrive.ClampLead(target, Vector3.new(0, 100, 0), 50)
			expect(clamped).to.equal(target)
		end)

		it("pulls an over-extended target back to exactly the bound, along the same line", function()
			-- A hull blocked for a while: Target has raced 400 studs down +X while the root never moved.
			local target = CFrame.new(400, 100, 0)
			local clamped = BlimpDrive.ClampLead(target, Vector3.new(0, 100, 0), 50)
			expect(clamped.Position.X).to.be.near(50, 1e-4)
			expect(math.abs(clamped.Position.Y - 100) < 1e-4).to.equal(true)
			expect(math.abs(clamped.Position.Z) < 1e-4).to.equal(true)
		end)

		it("clamps distance in any direction, not just along a world axis", function()
			local actual = Vector3.new(10, 100, -5)
			local target = CFrame.new(actual + Vector3.new(30, 40, 0)) -- 50 studs away
			local clamped = BlimpDrive.ClampLead(target, actual, 25)
			expect(math.abs((clamped.Position - actual).Magnitude - 25) < 1e-3).to.equal(true)
		end)

		it("preserves the target's rotation, not just its position", function()
			local target = CFrame.lookAt(Vector3.new(300, 100, 0), Vector3.new(301, 100, 1))
			local clamped = BlimpDrive.ClampLead(target, Vector3.new(0, 100, 0), 50)
			expect((clamped.LookVector - target.LookVector).Magnitude < 1e-4).to.equal(true)
		end)

		it("feeds a clamped Target back into Step cleanly on the next tick", function()
			-- Exercises the actual sequence BlimpSystem.onHeartbeatTick runs: Step, then ClampLead, then
			-- Step again from whatever ClampLead returned -- the same "feed the clamped result back into
			-- Drive.Target" contract the fix relies on, proven here without any Instance involved.
			local config = tuning()
			-- Facing +X explicitly, the same way "travels along its own heading" above does -- a plain
			-- CFrame.new faces -Z by default, and reading .X off that heading would make this assert on
			-- the wrong axis regardless of whether the clamp actually worked.
			local facingX = CFrame.lookAt(Vector3.new(0, 100, 0), Vector3.new(1, 100, 0))
			local racedAhead = run(BlimpDrive.NewState(facingX), intentOf(1, 0, 0), config, 5)
			local clampedTarget = BlimpDrive.ClampLead(racedAhead.Target, Vector3.new(0, 100, 0), 20)
			local reseeded = {
				Target = clampedTarget,
				Speed = racedAhead.Speed,
				YawRate = racedAhead.YawRate,
				ClimbRate = racedAhead.ClimbRate,
			}
			local nextTick = BlimpDrive.Step(reseeded, intentOf(1, 0, 0), config, FRAME)
			-- Still finite, still travelling forward from the clamped position, not from wherever the
			-- unclamped run left off -- proof the debt was actually discarded, not merely hidden.
			expect(nextTick.Target.Position.X > clampedTarget.Position.X).to.equal(true)
			expect(nextTick.Target.Position.X < racedAhead.Target.Position.X).to.equal(true)
		end)
	end)

	describe("the shipping tuning", function()
		it("is internally consistent", function()
			-- A guard on the constants themselves rather than on the module: every one of these being
			-- positive is assumed silently by Step, and a retune that zeroed one would produce a blimp
			-- that simply never moves, with nothing in any log.
			local drive = BlimpConstants.Drive
			expect(drive.CruiseSpeed > 0).to.equal(true)
			expect(drive.ReverseSpeed > 0).to.equal(true)
			expect(drive.ReverseSpeed < drive.CruiseSpeed).to.equal(true)
			expect(drive.Acceleration > 0).to.equal(true)
			expect(drive.TurnRate > 0).to.equal(true)
			expect(drive.TurnAcceleration > 0).to.equal(true)
			expect(drive.ClimbSpeed > 0).to.equal(true)
			expect(drive.ClimbAcceleration > 0).to.equal(true)
			expect(drive.MaxAltitude > drive.MinAltitude).to.equal(true)
			-- MaxLeadStuds must clear the tracking lag a clean flight path produces on its own or this
			-- would fire on every ordinary tick; see that entry's own comment for the reasoning. One
			-- second of cruise travel is a generous, easy-to-justify floor for "clears ordinary lag."
			expect(drive.MaxLeadStuds > 0).to.equal(true)
			expect(drive.MaxLeadStuds < drive.CruiseSpeed).to.equal(true)
		end)

		it("gives the drive velocity ceiling room above cruise and nitrous", function()
			-- BlimpConstants.Physics.MaxDriveVelocity is the actual hard cap on discharge speed -- it must
			-- sit above every speed the drive can ever COMMAND, or normal full-ahead flight (and any
			-- future nitrous boost) would be felt fighting its own safety net.
			local physics = BlimpConstants.Physics
			local drive = BlimpConstants.Drive
			expect(physics.MaxDriveVelocity > drive.CruiseSpeed).to.equal(true)
			expect(physics.MaxDriveVelocity > drive.NitrousSpeed).to.equal(true)
		end)
	end)
end
