--!strict
--[[
	DefenseConstants.lua

	Owns: the Defense System's tunables. Standalone, and deliberately NOT a section of
	Shared/Constants.lua -- the same choice HitboxEngineConstants.lua makes and for the same reason:
	this system is a module, and a module that can be added or removed without editing the game's
	central constants table is the concrete form of that claim. The one exception is
	DefenseStateAttribute below, which aliases onto Constants.Attributes.DefenseState rather than
	duplicating the literal -- see that field's own header for why.

	THERE IS NO PARRY WINDOW LENGTH IN THIS FILE, and its absence is the point. A parry's timing comes
	from markers authored on the animation asset (Shared/Defense/ParryWindows.lua), so retiming a parry
	is retiming the animation and nothing else. The values here are the ones no animation could
	define: an arc is geometry, a guard pool is a resource, a punish length is a balance decision.

	The distinction the whole design rests on: a value belongs in this file only if there is no clip
	whose keyframes could be its authority. Anything that fails that test belongs on the asset.

	Does not own: window timing (ParryWindows.lua), any damage number (nothing in this system applies
	damage), or the engine's own tunables (HitboxEngineConstants.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Only reference into Shared/Constants.lua this file makes: DefenseStateAttribute below is an alias
-- onto Constants.Attributes.DefenseState, not a second definition of the string -- see that field's
-- own header.
local Constants = require(ReplicatedStorage.Shared.Constants)

local DefenseConstants = {}

-- Geometry -----------------------------------------------------------------------------------------

-- Total width of the block arc, centred on the defender's facing. A hit arriving within
-- BlockArcDegrees/2 of dead ahead can be blocked; outside it the block does not apply.
--
-- 120 (so +/-60) is a deliberate middle: wide enough that blocking does not demand precise aim
-- against a single attacker, narrow enough that it cannot cover two attackers approaching from
-- opposite flanks. A value at or above 180 would make the rear-hemisphere rule below unreachable and
-- turn the whole directional layer off, which is why the two numbers are documented together.
DefenseConstants.BlockArcDegrees = 120

-- Past this bearing the attacker is BEHIND the defender, and a block does nothing at all
-- (OutcomeKind "Backstab"). 90 makes "behind" mean the literal rear hemisphere rather than a tuned
-- cone -- there is no reading of "struck from behind" that a player would disagree with at exactly
-- perpendicular, and inventing a number between the arc edge and 90 would create a third band with
-- no name.
--
-- Between BlockArcDegrees/2 and this lies the flank: unblocked, but not a backstab. An ordinary
-- clean hit, because you were not covering that side.
DefenseConstants.RearHemisphereDegrees = 90

-- Guard --------------------------------------------------------------------------------------------

DefenseConstants.Guard = {
	-- The pool a blocked hit spends. Arbitrary units on purpose: nothing outside this system reads
	-- the number, and expressing it as a percentage would invite a HUD to assume a percentage.
	Max = 100,

	-- Guard spent per blocked hit, per unit of the attack's PowerLevel (which the engine already
	-- carries on every HitReport). A PowerLevel-1 hit costs this; a PowerLevel-3 heavy costs triple.
	--
	-- 18 means a full guard absorbs five ordinary hits, or fewer under the stagger multiplier below.
	-- Sized so that turtling is a viable answer to one exchange and a losing answer to a sustained
	-- one, which is the whole intent of having a meter rather than free blocking.
	DrainPerPowerLevel = 18,

	-- Guard regained per second once regeneration is allowed.
	RegenPerSecond = 22,

	-- How long after the last blocked hit regeneration stays suppressed. Without this, guard would
	-- refill between the hits of a combo and the meter would never meaningfully deplete.
	RegenDelaySeconds = 1.2,

	-- Guard restored by a successful parry. THE incentive gradient of the whole system: parrying is
	-- better than blocking, blocking is better than eating it, and the reward for the hard option is
	-- the resource that pays for the easy one.
	--
	-- Deliberately larger than one hit's drain, so a parry inside a blocked combo is a genuine
	-- recovery rather than a break-even.
	ParryRestore = 35,

	-- A trade grants neither the restore nor a drain -- see DefenseSystem's arbitration. Recorded
	-- here as a named zero rather than an implicit one so the intent is greppable: two players with
	-- depleted guards must not be able to parry each other on purpose to refill.
	TradeRestore = 0,
}

-- Punish -------------------------------------------------------------------------------------------

DefenseConstants.Stagger = {
	-- How long a parried attacker cannot attack and cannot parry. From the brief.
	--
	-- FLAGGED, BECAUSE THIS NUMBER HAS HISTORY. The previous combat design's equivalent
	-- (Constants.Combat's GuardOpenSeconds, now retired -- the derivation is preserved at its old
	-- site in Constants.lua) was 0.6, and it was derived rather than guessed: sized to
	-- cover reaction plus one-way latency plus the slowest weapon's own windup (Primary Basic1,
	-- WindupSeconds 0.31) so the parrier got EXACTLY ONE guaranteed follow-up. That comment also
	-- recorded a hard UPPER bound near 0.75, past which a Secondary user's second swing also lands
	-- inside the window -- "a combo handed out for one read rather than a conversion."
	--
	-- 1.5 is double that bound, so a parry here converts into a full combo rather than a single
	-- punish. That is a deliberate design choice from the brief, not an oversight, and it is one
	-- constant to change if it plays too strong. Worth re-measuring once real attacks exist.
	DurationSeconds = 1.5,

	-- Blocking while staggered is ALLOWED (the brief is explicit) but must not be free, or the punish
	-- is hollow -- which the previous design measured directly and said so. Three costs, all applied
	-- only while Staggered:
	--
	--   * guard does not regenerate at all,
	--   * blocked hits drain at this multiple of the ordinary rate,
	--   * mitigation is reduced (published for the damage layer -- nothing here applies damage).
	--
	-- So a parried attacker who turtles through the punish spends their guard doing it and comes out
	-- one hit from a break. They kept the option and it still cost them the exchange.
	--
	-- Tuned against DurationSeconds above: at 1.5s and this multiplier, a full guard does not survive
	-- a sustained follow-up. If DurationSeconds drops to the derived 0.6, this wants lowering with
	-- it, or the counterweight becomes a guaranteed guard break rather than a cost.
	GuardDrainMultiplier = 1.75,

	-- Fraction of normal damage reduction a staggered block provides. Published on the outcome for a
	-- future damage layer; this system reads it only to pass it on.
	MitigationMultiplier = 0.5,
}

-- How long a guard break locks the defender out of blocking. A real opening -- the reason the meter
-- is worth tracking at all.
DefenseConstants.GuardBrokenSeconds = 1.0

-- Parry --------------------------------------------------------------------------------------------

DefenseConstants.Parry = {
	-- Fallback for a whiffed parry's recovery when the window carries no ParryRecoveryEnd -- an asset
	-- whose extraction failed outright (no KeyframeSequence, so no clip length either), or a
	-- ParryWindows.Register call that omitted it.
	--
	-- This is a constant and that is consistent, not a loophole: a recovery is a PUNISH LENGTH, a
	-- balance decision with no animation defining it, exactly like Stagger.DurationSeconds above.
	-- The rule this system enforces is that a parry WINDOW may never come from a constant, and this
	-- is not one.
	RecoverySeconds = 0.45,

	-- THE ANTI-TURTLE COST, and it closes a hole the plan's own state graph opens.
	--
	-- Holding block and re-tapping is otherwise free: a held press lands in Blocking, releasing
	-- returns to Neutral, and pressing again arms a fresh window at no cost -- so a player could hold
	-- guard permanently and re-arm a parry as fast as they can tap, which is continuous mitigation
	-- with a free parry on top. The previous design priced exactly this and called it the dominant
	-- strategy (Constants.Combat.GuardResetSeconds, 0.3, charged on release).
	--
	-- So: to ARM a parry, the defender must have been out of Blocking for this long. A press sooner
	-- than that still blocks -- it goes straight to Blocking, skipping the window -- rather than
	-- being refused. Fail-soft on purpose: the player never loses their guard for pressing too
	-- early, they only lose the parry, which is the thing that was being farmed.
	--
	-- ParryRecovery does not cover this case. It is entered only when a window closes with no hit AND
	-- the input was released, so a player who holds through every window never pays it.
	MinUnguardedSeconds = 0.3,

	-- Ceiling on the latency refund added to a parry window (see ParryWindows.Compensate). Moved here
	-- from Constants.Combat.ParryPingCompensationMaxSeconds, which is being retired with the rest of
	-- the deleted system's parry config.
	--
	-- The server opens its window when the request ARRIVES, which is already one-way latency after
	-- the player pressed, so a high-ping player is paying for their connection twice. This refunds
	-- min(ping, cap). Capped because ping is client-influenced and an uncapped refund is a permanent
	-- parry for anyone willing to lie about it.
	PingCompensationMaxSeconds = 0.12,
}

-- Animation ------------------------------------------------------------------------------------------

-- The clip every combatant registered without their own ParryAnimationId uses (DefenseSystem.
-- RegisterCombatant's default-parry-animation path -- see DefenseSystem.SetDefaultParryAnimation).
-- Lives here rather than in Constants.Combat.AnimationIds because that table is READ GENERICALLY by
-- Client/FX/CombatAnimator.lua's BindCharacter loop (every entry in it gets a template built and
-- loaded as a LOCOMOTION track) -- see that table's own header on being scoped to Walking/Running/
-- RunningStage2 since the combat teardown. Adding a non-locomotion id there would get it loaded and
-- ignored by the wrong module. This system already owns its own tunables file for exactly this
-- "a module's data shouldn't leak into an unrelated one" reason -- see this file's own header.
--
-- USER-SUPPLIED. Not yet authored with ParryStart/ParryClose/ParryRecoveryEnd markers as far as this
-- system can verify from code -- ParryWindows.ValidateAll (run at DefenseSystem.Init from
-- Main.server.lua) warns at boot if the asset carries no marker pair, per the fail-closed rule in
-- docs/design/parry-block-system-plan.md: a press still blocks, it just never arms a parry window
-- until the markers exist.
DefenseConstants.ParryAnimationId = "rbxassetid://94883396723007"

-- CLIENT-SIDE PRESENTATION ONLY, unlike ParryAnimationId above: the server never reads this id or
-- cares how long it plays, since nothing about parry timing lives in it (no ParryStart/ParryClose/
-- ParryRecoveryEnd markers expected or checked here). DefenseClient.lua plays ParryAnimationId ONCE,
-- non-looped, on press -- that clip's own markers are still what arms the server's parry window --
-- and chains into this one, looped, the instant the parry clip finishes (AnimationManager's
-- OnFinished "Completed" reason), for as long as the block key stays held. So a block press always
-- shows the parry swing-up first and settles into a held guard pose, whether or not anything was
-- actually parried; the OUTCOME was already decided server-side by the time this plays at all.
DefenseConstants.BlockHoldAnimationId = "rbxassetid://103128038437125"

-- Client-side presentation only (DefenseClient.lua) -- how long the block/parry pose crossfades in
-- and out on press/release, and how the parry-to-hold handoff above blends. Not read by the server:
-- the server's timing authority is ParryAnimationId's own markers, never how long any LOCAL blend
-- takes.
DefenseConstants.Presentation = {
	BlockAnimationFadeSeconds = 0.15,
}

-- Budgets ------------------------------------------------------------------------------------------

-- Ceiling on contacts buffered for one frame's arbitration. Reaching it means an implausible number
-- of simultaneous hits on one server frame; past it, contacts are dropped rather than allowed to make
-- an already-bad frame worse. Same "bound the worst case instead of letting it scale with load"
-- reasoning as HitboxEngineConstants.MaxActiveSwings.
DefenseConstants.MaxPendingContactsPerFrame = 128

-- Integration --------------------------------------------------------------------------------------

-- Humanoid Attribute mirroring the defender's live DefenseState, as a string. Nothing in THIS system
-- gates on it -- but something outside it now does, so it is no longer purely informational and must
-- not be renamed or made lossy on that assumption: Server/Systems/RunSystem.lua reads anything other
-- than "Neutral" as "a combat action is committing this body" and forces the run's stage and charge to
-- zero for the duration. See Constants.Attributes.CombatBusyUntil, its counterpart for the attack
-- side, for the whole contract. It exists because Humanoid Attributes replicate to every client
-- for free, so the HUD -- and any future spectator or debug tooling -- can read what a remote
-- character is doing without this system adding a broadcast remote of its own. Same shape and same
-- reasoning as Constants.Attributes.ParkourState. Aliased onto Constants.Attributes.DefenseState
-- rather than a second literal, now that RunSystem.lua also reads this Attribute by name.
DefenseConstants.DefenseStateAttribute = Constants.Attributes.DefenseState

DefenseConstants.Network = {
	RemoteNames = {
		-- Client -> server, the block/parry input edge. One remote carrying a boolean rather than
		-- two remotes, because press and release are the same decision observed twice and splitting
		-- them would let one arrive without the other.
		SetBlocking = "Defense_SetBlocking",
		-- Server -> defending client, fired when a state transition happens that the client could not
		-- have predicted (a parry landing, a stagger, a guard break). The client predicts its own
		-- press locally for feel; this is the correction and the confirmation.
		StateChanged = "Defense_StateChanged",
	},
	-- Press/release is a human-speed input. Generous enough that a fast tapper is never throttled,
	-- tight enough that a spamming client cannot make this a cost centre.
	MaxCallsPerSecondPerPlayer = 12,
}

-- Debug --------------------------------------------------------------------------------------------

DefenseConstants.Debug = {
	-- Master switch for this system's per-contact logging. Off by design -- a busy fight resolves
	-- many contacts a second and anything logged per contact is its own performance problem.
	Enabled = false,
	-- Logs one line per resolved outcome. Requires Enabled.
	LogOutcomes = true,
	-- Logs one line per state transition. Requires Enabled.
	LogTransitions = false,
}

return DefenseConstants
