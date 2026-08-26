--!strict
-- Covers Server/Blimp/BlimpFuel.lua -- the whole of a blimp's fuel behaviour.
--
-- No Instances, no Workspace, no waiting: that module deliberately touches nothing but numbers (see
-- its own header), the same split BlimpDrive.spec.lua already exercises for the flight side. Time is
-- passed in as deltaTime, so a case that needs minutes of burn runs that many steps and finishes
-- instantly.
--
-- What is NOT covered here, and cannot be: the prompts, the ProximityPrompt text rewrite, and the
-- interaction between depletion and BlimpDrive's own intent substitution all need real Instances and
-- a real character. Those are exercised by playing the game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BlimpFuel = require(ServerScriptService.Server.Blimp.BlimpFuel)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local FRAME = 1 / 60

-- A deliberately plain tuning rather than BlimpConstants.Fuel itself -- same reasoning as
-- BlimpDrive.spec.lua's own `tuning` helper: every expectation below is arithmetic on these numbers,
-- and reading them off the live constants would turn a retune into a test failure that says nothing.
local function tuning(overrides: { [string]: number }?): BlimpTypes.FuelTuning
	local base: BlimpTypes.FuelTuning = {
		CoalCapacity = 100,
		WaterCapacity = 100,
		CoalMinimum = 10,
		WaterMinimum = 20,
		CoalBurnPerSecond = 1,
		WaterBurnPerSecond = 5,
	}
	if overrides then
		for key, value in overrides do
			(base :: any)[key] = value
		end
	end
	return base
end

local function stateOf(coal: number, water: number): BlimpTypes.FuelState
	return { Coal = coal, Water = water }
end

local function run(
	state: BlimpTypes.FuelState,
	thrusting: boolean,
	config: BlimpTypes.FuelTuning,
	seconds: number
): BlimpTypes.FuelState
	local current = state
	local steps = math.floor(seconds / FRAME)
	for _ = 1, steps do
		current = BlimpFuel.Step(current, thrusting, config, FRAME)
	end
	return current
end

return function()
	describe("NewState", function()
		it("starts empty", function()
			local state = BlimpFuel.NewState()
			expect(state.Coal).to.equal(0)
			expect(state.Water).to.equal(0)
		end)
	end)

	describe("Step", function()
		it("drains nothing while not thrusting", function()
			local config = tuning()
			local state = stateOf(50, 50)
			local after = run(state, false, config, 5)
			expect(after).to.equal(state)
		end)

		it("drains each pool at its own rate while thrusting", function()
			local config = tuning()
			local state = stateOf(50, 50)
			local after = run(state, true, config, 2)
			expect(math.abs(after.Coal - 48) < 1e-2).to.equal(true)
			expect(math.abs(after.Water - 40) < 1e-2).to.equal(true)
		end)

		it("clamps at zero instead of going negative", function()
			local config = tuning()
			local state = stateOf(0.5, 0.5)
			local after = run(state, true, config, 5)
			expect(after.Coal).to.equal(0)
			expect(after.Water).to.equal(0)
		end)

		it("clamps a hitched frame instead of draining the whole stalled duration", function()
			local config = tuning()
			local state = stateOf(100, 100)
			-- A ten-second stall in one Step call. Integrated whole at WaterBurnPerSecond = 5 this would
			-- drain 50 water; clamped to MAX_STEP_SECONDS (0.25s) it should drain only 1.25.
			local after = BlimpFuel.Step(state, true, config, 10)
			expect(math.abs(after.Water - 98.75) < 1e-2).to.equal(true)
		end)

		it("is a no-op on a zero or negative delta", function()
			local config = tuning()
			local state = stateOf(50, 50)
			expect(BlimpFuel.Step(state, true, config, 0)).to.equal(state)
			expect(BlimpFuel.Step(state, true, config, -1)).to.equal(state)
		end)

		it("does not mutate the state it was given", function()
			local config = tuning()
			local state = stateOf(50, 50)
			BlimpFuel.Step(state, true, config, FRAME)
			expect(state.Coal).to.equal(50)
			expect(state.Water).to.equal(50)
		end)
	end)

	describe("Deposit", function()
		it("accepts the full amount when there is room", function()
			local config = tuning()
			local state = stateOf(10, 10)
			local after, accepted = BlimpFuel.Deposit(state, "Coal", 20, config)
			expect(accepted).to.equal(20)
			expect(after.Coal).to.equal(30)
			expect(after.Water).to.equal(10)
		end)

		it("caps a deposit at whatever room is left in the tank", function()
			local config = tuning()
			local state = stateOf(90, 0)
			local after, accepted = BlimpFuel.Deposit(state, "Coal", 50, config)
			expect(accepted).to.equal(10)
			expect(after.Coal).to.equal(config.CoalCapacity)
		end)

		it("accepts nothing into an already-full tank", function()
			local config = tuning()
			local state = stateOf(config.CoalCapacity, 0)
			local after, accepted = BlimpFuel.Deposit(state, "Coal", 10, config)
			expect(accepted).to.equal(0)
			expect(after).to.equal(state)
		end)

		it("accepts nothing for a non-positive amount", function()
			local config = tuning()
			local state = stateOf(10, 10)
			local afterZero, acceptedZero = BlimpFuel.Deposit(state, "Water", 0, config)
			expect(acceptedZero).to.equal(0)
			expect(afterZero).to.equal(state)
			local afterNegative, acceptedNegative = BlimpFuel.Deposit(state, "Water", -5, config)
			expect(acceptedNegative).to.equal(0)
			expect(afterNegative).to.equal(state)
		end)

		it("touches only the deposited resource's own pool", function()
			local config = tuning()
			local state = stateOf(10, 10)
			local after = BlimpFuel.Deposit(state, "Water", 20, config)
			expect(after.Coal).to.equal(10)
			expect(after.Water).to.equal(30)
		end)
	end)

	describe("Withdraw", function()
		it("hands back the full amount when the tank holds it", function()
			local state = stateOf(60, 40)
			local after, withdrawn = BlimpFuel.Withdraw(state, "Coal", 25)
			expect(withdrawn).to.equal(25)
			expect(after.Coal).to.equal(35)
			expect(after.Water).to.equal(40)
		end)

		it("caps a withdrawal at what the tank actually holds", function()
			local state = stateOf(15, 0)
			local after, withdrawn = BlimpFuel.Withdraw(state, "Coal", 500)
			expect(withdrawn).to.equal(15)
			expect(after.Coal).to.equal(0)
		end)

		it("hands back nothing from an empty pool", function()
			local state = stateOf(0, 40)
			local after, withdrawn = BlimpFuel.Withdraw(state, "Coal", 10)
			expect(withdrawn).to.equal(0)
			expect(after).to.equal(state)
		end)

		it("hands back nothing for a non-positive amount", function()
			local state = stateOf(10, 10)
			local afterZero, withdrawnZero = BlimpFuel.Withdraw(state, "Water", 0)
			expect(withdrawnZero).to.equal(0)
			expect(afterZero).to.equal(state)
			local afterNegative, withdrawnNegative = BlimpFuel.Withdraw(state, "Water", -5)
			expect(withdrawnNegative).to.equal(0)
			expect(afterNegative).to.equal(state)
		end)

		it("touches only the withdrawn resource's own pool", function()
			local state = stateOf(10, 30)
			local after = BlimpFuel.Withdraw(state, "Water", 20)
			expect(after.Coal).to.equal(10)
			expect(after.Water).to.equal(10)
		end)

		it("will drain a pool below its own operating minimum, which is deliberate", function()
			-- See Withdraw's own header: the Minimum stops an ENGINE running a tank dry in flight, it
			-- is not a claim on fuel a player is standing next to and wants back. A refusal here would
			-- be a rule with no fiction behind it.
			local config = tuning()
			local state = stateOf(config.CoalMinimum + 1, config.WaterMinimum + 1)
			local after, withdrawn = BlimpFuel.Withdraw(state, "Coal", 1000)
			expect(withdrawn).to.equal(config.CoalMinimum + 1)
			expect(after.Coal).to.equal(0)
			expect(BlimpFuel.IsDepleted(after, config)).to.equal(true)
		end)

		it("round-trips against Deposit: what a tank took is exactly what it gives back", function()
			-- The invariant the unload prompt lives or dies on. Loading 40 coal into a hull and then
			-- unloading it must leave both the tank and the player exactly where they started -- a
			-- withdrawal that returned a different number would quietly mint or destroy fuel.
			local config = tuning()
			local start = stateOf(10, 10)
			local loaded, accepted = BlimpFuel.Deposit(start, "Coal", 40, config)
			local recovered, withdrawn = BlimpFuel.Withdraw(loaded, "Coal", accepted)
			expect(withdrawn).to.equal(accepted)
			expect(recovered.Coal).to.equal(start.Coal)
			expect(recovered.Water).to.equal(start.Water)
		end)
	end)

	describe("IsDepleted", function()
		it("is not depleted with both pools above their own minimum", function()
			local config = tuning()
			expect(BlimpFuel.IsDepleted(stateOf(50, 50), config)).to.equal(false)
		end)

		it("is depleted when coal alone drops under its minimum, even with a full water tank", function()
			local config = tuning()
			expect(BlimpFuel.IsDepleted(stateOf(5, 100), config)).to.equal(true)
		end)

		it("is depleted when water alone drops under its minimum, even with a full coal bin", function()
			-- The case that matters most: a hull can be sitting on nearly-full coal and still be grounded
			-- because water crossed its own line -- see this module's own header.
			local config = tuning()
			expect(BlimpFuel.IsDepleted(stateOf(100, 5), config)).to.equal(true)
		end)

		it("is depleted exactly at the minimum, not only strictly below it", function()
			local config = tuning()
			expect(BlimpFuel.IsDepleted(stateOf(config.CoalMinimum, 100), config)).to.equal(false)
			expect(BlimpFuel.IsDepleted(stateOf(config.CoalMinimum - 0.01, 100), config)).to.equal(true)
		end)
	end)

	describe("SecondsUntilMinimum", function()
		it("reports no countdown at all while idle", function()
			local config = tuning()
			local coalSeconds, waterSeconds = BlimpFuel.SecondsUntilMinimum(stateOf(50, 50), config, false)
			expect(coalSeconds).to.equal(math.huge)
			expect(waterSeconds).to.equal(math.huge)
		end)

		it("computes each pool's own time to its own minimum while thrusting", function()
			local config = tuning()
			-- Coal: (50 - 10) / 1 = 40s. Water: (50 - 20) / 5 = 6s.
			local coalSeconds, waterSeconds = BlimpFuel.SecondsUntilMinimum(stateOf(50, 50), config, true)
			expect(math.abs(coalSeconds - 40) < 1e-6).to.equal(true)
			expect(math.abs(waterSeconds - 6) < 1e-6).to.equal(true)
		end)

		it("never reports negative time once already under the minimum", function()
			local config = tuning()
			local coalSeconds = BlimpFuel.SecondsUntilMinimum(stateOf(0, 50), config, true)
			expect(coalSeconds).to.equal(0)
		end)
	end)

	describe("the shipping tuning", function()
		it("is internally consistent", function()
			-- A guard on the constants themselves, same posture as BlimpDrive.spec.lua's own equivalent:
			-- every one of these being positive is assumed silently by Step/Deposit, and a Minimum at or
			-- above its own Capacity would ship a permanently grounded blimp with nothing in any log
			-- (BlimpTagging.ResolveFuelTuning guards the OVERRIDE path against this; this guards the
			-- shipped defaults themselves).
			local fuel = BlimpConstants.Fuel
			expect(fuel.CoalCapacity > 0).to.equal(true)
			expect(fuel.WaterCapacity > 0).to.equal(true)
			expect(fuel.CoalMinimum > 0).to.equal(true)
			expect(fuel.WaterMinimum > 0).to.equal(true)
			expect(fuel.CoalMinimum < fuel.CoalCapacity).to.equal(true)
			expect(fuel.WaterMinimum < fuel.WaterCapacity).to.equal(true)
			expect(fuel.CoalBurnPerSecond > 0).to.equal(true)
			expect(fuel.WaterBurnPerSecond > 0).to.equal(true)
			-- The whole point of the table: coal burns significantly slower than water.
			expect(fuel.CoalBurnPerSecond < fuel.WaterBurnPerSecond).to.equal(true)
		end)
	end)
end
