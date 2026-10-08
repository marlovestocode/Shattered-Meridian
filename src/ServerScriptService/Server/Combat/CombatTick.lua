--!strict
--[[
	CombatTick.lua

	Owns: the ONE Heartbeat the combat Systems step on, and the order they step in.

	WHY (2026-10-08). Every combat System used to connect its own Heartbeat, and the order those fired in --
	Roblox fires connections in connection order -- was load-bearing: DefenseSystem's pass 2 must follow the
	engine's substeps, DamageSystem must reclaim expired hitstun before AttackRequestSystem flushes buffered
	presses, the realm reads what the four layers wrote. That order was held by the boot order in
	Main.server.lua and re-asserted in each Init. It worked, but it was an order you could only see by
	reading nine files, and a System booted in the wrong slot would silently resolve a frame late.

	Here it is one list, PHASES, in the order they run. A System registers its Step against its own phase
	name from Init; where in the boot it does so no longer matters to WHEN it runs, only to whether it runs.

	EACH PHASE IS LABELLED AND ISOLATED. Every phase runs inside its own MicroProfiler label ("Combat.<Phase>",
	under one "CombatTick"), so a capture says which layer a combat hitch is in -- none of the four core
	layers had a label before. Each phase is also pcall'd: on separate connections, one System erroring
	could not stop another's Step, and folding them into one loop must not lose that. A phase slower than
	PHASE_BUDGET_SECONDS warns once through the Logger's own rate limit (the SlowWatch behaviour).

	ONE CLOCK PER FRAME. Every phase is handed the same `now`, read once. They used to read os.clock()
	separately, microseconds apart, so two layers could disagree about whether a deadline had passed in the
	same frame.

	WHERE IT SITS IN THE FRAME. The tick's Heartbeat is connected by the first Register -- HitboxEngine.Init,
	at the engine's existing boot slot -- so the whole block fires where the first combat Heartbeat used to,
	and Systems that connect their own Heartbeat later (ParkourSystem, TrainingBotSystem) still run after it,
	as before. GameplayEvents.OnHeartbeatTick subscribers (MovementGuard, KnockbackAudit) still run before
	it, also as before.

	Does not own: what any phase does, or a System's PreSimulation work (GrabSystem's pin), which is a
	different frame stage and stays on its own connection.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("CombatTick")

local CombatTick = {}

-- The order every combat phase runs in, each frame. Adding a System is adding its name here, in the slot
-- the data it reads demands, and registering against it.
CombatTick.PHASES = table.freeze({
	"HitboxEngine", -- contact detection: swings and shots, substepped
	"DefenseSystem", -- pass 2: arbitrate the frame's contacts, apply the classified outcomes
	"DamageSystem", -- reclaim expired hitstun, lunge, flush the frame's feedback batches
	"AttackRequestSystem", -- flush buffered presses against this frame's gates
	"GrabSystem",
	"AirComboSystem",
	"EngagementSystem",
	"EnvironmentReactionSystem",
	"DomainSystem", -- reads what every layer above wrote this frame
})

-- Half a 60Hz frame, as SlowWatch.DEFAULT_BUDGET_SECONDS: one phase spending that is a hitch on its own.
local PHASE_BUDGET_SECONDS = 1 / 120

export type Step = (deltaTime: number, now: number) -> ()

type Phase = {
	Name: string,
	Label: string,
	Step: Step?,
}

local phases: { Phase } = {}
local phaseByName: { [string]: Phase } = {}
for _, name in CombatTick.PHASES do
	local phase: Phase = { Name = name, Label = `Combat.{name}`, Step = nil }
	table.insert(phases, phase)
	phaseByName[name] = phase
end

local connection: RBXScriptConnection? = nil

-- One frame: every registered phase, in PHASES order, on one clock. Public so a spec can drive it.
function CombatTick.Step(deltaTime: number, now: number): ()
	debug.profilebegin("CombatTick")
	for _, phase in phases do
		local step = phase.Step
		if step == nil then
			continue
		end
		debug.profilebegin(phase.Label)
		local startedAt = os.clock()
		local ok, err = xpcall(step, debug.traceback, deltaTime, now)
		local elapsed = os.clock() - startedAt
		debug.profileend()
		if not ok then
			logger:error("Combat phase errored", { phase = phase.Name, error = tostring(err) })
		elseif elapsed >= PHASE_BUDGET_SECONDS then
			logger:warn("Slow combat phase", {
				phase = phase.Name,
				milliseconds = math.floor(elapsed * 1000 + 0.5),
			})
		end
	end
	debug.profileend()
end

-- Registers `step` as `phaseName`'s Step and returns the function that unregisters it (a Trove accepts it
-- directly). Each phase has one owner: a second registration while one is live is a boot bug and errors.
-- The first registration connects the tick's Heartbeat.
function CombatTick.Register(phaseName: string, step: Step): () -> ()
	local phase = phaseByName[phaseName]
	assert(phase ~= nil, `CombatTick.Register: unknown phase "{phaseName}" -- add it to CombatTick.PHASES`)
	assert(phase.Step == nil, `CombatTick.Register: phase "{phaseName}" is already registered`)
	phase.Step = step
	if connection == nil then
		connection = RunService.Heartbeat:Connect(function(deltaTime: number)
			CombatTick.Step(deltaTime, os.clock())
		end)
	end
	return function()
		if phase.Step == step then
			phase.Step = nil
		end
	end
end

-- Whether `phaseName` currently has a Step. What an Init asserts about the layer below it.
function CombatTick.IsRegistered(phaseName: string): boolean
	local phase = phaseByName[phaseName]
	return phase ~= nil and phase.Step ~= nil
end

-- Spec-only: drops every registration and the Heartbeat.
function CombatTick.Reset(): ()
	for _, phase in phases do
		phase.Step = nil
	end
	local current = connection
	if current then
		current:Disconnect()
		connection = nil
	end
end

return CombatTick
