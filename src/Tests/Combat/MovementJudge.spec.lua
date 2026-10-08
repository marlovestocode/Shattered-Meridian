--!strict
-- Covers Shared/Combat/MovementJudge.lua -- the pure verdict behind Server/Combat/MovementGuard.lua. The cases that
-- matter most are the honest ones that look suspicious: a running player, a stall then a catch-up, a jump.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementGuardConstants = require(ReplicatedStorage.Shared.Combat.MovementGuardConstants)
local MovementJudge = require(ReplicatedStorage.Shared.Combat.MovementJudge)

local WINDOW = MovementGuardConstants.Speed.WindowSeconds
local RUN = 54 -- the top run gear (RunConstants), studs/s

return function()
	describe("MovementJudge", function()
		-- Moves a body along X at `speed` for `seconds`, sampled every 0.1s. Returns the worst verdict seen.
		local function run(track: any, from: Vector3, speed: number, seconds: number, start: number, allowed: number)
			local worst = "Ok"
			local steps = math.floor(seconds / 0.1 + 0.5)
			for index = 0, steps do
				local at = start + index * 0.1
				local verdict = MovementJudge.Judge(track, from + Vector3.new(speed * index * 0.1, 0, 0), at, allowed)
				if verdict ~= "Ok" then
					worst = verdict
				end
			end
			return worst
		end

		it("passes a player running at their own WalkSpeed", function()
			local track = MovementJudge.NewTrack()
			expect(run(track, Vector3.zero, RUN, 3, 0, RUN)).to.equal("Ok")
		end)

		it("flags a body covering far more ground than its WalkSpeed allows", function()
			local track = MovementJudge.NewTrack()
			expect(run(track, Vector3.zero, RUN * 2, 2, 0, RUN)).to.equal("Speed")
		end)

		it("judges a stall then a catch-up over the whole stall, not one frame", function()
			-- One second with no replicated movement, then a packet carrying the second's worth at once.
			local track = MovementJudge.NewTrack()
			MovementJudge.Judge(track, Vector3.zero, 0, RUN)
			for index = 1, 9 do
				MovementJudge.Judge(track, Vector3.zero, index * 0.1, RUN)
			end
			local verdict = MovementJudge.Judge(track, Vector3.new(RUN, 0, 0), 1.0, RUN)
			expect(verdict).never.to.equal("Teleport")
		end)

		it("calls a sudden jump across the arena a teleport", function()
			local track = MovementJudge.NewTrack()
			MovementJudge.Judge(track, Vector3.zero, 0, RUN)
			local verdict, detail = MovementJudge.Judge(track, Vector3.new(80, 0, 0), 0.1, RUN)
			expect(verdict).to.equal("Teleport")
			expect(detail ~= nil).to.equal(true)
		end)

		it("does not judge a jump's arc as a climb, but does a body flying straight up", function()
			local jump = MovementJudge.NewTrack()
			MovementJudge.Judge(jump, Vector3.zero, 0, RUN)
			expect((MovementJudge.Judge(jump, Vector3.new(0, 6, 0), WINDOW, RUN))).to.equal("Ok")

			local fly = MovementJudge.NewTrack()
			MovementJudge.Judge(fly, Vector3.zero, 0, RUN)
			expect((MovementJudge.Judge(fly, Vector3.new(0, 40, 0), WINDOW, RUN))).to.equal("Rise")
		end)

		it("skips the climb check while a parkour action owns the body", function()
			local track = MovementJudge.NewTrack()
			MovementJudge.Judge(track, Vector3.zero, 0, RUN, false)
			expect((MovementJudge.Judge(track, Vector3.new(0, 40, 0), WINDOW, RUN, false))).to.equal("Ok")
		end)

		it("starts over from a reset track", function()
			local track = MovementJudge.NewTrack()
			MovementJudge.Judge(track, Vector3.zero, 0, RUN)
			MovementJudge.ResetTrack(track)
			-- The first sample after a reset only seeds the track, however far the body is from the old one.
			expect((MovementJudge.Judge(track, Vector3.new(500, 0, 0), 0.1, RUN))).to.equal("Ok")
		end)
	end)
end
