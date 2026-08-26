--!strict
-- Covers Shared/Blimp/BlimpSpeedStage.lua -- which of the three flight stages a hull is in, and the
-- hysteresis that decides when it has genuinely changed rather than merely wobbled.
--
-- The hysteresis is the only interesting thing in that module and it is the one thing that cannot be
-- checked by reading it: "does a hull sitting exactly on a boundary stay put" is a question about a
-- loop's interaction with its own previous answer. Without it the feature it serves is not subtly
-- wrong, it is a machine-gun of stage-change sounds -- so this is the spec that stops that shipping.
--
-- Written against the LIVE constants rather than a fixture, deliberately: every assertion below is
-- about the SHAPE of the response (it climbs, it saturates, it holds on a boundary), not about a
-- particular threshold, so a retune of the bands does not turn into a test failure that says nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpSpeedStage = require(ReplicatedStorage.Shared.Blimp.BlimpSpeedStage)

local COUNT = BlimpSpeedStage.Count()
local HALF_BAND = BlimpConstants.Audio.StageHysteresis / 2

return function()
	describe("the shipped stages", function()
		it("ships exactly the three the feature is named for", function()
			expect(COUNT).to.equal(3)
		end)

		it("starts its first stage at a standstill", function()
			-- The first stage's floor has to be 0 or a stopped hull is in no stage at all.
			expect(BlimpSpeedStage.At(1).EnterFraction).to.equal(0)
		end)

		it("orders its floors strictly upward", function()
			for index = 2, COUNT do
				expect(BlimpSpeedStage.At(index).EnterFraction > BlimpSpeedStage.At(index - 1).EnterFraction).to.equal(
					true
				)
			end
		end)

		it("separates every floor by more than the dead band", function()
			-- If two floors sat closer together than the hysteresis, the band around one would swallow
			-- the other and a stage would become unreachable -- silently, and only at some speeds.
			for index = 2, COUNT do
				local gap = BlimpSpeedStage.At(index).EnterFraction - BlimpSpeedStage.At(index - 1).EnterFraction
				expect(gap > BlimpConstants.Audio.StageHysteresis).to.equal(true)
			end
		end)

		it("gives every stage a distinct id, a label and a distinct pitch", function()
			-- The three stages are told apart by EAR before they are told apart by anything else -- one
			-- sound at three pitches (see BlimpConstants.Audio.StageChangeSound) -- so two stages
			-- sharing a playback speed would be two stages a player cannot distinguish.
			local seenId: { [string]: boolean } = {}
			local seenPitch: { [number]: boolean } = {}
			for index = 1, COUNT do
				local stage = BlimpSpeedStage.At(index)
				expect(seenId[stage.Id]).to.never.be.ok()
				expect(seenPitch[stage.PlaybackSpeed]).to.never.be.ok()
				seenId[stage.Id] = true
				seenPitch[stage.PlaybackSpeed] = true
				expect(#stage.Label > 0).to.equal(true)
			end
		end)
	end)

	describe("Resolve", function()
		it("climbs as the ship speeds up", function()
			expect(BlimpSpeedStage.Resolve(1, 0)).to.equal(1)
			expect(BlimpSpeedStage.Resolve(1, 1)).to.equal(COUNT)
		end)

		it("falls back as it slows down", function()
			expect(BlimpSpeedStage.Resolve(COUNT, 0)).to.equal(1)
		end)

		it("saturates at both ends rather than running off the array", function()
			expect(BlimpSpeedStage.Resolve(COUNT, 99)).to.equal(COUNT)
			expect(BlimpSpeedStage.Resolve(1, -99)).to.equal(1)
		end)

		it("crosses several bands in ONE call, not one per frame", function()
			-- Boarding a ship already at flank, or a landing hull dropping to a standstill, must land on
			-- the right stage immediately. Stepping through the intervening ones a frame at a time would
			-- play every stage sound on the way past.
			local landed = BlimpSpeedStage.Resolve(1, 1)
			expect(landed).to.equal(COUNT)
		end)
	end)

	describe("hysteresis -- the reason this module exists", function()
		it("holds its stage for a hull sitting exactly on a boundary", function()
			-- THE case. A hull holding station on a threshold has a speed that jitters by a fraction of
			-- a percent from the solver alone; a bare comparison would flip every frame, and every flip
			-- is an audible ping.
			for index = 2, COUNT do
				local floor = BlimpSpeedStage.At(index).EnterFraction
				-- Sitting exactly on the line, having arrived from below: it must NOT have entered.
				expect(BlimpSpeedStage.Resolve(index - 1, floor)).to.equal(index - 1)
				-- And having arrived from above: it must NOT have left.
				expect(BlimpSpeedStage.Resolve(index, floor)).to.equal(index)
			end
		end)

		it("survives jitter around a boundary without ever changing stage", function()
			local floor = BlimpSpeedStage.At(2).EnterFraction
			local index = 1
			for step = 1, 200 do
				-- A sawtooth straddling the threshold by well under the dead band, which is exactly what
				-- replication jitter looks like.
				local wobble = (if step % 2 == 0 then 1 else -1) * HALF_BAND * 0.6
				index = BlimpSpeedStage.Resolve(index, floor + wobble)
			end
			expect(index).to.equal(1)
		end)

		it("still changes for a crossing that is actually meant", function()
			-- The dead band must not be so wide that a real acceleration cannot get through it.
			local floor = BlimpSpeedStage.At(2).EnterFraction
			expect(BlimpSpeedStage.Resolve(1, floor + HALF_BAND)).to.equal(2)
			expect(BlimpSpeedStage.Resolve(2, floor - HALF_BAND - 1e-6)).to.equal(1)
		end)

		it("keeps a NaN speed on the stage it already had", function()
			-- Reachable from a divide by a zero cruise speed. NaN fails every comparison, so both loops
			-- would fall through and latch -- which is the right answer, but only by accident unless it
			-- is asserted.
			expect(BlimpSpeedStage.Resolve(2, 0 / 0)).to.equal(2)
		end)
	end)
end
