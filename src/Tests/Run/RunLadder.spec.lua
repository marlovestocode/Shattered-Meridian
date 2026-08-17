--!strict
-- Covers Shared/Run/RunLadder.lua -- the pure arithmetic the run's three-stage ladder runs on, shared
-- by the server (which resolves the authoritative stage and the WalkSpeed that follows from it) and
-- the client (which presents it).
--
-- Instance-free by design, so every case below is plain arithmetic with no Humanoid, no Player and no
-- yielding. Weighted toward the cases that are easy to get wrong and expensive to notice in a
-- playtest: the hysteresis boundaries (which is where a gear flickers), the freeze-versus-decay split
-- (which is what makes vaulting mid-run not cost a gear), and the "held intent short-circuits
-- everything" rule that keeps a released key from reading as a stage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local RunLadder = require(ReplicatedStorage.Shared.Run.RunLadder)

local function expectClose(actual: number, expected: number, tolerance: number?): ()
	local allowed = tolerance or 1e-4
	expect(math.abs(actual - expected) <= allowed).to.equal(true)
end

-- Read from the config rather than hardcoded, so retuning the ladder retunes these tests with it. A
-- spec that hardcodes 7 and 16 fails for the wrong reason the first time someone moves a threshold --
-- it should be asserting the RELATIONSHIPS, not restating the numbers.
local STAGES = RunConstants.Stages
local TOP = STAGES[#STAGES]
local SECOND = STAGES[2]

return function()
	describe("the ladder's own shape", function()
		it("defines at least three stages", function()
			expect(#STAGES >= 3).to.equal(true)
		end)

		it("is ordered: every stage is faster and costs more charge than the one below it", function()
			for index = 2, #STAGES do
				local lower = STAGES[index - 1]
				local higher = STAGES[index]
				expect(higher.Id > lower.Id).to.equal(true)
				expect(higher.SpeedMultiplier > lower.SpeedMultiplier).to.equal(true)
				expect(higher.ChargeSeconds > lower.ChargeSeconds).to.equal(true)
			end
		end)

		it("caps the charge clock at the top stage's requirement", function()
			expect(RunConstants.MaxChargeSeconds).to.equal(TOP.ChargeSeconds)
		end)

		it("lets the first stage engage with no charge at all", function()
			expect(STAGES[1].ChargeSeconds).to.equal(0)
		end)
	end)

	describe("RunLadder.StepCharge", function()
		it("accrues while the tier is granted and the character is moving", function()
			expectClose(RunLadder.StepCharge(0, 0.5, true, false, 0), 0.5)
		end)

		it("stops accruing at the ladder's ceiling rather than banking indefinitely", function()
			local result = RunLadder.StepCharge(RunConstants.MaxChargeSeconds, 10, true, false, 0)
			expect(result).to.equal(RunConstants.MaxChargeSeconds)
		end)

		it("decays gently -- not resets -- inside the flicker grace window", function()
			local result = RunLadder.StepCharge(5, 1, false, false, 0)
			expectClose(result, 5 - RunConstants.ChargeDecayMultiplier)
			expect(result > 0).to.equal(true)
		end)

		-- THE STOP PENALTY. Past the grace window the player has genuinely stopped, and the charge has
		-- to bleed fast enough that they cannot stop and drop straight back into the gear they had.
		it("decays far faster once the stop grace window has passed", function()
			local gentle = RunLadder.StepCharge(10, 1, false, false, 0)
			local aggressive = RunLadder.StepCharge(10, 1, false, false, RunConstants.StopGraceSeconds + 0.01)
			expect(aggressive < gentle).to.equal(true)
			expectClose(aggressive, 10 - RunConstants.StopDecayMultiplier)
		end)

		it("never decays below zero, at either rate", function()
			expect(RunLadder.StepCharge(0.1, 10, false, false, 0)).to.equal(0)
			expect(RunLadder.StepCharge(0.1, 10, false, false, 99)).to.equal(0)
		end)

		-- THE VAULT CASE. This is the rule that stops the movement system from punishing the player for
		-- using the movement system -- see RunConstants.Stages' own header.
		it("freezes -- neither accruing nor decaying -- while a parkour action owns velocity", function()
			expect(RunLadder.StepCharge(5, 1, true, true, 0)).to.equal(5)
			expect(RunLadder.StepCharge(5, 1, false, true, 0)).to.equal(5)
			-- Frozen outranks the stop penalty: a long vault must not be billed as a long stop.
			expect(RunLadder.StepCharge(5, 1, false, true, 99)).to.equal(5)
		end)

		it("ignores a non-positive delta rather than integrating backwards", function()
			expect(RunLadder.StepCharge(5, 0, true, false, 0)).to.equal(5)
			expect(RunLadder.StepCharge(5, -1, false, false, 0)).to.equal(5)
		end)
	end)

	describe("RunLadder.ResolveStage", function()
		it("is stage 0 whenever the run is not held, however much charge is banked", function()
			expect(RunLadder.ResolveStage(TOP.Id, RunConstants.MaxChargeSeconds, false)).to.equal(0)
		end)

		it("is stage 1 the moment the run is held, with no charge", function()
			expect(RunLadder.ResolveStage(0, 0, true)).to.equal(1)
		end)

		it("reaches each stage at exactly its authored charge requirement", function()
			for _, stage in STAGES do
				expect(RunLadder.ResolveStage(0, stage.ChargeSeconds, true)).to.equal(stage.Id)
			end
		end)

		it("refuses a stage a hair below its requirement when climbing into it", function()
			expect(RunLadder.ResolveStage(1, SECOND.ChargeSeconds - 1e-3, true)).to.equal(1)
		end)

		-- THE HYSTERESIS. Entering costs the full requirement; staying costs only SustainFraction of it.
		-- Without this a single frame of the tier not being granted drops a gear and re-earns it a few
		-- frames later, which the player hears as the onset kick replaying every time they brush a wall.
		it("holds a stage below its entry requirement, down to its sustain floor", function()
			local justInside = SECOND.ChargeSeconds * SECOND.SustainFraction + 1e-3
			-- Climbing into it from below at this charge is refused...
			expect(RunLadder.ResolveStage(1, justInside, true)).to.equal(1)
			-- ...but holding it at the very same charge is not.
			expect(RunLadder.ResolveStage(SECOND.Id, justInside, true)).to.equal(SECOND.Id)
		end)

		it("finally drops a held stage once the charge falls through its sustain floor", function()
			local justBelow = SECOND.ChargeSeconds * SECOND.SustainFraction - 1e-3
			expect(RunLadder.ResolveStage(SECOND.Id, justBelow, true)).to.equal(1)
		end)

		it("drops the top gear to the one below it, not all the way to stage 1", function()
			local belowTopSustain = TOP.ChargeSeconds * TOP.SustainFraction - 1e-3
			-- That charge is still comfortably above stage 2's own entry requirement, so the fall is one
			-- gear rather than a collapse -- the property that makes the ladder feel like gears.
			expect(belowTopSustain > SECOND.ChargeSeconds).to.equal(true)
			expect(RunLadder.ResolveStage(TOP.Id, belowTopSustain, true)).to.equal(SECOND.Id)
		end)
	end)

	describe("RunLadder.SpeedMultiplier", function()
		it("returns each stage's authored multiplier", function()
			for _, stage in STAGES do
				expect(RunLadder.SpeedMultiplier(stage.Id)).to.equal(stage.SpeedMultiplier)
			end
		end)

		-- Defaulting to "no bonus" rather than to the nearest stage is the safe direction to be wrong in:
		-- an unknown stage must never hand out speed.
		it("returns a plain 1 for stage 0 and for any stage the ladder does not define", function()
			expect(RunLadder.SpeedMultiplier(0)).to.equal(1)
			expect(RunLadder.SpeedMultiplier(TOP.Id + 1)).to.equal(1)
			expect(RunLadder.SpeedMultiplier(-1)).to.equal(1)
		end)

		it("never grants less than walking for a real stage", function()
			for _, stage in STAGES do
				expect(stage.SpeedMultiplier >= 1).to.equal(true)
			end
		end)
	end)

	describe("RunLadder.MaxStage", function()
		it("is the top of the ladder", function()
			expect(RunLadder.MaxStage()).to.equal(TOP.Id)
		end)
	end)

	describe("RunLadder.ChargeProgress", function()
		it("is 0 while not running", function()
			expect(RunLadder.ChargeProgress(0, 12)).to.equal(0)
		end)

		it("is 1 in the top gear, which has nothing left to fill toward", function()
			expect(RunLadder.ChargeProgress(TOP.Id, TOP.ChargeSeconds)).to.equal(1)
		end)

		it("fills from 0 to 1 across the gap to the next gear", function()
			expect(RunLadder.ChargeProgress(1, STAGES[1].ChargeSeconds)).to.equal(0)
			expectClose(RunLadder.ChargeProgress(1, SECOND.ChargeSeconds / 2), 0.5)
			expect(RunLadder.ChargeProgress(1, SECOND.ChargeSeconds)).to.equal(1)
		end)

		it("clamps rather than exceeding 1 for a charge past the next gear", function()
			expect(RunLadder.ChargeProgress(1, RunConstants.MaxChargeSeconds)).to.equal(1)
		end)
	end)

	-- INTEGRATION, at the level the two consumers actually experience: run for N seconds and see which
	-- gear you are in. This is the one that would catch a sign error or an off-by-one in the loop that
	-- no single-function test above would.
	describe("running for real time", function()
		-- Mirrors RunSystem.stepPlayer's own loop, including the NotAccruingSeconds counter it keeps, so
		-- these assert the behavior a player actually experiences rather than one function's arithmetic.
		local function simulate(
			seconds: number,
			accruing: boolean,
			startCharge: number,
			startStage: number
		): (number, number)
			local charge = startCharge
			local stage = startStage
			local notAccruing = 0
			local step = 1 / 60
			for _ = 1, math.floor(seconds / step) do
				if accruing then
					notAccruing = 0
				else
					notAccruing += step
				end
				charge = RunLadder.StepCharge(charge, step, accruing, false, notAccruing)
				stage = RunLadder.ResolveStage(stage, charge, true)
			end
			return stage, charge
		end

		local function runFor(seconds: number): (number, number)
			return simulate(seconds, true, 0, 0)
		end

		it("is in first gear immediately", function()
			local stage = runFor(0.5)
			expect(stage).to.equal(1)
		end)

		it("reaches second gear shortly after its threshold", function()
			local stage = runFor(SECOND.ChargeSeconds + 0.5)
			expect(stage).to.equal(SECOND.Id)
		end)

		it("has NOT reached the top gear at second gear's threshold", function()
			local stage = runFor(SECOND.ChargeSeconds + 0.5)
			expect(stage < TOP.Id).to.equal(true)
		end)

		it("reaches the top gear shortly after its own threshold", function()
			local stage = runFor(TOP.ChargeSeconds + 0.5)
			expect(stage).to.equal(TOP.Id)
		end)

		it("climbs the gears in order, never skipping one", function()
			local charge = 0
			local stage = 0
			local seen: { number } = {}
			local step = 1 / 60
			for _ = 1, math.floor((TOP.ChargeSeconds + 1) / step) do
				charge = RunLadder.StepCharge(charge, step, true, false)
				local nextStage = RunLadder.ResolveStage(stage, charge, true)
				if nextStage ~= stage then
					table.insert(seen, nextStage)
					stage = nextStage
				end
			end
			expect(#seen).to.equal(#STAGES)
			for index, stageId in seen do
				expect(stageId).to.equal(STAGES[index].Id)
			end
		end)
	end)

	-- STOPPING HAS TO COST SOMETHING. The whole ladder is free if a player can stop, do something else,
	-- and resume at full stride -- there would be no reason to ever maintain a run. These are the tests
	-- for that rule, and they are deliberately expressed as "what happens when I stop for N seconds"
	-- rather than as decay arithmetic, because that is the thing that has to stay true.
	describe("stopping", function()
		local function simulateStop(seconds: number): (number, number)
			local charge = RunConstants.MaxChargeSeconds
			local stage = TOP.Id
			local notAccruing = 0
			local step = 1 / 60
			for _ = 1, math.floor(seconds / step) do
				notAccruing += step
				charge = RunLadder.StepCharge(charge, step, false, false, notAccruing)
				stage = RunLadder.ResolveStage(stage, charge, true)
			end
			return stage, charge
		end

		it("keeps the top gear through a momentary interruption inside the grace window", function()
			local stage = simulateStop(RunConstants.StopGraceSeconds)
			expect(stage).to.equal(TOP.Id)
		end)

		it("drops out of the top gear within a second of genuinely stopping", function()
			local stage = simulateStop(1)
			expect(stage < TOP.Id).to.equal(true)
		end)

		-- THE ONE THAT MATTERS: after a real stop the charge is below the top gear's ENTRY requirement,
		-- not merely below its sustain floor -- so resuming means re-earning the gear the long way rather
		-- than dropping straight back into it.
		it("leaves the charge below the top gear's entry requirement, not just its sustain floor", function()
			local _, charge = simulateStop(1.5)
			expect(charge < TOP.ChargeSeconds).to.equal(true)
			expect(charge < TOP.ChargeSeconds * TOP.SustainFraction).to.equal(true)
			-- And resuming from there does NOT hand the top gear back immediately.
			expect(RunLadder.ResolveStage(SECOND.Id, charge, true) < TOP.Id).to.equal(true)
		end)

		it("falls all the way to first gear after a few seconds of standing still", function()
			local stage, charge = simulateStop(4)
			expect(stage).to.equal(1)
			expect(charge).to.equal(0)
		end)
	end)
end
