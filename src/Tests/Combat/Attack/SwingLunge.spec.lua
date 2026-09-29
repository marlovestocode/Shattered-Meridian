--!strict
local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwingLunge = require(StarterPlayer.StarterPlayerScripts.Client.Combat.SwingLunge) :: any
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local LockOnConstants = require(ReplicatedStorage.Shared.Combat.LockOnConstants)

-- Integrates the speed curve numerically, the same way the physics engine will: sum speed * dt over
-- the window. Asserting on the INTEGRAL rather than on the peak is the point -- the authored number
-- is a distance, and a curve that peaks correctly but covers half the distance is exactly the silent
-- failure SpeedAt's own comment warns about.
local function travelled(distanceStuds: number, durationSeconds: number, steps: number): number
	local dt = durationSeconds / steps
	local total = 0
	for index = 0, steps - 1 do
		total += SwingLunge.SpeedAt(distanceStuds, durationSeconds, index * dt) * dt
	end
	return total
end

return function()
	describe("SpeedAt", function()
		it("starts at twice the average speed", function()
			-- 3 studs in 0.2s averages 15 studs/s, so a curve decaying to zero has to open at 30.
			expect(SwingLunge.SpeedAt(3, 0.2, 0)).to.be.near(30, 1e-6)
		end)

		it("decays linearly to a standstill at the end of the window", function()
			expect(SwingLunge.SpeedAt(3, 0.2, 0.1)).to.be.near(15, 1e-6)
			expect(SwingLunge.SpeedAt(3, 0.2, 0.15)).to.be.near(7.5, 1e-6)
		end)

		it("covers the authored distance over the window", function()
			-- Midpoint-free left Riemann sum over a falling line overshoots by half a step's worth, so
			-- the tolerance scales with the step count rather than being a fixed fudge.
			expect(travelled(3, 0.2, 2000)).to.be.near(3, 0.01)
			expect(travelled(5, 0.26, 2000)).to.be.near(5, 0.01)
		end)

		it("returns zero outside the window rather than a negative speed", function()
			-- Past the end matters: the frame loop reads this while `elapsed` is racing the duration,
			-- and a linear decay taken past 1.0 goes negative -- which would yank the character
			-- BACKWARDS on the last frame instead of releasing it.
			expect(SwingLunge.SpeedAt(3, 0.2, 0.2)).to.equal(0)
			expect(SwingLunge.SpeedAt(3, 0.2, 5)).to.equal(0)
			expect(SwingLunge.SpeedAt(3, 0.2, -1)).to.equal(0)
		end)

		it("returns zero for a degenerate authored pair instead of dividing by it", function()
			expect(SwingLunge.SpeedAt(3, 0, 0)).to.equal(0)
			expect(SwingLunge.SpeedAt(0, 0.2, 0)).to.equal(0)
		end)
	end)

	describe("DelayFor", function()
		it("waits out the swing's own windup", function()
			-- The whole point of the feature: the step is scheduled against what the SERVER said this
			-- specific swing's windup was, not against anything authored in this module.
			expect(SwingLunge.DelayFor(0.25, 0)).to.be.near(0.25, 1e-6)
			expect(SwingLunge.DelayFor(0.4, 0)).to.be.near(0.4, 1e-6)
		end)

		it("applies the authored offset on top of it, in both directions", function()
			expect(SwingLunge.DelayFor(0.25, 0.05)).to.be.near(0.3, 1e-6)
			-- Negative is the useful direction -- the lean starts inside the windup rather than after it.
			expect(SwingLunge.DelayFor(0.25, -0.05)).to.be.near(0.2, 1e-6)
		end)

		it("floors at zero rather than scheduling a step in the past", function()
			-- A stage whose windup is shorter than the offset. Measured against os.clock(), a negative
			-- delay is a step that fires instantly AND has already burned part of its own duration, so
			-- it would travel less than its authored distance with nothing to explain why.
			expect(SwingLunge.DelayFor(0.05, -0.2)).to.equal(0)
			expect(SwingLunge.DelayFor(0, -1)).to.equal(0)
		end)

		it("degrades to immediate for a swing the server reported no windup for", function()
			expect(SwingLunge.DelayFor(0, 0)).to.equal(0)
		end)
	end)

	describe("tuning", function()
		it("authors a step for Heavy only -- Basic and the hotbar both go without one", function()
			local byKind = AttackConstants.Presentation.SwingLunge.ByKind
			expect(byKind.Heavy).to.be.ok()
			-- Absent, not zero, for two different reasons that land on the same contract. Hotbar: an
			-- authored move carries its own lunge pair (MoveTypes), and a second number here would be the
			-- one-system-two-configs trap the tuning comment names. Basic: it USED to carry a step, and
			-- was deliberately dropped after a playtest read it as the punch closing distance for the
			-- player rather than the player closing it themselves -- see the ByKind comment's own
			-- "BASIC IS ALSO ABSENT NOW" paragraph. Either way, onAttackStarted (SwingLunge.lua) treats a
			-- missing entry as "this move does not step" -- an ordinary authoring answer, not a fault --
			-- which is what makes asserting the absence here as load-bearing as asserting the presence.
			expect(byKind.Basic).to.never.be.ok()
			expect(byKind.Hotbar).to.never.be.ok()
		end)

		it("keeps every authored step positive in both dimensions", function()
			-- A zero or negative duration would divide by zero in SpeedAt; a zero distance would author
			-- a step that silently does nothing. Both are caught here rather than in a playtest.
			for kind, entry in AttackConstants.Presentation.SwingLunge.ByKind do
				expect(entry.DistanceStuds > 0).to.equal(true, kind)
				expect(entry.DurationSeconds > 0).to.equal(true, kind)
			end
		end)

		it("authors a delay offset for every kind that has a step", function()
			-- A kind added to ByKind without this field throws inside DelayFor the first time that move
			-- is swung, and unwinds out of AttackInputClient's un-pcall'd listener loop with it. Cheap
			-- to catch here; expensive to find in a playtest.
			for kind, entry in AttackConstants.Presentation.SwingLunge.ByKind do
				expect(type(entry.DelaySeconds)).to.equal("number", kind)
			end
		end)

		it("keeps every step short enough not to be a gap-closer", function()
			-- The tuning comment's own promise: a swing thrown from outside range still misses. Six
			-- studs is roughly a character's own reach, so anything at or past it starts closing gaps
			-- that the attack layer is supposed to make the player close themselves.
			for kind, entry in AttackConstants.Presentation.SwingLunge.ByKind do
				expect(entry.DistanceStuds < 6).to.equal(true, kind)
			end
		end)
	end)

	describe("IsStepping / IsPending", function()
		it("are both false before any swing has been confirmed", function()
			expect(SwingLunge.IsStepping()).to.equal(false)
			expect(SwingLunge.IsPending()).to.equal(false)
		end)
	end)
	describe("SwingLunge.StepInDistance -- the target-aware step", function()
		local STEP = LockOnConstants.StepIn

		it("never steps without a target unless the kind authors its own step", function()
			expect(SwingLunge.StepInDistance(nil, nil)).to.equal(0)
			expect(SwingLunge.StepInDistance(nil, 5)).to.equal(5)
		end)

		it("closes the gap to the standoff and no further", function()
			local gap = STEP.StandoffStuds + 1.5
			expect(SwingLunge.StepInDistance(gap, nil)).to.be.near(1.5, 1e-6)
		end)

		it("does not step toward a target already in range", function()
			expect(SwingLunge.StepInDistance(STEP.StandoffStuds + STEP.MinStepStuds * 0.5, nil)).to.equal(0)
			expect(SwingLunge.StepInDistance(STEP.StandoffStuds - 1, nil)).to.equal(0)
		end)

		it("does not chase a target out of reach -- it is not a gap-closer", function()
			expect(SwingLunge.StepInDistance(STEP.StandoffStuds + STEP.MaxStepStuds + 1, nil)).to.equal(0)
		end)

		it("keeps an authored step, but never past a close target", function()
			expect(SwingLunge.StepInDistance(STEP.StandoffStuds + 20, 5)).to.equal(5)
			expect(SwingLunge.StepInDistance(STEP.StandoffStuds + 1, 5)).to.be.near(1, 1e-6)
			expect(SwingLunge.StepInDistance(STEP.StandoffStuds, 5)).to.equal(0)
		end)
	end)
end
