--!strict
-- Covers the one normal run speed shared by the server's RunSystem and the client presentation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local RunLadder = require(ReplicatedStorage.Shared.Run.RunLadder)

local STAGES = RunConstants.Stages
local NORMAL_STAGE = STAGES[1]

return function()
	describe("the normal run speed", function()
		it("defines exactly one sprint stage", function()
			expect(#STAGES).to.equal(1)
			expect(NORMAL_STAGE.Id).to.equal(1)
			expect(NORMAL_STAGE.ChargeSeconds).to.equal(0)
			expect(NORMAL_STAGE.SustainFraction).to.equal(0)
			expect(RunConstants.MaxChargeSeconds).to.equal(0)
		end)

		it("has no second-stage presentation", function()
			expect(RunConstants.Footsteps.Stages[2]).to.equal(nil)
			expect(RunConstants.StageOnset[2]).to.equal(nil)
			expect(RunConstants.Animation.PlaybackSpeeds[2]).to.equal(nil)
		end)
	end)

	describe("RunLadder.StepCharge", function()
		it("cannot accrue speed-changing charge", function()
			expect(RunLadder.StepCharge(0, 10, true, false, 0)).to.equal(0)
			expect(RunLadder.StepCharge(4, 1, true, false, 0)).to.equal(0)
		end)
	end)

	describe("RunLadder.ResolveStage", function()
		it("is stage 0 while sprint is not held", function()
			expect(RunLadder.ResolveStage(NORMAL_STAGE.Id, 0, false)).to.equal(0)
		end)

		it("stays at the normal stage for the entire sprint", function()
			for _, charge in { 0, 1, 7, 60 } do
				expect(RunLadder.ResolveStage(0, charge, true)).to.equal(NORMAL_STAGE.Id)
				expect(RunLadder.ResolveStage(NORMAL_STAGE.Id, charge, true)).to.equal(NORMAL_STAGE.Id)
			end
		end)
	end)

	describe("RunLadder.SpeedMultiplier", function()
		it("returns the normal speed only for the sprint stage", function()
			expect(RunLadder.SpeedMultiplier(NORMAL_STAGE.Id)).to.equal(NORMAL_STAGE.SpeedMultiplier)
			expect(RunLadder.SpeedMultiplier(0)).to.equal(1)
			expect(RunLadder.SpeedMultiplier(2)).to.equal(1)
			expect(RunLadder.SpeedMultiplier(-1)).to.equal(1)
		end)
	end)

	describe("RunLadder progress", function()
		it("has no next speed stage to fill toward", function()
			expect(RunLadder.MaxStage()).to.equal(NORMAL_STAGE.Id)
			expect(RunLadder.ChargeProgress(0, 0)).to.equal(0)
			expect(RunLadder.ChargeProgress(NORMAL_STAGE.Id, 0)).to.equal(1)
		end)
	end)
end
