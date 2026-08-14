--!strict
--[[
	HealthRegen.spec.lua

	Covers Server/Combat/HealthRegen.lua -- the arithmetic behind passive health regen.

	The cases worth having here are not "does addition work." They are the ones where a wrong answer
	is either invisible or unrecoverable: a NaN that poisons Humanoid.Health past the point any clamp
	can rescue it, a return value lower than the input (which would become passive damage that no hit
	registered and no death attribution could explain), and a heal that resurrects a body sitting at 0
	between the killing blow and confirmDeath.

	CONFIG uses blunt round numbers rather than the shipped tuning, so every expectation below can be
	read as arithmetic instead of taken on faith -- and so a designer retuning Constants.Combat.
	HealthRegen never breaks a test that was never about their numbers.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local HealthRegen = require(ServerScriptService.Server.Combat.HealthRegen)

-- Ramp from 1 HP/s to 10 HP/s over 10 seconds against a 100 max, ceiling at full.
local CONFIG: HealthRegen.RegenConfig = {
	Enabled = true,
	StartFractionPerSecond = 0.01,
	FullFractionPerSecond = 0.1,
	RampSeconds = 10,
	MaxFractionOfMax = 1,
}

local MAX = 100

local function withConfig(overrides: { [string]: any }): HealthRegen.RegenConfig
	local built = {
		Enabled = CONFIG.Enabled,
		StartFractionPerSecond = CONFIG.StartFractionPerSecond,
		FullFractionPerSecond = CONFIG.FullFractionPerSecond,
		RampSeconds = CONFIG.RampSeconds,
		MaxFractionOfMax = CONFIG.MaxFractionOfMax,
	}
	for key, value in pairs(overrides) do
		built[key] = value
	end
	return built :: any
end

local function isNear(actual: number, expected: number, tolerance: number?): boolean
	return math.abs(actual - expected) <= (tolerance or 0.0001)
end

return function()
	describe("HealthRegen.ComputeRatePerSecond", function()
		it("is a hard zero while still in combat", function()
			-- Negative seconds-out-of-combat is how the caller expresses "the window has not lapsed":
			-- CombatSystem passes now - inCombatUntil directly. The rate is OFF here, not merely at
			-- the foot of the ramp.
			expect(HealthRegen.ComputeRatePerSecond(-3, MAX, CONFIG)).to.equal(0)
			expect(HealthRegen.ComputeRatePerSecond(0, MAX, CONFIG)).to.equal(0)
		end)

		it("starts at the foot of the ramp the instant combat lapses", function()
			-- Smoothstep(0) is 0, so an infinitesimal moment out of combat yields the start rate.
			expect(isNear(HealthRegen.ComputeRatePerSecond(0.0001, MAX, CONFIG), 1, 0.01)).to.equal(true)
		end)

		it("reaches the full rate at the top of the ramp and holds there", function()
			expect(isNear(HealthRegen.ComputeRatePerSecond(10, MAX, CONFIG), 10)).to.equal(true)
			expect(isNear(HealthRegen.ComputeRatePerSecond(600, MAX, CONFIG), 10)).to.equal(true)
		end)

		it("sits at the midpoint halfway through the ramp", function()
			-- Smoothstep(0.5) is exactly 0.5, so the curve is symmetric about its middle -- the one
			-- point where an eased ramp and a linear one agree, which makes it the honest place to
			-- assert the interpolation itself rather than the easing.
			expect(isNear(HealthRegen.ComputeRatePerSecond(5, MAX, CONFIG), 5.5)).to.equal(true)
		end)

		it("eases in rather than ramping linearly", function()
			-- The whole point of smoothstep over a lerp. At a quarter through, a linear ramp would
			-- already be at 3.25 HP/s; the eased curve is meaningfully below that, and is what stops
			-- the onset of regen from cornering visibly.
			local eased = HealthRegen.ComputeRatePerSecond(2.5, MAX, CONFIG)
			expect(eased < 3.25).to.equal(true)
			expect(eased > 1).to.equal(true)
		end)

		it("scales with max health, so a larger pool refills proportionally", function()
			-- Rates are fractions of max, not flat HP/s -- this is what makes the model survive
			-- Vitality eventually driving Max Health.
			expect(isNear(HealthRegen.ComputeRatePerSecond(10, 200, CONFIG), 20)).to.equal(true)
		end)

		it("returns zero when disabled", function()
			expect(HealthRegen.ComputeRatePerSecond(60, MAX, withConfig({ Enabled = false }))).to.equal(0)
		end)

		it("treats a zero ramp as full rate immediately rather than dividing by zero", function()
			local rate = HealthRegen.ComputeRatePerSecond(0.001, MAX, withConfig({ RampSeconds = 0 }))
			expect(isNear(rate, 10)).to.equal(true)
		end)

		it("refuses a NaN elapsed time instead of producing a NaN rate", function()
			local nan = 0 / 0
			expect(HealthRegen.ComputeRatePerSecond(nan, MAX, CONFIG)).to.equal(0)
		end)

		it("refuses a non-positive max health", function()
			expect(HealthRegen.ComputeRatePerSecond(60, 0, CONFIG)).to.equal(0)
			expect(HealthRegen.ComputeRatePerSecond(60, -100, CONFIG)).to.equal(0)
		end)
	end)

	describe("HealthRegen.ComputeHealedHealth", function()
		it("heals by rate times delta at the top of the ramp", function()
			-- 10 HP/s for a quarter second.
			expect(isNear(HealthRegen.ComputeHealedHealth(50, MAX, 10, 0.25, CONFIG), 52.5)).to.equal(true)
		end)

		it("does not heal while in combat", function()
			expect(HealthRegen.ComputeHealedHealth(50, MAX, -1, 0.25, CONFIG)).to.equal(50)
		end)

		it("never exceeds the ceiling even with an enormous delta", function()
			-- A resumed session or a hitched server can hand back a very large delta; it must not
			-- overshoot into more health than the player can have.
			expect(HealthRegen.ComputeHealedHealth(50, MAX, 60, 999, CONFIG)).to.equal(MAX)
		end)

		it("honors a ceiling below full", function()
			-- The documented first lever if regen removes too much tension: recover to 70%, then a
			-- deliberate heal is still required to top off.
			local capped = withConfig({ MaxFractionOfMax = 0.7 })
			expect(HealthRegen.ComputeHealedHealth(50, MAX, 60, 999, capped)).to.equal(70)
		end)

		it("leaves a player already above the ceiling exactly where they are", function()
			-- The guarantee that matters most: this function may never return a value lower than the
			-- one it was given. CombatSystem assigns the result straight onto Humanoid.Health, so
			-- dragging an over-ceiling player down would be passive damage with no hit behind it.
			local capped = withConfig({ MaxFractionOfMax = 0.7 })
			expect(HealthRegen.ComputeHealedHealth(95, MAX, 60, 0.25, capped)).to.equal(95)
		end)

		it("does not resurrect a body at zero health", function()
			-- A character sits at exactly 0 between the killing blow and confirmDeath. Healing out of
			-- that window would revive someone the death pipeline has already committed to.
			expect(HealthRegen.ComputeHealedHealth(0, MAX, 60, 0.25, CONFIG)).to.equal(0)
			expect(HealthRegen.ComputeHealedHealth(-5, MAX, 60, 0.25, CONFIG)).to.equal(-5)
		end)

		it("is a no-op at full health", function()
			expect(HealthRegen.ComputeHealedHealth(MAX, MAX, 60, 0.25, CONFIG)).to.equal(MAX)
		end)

		it("contributes nothing on a stalled or malformed frame", function()
			expect(HealthRegen.ComputeHealedHealth(50, MAX, 60, 0, CONFIG)).to.equal(50)
			expect(HealthRegen.ComputeHealedHealth(50, MAX, 60, -1, CONFIG)).to.equal(50)
			expect(HealthRegen.ComputeHealedHealth(50, MAX, 60, 0 / 0, CONFIG)).to.equal(50)
		end)

		it("never returns NaN from a NaN input, it returns the input unchanged", function()
			local nan = 0 / 0
			-- A NaN health is unrecoverable without a respawn -- every clamp that would normally
			-- rescue it also returns NaN -- so the only safe answer is to pass it through untouched
			-- and let it stay someone else's bug rather than becoming this module's.
			local fromNanHealth = HealthRegen.ComputeHealedHealth(nan, MAX, 60, 0.25, CONFIG)
			expect(fromNanHealth ~= fromNanHealth).to.equal(true)
			expect(HealthRegen.ComputeHealedHealth(50, nan, 60, 0.25, CONFIG)).to.equal(50)
			expect(HealthRegen.ComputeHealedHealth(50, MAX, nan, 0.25, CONFIG)).to.equal(50)
		end)

		it("never decreases health across a sweep of the whole input space", function()
			-- The one property worth asserting exhaustively rather than by example, because a
			-- violation is silent: passive damage looks like a balance problem, not a bug.
			for _, health in { 0.5, 1, 25, 50, 99.9, 100 } do
				for _, elapsed in { -5, 0, 0.001, 1, 5, 10, 60 } do
					for _, delta in { 0.016, 0.25, 5 } do
						local result = HealthRegen.ComputeHealedHealth(health, MAX, elapsed, delta, CONFIG)
						expect(result >= health).to.equal(true)
					end
				end
			end
		end)
	end)

	describe("the shipped tuning", function()
		local Constants = require(game:GetService("ReplicatedStorage").Shared.Constants)
		local SHIPPED = Constants.Combat.HealthRegen

		it("ramps upward, never downward", function()
			-- A start rate above the full rate would invert the curve into a decelerating heal, which
			-- is the opposite of the intended "recovery accelerates as safety persists" feel and would
			-- be very easy to introduce by editing one number.
			expect(SHIPPED.StartFractionPerSecond < SHIPPED.FullFractionPerSecond).to.equal(true)
		end)

		it("cannot out-heal a fight", function()
			-- The property that keeps this feature away from combat balance entirely: full-rate regen
			-- must be small next to the damage of a single ordinary hit. Asserted against the real
			-- constants so a retune that crossed this line would fail here rather than in a playtest.
			local fullRatePerSecond = SHIPPED.FullFractionPerSecond * Constants.Combat.MaxHealth
			expect(fullRatePerSecond < Constants.Combat.MaxHealth * 0.1).to.equal(true)
		end)

		it("never regenerates past full health", function()
			expect(SHIPPED.MaxFractionOfMax <= 1).to.equal(true)
			expect(SHIPPED.MaxFractionOfMax > 0).to.equal(true)
		end)
	end)
end
