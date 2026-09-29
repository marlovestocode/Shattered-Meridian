--!strict
-- Covers Server/Combat/Defense/DefenseStateMachine.lua -- one combatant's guard lifecycle.
--
-- Synthetic clock, synthetic window, no rig. The machine takes time as a parameter on every entry
-- point precisely so this is possible: nothing here sleeps, nothing here needs a character, and
-- frame-data behaviour that would take a real second to observe is asserted in microseconds. A case
-- here that needed a body would mean the machine had learned about bodies, which it must not.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseStateMachine = require(ServerScriptService.Server.Combat.Defense.DefenseStateMachine)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)

type ParryWindow = DefenseTypes.ParryWindow

-- Opens 0.05s after the press, closes 0.20s later, and a whiff costs 0.35s past the close.
local WINDOW: ParryWindow = { Open = 0.05, Close = 0.25, RecoveryEnd = 0.6, Source = "Registered" }
local T = 100

return function()
	describe("DefenseStateMachine -- construction", function()
		it("starts Neutral with the guard down", function()
			local machine = DefenseStateMachine.New()
			expect(machine:GetState()).to.equal("Neutral")
			expect(machine:IsBlockHeld()).to.equal(false)
			expect(machine:CanAttack()).to.equal(true)
		end)
	end)

	describe("DefenseStateMachine -- the armed walk", function()
		it("goes Raising -> ParryWindow -> Blocking while held", function()
			local machine = DefenseStateMachine.New()
			expect(machine:Press(T, WINDOW, 0)).to.equal(true)
			expect(machine:GetState()).to.equal("Raising")

			machine:Update(T + 0.05)
			expect(machine:GetState()).to.equal("ParryWindow")

			machine:Update(T + 0.25)
			expect(machine:GetState()).to.equal("Blocking")
		end)

		it("reaches the window within the arming call when Open is authored at zero", function()
			local machine = DefenseStateMachine.New()
			local instant: ParryWindow = { Open = 0, Close = 0.2, RecoveryEnd = 0.5, Source = "Registered" }
			machine:Press(T, instant, 0)
			-- A zero-length raise costing a frame is real, felt input latency in exactly the parries
			-- tuned to have none -- the same reasoning behind AttackStateMachine.Begin's own immediate
			-- Update.
			expect(machine:GetState()).to.equal("ParryWindow")
			expect(machine:IsParryLiveAt(T)).to.equal(true)
		end)

		it("lands phase boundaries on their DUE times, not the time they were noticed", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			-- One very late Update, chaining both boundaries at once.
			machine:Update(T + 0.9)
			expect(machine:GetState()).to.equal("Blocking")
			-- Blocking began at the close (T + 0.25), not at T + 0.9. Carrying the overshoot forward
			-- would make a window's length depend on server frame timing.
			expect(machine:GetStateElapsed(T + 0.9)).to.be.near(0.65, 1e-6)
		end)
	end)

	describe("DefenseStateMachine -- the whiff branch", function()
		it("takes ParryRecovery when the window closes released and uncaught", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Release(T + 0.1)
			machine:Update(T + 0.25)
			expect(machine:GetState()).to.equal("ParryRecovery")
		end)

		it("does NOT cancel the window when the input is released inside it", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Update(T + 0.05)
			machine:Release(T + 0.1)
			-- A parry is a committed read. Cancelling on release would hand out a free arm-and-disarm:
			-- tap, keep a live window, stay free to act inside it.
			expect(machine:GetState()).to.equal("ParryWindow")
			expect(machine:IsParryLiveAt(T + 0.2)).to.equal(true)
		end)

		it("charges the lockout even when the player presses straight back into a block", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Release(T + 0.1)
			machine:Update(T + 0.25)
			-- Leaves ParryRecovery immediately, never paying it as a STATE...
			machine:Press(T + 0.26, WINDOW, 0)
			expect(machine:GetState()).to.equal("Blocking")
			-- ...but the lockout is a timestamp, so it is paid anyway. Recovery ends at 0.25 + 0.35.
			local canArm, reason = machine:CanArmParryAt(T + 0.5)
			expect(canArm).to.equal(false)
			expect(reason).to.equal("Locked")
			expect(machine:CanArmParryAt(T + 0.65)).to.equal(true)
		end)

		it("does not charge the lockout for a window that was consumed", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Update(T + 0.05)
			machine:ConsumeParry(T + 0.1)
			machine:Update(T + 0.25)
			-- A parry that landed is a success, and must not also pay the whiff's price.
			expect(machine:CanArmParryAt(T + 0.3)).to.equal(true)
		end)
	end)

	describe("DefenseStateMachine -- the anti-turtle rule", function()
		it("arms the first press from a standing start", function()
			local machine = DefenseStateMachine.New()
			expect(machine:Press(T, WINDOW, 0)).to.equal(true)
		end)

		it("refuses to arm a re-press that follows a block too closely, but still blocks", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Update(T + 0.25)
			machine:Release(T + 1)

			-- Hold-and-retap is the dominant strategy this prices: continuous mitigation with a free
			-- parry on top.
			local armed = machine:Press(T + 1.1, WINDOW, 0)
			expect(armed).to.equal(false)
			-- Fail-soft: the guard still comes up. The player loses the parry, not the block.
			expect(machine:GetState()).to.equal("Blocking")
		end)

		it("arms again once the guard has been down long enough", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Update(T + 0.25)
			machine:Release(T + 1)
			-- A hair past the threshold rather than exactly on it: (T + 1 + 0.3) - (T + 1) is
			-- 0.2999999999999972 in double precision, so an exact-boundary press tests floating-point
			-- luck rather than the rule.
			local justPast = T + 1 + DefenseConstants.Parry.MinUnguardedSeconds + 1e-3
			expect(machine:Press(justPast, WINDOW, 0)).to.equal(true)
		end)

		it("does not re-arm a second press while already guarding", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			-- Minting a second window without releasing is the other half of the same exploit.
			expect(machine:Press(T + 0.01, WINDOW, 0)).to.equal(false)
			expect(machine:GetState()).to.equal("Raising")
		end)
	end)

	describe("DefenseStateMachine -- fail-closed", function()
		it("blocks without arming when the id has no window", function()
			local machine = DefenseStateMachine.New()
			expect(machine:Press(T, nil, 0)).to.equal(false)
			expect(machine:GetState()).to.equal("Blocking")
			expect(machine:IsParryLiveAt(T)).to.equal(false)
		end)
	end)

	describe("DefenseStateMachine -- ping compensation", function()
		it("extends parry liveness past the close without delaying the block", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0.05)
			machine:Update(T + 0.25)
			-- The guard comes up exactly on the authored close -- a high-ping player is not charged
			-- for the latency this refunds.
			expect(machine:GetState()).to.equal("Blocking")
			-- ...but a contact inside the refund still counts as a parry.
			expect(machine:IsParryLiveAt(T + 0.28)).to.equal(true)
			expect(machine:IsParryLiveAt(T + 0.31)).to.equal(false)
		end)

		it("gives a zero-latency combatant nothing", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			expect(machine:IsParryLiveAt(T + 0.26)).to.equal(false)
		end)
	end)

	describe("DefenseStateMachine -- the historical query", function()
		it("answers what state it was in at a time it has already left", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Update(T + 0.9)
			expect(machine:GetState()).to.equal("Blocking")

			-- This is the whole reason the trail exists: one engine frame can deliver contacts tens of
			-- milliseconds apart, so classification has to ask about the past.
			expect(machine:StateAt(T + 0.01)).to.equal("Raising")
			expect(machine:StateAt(T + 0.1)).to.equal("ParryWindow")
			expect(machine:StateAt(T + 0.5)).to.equal("Blocking")
		end)

		it("tracks the guard separately from the state, for a staggered block", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			expect(machine:BlockHeldAt(T)).to.equal(false)
			-- No window, so this is a plain block: with parry trading on, a windowed press would arm a
			-- parry out of the stagger instead (see "parry trading" below).
			machine:Press(T + 0.1, nil, 0)
			-- Staggered is still the state, but the guard is genuinely up -- "Staggered" alone does not
			-- say whether a contact was covered.
			expect(machine:StateAt(T + 0.2)).to.equal("Staggered")
			expect(machine:BlockHeldAt(T + 0.2)).to.equal(true)
			expect(machine:BlockHeldAt(T + 0.05)).to.equal(false)
		end)
	end)

	describe("DefenseStateMachine -- the stagger punish", function()
		it("cannot attack, CAN parry back, CAN block", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			expect(machine:GetState()).to.equal("Staggered")

			local canAttack, attackReason = machine:CanAttack()
			expect(canAttack).to.equal(false)
			expect(attackReason).to.equal("Staggered")

			-- Parry trading (DefenseConstants.Rally): the stagger no longer forbids arming a parry.
			expect(DefenseConstants.Rally.ParryFromStagger).to.equal(true)
			expect(machine:Press(T + 0.1, WINDOW, 0)).to.equal(true)
			expect(machine:IsBlockHeld()).to.equal(true)
			expect(machine:IsParryLiveAt(T + 0.2)).to.equal(true)
		end)

		it("lasts exactly the configured duration and then hands back to the held guard", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			machine:Press(T + 0.1, WINDOW, 0)

			machine:Update(T + DefenseConstants.Stagger.DurationSeconds - 0.01)
			expect(machine:GetState()).to.equal("Staggered")

			machine:Update(T + DefenseConstants.Stagger.DurationSeconds)
			expect(machine:GetState()).to.equal("Blocking")
		end)

		it("leaves the parry armable for the whole punish", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			expect(machine:CanArmParryAt(T + DefenseConstants.Stagger.DurationSeconds - 0.01)).to.equal(true)
		end)
	end)

	describe("DefenseStateMachine -- parry trading", function()
		it("drops a whiffed parry straight back into the stagger it interrupted", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			machine:Press(T + 0.1, WINDOW, 0)
			machine:Release(T + 0.12)
			-- The window closes at T + 0.35 with nothing caught.
			machine:Update(T + 0.4)
			expect(machine:GetState()).to.equal("Staggered")
			expect(machine:CanAttack()).to.equal(false)
			-- And the whiff still paid its lockout: recovery ends 0.35s past the close.
			local canArm, reason = machine:CanArmParryAt(T + 0.5)
			expect(canArm).to.equal(false)
			expect(reason).to.equal("Locked")
			-- The punish runs to its own end, not the window's.
			machine:Update(T + DefenseConstants.Stagger.DurationSeconds)
			expect(machine:GetState()).to.equal("Neutral")
		end)

		it("ends the stagger the moment a parry out of it lands", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			machine:Press(T + 0.1, WINDOW, 0)
			machine:Release(T + 0.12)
			machine:Update(T + 0.15)
			machine:ConsumeParry(T + 0.2)
			machine:Update(T + 0.2)
			expect(machine:GetState()).to.equal("Neutral")
			expect(machine:CanAttack()).to.equal(true)
		end)

		it("keeps the stagger's gates on while the parry out of it is still pending", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			machine:Press(T + 0.1, WINDOW, 0)
			machine:Update(T + 0.2)
			expect(machine:GetState()).to.equal("ParryWindow")
			expect(machine:IsStaggerHeld()).to.equal(true)
			local canAttack, attackReason = machine:CanAttack()
			expect(canAttack).to.equal(false)
			expect(attackReason).to.equal("Staggered")
			local ok, evadeReason = machine:BeginEvade(T + 0.2, 0)
			expect(ok).to.equal(false)
			expect(evadeReason).to.equal("Staggered")
		end)

		it("charges the anti-turtle rule when a staggered guard is released", function()
			local machine = DefenseStateMachine.New()
			machine:Stagger(T)
			-- A plain block during the stagger (the machine only arms when the lockout allows, so force
			-- the no-window path), then a release and an instant re-press.
			machine:Press(T + 0.1, nil, 0)
			machine:Release(T + 0.5)
			expect(machine:Press(T + 0.55, WINDOW, 0)).to.equal(false)
		end)

		it("shortens the window by the rally scale, keeping its opening moment", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0, 0.5)
			-- Opens at T + 0.05 as authored; lasts 0.1s instead of 0.2s.
			expect(machine:IsParryLiveAt(T + 0.05)).to.equal(true)
			expect(machine:IsParryLiveAt(T + 0.14)).to.equal(true)
			expect(machine:IsParryLiveAt(T + 0.16)).to.equal(false)
			-- The perfect band shrinks with it.
			local perfect = DefenseConstants.PerfectParry.WindowSeconds
			expect(machine:IsPerfectParryAt(T + 0.05 + perfect * 0.5 - 0.001)).to.equal(true)
			expect(machine:IsPerfectParryAt(T + 0.05 + perfect * 0.5 + 0.001)).to.equal(false)
		end)

		it("ignores a rally scale outside (0, 1)", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0, 1.5)
			expect(machine:IsParryLiveAt(T + 0.24)).to.equal(true)
		end)
	end)

	describe("DefenseStateMachine -- the guard break", function()
		it("forbids blocking for its duration, unlike a stagger", function()
			local machine = DefenseStateMachine.New()
			machine:BreakGuard(T)
			expect(machine:GetState()).to.equal("GuardBroken")

			-- A break is the opening. A held input buys nothing at all here, which is the difference
			-- between it and a stagger.
			expect(machine:Press(T + 0.1, WINDOW, 0)).to.equal(false)
			expect(machine:GetState()).to.equal("GuardBroken")
			expect(machine:CanAttack()).to.equal(false)
		end)

		it("hands back to the remembered press when it ends", function()
			local machine = DefenseStateMachine.New()
			machine:BreakGuard(T)
			machine:Press(T + 0.1, WINDOW, 0)
			machine:Update(T + DefenseConstants.GuardBrokenSeconds)
			expect(machine:GetState()).to.equal("Blocking")
		end)
	end)

	describe("DefenseStateMachine -- the roll's evade window", function()
		local EVADE = DefenseConstants.Evade

		it("is vulnerable through any startup, evading through the active phase, and vulnerable after", function()
			local machine = DefenseStateMachine.New()
			expect(machine:BeginEvade(T, 0)).to.equal(true)
			expect(machine:IsEvadingAt(T - 0.01)).to.equal(false)
			if EVADE.StartupSeconds > 0 then
				expect(machine:IsEvadingAt(T + EVADE.StartupSeconds * 0.5)).to.equal(false)
			end
			expect(machine:IsEvadingAt(T + EVADE.StartupSeconds)).to.equal(true)
			expect(machine:IsEvadingAt(T + EVADE.StartupSeconds + EVADE.ActiveSeconds)).to.equal(true)
			expect(machine:IsEvadingAt(T + EVADE.StartupSeconds + EVADE.ActiveSeconds + 0.01)).to.equal(false)
		end)

		it("is never live on a machine that has not evaded", function()
			local machine = DefenseStateMachine.New()
			expect(machine:IsEvadingAt(0)).to.equal(false)
			expect(machine:IsEvadingAt(T)).to.equal(false)
		end)

		it("refunds latency on the END only, capped", function()
			local machine = DefenseStateMachine.New()
			machine:BeginEvade(T, 10) -- an absurd ping
			local activeEnd = T + EVADE.StartupSeconds + EVADE.ActiveSeconds
			-- The start is not pulled earlier by any ping.
			expect(machine:IsEvadingAt(T - 0.01)).to.equal(false)
			if EVADE.StartupSeconds > 0 then
				expect(machine:IsEvadingAt(T + EVADE.StartupSeconds * 0.5)).to.equal(false)
			end
			expect(machine:IsEvadingAt(activeEnd + EVADE.PingCompensationMaxSeconds)).to.equal(true)
			expect(machine:IsEvadingAt(activeEnd + EVADE.PingCompensationMaxSeconds + 0.01)).to.equal(false)
		end)

		it("refuses a second evade inside the cooldown", function()
			local machine = DefenseStateMachine.New()
			machine:BeginEvade(T, 0)
			local ok, reason = machine:BeginEvade(T + EVADE.CooldownSeconds * 0.5, 0)
			expect(ok).to.equal(false)
			expect(reason).to.equal("EvadeCooldown")
			expect((machine:BeginEvade(T + EVADE.CooldownSeconds, 0))).to.equal(true)
		end)

		it("opens on the press and outlasts the glide it covers", function()
			local evadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)
			expect(EVADE.StartupSeconds).to.equal(0)
			expect(EVADE.StartupSeconds + EVADE.ActiveSeconds > evadeConstants.DurationSeconds).to.equal(true)
		end)

		it("derives its cooldown from the evade's, a little under it", function()
			local evadeCooldown = require(ReplicatedStorage.Shared.Combat.EvadeConstants).CooldownSeconds
			expect(EVADE.CooldownSeconds < evadeCooldown).to.equal(true)
			expect(EVADE.CooldownSeconds > 0).to.equal(true)
		end)

		it("refuses while staggered or guard-broken -- a roll must not end a punish", function()
			local staggered = DefenseStateMachine.New()
			staggered:Stagger(T)
			local ok, reason = staggered:BeginEvade(T + 0.1, 0)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Staggered")
			expect(staggered:IsEvadingAt(T + 0.2)).to.equal(false)

			local broken = DefenseStateMachine.New()
			broken:BreakGuard(T)
			ok, reason = broken:BeginEvade(T + 0.1, 0)
			expect(ok).to.equal(false)
			expect(reason).to.equal("GuardBroken")
		end)

		it("drops a raised guard rather than refusing", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Update(T + WINDOW.Close)
			expect(machine:GetState()).to.equal("Blocking")
			expect(machine:BeginEvade(T + 1, 0)).to.equal(true)
			expect(machine:GetState()).to.equal("Neutral")
			expect(machine:IsBlockHeld()).to.equal(false)
		end)

		it("is cleared by Reset", function()
			local machine = DefenseStateMachine.New()
			machine:BeginEvade(T, 0)
			machine:Reset(T + 0.01)
			expect(machine:IsEvadingAt(T + EVADE.StartupSeconds + 0.01)).to.equal(false)
			-- And the cooldown with it: a fresh life rolls immediately.
			expect((machine:BeginEvade(T + 0.02, 0))).to.equal(true)
		end)
	end)

	describe("DefenseStateMachine.Reset", function()
		it("drops everything back to a fresh guard", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, WINDOW, 0)
			machine:Stagger(T + 0.1)
			machine:Reset(T + 1)
			expect(machine:GetState()).to.equal("Neutral")
			expect(machine:IsBlockHeld()).to.equal(false)
			expect(machine:CanAttack()).to.equal(true)
			expect(machine:CanArmParryAt(T + 1)).to.equal(true)
		end)
	end)

	describe("DefenseStateMachine -- the air parry's rewind", function()
		-- RewoundParryCovers answers "would a press made at pressAt have caught a contact at contactAt",
		-- judged exactly as a live press is -- but at the rewound time, with no end refund.
		local OPEN = WINDOW.Open

		it("covers a contact inside the window a press at the rewound time would have armed", function()
			local machine = DefenseStateMachine.New()
			local covers = machine:RewoundParryCovers(T, T + OPEN + 0.1, WINDOW, 1)
			expect(covers).to.equal(true)
		end)

		it("misses a contact outside that window, early or late, with no end refund", function()
			local machine = DefenseStateMachine.New()
			expect((machine:RewoundParryCovers(T, T + OPEN - 0.01, WINDOW, 1))).to.equal(false)
			expect((machine:RewoundParryCovers(T, T + WINDOW.Close + 0.01, WINDOW, 1))).to.equal(false)
		end)

		it("judges the perfect band from the rewound opening", function()
			local machine = DefenseStateMachine.New()
			local perfectBand = DefenseConstants.PerfectParry.WindowSeconds
			local _, perfect = machine:RewoundParryCovers(T, T + OPEN + perfectBand * 0.5, WINDOW, 1)
			expect(perfect).to.equal(true)
			local _, late = machine:RewoundParryCovers(T, T + OPEN + perfectBand + 0.02, WINDOW, 1)
			expect(late).to.equal(false)
		end)

		it("applies MinUnguardedSeconds at the rewound time", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, nil, 0)
			machine:Release(T + 0.1)
			local pressAt = T + 0.1 + DefenseConstants.Parry.MinUnguardedSeconds * 0.5
			expect((machine:RewoundParryCovers(pressAt, pressAt + OPEN + 0.05, WINDOW, 1))).to.equal(false)
		end)

		it("mints nothing for a guard already held at the rewound time", function()
			local machine = DefenseStateMachine.New()
			machine:Press(T, nil, 0)
			expect((machine:RewoundParryCovers(T + 0.5, T + 0.5 + OPEN + 0.05, WINDOW, 1))).to.equal(false)
		end)

		it("shortens with the rally scale, keeping its opening", function()
			local machine = DefenseStateMachine.New()
			local length = WINDOW.Close - OPEN
			expect((machine:RewoundParryCovers(T, T + OPEN + length * 0.4, WINDOW, 0.5))).to.equal(true)
			expect((machine:RewoundParryCovers(T, T + OPEN + length * 0.6, WINDOW, 0.5))).to.equal(false)
		end)

		it("refuses without a window", function()
			local machine = DefenseStateMachine.New()
			expect((machine:RewoundParryCovers(T, T + OPEN + 0.05, nil, 1))).to.equal(false)
		end)
	end)
end
