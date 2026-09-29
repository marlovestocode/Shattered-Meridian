--!strict
-- Covers Client/Parkour/StateMachine.lua -- the movement-agnostic dispatcher every parkour state runs
-- inside.
--
-- Driven entirely with SYNTHETIC states and a synthetic context, never with the real movement states.
-- That is the point: this module is supposed to know nothing about parkour, and a spec that needed a
-- character, a Workspace or a probe result to exercise it would be evidence that it does. Every case
-- below is about arbitration -- who wins, who is exempt, what runs in what order -- and none of them
-- mentions a wall or a ledge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local StateMachine = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.StateMachine)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

type ParkourContext = ParkourTypes.ParkourContext
type MovementStateId = ParkourTypes.MovementStateId

-- The machine reads exactly four context fields (Now, CurrentStateId, PreviousStateId, StateElapsed)
-- and passes the rest through untouched, so a partial context is sufficient and honest here -- and
-- building a full one would tie this spec to a shape that has nothing to do with what it is testing.
local function makeContext(): ParkourContext
	return {
		Now = 100,
		CurrentStateId = "Idle" :: MovementStateId,
		PreviousStateId = "Idle" :: MovementStateId,
		StateElapsed = 0,
	} :: any
end

type Trace = { string }

-- Builds a synthetic state that records every callback it receives into `trace`, so ordering can be
-- asserted directly rather than inferred.
local function makeState(
	id: MovementStateId,
	priority: number,
	trace: Trace,
	options: {
		CanEnter: boolean?,
		Reason: string?,
		Committed: boolean?,
		UpdateReturns: MovementStateId?,
	}?
): ParkourTypes.StateDefinition
	local settings = options or {}
	return {
		Id = id,
		Priority = priority,
		Drive = "Humanoid",
		Probes = { Ground = true },
		Committed = settings.Committed,
		CanEnter = function(): (boolean, string?)
			return settings.CanEnter ~= false, settings.Reason
		end,
		Enter = function()
			table.insert(trace, `Enter:{id}`)
		end,
		Update = function(): ParkourTypes.TransitionResult
			table.insert(trace, `Update:{id}`)
			return settings.UpdateReturns
		end,
		Exit = function()
			table.insert(trace, `Exit:{id}`)
		end,
	}
end

return function()
	describe("StateMachine -- construction and registration", function()
		it("starts parked in the initial state without entering it", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			expect(machine:GetCurrentId()).to.equal("Idle")
			expect(#trace).to.equal(0)
		end)

		it("returns a registered definition by id", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			local definition = makeState("Idle", 10, trace)
			machine:Register(definition)
			expect(machine:GetDefinition("Idle")).to.equal(definition)
			expect(machine:GetCurrentDefinition()).to.equal(definition)
		end)

		it("returns nil for an unregistered id", function()
			local machine = StateMachine.New("Idle")
			expect(machine:GetDefinition("Sliding")).to.equal(nil)
		end)

		it("replaces a definition re-registered under the same id", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			local replacement = makeState("Idle", 10, trace)
			machine:Register(replacement)
			expect(machine:GetDefinition("Idle")).to.equal(replacement)
		end)
	end)

	describe("StateMachine.Update -- self-directed transitions", function()
		it("honors the id the active state asks to hand off to", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace))

			expect(machine:Update(makeContext())).to.equal("Walking")
		end)

		it("runs Update, then Exit, then Enter, in that order", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace))

			machine:Update(makeContext())
			expect(trace[1]).to.equal("Update:Idle")
			expect(trace[2]).to.equal("Exit:Idle")
			expect(trace[3]).to.equal("Enter:Walking")
		end)

		it("outranks pre-emption -- a state that says it is done is not second-guessed", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace))
			-- A higher-priority state that would happily accept -- and must not get the chance.
			machine:Register(makeState("Sliding", 500, trace))

			expect(machine:Update(makeContext())).to.equal("Walking")
		end)

		it("stays put when Update returns its own id", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Idle" }))
			expect(machine:Update(makeContext())).to.equal("Idle")
			expect(#trace).to.equal(1)
		end)

		it("refuses a transition to an unregistered id rather than erroring", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Vaulting" }))
			expect(machine:Update(makeContext())).to.equal("Idle")
		end)

		it("applies at most ONE transition per call, bounding a mis-authored state pair", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			-- A and B hand off to each other forever; without the cap this would hang the frame.
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace, { UpdateReturns = "Idle" }))

			expect(machine:Update(makeContext())).to.equal("Walking")
			expect(machine:Update(makeContext())).to.equal("Idle")
		end)
	end)

	describe("StateMachine.Update -- pre-emption", function()
		it("lets a strictly higher-priority state barge in", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Sliding", 120, trace))

			expect(machine:Update(makeContext())).to.equal("Sliding")
		end)

		it("does NOT let an equal-priority state barge in -- no ping-pong between peers", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Walking", 10, trace))

			expect(machine:Update(makeContext())).to.equal("Idle")
		end)

		it("does not let a lower-priority state barge in", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Sliding")
			machine:Register(makeState("Sliding", 120, trace))
			machine:Register(makeState("Idle", 10, trace))

			expect(machine:Update(makeContext())).to.equal("Sliding")
		end)

		it("picks the highest-priority acceptor when several would accept", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Walking", 20, trace))
			machine:Register(makeState("Sliding", 120, trace))
			machine:Register(makeState("WallRunning", 160, trace))

			expect(machine:Update(makeContext())).to.equal("WallRunning")
		end)

		it("skips a higher-priority state that refuses", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("WallRunning", 160, trace, { CanEnter = false }))
			machine:Register(makeState("Sliding", 120, trace))

			expect(machine:Update(makeContext())).to.equal("Sliding")
		end)

		it("stays put when every higher-priority state refuses", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Sliding", 120, trace, { CanEnter = false }))

			expect(machine:Update(makeContext())).to.equal("Idle")
		end)
	end)

	describe("StateMachine.Update -- committed states", function()
		it("is exempt from pre-emption entirely", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Vaulting")
			machine:Register(makeState("Vaulting", 150, trace, { Committed = true }))
			machine:Register(makeState("CombatHeld", 1000, trace))

			expect(machine:Update(makeContext())).to.equal("Vaulting")
		end)

		it("can still hand off on its own terms", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Vaulting")
			machine:Register(makeState("Vaulting", 150, trace, { Committed = true, UpdateReturns = "Falling" }))
			machine:Register(makeState("Falling", 60, trace))

			expect(machine:Update(makeContext())).to.equal("Falling")
		end)

		it("can still be moved by an explicit ForceTransition", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Vaulting")
			machine:Register(makeState("Vaulting", 150, trace, { Committed = true }))
			machine:Register(makeState("CombatHeld", 1000, trace))

			expect(machine:ForceTransition("CombatHeld", makeContext())).to.equal(true)
			expect(machine:GetCurrentId()).to.equal("CombatHeld")
		end)
	end)

	describe("StateMachine.ForceTransition", function()
		it("bypasses CanEnter -- the caller is asserting, not asking", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Falling", 60, trace, { CanEnter = false }))

			expect(machine:ForceTransition("Falling", makeContext())).to.equal(true)
			expect(machine:GetCurrentId()).to.equal("Falling")
		end)

		it("still runs Exit and Enter, so nothing is left holding a constraint", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Sliding")
			machine:Register(makeState("Sliding", 120, trace))
			machine:Register(makeState("Idle", 10, trace))

			machine:ForceTransition("Idle", makeContext())
			expect(trace[1]).to.equal("Exit:Sliding")
			expect(trace[2]).to.equal("Enter:Idle")
		end)

		it("returns false for an unregistered target", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			expect(machine:ForceTransition("Mantling", makeContext())).to.equal(false)
		end)

		it("returns false when already in the target state", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			expect(machine:ForceTransition("Idle", makeContext())).to.equal(false)
		end)
	end)

	describe("StateMachine -- context bookkeeping", function()
		it("stamps CurrentStateId and PreviousStateId before the state's callbacks run", function()
			local machine = StateMachine.New("Idle")
			local seenCurrent: string? = nil
			local seenPrevious: string? = nil
			machine:Register({
				Id = "Idle",
				Priority = 10,
				Drive = "Humanoid",
				Probes = {},
				CanEnter = function(): (boolean, string?)
					return true, nil
				end,
				Update = function(context: ParkourContext): ParkourTypes.TransitionResult
					seenCurrent = context.CurrentStateId
					seenPrevious = context.PreviousStateId
					return nil
				end,
			})

			local context = makeContext()
			context.CurrentStateId = "Falling"
			machine:Update(context)
			expect(seenCurrent).to.equal("Idle")
			expect(seenPrevious).to.equal("Idle")
		end)

		it("maintains StateElapsed from the entry time", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			local seenElapsed = -1
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register({
				Id = "Walking",
				Priority = 20,
				Drive = "Humanoid",
				Probes = {},
				CanEnter = function(): (boolean, string?)
					return true, nil
				end,
				Update = function(context: ParkourContext): ParkourTypes.TransitionResult
					seenElapsed = context.StateElapsed
					return nil
				end,
			})

			local context = makeContext()
			machine:Update(context)
			context.Now = 102.5
			machine:Update(context)
			expect(seenElapsed).to.equal(2.5)
		end)

		it("tracks the previous state id across a transition", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace))

			machine:Update(makeContext())
			expect(machine:GetPreviousId()).to.equal("Idle")
		end)
	end)

	describe("StateMachine.GetHistory", function()
		it("records the route each transition took", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace))
			machine:Register(makeState("Sliding", 120, trace, { CanEnter = false }))

			machine:Update(makeContext())
			local history = machine:GetHistory()
			expect(#history).to.equal(1)
			expect(history[1].From).to.equal("Idle")
			expect(history[1].To).to.equal("Walking")
			expect(history[1].Route).to.equal("Self")
		end)

		it("labels a pre-emption distinctly from a self-directed hand-off", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Sliding", 120, trace))

			machine:Update(makeContext())
			expect(machine:GetHistory()[1].Route).to.equal("Preempt")
		end)

		it("labels a forced transition distinctly again", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("CombatHeld", 1000, trace))

			machine:ForceTransition("CombatHeld", makeContext())
			expect(machine:GetHistory()[1].Route).to.equal("Forced")
		end)

		it("bounds the history rather than growing forever on a session-long client", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace, { UpdateReturns = "Walking" }))
			machine:Register(makeState("Walking", 20, trace, { UpdateReturns = "Idle" }))

			local context = makeContext()
			for _ = 1, 50 do
				machine:Update(context)
			end
			expect(#machine:GetHistory() <= 16).to.equal(true)
		end)
	end)

	describe("StateMachine.EvaluateAvailability", function()
		it("reports every registered state, available or not", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Sliding", 120, trace, { CanEnter = false, Reason = "TooSlowToSlide" }))

			local records = machine:EvaluateAvailability(makeContext())
			expect(#records).to.equal(2)
		end)

		it("carries each refusal's own reason string verbatim", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Sliding", 120, trace, { CanEnter = false, Reason = "TooSlowToSlide" }))

			local records = machine:EvaluateAvailability(makeContext())
			expect(records[1].Id).to.equal("Sliding")
			expect(records[1].Available).to.equal(false)
			expect(records[1].Reason).to.equal("TooSlowToSlide")
		end)

		it("does not itself change the current state", function()
			local trace: Trace = {}
			local machine = StateMachine.New("Idle")
			machine:Register(makeState("Idle", 10, trace))
			machine:Register(makeState("Sliding", 120, trace))

			machine:EvaluateAvailability(makeContext())
			expect(machine:GetCurrentId()).to.equal("Idle")
			expect(#trace).to.equal(0)
		end)
	end)
end
