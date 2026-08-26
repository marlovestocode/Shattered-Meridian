--!strict
-- Covers Shared/Blimp/BlimpCameraMath.lua -- the aboard-a-blimp camera's whole feel.
--
-- The point of that module touching no Instance is that this file can exist: "does a turn overshoot
-- and settle", "does opening the throttle shove the view backward", "does the bob fade out once the
-- ship is making way", "does letting go of everything return to level" and "does a hitch blow the
-- spring up" are all answerable by feeding numbers to a table. None of them is answerable by reading
-- the code, and short of this they would only be answerable by flying a blimp in Studio and squinting.
--
-- Every case drives the module the way the render step does: Observe a hull pose and its velocities,
-- then Step. The hull pose is a plain CFrame, so "which way is forward" is under test too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpCameraMath = require(ReplicatedStorage.Shared.Blimp.BlimpCameraMath)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)

local FRAME = 1 / 60
local CRUISE = 110

-- The engine rumble rides on top of every rotational channel and never settles (that is its whole
-- point -- see BlimpCameraMath's header), so any assertion about a rotational channel's BOUND has to
-- allow for it. Read off the live constant rather than written out, so a retune of one does not
-- silently invalidate the other.
local RUMBLE = BlimpConstants.Camera.Rumble.MaxRadians

-- An identity-facing hull: LookVector is (0, 0, -1), so "forward" is -Z and "right" is +X.
local LEVEL = CFrame.new(0, 200, 0)

local function advance(
	state: BlimpCameraMath.State,
	linear: Vector3,
	angular: Vector3,
	seconds: number,
	rotationEnabled: boolean?
): ()
	local enabled = if rotationEnabled == nil then true else rotationEnabled
	for _ = 1, math.floor(seconds / FRAME) do
		BlimpCameraMath.Observe(state, LEVEL, linear, angular, CRUISE, FRAME)
		BlimpCameraMath.Step(state, FRAME, enabled)
	end
end

-- Straight ahead at cruise: -Z is forward for LEVEL above.
local function forwardAt(speed: number): Vector3
	return Vector3.new(0, 0, -speed)
end

return function()
	describe("Observe", function()
		it("resolves travel along the hull's own facing, not the world's", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 2)
			expect(state.Motion.ForwardSpeed > CRUISE * 0.9).to.equal(true)
			expect(math.abs(state.Motion.LateralSpeed) < 1).to.equal(true)
		end)

		it("reads sideways drift as lateral, not as speed", function()
			-- The sign matters as much as the magnitude: right is +X for a hull looking down -Z, and
			-- getting it backwards silently mirrors the whole camera's lateral lean.
			local state = BlimpCameraMath.NewState()
			advance(state, Vector3.new(30, 0, 0), Vector3.zero, 2)
			expect(state.Motion.LateralSpeed > 25).to.equal(true)
			expect(math.abs(state.Motion.ForwardSpeed) < 1).to.equal(true)
		end)

		it("does not leak a PITCHED hull's climb into its forward speed", function()
			-- A blimp is a physically simulated body: a collision, a passenger's mass shifting, or the
			-- orientation constraint still settling all leave the hull nose-up or nose-down for a moment.
			-- Decomposing velocity against that raw LookVector would report a pure climb as forward speed
			-- -- which then differentiates into a phantom acceleration and shoves the view backward for no
			-- reason a player could see. Observe flattens the facing first; this is what that buys.
			local pitched = CFrame.new(0, 200, 0) * CFrame.Angles(math.rad(25), 0, 0)
			local state = BlimpCameraMath.NewState()
			for _ = 1, 180 do
				BlimpCameraMath.Observe(state, pitched, Vector3.new(0, 40, 0), Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, true)
			end
			expect(math.abs(state.Motion.ForwardSpeed) < 1).to.equal(true)
			expect(state.Motion.ClimbRate > 35).to.equal(true)
		end)

		it("reports no acceleration on the very first frame", function()
			-- Boarding a ship already at flank must not read its entire current speed as one frame's
			-- worth of acceleration -- that is a violent shove backward on the exact frame the player's
			-- view is handed over.
			local state = BlimpCameraMath.NewState()
			BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.zero, CRUISE, FRAME)
			expect(state.Motion.ForwardAccel).to.equal(0)
		end)

		it("clamps the speed fraction and refuses to report astern as fast", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE * 4), Vector3.zero, 3)
			expect(state.Motion.SpeedFraction).to.equal(1)

			local reversing = BlimpCameraMath.NewState()
			advance(reversing, forwardAt(-40), Vector3.zero, 3)
			expect(reversing.Motion.SpeedFraction).to.equal(0)
		end)
	end)

	describe("rotational channels", function()
		it("rolls into a turn", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), 2)
			expect(state.Pose.RollRadians ~= 0).to.equal(true)
			expect(math.abs(state.Pose.RollRadians) <= BlimpConstants.Camera.Roll.MaxRadians + RUMBLE + 1e-3).to.equal(
				true
			)
		end)

		it("rolls the opposite way for the opposite turn", function()
			local port = BlimpCameraMath.NewState()
			advance(port, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), 2)
			local starboard = BlimpCameraMath.NewState()
			advance(starboard, forwardAt(CRUISE), Vector3.new(0, -0.8, 0), 2)
			expect(port.Pose.RollRadians * starboard.Pose.RollRadians < 0).to.equal(true)
		end)

		it("overshoots on the way into a turn -- the whole reason these are springs", function()
			-- An exponential ease approaches its target from one side and never passes it. This one
			-- must, or the camera has no mass. Sampled every frame for the peak against the settled
			-- value, so the assertion is about the SHAPE of the response, not about a tuned number.
			-- Turned WITHOUT forward speed, deliberately: the engine rumble scales with speed fraction,
			-- and at cruise its amplitude is a comparable fraction of the settled roll to the overshoot
			-- being measured -- so a single settled sample taken at a rumble peak could swamp the signal.
			-- At zero speed the rumble is silent and this measures the spring alone, which is the thing
			-- under test.
			local state = BlimpCameraMath.NewState()
			local peak = 0
			for _ = 1, 240 do
				BlimpCameraMath.Observe(state, LEVEL, Vector3.zero, Vector3.new(0, 0.8, 0), CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, true)
				peak = math.max(peak, math.abs(state.Pose.RollRadians))
			end
			local settled = math.abs(state.Pose.RollRadians)
			-- A small margin, not a tuned one: at the shipped damping ratio the theoretical overshoot is a
			-- few percent, and the velocity filter in front of the spring softens the step a little
			-- further. The assertion is that it overshoots AT ALL -- which an ease cannot -- not by how
			-- much, so a future retune of the damping does not break this.
			expect(peak > settled * 1.005).to.equal(true)
		end)

		it("pitches with the climb rate", function()
			local climbing = BlimpCameraMath.NewState()
			advance(climbing, Vector3.new(0, 40, 0), Vector3.zero, 2)
			local descending = BlimpCameraMath.NewState()
			advance(descending, Vector3.new(0, -40, 0), Vector3.zero, 2)
			expect(climbing.Pose.PitchRadians * descending.Pose.PitchRadians < 0).to.equal(true)
		end)

		it("levels the horizon with rotation disabled but keeps the sense of speed", function()
			-- The comfort opt-out is a SPLIT, not an off switch -- rotating the horizon is what
			-- provokes simulator sickness; sliding the view is what says the ship is moving.
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), 4, false)
			expect(math.abs(state.Pose.RollRadians) < 1e-3).to.equal(true)
			expect(math.abs(state.Pose.YawRadians) < 1e-3).to.equal(true)
			expect(math.abs(state.Pose.PitchRadians) < 1e-3).to.equal(true)
			expect(state.Pose.Offset.Z > 1).to.equal(true)
		end)
	end)

	describe("positional channels", function()
		it("pulls back with speed", function()
			-- +Z is BACK in Humanoid.CameraOffset's local space, the same convention ShiftLock's
			-- shoulder offset and Flight's chase pull-back already use.
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 4)
			expect(state.Pose.Offset.Z > 1).to.equal(true)
		end)

		it("surges backward under acceleration and forward under braking", function()
			-- The channel the whole camera is named for. Ramped rather than stepped so the
			-- accelerometer sees a real, sustained acceleration rather than one frame's jump.
			-- Neither ramp saturates before the last frame, deliberately: a ramp that flattens out
			-- early leaves the accelerometer reading zero by the time the comparison is taken, and the
			-- two runs converge on the same answer for a reason that has nothing to do with the surge.
			local STEPS = 100
			local RAMP = CRUISE / STEPS

			local accelerating = BlimpCameraMath.NewState()
			for step = 1, STEPS do
				BlimpCameraMath.Observe(accelerating, LEVEL, forwardAt(step * RAMP), Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(accelerating, FRAME, true)
			end
			local underPower = accelerating.Pose.Offset.Z

			-- The same terminal speed on the same last frame, reached by DECELERATING onto it from above.
			local braking = BlimpCameraMath.NewState()
			for step = 1, STEPS do
				BlimpCameraMath.Observe(
					braking,
					LEVEL,
					forwardAt(CRUISE * 2 - step * RAMP),
					Vector3.zero,
					CRUISE,
					FRAME
				)
				BlimpCameraMath.Step(braking, FRAME, true)
			end
			expect(underPower > braking.Pose.Offset.Z).to.equal(true)
		end)

		it("widens the field of view as the ship gets going", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 6)
			expect(state.Pose.FovDelta > 1).to.equal(true)
			expect(state.Pose.FovDelta <= BlimpConstants.Camera.Fov.MaxDeltaAtCruise + 1e-3).to.equal(true)
		end)
	end)

	describe("the engine rumble", function()
		it("never settles while the ship is under way -- the only cue a steady cruise has", function()
			-- The failure this exists to prevent: every OTHER channel answers to change, so a ship holding
			-- a steady heading at a steady rung has them all at rest and the view goes as still as solid
			-- ground. Measured well AFTER the springs have settled, so anything still moving is the rumble.
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 6)

			local low, high = math.huge, -math.huge
			for _ = 1, 240 do
				BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, true)
				low = math.min(low, state.Pose.RollRadians)
				high = math.max(high, state.Pose.RollRadians)
			end
			expect(high - low > 1e-4).to.equal(true)
		end)

		it("stays far below anything a player would read as a shaking camera", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 6)
			for _ = 1, 240 do
				BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, true)
				-- The springs are settled at zero here (straight and level), so the whole of the pose IS
				-- the rumble.
				expect(math.abs(state.Pose.RollRadians) <= RUMBLE + 1e-6).to.equal(true)
			end
		end)

		it("is silent on a stopped hull", function()
			-- A moored blimp is not running its engines. The idle bob is what that state gets instead.
			local state = BlimpCameraMath.NewState()
			advance(state, Vector3.zero, Vector3.zero, 4)
			expect(math.abs(state.Pose.RollRadians) < 1e-6).to.equal(true)
		end)

		it("goes quiet with the rest of the rotation under the comfort opt-out", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 4, false)
			for _ = 1, 120 do
				BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, false)
				expect(math.abs(state.Pose.RollRadians) < 1e-6).to.equal(true)
			end
		end)
	end)

	describe("the telegraph kick", function()
		it("shoves the view backward on a rung toward flank", function()
			-- +Z is BACK. The kick is the RECEIPT for a control whose real effect takes seconds to arrive.
			local state = BlimpCameraMath.NewState()
			advance(state, Vector3.zero, Vector3.zero, 2)
			local before = state.Pose.Offset.Z
			BlimpCameraMath.Kick(state, 1)
			BlimpCameraMath.Step(state, FRAME, true)
			expect(state.Pose.Offset.Z > before).to.equal(true)
		end)

		it("shoves it the other way on a rung toward astern", function()
			local state = BlimpCameraMath.NewState()
			advance(state, Vector3.zero, Vector3.zero, 2)
			local before = state.Pose.Offset.Z
			BlimpCameraMath.Kick(state, -1)
			BlimpCameraMath.Step(state, FRAME, true)
			expect(state.Pose.Offset.Z < before).to.equal(true)
		end)

		it("settles back out on its own, with no target to hold it", function()
			-- It is an impulse into a spring, not a channel with its own decay -- which is what lets a
			-- pilot walking the ladder on a held key get one continuous swell rather than five thumps.
			local state = BlimpCameraMath.NewState()
			BlimpCameraMath.Kick(state, 1)
			for _ = 1, 600 do
				BlimpCameraMath.Step(state, FRAME, true)
			end
			expect(math.abs(state.Pose.Offset.Z) < 1e-2).to.equal(true)
		end)

		it("stacks rather than restarting when the ladder is walked", function()
			-- Four rungs in quick succession should read as one bigger shove, not as the fourth one only.
			local single = BlimpCameraMath.NewState()
			BlimpCameraMath.Kick(single, 1)
			BlimpCameraMath.Step(single, FRAME, true)

			local walked = BlimpCameraMath.NewState()
			for _ = 1, 4 do
				BlimpCameraMath.Kick(walked, 1)
			end
			BlimpCameraMath.Step(walked, FRAME, true)
			expect(walked.Pose.Offset.Z > single.Pose.Offset.Z).to.equal(true)
		end)
	end)

	describe("the idle bob", function()
		it("moves a stationary hull's view up and down", function()
			local state = BlimpCameraMath.NewState()
			local low, high = math.huge, -math.huge
			for _ = 1, 600 do
				BlimpCameraMath.Observe(state, LEVEL, Vector3.zero, Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, true)
				low = math.min(low, state.Pose.Offset.Y)
				high = math.max(high, state.Pose.Offset.Y)
			end
			expect(high - low > BlimpConstants.Camera.Bob.AmplitudeStuds).to.equal(true)
		end)

		it("has faded out entirely once the ship is under way", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 4)
			local low, high = math.huge, -math.huge
			for _ = 1, 600 do
				BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.zero, CRUISE, FRAME)
				BlimpCameraMath.Step(state, FRAME, true)
				low = math.min(low, state.Pose.Offset.Y)
				high = math.max(high, state.Pose.Offset.Y)
			end
			expect(high - low < 1e-3).to.equal(true)
		end)
	end)

	describe("release", function()
		it("settles every channel back to level after the motion stops", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), 3)
			expect(math.abs(state.Pose.RollRadians) > 1e-2).to.equal(true)

			BlimpCameraMath.ZeroMotion(state)
			for _ = 1, 600 do
				BlimpCameraMath.Step(state, FRAME, true)
			end
			expect(math.abs(state.Pose.RollRadians) < 1e-3).to.equal(true)
			expect(math.abs(state.Pose.PitchRadians) < 1e-3).to.equal(true)
			expect(state.Pose.Offset.Magnitude < 1e-2).to.equal(true)
			expect(math.abs(state.Pose.FovDelta) < 1e-2).to.equal(true)
		end)

		it("un-primes the accelerometer so the next ship starts clean", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.zero, 3)
			BlimpCameraMath.ZeroMotion(state)
			BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.zero, CRUISE, FRAME)
			expect(state.Motion.ForwardAccel).to.equal(0)
		end)
	end)

	describe("stability", function()
		it("survives a hitch without the spring diverging", function()
			-- The reason the integrator is implicit rather than semi-implicit: a Studio breakpoint or
			-- an alt-tabbed client hands in a dt far past the semi-implicit stability limit, and the
			-- failure there is not a wobble, it is the camera being flung.
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), 1)
			for _ = 1, 30 do
				BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), CRUISE, 5)
				BlimpCameraMath.Step(state, 5, true)
			end
			expect(math.abs(state.Pose.RollRadians) <= BlimpConstants.Camera.Roll.MaxRadians + 1e-2).to.equal(true)
			expect(state.Pose.Offset.Magnitude < 100).to.equal(true)
		end)

		it("treats a zero or negative frame as no frame at all", function()
			local state = BlimpCameraMath.NewState()
			advance(state, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), 2)
			local roll = state.Pose.RollRadians
			BlimpCameraMath.Observe(state, LEVEL, forwardAt(CRUISE), Vector3.new(0, 0.8, 0), CRUISE, 0)
			BlimpCameraMath.Step(state, 0, true)
			expect(state.Pose.RollRadians).to.equal(roll)
		end)
	end)
end
