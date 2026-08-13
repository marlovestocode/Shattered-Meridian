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

	SUBSCRIBER INVENTORY. docs/architecture/2026-08-audit.md section 5.1 asked for this list to exist
	before the progression spine lands, so ordering assumptions live in one readable place instead of
	archaeology across N Init() functions. Keep it current when you add a subscriber -- it is
	documentation, not runtime machinery, and nothing enforces it but this sentence.

	  PlayerKilled     -> RespawnSystem (new body), CombatSystem (its own kill-feed remote),
	                      RivalrySystem (standings), BountySystem (auto-claim), MeridianSystem (XP)
	  MeridianXPAwarded-> TierSystem (promotion check)
	  TierChanged      -> QiSystem (recompute the Max Qi ceiling for the new tier)
	  TrainingBotKilled-> TrainingBotSystem (respawn scheduling)
	  TrainingBotDespawned -> TrainingBotSystem, BotCombat (per-bot AI state cleanup)
	  HeartbeatTick    -> QiSystem (passive regen)

	ORDERING. BindableEvents fire subscribers in connection order, which is Main.server.lua's Init()
	order -- but no subscriber above depends on running before or after any other, and new ones should
	keep it that way. Where an ordering dependency is genuinely real, express it as a chain of distinct
	signals (PlayerKilled -> MeridianXPAwarded -> TierChanged below is exactly that: each publisher
	fires only after its own state is already consistent), never as an assumption about boot order.
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
-- Progression
--

-- Fired once per successful Meridian XP grant, AFTER PlayerDataSystem.Transform has already
-- committed the new total to the canonical profile -- so a subscriber reading the profile inside its
-- handler sees `newTotal`, never the pre-award value. A failed award (profile not loaded, invalid
-- amount) fires nothing at all.
--
-- This exists so TierSystem can react to "this player's XP moved" WITHOUT subscribing to
-- PlayerKilled and racing MeridianSystem for the same profile: a kill is not the only thing that can
-- ever move Meridian XP (RewardSystem/AchievementSystem will both grant it), and a promotion check
-- keyed on the kill rather than on the grant would silently miss every one of those future sources.
-- Subscribe to the state change, not to one of the things that causes it.
local meridianXpAwardedSignal = Instance.new("BindableEvent")

function GameplayEvents.FireMeridianXPAwarded(player: Player, amount: number, newTotal: number, reason: string?): ()
	meridianXpAwardedSignal:Fire(player, amount, newTotal, reason)
end

function GameplayEvents.OnMeridianXPAwarded(handler: (
	player: Player,
	amount: number,
	newTotal: number,
	reason: string?
) -> ()): RBXScriptConnection
	return meridianXpAwardedSignal.Event:Connect(handler)
end

-- Fired once per confirmed tier change, after TierSystem has already persisted the new tier. Carries
-- `previousTier` because a single large grant can cross more than one threshold at once (see
-- TierSystem.Evaluate) -- a subscriber that assumes `newTier == previousTier + 1` is wrong, and the
-- payload is shaped so it never has to guess.
--
-- Deliberately a signal rather than TierSystem calling QiSystem directly: Max Qi is priced off tier
-- (QiConstants.MaxQiByTier), so a tier-up MUST raise the ceiling -- but that is Qi's concern to
-- implement, not the tier ladder's to know about. QiSystem.RefreshFromProfile was written for
-- exactly this hook and documents itself as waiting for it. Every future tier-priced system
-- (ArtSystem gating, AbsorbSystem) subscribes here the same way instead of TierSystem growing a
-- require of each one.
local tierChangedSignal = Instance.new("BindableEvent")

function GameplayEvents.FireTierChanged(player: Player, newTier: number, previousTier: number): ()
	tierChangedSignal:Fire(player, newTier, previousTier)
end

function GameplayEvents.OnTierChanged(
	handler: (player: Player, newTier: number, previousTier: number) -> ()
): RBXScriptConnection
	return tierChangedSignal.Event:Connect(handler)
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
