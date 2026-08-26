--!strict
-- Covers Server/Blimp/BlimpFlightMode.lua -- who is flying a hull, and what the integrator is handed
-- as a result.
--
-- No Instances, no Workspace, no waiting: that module deliberately touches nothing but numbers and a
-- string (see its own header), which is what makes "does an abandoned ship actually give up its
-- autopilot", "does a passenger boarding a descending hull stop the descent" and "does a hull that
-- clips a treetop on the way down latch Grounded a hundred studs up" answerable here rather than only
-- by leaving a blimp alone in Studio for eight seconds and watching.
--
-- The height above ground arrives as a plain number, exactly as it does in production -- the raycast
-- that produces it lives in Server/Systems/BlimpSystem.lua and is the part this cannot cover.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpFlightMode = require(ServerScriptService.Server.Blimp.BlimpFlightMode)

local FRAME = 1 / 60

local function context(overrides: { [string]: any }?): BlimpFlightMode.Context
	local base: BlimpFlightMode.Context = {
		HasPilot = false,
		OccupantCount = 0,
		AutopilotArmed = false,
		Depleted = false,
		HeightAboveGround = nil,
	}
	if overrides then
		for key, value in overrides do
			(base :: any)[key] = value
		end
	end
	return base
end

-- Advances the machine for `seconds` against one unchanging context, the way the real tick does.
local function run(state: BlimpFlightMode.State, ctx: BlimpFlightMode.Context, seconds: number): BlimpFlightMode.State
	local current = state
	for _ = 1, math.floor(seconds / FRAME) do
		current = BlimpFlightMode.Step(current, ctx, FRAME)
	end
	return current
end

-- Comfortably inside the touchdown band, so "resting" is unambiguous.
local RESTING_HEIGHT = BlimpConstants.Landing.TouchdownClearanceStuds
local GRACE = BlimpConstants.Autopilot.AbandonGraceSeconds

return function()
	describe("occupied hulls", function()
		it("is Piloted whenever somebody holds the helm", function()
			local state = run(BlimpFlightMode.NewState(), context({ HasPilot = true, OccupantCount = 1 }), 1)
			expect(state.Mode).to.equal("Piloted")
		end)

		it("stays Piloted even while fuel-gated", function()
			-- Depletion is not a demotion: the pilot is still standing there, and telling them they
			-- have been demoted to Moored explains nothing about why the ship stopped. The gate lands
			-- on the INTENT instead -- see ApplyFuelGate below.
			local state =
				run(BlimpFlightMode.NewState(), context({ HasPilot = true, OccupantCount = 1, Depleted = true }), 1)
			expect(state.Mode).to.equal("Piloted")
		end)

		-- Autopilot only ever means something while somebody is STILL ABOARD -- it is a thing a pilot
		-- leaves running for the passengers, not a thing that outlives them. The abandonment block below
		-- covers the other side of that.
		it("is Autopilot when the helm is empty but somebody is still aboard and it is armed", function()
			local state = run(BlimpFlightMode.NewState(), context({ OccupantCount = 2, AutopilotArmed = true }), 1)
			expect(state.Mode).to.equal("Autopilot")
		end)

		it("is Moored when the helm is empty and nothing is armed", function()
			local state = run(BlimpFlightMode.NewState(), context({ OccupantCount = 2 }), 1)
			expect(state.Mode).to.equal("Moored")
		end)

		it("never begins the abandon clock while anybody is aboard", function()
			local state = run(BlimpFlightMode.NewState(), context({ OccupantCount = 1 }), GRACE * 3)
			expect(state.Mode).to.equal("Moored")
			expect(state.UnoccupiedSeconds).to.equal(0)
		end)
	end)

	describe("abandonment", function()
		it("stops making way the instant the ship is empty, even on an armed autopilot", function()
			-- The load-bearing half of "stop first, land later". An empty ship is Moored -- coasting down
			-- its own deceleration ramp and holding altitude -- REGARDLESS of the latch, so a pilot who
			-- steps onto a dock does not watch their ship sail away from them under power.
			local state = BlimpFlightMode.Step(BlimpFlightMode.NewState(), context({ AutopilotArmed = true }), FRAME)
			expect(state.Mode).to.equal("Moored")
		end)

		it("holds that stop for the whole window rather than descending immediately", function()
			-- The other half: stopping and landing are two beats. Through the entire window the ship is
			-- stationary and still at altitude, so a pilot who died at the wheel and is sprinting back
			-- finds it where they left it rather than on the ground.
			local state = run(BlimpFlightMode.NewState(), context({ AutopilotArmed = true }), GRACE * 0.9)
			expect(state.Mode).to.equal("Moored")
		end)

		it("gives up and starts landing once the window passes", function()
			local state = run(BlimpFlightMode.NewState(), context({ AutopilotArmed = true }), GRACE + 1)
			expect(state.Mode).to.equal("Landing")
		end)

		it("lands an unarmed hull too", function()
			local state = run(BlimpFlightMode.NewState(), context(), GRACE + 1)
			expect(state.Mode).to.equal("Landing")
		end)

		it("resets the whole clock when somebody boards, not just pausing it", function()
			-- A ship one second from giving up that has a passenger climb aboard must get the FULL
			-- grace the next time it empties, rather than the one second it had left.
			local nearlyGone = run(BlimpFlightMode.NewState(), context(), GRACE - 1)
			expect(nearlyGone.Mode).to.never.equal("Landing")

			local boarded = BlimpFlightMode.Step(nearlyGone, context({ OccupantCount = 1 }), FRAME)
			expect(boarded.UnoccupiedSeconds).to.equal(0)

			local emptyAgain = run(boarded, context(), GRACE - 1)
			expect(emptyAgain.Mode).to.never.equal("Landing")
		end)
	end)

	describe("landing and settling", function()
		local function landing(): BlimpFlightMode.State
			local state = run(BlimpFlightMode.NewState(), context(), GRACE + 1)
			expect(state.Mode).to.equal("Landing")
			return state
		end

		it("keeps descending while no probe has answered", function()
			-- nil height is honestly different from "very high up": a landing hull with no reading must
			-- keep going rather than latch Grounded on a number nobody measured.
			local state = run(landing(), context(), BlimpConstants.Landing.SettleSeconds * 3)
			expect(state.Mode).to.equal("Landing")
		end)

		it("keeps descending while still well above the ground", function()
			local high = context({ HeightAboveGround = RESTING_HEIGHT + 200 })
			local state = run(landing(), high, BlimpConstants.Landing.SettleSeconds * 3)
			expect(state.Mode).to.equal("Landing")
		end)

		it("reaches Grounded after settling at touchdown height", function()
			local resting = context({ HeightAboveGround = RESTING_HEIGHT })
			local state = run(landing(), resting, BlimpConstants.Landing.SettleSeconds + 1)
			expect(state.Mode).to.equal("Grounded")
		end)

		it("does not latch Grounded from a momentary brush with a treetop", function()
			-- The settle timer resets the instant the hull rises back out of tolerance, which is the
			-- whole reason SettleSeconds exists rather than a single-frame height check.
			local resting = context({ HeightAboveGround = RESTING_HEIGHT })
			local high = context({ HeightAboveGround = RESTING_HEIGHT + 200 })

			local state = landing()
			for _ = 1, 40 do
				state = run(state, resting, BlimpConstants.Landing.SettleSeconds * 0.4)
				state = BlimpFlightMode.Step(state, high, FRAME)
			end
			expect(state.Mode).to.equal("Landing")
		end)

		it("holds Grounded through a probe that momentarily misses", function()
			-- A vehicle driving underneath a moored blimp, or a part streaming out, must not bounce it
			-- back into a landing it has already finished.
			local grounded = run(
				landing(),
				context({ HeightAboveGround = RESTING_HEIGHT }),
				BlimpConstants.Landing.SettleSeconds + 1
			)
			expect(grounded.Mode).to.equal("Grounded")
			local afterMiss = run(grounded, context(), 5)
			expect(afterMiss.Mode).to.equal("Grounded")
		end)

		it("hands a grounded hull straight back the moment anybody boards", function()
			local grounded = run(
				landing(),
				context({ HeightAboveGround = RESTING_HEIGHT }),
				BlimpConstants.Landing.SettleSeconds + 1
			)
			local boarded = BlimpFlightMode.Step(grounded, context({ HasPilot = true, OccupantCount = 1 }), FRAME)
			expect(boarded.Mode).to.equal("Piloted")
		end)
	end)

	describe("WantsGroundProbe", function()
		it("is false for any occupied hull -- the common case", function()
			expect(BlimpFlightMode.WantsGroundProbe(context({ OccupantCount = 1 }))).to.equal(false)
		end)

		it("is true through the whole grace window, not just once landing starts", function()
			expect(BlimpFlightMode.WantsGroundProbe(context())).to.equal(true)
		end)
	end)

	describe("ResolveFloor", function()
		it("leaves the authored floor alone for every flying mode", function()
			expect(BlimpFlightMode.ResolveFloor("Piloted", 40)).to.never.be.ok()
			expect(BlimpFlightMode.ResolveFloor("Autopilot", 40)).to.never.be.ok()
			expect(BlimpFlightMode.ResolveFloor("Moored", 40)).to.never.be.ok()
		end)

		it("moves the floor to the ground plus clearance while landing", function()
			expect(BlimpFlightMode.ResolveFloor("Landing", 40)).to.equal(
				40 + BlimpConstants.Landing.TouchdownClearanceStuds
			)
		end)

		it("declines to invent a floor with no probe reading", function()
			expect(BlimpFlightMode.ResolveFloor("Landing", nil)).to.never.be.ok()
		end)
	end)

	describe("ResolveIntent", function()
		it("gives a pilot their own axes and their own rung", function()
			local intent = BlimpFlightMode.ResolveIntent("Piloted", 0.7, { Steer = -1, Lift = 1 })
			expect(intent.Throttle).to.equal(0.7)
			expect(intent.Steer).to.equal(-1)
			expect(intent.Lift).to.equal(1)
		end)

		it("holds the rung but refuses stale axes on autopilot", function()
			-- Honouring a steer axis from a pilot who has walked away is how a ship ends up circling.
			local intent = BlimpFlightMode.ResolveIntent("Autopilot", 0.7, { Steer = 1, Lift = 1 })
			expect(intent.Throttle).to.equal(0.7)
			expect(intent.Steer).to.equal(0)
			expect(intent.Lift).to.equal(0)
		end)

		it("coasts a moored hull rather than driving it", function()
			local intent = BlimpFlightMode.ResolveIntent("Moored", 1, nil)
			expect(intent.Throttle).to.equal(0)
			expect(intent.Lift).to.equal(0)
		end)

		it("descends under no power while landing, whatever the rung says", function()
			local intent = BlimpFlightMode.ResolveIntent("Landing", 1, nil)
			expect(intent.Throttle).to.equal(0)
			expect(intent.Lift).to.equal(BlimpConstants.Landing.DescentLiftAxis)
			expect(intent.Lift < 0).to.equal(true)
		end)

		it("holds station once grounded", function()
			local intent = BlimpFlightMode.ResolveIntent("Grounded", 1, nil)
			expect(intent.Throttle).to.equal(0)
			expect(intent.Lift).to.equal(0)
		end)
	end)

	describe("ApplyFuelGate", function()
		it("passes a fuelled hull through untouched", function()
			local intent = { Throttle = 1, Steer = 1, Lift = 1 }
			expect(BlimpFlightMode.ApplyFuelGate(intent, false)).to.equal(intent)
		end)

		it("cuts thrust, steering and climb when dry", function()
			local gated = BlimpFlightMode.ApplyFuelGate({ Throttle = 1, Steer = 1, Lift = 1 }, true)
			expect(gated.Throttle).to.equal(0)
			expect(gated.Steer).to.equal(0)
			expect(gated.Lift).to.equal(0)
		end)

		it("still lets a dry hull come down", function()
			-- Without this an abandoned hull that ran dry mid-flight could never land: it would hang at
			-- altitude forever with its landing sequence commanding a descent the gate zeroed.
			local gated = BlimpFlightMode.ApplyFuelGate({ Throttle = 0, Steer = 0, Lift = -0.55 }, true)
			expect(gated.Lift).to.equal(-0.55)
		end)
	end)
end
