--!strict
-- Covers Server/Combat/AirCombo/AirComboMachine.lua -- the air combo's rules as pure functions on a synthetic
-- clock (docs/design/air-combat-and-evade.md, B1-B3). No rig, no services: every deadline is asserted exactly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local AirComboMachine = require(ServerScriptService.Server.Combat.AirCombo.AirComboMachine)

local TIMING = AirComboConstants.Timing
local HOVER = AirComboConstants.Hover
local DAMAGE = AirComboConstants.Damage
local T = 500
-- An air beat's authored windup and active window (CombatConstants.Weapons.Baseline.Stages.Air).
local W = 0.22
local ACTIVE = 0.18

return function()
	describe("AirComboMachine -- the shared deadline", function()
		it("gives the first beat its own longer budget from the launch", function()
			local combo = AirComboMachine.Launch(T)
			expect(AirComboMachine.HoldUntil(combo)).to.equal(T + TIMING.FirstContinueSeconds)
			expect(AirComboMachine.Tick(combo, T + TIMING.FirstContinueSeconds - 0.01)).to.equal(nil)
			expect(AirComboMachine.Tick(combo, T + TIMING.FirstContinueSeconds + 0.01)).to.equal("Dropped")
		end)

		it("moves on from each landed air hit's own contact", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteAirHit(combo, T + 0.5)
			expect(combo.AirHitsLanded).to.equal(1)
			expect(AirComboMachine.HoldUntil(combo)).to.equal(T + 0.5 + TIMING.ContinueSeconds)
		end)

		it("rises, then holds", function()
			local combo = AirComboMachine.Launch(T)
			expect(combo.Phase).to.equal("Rising")
			AirComboMachine.Tick(combo, T + HOVER.RiseSeconds + 0.01)
			expect(combo.Phase).to.equal("Held")
		end)

		it("times out at the hard cap whatever else happens", function()
			local combo = AirComboMachine.Launch(T)
			-- Keep landing hits well inside every deadline; the cap still ends it.
			local at = T
			while at < T + TIMING.MaxComboSeconds - 0.3 do
				at += 0.4
				AirComboMachine.NoteAirHit(combo, at)
			end
			expect(AirComboMachine.Tick(combo, T + TIMING.MaxComboSeconds)).to.equal("Timeout")
		end)
	end)

	describe("AirComboMachine -- in-time swings are honoured", function()
		it("extends the hold through an on-beat swing's active window", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteAirHit(combo, T + 0.5)
			local continueBy = T + 0.5 + TIMING.ContinueSeconds
			-- Pressed just inside the last moment whose hit still lands by ContinueBy.
			local acceptedAt = continueBy - W - 0.01
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Air", Beat = 2 }, acceptedAt, 0, W, ACTIVE)
			expect(AirComboMachine.HoldUntil(combo)).to.equal(acceptedAt + W + ACTIVE)
			expect(AirComboMachine.Tick(combo, continueBy + 0.05)).to.equal(nil)
		end)

		it("judges a late-arriving press at its rewound start, so ping cannot drop it", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteAirHit(combo, T + 0.5)
			local continueBy = T + 0.5 + TIMING.ContinueSeconds
			-- On the attacker's screen the press was exactly in time; it reached the server 0.1s later.
			local rewind = 0.1
			local acceptedAt = continueBy - W + rewind - 0.01
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Air", Beat = 2 }, acceptedAt, rewind, W, ACTIVE)
			expect(AirComboMachine.HoldUntil(combo) > continueBy).to.equal(true)
		end)

		it("does not honour a press that was late on the attacker's own screen", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteAirHit(combo, T + 0.5)
			local continueBy = T + 0.5 + TIMING.ContinueSeconds
			local acceptedAt = continueBy - W + 0.05
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Air", Beat = 2 }, acceptedAt, 0, W, ACTIVE)
			expect(AirComboMachine.HoldUntil(combo)).to.equal(continueBy)
			expect(AirComboMachine.Tick(combo, continueBy + 0.01)).to.equal("Dropped")
		end)

		it("caps the rewind it will honour", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteAirHit(combo, T + 0.5)
			local continueBy = T + 0.5 + TIMING.ContinueSeconds
			-- Claims a full second of ping; only SwingRewindMaxSeconds of it counts.
			local acceptedAt = continueBy - W + TIMING.SwingRewindMaxSeconds + 0.05
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Air", Beat = 2 }, acceptedAt, 1, W, ACTIVE)
			expect(AirComboMachine.HoldUntil(combo)).to.equal(continueBy)
		end)

		it("never extends past the hard cap", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Air", Beat = 1 }, T + 0.2, 0, 10, 10)
			expect(AirComboMachine.HoldUntil(combo)).to.equal(T + TIMING.MaxComboSeconds)
		end)
	end)

	describe("AirComboMachine -- the input grammar", function()
		it("waits out the rise before the first press", function()
			local combo = AirComboMachine.Launch(T)
			local early, reason = AirComboMachine.CanPress(combo, T + TIMING.FirstPressSeconds - 0.01)
			expect(early).to.equal(false)
			expect(reason).to.equal("Rising")
			expect((AirComboMachine.CanPress(combo, T + TIMING.FirstPressSeconds))).to.equal(true)
		end)

		it("runs Basic through the fixed string, then auto-throws the Slam", function()
			local combo = AirComboMachine.Launch(T)
			for beat = 1, AirComboConstants.StringLength do
				local role = AirComboMachine.ResolvePress(combo, "Basic", false)
				expect(role.Role).to.equal("Air")
				expect(role.Beat).to.equal(beat)
				AirComboMachine.NoteAirHit(combo, T + beat * 0.4)
			end
			local last = AirComboMachine.ResolvePress(combo, "Basic", false)
			expect(last.Role).to.equal("Finisher")
			expect(last.Finisher).to.equal("Slam")
		end)

		it("re-throws the same beat after a whiff: beats count LANDED hits", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Air", Beat = 1 }, T + 0.3, 0, W, ACTIVE)
			-- No hit landed.
			expect(AirComboMachine.ResolvePress(combo, "Basic", false).Beat).to.equal(1)
		end)

		it("chooses the finisher from air hit one onward: Heavy is Slam, Space + Heavy is Spike", function()
			local combo = AirComboMachine.Launch(T)
			expect(AirComboMachine.ResolvePress(combo, "Heavy", false).Finisher).to.equal("Slam")
			expect(AirComboMachine.ResolvePress(combo, "Heavy", true).Finisher).to.equal("Spike")
		end)

		it("refuses every press once a finisher has been thrown", function()
			local combo = AirComboMachine.Launch(T)
			AirComboMachine.NoteSwingAccepted(combo, { Role = "Finisher", Finisher = "Slam" }, T + 0.3, 0, 0.4, 0.2)
			expect(combo.Phase).to.equal("Finishing")
			local allowed, reason = AirComboMachine.CanPress(combo, T + 0.35)
			expect(allowed).to.equal(false)
			expect(reason).to.equal("FinisherThrown")
		end)
	end)

	describe("AirComboMachine -- scaling", function()
		it("scales each air hit down by the hits already landed, to a floor", function()
			expect(AirComboMachine.AirHitDamage(4, 0)).to.equal(4)
			expect(math.abs(AirComboMachine.AirHitDamage(4, 1) - 4 * (1 - DAMAGE.AirHitFalloffPerHit)) < 1e-9).to.equal(
				true
			)
			expect(AirComboMachine.AirHitDamage(4, 100)).to.equal(4 * DAMAGE.AirHitFloor)
		end)

		it("grows a finisher with the string behind it", function()
			local slam = DAMAGE.Finishers.Slam.PerHitBonus
			expect(AirComboMachine.FinisherDamage(8, "Slam", 0)).to.equal(8)
			expect(AirComboMachine.FinisherDamage(8, "Slam", 3)).to.equal(8 + 3 * slam)
		end)

		it("keeps a full route strong but never a kill from full health", function()
			-- docs B3's route table, off the authored bases: three air hits then the Slam, at 100 max health.
			local total = 0
			for k = 0, 2 do
				total += AirComboMachine.AirHitDamage(4, k)
			end
			total += AirComboMachine.FinisherDamage(8, "Slam", 3)
			expect(total > 20).to.equal(true)
			expect(total < 100).to.equal(true)
		end)

		it("leaves anything without an air role untouched", function()
			local combo = AirComboMachine.Launch(T)
			expect(AirComboMachine.ScaleDamage(combo, nil, 12)).to.equal(12)
		end)
	end)

	describe("AirComboMachine -- endings", function()
		it("ends once: the first reason wins", function()
			local combo = AirComboMachine.Launch(T)
			expect(AirComboMachine.End(combo, "Parried", T + 1)).to.equal(true)
			expect(AirComboMachine.End(combo, "Timeout", T + 1)).to.equal(false)
			expect(combo.Ended).to.equal("Parried")
			expect(AirComboMachine.Tick(combo, T + 100)).to.equal(nil)
		end)

		it("publishes one end phase per reason", function()
			expect(AirComboMachine.EndPhaseFor("Finished", "Slam")).to.equal("Slammed")
			expect(AirComboMachine.EndPhaseFor("Finished", "Spike")).to.equal("Spiked")
			expect(AirComboMachine.EndPhaseFor("Parried")).to.equal("Parried")
			for _, reason in { "Dropped", "Interrupted", "SpacingFail", "Timeout", "Aborted" } do
				expect(AirComboMachine.EndPhaseFor(reason :: any)).to.equal("Dropped")
			end
		end)

		it("makes the victim launch-immune after any ending", function()
			local immuneUntil = AirComboMachine.ImmuneUntil(T)
			expect(AirComboMachine.CanLaunch(immuneUntil, T + TIMING.LaunchImmunitySeconds - 0.01)).to.equal(false)
			expect(AirComboMachine.CanLaunch(immuneUntil, T + TIMING.LaunchImmunitySeconds)).to.equal(true)
			expect(AirComboMachine.CanLaunch(nil, T)).to.equal(true)
		end)
	end)
end
