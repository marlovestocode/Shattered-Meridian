--!strict
-- Covers Server/Combat/Defense/DefenseSystem.lua -- the two-pass resolution, against the real engine.
--
-- Needs a Workspace, like HitboxEngine.spec and for the same reason: the point of this module is that
-- it classifies contacts a live engine found on live bodies, and a synthetic stand-in for that would
-- test the wiring rather than the behaviour. The dummies are built with Instance.new exactly as that
-- spec builds its own -- the deleted DummyCombat/TrainingBotSystem are neither needed nor available,
-- and the engine accepting a bare Model/root/Humanoid is itself part of the contract.
--
-- Time is driven through Step(deltaTime, now) on BOTH modules, in the same order Main.server.lua
-- guarantees at runtime (engine first, defence second). Nothing here sleeps. Init() is deliberately
-- never called: it would connect a real Heartbeat that raced these synthetic Steps, which is exactly
-- why Attach() exists separately.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CombatHarness = require(ServerScriptService.Tests.TestHelpers.CombatHarness)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local Rig = require(ServerScriptService.Tests.TestHelpers.Rig)

type DefenseOutcome = DefenseTypes.DefenseOutcome

local FRAME = 1 / 60
local PARRY_ANIMATION = "rbxassetid://spec-parry"
-- Opens on the press so a case does not have to advance time just to arm; closes late enough that a
-- case can choose to sit inside the window or step past it.
local WINDOW_OPEN = 0
local WINDOW_CLOSE = 0.3

-- Anchored, so every positional assertion here is not a race against gravity.
local spawnDummy = CombatHarness.Spawner({ ParryAnimation = PARRY_ANIMATION })

local function makeDefinition(overrides: { [string]: any }?): HitboxTypes.AttackDefinition
	local base: { [string]: any } = {
		DebugName = "SpecSwing",
		Shape = "Box",
		BaseDimensions = { Width = 4, Height = 6, Length = 6 },
		Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 8 },
		-- Four studs in front of the attacker (-Z is forward), so the volume sits ahead of the body.
		Offset = CFrame.new(0, 0, -4),
		AttachmentPart = "Root",
		WindupSeconds = 0,
		ActiveSeconds = 5,
		RecoverySeconds = 0,
		LocksMovement = false,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return (HitboxTypes.SanitizeDefinition(base))
end

local function captureOutcomes(): ({ DefenseOutcome }, () -> ())
	local outcomes: { DefenseOutcome } = {}
	local disconnect = DefenseSystem.OnResolved(function(outcome: DefenseOutcome)
		table.insert(outcomes, outcome)
	end)
	return outcomes, disconnect
end

-- One frame, in the order Main.server.lua guarantees: the engine fills the batch during its
-- substeps, then defence arbitrates and applies it.
local function step(deltaTime: number, now: number): ()
	HitboxEngine.Step(deltaTime, now)
	DefenseSystem.Step(deltaTime, now)
end

return function()
	beforeEach(function()
		DefenseSystem.Attach()
		ParryWindows.Register(PARRY_ANIMATION, WINDOW_OPEN, WINDOW_CLOSE)
	end)

	afterEach(function()
		CombatHarness.Teardown()
	end)

	describe("DefenseSystem -- parrying", function()
		it("cancels the attacker's swing and staggers them", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
			-- The engine's own CancelAttack path ran, so the swing is over and the body released.
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
		end)

		it("restores the defender's guard", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local guard, guardMax = DefenseSystem.GetGuard(defender.Model)
			-- Already full, so the restore is clamped -- the assertion worth making is that a parry
			-- never COSTS guard, which a mis-signed delta would.
			expect(guard).to.equal(guardMax)
		end)

		it("forbids the staggered attacker from attacking again", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			local canAttack, reason = DefenseSystem.CanAttack(attacker.Model)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Staggered")
		end)
	end)

	describe("DefenseSystem -- blocking", function()
		it("raises no guard or parry for a frozen body, and does not hold the press for later", function()
			local base = os.clock()
			local fighter = spawnDummy("Frozen", Vector3.new(0, 5, 0))
			fighter.Humanoid:SetAttribute("Frozen", true)

			expect(DefenseSystem.SetBlocking(fighter.Model, true, base)).to.equal(false)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")

			-- Thawed with the key still "down": nothing was deferred, so nothing arms by itself.
			fighter.Humanoid:SetAttribute("Frozen", false)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")
		end)

		it("drains guard on a blocked hit", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			-- Past the window's close, so the guard is genuinely up rather than still parrying.
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Blocked")
			local guard = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.be.near(DefenseConstants.Guard.Max - DefenseConstants.Guard.DrainPerPowerLevel, 1e-3)
		end)

		it("reports a hit to a blocking defender's back as a Backstab", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			-- Facing AWAY from the attacker -- the block covers nothing behind it.
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, -20))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Backstab")
			-- A backstab beats the block outright, so it costs no guard.
			expect(outcomes[1].GuardDelta).to.equal(0)
		end)

		it("reports an unguarded hit as Clean", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)
	end)

	describe("DefenseSystem -- a second hit behind a landed parry", function()
		it("blocks it when the key is still held, and counts the parry's restore before the drain", function()
			-- Two swings land in ONE batch. The first is parried; the second used to land Clean because
			-- ParryWindow does not mitigate -- while the identical hit a frame later was Blocked, once pass 2
			-- had dropped the defender into Blocking. Whether it got through depended on a frame boundary.
			local base = os.clock()
			local first = spawnDummy("First", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local second = spawnDummy("Second", Vector3.new(1, 5, 0), Vector3.new(1, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.DrainGuard(defender.Model, 50, base)

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(first.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(second.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(2)
			local kinds: { [string]: number } = {}
			for _, outcome in outcomes do
				kinds[outcome.Kind] = (kinds[outcome.Kind] or 0) + 1
			end
			-- One window, one parry -- the other swing is blocked, not parried and not clean.
			expect(kinds.Parried).to.equal(1)
			expect(kinds.Blocked).to.equal(1)
			-- 50 + the parry's restore - one blocked hit. Both contacts are classified before either
			-- applies, so the block must be charged against the restored pool, not the pre-batch one.
			local guard = DefenseSystem.GetGuard(defender.Model)
			local GUARD = DefenseConstants.Guard
			expect(guard).to.be.near(50 + GUARD.ParryRestore - GUARD.DrainPerPowerLevel, 1e-3)
		end)

		it("drains a guard once per blocked hit when two land in the same batch", function()
			local base = os.clock()
			local first = spawnDummy("First", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local second = spawnDummy("Second", Vector3.new(1, 5, 0), Vector3.new(1, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(first.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(second.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)

			local guard = DefenseSystem.GetGuard(defender.Model)
			local GUARD = DefenseConstants.Guard
			expect(guard).to.be.near(GUARD.Max - 2 * GUARD.DrainPerPowerLevel, 1e-3)
		end)
	end)

	describe("DefenseSystem -- the guard break is an opening, not a lock", function()
		local BROKEN = DefenseConstants.GuardBrokenSeconds

		it("is not extended by the posture the punish hits drain", function()
			-- Every clean hit drains posture (DamageSystem -> DrainGuard). On the emptied pool that used to read as
			-- another break, restarting the opening on each hit of the punish.
			local base = os.clock()
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			local _, _, broke = DefenseSystem.DrainGuard(defender.Model, DefenseConstants.Guard.Max, base)
			expect(broke).to.equal(true)

			local _, delta, brokeAgain = DefenseSystem.DrainGuard(defender.Model, 10, base + BROKEN * 0.9)
			expect(delta).to.equal(0)
			expect(brokeAgain).to.equal(false)
			step(FRAME, base + BROKEN + FRAME)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Neutral")
		end)

		it("ends with a whole guard, so the next hit does not break it again", function()
			local base = os.clock()
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.DrainGuard(defender.Model, DefenseConstants.Guard.Max, base)
			step(FRAME, base + BROKEN + FRAME)

			local guard, guardMax = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.equal(guardMax)
			DefenseSystem.DrainGuard(defender.Model, 10, base + BROKEN + 2 * FRAME)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Neutral")
			expect(DefenseSystem.GetGuard(defender.Model)).to.be.near(guardMax - 10, 1e-3)
		end)
	end)

	describe("DefenseSystem -- the lag rewind on the ground", function()
		-- The defender's press is judged at its arrival minus min(round trip, Parry.RewindMaxSeconds), so a
		-- parry or block pressed in time on their own screen is not eaten by the trip to the server. A dummy
		-- has no Player, so the round trip comes from the spec seam.
		local PING = 0.1

		beforeEach(function()
			DefenseSystem.SetPingResolver(function(): number
				return PING
			end)
		end)

		it("holds a Clean hit on a defender with a round trip, then applies it when no press comes", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(#outcomes).to.equal(0)
			step(FRAME, base + FRAME + PING * 0.5)
			expect(#outcomes).to.equal(0)
			step(FRAME, base + FRAME + PING + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("parries a hit that landed while the press was still in flight", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			-- Arrives after the contact, but its rewound time (arrival - PING) is before it.
			DefenseSystem.SetBlocking(defender.Model, true, base + FRAME + PING * 0.5)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)

		it("does not parry twice -- the rewound parry spends the window the press armed", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local other = spawnDummy("Other", Vector3.new(1, 5, 0), Vector3.new(1, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			local pressAt = base + FRAME + PING * 0.5
			DefenseSystem.SetBlocking(defender.Model, true, pressAt)
			HitboxEngine.RequestAttack(other.Id, makeDefinition(), 1, 1)
			step(FRAME, pressAt + FRAME)
			disconnect()

			expect(#outcomes).to.equal(2)
			expect(outcomes[1].Kind).to.equal("Parried")
			-- The key is still down behind the spent window, so the second swing is blocked.
			expect(outcomes[2].Kind).to.equal("Blocked")
		end)

		it("blocks a hit that landed while a plain block press was in flight", function()
			local base = os.clock()
			-- No window anywhere: every press is a plain block.
			ParryWindows.Reset()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			DefenseSystem.SetBlocking(defender.Model, true, base + FRAME + PING * 0.5)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Blocked")
			local guard = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.be.near(DefenseConstants.Guard.Max - DefenseConstants.Guard.DrainPerPowerLevel, 1e-3)
		end)

		it("leaves a hit Clean when the press arrives later than the rewind reaches", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			-- Still inside the hold (the frame that releases it has not run), but rewound only to just
			-- after the contact -- the press really was late.
			DefenseSystem.SetBlocking(defender.Model, true, base + FRAME + PING + 0.5 * FRAME)
			step(FRAME, base + FRAME + PING + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("does not hold a hit on a stunned defender locked out of the parry", function()
			-- A stunned body's guard does nothing, so only a parry could answer the hit -- and a whiffed parry's
			-- lockout means none can. Holding the contact would only delay the next link of the string.
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("HitstunUntil", base + 2)

			-- The mashed parry: pressed, released, and its window closes on nothing.
			DefenseSystem.SetBlocking(defender.Model, true, base)
			DefenseSystem.SetBlocking(defender.Model, false, base + FRAME)
			local afterWhiff = base + WINDOW_CLOSE + 2 * FRAME
			step(FRAME, afterWhiff)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, afterWhiff + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("still holds a hit on a stunned defender who could parry it", function()
			-- The other half: a stunned body with its parry free is exactly who the rewind is for.
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("HitstunUntil", base + 2)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(#outcomes).to.equal(0)
			step(FRAME, base + FRAME + PING + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("caps the rewind at Parry.RewindMaxSeconds however bad the round trip", function()
			DefenseSystem.SetPingResolver(function(): number
				return 1
			end)
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(#outcomes).to.equal(0)
			step(FRAME, base + FRAME + DefenseConstants.Parry.RewindMaxSeconds + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("does not hold a hit from the flank when no press could have turned it", function()
			local base = os.clock()
			-- Off the defender's shoulder, past the block arc but short of the rear hemisphere: no guard covers it,
			-- and the evade that could is still cooling down from one that has already ended.
			local attacker = spawnDummy("Attacker", Vector3.new(4, 5, -3), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			-- In combat, so the cooldown -- not the missing tag -- is what leaves no evade to wait for.
			defender.Humanoid:SetAttribute("InCombat", true)
			local EVADE = DefenseConstants.Evade
			local endedBy = EVADE.StartupSeconds + EVADE.ActiveSeconds + 0.05
			expect(DefenseSystem.BeginEvade(defender.Model, base - endedBy)).to.equal(true)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("evades a hit that landed while the evade was in flight, from any side", function()
			-- The dodge's own lag rewind: before it, a dodge timed to the hit on the defender's screen arrived after
			-- the hit was judged Clean, and only the parry and the block were rewound. From behind, to show the
			-- evade holds what no guard rule would.
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, -20))
			defender.Humanoid:SetAttribute("InCombat", true)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(#outcomes).to.equal(0)
			expect(DefenseSystem.BeginEvade(defender.Model, base + FRAME + PING * 0.5)).to.equal(true)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Evaded")
			local guard, guardMax = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.equal(guardMax)
		end)

		it("evades a Backstab on a raised guard the same way -- the dodge is positional", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, -20))
			defender.Humanoid:SetAttribute("InCombat", true)
			DefenseSystem.SetBlocking(defender.Model, true, base - WINDOW_CLOSE - FRAME)
			step(FRAME, base)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(#outcomes).to.equal(0)
			expect(DefenseSystem.BeginEvade(defender.Model, base + FRAME + PING * 0.5)).to.equal(true)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Evaded")
		end)

		it("does not hold a rear hit on a defender who is not in combat -- no evade could be accepted", function()
			-- The evade is combat-only (Main.server.lua drops the report otherwise), and the tag is written when a hit
			-- applies. Holding the opener for an evade that cannot come would only delay it.
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, -20))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("does not hold a hit on a broken guard -- nothing could answer it", function()
			-- Held past the break's end it would also drain the pool the break's end just refilled.
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("InCombat", true)
			DefenseSystem.DrainGuard(defender.Model, DefenseConstants.Guard.Max, base)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("leaves a hit Clean when the evade really was late", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("InCombat", true)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			-- Inside the hold, but rewound only to after the contact.
			DefenseSystem.BeginEvade(defender.Model, base + FRAME + PING + 0.5 * FRAME)
			step(FRAME, base + FRAME + PING + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("does not rewind an evade onto a cooldown that had not run out", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("InCombat", true)
			local EVADE = DefenseConstants.Evade
			-- This evade's cooldown runs out after the contact but before the second press arrives: that press is
			-- accepted, but rewound no earlier than the cooldown's end, which the contact precedes.
			local firstAt = base + FRAME * 1.5 - EVADE.CooldownSeconds
			expect(DefenseSystem.BeginEvade(defender.Model, firstAt)).to.equal(true)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(DefenseSystem.BeginEvade(defender.Model, base + FRAME + PING * 0.5)).to.equal(true)
			step(FRAME, base + FRAME + PING + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("does not hold a hit on a defender committed to their own swing", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			-- The defender's own swing sits far behind them, so it hits nothing -- it only commits the body.
			HitboxEngine.RequestAttack(defender.Id, makeDefinition({ Offset = CFrame.new(0, 0, 30) }), 1, 1)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)
	end)

	describe("DefenseSystem -- a guard waits for a committed body", function()
		-- Before this, a guard could be raised mid-swing and both ran at once: the swing's hitbox stayed
		-- live while its thrower blocked. The press is HELD, not refused -- the guard comes up the frame
		-- the body is free, provided the key is still down.
		it("holds a guard pressed mid-swing and raises it once the swing is over", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			step(FRAME, base + FRAME)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")

			step(FRAME, base + 0.3)
			expect(DefenseSystem.GetState(fighter.Model)).never.to.equal("Neutral")
		end)

		it("refuses a fresh swing while a held guard is waiting", function()
			-- The key is down: the swing that ends the commitment must not be followed by another one
			-- ahead of the guard the player is still asking for.
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)

			local canAttack, reason = DefenseSystem.CanAttack(fighter.Model)
			expect(canAttack).to.equal(false)
			expect(reason).to.equal("Guarding")
		end)

		it("forgets a held guard whose key came up before the swing ended", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			DefenseSystem.SetBlocking(fighter.Model, false, base + FRAME)
			step(FRAME, base + 0.3)

			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")
			expect((DefenseSystem.CanAttack(fighter.Model))).to.equal(true)
		end)

		-- With the stun parry OFF (DefenseConstants.StunParry): the pre-2026-10-06 rule, still the behaviour for
		-- anyone who turns it off. With it on, a stunned press arms at once -- see "parrying out of a stun".
		local function withoutStunParry(case: () -> ()): ()
			local previous = DefenseConstants.StunParry.Enabled
			DefenseConstants.StunParry.Enabled = false
			local ok, err = pcall(case)
			DefenseConstants.StunParry.Enabled = previous
			if not ok then
				error(err, 0)
			end
		end

		it("holds a guard pressed while stunned until the stun ends, with the stun parry off", function()
			-- HitstunUntil is the damage layer's published stun (AttributeConstants) -- the seam this layer
			-- reads because it may not require the layer above it.
			withoutStunParry(function()
				local base = os.clock()
				local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
				fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

				DefenseSystem.SetBlocking(fighter.Model, true, base)
				step(FRAME, base + 0.2)
				expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")

				step(FRAME, base + 0.6)
				expect(DefenseSystem.GetState(fighter.Model)).never.to.equal("Neutral")
			end)
		end)

		it("raises a guard HELD through a stun as a block, never a parry window, with the stun parry off", function()
			-- A free press arms a parry (see "arms the spawn-time clip's window" below). The same press
			-- held through hitstun must not: otherwise holding the key parried the next hit of any tight
			-- string with no timing at all.
			withoutStunParry(function()
				local base = os.clock()
				local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
				fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

				DefenseSystem.SetBlocking(fighter.Model, true, base)
				step(FRAME, base + 0.6)
				expect(DefenseSystem.GetState(fighter.Model)).to.equal("Blocking")
			end)
		end)

		it("raises a guard HELD through a swing as a block, never a parry window", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))

			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			step(FRAME, base + 0.5)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Blocking")
		end)

		it("raises the guard at once for a body nothing commits", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(fighter.Model, true, base)
			expect(DefenseSystem.GetState(fighter.Model)).never.to.equal("Neutral")
		end)
	end)

	describe("DefenseSystem -- parrying out of a stun", function()
		-- M1s link (DamageConstants.Hitstun.LinkBasicString), so a stunned defender's answer is the stun parry
		-- (DefenseConstants.StunParry): the press arms at once, the guard blocks nothing, a timed parry counts.
		it("arms a parry the moment a stunned body presses", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
			fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

			expect(DefenseSystem.SetBlocking(fighter.Model, true, base)).to.equal(true)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("ParryWindow")
		end)

		it("parries the next hit of a string from inside the stun", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")
		end)

		it("blocks nothing with a guard held through the stun", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("HitstunUntil", base + 1)

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			-- Past the window, key still down: a block on a free body, nothing on a stunned one.
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + WINDOW_CLOSE + 2 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("gives a stunned press a shorter window than a free one", function()
			local scale = DefenseConstants.StunParry.WindowScale
			expect(scale < 1).to.equal(true)
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			defender.Humanoid:SetAttribute("HitstunUntil", base + 1)

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			-- Inside the free window's close, past the scaled one's.
			local contactAt = base + WINDOW_CLOSE * (1 + scale) / 2
			step(FRAME, contactAt - FRAME)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, contactAt)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).never.to.equal("Parried")
		end)

		it("still refuses an evade out of the stun", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
			fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Committed")
		end)
	end)

	describe("DefenseSystem -- the roll's evade frames", function()
		local EVADE = DefenseConstants.Evade

		it("resolves a contact inside the window as Evaded, costing nothing and cancelling nothing", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			-- Opened far enough back that the contact below lands mid-window, clear of the startup.
			expect(DefenseSystem.BeginEvade(defender.Model, base - EVADE.StartupSeconds - 0.02)).to.equal(true)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Evaded")
			expect(outcomes[1].GuardDelta).to.equal(0)
			local guard, guardMax = DefenseSystem.GetGuard(defender.Model)
			expect(guard).to.equal(guardMax)
			-- Unlike a parry, the swing carries on -- the defender was simply not there.
			expect(HitboxEngine.GetAttackState(attacker.Id)).never.to.equal("Idle")
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Neutral")
		end)

		it("does not let the same swing re-hit once the window has closed", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.BeginEvade(defender.Model, base - EVADE.StartupSeconds - 0.02)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			-- Well past the evade window, the swing still active and the defender still inside it.
			step(FRAME, base + 1)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Evaded")
		end)

		-- THE STARTUP RULE, stated with the startup SET rather than read: the window opens `StartupSeconds` after
		-- the press. The authored value was 0.07 when this case was written and is 0 now ("a press anywhere in a
		-- windup covers the hit"), so a case that read it would test whichever branch the design happened to be on.
		-- The press below lands half a frame before the contact.
		local function evadeThenSwing(startup: number): string
			local original = EVADE.StartupSeconds
			EVADE.StartupSeconds = startup
			local ok, kind = pcall(function()
				local base = os.clock()
				local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
				local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

				local outcomes, disconnect = captureOutcomes()
				DefenseSystem.BeginEvade(defender.Model, base + FRAME * 0.5)
				HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
				step(FRAME, base + FRAME)
				disconnect()
				expect(#outcomes).to.equal(1)
				return outcomes[1].Kind
			end)
			EVADE.StartupSeconds = original
			if not ok then
				error(kind, 0)
			end
			return kind
		end

		it("is hit during a startup that outlasts the press -- pressing as the swing lands is too late", function()
			expect(evadeThenSwing(FRAME)).to.equal("Clean")
		end)

		it("covers the hit when there is no startup -- a press anywhere in the windup is in time", function()
			expect(evadeThenSwing(0)).to.equal("Evaded")
		end)

		it("refuses mid-swing -- no rolling out of your own attack", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
			HitboxEngine.RequestAttack(fighter.Id, makeDefinition({ ActiveSeconds = 0.2 }), 1, 1)

			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Committed")
		end)

		it("refuses while stunned", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
			fighter.Humanoid:SetAttribute("HitstunUntil", base + 0.5)

			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Committed")
			expect((DefenseSystem.BeginEvade(fighter.Model, base + 0.6))).to.equal(true)
		end)

		it("refuses while staggered", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			expect(DefenseSystem.GetState(attacker.Model)).to.equal("Staggered")

			local ok, reason = DefenseSystem.BeginEvade(attacker.Model, base + 2 * FRAME)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Staggered")
		end)

		it("refuses while grabbed or mounted", function()
			local base = os.clock()
			local grabbed = spawnDummy("Grabbed", Vector3.new(0, 5, 0))
			grabbed.Humanoid:SetAttribute("Grabbed", true)
			local ok, reason = DefenseSystem.BeginEvade(grabbed.Model, base)
			expect(ok).to.equal(false)
			expect(reason).to.equal("Restrained")

			local mounted = spawnDummy("Mounted", Vector3.new(10, 5, 0))
			mounted.Humanoid:SetAttribute("Mounted", true)
			expect((DefenseSystem.BeginEvade(mounted.Model, base))).to.equal(false)
		end)

		it("refuses while frozen", function()
			local frozen = spawnDummy("Frozen", Vector3.new(0, 5, 0))
			frozen.Humanoid:SetAttribute("Frozen", true)
			local ok, reason = DefenseSystem.BeginEvade(frozen.Model, os.clock())
			expect(ok).to.equal(false)
			expect(reason).to.equal("Frozen")
		end)

		it("refuses inside its own cooldown", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
			expect(DefenseSystem.BeginEvade(fighter.Model, base)).to.equal(true)
			local ok, reason = DefenseSystem.BeginEvade(fighter.Model, base + 0.1)
			expect(ok).to.equal(false)
			expect(reason).to.equal("EvadeCooldown")
		end)

		it("drops a raised guard and a deferred one", function()
			local base = os.clock()
			local fighter = spawnDummy("Fighter", Vector3.new(0, 5, 0))
			DefenseSystem.SetBlocking(fighter.Model, true, base)
			step(FRAME, base + WINDOW_CLOSE + FRAME)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Blocking")

			expect(DefenseSystem.BeginEvade(fighter.Model, base + 1)).to.equal(true)
			expect(DefenseSystem.GetState(fighter.Model)).to.equal("Neutral")
			expect((DefenseSystem.CanAttack(fighter.Model))).to.equal(true)
		end)

		it("reports an unregistered model rather than erroring", function()
			local model = Instance.new("Model")
			local ok, reason = DefenseSystem.BeginEvade(model, os.clock())
			expect(ok).to.equal(false)
			expect(reason).to.equal("NotRegistered")
			model:Destroy()
		end)
	end)

	describe("DefenseSystem.ParryFacingTarget", function()
		it("aims a melee parry at the attacker's root, not the contact point on the parrier", function()
			local attacker = spawnDummy("Attacker", Vector3.new(10, 5, 0), Vector3.new(0, 5, 0))
			local onParrierBody = Vector3.new(0, 5, 0.5)

			local target = DefenseSystem.ParryFacingTarget(attacker.Model, onParrierBody, nil)

			expect(target).to.equal(attacker.Root.Position)
		end)

		it("falls back to the contact point when the attacker has no root", function()
			local rootless = Instance.new("Model")
			local contact = Vector3.new(1, 2, 3)

			expect(DefenseSystem.ParryFacingTarget(rootless, contact, nil)).to.equal(contact)
			rootless:Destroy()
		end)

		it("keeps a shot's source", function()
			local attacker = spawnDummy("Attacker", Vector3.new(10, 5, 0), Vector3.new(0, 5, 0))
			local source = Vector3.new(0, 5, -30)

			local target = DefenseSystem.ParryFacingTarget(attacker.Model, Vector3.zero, { SourcePosition = source })

			expect(target).to.equal(source)
		end)
	end)

	describe("DefenseSystem -- trading", function()
		it("collapses mutual parries in one Step into a single Trade on each side", function()
			local base = os.clock()
			local alpha = spawnDummy("Alpha", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local beta = spawnDummy("Beta", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(alpha.Model, true, base)
			DefenseSystem.SetBlocking(beta.Model, true, base)
			HitboxEngine.RequestAttack(alpha.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(beta.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(2)
			expect(outcomes[1].Kind).to.equal("Trade")
			expect(outcomes[2].Kind).to.equal("Trade")
			-- Neither is punished: both read correctly.
			expect(DefenseSystem.GetState(alpha.Model)).never.to.equal("Staggered")
			expect(DefenseSystem.GetState(beta.Model)).never.to.equal("Staggered")
		end)

		it("moves neither guard, so a trade cannot be farmed to refill", function()
			local base = os.clock()
			local alpha = spawnDummy("Alpha", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local beta = spawnDummy("Beta", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(alpha.Model, true, base)
			DefenseSystem.SetBlocking(beta.Model, true, base)
			HitboxEngine.RequestAttack(alpha.Id, makeDefinition(), 1, 1)
			HitboxEngine.RequestAttack(beta.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(outcomes[1].GuardDelta).to.equal(0)
			expect(outcomes[2].GuardDelta).to.equal(0)
		end)
	end)

	describe("DefenseSystem -- two-pass resolution", function()
		it("classifies a contact against the window state at its OWN SampleTime", function()
			-- THE case a single end-of-frame pass gets wrong. The window opens partway through a long
			-- frame; the contact lands at a substep BEFORE it opened. Resolved against the state at
			-- frame end this reads as Parried, which is a parry for a hit that arrived first.
			local base = os.clock()
			ParryWindows.Reset()
			ParryWindows.Register(PARRY_ANIMATION, 0.05, 0.3)

			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			DefenseSystem.SetBlocking(defender.Model, true, base)
			-- A long frame, so its substeps straddle the window's opening at base + 0.05. The engine
			-- treats `now` as the END of the frame, so the earliest substep lands well before it.
			step(0.2, base + 0.1)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].SampleTime < base + 0.05).to.equal(true)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)

		it("bounds the cancel residual at the frame the parry landed in", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)

			-- Cancels apply in pass 2, so the parried swing keeps sampling for the rest of ITS frame.
			-- What must hold is that it is over by the next one -- the same one-frame bound the engine
			-- already accepts for a callback-started follow-up swing.
			local outcomes, disconnect = captureOutcomes()
			step(FRAME, base + 2 * FRAME)
			step(FRAME, base + 3 * FRAME)
			disconnect()

			expect(#outcomes).to.equal(0)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)
	end)

	describe("DefenseSystem -- fail-closed", function()
		it("blocks without parrying when no window is registered for the animation", function()
			local base = os.clock()
			ParryWindows.Reset()

			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			-- The press still raised the guard; it simply never opened a window.
			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Blocked")
			expect(DefenseSystem.GetState(attacker.Model)).never.to.equal("Staggered")
		end)

		it("parries on the default clip's window when a weapon's own clip carries none", function()
			-- A weapon that authored a PARRY clip with no markers used to lose its parry entirely.
			local base = os.clock()
			DefenseSystem.SetDefaultParryAnimation(PARRY_ANIMATION)

			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.SetParryAnimation(defender.Model, "rbxassetid://spec-unmarked-weapon-parry")

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Parried")
		end)

		it("still only blocks when neither the clip nor the default has a window", function()
			local base = os.clock()
			ParryWindows.Reset()
			DefenseSystem.SetDefaultParryAnimation(PARRY_ANIMATION)

			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			local outcomes, disconnect = captureOutcomes()
			DefenseSystem.SetBlocking(defender.Model, true, base)
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			expect(outcomes[1].Kind).to.equal("Blocked")
		end)
	end)

	describe("DefenseConstants.RegisteredParryWindows", function()
		it("arms the shipped parry clip, so a timed block press really parries", function()
			-- The parry was unreachable in play until this table existed: the shipped clip carries no
			-- marker pair, and ParryWindows fails closed. These are what DefenseSystem.Init registers.
			ParryWindows.Reset()
			for animationId, window in DefenseConstants.RegisteredParryWindows do
				expect(ParryWindows.Register(animationId, window.Open, window.Close, window.RecoveryEnd)).to.equal(true)
			end
			expect(ParryWindows.IsArmed(DefenseConstants.ParryAnimationId)).to.equal(true)
			local armed = ParryWindows.Get(DefenseConstants.ParryAnimationId) :: any
			expect(armed.Close > armed.Open).to.equal(true)
		end)
	end)

	-- The seam per-weapon parry clips arrive through. Server/Main.server.lua subscribes to
	-- AttackRequestSystem.OnWeaponChanged and calls SetParryAnimation with
	-- WeaponDefenseAnimations.GetParry(weaponId), so a weapon swap is a WINDOW swap -- these cases are
	-- what keep that true. See that function's own header for why the wiring lives in the boot script.
	describe("DefenseSystem -- SetParryAnimation", function()
		-- Opens later than PARRY_ANIMATION's 0, so which clip is armed is observable from the state
		-- alone: a window open at 0 chains through Raising within the press, one open later does not.
		local LATE_ANIMATION = "rbxassetid://spec-parry-late"

		-- The two halves are separate cases on separate bodies rather than one press-swap-press
		-- sequence, because releasing inside a LIVE window deliberately does not close it (a released
		-- tap can still parry) -- so a second press on the same body would hit Press's own "already
		-- guarding" early return and report the first window's state, proving nothing about the swap.
		it("arms the spawn-time clip's window when nothing has re-pointed it", function()
			local base = os.clock()
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- PARRY_ANIMATION's window opens at 0, so the press chains through Raising within the call.
			DefenseSystem.SetBlocking(defender.Model, true, base)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("ParryWindow")
		end)

		it("arms the window of the clip it was pointed at, not the one it registered with", function()
			local base = os.clock()
			ParryWindows.Register(LATE_ANIMATION, 0.2, 0.5)
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			-- Same press, same instant, on a body re-pointed at a clip whose window opens 0.2s in: still
			-- Raising rather than live. The ONLY difference from the case above is the swapped clip.
			DefenseSystem.SetParryAnimation(defender.Model, LATE_ANIMATION)
			DefenseSystem.SetBlocking(defender.Model, true, base)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Raising")
		end)

		-- A weapon with no PARRY clip of its own resolves to a blank id rather than to nothing, so this
		-- is a real argument the boot wiring can pass, not a defensive check against a caller mistake.
		it("fail-closes on a blank id -- the guard still raises, no window opens", function()
			local base = os.clock()
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))

			DefenseSystem.SetParryAnimation(defender.Model, "")
			DefenseSystem.SetBlocking(defender.Model, true, base)
			expect(DefenseSystem.GetState(defender.Model)).to.equal("Blocking")
		end)

		-- The boot subscription fires on character bind, which can beat this System's own
		-- PlayerLifecycle registration. Silently ignoring an unregistered model is what makes that
		-- ordering a non-issue rather than a race to get right.
		it("ignores a model it has no registration for", function()
			local stray = Instance.new("Model")
			stray.Name = "Unregistered"
			stray.Parent = Workspace
			Rig.Track(stray)

			expect(function()
				DefenseSystem.SetParryAnimation(stray, PARRY_ANIMATION)
			end).never.to.throw()
		end)
	end)

	describe("DefenseSystem -- registration", function()
		it("reports an unregistered target's contacts as Clean rather than dropping them", function()
			local base = os.clock()
			local attacker = spawnDummy("Attacker", Vector3.new(0, 5, 0), Vector3.new(0, 5, -4))
			local defender = spawnDummy("Defender", Vector3.new(0, 5, -4), Vector3.new(0, 5, 0))
			DefenseSystem.UnregisterCombatant(defender.Model)

			local outcomes, disconnect = captureOutcomes()
			HitboxEngine.RequestAttack(attacker.Id, makeDefinition(), 1, 1)
			step(FRAME, base + FRAME)
			disconnect()

			-- The damage layer must still see every contact.
			expect(#outcomes).to.equal(1)
			expect(outcomes[1].Kind).to.equal("Clean")
		end)
	end)

	describe("ClashGuard", function()
		it("costs the clash's posture from a healthy pool", function()
			expect(DefenseSystem.ClashGuard(100, -12)).to.equal(88)
		end)

		it("never empties a guard", function()
			local floor = DefenseConstants.Clash.GuardFloor
			expect(DefenseSystem.ClashGuard(10, -12)).to.equal(floor)
			expect(DefenseSystem.ClashGuard(floor, -12)).to.equal(floor)
		end)

		it("leaves a pool already under the floor where it is", function()
			expect(DefenseSystem.ClashGuard(0, -12)).to.equal(0)
		end)
	end)
end
