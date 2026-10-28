--!strict
-- Covers Shared/CameraMotionMath.lua -- the movement-responsive camera's arithmetic. Pure, so every case drives it with
-- plain vectors and a fixed frame time: no camera, no character, no frame clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConstants = require(ReplicatedStorage.Shared.CameraConstants)
local CameraMotionMath = require(ReplicatedStorage.Shared.CameraMotionMath)

local TUNING: CameraMotionMath.Tuning = CameraConstants.Motion
local RIGHT = Vector3.new(1, 0, 0)
local MAX_LEAN = math.rad(TUNING.Lean.MaxDegrees)

type Outputs = { Roll: number, Pull: number, Dip: number, Fov: number, Severity: number? }

-- One frame at `fps`, returning the outputs as a record.
local function step(
	state: CameraMotionMath.State,
	velocity: Vector3,
	fps: number,
	suspended: boolean?,
	tuning: CameraMotionMath.Tuning?
): Outputs
	local roll, pull, dip, fov, severity =
		CameraMotionMath.Step(state, velocity, RIGHT, suspended == true, 1 / fps, tuning or TUNING)
	return { Roll = roll, Pull = pull, Dip = dip, Fov = fov, Severity = severity }
end

-- Runs `seconds` of a velocity profile at `fps` and returns the last outputs.
local function run(
	state: CameraMotionMath.State,
	profile: (time: number) -> Vector3,
	seconds: number,
	fps: number,
	suspended: boolean?
): Outputs
	local out = step(state, profile(0), fps, suspended)
	local frames = math.floor(seconds * fps)
	for frame = 1, frames do
		out = step(state, profile(frame / fps), fps, suspended)
	end
	return out
end

-- A body running at `speed` along -Z that begins a strafe to the camera's right at `at` seconds.
local function strafeRight(speed: number, at: number, sideSpeed: number): (number) -> Vector3
	return function(time: number)
		return Vector3.new(if time >= at then sideSpeed else 0, 0, -speed)
	end
end

local function steady(velocity: Vector3): (number) -> Vector3
	return function()
		return velocity
	end
end

-- The largest absolute roll seen across a run.
local function peakRoll(profile: (number) -> Vector3, seconds: number, fps: number): number
	local state = CameraMotionMath.NewState()
	local peak = 0
	local out = step(state, profile(0), fps)
	for frame = 1, math.floor(seconds * fps) do
		out = step(state, profile(frame / fps), fps)
		peak = math.max(peak, math.abs(out.Roll))
	end
	return peak
end

-- A body in free fall at `speed` that stops dead at `at`.
local function landingAt(speed: number, at: number): (number) -> Vector3
	return function(time: number)
		return if time < at then Vector3.new(0, -speed, 0) else Vector3.zero
	end
end

-- The deepest dip seen across a run of that landing.
local function peakDip(speed: number, fps: number): number
	local state = CameraMotionMath.NewState()
	local profile = landingAt(speed, 0.2)
	local peak = 0
	step(state, profile(0), fps)
	for frame = 1, math.floor(1.2 * fps) do
		peak = math.max(peak, step(state, profile(frame / fps), fps).Dip)
	end
	return peak
end

local function withScale(scale: { Lean: number, Pull: number, Fov: number, Landing: number }): CameraMotionMath.Tuning
	local copy = table.clone(TUNING)
	copy.Scale = scale
	return copy
end

return function()
	describe("CameraMotionMath.SpeedFov", function()
		it("is zero at and below sprint pace and for a gentle fall", function()
			expect(CameraMotionMath.SpeedFov(0, 0, TUNING)).to.equal(0)
			expect(CameraMotionMath.SpeedFov(TUNING.Fov.StartSpeed, 0, TUNING)).to.equal(0)
			expect(CameraMotionMath.SpeedFov(10, TUNING.Fov.FallStartSpeed, TUNING)).to.equal(0)
		end)

		it("widens monotonically and caps at the configured maximum", function()
			local previous = 0
			for speed = TUNING.Fov.StartSpeed, TUNING.Fov.FullSpeed, 2 do
				local fov = CameraMotionMath.SpeedFov(speed, 0, TUNING)
				expect(fov >= previous).to.equal(true)
				previous = fov
			end
			expect(CameraMotionMath.SpeedFov(500, 0, TUNING)).to.be.near(TUNING.Fov.MaxDelta, 1e-6)
		end)

		it("adds free fall on top, bounded by both maxima together", function()
			local both = CameraMotionMath.SpeedFov(500, 500, TUNING)
			expect(both).to.be.near(TUNING.Fov.MaxDelta + TUNING.Fov.FallMaxDelta, 1e-6)
		end)
	end)

	describe("CameraMotionMath.Step", function()
		it("holds still for a body that is not moving", function()
			local state = CameraMotionMath.NewState()
			local out = run(state, steady(Vector3.zero), 2, 60)
			expect(out.Roll).to.equal(0)
			expect(out.Pull).to.equal(0)
			expect(out.Dip).to.equal(0)
			expect(out.Fov).to.equal(0)
		end)

		it("does not lean for a steady run, however fast", function()
			local state = CameraMotionMath.NewState()
			local out = run(state, steady(Vector3.new(0, 0, -40)), 2, 60)
			expect(math.abs(out.Roll) < 1e-3).to.equal(true)
		end)

		it("leans into a strafe toward the camera's right, then comes back to level", function()
			local state = CameraMotionMath.NewState()
			local profile = strafeRight(30, 0.3, 20)
			local leaned = run(state, profile, 0.45, 60)
			-- Negative roll banks the right edge of the view down: into the turn.
			expect(leaned.Roll < -0.2 * MAX_LEAN).to.equal(true)
			local settled = run(state, profile, 2, 60)
			expect(math.abs(settled.Roll) < 0.02 * MAX_LEAN).to.equal(true)
		end)

		it("leans the other way for a strafe to the left", function()
			local state = CameraMotionMath.NewState()
			local leaned = run(state, strafeRight(30, 0.3, -20), 0.45, 60)
			expect(leaned.Roll > 0.2 * MAX_LEAN).to.equal(true)
		end)

		it("never leans past the configured maximum, even for an instant reversal", function()
			local reversal = function(time: number): Vector3
				return Vector3.new(if time >= 0.3 then -60 else 60, 0, 0)
			end
			expect(peakRoll(reversal, 1.5, 60) <= MAX_LEAN * 1.25).to.equal(true)
			expect(peakRoll(reversal, 1.5, 60) > 0.5 * MAX_LEAN).to.equal(true)
		end)

		it("barely leans for a body shuffling slowly, however sharply it changes", function()
			local shuffle = function(time: number): Vector3
				return Vector3.new(if time >= 0.3 then 3 else 0, 0, 0)
			end
			expect(peakRoll(shuffle, 1, 60) < 0.2 * MAX_LEAN).to.equal(true)
		end)

		it("gives the same lean at 30, 60, 144 and 240 fps", function()
			local profile = strafeRight(30, 0.3, 20)
			local reference = peakRoll(profile, 1.2, 240)
			for _, fps in { 30, 60, 144 } do
				local peak = peakRoll(profile, 1.2, fps)
				expect(math.abs(peak - reference) / reference < 0.2).to.equal(true)
			end
		end)

		it("pulls back and widens with planar speed, and not at walking pace", function()
			local walking = run(CameraMotionMath.NewState(), steady(Vector3.new(0, 0, -16)), 3, 60)
			local running = run(CameraMotionMath.NewState(), steady(Vector3.new(0, 0, -50)), 3, 60)
			expect(walking.Pull).to.equal(0)
			expect(walking.Fov).to.equal(0)
			expect(running.Pull > 0.9 * TUNING.Pull.MaxStuds).to.equal(true)
			expect(running.Pull <= TUNING.Pull.MaxStuds + 1e-6).to.equal(true)
			expect(running.Fov).to.be.near(TUNING.Fov.MaxDelta, 0.1)
		end)

		it("releases the pull and the lean when the body stops", function()
			local state = CameraMotionMath.NewState()
			run(state, steady(Vector3.new(0, 0, -50)), 2, 60)
			local stopped = run(state, steady(Vector3.zero), 3, 60)
			expect(stopped.Pull < 0.01).to.equal(true)
			expect(stopped.Fov).to.equal(0)
		end)

		it("widens for free fall", function()
			local out = run(CameraMotionMath.NewState(), steady(Vector3.new(0, -140, 0)), 2, 60)
			expect(out.Fov).to.be.near(TUNING.Fov.FallMaxDelta, 0.1)
		end)

		it("holds the last outputs for a frame with no time in it, and survives a long one", function()
			local state = CameraMotionMath.NewState()
			run(state, steady(Vector3.new(0, 0, -50)), 1, 60)
			local before = step(state, Vector3.new(0, 0, -50), 60)
			local roll, pull = CameraMotionMath.Step(state, Vector3.new(0, 0, -50), RIGHT, false, 0, TUNING)
			expect(roll).to.equal(before.Roll)
			expect(pull).to.equal(before.Pull)
			local _, longPull = CameraMotionMath.Step(state, Vector3.new(0, 0, -50), RIGHT, false, 30, TUNING)
			expect(longPull <= TUNING.Pull.MaxStuds + 1e-6).to.equal(true)
		end)
	end)

	describe("CameraMotionMath.Step landings", function()
		it("compresses on a landing and recovers to neutral", function()
			local state = CameraMotionMath.NewState()
			local severity: number? = nil
			local peak = 0
			local profile = landingAt(100, 0.2)
			step(state, profile(0), 60)
			for frame = 1, 90 do
				local out = step(state, profile(frame / 60), 60)
				severity = severity or out.Severity
				peak = math.max(peak, out.Dip)
			end
			expect(severity ~= nil).to.equal(true)
			expect(peak > TUNING.Landing.SoftDipStuds).to.equal(true)
			local settled = step(state, Vector3.zero, 60)
			expect(math.abs(settled.Dip) < 0.01).to.equal(true)
		end)

		it("reports the landing on exactly one frame", function()
			local state = CameraMotionMath.NewState()
			local reports = 0
			local profile = landingAt(100, 0.2)
			step(state, profile(0), 60)
			for frame = 1, 90 do
				if step(state, profile(frame / 60), 60).Severity ~= nil then
					reports += 1
				end
			end
			expect(reports).to.equal(1)
		end)

		it("scales the compression with the impact, from the soft dip toward the hard one", function()
			local soft = peakDip(TUNING.Landing.MinImpactSpeed + 2, 60)
			local hard = peakDip(TUNING.Landing.FullImpactSpeed, 60)
			expect(soft > 0.8 * TUNING.Landing.SoftDipStuds).to.equal(true)
			expect(hard > soft * 2.5).to.equal(true)
			expect(hard <= TUNING.Landing.HardDipStuds * 1.3 + 1e-6).to.equal(true)
		end)

		it("peaks at the configured dip", function()
			expect(peakDip(TUNING.Landing.FullImpactSpeed, 240)).to.be.near(TUNING.Landing.HardDipStuds, 0.12)
			expect(peakDip(TUNING.Landing.MinImpactSpeed + 1, 240)).to.be.near(TUNING.Landing.SoftDipStuds, 0.06)
		end)

		it("is the same landing at 30, 60, 144 and 240 fps", function()
			local reference = peakDip(120, 240)
			for _, fps in { 30, 60, 144 } do
				expect(math.abs(peakDip(120, fps) - reference) / reference < 0.12).to.equal(true)
			end
		end)

		it("does not feel an ordinary jump's landing, a step down or a takeoff", function()
			expect(peakDip(TUNING.Landing.MinImpactSpeed - 6, 60)).to.equal(0)
			local state = CameraMotionMath.NewState()
			step(state, Vector3.zero, 60)
			local takeoff = step(state, Vector3.new(0, 52, 0), 60)
			expect(takeoff.Severity).to.equal(nil)
			expect(takeoff.Dip).to.equal(0)
		end)

		it("counts only the speed the body actually lost", function()
			-- 140 studs/s falling, slowed to 100: 40 studs/s absorbed, under the threshold.
			local state = CameraMotionMath.NewState()
			step(state, Vector3.new(0, -140, 0), 60)
			local out = step(state, Vector3.new(0, -100, 0), 60)
			expect(out.Severity).to.equal(nil)
		end)

		it("does not report two landings inside the cooldown", function()
			local state = CameraMotionMath.NewState()
			step(state, Vector3.new(0, -100, 0), 60)
			expect(step(state, Vector3.zero, 60).Severity ~= nil).to.equal(true)
			step(state, Vector3.new(0, -100, 0), 60)
			expect(step(state, Vector3.zero, 60).Severity).to.equal(nil)
		end)

		it("keeps the rebound above the camera inside its bound", function()
			local state = CameraMotionMath.NewState()
			local lowest = 0
			local profile = landingAt(150, 0.1)
			step(state, profile(0), 60)
			for frame = 1, 120 do
				lowest = math.min(lowest, step(state, profile(frame / 60), 60).Dip)
			end
			expect(lowest >= -TUNING.Landing.MaxReboundStuds - 1e-6).to.equal(true)
		end)
	end)

	describe("CameraMotionMath.Step while suspended", function()
		it("eases every channel out and stays at neutral for a body something else is moving", function()
			local state = CameraMotionMath.NewState()
			run(state, strafeRight(40, 0.1, 25), 1, 60)
			local out = run(state, strafeRight(40, 0.1, 25), 2, 60, true)
			expect(math.abs(out.Roll) < 1e-3).to.equal(true)
			expect(out.Pull < 0.01).to.equal(true)
			expect(out.Fov).to.equal(0)
		end)

		it("reports no landing while suspended, nor on the first frame released", function()
			local state = CameraMotionMath.NewState()
			step(state, Vector3.new(0, -120, 0), 60, true)
			expect(step(state, Vector3.zero, 60, true).Severity).to.equal(nil)
			-- Held while falling, then released onto the ground in the same frame: an end of a hold, not an impact.
			step(state, Vector3.new(0, -120, 0), 60, true)
			expect(step(state, Vector3.zero, 60).Severity).to.equal(nil)
		end)

		it("feels a landing on the frame after a released body has been live once", function()
			local state = CameraMotionMath.NewState()
			step(state, Vector3.new(0, -120, 0), 60, true)
			step(state, Vector3.new(0, -120, 0), 60)
			expect(step(state, Vector3.zero, 60).Severity ~= nil).to.equal(true)
		end)

		it("does not read the end of a hold as a phantom acceleration", function()
			local state = CameraMotionMath.NewState()
			-- Carried sideways at 60 studs/s by something else, then released.
			run(state, steady(Vector3.new(60, 0, 0)), 1, 60, true)
			local peak = 0
			for _ = 1, 30 do
				peak = math.max(peak, math.abs(step(state, Vector3.new(60, 0, 0), 60).Roll))
			end
			expect(peak < 0.05 * MAX_LEAN).to.equal(true)
		end)

		it("forgets everything on Reset", function()
			local state = CameraMotionMath.NewState()
			run(state, strafeRight(40, 0.1, 25), 0.6, 60)
			CameraMotionMath.Reset(state)
			local out = step(state, Vector3.zero, 60)
			expect(out.Roll).to.equal(0)
			expect(out.Pull).to.equal(0)
			expect(out.Dip).to.equal(0)
		end)
	end)

	describe("CameraMotionMath.Step intensity", function()
		it("silences a channel at 0 and halves it at 0.5", function()
			local full = peakDip(120, 60)
			local state = CameraMotionMath.NewState()
			local silent = withScale({ Lean = 0, Pull = 0, Fov = 0, Landing = 0 })
			local out = step(state, Vector3.new(0, 0, -50), 60, nil, silent)
			for _ = 1, 180 do
				out = step(state, Vector3.new(0, 0, -50), 60, nil, silent)
			end
			expect(out.Pull).to.equal(0)
			expect(out.Fov).to.equal(0)

			local half = withScale({ Lean = 0.5, Pull = 0.5, Fov = 0.5, Landing = 0.5 })
			local halfState = CameraMotionMath.NewState()
			local halfOut = step(halfState, Vector3.new(0, 0, -50), 60, nil, half)
			for _ = 1, 240 do
				halfOut = step(halfState, Vector3.new(0, 0, -50), 60, nil, half)
			end
			expect(halfOut.Pull).to.be.near(TUNING.Pull.MaxStuds * 0.5, 0.02)
			expect(halfOut.Fov).to.be.near(TUNING.Fov.MaxDelta * 0.5, 0.05)

			local landing = CameraMotionMath.NewState()
			local peak = 0
			step(landing, Vector3.new(0, -120, 0), 60, nil, half)
			for frame = 1, 90 do
				peak = math.max(
					peak,
					step(landing, if frame < 3 then Vector3.new(0, -120, 0) else Vector3.zero, 60, nil, half).Dip
				)
			end
			expect(peak < full * 0.65).to.equal(true)
		end)
	end)
end
