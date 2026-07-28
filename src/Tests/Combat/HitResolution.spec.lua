--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local HitResolution = require(ServerScriptService.Server.Combat.HitResolution)
local Fixtures = require(ServerScriptService.Tests.TestHelpers.Fixtures)

local function makeDefinition(overrides: { [string]: any }?): Types.HitboxAttackDefinition
	local definition = {
		DebugName = "TestAttack",
		WindupSeconds = 0.1,
		ActiveSeconds = 0.1,
		RecoverySeconds = 0.1,
		Size = Vector3.new(5, 5, 5),
		Offset = CFrame.new(0, 0, -3),
		Damage = 10,
		PostureDamage = 20,
		Cooldown = 0.5,
		ArcDegrees = 100,
		MaxTargets = 3,
	}
	return Fixtures.applyOverrides(definition, overrides) :: Types.HitboxAttackDefinition
end

return function()
	describe("HitResolution.ClassifyDefense", function()
		it("returns None with no active windows", function()
			expect(HitResolution.ClassifyDefense(100, 0, 0, false)).to.equal("None")
		end)

		it("prioritizes Parry over Block", function()
			expect(HitResolution.ClassifyDefense(100, 0, 200, true)).to.equal("Parry")
		end)

		it("falls through to Block when parry is absent/inactive", function()
			expect(HitResolution.ClassifyDefense(100, 0, nil, true)).to.equal("Block")
		end)

		it("treats an expired parry window as inactive", function()
			expect(HitResolution.ClassifyDefense(100, 0, 50, false)).to.equal("None")
		end)

		it("treats a zero (never-armed) window as inactive", function()
			expect(HitResolution.ClassifyDefense(100, 0, 0, false)).to.equal("None")
		end)

		it("suppresses every defense while posture-broken, even with active windows", function()
			expect(HitResolution.ClassifyDefense(100, 200, 200, true)).to.equal("None")
		end)

		it("dummy-shaped defender (no parry concept) always resolves None or Block", function()
			expect(HitResolution.ClassifyDefense(100, 0, nil, false)).to.equal("None")
		end)
	end)

	describe("HitResolution.ComputeOutcome", function()
		it("passes damage/posture through unmodified for None", function()
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })
			local outcome = HitResolution.ComputeOutcome(definition, "None")
			expect(outcome.Damage).to.equal(10)
			expect(outcome.Posture).to.equal(20)
		end)

		it("applies Block multipliers", function()
			local definition = makeDefinition({ Damage = 10, PostureDamage = 20 })
			local outcome = HitResolution.ComputeOutcome(definition, "Block")
			expect(outcome.Damage).to.equal(10 * Constants.Combat.BlockDamageMultiplier)
			expect(outcome.Posture).to.equal(20 * Constants.Combat.BlockPostureMultiplier)
		end)
	end)

	describe("HitResolution.SelectFinisherVariant", function()
		-- Only ever called for a grounded M1 finisher throw now -- an airborne Basic-attack press is
		-- intercepted into the standalone AirSlam attack before this function is reached (see this
		-- function's own header in HitResolution.lua), which is why it no longer takes an isAirborne
		-- parameter or has a Downslam case.
		it("resolves to Uppercut when holding jump", function()
			expect(HitResolution.SelectFinisherVariant(true)).to.equal("Uppercut")
		end)

		it("resolves to Normal when not holding jump", function()
			expect(HitResolution.SelectFinisherVariant(false)).to.equal("Normal")
		end)
	end)

	describe("HitResolution.ApplyPostureBreak", function()
		it("zeroes posture and opens the posture-broken window", function()
			local state = { posture = 50, postureBrokenExpiry = 0 }
			local applied = HitResolution.ApplyPostureBreak(state)
			expect(state.posture).to.equal(0)
			expect(state.postureBrokenExpiry > 0).to.equal(true)
			expect(applied).to.equal(true)
		end)

		it("applies unconditionally when no humanoid is given (dummy/bot-shaped callers)", function()
			local state = { posture = 50, postureBrokenExpiry = 0 }
			expect(HitResolution.ApplyPostureBreak(state, nil)).to.equal(true)
			expect(state.posture).to.equal(0)
		end)

		it("skips the break (and leaves posture untouched) when the target's humanoid is already dead", function()
			local humanoid = Instance.new("Humanoid")
			humanoid.MaxHealth = 100
			humanoid.Health = 0
			local state = { posture = 50, postureBrokenExpiry = 0 }

			local applied = HitResolution.ApplyPostureBreak(state, humanoid)

			expect(applied).to.equal(false)
			expect(state.posture).to.equal(50)
			expect(state.postureBrokenExpiry).to.equal(0)
		end)

		it("applies normally when the given humanoid is still alive", function()
			local humanoid = Instance.new("Humanoid")
			humanoid.MaxHealth = 100
			humanoid.Health = 100
			local state = { posture = 50, postureBrokenExpiry = 0 }

			expect(HitResolution.ApplyPostureBreak(state, humanoid)).to.equal(true)
			expect(state.posture).to.equal(0)
		end)
	end)

	describe("HitResolution.ShouldDisarm", function()
		-- Temporarily disabled unconditionally -- see ShouldDisarm's own header in HitResolution.lua:
		-- nothing in this codebase yet distinguishes an armed weapon-swing from a bare-fisted one, so
		-- Disarm has nothing meaningful to disarm from right now. These cases (including the
		-- previously-true "Parry against Heavy" case) all assert false until that distinction exists.
		it("is false for a Parry against a Heavy attack (disabled pending an armed/unarmed distinction)", function()
			expect(HitResolution.ShouldDisarm("Parry", true)).to.equal(false)
		end)

		it("is false for a Parry against a Basic (non-Heavy) attack", function()
			expect(HitResolution.ShouldDisarm("Parry", false)).to.equal(false)
		end)

		it("is false for a Block against a Heavy attack", function()
			expect(HitResolution.ShouldDisarm("Block", true)).to.equal(false)
		end)

		it("is false for None against a Heavy attack", function()
			expect(HitResolution.ShouldDisarm("None", true)).to.equal(false)
		end)
	end)

	describe("HitResolution.StampRecentOpponent", function()
		it("stamps a new opponent with the given timestamp", function()
			local opponent = {} :: any
			local state = { recentOpponents = {} }
			HitResolution.StampRecentOpponent(state, opponent, 100)
			expect(state.recentOpponents[opponent]).to.equal(100)
		end)

		it("refreshes an already-tracked opponent's timestamp in place", function()
			local opponent = {} :: any
			local state = { recentOpponents = { [opponent] = 50 } }
			HitResolution.StampRecentOpponent(state, opponent, 100)
			expect(state.recentOpponents[opponent]).to.equal(100)
		end)

		it("never evicts anything while refreshing an already-tracked opponent, even at the cap", function()
			local state = { recentOpponents = {} }
			local opponents = {}
			for i = 1, Constants.Combat.MaxTrackedOpponents do
				local opponent = {} :: any
				opponents[i] = opponent
				HitResolution.StampRecentOpponent(state, opponent, i)
			end

			HitResolution.StampRecentOpponent(state, opponents[1], 999)

			local trackedCount = 0
			for _ in pairs(state.recentOpponents) do
				trackedCount += 1
			end
			expect(trackedCount).to.equal(Constants.Combat.MaxTrackedOpponents)
			expect(state.recentOpponents[opponents[1]]).to.equal(999)
		end)

		it("evicts the single oldest entry once a genuinely new opponent would exceed the cap", function()
			local state = { recentOpponents = {} }
			local opponents = {}
			for i = 1, Constants.Combat.MaxTrackedOpponents do
				local opponent = {} :: any
				opponents[i] = opponent
				HitResolution.StampRecentOpponent(state, opponent, i)
			end

			local newOpponent = {} :: any
			HitResolution.StampRecentOpponent(state, newOpponent, 1000)

			local trackedCount = 0
			for _ in pairs(state.recentOpponents) do
				trackedCount += 1
			end
			expect(trackedCount).to.equal(Constants.Combat.MaxTrackedOpponents)
			-- opponents[1] was stamped with the smallest timestamp (1) -- the oldest -- so it's the
			-- one evicted; every other original opponent plus the new one survive.
			expect(state.recentOpponents[opponents[1]]).to.equal(nil)
			expect(state.recentOpponents[newOpponent]).to.equal(1000)
			for i = 2, Constants.Combat.MaxTrackedOpponents do
				expect(state.recentOpponents[opponents[i]]).to.equal(i)
			end
		end)
	end)

	describe("HitResolution.ApplyDisarm", function()
		it("sets disarmedUntil to now + Constants.Combat.Disarm.DurationSeconds", function()
			local state = { disarmedUntil = 0 }
			HitResolution.ApplyDisarm(state, 100)
			expect(state.disarmedUntil).to.equal(100 + Constants.Combat.Disarm.DurationSeconds)
		end)

		it("extends (never shortens) an existing later disarmedUntil", function()
			local state = { disarmedUntil = 500 }
			HitResolution.ApplyDisarm(state, 100)
			expect(state.disarmedUntil).to.equal(500)
		end)

		it("does extend when the new window would end later than the existing one", function()
			local state = { disarmedUntil = 100.5 }
			HitResolution.ApplyDisarm(state, 100)
			expect(state.disarmedUntil).to.equal(100 + Constants.Combat.Disarm.DurationSeconds)
		end)
	end)
end
