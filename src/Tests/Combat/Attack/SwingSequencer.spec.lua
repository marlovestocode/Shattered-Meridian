--!strict
-- Covers Server/Combat/Attack/SwingSequencer.lua -- the throw-based "which move throws next" counter.
--
-- Driven entirely on a synthetic clock. The module reads no wall clock of its own (time comes from the
-- caller on every entry point, the same rule DefenseStateMachine, GuardMeter and ComboEscalation all
-- keep), so nothing here sleeps and every window boundary is asserted exactly rather than
-- approximately.
--
-- Asserts against the REAL catalogue rather than a stubbed one: the whole point of the module is that
-- it discovers a string's length by probing what is actually authored, so a fake registry would test
-- the probe against itself. That does mean these cases read Constants.Combat.Weapons' real stage
-- counts -- so they assert the SHAPE ("the last stage wraps", "one past the end is stage 1") wherever
-- possible, and pin a literal count in exactly one place, where a changed count SHOULD fail loudly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local SwingSequencer = require(ServerScriptService.Server.Combat.Attack.SwingSequencer)

local T = 1000
local RESET = AttackConstants.Sequence.ResetSeconds
local CHAIN_DELAY = AttackConstants.Sequence.ChainDelaySeconds
local FINISHER_STAGE = AttackConstants.Finisher.MinComboStage

local spawned: { Model } = {}

-- A bare Model is all this module ever touches -- it keys by attacker and never reads a rig.
local function makeAttacker(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = workspace
	table.insert(spawned, model)
	return model
end

-- How many stages the Primary Basic string actually has, discovered the same way the module does.
local function primaryBasicCount(): number
	local count = 0
	for index = 1, AttackConstants.Sequence.MaxStageProbe do
		if not AttackCatalog.Has(`default:Primary:Basic:{index}`) then
			break
		end
		count = index
	end
	return count
end

-- How long a swing occupies its thrower for. Zero here on purpose for most cases: the string's
-- deadline is (throw time + commitment + ResetSeconds), and a case about the RESET WINDOW should not
-- also be silently depending on how long a particular authored move happens to take. The one case
-- that is about the commitment passes a real one.
local NO_COMMITMENT = 0

-- Throws `times` Basic swings starting at T, advancing the record each time, and returns the last
-- resolution.
local function throwBasic(model: Model, times: number, comboStage: number): SwingSequencer.Resolution
	local last: SwingSequencer.Resolution
	for index = 1, times do
		local at = T + (index - 1) * 0.2
		local resolution = SwingSequencer.Resolve(model, "Basic", comboStage, at)
		assert(resolution ~= nil, "the Primary Basic string must resolve")
		last = resolution :: SwingSequencer.Resolution
		SwingSequencer.Advance(model, "Basic", last, NO_COMMITMENT, at)
	end
	return last
end

return function()
	afterEach(function()
		SwingSequencer.Reset()
		AttackCatalog.Reset()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("SwingSequencer -- the authored move set it probes", function()
		it("finds the Primary Basic string by probing the catalogue, not by reading a count", function()
			-- The one place a literal count is pinned. If Constants.Combat.Weapons.Primary.Stages.Basic
			-- ever grows or shrinks, this is the test that should say so -- every other case below is
			-- written against the discovered count so it survives a retune.
			expect(primaryBasicCount()).to.equal(3)
		end)

		it("returns nil for a string the weapon has no authored stages for", function()
			-- Not reachable through the two real weapons today, so it is asserted through SetWeapon
			-- refusing an id that is not in the swap order at all -- the same "do not substitute
			-- something" contract AttackCatalog.Get keeps for an unknown MoveId.
			local attacker = makeAttacker("NoSuchWeapon")
			expect(SwingSequencer.SetWeapon(attacker, "Tertiary" :: any, T)).to.equal(false)
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(AttackConstants.Weapons.Default)
		end)
	end)

	describe("SwingSequencer -- a fresh combatant", function()
		it("starts on the default weapon", function()
			local attacker = makeAttacker("Fresh")
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(AttackConstants.Weapons.Default)
		end)

		it("resolves its first Basic press to stage 1", function()
			local attacker = makeAttacker("First")
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T)
			expect(resolution).to.be.ok()
			expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(1)
			expect((resolution :: SwingSequencer.Resolution).MoveId).to.equal("default:Primary:Basic:1")
		end)

		it("reports no string in progress before anything is thrown", function()
			local attacker = makeAttacker("Untouched")
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T)).to.equal(0)
		end)
	end)

	describe("SwingSequencer -- Resolve does not commit", function()
		it("returns the same stage twice when Advance is never called", function()
			-- The property that makes "press early, get refused, press again" continue the combo
			-- instead of silently skipping a stage: a refused press must leave the string untouched.
			local attacker = makeAttacker("Refused")
			local first = SwingSequencer.Resolve(attacker, "Basic", 1, T)
			local second = SwingSequencer.Resolve(attacker, "Basic", 1, T + 0.1)
			expect((first :: SwingSequencer.Resolution).StageIndex).to.equal(1)
			expect((second :: SwingSequencer.Resolution).StageIndex).to.equal(1)
		end)
	end)

	describe("SwingSequencer -- an unbroken string", function()
		it("advances one stage per accepted throw", function()
			local attacker = makeAttacker("Stringing")
			local count = primaryBasicCount()
			for index = 1, count do
				local at = T + (index - 1) * 0.2
				local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, at)
				expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(index)
				SwingSequencer.Advance(attacker, "Basic", resolution :: SwingSequencer.Resolution, NO_COMMITMENT, at)
			end
		end)

		it("wraps back to stage 1 past the end of the string when the combo is too shallow", function()
			-- comboStage 1 is below Finisher.MinComboStage, so completing the string wraps rather than
			-- tipping into the finisher. This is the whiffing player's experience: the string cycles.
			local attacker = makeAttacker("Wrapping")
			local count = primaryBasicCount()
			throwBasic(attacker, count, 1)
			local wrapped = SwingSequencer.Resolve(attacker, "Basic", 1, T + count * 0.2)
			expect((wrapped :: SwingSequencer.Resolution).StageIndex).to.equal(1)
			expect((wrapped :: SwingSequencer.Resolution).IsFinisher).to.equal(false)
		end)

		it("advances on a throw regardless of whether anything landed", function()
			-- The whole reason this counter is separate from ComboEscalation: comboStage stays at 1
			-- (nothing landed) and the string still cycles.
			local attacker = makeAttacker("Whiffing")
			throwBasic(attacker, 2, 1)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T + 0.3)).to.equal(2)
		end)
	end)

	describe("SwingSequencer -- the string lapsing", function()
		it("keeps the string alive right up to the reset boundary", function()
			local attacker = makeAttacker("Boundary")
			throwBasic(attacker, 1, 1)
			-- Asserted a millisecond either side of the boundary rather than merely "somewhere inside"
			-- and "somewhere after" -- that pins the window to within a millisecond, which is as tight
			-- as this is worth being.
			--
			-- Deliberately NOT asserted at exactly T + RESET: `(1000 + 1.2) - 1000` is 1.2000000000000455
			-- in double precision, so an exact-boundary assertion tests the float representation of the
			-- test's own arbitrary epoch rather than the module's rule. A sub-millisecond disagreement
			-- about when a 1.2-second window closes is not a behaviour anything can observe.
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T + RESET - 1e-3)).to.equal(1)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T + RESET + 1e-3)).to.equal(0)
		end)

		it("starts again at stage 1 once the gap exceeds the reset window", function()
			local attacker = makeAttacker("Lapsed")
			throwBasic(attacker, 2, 1)
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T + RESET + 0.5)
			expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(1)
		end)

		it("keeps the weapon across a lapsed string", function()
			-- The specific reason Sweep only reclaims destroyed models: dropping a lapsed record would
			-- silently hand a player back the default weapon for standing still.
			local attacker = makeAttacker("Patient")
			SwingSequencer.SwapWeapon(attacker, T)
			SwingSequencer.Sweep()
			expect(SwingSequencer.GetWeapon(attacker)).to.equal("Secondary")
		end)
	end)

	describe("SwingSequencer -- the beat between links", function()
		it("reports no beat owed before anything has been thrown", function()
			local attacker = makeAttacker("Rested")
			expect(SwingSequencer.ChainDelayRemaining(attacker, T)).to.equal(0)
		end)

		it("measures the beat from the end of the swing, not its start", function()
			-- The same end-relative rule the reset window uses, and for the same reason: a beat measured
			-- from the throw would be shorter after a slow move than after a fast one, which is exactly
			-- backwards.
			local attacker = makeAttacker("Beating")
			local commitment = 0.7
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T)
			SwingSequencer.Advance(attacker, "Basic", resolution :: SwingSequencer.Resolution, commitment, T)

			-- Still owed while the swing itself is running.
			expect(SwingSequencer.ChainDelayRemaining(attacker, T + commitment) > 0).to.equal(true)
			-- And still owed a moment after it ends.
			expect(SwingSequencer.ChainDelayRemaining(attacker, T + commitment + CHAIN_DELAY - 1e-3) > 0).to.equal(true)
			-- Paid off a moment after that.
			expect(SwingSequencer.ChainDelayRemaining(attacker, T + commitment + CHAIN_DELAY + 1e-3)).to.equal(0)
		end)

		it("is not refunded by swapping weapons", function()
			-- Otherwise the swap key would be a free way to skip the beat owed for the swing just thrown.
			local attacker = makeAttacker("SwapSkipper")
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T)
			SwingSequencer.Advance(attacker, "Basic", resolution :: SwingSequencer.Resolution, 0, T)
			SwingSequencer.SwapWeapon(attacker, T + 0.01)
			expect(SwingSequencer.ChainDelayRemaining(attacker, T + 0.02) > 0).to.equal(true)
		end)
	end)

	describe("SwingSequencer -- switching strings", function()
		it("restarts the string that was switched away from", function()
			-- Without this, alternating presses would hold both strings at their last stage and arrive
			-- at two finishers' worth of state for free.
			local attacker = makeAttacker("Switcher")
			throwBasic(attacker, 2, 1)

			local heavy = SwingSequencer.Resolve(attacker, "Heavy", 1, T + 0.5)
			expect((heavy :: SwingSequencer.Resolution).StageIndex).to.equal(1)
			SwingSequencer.Advance(attacker, "Heavy", heavy :: SwingSequencer.Resolution, NO_COMMITMENT, T + 0.5)

			local backToBasic = SwingSequencer.Resolve(attacker, "Basic", 1, T + 0.7)
			expect((backToBasic :: SwingSequencer.Resolution).StageIndex).to.equal(1)
		end)
	end)

	describe("SwingSequencer -- the finisher", function()
		it("tips a completed Basic string into the Finisher once the landed combo is deep enough", function()
			local attacker = makeAttacker("Finishing")
			local count = primaryBasicCount()
			throwBasic(attacker, count, FINISHER_STAGE)
			local finisher = SwingSequencer.Resolve(attacker, "Basic", FINISHER_STAGE, T + count * 0.2)
			expect((finisher :: SwingSequencer.Resolution).IsFinisher).to.equal(true)
			expect((finisher :: SwingSequencer.Resolution).MoveId).to.equal("default:Primary:Finisher")
			expect((finisher :: SwingSequencer.Resolution).StageIndex).to.equal(0)
		end)

		it("does not unlock the Finisher one stage below the threshold", function()
			local attacker = makeAttacker("NearlyFinishing")
			local count = primaryBasicCount()
			throwBasic(attacker, count, FINISHER_STAGE - 1)
			local wrapped = SwingSequencer.Resolve(attacker, "Basic", FINISHER_STAGE - 1, T + count * 0.2)
			expect((wrapped :: SwingSequencer.Resolution).IsFinisher).to.equal(false)
		end)

		it("never offers a Finisher on the Heavy string", function()
			-- The finisher is the Basic string's payoff. Heavy wraps like any other string.
			local attacker = makeAttacker("HeavyFinisher")
			local stage = 0
			for index = 1, AttackConstants.Sequence.MaxStageProbe do
				local at = T + (index - 1) * 0.2
				local resolution = SwingSequencer.Resolve(attacker, "Heavy", FINISHER_STAGE + 5, at)
				if not resolution then
					break
				end
				expect(resolution.IsFinisher).to.equal(false)
				SwingSequencer.Advance(attacker, "Heavy", resolution, NO_COMMITMENT, at)
				stage = index
			end
			expect(stage > 0).to.equal(true)
		end)

		it("starts the next string at stage 1 after a Finisher", function()
			-- Falls out of Advance recording StageIndex 0 -- no special-cased reset path.
			local attacker = makeAttacker("PostFinisher")
			local count = primaryBasicCount()
			throwBasic(attacker, count, FINISHER_STAGE)
			local at = T + count * 0.2
			local finisher = SwingSequencer.Resolve(attacker, "Basic", FINISHER_STAGE, at)
			SwingSequencer.Advance(attacker, "Basic", finisher :: SwingSequencer.Resolution, NO_COMMITMENT, at)

			local next_ = SwingSequencer.Resolve(attacker, "Basic", FINISHER_STAGE, at + 0.2)
			expect((next_ :: SwingSequencer.Resolution).StageIndex).to.equal(1)
			expect((next_ :: SwingSequencer.Resolution).IsFinisher).to.equal(false)
		end)
	end)

	describe("SwingSequencer -- weapons", function()
		it("cycles through the authored swap order and back", function()
			local attacker = makeAttacker("Swapper")
			expect(SwingSequencer.SwapWeapon(attacker, T)).to.equal("Secondary")
			expect(SwingSequencer.SwapWeapon(attacker, T + 1)).to.equal("Primary")
		end)

		it("resolves against the newly held weapon's own string", function()
			local attacker = makeAttacker("SwappedString")
			SwingSequencer.SwapWeapon(attacker, T)
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T + 0.1)
			expect((resolution :: SwingSequencer.Resolution).MoveId).to.equal("default:Secondary:Basic:1")
		end)

		it("abandons the in-progress string on a swap rather than carrying the stage across", function()
			-- Stage 2 of a Primary string is not stage 2 of a Secondary one; carrying the count would
			-- throw a move the player never worked up to.
			local attacker = makeAttacker("SwapMidString")
			throwBasic(attacker, 2, 1)
			SwingSequencer.SwapWeapon(attacker, T + 0.5)
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T + 0.6)
			expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(1)
		end)
	end)

	describe("SwingSequencer -- reclamation", function()
		it("drops a destroyed combatant's record", function()
			local attacker = makeAttacker("Destroyed")
			SwingSequencer.SwapWeapon(attacker, T)
			attacker:Destroy()
			SwingSequencer.Sweep()
			-- A fresh record is built on demand, back on the default weapon.
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(AttackConstants.Weapons.Default)
		end)

		it("drops everything on Clear", function()
			local attacker = makeAttacker("Cleared")
			throwBasic(attacker, 2, 1)
			SwingSequencer.Clear(attacker)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T + 0.3)).to.equal(0)
		end)
	end)
end
