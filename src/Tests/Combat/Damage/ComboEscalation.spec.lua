--!strict
-- Covers Server/Combat/Damage/ComboEscalation.lua -- the landing-based combo counter.
--
-- Driven entirely on a synthetic clock. The module reads no wall clock of its own (time comes from the
-- caller on every entry point, the same rule DefenseStateMachine and GuardMeter keep), so nothing here
-- sleeps and every window boundary is asserted exactly rather than approximately.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ComboEscalation = require(ServerScriptService.Server.Combat.Damage.ComboEscalation)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)

local T = 1000
local WINDOW = DamageConstants.Combo.WindowSeconds

local spawned: { Model } = {}

-- A bare Model is all this module ever touches -- it keys by attacker and never reads a rig. Parented
-- to nil-but-tracked so the Sweep-on-destroyed case can be exercised honestly.
local function makeAttacker(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = workspace
	table.insert(spawned, model)
	return model
end

return function()
	afterEach(function()
		ComboEscalation.Reset()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("ComboEscalation -- a fresh attacker", function()
		it("starts at stage 1 without any record existing", function()
			local attacker = makeAttacker("Fresh")
			expect(ComboEscalation.GetStage(attacker, T)).to.equal(1)
		end)

		it("counts its first landed hit as stage 1, not stage 0 or 2", function()
			-- The off-by-one that would make every first hit of every combo deal the wrong damage.
			local attacker = makeAttacker("First")
			expect(ComboEscalation.Advance(attacker, T)).to.equal(1)
		end)
	end)

	describe("ComboEscalation -- an unbroken string", function()
		it("advances one stage per landed hit", function()
			local attacker = makeAttacker("Stringing")
			expect(ComboEscalation.Advance(attacker, T)).to.equal(1)
			expect(ComboEscalation.Advance(attacker, T + 0.2)).to.equal(2)
			expect(ComboEscalation.Advance(attacker, T + 0.4)).to.equal(3)
			expect(ComboEscalation.GetStage(attacker, T + 0.5)).to.equal(3)
		end)

		it("clamps at the ceiling but keeps the string alive", function()
			local attacker = makeAttacker("Capped")
			local lastHitAt = T
			for index = 1, DamageConstants.Combo.MaxStage + 5 do
				lastHitAt = T + 0.1 * (index - 1)
				ComboEscalation.Advance(attacker, lastHitAt)
			end
			expect(ComboEscalation.GetStage(attacker, lastHitAt)).to.equal(DamageConstants.Combo.MaxStage)
			-- Still live: the window kept extending even after the stage stopped growing. Measured from
			-- the LAST hit, which is what the window hangs off -- measuring from any later moment would
			-- be testing this spec's own arithmetic rather than the module's.
			expect(ComboEscalation.GetStage(attacker, lastHitAt + WINDOW - 0.01)).to.equal(
				DamageConstants.Combo.MaxStage
			)
		end)

		it("extends the window from the most recent hit", function()
			local attacker = makeAttacker("Extending")
			ComboEscalation.Advance(attacker, T)
			ComboEscalation.Advance(attacker, T + WINDOW - 0.01)
			-- Would have lapsed on the FIRST hit's window, but the second pushed it out.
			expect(ComboEscalation.GetStage(attacker, T + WINDOW + 0.01)).to.equal(2)
		end)
	end)

	describe("ComboEscalation -- the window lapsing", function()
		it("drops back to stage 1 exactly at expiry, not merely after it", function()
			local attacker = makeAttacker("Lapsing")
			ComboEscalation.Advance(attacker, T)
			ComboEscalation.Advance(attacker, T + 0.1)
			expect(ComboEscalation.GetStage(attacker, T + 0.1 + WINDOW - 0.001)).to.equal(2)
			-- At the boundary itself, not one epsilon past it: a stage that survived its own expiry
			-- would make the window a suggestion.
			expect(ComboEscalation.GetStage(attacker, T + 0.1 + WINDOW)).to.equal(1)
		end)

		it("restarts a lapsed string at stage 1 with no reset call anywhere", function()
			local attacker = makeAttacker("Restarting")
			ComboEscalation.Advance(attacker, T)
			ComboEscalation.Advance(attacker, T + 0.1)
			expect(ComboEscalation.Advance(attacker, T + 0.1 + WINDOW + 1)).to.equal(1)
		end)
	end)

	describe("ComboEscalation -- the stagger relationship", function()
		it("has lapsed by the time a parried attacker's stagger ends", function()
			-- THE LOAD-BEARING RELATIONSHIP, asserted rather than the two numbers themselves: this is
			-- the entire reason the damage layer needs no "reset the combo on a parry" rule. If someone
			-- retunes Stagger.DurationSeconds down toward the 0.6-0.75 its own comment flags as the
			-- previous design's derived bound, this fails and says why.
			expect(WINDOW < DefenseConstants.Stagger.DurationSeconds).to.equal(true)

			local attacker = makeAttacker("Parried")
			ComboEscalation.Advance(attacker, T)
			ComboEscalation.Advance(attacker, T + 0.1)
			-- Parried at T + 0.1; the earliest they can act again is one full stagger later.
			local staggerEnds = T + 0.1 + DefenseConstants.Stagger.DurationSeconds
			expect(ComboEscalation.GetStage(attacker, staggerEnds)).to.equal(1)
		end)
	end)

	describe("ComboEscalation -- independence", function()
		it("keeps each attacker's string entirely separate", function()
			-- Combo state is per-attacker and never contested, so "who gets the combo" is never an
			-- arbitration between two claims on one resource.
			local alpha = makeAttacker("Alpha")
			local beta = makeAttacker("Beta")
			ComboEscalation.Advance(alpha, T)
			ComboEscalation.Advance(alpha, T + 0.1)
			ComboEscalation.Advance(beta, T + 0.1)
			expect(ComboEscalation.GetStage(alpha, T + 0.2)).to.equal(2)
			expect(ComboEscalation.GetStage(beta, T + 0.2)).to.equal(1)
		end)

		it("hands out a copy, so a caller cannot mutate the held record", function()
			local attacker = makeAttacker("Copied")
			ComboEscalation.Advance(attacker, T)
			local state = ComboEscalation.GetState(attacker, T)
			state.Stage = 99
			expect(ComboEscalation.GetStage(attacker, T)).to.equal(1)
		end)
	end)

	describe("ComboEscalation.Sweep", function()
		it("reclaims a lapsed record", function()
			-- This is what lets the module need no registration call and no PlayerRemoving hook.
			local attacker = makeAttacker("Swept")
			ComboEscalation.Advance(attacker, T)
			ComboEscalation.Sweep(T + WINDOW + 1)
			expect(ComboEscalation.GetStage(attacker, T)).to.equal(1)
		end)

		it("reclaims a record whose attacker has left the world", function()
			local attacker = makeAttacker("Destroyed")
			ComboEscalation.Advance(attacker, T)
			attacker.Parent = nil
			ComboEscalation.Sweep(T)
			-- Still inside its window, so only the missing body can have reclaimed it.
			expect(ComboEscalation.GetStage(attacker, T)).to.equal(1)
		end)

		it("leaves a live string alone", function()
			local attacker = makeAttacker("Surviving")
			ComboEscalation.Advance(attacker, T)
			ComboEscalation.Advance(attacker, T + 0.1)
			ComboEscalation.Sweep(T + 0.2)
			expect(ComboEscalation.GetStage(attacker, T + 0.2)).to.equal(2)
		end)
	end)
end
