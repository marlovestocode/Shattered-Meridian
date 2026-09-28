--!strict
-- Covers Server/Boat/BoatHullMode.lua -- who is sailing the hull, and what each mode actually commands.
--
-- The safety property this file exists to pin is the last describe block: a latched sail setting must
-- never outlive the crew. Everything else here is precedence, and precedence is exactly what a pile of
-- booleans would have got wrong silently.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatHullMode = require(ServerScriptService.Server.Boat.BoatHullMode)

local function context(overrides: { [string]: any }?): BoatHullMode.Context
	local result: BoatHullMode.Context = {
		HasPilot = false,
		OccupantCount = 0,
		AdriftArmed = false,
		WaterSupported = true,
	}
	for key, value in overrides or {} do
		(result :: any)[key] = value
	end
	return result
end

local HELM = { Steer = 0.7 }

return function()
	describe("Step", function()
		it("starts Moored", function()
			expect(BoatHullMode.NewState().Mode).to.equal("Moored")
		end)

		it("is Piloted while somebody holds the helm", function()
			local state =
				BoatHullMode.Step(BoatHullMode.NewState(), context({ HasPilot = true, OccupantCount = 1 }), 0.1)
			expect(state.Mode).to.equal("Piloted")
		end)

		it("is Moored with crew aboard and nobody steering", function()
			local state = BoatHullMode.Step(BoatHullMode.NewState(), context({ OccupantCount = 2 }), 0.1)
			expect(state.Mode).to.equal("Moored")
		end)

		it("is Adrift with crew aboard, nobody steering, and the latch armed", function()
			local state =
				BoatHullMode.Step(BoatHullMode.NewState(), context({ OccupantCount = 2, AdriftArmed = true }), 0.1)
			expect(state.Mode).to.equal("Adrift")
		end)

		it("stays Moored for the whole grace after the last person leaves", function()
			local state = BoatHullMode.NewState()
			local empty = context()
			for _ = 1, 10 do
				state = BoatHullMode.Step(state, empty, BoatConstants.Adrift.AbandonGraceSeconds / 20)
				expect(state.Mode).to.equal("Moored")
			end
		end)

		it("reaches Anchored once the grace has run out", function()
			-- Advanced in real-sized ticks rather than one big one, because a single step long enough to
			-- cross the grace is clamped to MAX_STEP_SECONDS -- see the hitch case below, which is the
			-- same behaviour asserted from the other side.
			local state = BoatHullMode.NewState()
			local empty = context()
			for _ = 1, math.ceil(BoatConstants.Adrift.AbandonGraceSeconds / 0.2) + 1 do
				state = BoatHullMode.Step(state, empty, 0.2)
			end
			expect(state.Mode).to.equal("Anchored")
		end)

		it("RESETS the abandon clock when somebody boards, rather than pausing it", function()
			-- A boat two seconds from giving up that then has a passenger climb aboard gets the full grace
			-- again the next time she empties -- not the two seconds she had left.
			local state = BoatHullMode.NewState()
			state = BoatHullMode.Step(state, context(), BoatConstants.Adrift.AbandonGraceSeconds - 1)
			state = BoatHullMode.Step(state, context({ OccupantCount = 1 }), 0.1)
			expect(state.UnoccupiedSeconds).to.equal(0)

			state = BoatHullMode.Step(state, context(), BoatConstants.Adrift.AbandonGraceSeconds - 1)
			expect(state.Mode).to.equal("Moored")
		end)

		it("clamps a hitch rather than banking it through the whole grace in one frame", function()
			local state = BoatHullMode.Step(BoatHullMode.NewState(), context(), 999)
			expect(state.UnoccupiedSeconds <= 0.25).to.equal(true)
			expect(state.Mode).to.equal("Moored")
		end)
	end)

	describe("Beached outranks everything", function()
		it("beats a pilot at the wheel", function()
			local state = BoatHullMode.Step(
				BoatHullMode.NewState(),
				context({ HasPilot = true, OccupantCount = 1, WaterSupported = false }),
				0.1
			)
			expect(state.Mode).to.equal("Beached")
		end)

		it("beats an armed Adrift latch", function()
			local state = BoatHullMode.Step(
				BoatHullMode.NewState(),
				context({ OccupantCount = 1, AdriftArmed = true, WaterSupported = false }),
				0.1
			)
			expect(state.Mode).to.equal("Beached")
		end)

		it("never becomes Anchored, however long she is left there", function()
			-- "Anchored" claims she is lying safely. A boat on a shoal is not, and saying so would be the
			-- panel lying to the next player who walks past.
			local state = BoatHullMode.NewState()
			for _ = 1, 200 do
				state = BoatHullMode.Step(state, context({ WaterSupported = false }), 0.2)
			end
			expect(state.Mode).to.equal("Beached")
		end)

		it("goes straight to Anchored once she floats off, with no second grace period", function()
			local state = BoatHullMode.NewState()
			for _ = 1, 200 do
				state = BoatHullMode.Step(state, context({ WaterSupported = false }), 0.2)
			end
			-- The clock kept running underneath the whole time.
			state = BoatHullMode.Step(state, context(), 0.1)
			expect(state.Mode).to.equal("Anchored")
		end)
	end)

	describe("ResolveIntent", function()
		it("gives a helmsman their rung and their rudder", function()
			local intent = BoatHullMode.ResolveIntent("Piloted", context({ HasPilot = true }), 0.75, HELM)
			expect(intent.Sail).to.equal(0.75)
			expect(intent.Steer).to.equal(0.7)
		end)

		it("holds the rung but not the rudder while Adrift", function()
			-- She keeps her course because the yaw rate decays to zero on a neutral helm all by itself,
			-- not because anything is steering.
			local intent = BoatHullMode.ResolveIntent("Adrift", context(), 0.75, HELM)
			expect(intent.Sail).to.equal(0.75)
			expect(intent.Steer).to.equal(0)
		end)

		it("furls her Moored and Anchored alike", function()
			for _, mode in { "Moored", "Anchored" } do
				local intent = BoatHullMode.ResolveIntent(mode :: any, context(), 1, HELM)
				expect(intent.Sail).to.equal(0)
				expect(intent.Steer).to.equal(0)
			end
		end)

		it("leaves a beached hull's skipper everything -- backing off needs both", function()
			local intent = BoatHullMode.ResolveIntent("Beached", context({ HasPilot = true }), -1, HELM)
			expect(intent.Sail).to.equal(-1)
			expect(intent.Steer).to.equal(0.7)
		end)

		it("furls a beached hull nobody is aboard", function()
			local intent = BoatHullMode.ResolveIntent("Beached", context(), 1, HELM)
			expect(intent.Sail).to.equal(0)
			expect(intent.Steer).to.equal(0)
		end)
	end)

	describe("the safety property -- an empty hull is never under sail", function()
		it("commands no canvas in any mode an empty hull can be in", function()
			local empty = context()
			for _, mode in { "Moored", "Anchored", "Beached" } do
				expect(BoatHullMode.ResolveIntent(mode :: any, empty, 1, { Steer = 1 }).Sail).to.equal(0)
			end
		end)

		it("cannot reach Adrift or Piloted with nobody aboard", function()
			local state = BoatHullMode.NewState()
			-- AdriftArmed left true, which is the dangerous case: a latch that outlived its crew.
			for _ = 1, 100 do
				state = BoatHullMode.Step(state, context({ AdriftArmed = true }), 0.2)
				expect(state.Mode ~= "Adrift").to.equal(true)
				expect(state.Mode ~= "Piloted").to.equal(true)
			end
		end)
	end)

	describe("DecelerationMultiple", function()
		it("is 1 everywhere she is afloat", function()
			for _, mode in { "Moored", "Piloted", "Adrift", "Anchored" } do
				expect(BoatHullMode.DecelerationMultiple(mode :: any)).to.equal(1)
			end
		end)

		it("bites while aground", function()
			expect(BoatHullMode.DecelerationMultiple("Beached")).to.equal(BoatConstants.Beaching.DecelerationMultiple)
			expect(BoatConstants.Beaching.DecelerationMultiple > 1).to.equal(true)
		end)
	end)
end
