--!strict
-- Covers Server/Combat/HitboxEngine/AttackStateMachine.lua -- the per-combatant attack lifecycle.
--
-- Driven entirely with a synthetic clock and a synthetic definition. The machine takes time as a
-- parameter on every entry point precisely so this is possible: nothing here sleeps, nothing here
-- needs a character, and frame-data behaviour that would take a real second to observe is asserted
-- in microseconds. A case in this file that needed a rig would mean the machine had learned
-- something about bodies, which it must not.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackStateMachine = require(ServerScriptService.Server.Combat.HitboxEngine.AttackStateMachine)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

type AttackDefinition = HitboxTypes.AttackDefinition

local function makeDefinition(windup: number, active: number, recovery: number): AttackDefinition
	local definition = HitboxTypes.SanitizeDefinition({
		DebugName = "SpecAttack",
		Shape = "Box",
		BaseDimensions = { Width = 4, Height = 4, Length = 4 },
		Scaling = { ComboStageMultipliers = { 1 }, MaxScaleMultiplier = 4 },
		Offset = CFrame.identity,
		AttachmentPart = "Root",
		WindupSeconds = windup,
		ActiveSeconds = active,
		RecoverySeconds = recovery,
		LocksMovement = false,
	})
	return definition
end

type Trace = { string }

-- Records every hook the machine fires, so ORDER can be asserted directly rather than inferred from
-- which state happens to be current afterwards.
local function makeHooks(trace: Trace): AttackStateMachine.Hooks
	return {
		OnEnterActive = function()
			table.insert(trace, "EnterActive")
		end,
		OnExitActive = function()
			table.insert(trace, "ExitActive")
		end,
		OnSwingEnded = function(swing, completed)
			table.insert(trace, `SwingEnded:{completed}:{swing.InterruptReason or "none"}`)
		end,
	}
end

return function()
	describe("AttackStateMachine -- construction", function()
		it("starts Idle and not attacking", function()
			local machine = AttackStateMachine.New()
			expect(machine:GetState()).to.equal("Idle")
			expect(machine:IsAttacking()).to.equal(false)
			expect(machine:GetSwing()).to.equal(nil)
		end)

		it("does nothing on Update while Idle", function()
			local machine = AttackStateMachine.New()
			expect(machine:Update(1000)).to.equal("Idle")
		end)
	end)

	describe("AttackStateMachine.Begin", function()
		it("enters Windup and carries the caller's numbers on the swing", function()
			local machine = AttackStateMachine.New()
			local accepted, reason = machine:Begin(makeDefinition(0.1, 0.1, 0.1), 3, 7, 0)

			expect(accepted).to.equal(true)
			expect(reason).to.equal(nil)
			expect(machine:GetState()).to.equal("Windup")

			local swing = machine:GetSwing()
			expect(swing).to.be.ok()
			expect((swing :: any).ComboStage).to.equal(3)
			expect((swing :: any).PowerLevel).to.equal(7)
		end)

		it("refuses a second attack while one is in flight, without erroring", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0.1, 0.1, 0.1), 1, 0, 0)

			local accepted, reason = machine:Begin(makeDefinition(0.1, 0.1, 0.1), 1, 0, 0.05)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Busy")
			-- The refusal must not have disturbed the swing already running.
			expect(machine:GetState()).to.equal("Windup")
		end)

		it("reaches Active within the same call when the windup is zero", function()
			-- The attacks most likely to author a zero windup are the ones whose entire identity is
			-- that they come out instantly. Costing them a frame here would be felt input latency.
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Begin(makeDefinition(0, 0.1, 0.1), 1, 0, 0)

			expect(machine:GetState()).to.equal("Active")
			expect(trace[1]).to.equal("EnterActive")
		end)
	end)

	describe("AttackStateMachine -- phase progression", function()
		it("walks Idle -> Windup -> Active -> Recovery -> Idle at the authored times", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0.1, 0.2, 0.1), 1, 0, 0)

			expect(machine:Update(0.05)).to.equal("Windup")
			expect(machine:Update(0.15)).to.equal("Active")
			expect(machine:Update(0.25)).to.equal("Active")
			expect(machine:Update(0.35)).to.equal("Recovery")
			expect(machine:Update(0.45)).to.equal("Idle")
		end)

		it("fires each lifecycle hook exactly once, in order", function()
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Begin(makeDefinition(0.1, 0.2, 0.1), 1, 0, 0)
			machine:Update(1)

			expect(#trace).to.equal(3)
			expect(trace[1]).to.equal("EnterActive")
			expect(trace[2]).to.equal("ExitActive")
			expect(trace[3]).to.equal("SwingEnded:true:none")
		end)

		it("releases the swing on the return to Idle", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0.1, 0.1, 0.1), 1, 0, 0)
			machine:Update(1)
			expect(machine:GetSwing()).to.equal(nil)
			expect(machine:IsAttacking()).to.equal(false)
		end)

		it("chains through zero-length phases in one Update rather than one per frame", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0, 0, 0), 1, 0, 0)
			-- Everything is instant, so Begin's own drive should have taken it all the way home.
			expect(machine:GetState()).to.equal("Idle")
		end)
	end)

	describe("AttackStateMachine -- timing exactness", function()
		it("starts a phase when the previous one was DUE, not when it was noticed", function()
			-- Windup 0.05, Active 0.05. The machine is not driven until 0.09 -- 40ms late. Active must
			-- have begun at the 0.05 mark and be due to end at 0.10, so at 0.09 it is still Active.
			-- If the overshoot were carried forward, Active would have started at 0.09 and the attack's
			-- total length would depend on server frame timing -- frame data players cannot learn.
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0.05, 0.05, 0), 1, 0, 0)

			expect(machine:Update(0.09)).to.equal("Active")
			expect(machine:GetStateElapsed(0.09) > 0.03).to.equal(true)
			expect(machine:Update(0.1)).to.equal("Idle")
		end)

		it("reports Active elapsed only while Active, which is what a charge attack grows against", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0.1, 1, 0), 1, 0, 0)

			expect(machine:GetActiveElapsed(0.05)).to.equal(0)
			machine:Update(0.3)
			expect(machine:GetState()).to.equal("Active")
			-- Active opened at the 0.1 mark, so 0.3 is 0.2 into the window.
			expect(math.abs(machine:GetActiveElapsed(0.3) - 0.2) < 1e-6).to.equal(true)
		end)
	end)

	describe("AttackStateMachine.Interrupt", function()
		it("cuts a Windup short and returns home", function()
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Begin(makeDefinition(0.5, 0.5, 0.5), 1, 0, 0)

			expect(machine:Interrupt("Parried", 0.1)).to.equal(true)
			expect(machine:GetState()).to.equal("Idle")
			-- Never reached Active, so no Active hooks -- only the ending.
			expect(#trace).to.equal(1)
			expect(trace[1]).to.equal("SwingEnded:false:Parried")
		end)

		it("cuts an Active window short, closing it through the same Exit path a finish uses", function()
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Begin(makeDefinition(0, 0.5, 0.5), 1, 0, 0)

			machine:Interrupt("Stunned", 0.1)
			expect(machine:GetState()).to.equal("Idle")
			expect(trace[1]).to.equal("EnterActive")
			expect(trace[2]).to.equal("ExitActive")
			expect(trace[3]).to.equal("SwingEnded:false:Stunned")
		end)

		it("cuts a Recovery short", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0.1, 0.1, 5), 1, 0, 0)
			machine:Update(0.25)
			expect(machine:GetState()).to.equal("Recovery")

			expect(machine:Interrupt("Ragdolled", 0.3)).to.equal(true)
			expect(machine:GetState()).to.equal("Idle")
		end)

		it("refuses to interrupt an idle machine", function()
			local machine = AttackStateMachine.New()
			expect(machine:Interrupt("Nothing", 0)).to.equal(false)
		end)
	end)

	describe("AttackStateMachine -- runaway guard", function()
		it("ends a swing that outlives MaxSwingSeconds, whatever its authored timings say", function()
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			-- Authored to last far longer than the engine's hard ceiling.
			machine:Begin(makeDefinition(1, 1, 1), 1, 0, 0)

			machine:Update(HitboxEngineConstants.MaxSwingSeconds * 2)
			expect(machine:GetState()).to.equal("Idle")
			expect(trace[#trace]).to.equal("SwingEnded:false:Expired")
		end)

		it("does not expire a long-but-legal swing that was simply driven late", function()
			-- Driven well past the attack's own length but nowhere near the ceiling. The guard must not
			-- turn "the server hitched through this whole attack" into a spurious interruption.
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Begin(makeDefinition(0.5, 0.5, 0.5), 1, 0, 0)
			machine:Update(3)
			expect(trace[#trace]).to.equal("SwingEnded:true:none")
		end)
	end)

	describe("AttackStateMachine.Reset", function()
		it("drops straight to Idle while still running the cleanup path", function()
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Begin(makeDefinition(0, 5, 5), 1, 0, 0)
			expect(machine:GetState()).to.equal("Active")

			machine:Reset(0.1)
			expect(machine:GetState()).to.equal("Idle")
			expect(machine:GetSwing()).to.equal(nil)
			-- Still closed the Active window and still announced the ending -- teardown must not leave a
			-- consumer believing a swing is live.
			expect(trace[2]).to.equal("ExitActive")
			expect(trace[3]).to.equal("SwingEnded:false:Reset")
		end)

		it("is harmless on an already-idle machine", function()
			local trace: Trace = {}
			local machine = AttackStateMachine.New(makeHooks(trace))
			machine:Reset(0)
			expect(machine:GetState()).to.equal("Idle")
			expect(#trace).to.equal(0)
		end)

		it("accepts a fresh attack afterwards", function()
			local machine = AttackStateMachine.New()
			machine:Begin(makeDefinition(0, 5, 5), 1, 0, 0)
			machine:Reset(0.1)
			expect(machine:Begin(makeDefinition(0.1, 0.1, 0.1), 2, 0, 0.2)).to.equal(true)
			expect(machine:GetState()).to.equal("Windup")
		end)
	end)
end
