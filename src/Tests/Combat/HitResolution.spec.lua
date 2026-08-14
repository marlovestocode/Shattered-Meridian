--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local HitResolution = require(ServerScriptService.Server.Combat.HitResolution)
local CombatTypes = require(ServerScriptService.Server.Combat.CombatTypes)
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

	describe("HitResolution.ActionDropsParryWindow", function()
		it("does not drop the window for BlockStart, the action that arms it", function()
			expect(HitResolution.ActionDropsParryWindow("BlockStart")).to.equal(false)
		end)

		it("drops the window for every other committed action kind", function()
			local kinds: { CombatTypes.CombatActionKind } = {
				"Basic",
				"Heavy",
				"AirSlam",
				"Dash",
				"DashPunch",
				"DashHit",
				"Slide",
				"Feint",
				"CustomMove",
			}
			for _, kind in kinds do
				expect(HitResolution.ActionDropsParryWindow(kind)).to.equal(true)
			end
		end)

		it(
			"regression: a parry-armed defender who commits to a swing classifies the next incoming hit as None, not Parry -- holding Block then attacking must not grant a free, cost-free parry",
			function()
				local now = 100
				local parryWindowExpiry = now + Constants.Combat.ParryWindowSeconds
				local blocking = true

				-- The defender is still inside their own armed window right up until the moment they
				-- commit to a swing -- exactly what a "hold Block, then press M1 without releasing"
				-- press produces server-side.
				expect(HitResolution.ClassifyDefense(now, 0, parryWindowExpiry, blocking)).to.equal("Parry")

				-- Committing to Basic (or Heavy/AirSlam/Dash/.../CustomMove -- anything but BlockStart)
				-- must drop the window, mirroring what setActiveAction/RequestBotAttack now do.
				if HitResolution.ActionDropsParryWindow("Basic") then
					parryWindowExpiry = 0
				end
				blocking = false

				-- A hit landing mid-swing, moments later, must resolve as a genuine, undefended hit --
				-- not the free parry the unfixed code granted.
				expect(HitResolution.ClassifyDefense(now + 0.05, 0, parryWindowExpiry, blocking)).to.equal("None")
			end
		)
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

	-- HitResolution.ShouldDisarm is GONE, and there is deliberately no replacement describe block for
	-- it. The four specs that stood here asserted the `false` its shelved `return false and (...)`
	-- produced, which had the effect of pinning the disabled state in place as a tested contract --
	-- exactly the thing that made deleting it feel like a behavior change when it never was. Nothing
	-- produces a disarm today; see Constants.Combat.Disarm's own comment for what to add back, where,
	-- and what to spec at that point.

	describe("HitResolution.ApplyParryPunish", function()
		it("takes posture, extends the stun, and opens the guard", function()
			local now = 100
			local state = { posture = 80, stunExpiry = 0, guardOpenExpiry = 0 }

			HitResolution.ApplyParryPunish(state, now)

			expect(state.posture).to.equal(80 - Constants.Combat.ParryPunishPostureDamage)
			expect(state.stunExpiry).to.equal(now + Constants.Combat.StunDuration)
			expect(state.guardOpenExpiry).to.equal(now + Constants.Combat.GuardOpenSeconds)
		end)

		it("never shortens an already-longer guard-open window", function()
			local now = 100
			local farFuture = now + Constants.Combat.GuardOpenSeconds + 5
			local state = { posture = 80, stunExpiry = 0, guardOpenExpiry = farFuture }

			HitResolution.ApplyParryPunish(state, now)

			expect(state.guardOpenExpiry).to.equal(farFuture)
		end)

		it("floors posture at zero rather than going negative", function()
			local state = { posture = 5, stunExpiry = 0, guardOpenExpiry = 0 }
			HitResolution.ApplyParryPunish(state, 100)
			expect(state.posture).to.equal(0)
		end)
	end)

	describe("HitResolution.ClassifyDefense guard-open suppression", function()
		it("suppresses a held block while the guard is open", function()
			expect(HitResolution.ClassifyDefense(100, 0, 0, true, 200)).to.equal("None")
		end)

		it("suppresses even an armed parry window while the guard is open", function()
			-- The attacker who was parried mid-swing may still have had their own window armed. Being
			-- parried has to beat that, or a trade would hand the loser of the read a free parry back.
			expect(HitResolution.ClassifyDefense(100, 0, 200, true, 200)).to.equal("None")
		end)

		it("restores normal defense once the guard-open window has expired", function()
			expect(HitResolution.ClassifyDefense(100, 0, 0, true, 50)).to.equal("Block")
			expect(HitResolution.ClassifyDefense(100, 0, 200, false, 50)).to.equal("Parry")
		end)

		it("treats a zero (never-parried) guard-open as inactive", function()
			expect(HitResolution.ClassifyDefense(100, 0, 0, true, 0)).to.equal("Block")
		end)

		it("treats an omitted guard-open as inactive, so the 4-argument callers are unaffected", function()
			expect(HitResolution.ClassifyDefense(100, 0, 0, true)).to.equal("Block")
			expect(HitResolution.ClassifyDefense(100, 0, 200, true)).to.equal("Parry")
		end)

		it(
			"regression: the parry punish's own guard-open makes the follow-up land -- the whole reason the punish exists",
			function()
				-- The measured failure this replaces: ACTION_GATES exempts BlockStart from Stun, so a
				-- parried attacker's only real lockout was their own swing's recovery, and against every
				-- Basic stage that recovery (0.36-0.44s) expires before any human follow-up can land.
				local now = 100
				local attacker = { posture = 80, stunExpiry = 0, guardOpenExpiry = 0 }
				HitResolution.ApplyParryPunish(attacker, now)

				-- The parrier's fastest realistic follow-up: reaction + latency + Primary Basic1's own
				-- playtest-confirmed 0.31 windup. It must NOT be mitigated, however hard they guard.
				local followUpAt = now + 0.56
				expect(HitResolution.ClassifyDefense(followUpAt, 0, 0, true, attacker.guardOpenExpiry)).to.equal("None")

				-- And the window has to END -- one guaranteed hit, not a combo. A second swing, gated by
				-- the first one's own commitment, arrives well outside it and meets a real guard again.
				local secondSwingAt = now + Constants.Combat.GuardOpenSeconds + 0.1
				expect(HitResolution.ClassifyDefense(secondSwingAt, 0, 0, true, attacker.guardOpenExpiry)).to.equal(
					"Block"
				)
			end
		)
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
