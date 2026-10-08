--!strict
-- Covers Server/Combat/HitboxEngine/PoseHistory.lua -- the per-body ring of root positions that
-- lag-compensated hits rewind. Pure: no Workspace, the clock is whatever the case passes.

local ServerScriptService = game:GetService("ServerScriptService")

local PoseHistory = require(ServerScriptService.Server.Combat.HitboxEngine.PoseHistory)

local function near(a: Vector3?, b: Vector3): boolean
	return a ~= nil and (a - b).Magnitude < 1e-6
end

return function()
	describe("PoseHistory", function()
		it("has nothing to say while empty", function()
			local history = PoseHistory.New(4)
			expect(PoseHistory.At(history, 1)).to.equal(nil)
			expect(PoseHistory.DisplacementSince(history, 1)).to.equal(Vector3.zero)
		end)

		it("interpolates between the two samples around a time", function()
			local history = PoseHistory.New(4)
			PoseHistory.Record(history, 1, Vector3.new(0, 0, 0))
			PoseHistory.Record(history, 2, Vector3.new(10, 0, 0))
			expect(near(PoseHistory.At(history, 1.25), Vector3.new(2.5, 0, 0))).to.equal(true)
		end)

		it("holds the newest sample past the end, and the oldest before the start", function()
			local history = PoseHistory.New(4)
			PoseHistory.Record(history, 1, Vector3.new(1, 0, 0))
			PoseHistory.Record(history, 2, Vector3.new(2, 0, 0))
			expect(near(PoseHistory.At(history, 5), Vector3.new(2, 0, 0))).to.equal(true)
			expect(near(PoseHistory.At(history, 0), Vector3.new(1, 0, 0))).to.equal(true)
		end)

		it("overwrites its oldest sample once full", function()
			local history = PoseHistory.New(3)
			for time = 1, 5 do
				PoseHistory.Record(history, time, Vector3.new(time, 0, 0))
			end
			expect(history.Count).to.equal(3)
			-- Samples 3, 4, 5 remain: a time before 3 reads as the oldest kept.
			expect(near(PoseHistory.At(history, 1), Vector3.new(3, 0, 0))).to.equal(true)
			expect(near(PoseHistory.At(history, 4.5), Vector3.new(4.5, 0, 0))).to.equal(true)
		end)

		it("keeps the last of two records in one instant", function()
			local history = PoseHistory.New(3)
			PoseHistory.Record(history, 1, Vector3.new(1, 0, 0))
			PoseHistory.Record(history, 1, Vector3.new(7, 0, 0))
			expect(history.Count).to.equal(1)
			expect(near(PoseHistory.At(history, 1), Vector3.new(7, 0, 0))).to.equal(true)
		end)

		it("measures how far the body has moved since a time", function()
			local history = PoseHistory.New(8)
			PoseHistory.Record(history, 0, Vector3.new(0, 0, -5))
			PoseHistory.Record(history, 0.1, Vector3.new(0, 0, -8))
			PoseHistory.Record(history, 0.2, Vector3.new(0, 0, -11))
			expect(near(PoseHistory.DisplacementSince(history, 0.05), Vector3.new(0, 0, -4.5))).to.equal(true)
		end)
	end)
end
