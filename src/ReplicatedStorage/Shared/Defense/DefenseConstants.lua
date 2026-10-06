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
-- For the Evade table, which derives every number from the glide it covers -- see that table.
-- EvadeConstants has no requires of its own, so this cannot form a cycle.
local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)

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

	-- HOW THE OWNING CLIENT'S GUARD READOUT STAYS TRUE (DefenseSystem's syncGuard). The pool changes in
	-- places that are not state transitions -- it REGENERATES every frame, and a blocked hit drains it
	-- while the state stays Blocking -- and those used to reach the HUD only when some unrelated
	-- transition happened to resend the number, so the guard gauge sat wrong for seconds at a time.
	-- Now any change is pushed, at most once per SyncIntervalSeconds, and at once when the pool reaches
	-- empty or full so the end states are never late. The HUD's own spring smooths between pushes.
	SyncIntervalSeconds = 0.2,
	-- Changes smaller than this are not worth a push on their own (they still ride the next one).
	SyncMinDelta = 1,
}

-- Guard cracking -----------------------------------------------------------------------------------

-- THE BREAK YOU CAN SEE COMING. Below EnterFraction of Guard.Max the guard is "cracking": every block
-- throws heavier, hotter sparks, and the blocker's guard pose strains and trembles. Both are the same fact
-- read two ways -- the attacker learns one more hit may break it, the defender learns they are one read
-- from an opening -- which is the tension the posture meter exists to create. Before this, the first
-- visible sign a guard was low was the break itself.
--
-- PUBLISHED, NOT DERIVED BY CLIENTS. The pool is server-only (only the owning client is ever sent its
-- number), so DefenseSystem publishes the crossing as the CollectionService tag below on the Humanoid,
-- which replicates to every client -- the strain pose then reads the same for a spectator as for the two
-- fighters -- and stamps it on each Combat_Feedback so the block's sparks never race the tag.
--
-- A TAG, NOT AN ATTRIBUTE, because the reader needs DISCOVERY: a cracking guard can be a player or a
-- training bot (a Model under Workspace, with no Player to hang a character hook off), and the tag's
-- added/removed signals hand Client/FX/GuardStrainPose.lua exactly the bodies to pose with no scan at
-- all. It gates nothing -- no system reads it to decide anything -- so the "deadlines, not booleans"
-- rule for cross-system GATES does not apply; DefenseSystem re-derives it from the pool every frame, and
-- UnregisterCombatant removes it.
--
-- HYSTERESIS, so a guard regenerating across the line does not flicker the pose on and off: the flag
-- sets below EnterFraction and clears only above ExitFraction. 0.3 is the brief; 0.3 of Guard.Max (100)
-- is 30, which is under two ordinary blocked hits (DrainPerPowerLevel 18) -- the warning arrives with
-- one real decision left, not three.
DefenseConstants.GuardCrack = {
	EnterFraction = 0.3,
	ExitFraction = 0.36,
	Tag = "GuardCracking",
}

-- Every combatant's guard as a fraction of its max, published on this Humanoid Attribute for EVERY client
-- (DefenseSystem's publishGuardFraction). The owner still gets exact numbers on its own remote; this is how
-- an opponent's guard reaches the lock-on marker. Steps is how finely it is quantised before replicating:
-- 20 is a 5% bar step, invisible at the marker's width and at most 20 writes per full regen.
DefenseConstants.GuardFraction = {
	Attribute = "GuardFraction",
	Steps = 20,
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

	-- THE GROUND PARRY'S LAG REWIND -- the air combo's rewind (AirComboConstants.Parry), extended to every
	-- player-backed defender. The window above opens when the press ARRIVES, but the defender pressed
	-- against a swing they saw late: the server started it, it reached their screen a one-way trip (plus
	-- interpolation) later, and their press took another one-way trip back. So a parry timed to the hit
	-- ON THEIR SCREEN arrives after the hit has already landed on the server's clock -- the "I pressed it
	-- in time and it didn't parry" feel. The end refund above cannot fix that: it extends the window's
	-- far side, which forgives an EARLY press, never a late-looking one.
	--
	-- So a Clean contact on a defender with a real round trip waits up to min(round trip, this) before it
	-- applies (DefenseSystem's rewind hold). A press arriving inside that hold is judged at its REWOUND
	-- time -- arrival minus the same amount, never earlier than the release before it -- as the parry, or
	-- on the ground the block, it would have been had it reached the server when it was pressed.
	--
	-- THE COST, stated rather than hidden: against a laggy defender the attacker's hit confirmation
	-- (damage, hitstun, hit feedback) lands up to this much later. Their own swing animation is untouched.
	-- Only contacts a later press could actually change are held (in the block arc, key not already down,
	-- body not committed to a swing or stun), so the delay is never spent where it could not matter.
	--
	-- Tighter than the air combo's 0.2 on purpose: an air-held victim's parry is their ONE way out, so it
	-- is worth a longer confirmation delay there. On the ground every exchange pays this, and 0.12 --
	-- the same ceiling the end refund already trusts ping up to -- covers a typical round trip without
	-- letting a padded ping stall every hit an attacker lands.
	RewindMaxSeconds = 0.12,
}

-- THE PERFECT PARRY. A contact landing within WindowSeconds of the parry window OPENING -- the defender
-- held the press until the last possible moment -- is Perfect: the attacker is staggered for
-- StaggerSeconds instead of Stagger.DurationSeconds, and both clients play a heavier clash (a longer
-- freeze, a camera punch, a brighter burst -- FXConstants.PerfectParry). Skill you can feel, not just a
-- number.
--
-- MEASURED ON THE SERVER'S OWN SUBSTEP CLOCK, the same one the parry itself is judged on: contact
-- SampleTime minus the moment the window went live (DefenseStateMachine.ParryOpenedAt). NO PING REFUND,
-- and that is deliberate, not an omission: the window opens when the press ARRIVES, one-way latency
-- after the player pressed, so the measured interval is already SHORTER than the real press-to-impact
-- interval by that latency. A refund here would subtract from a number that is already in the
-- defender's favour. The refund that matters -- a late press still counting as a parry at all -- stays
-- where it was, on the window's end (Parry.PingCompensationMaxSeconds).
--
-- 0.05 is the brief. The window itself is 0.2 (RegisteredParryWindows), so the perfect band is the first
-- quarter of it: common enough to be a goal, rare enough to mean something.
--
-- StaggerSeconds is FLAGGED in the same spirit Stagger.DurationSeconds is: 1.5 already converts a parry
-- into a full combo, and +0.3 adds roughly one more Basic swing (0.31s windup at WeaponSpeed 1) to it. It
-- extends the punish; it does not create a new one. The whiff lockout it also extends
-- (_parryLockedUntil follows the stagger) is the attacker's, and is correct to extend with it.
DefenseConstants.PerfectParry = {
	WindowSeconds = 0.05,
	StaggerSeconds = DefenseConstants.Stagger.DurationSeconds + 0.3,
}

-- Rally --------------------------------------------------------------------------------------------

-- PARRY TRADING. A parried attacker may parry back: the stagger still forbids attacking and still
-- parks their movement, but it no longer forbids arming a parry, so the parrier's counter can itself
-- be parried and the exchange can go back and forth. Landing a parry out of a stagger ends that
-- stagger on the spot -- you won the exchange -- and staggers the other side in turn. A whiff out of
-- a stagger pays the ordinary whiff lockout and drops straight back into the stagger it came from.
--
-- EACH PARRY IN AN UNBROKEN RALLY SHRINKS THE NEXT WINDOW. Same clip, same opening moment -- only the
-- DURATION (Close - Open) is multiplied by WindowScalePerParry for every parry already traded between
-- the two, down to MinWindowScale. The perfect-parry band shrinks with it, so it stays the same
-- fraction of the window. The ping refund (Parry.PingCompensationMaxSeconds) is NOT scaled: it pays
-- back latency, which does not shrink because the exchange got longer.
--
-- Against the shipped 0.2s window: 0.2 -> 0.16 -> 0.128 -> 0.102 -> 0.082 -> 0.07 (floor).
--
-- A rally is between TWO combatants and lapses after LapseSeconds with no parry between them, or the
-- moment either one takes a clean hit, a backstab or a guard break. Longer than the longest stagger
-- (PerfectParry.StaggerSeconds, 1.8), so a counter thrown at the very end of a punish still counts as
-- the same rally.
DefenseConstants.Rally = {
	ParryFromStagger = true,
	WindowScalePerParry = 0.8,
	MinWindowScale = 0.35,
	LapseSeconds = 2.5,
}

-- Stun parry ----------------------------------------------------------------------------------------

-- PARRYING OUT OF A STRING (2026-10-06). M1s now LINK: a landed Basic stuns until the next one in the
-- string arrives (DamageConstants.Hitstun.LinkBasicString), so a string that keeps its rhythm lands every
-- hit -- the battlegrounds feel. What keeps it from being a free three hits is this rule, the air combo's
-- own (docs/design/air-combat-and-evade.md B4) brought to the ground: while stunned, the guard does
-- NOTHING (a block resolves Clean), an evade is still refused, but a timed parry still counts. A parry
-- landed out of the stun ends the stun on the spot (DamageSystem) and staggers the attacker as usual.
--
-- So answering a string is a read on the NEXT impact, not a gap you are handed between hits. Mashing it
-- fails on its own: a whiffed window pays Parry.RecoverySeconds, which outlasts a link, so one wrong
-- guess eats the rest of the string.
--
-- WindowScale multiplies the window's DURATION exactly as Rally does (and stacks with it): a parry out of
-- a stun is a harder read than one made on a free body, not an equal one. 1 makes them equal; 0 turns
-- the rule off as surely as Enabled = false does.
DefenseConstants.StunParry = {
	Enabled = true,
	WindowScale = 0.75,
}

-- Clash ---------------------------------------------------------------------------------------------

-- TWO SWINGS THAT MEET CLASH (2026-09-30). Before this, two players swinging into each other got one of
-- two answers, and neither read as a trade: both hits landing in the same server frame was a double hit
-- (both stunned, both damaged), and anything else went to whichever hit the server HEARD first -- which is
-- to say the lower-ping player, every time.
--
-- A clash is resolved as the existing "Trade" outcome (OutcomeResolver.ArbitrateClashes): no damage, no
-- stun, no guard change, BOTH swings cancelled, both bodies pushed apart (DamageConstants.Spacing.Clash),
-- a shared hit-stop, and both players keep their place in their string (AttackRequestSystem). Both are
-- free to swing again RecoverySeconds after the contact -- one symmetric beat, rather than each side
-- waiting out whatever was left of the swing that got cut.
--
-- WHEN IT IS A CLASH -- and this is deliberately NOT a time window. Two Clean melee contacts:
--   * in ONE batch (one server frame) that are mutual -- each one's attacker is the other's defender; or
--   * a Clean melee contact on a defender whose own swing is in its ACTIVE window with a volume that
--     already reaches the attacker (within ReachMarginStuds -- HitboxEngine.ActiveSwingReaches).
-- A defender still WINDING UP loses, however close. That is load-bearing: a defender mashing out of
-- hitstun is ~0.06s from Active when the attacker's next M1 lands (the M1 read is tuned to sit just
-- under the weapon's own windup -- see DamageConstants.Hitstun), so any time window wide enough to be
-- felt would turn every mash-out into a clash and hand the defender a free escape from the string.
-- "Both blades are out and reach each other" is the rule that cannot do that.
--
-- Projectiles never clash (a shot is answered on the shot), and neither does anything in an air combo.
DefenseConstants.Clash = {
	Enabled = true,
	-- Slack on the defender's live volume, in studs, on top of the engine's own narrow-phase margin: a
	-- blade a hair short of the attacker is still a blade meeting one.
	ReachMarginStuds = 1,
	-- Seconds after the contact until either side may swing again. Longer than the push apart lasts
	-- (DamageConstants.Knockback.HoldSeconds), so the next swing is thrown from the new spacing.
	RecoverySeconds = 0.25,
}

-- Evade ---------------------------------------------------------------------------------------------

-- THE EVADE'S FRAMES. A contact landing inside the window resolves to OutcomeKind "Evaded" -- no damage,
-- no guard change, no stun -- regardless of bearing. Opened by DefenseSystem.BeginEvade, which the
-- composition root calls when ParkourSystem accepts an Evade start (Main.server.lua), so the trigger is
-- the evade report the client already sends and no remote was added for it.
--
-- A FIXED SHAPE, NOT A CLIP'S MARKERS, and that is consistent with this file's own rule rather than an
-- exception to it: the parry window lives on an asset because the parry IS its animation. The evade is a
-- glide with no required clip at all (EvadeConstants.AnimationIds are optional), so there is no asset
-- whose keyframes could be the authority.
--
-- DERIVED, NOT RESTATED: every number comes from Shared/Combat/EvadeConstants.lua, which owns the glide
-- these frames cover. Retuning the glide retunes the frames with it; two independently-authored copies
-- would drift the first time one was tuned.
--   startup   -- vulnerable (0 today: a press anywhere in an opponent's windup covers the hit).
--   active    -- evading. Outlasts the glide, so the whole move is covered.
--   recovery  -- vulnerable again. Nothing to author: the glide is over by then, and ParkourOwnership
--                refuses attacks and guards for as long as the evade report is open.
DefenseConstants.Evade = {
	StartupSeconds = EvadeConstants.Frames.StartupSeconds,
	ActiveSeconds = EvadeConstants.Frames.ActiveSeconds,
	-- The server opens the window when the report ARRIVES, one-way latency after the player pressed -- the
	-- same double charge the parry refunds, refunded the same way and under the same cap. Extends the END
	-- only; a refund that also opened the window early would let a high-ping evade start before it began.
	PingCompensationMaxSeconds = EvadeConstants.Frames.PingCompensationMaxSeconds,
	-- Minimum gap between two accepted evades: the client's cooldown minus a jitter tolerance.
	CooldownSeconds = math.max(EvadeConstants.CooldownSeconds - EvadeConstants.ServerCooldownToleranceSeconds, 0),
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

-- THE PARRY WAS NEVER ARMED IN PLAY, and this table is the fix (2026-09-28). ParryWindows fails closed:
-- an animation id with no ParryStart/ParryClose markers and no registration gets NO window, so every
-- block press just blocks. The clip above carries no marker pair that anything in code can verify, and
-- ParryWindows' own header says registrations exist precisely "because there are no parry clips yet at
-- all" -- but none was ever written. So the parry, the Parried outcome, the attacker stagger and the
-- parry clash hit-stop were all unreachable.
--
-- Registered windows, per animation id, in seconds from the PRESS: the parry is live from Open to Close,
-- and a whiff is punished until RecoveryEnd (omitted -> Close + Parry.RecoverySeconds). DefenseSystem.Init
-- registers these before its boot validation. This is ParryWindows' "Registered" source, not the
-- forbidden default: per-id, hand-written, greppable -- and authored markers on the clip OUTRANK it, so
-- the day the animator adds ParryStart/ParryClose, the clip's own timing takes over and the boot
-- validation reports this entry as shadowed (delete it then).
--
-- 0.2s: generous enough to be a learnable read at real ping (ParryWindows.ParryEndFor refunds up to
-- another Parry.PingCompensationMaxSeconds on top), tight enough that it is a timing and not a block.
-- A starting value -- tune in Studio with ParryWindows.Override, then write the number back here.
DefenseConstants.RegisteredParryWindows = {
	[DefenseConstants.ParryAnimationId] = { Open = 0, Close = 0.2 },
} :: { [string]: { Open: number, Close: number, RecoveryEnd: number? } }

-- CLIENT-SIDE PRESENTATION ONLY, unlike ParryAnimationId above: the server never reads this id or
-- cares how long it plays, since nothing about parry timing lives in it (no ParryStart/ParryClose/
-- ParryRecoveryEnd markers expected or checked here). DefenseClient.lua plays ParryAnimationId ONCE,
-- non-looped, on a press predicted to ARM a parry -- that clip's own markers are still what arms the
-- server's parry window -- and hands off to this one, looped, when the parry window closes (or the clip
-- ends, if sooner), for as long as the block key stays held. A press predicted to only BLOCK plays this
-- one straight away, with no swing-up: the swing-up is the "this press is a parry" tell, so it plays
-- only when that is true (Client/Defense/ParryPrediction.lua, corrected by the server's verdict).
DefenseConstants.BlockHoldAnimationId = "rbxassetid://103128038437125"

-- Client-side presentation only (DefenseClient.lua) -- how long the block/parry pose crossfades in
-- and out on press/release, and how the parry-to-hold handoff above blends. Not read by the server:
-- the server's timing authority is ParryAnimationId's own markers, never how long any LOCAL blend
-- takes.
DefenseConstants.Presentation = {
	-- The parry-to-hold handoff and the fade out on release.
	BlockAnimationFadeSeconds = 0.15,
	-- The fade IN on the key edge -- the first clip of a press, the parry swing-up or the plain guard.
	-- Separate from the handoff fade, and much shorter, because it is the latency the player feels: at
	-- 0.15 a guard spent most of a 0.2s parry window still blending up from the idle, so the pose read as
	-- late even when the server had the guard up on arrival. Short enough to read as instant, long enough
	-- not to pop.
	PressFadeInSeconds = 0.05,
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
