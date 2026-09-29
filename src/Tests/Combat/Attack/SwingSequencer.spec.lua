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
-- the probe against itself. The weapons themselves come from TestHelpers/WeaponFixture (models in
-- Workspace.Weapons -- see Shared/Combat/WeaponRoster.lua), because a weapon is a DataModel fact now
-- rather than a constant; the stage COUNTS those weapons carry are still the real authored ones off
-- CombatConstants.Weapons.Baseline, so these cases assert the SHAPE ("the last stage wraps", "one past
-- the end is stage 1") wherever possible and pin a literal count in exactly one place, where a changed
-- count SHOULD fail loudly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local SwingSequencer = require(ServerScriptService.Server.Combat.Attack.SwingSequencer)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

-- Installed once for the whole file (not per case) -- building a roster invalidates the catalogue's
-- descriptor cache, and doing that between cases would be pure overhead for a fixture none of them
-- mutate. FIRST_WEAPON is the roster's own first entry, which is what a fresh combatant starts on.
local ROSTER = WeaponFixture.Install()
local FIRST_WEAPON = ROSTER[1]
local SECOND_WEAPON = ROSTER[2]

local T = 1000
local RESET = AttackConstants.Sequence.ResetSeconds
local CHAIN_DELAY = AttackConstants.Sequence.ChainDelaySeconds
-- A landed combo deep enough for anything the string could offer: the launcher's own threshold.
local FULL_COMBO = AirComboConstants.Launcher.MinComboStage
local END_OF_STRING = AttackConstants.Sequence.EndOfStringCooldownSeconds

local spawned: { Model } = {}

-- Sweep is amortised (Shared/AmortizedReclaim.lua): one call examines a fixed handful of records, not
-- the whole table. A case that wants "every destroyed record is gone" therefore has to run the cursor
-- far enough round to lap the table, which is what sweepFully does -- generously bounded above the
-- number of attackers this whole file registers, so it always laps and always terminates.
local SWEEP_BOUND = 512

local function sweepFully(): ()
	for _ = 1, SWEEP_BOUND do
		SwingSequencer.Sweep()
	end
end

-- A bare Model is all this module ever touches -- it keys by attacker and never reads a rig.
--
-- ARMED ON CREATION, because a fresh record is now EMPTY-HANDED: a combatant holds nothing until
-- something draws a weapon for them (Server/Combat/Weapon/WeaponInventorySystem.lua), so a bare Model
-- resolves no swings at all. Every case below is about the STRING rather than about being armed, so
-- arming is fixture work rather than something each case restates. The one case that IS about starting
-- state calls makeUnarmedAttacker instead.
local function makeUnarmedAttacker(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = workspace
	table.insert(spawned, model)
	return model
end

local function makeAttacker(name: string): Model
	local model = makeUnarmedAttacker(name)
	SwingSequencer.SetWeapon(model, FIRST_WEAPON, T)
	return model
end

-- How many stages the first roster weapon's Basic string actually has, discovered the same way the
-- module does.
local function firstWeaponBasicCount(): number
	local count = 0
	for index = 1, AttackConstants.Sequence.MaxStageProbe do
		if not AttackCatalog.Has(`default:{FIRST_WEAPON}:Basic:{index}`) then
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
		assert(resolution ~= nil, "the first weapon's Basic string must resolve")
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
		it("finds the first weapon's Basic string by probing the catalogue, not by reading a count", function()
			-- The one place a literal count is pinned. If CombatConstants.Weapons.Baseline.Stages.Basic
			-- ever grows or shrinks, this is the test that should say so -- every other case below is
			-- written against the discovered count so it survives a retune.
			expect(firstWeaponBasicCount()).to.equal(3)
		end)

		it("returns nil for a string the weapon has no authored stages for", function()
			-- Not reachable through the fixture's weapons, so it is asserted through SetWeapon
			-- refusing an id the roster does not know at all -- the same "do not substitute
			-- something" contract AttackCatalog.Get keeps for an unknown MoveId.
			local attacker = makeAttacker("NoSuchWeapon")
			expect(SwingSequencer.SetWeapon(attacker, "Tertiary" :: any, T)).to.equal(false)
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(FIRST_WEAPON)
		end)
	end)

	describe("SwingSequencer -- a fresh combatant", function()
		it("starts EMPTY-HANDED, holding nothing until something arms them", function()
			-- The property the whole pickup/draw loop rests on: spawning does not hand anybody a
			-- weapon. A combatant with no weapon resolves no swings, which is what makes "sheathed"
			-- need no gate of its own -- see WeaponInventorySystem's own header.
			local attacker = makeUnarmedAttacker("Fresh")
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(nil)
			expect(SwingSequencer.Resolve(attacker, "Basic", 1, T)).to.equal(nil)
		end)

		it("resolves once armed", function()
			local attacker = makeAttacker("Armed")
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(FIRST_WEAPON)
		end)

		it("resolves its first Basic press to stage 1", function()
			local attacker = makeAttacker("First")
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T)
			expect(resolution).to.be.ok()
			expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(1)
			expect((resolution :: SwingSequencer.Resolution).MoveId).to.equal(`default:{FIRST_WEAPON}:Basic:1`)
		end)

		it("reports no string in progress before anything is thrown", function()
			local attacker = makeAttacker("Untouched")
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T)).to.equal(0)
		end)
	end)

	describe("SwingSequencer.ClearWeapon", function()
		it("empties the hands and stops resolving -- the whole of what sheathing is", function()
			local attacker = makeAttacker("Sheathing")
			expect(SwingSequencer.Resolve(attacker, "Basic", 1, T)).to.be.ok()

			SwingSequencer.ClearWeapon(attacker, T)
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(nil)
			expect(SwingSequencer.Resolve(attacker, "Basic", 1, T)).to.equal(nil)
		end)

		it("abandons the string, so re-drawing starts at stage 1 rather than mid-combo", function()
			local attacker = makeAttacker("Redrawn")
			throwBasic(attacker, 2, 1)

			SwingSequencer.ClearWeapon(attacker, T)
			SwingSequencer.SetWeapon(attacker, FIRST_WEAPON, T)

			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T)
			expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(1)
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
			local count = firstWeaponBasicCount()
			for index = 1, count do
				local at = T + (index - 1) * 0.2
				local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, at)
				expect((resolution :: SwingSequencer.Resolution).StageIndex).to.equal(index)
				SwingSequencer.Advance(attacker, "Basic", resolution :: SwingSequencer.Resolution, NO_COMMITMENT, at)
			end
		end)

		it("wraps back to stage 1 past the end of the string", function()
			-- The whiffing player's experience: the string cycles.
			local attacker = makeAttacker("Wrapping")
			local count = firstWeaponBasicCount()
			throwBasic(attacker, count, 1)
			local wrapped = SwingSequencer.Resolve(attacker, "Basic", 1, T + count * 0.2)
			expect((wrapped :: SwingSequencer.Resolution).StageIndex).to.equal(1)
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
			sweepFully()
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(SECOND_WEAPON)
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

	describe("SwingSequencer -- the 4th M1", function()
		-- The only 4th hit of an M1 string is the air combo's launcher (Space + M1 after B3). A plain M1
		-- after a fully LANDED string used to tip into the weapon's Finisher; it now starts a fresh string.
		it("never throws the Finisher off a fully landed string", function()
			local attacker = makeAttacker("NoFinisher")
			local count = firstWeaponBasicCount()
			throwBasic(attacker, count, FULL_COMBO)
			local fourth = SwingSequencer.Resolve(attacker, "Basic", FULL_COMBO, T + count * 0.2)
			expect((fourth :: SwingSequencer.Resolution).MoveId).to.equal(`default:{FIRST_WEAPON}:Basic:1`)
			expect((fourth :: SwingSequencer.Resolution).IsLauncher).never.to.equal(true)
		end)

		it("makes a plain press after a completed string wait out the end-of-string lockout", function()
			local attacker = makeAttacker("LockedOut")
			local count = firstWeaponBasicCount()
			throwBasic(attacker, count, FULL_COMBO)
			local lastAt = T + (count - 1) * 0.2
			local plain = SwingSequencer.Resolve(attacker, "Basic", FULL_COMBO, lastAt + CHAIN_DELAY + 0.01)
			expect(SwingSequencer.ChainDelayRemaining(attacker, lastAt + CHAIN_DELAY + 0.01, plain) > 0).to.equal(true)
			expect(SwingSequencer.ChainDelayRemaining(attacker, lastAt + END_OF_STRING + 0.01, plain)).to.equal(0)
		end)

		it("lets the launcher follow a completed string on the ordinary beat, not the lockout", function()
			-- The launcher IS the string's 4th link. A 0.5s lockout before it would outrun the combo window
			-- whose landed hits it needs.
			local attacker = makeAttacker("LaunchOnBeat")
			local count = firstWeaponBasicCount()
			throwBasic(attacker, count, FULL_COMBO)
			local at = T + (count - 1) * 0.2 + CHAIN_DELAY + 0.01
			local launcher = SwingSequencer.Resolve(attacker, "Basic", FULL_COMBO, at, { ModifierUp = true })
			expect((launcher :: SwingSequencer.Resolution).IsLauncher).to.equal(true)
			expect(SwingSequencer.ChainDelayRemaining(attacker, at, launcher)).to.equal(0)
		end)
	end)

	describe("SwingSequencer -- weapons", function()
		it("cycles through the authored swap order and back", function()
			-- The roster always ends in the synthesized fists (WeaponRoster.FISTS_ID), so the cycle is
			-- the Workspace weapons in order, then bare hands, then round again.
			local attacker = makeAttacker("Swapper")
			expect(SwingSequencer.SwapWeapon(attacker, T)).to.equal(SECOND_WEAPON)
			expect(SwingSequencer.SwapWeapon(attacker, T + 1)).to.equal(WeaponRoster.FISTS_ID)
			expect(SwingSequencer.SwapWeapon(attacker, T + 2)).to.equal(FIRST_WEAPON)
		end)

		it("resolves against the newly held weapon's own string", function()
			local attacker = makeAttacker("SwappedString")
			SwingSequencer.SwapWeapon(attacker, T)
			local resolution = SwingSequencer.Resolve(attacker, "Basic", 1, T + 0.1)
			expect((resolution :: SwingSequencer.Resolution).MoveId).to.equal(`default:{SECOND_WEAPON}:Basic:1`)
		end)

		it("abandons the in-progress string on a swap rather than carrying the stage across", function()
			-- Stage 2 of one weapon's string is not stage 2 of another's; carrying the count would
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
			sweepFully()
			-- A fresh record is built on demand, and a fresh record is EMPTY-HANDED -- so the rebuilt
			-- one no longer remembers the weapon that was set on the reclaimed one.
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(nil)
		end)

		it("reclaims a destroyed record within a bounded number of frames, not necessarily the next one", function()
			local attacker = makeAttacker("Amortised")
			SwingSequencer.SwapWeapon(attacker, T)
			attacker:Destroy()
			-- The contract Sweep actually offers now (Shared/AmortizedReclaim.lua): a fixed handful of
			-- keys per call, so the number of calls needed scales with how much OTHER state this spec
			-- file has registered -- but it is always bounded, and it always terminates in a state
			-- where nothing destroyed is left. Asserting "one Sweep is enough" would be asserting the
			-- full walk that was removed.
			local sweeps = 0
			while SwingSequencer.GetWeapon(attacker) ~= nil and sweeps < SWEEP_BOUND do
				SwingSequencer.Sweep()
				sweeps += 1
			end
			expect(SwingSequencer.GetWeapon(attacker)).to.equal(nil)
			expect(sweeps < SWEEP_BOUND).to.equal(true)
		end)

		it("drops everything on Clear", function()
			local attacker = makeAttacker("Cleared")
			throwBasic(attacker, 2, 1)
			SwingSequencer.Clear(attacker)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T + 0.3)).to.equal(0)
		end)
	end)

	describe("SwingSequencer -- the air combo's launcher branch", function()
		local LAUNCHER = AirComboConstants.Launcher
		local UP = { ModifierUp = true }

		it("throws the Launcher for Space + M1 once the string and the landed combo have earned it", function()
			local attacker = makeAttacker("Launcher")
			throwBasic(attacker, LAUNCHER.MinStringStage, 1)
			local at = T + LAUNCHER.MinStringStage * 0.2
			local resolution = SwingSequencer.Resolve(attacker, "Basic", LAUNCHER.MinComboStage, at, UP)
			expect(resolution).to.be.ok()
			expect((resolution :: any).MoveId).to.equal(`default:{FIRST_WEAPON}:Launcher`)
			expect((resolution :: any).IsLauncher).to.equal(true)
		end)

		it("is just the next Basic when the string has not thrown enough stages -- never a dead input", function()
			local attacker = makeAttacker("TooEarly")
			throwBasic(attacker, LAUNCHER.MinStringStage - 1, 1)
			local at = T + LAUNCHER.MinStringStage * 0.2
			local resolution = SwingSequencer.Resolve(attacker, "Basic", LAUNCHER.MinComboStage, at, UP)
			expect((resolution :: any).MoveId).to.equal(`default:{FIRST_WEAPON}:Basic:{LAUNCHER.MinStringStage}`)
		end)

		it("ignores a forged modifier when the landed combo has not earned it", function()
			local attacker = makeAttacker("Forged")
			throwBasic(attacker, LAUNCHER.MinStringStage, 1)
			local at = T + LAUNCHER.MinStringStage * 0.2
			local resolution = SwingSequencer.Resolve(attacker, "Basic", LAUNCHER.MinComboStage - 1, at, UP)
			expect((resolution :: any).IsLauncher).never.to.equal(true)
		end)

		it("needs the modifier: the same earned press without Space continues the string", function()
			local attacker = makeAttacker("NoModifier")
			throwBasic(attacker, LAUNCHER.MinStringStage, 1)
			local at = T + LAUNCHER.MinStringStage * 0.2
			local resolution = SwingSequencer.Resolve(attacker, "Basic", LAUNCHER.MinComboStage, at)
			expect((resolution :: any).IsLauncher).never.to.equal(true)
		end)

		it("ends the ground string: the next ground press after a launcher starts at stage 1", function()
			local attacker = makeAttacker("AfterLaunch")
			throwBasic(attacker, LAUNCHER.MinStringStage, 1)
			local at = T + LAUNCHER.MinStringStage * 0.2
			local launcher = SwingSequencer.Resolve(attacker, "Basic", LAUNCHER.MinComboStage, at, UP)
			SwingSequencer.Advance(attacker, "Basic", launcher :: any, NO_COMMITMENT, at)
			local nextPress = SwingSequencer.Resolve(attacker, "Basic", 1, at + CHAIN_DELAY + 0.01)
			expect((nextPress :: any).MoveId).to.equal(`default:{FIRST_WEAPON}:Basic:1`)
		end)
	end)

	describe("SwingSequencer -- air moves inside a combo", function()
		it("turns the air combo's role into the weapon's own air move", function()
			local attacker = makeAttacker("AirBeat")
			local beat = SwingSequencer.Resolve(attacker, "Basic", 1, T, { AirRole = { Role = "Air", Beat = 2 } })
			expect((beat :: any).MoveId).to.equal(`default:{FIRST_WEAPON}:Air:2`)
			local spike =
				SwingSequencer.Resolve(attacker, "Heavy", 1, T, { AirRole = { Role = "Finisher", Finisher = "Spike" } })
			expect((spike :: any).MoveId).to.equal(`default:{FIRST_WEAPON}:AirFinisher:Spike`)
		end)

		it("throws nothing for an air beat the weapon has not authored", function()
			local attacker = makeAttacker("NoSuchBeat")
			local resolution =
				SwingSequencer.Resolve(attacker, "Basic", 1, T, { AirRole = { Role = "Air", Beat = 99 } })
			expect(resolution).to.equal(nil)
		end)
	end)
	describe("SwingSequencer.Weave -- an Art holds the string's place", function()
		it("does not spend a stage: B1, B2, an Art, then M1 is B3", function()
			local attacker = makeAttacker("WeaveStage")
			throwBasic(attacker, 2, 1)
			local artAt = T + 0.3
			SwingSequencer.Weave(attacker, "art:test", 0.5, artAt)
			local nextPress = SwingSequencer.Resolve(attacker, "Basic", 1, artAt + 0.5 + CHAIN_DELAY)
			expect((nextPress :: any).StageIndex).to.equal(3)
		end)

		it("holds the string live through a long art, with the full grace after it", function()
			local attacker = makeAttacker("WeaveLong")
			throwBasic(attacker, 2, 1)
			local artAt = T + 0.3
			local artLength = RESET + 1
			SwingSequencer.Weave(attacker, "art:long", artLength, artAt)
			-- Past the grace the last M1 left, but inside the art's own end plus grace.
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", artAt + artLength + RESET - 0.01)).to.equal(2)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", artAt + artLength + RESET + 0.01)).to.equal(0)
		end)

		it("makes the next link owe the ordinary beat after the art", function()
			local attacker = makeAttacker("WeaveBeat")
			throwBasic(attacker, 1, 1)
			local artAt = T + 0.3
			SwingSequencer.Weave(attacker, "art:beat", 0.5, artAt)
			expect(SwingSequencer.ChainDelayRemaining(attacker, artAt + 0.5)).to.be.near(CHAIN_DELAY, 1e-6)
			expect(SwingSequencer.ChainDelayRemaining(attacker, artAt + 0.5 + CHAIN_DELAY)).to.equal(0)
		end)

		it("does not make a string where none was live", function()
			local attacker = makeAttacker("WeaveNoString")
			SwingSequencer.Weave(attacker, "art:alone", 0.5, T)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", T + 0.6)).to.equal(0)
		end)

		it("still reaches the launcher after B1, B2, B3 and an Art", function()
			local minStage = AirComboConstants.Launcher.MinStringStage
			local attacker = makeAttacker("WeaveLaunch")
			throwBasic(attacker, minStage, 1)
			local artAt = T + minStage * 0.2
			SwingSequencer.Weave(attacker, "art:into-launch", 0.6, artAt)
			local at = artAt + 0.6 + CHAIN_DELAY
			local resolution = SwingSequencer.Resolve(attacker, "Basic", FULL_COMBO, at, { ModifierUp = true })
			expect((resolution :: any).IsLauncher).to.equal(true)
		end)
	end)

	describe("SwingSequencer.RestoreParried -- a parried swing keeps the chain", function()
		local STAGGER = 1.5

		it("hands the parried stage back: B1, B2, B3 parried, then M1 is B3 again", function()
			local attacker = makeAttacker("ParriedB3")
			local b3 = throwBasic(attacker, 3, 1)
			local resumeAt = T + 0.5 + STAGGER
			expect(SwingSequencer.RestoreParried(attacker, b3.MoveId, resumeAt)).to.equal(true)
			local nextPress = SwingSequencer.Resolve(attacker, "Basic", 1, resumeAt)
			expect((nextPress :: any).StageIndex).to.equal(3)
		end)

		it("holds the string through the stagger, with the full grace after it", function()
			local attacker = makeAttacker("ParriedHold")
			local b2 = throwBasic(attacker, 2, 1)
			local resumeAt = T + 0.3 + STAGGER
			SwingSequencer.RestoreParried(attacker, b2.MoveId, resumeAt)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", resumeAt + RESET - 0.01)).to.equal(1)
			expect(SwingSequencer.GetStageIndex(attacker, "Basic", resumeAt + RESET + 0.01)).to.equal(0)
		end)

		it("drops the end-of-string lockout a parried B3 had started", function()
			local attacker = makeAttacker("ParriedLockout")
			local b3 = throwBasic(attacker, 3, 1)
			local resumeAt = T + 0.5 + STAGGER
			SwingSequencer.RestoreParried(attacker, b3.MoveId, resumeAt)
			expect(SwingSequencer.ChainDelayRemaining(attacker, resumeAt)).to.equal(0)
		end)

		it("leaves a parried launcher's string at B3, so Space + M1 launches again", function()
			local minStage = AirComboConstants.Launcher.MinStringStage
			local attacker = makeAttacker("ParriedLauncher")
			throwBasic(attacker, minStage, 1)
			local at = T + minStage * 0.2
			local launcher = SwingSequencer.Resolve(attacker, "Basic", FULL_COMBO, at, { ModifierUp = true })
			SwingSequencer.Advance(attacker, "Basic", launcher :: any, NO_COMMITMENT, at)
			local resumeAt = at + STAGGER
			expect(SwingSequencer.RestoreParried(attacker, (launcher :: any).MoveId, resumeAt)).to.equal(true)
			local again = SwingSequencer.Resolve(attacker, "Basic", FULL_COMBO, resumeAt, { ModifierUp = true })
			expect((again :: any).IsLauncher).to.equal(true)
		end)

		it("restores a fresh string's parried B1 to no string at all", function()
			local attacker = makeAttacker("ParriedB1")
			local b1 = throwBasic(attacker, 1, 1)
			SwingSequencer.RestoreParried(attacker, b1.MoveId, T + STAGGER)
			local nextPress = SwingSequencer.Resolve(attacker, "Basic", 1, T + STAGGER)
			expect((nextPress :: any).StageIndex).to.equal(1)
		end)

		it("ignores a parry of an older swing, and restores at most once", function()
			local attacker = makeAttacker("ParriedStale")
			local b1 = throwBasic(attacker, 1, 1)
			local b2 = SwingSequencer.Resolve(attacker, "Basic", 1, T + 0.2)
			SwingSequencer.Advance(attacker, "Basic", b2 :: any, NO_COMMITMENT, T + 0.2)
			expect(SwingSequencer.RestoreParried(attacker, b1.MoveId, T + STAGGER)).to.equal(false)
			local _, stage = SwingSequencer.GetString(attacker, T + 0.3)
			expect(stage).to.equal(2)

			expect(SwingSequencer.RestoreParried(attacker, (b2 :: any).MoveId, T + STAGGER)).to.equal(true)
			expect(SwingSequencer.RestoreParried(attacker, (b2 :: any).MoveId, T + STAGGER)).to.equal(false)
		end)

		it("restores nothing for a parried air hit -- that parry ends the combo", function()
			local attacker = makeAttacker("ParriedAir")
			local beat = SwingSequencer.Resolve(attacker, "Basic", 1, T, { AirRole = { Role = "Air", Beat = 1 } })
			SwingSequencer.Advance(attacker, "Basic", beat :: any, NO_COMMITMENT, T)
			expect(SwingSequencer.RestoreParried(attacker, (beat :: any).MoveId, T + STAGGER)).to.equal(false)
		end)

		it("does not restore across a feint", function()
			local attacker = makeAttacker("ParriedAfterFeint")
			local b2 = throwBasic(attacker, 2, 1)
			SwingSequencer.CancelString(attacker, T + 0.5, T + 0.3)
			expect(SwingSequencer.RestoreParried(attacker, b2.MoveId, T + STAGGER)).to.equal(false)
		end)

		it("hands back the string around a parried Art unchanged", function()
			local attacker = makeAttacker("ParriedArt")
			throwBasic(attacker, 2, 1)
			SwingSequencer.Weave(attacker, "art:parried", 0.6, T + 0.3)
			local resumeAt = T + 0.5 + STAGGER
			expect(SwingSequencer.RestoreParried(attacker, "art:parried", resumeAt)).to.equal(true)
			local nextPress = SwingSequencer.Resolve(attacker, "Basic", 1, resumeAt)
			expect((nextPress :: any).StageIndex).to.equal(3)
		end)
	end)
end
