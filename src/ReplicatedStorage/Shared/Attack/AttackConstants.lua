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
	-- CombatTypes' own basicSwingIndex/basicComboLanded split existed to avoid.
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
	-- 0.15 against the Primary Basic string's own ~0.45s stage-to-stage gap (0.14 recovery + 0.31
	-- windup) makes a three-hit string read at roughly 0.6s per link. Raise it for a heavier, more
	-- deliberate game; drop it to 0 to restore the previous back-to-back chaining exactly.
	--
	-- TWO RELATIONSHIPS BOUND IT, and both bite quietly if ignored. It must stay well under
	-- Input.BufferSeconds (see that constant -- the gap between them IS the early-press forgiveness a
	-- player actually gets), and the resulting stage-to-stage gap must stay under
	-- DamageConstants.Combo.WindowSeconds (0.9) or a landed string stops escalating and the Finisher
	-- becomes unreachable. At 0.15 the Basic string chains at ~0.6s, comfortably inside 0.9.
	ChainDelaySeconds = 0.15,

	-- Switching between the Basic and Heavy strings restarts whichever you switched away from.
	-- Without this a player could alternate presses and hold both strings at their last stage
	-- indefinitely, arriving at two finishers' worth of state for free. Kept as a named flag rather
	-- than an unconditional rule because "strings are independent" is a legitimate alternative feel
	-- (it rewards deliberate mixing) and this is the one line that would change to get it.
	ResetOnCategorySwitch = true,

	-- How far the stage probe will count before concluding a string has no further stages. Sized well
	-- above the largest authored string (3) so widening one in Constants.Combat.Weapons needs no edit
	-- here, and bounded at all so a malformed registry cannot spin the probe.
	MaxStageProbe = 16,
}

AttackConstants.Finisher = {
	-- Landed-combo depth (ComboEscalation.GetStage) required before completing the Basic string tips
	-- into the weapon's Finisher instead of wrapping back to stage 1.
	--
	-- LANDED, not thrown, and that is the whole design of it: the finisher is the payoff for a string
	-- that actually connected, so whiffing three times in the air can never earn one. Three is the
	-- length of the Primary Basic string, so "land a full string, get the finisher" is the rule a
	-- player learns without being told it.
	MinComboStage = 3,
}

-- Weapons ---------------------------------------------------------------------------------------

AttackConstants.Weapons = {
	-- What every combatant starts on. Not a balance statement -- Primary is simply the fuller
	-- authored move set (three Basic stages, two Heavy, a Finisher), so it is the one a player who
	-- never touches the swap key should be holding.
	Default = "Primary" :: "Primary",
	-- Swap order. A two-entry cycle today; kept as a list rather than an if/else so a third weapon is
	-- a data edit rather than a control-flow one.
	Order = { "Primary", "Secondary" },
}

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
	-- is tighter than the buffer appears to promise and would read as dropped inputs. 0.35 restores it
	-- to a genuine 0.2s.
	--
	-- Still deliberately shorter than DamageConstants.Hitstun.Seconds (0.45), so a swing buffered at
	-- the moment of being hit expires rather than firing the instant hitstun ends -- being interrupted
	-- should cost the exchange, not merely delay it. That gives the pair a real ceiling: raising the
	-- chain delay much further means raising this, and raising this past 0.45 silently un-does the
	-- interruption rule.
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
	} :: { [string]: boolean },
}

AttackConstants.Hotbar = {
	-- Matches Client/Combat/HotbarBindings.lua's own SLOT_COUNT and the HUD's five AbilitySlots. The
	-- server validates against this rather than trusting the slot number it is sent.
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
	},

	-- Sized against DefenseConstants.Network.MaxCallsPerSecondPerPlayer (12) as the established
	-- analog. Generous enough that no legitimate string is ever throttled -- the fastest authored
	-- stage gap is well over 0.1s, so a player physically cannot reach 10 legal presses a second --
	-- while bounding a spamming client the same way every other public remote in this codebase does.
	--
	-- A throttled request is dropped, NOT buffered: the buffer exists to forgive a mistimed press,
	-- not to hand a mashing client a queue.
	MaxCallsPerSecondPerPlayer = 10,

	-- The swap key gets its own, much tighter bucket. Swapping is a deliberate act, not a combat
	-- rhythm, and a swap costs a registry lookup plus a string reset -- there is no legitimate reason
	-- to send more than a couple a second.
	MaxSwapsPerSecondPerPlayer = 4,
}

-- Windows -----------------------------------------------------------------------------------------

-- Shared/Attack/AttackWindows.lua's one setting. SERVER-AUTHORITATIVE (unlike Presentation below):
-- when true, a Basic-string (M1) swing's WindupSeconds is overridden from its clip's own "AttackM<
-- stage>" animation marker whenever one is cached and usable, falling back to the hand-typed
-- Constants.Combat.Weapons[...].Stages.Basic[n].WindupSeconds otherwise. false disables the whole
-- mechanism unconditionally -- every M1 keeps its hardcoded timing, the same behaviour as before
-- AttackWindows.lua existed -- for ruling it out as a suspect on a live server without a code change.
AttackConstants.Windows = {
	Enabled = true,
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
	ShakePresets = {
		Attacker = {
			Clean = "HitLight",
			Backstab = "HitHeavy",
			GuardBroken = "HitHeavy",
			Blocked = "HitLight",
			Parried = "Parry",
			Trade = "HitLight",
		} :: { [string]: string },
		Defender = {
			Clean = "HitHeavy",
			Backstab = "PostureBreak",
			GuardBroken = "PostureBreak",
			Blocked = "HitLight",
			Parried = "Parry",
			Trade = "HitHeavy",
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
