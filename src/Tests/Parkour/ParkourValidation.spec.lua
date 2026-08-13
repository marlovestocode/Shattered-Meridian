--!strict
-- Covers Shared/Parkour/ParkourValidation.lua -- the pure half of the Parkour System's trust
-- boundary.
--
-- This is the spec that matters most in this feature, for the reason that module's own header gives:
-- a validator that silently stops validating is indistinguishable from one that works. So the
-- hostile-input cases (wrong types, NaN, infinity, unknown action kinds) get as much attention as the
-- happy path, and every plausibility check gets both a passing and a failing case so a check that is
-- accidentally deleted fails a test rather than quietly widening.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourValidation = require(ReplicatedStorage.Shared.Parkour.ParkourValidation)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

type ActionReport = ParkourTypes.ActionReport

local CONFIG: ParkourValidation.ValidationConfig = {
	MaxReportedSpeed = 70,
	MaxVerticalGainStuds = 24,
	MaxTravelSpeed = 90,
	MaxActionSeconds = 8,
}

local ORIGIN = Vector3.new(0, 10, 0)

local function report(overrides: { [string]: any }?): ActionReport
	local built: ActionReport = {
		Kind = "Slide",
		Phase = "Start",
		Speed = 30,
		Position = ORIGIN,
		DurationSeconds = 2,
	}
	if overrides then
		for key, value in overrides do
			(built :: { [string]: any })[key] = value
		end
	end
	return built
end

local function observed(overrides: { [string]: any }?): ParkourValidation.ObservedState
	local built: ParkourValidation.ObservedState = {
		Position = ORIGIN,
		Now = 100,
		OpenKind = nil,
		OpenStartedAt = nil,
		OpenStartPosition = nil,
		LastSameKindAt = 0,
		MinSameKindIntervalSeconds = 0.06,
	}
	if overrides then
		for key, value in overrides do
			(built :: { [string]: any })[key] = value
		end
	end
	return built
end

return function()
	describe("ParkourValidation.Parse -- structural validation", function()
		it("accepts a well-formed payload", function()
			local parsed, reason = ParkourValidation.Parse({
				Kind = "Slide",
				Phase = "Start",
				Speed = 30,
				Position = ORIGIN,
				DurationSeconds = 2,
			})
			expect(parsed).to.be.ok()
			expect(reason).to.equal(nil)
			expect((parsed :: ActionReport).Kind).to.equal("Slide")
		end)

		it("accepts a payload with no duration -- that field is optional by contract", function()
			local parsed = ParkourValidation.Parse({ Kind = "Roll", Phase = "End", Speed = 10, Position = ORIGIN })
			expect(parsed).to.be.ok()
		end)

		it("rejects a non-table payload", function()
			local parsed, reason = ParkourValidation.Parse("not a table")
			expect(parsed).to.equal(nil)
			expect(reason).to.equal("MalformedPayload")
		end)

		it("rejects nil", function()
			expect(ParkourValidation.Parse(nil)).to.equal(nil)
		end)

		it("rejects an unrecognized action kind", function()
			local parsed = ParkourValidation.Parse({ Kind = "Teleport", Phase = "Start", Speed = 1, Position = ORIGIN })
			expect(parsed).to.equal(nil)
		end)

		it("rejects a non-string action kind", function()
			expect(ParkourValidation.Parse({ Kind = 7, Phase = "Start", Speed = 1, Position = ORIGIN })).to.equal(nil)
		end)

		it("rejects an unrecognized phase", function()
			expect(ParkourValidation.Parse({ Kind = "Slide", Phase = "Middle", Speed = 1, Position = ORIGIN })).to.equal(
				nil
			)
		end)

		it("rejects a non-numeric speed", function()
			expect(ParkourValidation.Parse({ Kind = "Slide", Phase = "Start", Speed = "fast", Position = ORIGIN })).to.equal(
				nil
			)
		end)

		it("rejects a NaN speed -- which would otherwise slip past every range check", function()
			expect(ParkourValidation.Parse({ Kind = "Slide", Phase = "Start", Speed = 0 / 0, Position = ORIGIN })).to.equal(
				nil
			)
		end)

		it("rejects an infinite speed", function()
			expect(ParkourValidation.Parse({ Kind = "Slide", Phase = "Start", Speed = math.huge, Position = ORIGIN })).to.equal(
				nil
			)
		end)

		it("rejects a non-Vector3 position", function()
			expect(ParkourValidation.Parse({ Kind = "Slide", Phase = "Start", Speed = 1, Position = { 0, 0, 0 } })).to.equal(
				nil
			)
		end)

		it("rejects a position containing NaN", function()
			local poisoned = Vector3.new(0 / 0, 0, 0)
			expect(ParkourValidation.Parse({ Kind = "Slide", Phase = "Start", Speed = 1, Position = poisoned })).to.equal(
				nil
			)
		end)

		it("rejects a non-numeric duration when one is present", function()
			expect(ParkourValidation.Parse({
				Kind = "Slide",
				Phase = "Start",
				Speed = 1,
				Position = ORIGIN,
				DurationSeconds = "long",
			})).to.equal(nil)
		end)
	end)

	describe("ParkourValidation.Validate -- speed and position", function()
		it("accepts an ordinary start report", function()
			local accepted, reason = ParkourValidation.Validate(report(), observed(), CONFIG)
			expect(accepted).to.equal(true)
			expect(reason).to.equal(nil)
		end)

		it("rejects a speed above the cap", function()
			local accepted, reason = ParkourValidation.Validate(report({ Speed = 500 }), observed(), CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ImplausibleSpeed")
		end)

		it("rejects a negative speed", function()
			local accepted, reason = ParkourValidation.Validate(report({ Speed = -1 }), observed(), CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ImplausibleSpeed")
		end)

		it("accepts a speed exactly at the cap", function()
			expect(ParkourValidation.Validate(report({ Speed = 70 }), observed(), CONFIG)).to.equal(true)
		end)

		it("rejects a claimed position nowhere near the character the server can see", function()
			local accepted, reason =
				ParkourValidation.Validate(report({ Position = Vector3.new(5000, 10, 0) }), observed(), CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ImplausibleTravel")
		end)

		it("tolerates a small position disagreement -- ordinary latency, not a lie", function()
			expect(ParkourValidation.Validate(report({ Position = Vector3.new(3, 10, 0) }), observed(), CONFIG)).to.equal(
				true
			)
		end)
	end)

	describe("ParkourValidation.Validate -- Start phase", function()
		it("rejects a duration longer than any action may claim", function()
			local accepted, reason = ParkourValidation.Validate(report({ DurationSeconds = 999 }), observed(), CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ActionTooLong")
		end)

		it("rejects a zero or negative duration", function()
			expect(ParkourValidation.Validate(report({ DurationSeconds = 0 }), observed(), CONFIG)).to.equal(false)
			expect(ParkourValidation.Validate(report({ DurationSeconds = -1 }), observed(), CONFIG)).to.equal(false)
		end)

		it("rejects a second Start for an action already open", function()
			local accepted, reason =
				ParkourValidation.Validate(report(), observed({ OpenKind = "Slide", OpenStartedAt = 99 }), CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("DuplicateAction")
		end)

		it("allows a Start for a DIFFERENT kind while one is open", function()
			-- Two velocity-owning actions can legitimately overlap at a hand-off boundary (a slide's End
			-- and a vault's Start can arrive in either order); refusing here would drop the second.
			expect(
				ParkourValidation.Validate(
					report({ Kind = "Vault" }),
					observed({ OpenKind = "Slide", OpenStartedAt = 99 }),
					CONFIG
				)
			).to.equal(true)
		end)

		it("rejects a report arriving faster than the per-kind minimum interval", function()
			local accepted, reason = ParkourValidation.Validate(report(), observed({ LastSameKindAt = 99.99 }), CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("DuplicateAction")
		end)

		it("accepts a report once the per-kind interval has elapsed", function()
			expect(ParkourValidation.Validate(report(), observed({ LastSameKindAt = 99.5 }), CONFIG)).to.equal(true)
		end)
	end)

	describe("ParkourValidation.Validate -- End phase", function()
		local function endReport(overrides: { [string]: any }?): ActionReport
			local merged: { [string]: any } = { Phase = "End", DurationSeconds = nil }
			if overrides then
				for key, value in overrides do
					merged[key] = value
				end
			end
			return report(merged)
		end

		it("accepts an End with no matching open window -- the benign late/expired case", function()
			expect(ParkourValidation.Validate(endReport(), observed(), CONFIG)).to.equal(true)
		end)

		it("accepts an ordinary End for an open window", function()
			local state = observed({
				OpenKind = "Slide",
				OpenStartedAt = 99,
				OpenStartPosition = Vector3.new(0, 10, 0),
			})
			expect(ParkourValidation.Validate(endReport({ Position = Vector3.new(20, 10, 0) }), state, CONFIG)).to.equal(
				true
			)
		end)

		it("rejects an End implying impossible travel", function()
			local state = observed({
				OpenKind = "Slide",
				OpenStartedAt = 99.9,
				OpenStartPosition = Vector3.new(0, 10, 0),
			})
			-- The claimed position also has to stay near the server's own view, so the server is moved
			-- with it -- this test is specifically about the START-to-END travel rate, not the anchor.
			state.Position = Vector3.new(80, 10, 0)
			local accepted, reason =
				ParkourValidation.Validate(endReport({ Position = Vector3.new(80, 10, 0) }), state, CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ImplausibleTravel")
		end)

		it("rejects an End implying impossible vertical gain", function()
			local state = observed({
				OpenKind = "WallRun",
				OpenStartedAt = 96,
				OpenStartPosition = Vector3.new(0, 10, 0),
			})
			state.Position = Vector3.new(0, 200, 0)
			local accepted, reason = ParkourValidation.Validate(
				endReport({ Kind = "WallRun", Position = Vector3.new(0, 200, 0) }),
				state,
				CONFIG
			)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ImplausibleVerticalGain")
		end)

		it("allows ordinary vertical gain within the cap", function()
			local state = observed({
				OpenKind = "WallRun",
				OpenStartedAt = 98,
				OpenStartPosition = Vector3.new(0, 10, 0),
			})
			state.Position = Vector3.new(0, 25, 0)
			expect(
				ParkourValidation.Validate(
					endReport({ Kind = "WallRun", Position = Vector3.new(0, 25, 0) }),
					state,
					CONFIG
				)
			).to.equal(true)
		end)

		it("rejects an End for a window open longer than any action may last", function()
			local state = observed({
				OpenKind = "Slide",
				OpenStartedAt = 50,
				OpenStartPosition = ORIGIN,
			})
			local accepted, reason = ParkourValidation.Validate(endReport(), state, CONFIG)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ActionTooLong")
		end)

		it("does not divide by zero for a near-instant action", function()
			-- A hop or a wall-jump legitimately starts and ends within a frame; without the elapsed-time
			-- floor this would compute an infinite travel speed for a two-stud move.
			local state = observed({
				OpenKind = "WallJump",
				OpenStartedAt = 99.999,
				OpenStartPosition = Vector3.new(0, 10, 0),
			})
			expect(
				ParkourValidation.Validate(
					endReport({ Kind = "WallJump", Position = Vector3.new(1, 10, 0) }),
					state,
					CONFIG
				)
			).to.equal(true)
		end)
	end)

	describe("ParkourValidation.PruneRejections", function()
		it("keeps timestamps inside the window", function()
			local timestamps = { 95, 98, 99 }
			expect(ParkourValidation.PruneRejections(timestamps, 100, 10)).to.equal(3)
		end)

		it("drops timestamps outside the window", function()
			local timestamps = { 10, 20, 98, 99 }
			expect(ParkourValidation.PruneRejections(timestamps, 100, 10)).to.equal(2)
			expect(timestamps[1]).to.equal(98)
			expect(timestamps[2]).to.equal(99)
			expect(timestamps[3]).to.equal(nil)
		end)

		it("empties the list when everything has aged out", function()
			local timestamps = { 1, 2, 3 }
			expect(ParkourValidation.PruneRejections(timestamps, 100, 10)).to.equal(0)
			expect(#timestamps).to.equal(0)
		end)

		it("handles an already-empty list", function()
			local timestamps: { number } = {}
			expect(ParkourValidation.PruneRejections(timestamps, 100, 10)).to.equal(0)
		end)

		it("mutates in place rather than returning a new table", function()
			local timestamps = { 1, 99 }
			ParkourValidation.PruneRejections(timestamps, 100, 10)
			expect(#timestamps).to.equal(1)
		end)
	end)

	describe("ParkourValidation.ShouldFlag", function()
		it("flags at the threshold", function()
			expect(ParkourValidation.ShouldFlag(25, 25)).to.equal(true)
		end)

		it("does not flag one below the threshold", function()
			expect(ParkourValidation.ShouldFlag(24, 25)).to.equal(false)
		end)

		it("flags above the threshold", function()
			expect(ParkourValidation.ShouldFlag(100, 25)).to.equal(true)
		end)
	end)

	describe("ParkourTypes -- reportable kinds", function()
		it("only exposes velocity-owning actions as reportable", function()
			-- Ordinary locomotion generates no network traffic at all; if a future change adds Walking or
			-- Falling to the reportable set, that is a per-frame remote and this test should be the thing
			-- that objects.
			local parsed = ParkourValidation.Parse({ Kind = "Walking", Phase = "Start", Speed = 1, Position = ORIGIN })
			expect(parsed).to.equal(nil)
		end)
	end)
end
