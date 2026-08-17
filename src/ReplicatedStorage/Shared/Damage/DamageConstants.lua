--!strict
--[[
	DamageConstants.lua

	Owns: the Damage System's tunables. Standalone, and deliberately NOT a section of
	Shared/Constants.lua -- the same choice DefenseConstants.lua and HitboxEngineConstants.lua both
	make, and for the same reason: this system is a module, and a module that can be added or removed
	without editing the game's central constants table is the concrete form of that claim.

	THERE IS NO DAMAGE NUMBER IN THIS FILE, and its absence is the point, exactly as the absence of a
	parry window length is DefenseConstants' point. How much a hit hurts is authored PER MOVE in the
	Move Creation System (MoveDefinition.Damage / .PostureDamage, editable in the Move Editor, persisted
	to a DataStore) and reaches this layer through AttackCatalog. A damage number in here would be a
	second authority competing with the editor, and the editor would lose silently.

	What IS here is the set of values no single move could define, because each one describes the
	RELATIONSHIP between moves rather than any one of them: how long being hit locks you out, how long
	a string stays connected, how much a landed hit escalates. Those are properties of the combat
	system, not of any attack in it.

	Does not own: per-move damage/posture/knockback (the Move Creation System), guard pool sizing or the
	stagger's own length (DefenseConstants -- this layer reads that file rather than restating it), or
	anything about contact detection (HitboxEngineConstants).
]]

local DamageConstants = {}

-- Hitstun -------------------------------------------------------------------------------------------

DamageConstants.Hitstun = {
	-- How long a combatant who takes a genuinely landed hit (Clean, Backstab, GuardBroken) cannot
	-- start an attack, and during which their own in-flight swing is cancelled.
	--
	-- THIS IS THE MECHANIC THAT MAKES TRADING REAL. Before it, nothing cancelled a swing except a
	-- parry, and only the attacker's -- so a player struck mid-combo simply kept swinging, and a
	-- well-timed counter-hit was a damage race running in parallel rather than an interruption. With
	-- it, landing a hit is itself a counterplay tool: spacing and timing can stop a combo without a
	-- block or a parry, and two combatants who connect in the same batch both lose their swing, which
	-- is what a trade should mean.
	--
	-- 0.45 borrows only the ORDER OF MAGNITUDE from the deleted system's HitStunDuration (0.6). It is
	-- not a re-derivation: that number was measured against a move set that no longer exists, and the
	-- real constraint is its relationship to the rebuilt move set's WindupSeconds, which cannot be
	-- checked until real attacks exist. Deliberately shorter than the old value because it now cancels
	-- swings as well as gating them, so it does strictly more per second than its predecessor did.
	--
	-- The bound that keeps it fair: every hit that causes hitstun was itself avoidable -- blockable,
	-- parryable, or duckable by spacing -- and the telegraph is the same Windup every attack already
	-- authors. It is short and fixed, so no chain of them is an infinite stun.
	Seconds = 0.45,
}

-- Combo ---------------------------------------------------------------------------------------------

DamageConstants.Combo = {
	-- How long after a LANDED hit the attacker's string stays connected. A hit landed inside this
	-- window escalates; one landed after it starts again at stage 1.
	--
	-- MUST STAY STRICTLY BELOW DefenseConstants.Stagger.DurationSeconds (1.5), and that relationship
	-- is load-bearing rather than incidental: it is the entire reason this system needs no
	-- "reset the combo when you get parried" rule. A parried attacker is staggered for longer than
	-- their own window lasts, so by the time they can act again the window has lapsed on its own. That
	-- is the same "let the timer expire, don't special-case it" economy DefenseStateMachine already
	-- practices with its own lockout timestamps.
	--
	-- So if Stagger.DurationSeconds is ever retuned down (its own comment flags 0.6-0.75 as the
	-- previous design's derived bound), THIS number has to move with it or the parry silently stops
	-- interrupting combos. The spec asserts the ordering rather than either number.
	WindowSeconds = 0.9,

	-- Ceiling on escalation. Past this, further landed hits keep the window alive but grant no more
	-- growth -- an unbounded multiplier is one long string away from a one-combo kill, and bounding it
	-- here is cheaper than bounding it in every move's authored damage.
	MaxStage = 8,

	-- Extra damage per stage beyond the first: stage N deals (1 + this * (N - 1)) of authored damage.
	-- At MaxStage that is 1.56x, which rewards a sustained string without making the last hit of one
	-- worth more than the whole rest of it.
	DamageMultiplierPerStage = 0.08,
}

-- Guard pressure ------------------------------------------------------------------------------------

-- GUARD IS THE POSTURE POOL. There is deliberately no second meter.
--
-- The alternative -- a Posture resource distinct from Guard, as the deleted CombatTypes.CombatVitals
-- State carried -- was considered and rejected by the repo owner. The reason the two were ever
-- separate is worth recording, because this file has to make one meter do both jobs: DefenseSystem's
-- Guard only ever moves while a player is actively BLOCKING (spent on a mitigated hit, restored on a
-- parry), so on its own it cannot touch a player who never blocks. A posture system's whole purpose is
-- to punish exactly that player.
--
-- So this layer supplies the missing half: a hit that connects WITHOUT a guard covering it drains the
-- same pool. Full depletion runs through DefenseStateMachine.BreakGuard, which is already the
-- "guaranteed opening" a posture break is supposed to produce -- no new state, no new HUD element, no
-- second number for a player to track.
--
-- Blocked and GuardBroken contacts are excluded here, and NOT because they are free: DefenseSystem has
-- already priced them through GuardMeter.DrainFor on the same pool. Draining again in this layer would
-- charge one hit twice.
DamageConstants.Guard = {
	-- Multiplier on the move's authored PostureDamage when the hit was NOT blocked. 1.0 means the
	-- authored number is taken at face value, which keeps the Move Editor's own field meaningful --
	-- an author who doubles a move's PostureDamage sees it double in play.
	--
	-- This one number is the whole strength of the guard-as-posture mechanic. Raise it and never
	-- blocking becomes rapidly fatal; drop it to 0 and Guard reverts to being purely a blocking
	-- resource, which is the pre-this-layer behaviour and a legitimate thing to want back.
	PressurePerPostureDamage = 1.0,
}

-- Outcome multipliers -------------------------------------------------------------------------------

DamageConstants.Backstab = {
	-- A hit that lands in the rear hemisphere while the defender is blocking. DefenseSystem already
	-- decided the block does not apply; this is what makes it a punish rather than merely a
	-- non-block.
	--
	-- Applies to posture pressure as well as health, so being caught from behind costs the guard it
	-- failed to cover with -- otherwise the punish for the worst possible defensive read would be
	-- indistinguishable from simply standing still.
	Multiplier = 1.5,
}

-- Attacker lunge ------------------------------------------------------------------------------------

DamageConstants.AttackerLunge = {
	-- Whether a landed Basic-string (M1) hit gives the ATTACKER a brief forced-forward nudge --
	-- DamageSystem holds Humanoid:Move() in the swing's own facing for DurationSeconds, at whatever
	-- WalkSpeed RunSystem already has in effect (this never writes WalkSpeed itself -- see
	-- RunSystem.lua's own "exactly one thing may write that property" rule). A felt "the punch has
	-- weight" cue, not a real gap-closer: short enough that its actual travelled distance stays a
	-- couple of studs at most. false makes every M1 behave exactly as it did before this existed.
	Enabled = true,
	DurationSeconds = 0.08,
}

-- Network -------------------------------------------------------------------------------------------

DamageConstants.Network = {
	RemoteNames = {
		-- Server -> both participants, once per resolved contact. Carries what each side needs to
		-- present the hit (the attacker's "I landed that" and the defender's "I got hit") and nothing
		-- either could act on to change the outcome, which has already been decided by the time this
		-- fires.
		--
		-- There is deliberately no client -> server remote in this system at all. This layer never
		-- takes input: it is driven entirely by DefenseSystem.OnResolved, which is driven by
		-- HitboxEngine, which is driven by the attack layer's own remote. Adding one here would be a
		-- second way to cause damage.
		Feedback = "Combat_Feedback",
	},
}

-- Debug ---------------------------------------------------------------------------------------------

DamageConstants.Debug = {
	-- Master switch for this system's per-contact logging. Off by design, the same reason
	-- DefenseConstants.Debug.Enabled is: a busy fight resolves many contacts a second, and anything
	-- logged per contact is its own performance problem.
	Enabled = false,
	-- Logs one line per applied hit. Requires Enabled.
	LogApplied = true,
	-- Logs a line whenever an attack cannot be resolved in AttackCatalog. Requires Enabled, and is
	-- worth turning on first when hits land but deal nothing -- an unresolvable MoveId is the most
	-- likely cause and is otherwise silent.
	LogCatalogMisses = true,
}

return DamageConstants
