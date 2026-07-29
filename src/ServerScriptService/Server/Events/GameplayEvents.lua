--!strict
--[[
	GameplayEvents.lua

	Owns: the server-internal gameplay signals that cross System boundaries -- who died, which
	training bot died or despawned, and the shared combat tick. Publishers fire through here;
	subscribers listen here. Neither side requires the other.

	WHY THIS EXISTS -- the dependency direction, not the convenience.

	Before this module, CombatSystem owned these signals as public BindableEvent fields, so anything
	that wanted to hear about a death had to `require(CombatSystem)` -- a 3400-line module that
	pulls in ten Server/Combat/ siblings and creates two dozen remotes -- purely to reach one event.
	RespawnSystem did exactly that. software-architecture.md's documented progression flow then adds
	RewardSystem, ProgressionSystem, MeridianSystem, TierSystem, BloodlineSystem, ArtSystem and
	AchievementSystem as reactors to a confirmed kill, with RivalrySystem and BountySystem alongside
	them -- nine more modules, each of which would have required the combat monolith to hear that
	someone died. That is the inverted dependency this module fixes: the producer of an event should
	not be a dependency of everyone interested in it.

	It is also what keeps progression OUT of the combat monolith. When a progression system needs a
	new fact about a kill, the correct change is a new field on this file's payload -- never a new
	`require` inside CombatSystem, and never a call from CombatSystem outward into progression.

	A TYPED REGISTRY, NOT A GENERIC EVENT BUS.

	Every signal is a named field with a typed Connect helper and a typed Fire helper, rather than a
	string-keyed `Fire("PlayerKilled", ...)` dispatcher. A generic bus trades one coupling problem
	for a typo problem: `Fire("PlayerKiled", ...)` is a silent no-op at runtime, where
	`GameplayEvents.FirePlayerKiled(...)` fails to typecheck. It also keeps every payload shape
	declared in one readable place instead of implied by whatever the call sites happen to pass.

	MECHANISM. Each signal is a BindableEvent internally -- this project's own established
	notification shape (see ChangeNotifier.lua's header on not inventing a second one), and reusing
	it means this module changes no firing/ordering semantics versus the fields it replaces. The
	BindableEvents are deliberately private: callers go through the Connect/Fire helpers so the
	payload types are enforced on both sides, and so a future change of mechanism doesn't touch call
	sites.

	NO Init(), NO BOOT ORDER. This module holds signals and nothing else -- no state to seed, no
	remotes, no dependency on any System. It is safe to require from any System at any point in
	Main.server.lua's sequence, which is what lets a subscriber connect during its own Init() without
	caring whether the publisher has booted yet.

	Does not own: what any event MEANS or what should happen next. It does not decide that a kill
	grants progression (ProgressionSystem), what a kill is worth (RewardSystem/AbsorbSystem/
	MeridianSystem), when a player gets a new body (RespawnSystem), or whether a bot respawns
	(TrainingBotSystem). It carries facts; every consumer decides its own response independently.
	It also owns no client-facing surface -- these never cross the client boundary, which is
	NetworkBridge's job.
]]

local GameplayEvents = {}

--
-- Player lifecycle
--

-- Fired once per confirmed player death, after CombatSystem's own state is already consistent
-- (alive flag cleared, lock-on references dropped).
--
-- `killer` is nil for any death this System did not attribute to a specific attacker -- a fall, the
-- void, or a CombatSystem.ApplyServerDamage caller that passed none. That is deliberate and load-
-- bearing rather than an edge case: CombatSystem confirms EVERY death through one Humanoid.Died
-- handler regardless of cause, so a subscriber that only cares about PvP must check `killer` itself
-- rather than assuming this only fires for combat deaths. RespawnSystem depends on exactly that
-- breadth -- a player who falls into the void still needs a new body.
local playerKilledSignal = Instance.new("BindableEvent")

function GameplayEvents.FirePlayerKilled(victim: Player, killer: Player?): ()
	playerKilledSignal:Fire(victim, killer)
end

function GameplayEvents.OnPlayerKilled(handler: (victim: Player, killer: Player?) -> ()): RBXScriptConnection
	return playerKilledSignal.Event:Connect(handler)
end

--
-- Training bot lifecycle
--

-- Fired once per confirmed training bot death. Distinct from TrainingBotDespawned below, and the
-- distinction matters: this one means "this bot died", which TrainingBotSystem answers by scheduling
-- a RESPAWN. Firing it for a silent cap-eviction would respawn the just-evicted bot, which would
-- immediately re-evict whatever took its slot.
local trainingBotKilledSignal = Instance.new("BindableEvent")

function GameplayEvents.FireTrainingBotKilled(botModel: Model, ownerPlayer: Player, killerPlayer: Player?): ()
	trainingBotKilledSignal:Fire(botModel, ownerPlayer, killerPlayer)
end

function GameplayEvents.OnTrainingBotKilled(
	handler: (botModel: Model, ownerPlayer: Player, killerPlayer: Player?) -> ()
): RBXScriptConnection
	return trainingBotKilledSignal.Event:Connect(handler)
end

-- Fired unconditionally for EVERY path by which a bot's model stops being tracked -- death, the
-- explicit DespawnTrainingBot API, and per-owner cap eviction alike. Subscribers use it purely to
-- drop their own per-bot bookkeeping; without it an evicted bot's AI-state entry is never cleaned up
-- and is iterated forever by the Heartbeat-driven decision loop. See TrainingBotKilled above for why
-- these are two signals rather than one.
local trainingBotDespawnedSignal = Instance.new("BindableEvent")

function GameplayEvents.FireTrainingBotDespawned(botModel: Model): ()
	trainingBotDespawnedSignal:Fire(botModel)
end

function GameplayEvents.OnTrainingBotDespawned(handler: (botModel: Model) -> ()): RBXScriptConnection
	return trainingBotDespawnedSignal.Event:Connect(handler)
end

--
-- Shared tick
--

-- Fired at the end of every CombatSystem heartbeat tick, so a server-internal System that needs
-- per-frame work can piggyback the one existing RunService.Heartbeat connection instead of opening a
-- second one -- performance-optimization.md's server-tick-discipline guidance, and the same
-- reasoning HitboxResolver/RagdollController already follow by being driven from that single tick
-- rather than connecting their own.
--
-- Subscribe sparingly and keep handlers O(1)-per-entity: everything connected here runs inside the
-- server's per-frame budget, and there is deliberately no scheduler or priority band yet. Once the
-- number of subscribers or the per-tick entity count grows (the audit flags ~20 NPCs as the point
-- worth revisiting), this is the seam a TickScheduler with priority bands would slot into, without
-- any subscriber changing.
local heartbeatTickSignal = Instance.new("BindableEvent")

function GameplayEvents.FireHeartbeatTick(deltaTime: number): ()
	heartbeatTickSignal:Fire(deltaTime)
end

function GameplayEvents.OnHeartbeatTick(handler: (deltaTime: number) -> ()): RBXScriptConnection
	return heartbeatTickSignal.Event:Connect(handler)
end

return GameplayEvents
