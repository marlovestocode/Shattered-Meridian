--!strict
--[[
	AttackConstants.lua

	Owns: the Attack layer's tunables. Standalone, and deliberately NOT a section of
	Shared/Constants.lua -- the same choice DefenseConstants.lua, HitboxEngineConstants.lua and
	DamageConstants.lua all make, and for the same reason: this system is a module, and a module that
	can be added or removed without editing the game's central constants table is the concrete form of
	that claim.

	THERE IS NO PER-MOVE NUMBER IN THIS FILE, and its absence is the point, exactly as it is in
	DamageConstants. How long a move winds up for, how long it stays active, how much it hurts and how
	long it locks its own reuse are all authored PER MOVE in the Move Creation System and reach this
	layer through AttackCatalog. A windup or a cooldown in here would be a second authority competing
	with the Move Editor, and the editor would lose silently.

	What IS here is the set of values no single move could define, because each describes the
	RELATIONSHIP between presses rather than any one attack: how long a string stays connected between
	presses, how deep a landed combo has to be before the finisher unlocks, how long a refused press is
	remembered, and how loudly the local client is allowed to react before the server has answered.

	Does not own: per-move geometry/damage/timing (the Move Creation System), hitstun or combo-window
	length (DamageConstants -- this layer reads that file rather than restating it), stagger (
	DefenseConstants), or anything about contact detection (HitboxEngineConstants).
]]

local AttackConstants = {}

-- Strings ---------------------------------------------------------------------------------------

AttackConstants.Sequence = {
	-- How long after a thrown swing's own commitment ENDS the next press still continues the same
	-- string. Press again inside this and you get stage 2; wait longer and you start from stage 1.
	--
	-- MEASURED FROM THE END OF THE SWING, NOT THE START, and that is load-bearing rather than a nicety.
	-- Measured from the start, this number would have to exceed the longest authored swing before it
	-- granted a player any grace at all -- and the Primary Heavy string's first stage occupies the
	-- engine for 1.37s (0.6 windup + 0.22 active + 0.55 recovery), so a 1.2s start-relative window
	-- would have lapsed BEFORE its owner could legally throw stage 2. Heavy 2 would have been
	-- unreachable in play, silently, with every individual number looking reasonable on its own.
	-- End-relative, this reads as what it actually means: how long you may dawdle once you have
	-- control back, independent of how long the move you just threw happened to take.
	--
	-- THROW-BASED, NOT LANDING-BASED, and that distinction is the whole reason this number is not
	-- DamageConstants.Combo.WindowSeconds (0.9). This one keeps the *animation string* cycling so a
	-- player who whiffs still sees their three-hit combo play out; that one gates *escalation* and
	-- only ever moves on a hit that actually landed. Conflating them is the mistake the deleted
	-- the deleted CombatTypes' own basicSwingIndex/basicComboLanded split existed to avoid.
	--
	-- Deliberately LONGER than the combo window: whiffing should not feel like being reset, while
	-- failing to connect genuinely should cost escalation.
	ResetSeconds = 1.2,

	-- A deliberate beat between one stage of a string and the next, ON TOP OF the move's own authored
	-- RecoverySeconds.
	--
	-- WHY THIS IS NOT JUST MORE RECOVERY. RecoverySeconds is per-move and belongs to the move: it is
	-- how long THAT swing takes to put away, authored in the Move Editor alongside its windup and its
	-- active window, and lengthening it changes that move everywhere it appears -- including as a
	-- one-off hotbar cast. This is a property of CHAINING, not of any move: it is the pause between
	-- links, so a string reads as a sequence of distinct hits rather than one continuous blur, and it
	-- exists in exactly one place instead of being smeared across every stage's authored recovery.
	--
	-- IT COSTS THE PLAYER NOTHING IN FEEL, because a press made during it is buffered (Input.
	-- BufferSeconds, comfortably longer than this) and fires the instant the beat ends. The player
	-- presses at whatever rhythm they like; the pause shapes what comes OUT, not what goes in.
	--
	-- DROPPED TO 0.01 FROM 0.20 -- a deliberate, verified retune (not a placeholder, not a bug to
	-- correct back): the 0.20 beat that "just a little slower" landed on read as a hitch rather than a
	-- deliberate pace once actually played, and the ask flipped to "a lot smoother" instead. 0 was not
	-- used in its place because this constant is still what SwingSequencer keys ChainReadyAt off of --
	-- a real, if imperceptible, positive number keeps that timestamp meaningfully AFTER the swing that
	-- set it (see SwingSequencer.Advance) rather than collapsing chain-readiness and swing-end into the
	-- exact same instant, which is the kind of equality a floating-point clock should never be asked to
	-- resolve. 0.01s has no perceptible effect on pacing -- Input.BufferSeconds already absorbs it, see
	-- below -- while keeping the ordering real.
	--
	-- TWO RELATIONSHIPS BOUND IT, and both are trivially satisfied now, which is worth stating rather
	-- than leaving silent: it must stay well under Input.BufferSeconds (0.35 -- the gap between them IS
	-- the early-press forgiveness a player actually gets, and at 0.01 that forgiveness is essentially
	-- the whole 0.35s), and the resulting stage-to-stage gap must stay under
	-- DamageConstants.Combo.WindowSeconds (0.9) or a landed string stops escalating and the Finisher
	-- becomes unreachable.
	--
	-- THE NUMBER THAT ACTUALLY BOUNDS THE SECOND RELATIONSHIP is not any single stage-to-stage gap --
	-- it is the WORST recovery+windup pairing across BOTH weapons' full Basic->Finisher chains, because
	-- SwingSequencer applies this same beat between every consecutive pair of stages, including into
	-- the Finisher (see SwingSequencer.Advance, which stamps ChainReadyAt after every accepted throw
	-- regardless of which stage it was). That worst case, checked by hand against
	-- CombatConstants.Weapons, is Primary's own Basic3->Finisher transition (0.20 recovery + 0.28
	-- windup = 0.48s). At the 0.01 delay authored here that totals 0.49s against the 0.9s ceiling -- a
	-- 0.41s margin, the widest this constant has had. If a future retune ever pushes this constant, or
	-- any stage's Windup/RecoverySeconds, past the point where 0.48 + ChainDelaySeconds clears 0.9, the
	-- Finisher silently stops being reachable off a fully-landed string -- redo this check by hand, the
	-- same way this comment just did, rather than trusting the old margin.
	--
	-- RAISED TO 0.12 (2026-09-28, with Tempo.ByStage.Basic 0.75 -> 0.65): "there is not nearly enough
	-- time between each M1 for a defender to even try to parry." Impact to impact was ~0.87s against a
	-- 0.65s hitstun, so a hit defender had ~0.2s before the next impact -- a frame-perfect read, not a
	-- parry. Now it is ~1.03-1.09s (worst pair B3 -> Launcher: 0.24 + 0.20/0.65 + 0.12 + 0.42 = 1.09),
	-- under DamageConstants.Combo.WindowSeconds (1.15) by 0.06 -- the tightest this margin has been, so
	-- recheck that pair before moving either number again. BufferSeconds (0.35) still leaves 0.23s of
	-- early-press forgiveness. Most of the extra time is the slower windup (a READ), not dead air, which is
	-- what keeps this from being the 0.20 beat that read as a hitch.
	--
	-- DROPPED BACK TO 0.05 (2026-09-30, "combat in general feels pretty unresponsive"). This beat is dead time
	-- the player feels as input lag -- the next swing waits on it after the clip has visibly ended -- and the
	-- parry read it bought is now bought by a shorter M1 stun instead (DamageConstants.Hitstun.ByStage, whose
	-- header has the arithmetic). B3 -> Launcher on a blade is now 0.22 + 0.12 + 0.05 + 0.42 = 0.81 against the
	-- 1.15 combo window: the thin 0.06 margin above is gone.
	ChainDelaySeconds = 0.05,

	EndOfStringCooldownSeconds = 0.5,

	-- Switching between the Basic and Heavy strings restarts whichever you switched away from.
	-- Without this a player could alternate presses and hold both strings at their last stage
	-- indefinitely, arriving at two finishers' worth of state for free. Kept as a named flag rather
	-- than an unconditional rule because "strings are independent" is a legitimate alternative feel
	-- (it rewards deliberate mixing) and this is the one line that would change to get it.
	ResetOnCategorySwitch = true,

	-- How far the stage probe will count before concluding a string has no further stages. Sized well
	-- above the largest authored string (3) so widening one in CombatConstants.Weapons needs no edit
	-- here, and bounded at all so a malformed registry cannot spin the probe.
	MaxStageProbe = 16,
}

-- THE STRING'S TEMPO, per stage kind of a weapon string -- the one knob for "M1s are too fast".
--
-- A multiplier on the swing's PLAYBACK, not a pause between swings: below 1 the clip plays slower and
-- the swing's windup and recovery stretch by the same factor, so the punch reads as heavier and the
-- string's rhythm slows WITHOUT dead time between links (a gap between swings is what the old 0.20
-- ChainDelaySeconds was, and it read as a hitch -- see that constant). Stacks with the weapon's own
-- WeaponSpeed: the clip plays at WeaponSpeed x this.
--
-- ActiveSeconds -- the hit window -- is deliberately NOT stretched. It is a gameplay number (how long
-- a swing can connect), not an animation one, and a slower swing silently growing a more forgiving
-- hit window would be a balance change nobody asked for. Only where it opens moves.
--
-- Applied by Server/Combat/AttackCatalog.Get to a weapon string's Default moves (DefaultMoveRegistry
-- stamps MoveDefinition.Tempo by stage); custom Move Editor moves and the standalones are 1. Every
-- client-side reader (the predicted clip, the trail, the lunge, the whoosh) follows automatically
-- because each is timed off the server's own AttackStartedPayload.
--
-- BOUNDED BY THE COMBO WINDOW: a slower string lands hits further apart, and the gap between two
-- landed hits must stay under DamageConstants.Combo.WindowSeconds or the Finisher becomes
-- unreachable. Tests/Combat/Attack/AttackRequestSystem.spec.lua checks the authored string against
-- it; a clip much longer than its authored timeline is the case that check cannot see.
AttackConstants.Tempo = {
	ByStage = {
		-- 0.65 (was 0.75): a defender needs to be able to SEE the next M1 coming and parry it -- see
		-- Sequence.ChainDelaySeconds for the impact-to-impact arithmetic this and it share.
		-- 0.8 (2026-09-30): the blade M1 took 0.48s to land and 1.02s to cycle, which read as unresponsive. The
		-- defender's read is now kept by a shorter M1 stun (DamageConstants.Hitstun.ByStage) rather than by a
		-- slower attacker. Windup 0.39, impact to impact 0.78.
		-- 1 (2026-10-06): M1s LINK now (DamageConstants.Hitstun.LinkBasicString) and the defender's read moved
		-- onto the stun parry (DefenseConstants.StunParry), so nothing needs the string slowed any more. Blade
		-- windup 0.31, impact to impact ~0.63 on the shipped 0.583s clip.
		Basic = 1,
		Heavy = 1,
		Finisher = 1,
		-- The air combo's moves play at their authored pace: their windups are the parry read
		-- (CombatConstants.Weapons.Baseline.Stages' own header on them), and a tempo here would silently
		-- move every one of them.
		Launcher = 1,
		Air = 1,
		AirFinisher = 1,
	},
	-- PER-WEAPON OVERRIDES of ByStage, keyed by roster id then stage kind. A stage a weapon does not name
	-- here plays at ByStage's tempo. Replaces the ByStage value outright; it does not multiply it.
	--
	-- Fists Basic 0.72 (2026-09-29): "the parry window in between punches on hands may be a little too
	-- long". Fists already play at WeaponSpeed 1.5, so at the shared 0.65 the gap between one punch's
	-- hitstun ending and the next punch landing was the easiest parry read in the roster. 0.72 plays the
	-- windup and recovery about 10% faster and shortens each punch-to-punch gap by roughly 0.04s. The hit
	-- window is untouched, the same as for every tempo. A faster string can only WIDEN the combo-window
	-- margin that Sequence.ChainDelaySeconds' header tracks, so that check still holds.
	--
	-- Fists Basic 0.65 (2026-09-30), now SLOWER than the shared 0.8 rather than faster: at WeaponSpeed 1.5 the
	-- shared tempo would cycle a punch every 0.54s, too fast to read even with the short Fists stun. At 0.65
	-- (playback 0.975) a punch lands 0.32s after the press and every 0.65s, still well ahead of a blade's 0.78
	-- -- see DamageConstants.Hitstun.ByStage for the read it leaves.
	--
	-- Fists Basic 1.1 (2026-10-06): with M1s linking, a jab can be as fast as its weight suggests. Playback
	-- 1.65 lands a punch ~0.19s after the press and every ~0.40s -- battlegrounds pace. The defender answers
	-- with a stun parry on the next impact, not a gap between punches.
	ByWeapon = {
		Fists = {
			Basic = 1.1,
		},
	} :: { [string]: { [string]: number } },
}

-- The tempo one stage of one weapon's string plays at: that weapon's ByWeapon override when it names the
-- stage, else the shared ByStage value, else 1. Read LIVE on every call (not cached) so a spec or a Studio
-- session that edits either table sees its edit.
function AttackConstants.TempoFor(weaponId: string?, stage: string): number
	local override = if weaponId then AttackConstants.Tempo.ByWeapon[weaponId] else nil
	local tempo = (override and override[stage]) or (AttackConstants.Tempo.ByStage :: { [string]: number })[stage]
	return tempo or 1
end

-- THE HIT-CONFIRM CANCEL (2026-09-29). A swing that LANDED may be cut partway through its recovery into
-- the next action. A whiff sits through the whole recovery, so landing feels snappy and whiffing stays
-- punishable.
--
--   * ConfirmKinds -- which outcomes count as landing. A block does not: blocking has to stay a safe
--     answer, and a faster heavy off a blocked jab would turn it into a guard-break engine.
--   * RecoveryKeepFraction -- how much of the landed swing's recovery still plays before it can be cut.
--     0.4 keeps the first 40%, so the cut arrives 60% of the recovery early.
--   * CancelInto -- which follow-ups may take the cut. Evade is the Evade key (the server cuts on the
--     accepted evade report, Main.server.lua; the client checks it in States/Evading via
--     ParkourContext.CombatCommitted).
--
-- BASIC IS OFF, ON PURPOSE. M1 into M1 keeps its full rhythm: the gap between M1s is the parry read
-- the string was slowed for (Tempo.ByStage.Basic 0.65, 2026-09-28), and cutting recovery there would take
-- that read straight back out. The launcher IS on. It is the string's payoff, its windup is still the
-- read, and an earlier launcher widens the thin B3 -> launcher combo-window margin that
-- Sequence.ChainDelaySeconds' header tracks. Air moves never cancel or take a cancel: the air string has
-- its own grammar.
AttackConstants.HitConfirm = {
	Enabled = true,
	RecoveryKeepFraction = 0.4,
	ConfirmKinds = {
		Clean = true,
		Backstab = true,
		GuardBroken = true,
	} :: { [string]: boolean },
	CancelInto = {
		Basic = false,
		Heavy = true,
		Hotbar = true,
		Launcher = true,
		Evade = true,
	} :: { [string]: boolean },
	-- The evade has no server-side input buffer (an attack press does), and the client times its cut
	-- from a swing it started a little earlier than the server did. So the server accepts an evade cut
	-- this much before its own cut point rather than refusing the evade frames over clock skew.
	EvadeLatencyToleranceSeconds = 0.08,
}

-- THE GUARD CUT (2026-09-30). A guard pressed during your own swing's RECOVERY comes up partway through
-- it instead of at the very end. Before this the guard waited for the whole clip, so a block pressed right
-- after a whiffed M1 arrived ~0.12s later than the player asked for it -- read as "I pressed block and
-- nothing happened".
--
--   * RecoveryKeepFraction -- how much of the recovery still plays before the guard may cut it. 0.3 keeps
--     the first 30%: committing to a swing still costs something, a whiff is still punishable by a fast
--     enough answer, but the tail of the follow-through no longer holds a guard hostage.
--
-- Windup and active are NEVER cut: a swing you threw is a swing you threw. The guard it raises is a
-- BLOCK, never a parry (DefenseSystem raises a deferred press block-only), so a whiff cannot be turned
-- into a free parry. Air moves never take it (the air string's own grammar). Served by
-- AttackRequestSystem.Step (server) and LocalCombatState.GuardFreeAt (the client's guard animation).
AttackConstants.GuardCut = {
	Enabled = true,
	RecoveryKeepFraction = 0.3,
}

-- When a swing's recovery may be cut by a guard (GuardCut), from the timeline it was thrown with. One
-- definition for the server and the client's mirror of it.
function AttackConstants.GuardCutAt(
	startedAt: number,
	windupSeconds: number,
	activeSeconds: number,
	recoverySeconds: number
): number
	return startedAt
		+ windupSeconds
		+ activeSeconds
		+ recoverySeconds * math.clamp(AttackConstants.GuardCut.RecoveryKeepFraction, 0, 1)
end

-- THE ATTACKER'S LATENCY REFUND (2026-09-30). The swing animation is predicted: it starts on the
-- attacker's screen the instant they press. The server used to start the swing's clock when the press
-- ARRIVED, so its hitbox always ran one network trip behind the animation the attacker was watching --
-- and in an exchange, the lower-ping player's swing always came out first. The defence layer has refunded
-- the DEFENDER's latency on a parry press for a long time (DefenseConstants.Parry.RewindMaxSeconds); this
-- is the same refund on the other side.
--
-- A player's swing is judged to have started min(ping / 2, MaxLeadSeconds) before the press arrived --
-- half the round trip, because the press only made the one trip (the parry rewind uses the whole round
-- trip because the defender was reacting to a swing that had to reach them first). The lead is never
-- allowed to reach back past the moment the body became free to swing -- its last swing, a stun, a
-- stagger, the chain beat, a cooldown -- so it refunds the wire and nothing else
-- (AttackRequestSystem.throw). Only the WINDUP ever shortens: HitboxEngine.RequestAttack refuses to
-- backdate a swing so far that its Active window would already have been due.
--
-- Air moves take none (the air combo judges its own deadline against a rewound start already --
-- AirComboMachine.NoteSwingAccepted), and neither does a bot or a dummy, which has no connection.
AttackConstants.Latency = {
	Enabled = true,
	MaxLeadSeconds = 0.1,
}

-- THE HEAVY TELL (2026-09-29). A swing at or above MinPowerLevel -- every Heavy stage, the launcher, the
-- air finishers, and any authored art given that weight -- flashes on its thrower for its windup, for
-- every OTHER client. Heavy weight is what a block pays for (GuardMeter drains by PowerLevel), so this is
-- the "parry or evade this one, don't block it" read made visible.
--
-- Published by the server (AttackRequestSystem) as a CollectionService Tag on the thrower's model plus a
-- server-time deadline Attribute, so any combatant can carry it (bots and dummies included) and each
-- client decides how to draw it (Client/FX/SwingTellFX.lua). The tag comes off at the windup's end, or
-- early when the swing is feinted or cut.
AttackConstants.Tell = {
	Enabled = true,
	MinPowerLevel = 2,
	Tag = "SwingTell",
	-- workspace:GetServerTimeNow() at which the telegraphed windup ends.
	UntilAttribute = "SwingTellUntil",
	-- How the client draws it: a Highlight that INTENSIFIES toward the strike, from StartFillTransparency
	-- at the windup's start to PeakFillTransparency as the hit window opens, so the flash reads as "the
	-- blow is coming" and its brightest frame is the moment to answer it. Danger red, the palette's
	-- threat colour (UI Tokens.Color.DangerBright).
	Color = Color3.fromRGB(216, 98, 112),
	StartFillTransparency = 0.85,
	PeakFillTransparency = 0.45,
	OutlineTransparency = 0.15,
}

-- When a landed swing's recovery may be cut (HitConfirm), from the timeline it was thrown with. One
-- definition for the server gate and the client's prediction of it.
function AttackConstants.HitConfirmCancelAt(
	startedAt: number,
	windupSeconds: number,
	activeSeconds: number,
	recoverySeconds: number
): number
	return startedAt
		+ windupSeconds
		+ activeSeconds
		+ recoverySeconds * math.clamp(AttackConstants.HitConfirm.RecoveryKeepFraction, 0, 1)
end

-- AttackConstants.Finisher (the landed-combo depth that tipped a completed Basic string into the weapon's
-- Finisher) is retired: the only 4th hit of an M1 string is now the air combo's launcher, Space + M1 after
-- B3, with its own thresholds in AirComboConstants.Launcher. See SwingSequencer's header.

-- Weapons ---------------------------------------------------------------------------------------

-- INTENTIONALLY EMPTY of Default/Order -- both used to live here as the hardcoded two-entry
-- { "Primary", "Secondary" } cycle, and both now come from Shared/Combat/WeaponRoster.lua, which
-- reads the real roster out of Workspace.Weapons at boot. A weapon is a model somebody dropped in a
-- folder, so neither "which exist" nor "which is first" is knowable from a constants file, and
-- leaving a stale copy of either here is exactly how the swap key would start disagreeing with what
-- is actually in the player's hand.
--
-- Kept as a named empty table rather than deleted outright so this comment has somewhere to live --
-- the next person looking for the weapon list will look here first.
AttackConstants.Weapons = {}

-- Input -----------------------------------------------------------------------------------------

AttackConstants.Input = {
	-- How long a press refused for a reason that CLEARS ON ITS OWN (still recovering, still on
	-- cooldown, still in hitstun, still staggered) is remembered and thrown automatically the instant
	-- the gate opens.
	--
	-- THIS IS THE SINGLE BIGGEST FEEL LEVER IN THE LAYER. Without it, a player pressing at a
	-- perfectly reasonable rhythm silently drops inputs whenever they are a few milliseconds early,
	-- which reads as the game ignoring them rather than as their own mistiming. With it, pressing
	-- slightly early is simply pressing.
	--
	-- Buffered requests are RE-VALIDATED at flush time, never replayed blindly -- a player who gets
	-- parried while a press is buffered must not have that swing fire out of their own stagger.
	--
	-- 0.35 is long enough to cover an early press and a round trip on a bad connection, short enough
	-- that a press the player has mentally given up on never fires later.
	--
	-- IT HAS TO EXCEED Sequence.ChainDelaySeconds WITH ROOM TO SPARE, and that is the binding
	-- constraint rather than a coincidence. The buffer is measured from the PRESS, but the gate it is
	-- waiting on opens at (swing end + chain delay) -- so the window a press can actually be made in
	-- and still land is (BufferSeconds - ChainDelaySeconds) before the swing ends, plus the whole beat
	-- after it. At 0.25 against a 0.15 beat that left only 0.1s of real early-press forgiveness, which
	-- was tighter than the buffer appeared to promise and would read as dropped inputs. 0.35 restored it
	-- to a genuine 0.2s at the time.
	--
	-- ChainDelaySeconds HAS SINCE MOVED TWICE -- up to 0.20 ("just a little slower" on the chain beat),
	-- then back down to a near-imperceptible 0.01 ("a lot smoother" -- see that constant's own header
	-- for the full account, including why it did not go to a bare 0). Neither move ever needed this
	-- constant to change: the real early-press forgiveness only ever narrowed to 0.15s at the 0.20 peak
	-- (comfortably clear of the 0.1s that once read as broken, per the paragraph above) and has since
	-- widened back out to essentially the full 0.35s. Still the first place to recheck if
	-- ChainDelaySeconds ever moves again.
	--
	-- Still deliberately shorter than DamageConstants.Hitstun.Seconds (0.65 as of that constant's own
	-- rebalance), so a swing buffered at the moment of being hit expires rather than firing the instant
	-- hitstun ends -- being interrupted should cost the exchange, not merely delay it. That gives the
	-- pair a real ceiling: raising the chain delay much further means raising this, and raising this
	-- past 0.65 would silently un-do the interruption rule. Hitstun's own rise from 0.45 to 0.65 only
	-- WIDENED this margin (0.10s of slack became 0.30s), so nothing here needed to change to stay safe
	-- -- worth stating explicitly since the number this comment references moved out from under it.
	BufferSeconds = 0.35,

	-- Only the newest refused press is buffered; an older one it replaces is dropped rather than
	-- queued. Mashing must not build a backlog that fires as a burst once the gate opens -- that is
	-- the failure mode input buffering is famous for, and one slot is the whole of the fix.
	BufferDepth = 1,

	-- Refusal reasons that mean "not yet" rather than "no". Everything here is buffered; everything
	-- else is dropped on the spot. Keyed by the exact strings HitboxEngine.RequestAttack,
	-- DefenseSystem.CanAttack and DamageSystem.CanAttack already return, so this table is the one
	-- place those three vocabularies meet.
	TransientRefusals = {
		-- HitboxEngine: mid-swing, still in windup/active/recovery.
		Busy = true,
		-- HitboxEngine: the server-wide concurrent-swing ceiling. Clears within a frame or two.
		TooManySwings = true,
		-- DamageSystem: reeling from a hit.
		Hitstun = true,
		-- DefenseSystem: staggered by a parry, or guard broken.
		Staggered = true,
		GuardBroken = true,
		-- This layer: the move's own authored Cooldown has not elapsed.
		Cooldown = true,
		-- This layer: the deliberate beat between stages of a string (Sequence.ChainDelaySeconds).
		-- Buffering it is not optional -- it is what lets the pause shape the OUTPUT without the player
		-- having to feel for it on the input side. See that constant's own header.
		ChainDelay = true,
		-- Server/Combat/Grab/GrabSystem.lua: a holding attacker (must Throw or wait the hold out) or a
		-- held-or-thrown victim. Both clear on their own -- a hold's own safety timer, a throw landing
		-- -- so a press made mid-hold is worth remembering rather than dropping, the same reasoning
		-- Hitstun/Staggered already buffer on.
		Grabbing = true,
		Grabbed = true,
		-- The air combo's first beat, pressed while the victim is still rising (AirComboMachine.CanPress).
		-- Buffered, so an eager first press fires the moment it may -- the on-beat press, not a dropped one.
		AirRising = true,
	} :: { [string]: boolean },
}

AttackConstants.Hotbar = {
	-- The HUD's five AbilitySlots. Must agree with ArtConstants.EquipSlotCount, which is the number
	-- that actually bounds a slot index everywhere it matters: a hotbar slot holds an equipped ART and
	-- nothing else (see ArtSystem.lua's header), so ArtSystem.IsValidSlot is the real gate and this is
	-- the combat layer's own read of the same fact. Not aliased to it only because Shared/Attack must
	-- not depend on the progression side. The server validates against this rather than trusting the
	-- slot number it is sent.
	SlotCount = 5,
}

-- Network ---------------------------------------------------------------------------------------

AttackConstants.Network = {
	RemoteNames = {
		-- Client -> server, at most once per press plus one automatic buffer flush. Payload is an
		-- action selector only (AttackTypes.AttackRequest) -- never a target, a position, a direction
		-- or a client timestamp.
		Request = "Attack_Request",
		-- Server -> the attacker alone, once per ACCEPTED throw. The confirmation, and the correction
		-- for whatever the client guessed locally -- never a rollback of a hit, because the client
		-- never claimed one.
		Started = "Attack_Started",
		-- Client -> server, the weapon swap press.
		SwapWeapon = "Attack_SwapWeapon",
		-- Server -> owner, on every accepted swap.
		WeaponChanged = "Attack_WeaponChanged",
		-- Client -> server, the feint press (AttackRequestSystem.Feint). No payload at all: the server
		-- knows which swing is in flight, so there is nothing for a client to name.
		Feint = "Attack_Feint",
		-- Server -> the attacker alone, when the server cuts one of their swings short. The one route by
		-- which a client learns to stop a swing clip it started on Attack_Started -- see
		-- AttackTypes.AttackCancelledPayload. Senders: a feint, and a parry (which only restores the
		-- client's string mirror -- see AttackRequestSystem.KeepChainThroughParry).
		Cancelled = "Attack_Cancelled",
		-- Server -> each client the shots concern (ProjectileRelevanceStuds below), at most once per
		-- engine frame while shots are flying: the batch of launches, bounces, retargets and ends
		-- (AttackTypes.ProjectileBatchPayload), which Client/FX/ProjectileFX.lua draws. Presentation only.
		Projectile = "Attack_Projectile",
	},

	-- Sized against DefenseConstants.Network.MaxCallsPerSecondPerPlayer (12) as the established
	-- analog. Generous enough that no legitimate string is ever throttled -- the fastest authored
	-- stage gap is well over 0.1s, so a player physically cannot reach 10 legal presses a second --
	-- while bounding a spamming client the same way every other public remote in this codebase does.
	--
	-- A throttled request is dropped, NOT buffered: the buffer exists to forgive a mistimed press,
	-- not to hand a mashing client a queue.
	--
	-- RAISED TO 30 (2026-09-30), "M1 chains sometimes just stop in the middle". The bucket is a FIXED one-
	-- second window, and a player mashing M1 -- the normal way to play a string -- clicks 10-15 times a
	-- second. So the 11th click of any second was dropped: if that click was the one the buffer needed for
	-- the next stage, the string simply ended, and the client, which had already predicted the swing,
	-- played it and then cut it as unconfirmed. Every press past the gate costs one table write (the
	-- one-slot buffer), so 30 still bounds a spammer at trivial cost while no human mash reaches it.
	MaxCallsPerSecondPerPlayer = 30,

	-- The swap key gets its own, much tighter bucket. Swapping is a deliberate act, not a combat
	-- rhythm, and a swap costs a registry lookup plus a string reset -- there is no legitimate reason
	-- to send more than a couple a second.
	MaxSwapsPerSecondPerPlayer = 4,

	-- The feint key's own bucket. A legal feint needs a swing in its windup first, which is itself
	-- gated by the request bucket above, so more than a few a second is never legitimate.
	MaxFeintsPerSecondPerPlayer = 4,

	-- Attack_Projectile's RELEVANCE RADIUS (Server/Combat/Attack/ProjectileRelevance.lua). A client is sent
	-- a shot only if its path passes within this many studs of that player's character (or the player
	-- threw it, or is its homing target, or has no character to measure from). A shot's draw ball is a
	-- few studs across, so past this it is a handful of pixels at most -- and before this existed, every
	-- shot anywhere in the server was sent to and drawn by every client, which is how one realm's
	-- strikes dropped frames for players nowhere near it.
	ProjectileRelevanceStuds = 350,
}

-- Feint ---------------------------------------------------------------------------------------------

-- Cancelling your own swing (an M1 or a Heavy) during the early part of its windup, to bait a parry or a
-- block. See
-- AttackRequestSystem.Feint for the gate and MoveTypes.FeintableByStage for which moves may be feinted.
AttackConstants.Feint = {
	-- How far into the windup a feint is still accepted, as a fraction of that swing's WindupSeconds.
	--
	-- THE FRACTION IS WHAT MAKES A FEINT A READ RATHER THAN A REACTION. A defender commits to a parry on
	-- the attacker's windup; if the attacker could cancel right up to the strike, they could wait to SEE
	-- the parry come out and cancel into a free punish -- an option-select, not a mind game. Cut off at
	-- half, a feint has to be thrown before the defender's answer is visible.
	WindowFraction = 0.5,

	-- The attacker's own lockout after a feint -- how long before they may throw again, and what
	-- CombatBusyUntil is rewritten to. Short, so a feint into a real swing is a live mix-up, but not
	-- zero: a free cancel would make every Heavy press safe.
	RecoverySeconds = 0.25,

	-- Minimum gap between two feints, from the first one. Stops feint-feint-feint from locking a
	-- defender into perpetual guessing -- the second bait costs a real commitment.
	CooldownSeconds = 1.5,
}

-- Windows -----------------------------------------------------------------------------------------

-- Shared/Attack/AttackWindows.lua's settings, applied by Server/Combat/AttackCatalog.Get. Both are
-- SERVER-AUTHORITATIVE (unlike Presentation below), and both are suspect-elimination switches: false
-- restores the hand-typed Constants.lua timing for the whole move set without a code change.
AttackConstants.Windows = {
	-- Any attack's WindupSeconds -- when its hitbox opens -- is read off an animation marker on its own
	-- clip whenever one is cached and usable, falling back to the hand-typed WindupSeconds otherwise.
	-- Two names are recognised: HitMarkerName below on ANY attack clip (M1s, Heavy, Finisher, the
	-- standalones, a Move Editor move or Art), and the older stage-specific "AttackM<stage>" on an M1
	-- clip, which wins over HitMarkerName when a clip carries both.
	Enabled = true,
	-- The marker an animator puts on the impact frame of any attack clip. An Animation Event in the
	-- Animation Editor IS a KeyframeMarker, so this is the event's name. Read from the published asset
	-- when the server boots (or on a clip's first throw), never from the playing track -- see
	-- AttackWindows.lua's header -- so republish the clip with Overwrite (same asset id) after adding
	-- or moving it, and restart the server.
	HitMarkerName = "Hit",
	-- EVERY move with a clip ends when its clip does. The clip's real length (read off the authored
	-- KeyframeSequence, never guessed) replaces the authored Windup+Active+Recovery total: the hitbox
	-- still opens exactly when the move's own delay (WindupSeconds, marker, SpawnDelay) runs out and
	-- stays live for its authored ActiveSeconds, and RecoverySeconds is whatever the clip has left
	-- after that. Before this, the server ran a hand-typed timeline while the client played the clip
	-- at its native length, and the two never checked each other -- the swing unlocked mid-animation,
	-- or the body stood frozen after the clip had finished.
	SyncToClipLength = true,
	-- A BORROWED clip (an air move standing in on a ground swing's clip until its own is authored --
	-- Shared/Attack/AttackAnimations.lua's BORROWED_FROM) plays at whatever speed lands its strike marker on
	-- the air move's own windup (AttackCatalog.Get, step 0). Bounded so a wildly mismatched lender can
	-- neither freeze nor blur: past these the clip is simply off by the remainder, which is cosmetic --
	-- the timing is the move's authored numbers either way.
	BorrowedClipMinSpeed = 0.5,
	BorrowedClipMaxSpeed = 2.5,
	-- A CLIP THE AUTHORED TIMELINE CANNOT FIT (2026-09-30). With no Hit marker, a move whose windup + active
	-- runs past the end of its own clip opened its hitbox after the animation had already finished --
	-- every weapon's Heavy and Launcher did (boot log: "Hitbox closes after its clip ends"), so the blow
	-- landed on screen and THEN hit. For exactly that case AttackCatalog (step 1c) moves the hitbox onto the
	-- clip's estimated strike (AttackWindows.EstimateStrikeTime) and slows the clip toward the authored
	-- windup so the move keeps its weight: never faster than the weapon plays it, never slower than
	-- RetimeMinFactor of that. false restores the old behaviour. A Hit marker on the clip replaces all of it.
	RetimeUnfitClips = true,
	RetimeMinFactor = 0.75,
}

-- Presentation ----------------------------------------------------------------------------------

-- CLIENT-ONLY, and none of it can change an outcome. Every value here shapes how a press or a
-- confirmed hit LOOKS on the acting client; the server has already decided everything that matters
-- by the time any of it runs. Same category as Constants.FX, and kept here rather than there because
-- these belong to this system's lifetime -- deleting the attack layer should take its own feel
-- tunables with it.
AttackConstants.Presentation = {
	-- The immediate, local "you pressed it" acknowledgment: a small FOV punch the frame the key goes
	-- down, before the server has answered. Has no fairness stakes -- worst case an FOV nudge plays
	-- and no attack follows, which is cosmetically recoverable and is never a hit/miss decision made
	-- client-side. See Client/Combat/AttackInputClient.lua's header for the whole no-prediction
	-- stance this sits inside.
	SwingPunch = {
		FOVDelta = -1.6,
		OutSeconds = 0.06,
		BackSeconds = 0.14,
		-- Floor between two local cues, so mashing during hitstun does not strobe the camera. Shorter
		-- than the fastest authored stage gap, so it never suppresses a cue for a press that was
		-- actually going to be accepted.
		MinIntervalSeconds = 0.12,
	},

	-- Which Constants.FX.CameraShake preset a resolved contact plays, by DefenseTypes.OutcomeKind and
	-- by which side of it the local player was on. Names, not preset tables, so this file never
	-- duplicates the tuned numbers that already live in Constants.FX.
	--
	-- The asymmetry is deliberate: landing a hit should register, but being hit is the thing a player
	-- must not be able to miss, so the defender's cue is always the heavier of the pair. Blocked is
	-- the one outcome where the DEFENDER gets the lighter cue -- that is the block working.
	--
	-- Evaded maps to "None" on both sides -- a name with no Constants.FX.CameraShake preset behind it,
	-- which CameraShake.Shake reads as no shake at all. Mapped explicitly rather than left out, because an
	-- unmapped kind falls back to DefaultShakePreset below, and a dodge that shakes the camera like a
	-- landed hit tells the player the one thing that did not happen.
	ShakePresets = {
		Attacker = {
			Clean = "HitLight",
			Backstab = "HitHeavy",
			GuardBroken = "HitHeavy",
			Blocked = "HitLight",
			Parried = "Parry",
			Trade = "HitLight",
			Evaded = "None",
		} :: { [string]: string },
		Defender = {
			Clean = "HitHeavy",
			Backstab = "PostureBreak",
			GuardBroken = "PostureBreak",
			Blocked = "HitLight",
			Parried = "Parry",
			Trade = "HitHeavy",
			Evaded = "None",
		} :: { [string]: string },
	},

	-- Fallback when an outcome has no entry above -- a new OutcomeKind should degrade to a light nudge
	-- rather than to silence, so an unmapped case is visible in play instead of invisible.
	DefaultShakePreset = "HitLight",

	-- How long the on-screen outcome word (BLOCKED / PARRIED / GUARD BROKEN) is held. Short: it
	-- acknowledges an exchange that is already over, and a cue that outlives the exchange starts
	-- describing the wrong moment.
	OutcomeTextSeconds = 0.9,

	-- Crossfade for the swing clip claimed on the Attack layer. Faster than the Defense layer's own
	-- block fade -- a swing has to look like it started on the frame the key went down, where a guard
	-- can afford to ease up.
	SwingFadeSeconds = 0.05,

	-- Client/Combat/AttackInputClient.lua's predicted swing: a Basic/Heavy press plays the clip the
	-- server is about to confirm on the frame the key goes down, instead of a round trip later. Cosmetic
	-- only -- the hitbox, the damage and every gate stay on the server, and Attack_Started still
	-- confirms (or replaces) what was predicted. See that module's header for the whole contract.
	SwingPrediction = {
		-- false restores confirm-then-play for every swing, the suspect-elimination switch the rest of
		-- this file keeps per feature.
		Enabled = true,
		-- How long a prediction waits for its Attack_Started, ON TOP of two ping lengths and
		-- Input.BufferSeconds (a press the server buffered is confirmed only when it throws). Past it the
		-- server evidently refused the press, and the predicted swing is cut rather than left playing a
		-- move that never happened.
		ConfirmGraceSeconds = 0.1,
	},

	-- THE PREDICTED HIT (2026-09-30). Client/Combat/HitPrediction.lua plays the attacker's impact -- the
	-- thud, the flash, the exchange freeze, the target's flinch -- the frame their own swing's volume
	-- overlaps a target on their own screen, instead of a full round trip (plus up to
	-- DefenseConstants.Parry.RewindMaxSeconds of lag-rewind hold) later. Invisible in Studio, where the
	-- round trip is zero; on a real server it is the difference between a punch that lands and a punch
	-- that lands and then, a beat later, hits.
	--
	-- COSMETIC, AND IT CAN BE WRONG: the server may still rule the hit blocked, parried or evaded. Two
	-- things keep that rare and readable. A target visibly guarding or evading is never predicted (that
	-- is where nearly every reversal comes from). And the server's verdict always plays in full when it
	-- disagrees -- a predicted thud followed by a parry clang reads as "they parried it", which is true.
	-- A matching Clean verdict skips only what was already played; damage numbers always wait for it.
	HitPrediction = {
		Enabled = true,
		-- A target's ROOT is tested against the box, so the box is grown by roughly a body's half-extent --
		-- the engine tests every part of the body, not just its centre.
		PadStuds = 1,
		PadHeightStuds = 2.5,
		-- How long a predicted hit waits to be matched by the server's verdict for the same target and
		-- move before it is forgotten (a prediction the server never confirmed: a miss it called a hit).
		MatchSeconds = 0.8,
	},

	-- The forward step a confirmed swing carries the LOCAL player's own body through
	-- (Client/Combat/SwingLunge.lua). Fires on Attack_Started -- the swing being THROWN -- which is
	-- what makes it a swing's own weight rather than a reward: a whiff steps forward exactly as far as
	-- a hit does, because at the moment the step starts nobody knows yet which it will be.
	--
	-- CLIENT-SIDE, AND THAT IS THE WHOLE REASON THIS EXISTS. DamageConstants.AttackerLunge already
	-- expresses the same idea server-side, and for a real player it cannot work: a player's character
	-- is network-owned by their own client, so a server Humanoid:Move() write is replaced by the
	-- owner's next replicated frame and never reaches the simulation that is actually drawing them.
	-- That server-side nudge is still live and still correct for the bodies the SERVER owns (bots,
	-- dummies), which is why it was left alone rather than deleted -- see its own comment.
	--
	-- Distance/duration, not a speed: a step is a distance a body covers, and stating it that way
	-- means retuning the duration cannot silently change how far a swing carries. SwingLunge derives
	-- the speed curve from the pair (linear decay to a standstill -- see SpeedAt there).
	--
	-- THE STEP WAITS OUT THE SWING'S OWN WINDUP. A body that lurches forward on the frame the button
	-- goes down is moving before the arm is, which reads as the character being shoved rather than as
	-- them throwing a punch. So the delay before the step starts is the swing's actual
	-- AttackStartedPayload.WindupSeconds plus the per-kind DelaySeconds offset below -- windup is the
	-- interval whose whole definition is "the arm is cocking and nothing has happened yet", so its end
	-- is the instant the weight goes forward.
	--
	-- Taking it from the PAYLOAD rather than from a number here is what keeps it honest: that value is
	-- what the server actually scheduled for this specific swing, which since AttackConstants.Windows
	-- may have come from the clip's own Hit/AttackM<stage> marker rather than from any hand-typed constant.
	-- So a re-authored animation moves the step with it, and a stage with a longer windup than its
	-- neighbours waits longer, both without anyone editing this table.
	--
	-- NOT A GAP-CLOSER. Every distance below is under a character's own reach, so a swing thrown from
	-- outside range still misses. Raising these past that turns whiffing into a dash and is a combat
	-- balance change, not a feel change.
	SwingLunge = {
		-- false makes every swing behave exactly as it did before this existed -- the suspect-elimination
		-- switch AttackConstants.Windows.Enabled documents its own reasoning for.
		Enabled = true,
		-- Per AttackTypes.AttackKind. Hotbar is deliberately absent rather than zeroed: an authored move
		-- carries its own MoveTypes.LungeDistanceStuds/LungeDurationSeconds pair, and a second number here
		-- would be the "one system, two configs" trap Constants.Combat's own former Sprint* fields were.
		--
		-- BASIC IS ALSO ABSENT NOW, and unlike Hotbar's absence this is a reversal rather than a thing that
		-- was never authored: Basic used to carry a 4-stud step. Playtest read it as the punch closing
		-- distance for the player rather than the player closing it themselves -- exactly the "not a
		-- gap-closer" promise this whole table's header makes, and a step this short cannot be retuned
		-- around that complaint because ANY nonzero forward push on the most-thrown move in the game
		-- reproduces some version of the same slide. Removing the entry rather than zeroing it keeps this
		-- table honest by its own rule (see Hotbar just above): onAttackStarted (SwingLunge.lua) already
		-- treats a missing ByKind[Kind] as "this move does not step" -- an ordinary authoring answer, not a
		-- fault -- so dropping Basic needed no code change anywhere, only this entry's removal. Heavy KEEPS
		-- its step: a heavy swing is a slower, deliberate committing strike where a forward weight-shift
		-- reads as the swing's own momentum, and nothing about the M1 complaint applies to a move thrown a
		-- fraction as often.
		--
		-- DelaySeconds is an OFFSET ON TOP OF THE WINDUP, not the whole delay -- 0 starts the step on
		-- the frame the windup ends and the swing goes active. Negative is legal and is the useful
		-- direction: it starts the step slightly INSIDE the windup, so the body is already leaning as
		-- the arm comes through rather than beginning to move once it has. SwingLunge floors the total
		-- at zero, so an offset more negative than a short stage's own windup degrades to "immediately"
		-- rather than to a step in the past. Both sit at 0 until someone has actually watched them --
		-- the honest starting point for a number whose only correct value is the one that looks right.
		-- The distance was raised from 4.5 on a playtest read of "a little further". Note what that does
		-- to the SPEED, since the duration was deliberately left alone: SpeedAt derives its peak from
		-- 2 * distance / duration, so a longer step over the same window is also a faster and punchier
		-- one. That was the wanted direction here. Raising the duration alongside the distance is the
		-- other lever -- same peak speed, more travel, a longer commitment -- and is the one to reach for
		-- if the step ever starts reading as a shove rather than as a step.
		ByKind = {
			-- Further and longer than Basic used to be: a heavy swing commits harder, and the step is
			-- most of what sells the commitment before the hitbox ever opens.
			Heavy = { DistanceStuds = 5, DurationSeconds = 0.26, DelaySeconds = 0 },
		} :: { [string]: { DistanceStuds: number, DurationSeconds: number, DelaySeconds: number } },
		-- Skipped entirely while airborne (Humanoid.FloorMaterial == Air). A step is a thing feet do; the
		-- same write with no ground under it is an air-dash on every M1, which is a movement mechanic
		-- nobody designed. States/CombatHeld.lua already owns what the body does mid-air in combat.
		GroundedOnly = true,
	},

	-- A short Trail tracing the attacking limb through its own swing -- Client/FX/AttackTrail.lua.
	-- LOCAL-PLAYER-ONLY, the same Attack_Started visibility Client/FX/CombatAudio.lua's own PlaySwing
	-- already accepts for the swing whoosh (see AttackRequestSystem's own FireClient, not
	-- FireAllClients): this reads other characters' swings off nothing today, only the thrower's own.
	-- Extending it to be visible to everyone watching would need a broadcast this layer does not yet
	-- send, not just a client-side change here.
	SwingTrail = {
		Enabled = true,
		-- Pale and neutral rather than tied to a weapon or an outcome -- HitColor (FXConstants.lua) is
		-- the same choice for the same reason: a swing-in-progress is not yet a verdict, so it borrows
		-- no faction/outcome colour the way a parry or a guard-break flash does.
		Color = ColorSequence.new(Color3.fromRGB(235, 235, 245)),
		-- Solid for the first half of a segment's life, then gone -- the old straight 0.15 -> 1 ramp spent
		-- most of an already-short lifetime half-faded, which is most of why the M1 trail read as faint.
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		-- Seconds a given point along the trail takes to fade out -- Roblox's own Trail.Lifetime, not a
		-- duration this module schedules. Still a swing's own arc, not a comet tail -- but 0.18 left an
		-- M1's arc gone before the eye had found it; 0.3 holds it about one beat.
		LifetimeSeconds = 0.3,
		-- SELF-LIT and CAMERA-FACING. Unlit (LightInfluence 1, the Trail default) a pale trail in shade
		-- reads as grey smoke; FaceCamera turns the ribbon toward the viewer, where a flat ribbon swept
		-- by a punch is edge-on -- invisible -- for exactly the side view a fight is usually seen from.
		LightEmission = 0.6,
		LightInfluence = 0,
		Brightness = 2,
		FaceCamera = true,
		-- The trail lights this long BEFORE the hit window opens and stays lit this long AFTER it closes.
		-- The window alone is ~0.2s -- a flicker. The lead catches the arm's acceleration into the
		-- strike and the tail its follow-through, so the trail traces the swing rather than a slice of
		-- it. Presentation only: the hitbox is exactly the window, whatever this draws.
		LeadSeconds = 0.06,
		TailSeconds = 0.08,
		-- Trail.WidthScale runs over each segment's LIFETIME, not along the limb: 0 is the segment just
		-- laid down, 1 is the one about to vanish. Full width where the fist/blade is now, thinning to a
		-- sliver as it fades, so the trail reads as a streak behind the strike rather than a flat ribbon.
		--
		-- THERE IS NO Width PROPERTY ON A Trail, and this table used to carry one (Client/FX/AttackTrail.lua
		-- set it and threw on every swing). A trail's thickness IS the distance between its two
		-- Attachments -- the offset pairs below -- times this scale.
		WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.15),
		}),
		-- Where the two Attachments sit, in studs along the part's axis from its centre, and therefore how
		-- thick the trail is (their separation). See Client/FX/AttackTrail.lua's own header for why these
		-- are two pairs.
		--   * Fists: the R6 Right Arm is 2 studs long, so -1 is the fist. A 0.3-stud pair right at the
		--     knuckles draws a thin line that follows the punch, not a sheet swept by the whole forearm.
		--   * Weapons: along the Handle's own axis out to the blade, so the trail covers the edge that hit.
		-- Widened from a 0.3-stud pair (-0.75..-1.05) to 0.5: at 0.3 the camera-facing ribbon was a
		-- hairline at fighting distance. Still only the forearm's last half-stud, not a sheet swept by the
		-- whole arm -- Tests/FX/SwingTrail.spec holds it at or under 0.5.
		FistOffsetStuds = { Near = -0.55, Far = -1.05 },
		-- Which limb each stage of the bare-hands Basic string strikes with, in string order: jab with the
		-- left, cross with the right, then a kick with the left foot. R6 limb part names. Anything not in
		-- this list -- the Finisher (StageIndex 0), a Heavy, a stage past the end -- uses FistDefaultLimb.
		-- The same offsets serve legs: an R6 leg is 2 studs long like an arm, so -1 is the foot.
		FistLimbByStage = { "Left Arm", "Right Arm", "Left Leg" },
		FistDefaultLimb = "Right Arm",
		WeaponOffsetStuds = { Near = 0.5, Far = -3.2 },
		-- THE FEINT CUE. When the server confirms a feint (Attack_Cancelled), the same trail flares for
		-- this long in this colour as the arm pulls back -- a short, cold streak that reads in hindsight
		-- as "that was a bait", distinct from the pale strike trail above. Local to the feinter, like the
		-- trail itself; the defender's reward is the parry they wasted, not a banner.
		FeintColor = ColorSequence.new(Color3.fromRGB(120, 200, 255)),
		FeintPulseSeconds = 0.12,
	},
}

-- Debug -----------------------------------------------------------------------------------------

AttackConstants.Debug = {
	-- Master switch for this system's per-press logging. Off by design, the same reason
	-- DefenseConstants.Debug.Enabled and DamageConstants.Debug.Enabled are: a busy fight is many
	-- presses a second per player, and anything logged per press is its own performance problem.
	Enabled = false,
	-- One line per accepted throw. Requires Enabled.
	LogAccepted = true,
	-- One line per refusal, with the reason. Requires Enabled, and is the first thing to turn on when
	-- "my attacks do nothing" -- every gate in this layer reports through it.
	LogRefused = true,
	-- One line per buffered press and per flush. Requires Enabled.
	LogBuffer = false,
}

return AttackConstants
