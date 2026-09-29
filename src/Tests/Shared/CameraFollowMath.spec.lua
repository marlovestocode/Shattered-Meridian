--!strict
-- Covers Shared/CameraFollowMath.lua -- the smoothed camera follow's arithmetic. Pure, so every case drives
-- it with plain vectors and a fixed frame time; no camera and no character.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraFollowMath = require(ReplicatedStorage.Shared.CameraFollowMath)

local FRAME = 1 / 60

local TUNING: CameraFollowMath.Tuning = {
	HorizontalFrequency = 14,
	VerticalFrequency = 16,
	Damping = 1,
	MaxHorizontalLagStuds = 1.1,
	MaxVerticalLagStuds = 0.8,
	TeleportStuds = 8,
}

-- Runs `frames` steps with the target moving at `velocity` from `from`, returning the last lag.
local function run(state: CameraFollowMath.State, from: Vector3, velocity: Vector3, frames: number): (Vector3, Vector3)
	local target = from
	local lag = Vector3.zero
	for _ = 1, frames do
		target += velocity * FRAME
		lag = CameraFollowMath.Step(state, target, FRAME, TUNING)
	end
	return lag, target
end

return function()
	describe("CameraFollowMath.Step", function()
		it("seats on the first frame with no lag", function()
			local state = CameraFollowMath.NewState()
			local lag = CameraFollowMath.Step(state, Vector3.new(5, 2, -3), FRAME, TUNING)
			expect(lag.Magnitude).to.equal(0)
		end)

		it("eases into a sudden step instead of moving with it on the first frame", function()
			-- A punch's step-in: the body goes from standing to ~15 studs/s in one frame. The camera must not.
			local state = CameraFollowMath.NewState()
			CameraFollowMath.Step(state, Vector3.zero, FRAME, TUNING)
			local lag, target = run(state, Vector3.zero, Vector3.new(15, 0, 0), 1)
			local cameraMoved = (target + lag).X
			expect(cameraMoved < target.X * 0.5).to.equal(true)
		end)

		it("catches up once the body stops, without swinging past it", function()
			local state = CameraFollowMath.NewState()
			CameraFollowMath.Step(state, Vector3.zero, FRAME, TUNING)
			-- A 2.4-stud step over 0.16s, then stand still for half a second.
			local _, target = run(state, Vector3.zero, Vector3.new(15, 0, 0), 10)
			local worstOvershoot = 0
			local lag = Vector3.zero
			for _ = 1, 30 do
				lag = CameraFollowMath.Step(state, target, FRAME, TUNING)
				worstOvershoot = math.max(worstOvershoot, lag.X)
			end
			expect(math.abs(lag.X) < 0.05).to.equal(true)
			-- Critically damped: at most a hair past the body.
			expect(worstOvershoot < 0.1).to.equal(true)
		end)

		it("never trails further than the horizontal and vertical bounds", function()
			local state = CameraFollowMath.NewState()
			CameraFollowMath.Step(state, Vector3.zero, FRAME, TUNING)
			local lag = run(state, Vector3.zero, Vector3.new(60, -60, 0), 60)
			local flat = Vector3.new(lag.X, 0, lag.Z).Magnitude
			expect(flat <= TUNING.MaxHorizontalLagStuds + 1e-6).to.equal(true)
			expect(math.abs(lag.Y) <= TUNING.MaxVerticalLagStuds + 1e-6).to.equal(true)
		end)

		it("re-seats on a teleport rather than animating across it", function()
			local state = CameraFollowMath.NewState()
			CameraFollowMath.Step(state, Vector3.zero, FRAME, TUNING)
			local lag = CameraFollowMath.Step(state, Vector3.new(500, 0, 0), FRAME, TUNING)
			expect(lag.Magnitude).to.equal(0)
		end)

		it("holds the trail on a frame with no time in it", function()
			local state = CameraFollowMath.NewState()
			CameraFollowMath.Step(state, Vector3.zero, FRAME, TUNING)
			local moving, target = run(state, Vector3.zero, Vector3.new(15, 0, 0), 3)
			local held = CameraFollowMath.Step(state, target, 0, TUNING)
			expect(held.X).to.be.near(moving.X, 1e-6)
		end)

		it("forgets the trail on Reset", function()
			local state = CameraFollowMath.NewState()
			CameraFollowMath.Step(state, Vector3.zero, FRAME, TUNING)
			local _, target = run(state, Vector3.zero, Vector3.new(15, 0, 0), 5)
			CameraFollowMath.Reset(state)
			local lag = CameraFollowMath.Step(state, target, FRAME, TUNING)
			expect(lag.Magnitude).to.equal(0)
		end)
	end)
end
