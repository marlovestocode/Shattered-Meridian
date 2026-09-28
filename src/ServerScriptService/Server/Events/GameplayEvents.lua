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

	It is also what keeps progression OUT of combat and death confirmation. When a progression system
	needs a new fact about a kill, the correct change is a new field on this file's payload (PlayerKilled's
	deathId is exactly that) -- never a new `require` inside the publisher (PlayerDeathSystem, or the
	combat stack beneath it), and never a call from either outward into progression.

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

	  PlayerKilled     -> published ONLY by PlayerDeathSystem. RespawnSystem (new body), RewardSystem
	                      (the fight-to-grow spine: RewardSystem -> ProgressionSystem -> MeridianSystem),
	                      RivalrySystem (standings), BountySystem (streaks/claim), BloodlineSystem
	                      (interim stage-advancement dispatch, not yet routed through the spine),
	                      BlimpSystem/BoatSystem (dismount the dead), EmoteSystem (stop a dying emote)
	  MeridianXPAwarded-> TierSystem (promotion check)
	  TierChanged      -> QiSystem (recompute the Max Qi ceiling for the new tier),
	                      RaceSystem (recompute Bound trait effects)
	  QiSpent          -> QiDeviationSystem (deviation risk accrual/decay)
	  BloodlineAwakened-> (no subscriber yet -- carried for a future notification/achievement hook)
	  CombatLogged     -> (no subscriber yet -- EngagementSystem reports the fact, nothing punishes it)
	  TrainingBotKilled-> TrainingBotSystem (respawn scheduling)
	  TrainingBotDespawned -> TrainingBotSystem, BotCombat (per-bot AI state cleanup)
	  HeartbeatTick    -> QiSystem (passive regen), BountySystem (notoriety decay), EffectSystem
	                      (expired-modifier reclaim), EmoteSystem (active-emote monitor),
	                      BlimpSystem (hull physics/fuel step), VehicleManager (live-vehicle sweep)

	ORDERING. BindableEvents fire subscribers in connection order, which is Main.server.lua's Init()
	order -- but no subscriber above depends on running before or after any other, and new ones should
	keep it that way. HeartbeatTick is the one signal that is NOT a BindableEvent (see its own comment
	below) and its handler table is `pairs`-traversed, so its subscribers run in no defined order at
	all -- which is the same promise, stated more honestly. Where an ordering dependency is genuinely real, express it as a chain of distinct
	signals (PlayerKilled -> [RewardSystem -> ProgressionSystem -> MeridianSystem, direct calls] ->
	MeridianXPAwarded -> TierChanged below is exactly that: each publisher
	fires only after its own state is already consistent), never as an assumption about boot order.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)

local GameplayEvents = {}

-- The one thing in this file that is not a signal. Used solely to report a subscriber that threw
-- inside the shared tick's direct loop -- see FireHeartbeatTick. Requiring Logger keeps this module's
-- "no dependency on any System, safe to require from anywhere" promise intact: Shared/Logger.lua has
-- no Init(), no boot order and no System dependency of its own.
local logger = Logger.scope("GameplayEvents")

--
-- Player lifecycle
--

-- Fired exactly once per confirmed player death, by Server/Systems/PlayerDeathSystem.lua and nothing
-- else, after that module's own per-life state is already consistent.
--
-- `killer` is nil for any death PlayerDeathSystem did not attribute -- a fall or the void with no
-- fresh blow behind it, a non-player's hit, or a self-inflicted one. That is deliberate and load-
-- bearing rather than an edge case: EVERY death is confirmed through one Humanoid.Died handler
-- regardless of cause, so a subscriber that only cares about PvP must check `killer` itself rather
-- than assuming this only fires for combat deaths. RespawnSystem depends on exactly that breadth -- a
-- player who falls into the void still needs a new body. A non-nil killer is always a different,
-- still-present Player who removed health from this life within DamageConstants.KillCredit's window
-- -- see PlayerDeathSystem's header for the whole rule.
--
-- `deathId` is this fact's identity: unique and increasing for the server's lifetime. It exists for
-- the one kind of subscriber that must never act twice on a single death (RewardSystem grants
-- progression from it) -- (victim, killer) alone cannot tell a replayed fact from a second, genuine
-- kill of the same victim by the same killer. Subscribers with no such need simply ignore it.
local playerKilledSignal = Instance.new("BindableEvent")

function GameplayEvents.FirePlayerKilled(victim: Player, killer: Player?, deathId: number): ()
	playerKilledSignal:Fire(victim, killer, deathId)
end

function GameplayEvents.OnPlayerKilled(
	handler: (victim: Player, killer: Player?, deathId: number) -> ()
): RBXScriptConnection
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

-- Fired once per successful QiSystem.Spend -- never for a refund, and never for a spend that was
-- refused (QiSystem.Spend returns false and fires nothing in that case). `remaining`/`max` are the
-- POST-spend values, so a subscriber never has to re-derive "how close to empty did this leave
-- them" from `amount` alone.
--
-- Deliberately a signal rather than QiSystem calling QiDeviationSystem directly: QiSystem's own
-- header refuses to own Deviation risk/trigger/consequence, and the payload here carries only raw
-- facts (what was spent, what's left) -- what counts as "overreach" and what a Deviation costs are
-- entirely QiDeviationSystem's/QiDeviationConstants.lua's business, per this file's own "carries
-- facts, not meaning" contract.
local qiSpentSignal = Instance.new("BindableEvent")

function GameplayEvents.FireQiSpent(player: Player, amount: number, remaining: number, max: number, reason: string?): ()
	qiSpentSignal:Fire(player, amount, remaining, max, reason)
end

function GameplayEvents.OnQiSpent(handler: (
	player: Player,
	amount: number,
	remaining: number,
	max: number,
	reason: string?
) -> ()): RBXScriptConnection
	return qiSpentSignal.Event:Connect(handler)
end

-- Fired once per successful BloodlineSystem.Awaken -- AFTER PlayerDataSystem.Transform has already
-- committed bloodlineIds/bloodlineStageProgress together (BloodlineSystem.Awaken's own header on why
-- those two fields are written in one Transform, never one without the other), the same "fires only
-- once state is already consistent" shape MeridianXPAwarded above establishes. A refused Awaken
-- (already awakened, unknown bloodline, profile not loaded) fires nothing.
--
-- No subscriber yet -- carried for a future notification/achievement hook, the same "publish the fact,
-- let interested Systems decide their own response" reasoning this file's own header gives throughout.
local bloodlineAwakenedSignal = Instance.new("BindableEvent")

function GameplayEvents.FireBloodlineAwakened(player: Player, bloodlineId: string, reason: string?): ()
	bloodlineAwakenedSignal:Fire(player, bloodlineId, reason)
end

function GameplayEvents.OnBloodlineAwakened(
	handler: (player: Player, bloodlineId: string, reason: string?) -> ()
): RBXScriptConnection
	return bloodlineAwakenedSignal.Event:Connect(handler)
end

-- Fired when a player disconnects while their combat tag is still live (Server/Combat/Engagement/
-- EngagementSystem.lua). `opponentName` is the last combatant they exchanged with; `opponentUserId`
-- is nil when that opponent was not a Player, and also when the opponent had ALREADY left -- see
-- EngagementSystem's PlayerRemoving scrub, which drops a departed player's UserId from every other
-- engagement while leaving the name intact.
--
-- A FACT, NOT A PUNISHMENT, and the distinction is the reason this is a signal at all rather than a
-- method call. Whether combat logging deserves a penalty -- and whether that penalty is a persisted
-- record, a respawn delay, or a standings hit -- is a design decision belonging to whichever System
-- eventually makes it, exactly as this file's header describes. EngagementSystem publishes and warns
-- (which reaches the F5 Live Console capture ring) and does nothing else. NOTHING SUBSCRIBES TODAY,
-- and that is the deliberate state, not an unfinished wire.
local combatLoggedSignal = Instance.new("BindableEvent")

function GameplayEvents.FireCombatLogged(player: Player, opponentName: string, opponentUserId: number?): ()
	combatLoggedSignal:Fire(player, opponentName, opponentUserId)
end

function GameplayEvents.OnCombatLogged(
	handler: (player: Player, opponentName: string, opponentUserId: number?) -> ()
): RBXScriptConnection
	return combatLoggedSignal.Event:Connect(handler)
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

-- Fired every server frame, so a server-internal System that needs per-frame work can piggyback one
-- shared RunService.Heartbeat connection instead of opening a second one -- performance-
-- optimization.md's server-tick-discipline guidance.
--
-- Subscribe sparingly and keep handlers O(1)-per-entity: everything connected here runs inside the
-- server's per-frame budget, and there is deliberately no scheduler or priority band yet. Once the
-- number of subscribers or the per-tick entity count grows (the audit flags ~20 NPCs as the point
-- worth revisiting), this is the seam a TickScheduler with priority bands would slot into, without
-- any subscriber changing.
--
-- Self-pumped (below), not fired by a caller: this used to fire at the end of CombatSystem's own
-- Heartbeat loop, which made this module's own "no dependency on any System, safe to require from
-- anywhere" header claim quietly false for this one signal -- remove CombatSystem (as happened when
-- the combat system was cut) and every subscriber (QiSystem's passive regen, BountySystem,
-- EmoteSystem's active-emote monitor) silently stops ticking with no error anywhere. Owning the
-- RunService.Heartbeat connection here instead is what actually keeps the "neutral hub, no System
-- dependency" promise -- see this file's own header.
-- THE ONE SIGNAL HERE THAT IS NOT A BindableEvent, and the reason this file's MECHANISM note above
-- says a change of mechanism must not touch call sites.
--
-- Every other signal in this module fires when something HAPPENS -- a death, a despawn -- a few times
-- a minute at most, where a BindableEvent's cost is invisible and its per-connection thread isolation
-- is free safety. This one fires sixty times a second, forever, to six subscribers. Under the engine's
-- default Deferred signal behaviour (this project sets no SignalBehavior, so the default applies) that
-- is six deferred resumptions enqueued and drained every frame for handlers that between them do a few
-- hundred table reads. A plain table walked in a loop does the same work with none of the scheduling.
--
-- Keyed by a fresh throwaway table rather than an array, the same idiom Shared/Logger.lua's own
-- entryListeners uses and for the same two reasons: the key is an unforgeable token to unsubscribe by,
-- and `pairs` traversal stays well-defined when a handler unsubscribes itself mid-tick (Lua permits
-- setting an EXISTING field to nil during traversal, which is exactly what unsubscribing does). Adding
-- a subscriber from inside a tick is the case that would not be well-defined -- no subscriber does,
-- they all connect once from their own Init().
local heartbeatHandlers: { [{}]: (deltaTime: number) -> () } = {}

-- Individually pcall-wrapped, which is not defensive padding -- it is what preserves the one property
-- the BindableEvent was giving for free. Each connection used to run on its own deferred thread, so a
-- subscriber that errored took only itself down; in a direct loop an unguarded error would abort every
-- subscriber after it in the walk, every frame, and the resulting "QiSystem stopped regenerating"
-- would point nowhere near the System that actually threw. The warn is rate-limited by Logger's own
-- per-message limiter, so a handler erroring every frame reports at a readable rate rather than
-- becoming the flood.
--
-- Handlers run SYNCHRONOUSLY inside the Heartbeat step now, in registration (i.e. boot) order, rather
-- than at the next resumption point. No subscriber depends on the deferral -- all six are pure
-- per-frame sweeps with no yield anywhere in them, which is the precondition for this change and the
-- thing to re-check before adding a seventh. A handler that yields would stall every subscriber
-- behind it AND the Heartbeat step itself.
function GameplayEvents.FireHeartbeatTick(deltaTime: number): ()
	for _, handler in pairs(heartbeatHandlers) do
		local ok, errorMessage = pcall(handler, deltaTime)
		if not ok then
			logger:error("Heartbeat tick subscriber errored", { errorMessage = tostring(errorMessage) })
		end
	end
end

-- Returns an unsubscribe function rather than an RBXScriptConnection, since there is no longer a
-- connection to hand back. Idempotent, so a caller that tears down twice (an idempotent re-Init, say)
-- does not have to track whether it already has.
function GameplayEvents.OnHeartbeatTick(handler: (deltaTime: number) -> ()): () -> ()
	local token = {}
	heartbeatHandlers[token] = handler
	return function()
		heartbeatHandlers[token] = nil
	end
end

game:GetService("RunService").Heartbeat:Connect(function(deltaTime: number)
	GameplayEvents.FireHeartbeatTick(deltaTime)
end)

return GameplayEvents
