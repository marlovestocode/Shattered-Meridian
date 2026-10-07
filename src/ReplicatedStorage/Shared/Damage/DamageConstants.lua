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
	-- RAISED FROM 0.45 TO 0.65 once real attacks existed to check it against. 0.45 borrowed only the
	-- ORDER OF MAGNITUDE from the deleted system's HitStunDuration (0.6) as a placeholder -- it was
	-- never a re-derivation, because the real constraint (its relationship to the rebuilt move set's
	-- WindupSeconds) could not be checked until the rebuilt move set existed. With the real Basic/Heavy
	-- stages authored (CombatConstants.Weapons -- Basic windups 0.14-0.18, Heavy 0.35/0.6), 0.45 read
	-- as a flinch rather than a stun in play: a hit landed and the victim's next legal action arrived
	-- before the attacker's own follow-up swing had even finished its windup, so "you got hit" cost
	-- less than a single beat of pressure. 0.65 is a full, felt lockout a player cannot mistake for
	-- ordinary recovery -- comfortably past every Basic windup on both weapons and past Primary Heavy's
	-- own 0.6, so a stunned combatant reliably eats at least one more committed attack rather than
	-- occasionally slipping out from under it by a few frames of luck.
	--
	-- STILL SHORTER than the deleted system's 0.6 HitStunDuration despite landing above it now, in the
	-- sense that matters: this one also cancels the victim's own in-flight swing (see this table's own
	-- header), which that predecessor never did. Longer in seconds, but strictly more per second than
	-- its predecessor was, exactly as the previous 0.45 already reasoned -- raising the number further
	-- does not undo that comparison, it just moves where the two curves cross.
	--
	-- The bound that keeps it fair: every hit that causes hitstun was itself avoidable -- blockable,
	-- parryable, or duckable by spacing -- and the telegraph is the same Windup every attack already
	-- authors. It is short and fixed, so no chain of them is an infinite stun. And it widens rather than
	-- threatens AttackConstants.Input.BufferSeconds' own margin below it (0.35): that constant's whole
	-- job is expiring a press buffered at the moment of being hit rather than firing it the instant
	-- hitstun clears, and every second this number gains is a second more room for that rule to hold.
	Seconds = 0.65,

	-- PER-STAGE, then PER-WEAPON, OVERRIDES of Seconds -- the same shape and the same "replaces, does not
	-- multiply" rule as AttackConstants.Tempo.ByStage/ByWeapon. A weapon's entry wins over the stage's, and a
	-- stage neither names stuns for Seconds. DefaultMoveRegistry stamps the resolved value on each Default move
	-- (MoveDefinition.HitstunSeconds); a custom Move Editor move stuns for Seconds.
	--
	-- WHY FISTS HAVE THEIR OWN (2026-09-30): "defending against hands is literally impossible." Measured,
	-- not guessed: the M1 clips are 0.583s with no Hit marker (Studio boot log), and Fists played them at
	-- WeaponSpeed 1.5 x Tempo 0.72. Impact to impact came to 0.66s against the shared 0.65s stun, so the next
	-- punch landed 0.01s after the stun ended, and any contact past the first active frame landed INSIDE it
	-- -- a true combo. A jab stunning less than a sword cut is the honest fix: slowing the punches enough to
	-- open the same gap would make hands slower to throw than their weight suggests, on every press.
	--
	-- BOUNDS: every entry must stay above AttackConstants.Input.BufferSeconds (0.35), or a press buffered at
	-- the moment of being hit fires the instant the stun clears instead of expiring. And the read must stay
	-- SHORTER than the weapon's own M1 windup, so the attacker still wins a straight M1 mash-out on a kept
	-- rhythm: answering a string is a parry, a block or an evade, not a button race.
	-- Tests/Combat/Attack/AttackRequestSystem.spec.lua holds every roster weapon's M1 string to a parry read.
	--
	-- THE RESPONSIVENESS PASS (2026-09-30, "combat in general feels pretty unresponsive"). The blade M1 took
	-- 0.48s to land and 1.02s to cycle: the 2026-09-28 pacing pass bought the defender's parry read by
	-- slowing the ATTACKER (Tempo 0.65, ChainDelay 0.12), because the stun was one fixed 0.65s. With a
	-- per-stage stun the read can be bought from the stun instead. So the string is faster (Tempo.ByStage.
	-- Basic 0.8, ChainDelay 0.05 -- see those) and an M1 stuns for less:
	--
	--   Blade (speed 1, 0.583s clip): windup 0.39, impact to impact 0.78 (was 1.02), read 0.78 - 0.45 = 0.33
	--   (was 0.37). Fists (speed 1.5, Tempo 0.65): windup 0.32, impact to impact 0.65, read 0.65 - 0.40 = 0.25.
	--
	-- THE READ IS HELD NEAR THE BLADE'S OLD 0.37 ON PURPOSE. 2026-09-28 found ~0.2s "not nearly enough time
	-- to even try to parry"; this pass makes the attacker faster, not the defender's window smaller. Every
	-- weapon still wins a straight M1 mash-out on a kept rhythm (the defender's own windup outlasts the read).
	-- The launcher off a landed B3 is now a read too (~0.24s after the stun on a blade, was ~0.07s) -- no
	-- ground move is a true combo off an M1.
	ByStage = {
		Basic = 0.45,
	} :: { [string]: number },
	ByWeapon = {
		Fists = {
			Basic = 0.40,
		},
	} :: { [string]: { [string]: number } },

	-- M1s LINK (2026-10-06, "clunky, not smooth like a battlegrounds game"). Everything above made a landed
	-- M1 a parry READ: the defender came out of the stun ~0.25s before the next punch. In play that read as
	-- stop-start -- every exchange broke after one hit into a scramble of blocks, trades and clashes. Now a
	-- landed Basic that has a NEXT Basic in its string stuns until that next hit arrives:
	--
	--   stun = this swing's Active + Recovery + Sequence.ChainDelaySeconds + the next stage's Windup + margin
	--
	-- measured on the CLIP-SYNCED timeline (Server/Combat/AttackCatalog.Get works it out, so every weapon,
	-- at every WeaponSpeed and Tempo, links without a hand-typed number). That is impact to impact on the
	-- attacker's best rhythm -- contact on the first active frame, the next press buffered -- plus a margin
	-- for a contact a little later in the window. A player who presses late drops the string; that is the
	-- skill, not a bug.
	--
	-- The values above still apply to the LAST Basic in a string (nothing follows it to link into), so a
	-- finished string ends with the defender free a beat before the launcher can land -- that is still a read.
	--
	-- THE ANSWER IS THE STUN PARRY (DefenseConstants.StunParry): a stunned defender cannot block or evade, but
	-- a timed parry on the next impact breaks the string. That is what keeps "defending against hands" possible
	-- with no gap between hits.
	--
	-- LinkMarginSeconds is kept SHORT on purpose. A generous one starts covering the windup of something that
	-- is not the next M1 -- a Heavy off a landed M1 would become guaranteed -- and the link should guarantee the
	-- next M1, not every follow-up.
	--
	-- BUT NEVER SHORTER THAN THE PARRY REWIND (DefenseConstants.Parry.RewindMaxSeconds, 0.12). Against a laggy
	-- defender the next hit is HELD up to that long before it applies, waiting to see whether a parry press is
	-- still in flight -- and it is that hit that extends the stun. A margin under the hold would leave the
	-- defender free for the difference, mid-string, on the server: long enough for a buffered evade to come out.
	-- Tests/Combat/Attack/AttackRequestSystem.spec.lua asserts the ordering.
	LinkBasicString = true,
	LinkMarginSeconds = 0.14,
}

-- The hitstun one stage of one weapon's string inflicts: that weapon's ByWeapon override when it names the
-- stage, else the ByStage value, else Hitstun.Seconds. Read LIVE on every call, like AttackConstants.TempoFor.
function DamageConstants.HitstunFor(weaponId: string?, stage: string?): number
	local HITSTUN = DamageConstants.Hitstun
	if not stage then
		return HITSTUN.Seconds
	end
	local override = if weaponId then HITSTUN.ByWeapon[weaponId] else nil
	return (override and override[stage]) or HITSTUN.ByStage[stage] or HITSTUN.Seconds
end

-- Impact --------------------------------------------------------------------------------------------

-- Damage that is not a swing or a shot (DamageSystem.ApplyImpact -- a thrown body landing). Its outcome's
-- Report.DebugName: deliberately not a MoveId, so nothing keyed on a move mistakes an impact for one.
DamageConstants.Impact = {
	DebugName = "impact",
}

-- Combo ---------------------------------------------------------------------------------------------

DamageConstants.Combo = {
	-- How long after a LANDED hit the attacker's string stays connected. A hit landed inside this
	-- window escalates; one landed after it starts again at stage 1.
	--
	-- NO LONGER BOUND BELOW THE STAGGER (2026-10-07). This window used to have to stay shorter than
	-- DefenseConstants.Stagger.DurationSeconds so that a parry lapsed the parried attacker's combo on its
	-- own. That stopped being the design on 2026-09-29: a parried MELEE swing deliberately KEEPS its chain
	-- (AttackRequestSystem.KeepChainThroughParry holds this combo a full window past the stagger). The one
	-- parry the hold does not cover is a reflected shot whose move staggers its thrower (StaggersOwner):
	-- its combo may outlive the 0.9s stagger by the difference, and only Heavies, arts and shots escalate
	-- (M1s and air hits are flat-priced). ComboEscalation.spec pins that leftover under one Basic swing.
	--
	-- RAISED FROM 0.9 TO 1.15 with AttackConstants.Tempo (M1s at 0.75x). The slowed string lands its hits
	-- further apart -- stage 2 into 3 came out at ~0.9s hit-to-hit on the authored numbers alone, i.e. AT
	-- the old window -- and a string whose gaps outgrow this number can never reach its Finisher. Scaled
	-- with the string rather than left at the edge, and kept under AttackConstants.Sequence.ResetSeconds
	-- (1.2), which is deliberately the longer of the two.
	WindowSeconds = 1.15,

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
	--
	-- ONLY REACHES BODIES THE SERVER OWNS, which in practice is bots and training dummies. A player's
	-- character is network-owned by that player's own client: the client simulates it and replicates
	-- the result, so this Humanoid:Move() write lands on the server's follower copy and is replaced by
	-- the owner's next replicated frame. It moves no player, silently, with nothing logged anywhere --
	-- which is exactly how it read as working. Left enabled rather than deleted because for an NPC it
	-- is still the correct and only place to write this.
	--
	-- The player-facing half is AttackConstants.Presentation.SwingLunge, driven from
	-- Client/Combat/SwingLunge.lua on the acting client. Two mechanisms rather than one is not the
	-- "one system, two configs" trap: they run on different machines for different bodies and neither
	-- can reach the other's, so there is no pair of numbers here that can silently disagree. They ARE
	-- deliberately different moments -- this one fires on a landed hit, that one on the throw -- see
	-- that constant's own comment for why the throw is the right moment for a body you can see.
	Enabled = true,
	DurationSeconds = 0.08,
}

-- Kill credit ---------------------------------------------------------------------------------------

-- Read by Server/Systems/PlayerDeathSystem.lua, which owns kill attribution -- NOT by this layer, which
-- still attributes nothing (see DamageSystem.lua's header). It lives here rather than beside its reader
-- because what it bounds is a property of damage: how long a blow this layer applied stays the
-- explanation for a death that follows it.
DamageConstants.KillCredit = {
	-- How long after a player last removed health from another player that player still counts as the
	-- killer. A death inside the window credits them; a death after it is unattributed.
	--
	-- LONGER THAN ZERO BECAUSE MOST PvP DEATHS ARE NOT THE BLOW ITSELF. A lethal hit dies on the frame it
	-- lands and needs no window at all -- but a player knocked off a ledge, into the void, or who bleeds
	-- out on a hazard mid-fight died OF that fight, and fight-to-grow owes the attacker for it.
	--
	-- SHORT BECAUSE AN ESCAPE MUST END THE DEBT. Someone who got away and fell off a cliff unrelated to
	-- anything thirty seconds later did not lose a fight, and a window that long would sell progression
	-- to whoever last chipped them. 10s covers a knock-off's fall and a short chase; it is a starting
	-- point to tune against playtest deaths, not a derived number.
	--
	-- MUST STAY <= EngagementConstants.TagDurationSeconds (30): a credited death then always lands
	-- inside a live combat tag, so "who killed me" can never name someone the HUD had already stopped
	-- calling your opponent. Tests/Progression/PlayerDeathSystem.spec.lua asserts it.
	WindowSeconds = 10,
}

-- Knockback -----------------------------------------------------------------------------------------

-- How a move's authored knockback (MoveTypes.MoveKnockback, per move in the Move Editor) becomes a
-- launch. The NUMBERS of a knock stay authored per move -- as with damage, a knock strength here would
-- be a second authority competing with the editor. What lives here is what no single move can own:
-- the safety bounds on any launch, how the defender's client holds it, and the anti-cheat budgets.
DamageConstants.Knockback = {
	-- Master switch. Off returns every hit to "resolved, applied by nothing".
	Enabled = true,
	-- Ceilings on any launch, whatever a move authored. A mis-typed 900 in the Move Editor should knock
	-- someone across an arena, not out of the map. Roblox gravity is 196.2 studs/s^2, so 70 up is a
	-- ~12.5 stud apex -- a real launch, well short of throwing anyone onto a roof.
	MaxHorizontalVelocity = 90,
	MaxUpVelocity = 70,
	-- Seconds the defender's client keeps writing the HORIZONTAL part of the launch, decaying linearly
	-- to nothing (Client/Combat/KnockbackClient.lua). Needed because a grounded Humanoid's own walk
	-- controller drags horizontal velocity back toward its input within a couple of frames -- a single
	-- write would read as a flinch, not a knock. The vertical part is written once and left to gravity.
	HoldSeconds = 0.18,
	-- How long after a launch a player's movement is allowed to look like it (Attributes.KnockbackUntil).
	-- Longer than HoldSeconds plus a network round trip plus an apex's fall, so a parkour report that
	-- spans an honest launch never counts toward the cheater flag.
	MovementAllowanceSeconds = 2,
	-- The anti-knockback audit (Server/Combat/Damage/KnockbackAudit.lua): after launching a PLAYER, the
	-- server watches that body's replicated velocity; a client that honoured the launch shows speed
	-- along its direction at some sample, one that ignored it does not.
	Audit = {
		Enabled = true,
		-- Launches weaker than this horizontally are not audited: below it an honest knock and a player
		-- simply running (RunConstants tops out near 48) cannot be told apart.
		MinHorizontalVelocity = 30,
		-- Seconds of samples after the launch. Covers the client's hit-stop freeze (<= 0.14s), the
		-- round trip for the launch to arrive and its result to replicate back, with room to spare.
		SampleSeconds = 1.25,
		-- Pass when the best sample's speed along the launch direction reaches this fraction of the
		-- launch's horizontal speed.
		ComplianceFraction = 0.4,
		-- Flag through ModerationSystem ("System" source, once per session) after this many failed
		-- audits within WindowSeconds -- a pattern, never one lost packet.
		FailuresBeforeFlag = 6,
		WindowSeconds = 120,
	},
}

-- Spacing -------------------------------------------------------------------------------------------

-- THE PUSH EVERY CONTACT GIVES, for moves that author no knockback of their own (every Default M1 and
-- Heavy today). Before this a landed or blocked string moved nobody. Blocked strings left both fighters
-- glued together, and a landed string's spacing depended on whoever happened to be walking.
--   * Hit (Clean, Backstab, GuardBroken): the defender slides back DefenderStuds, and the ATTACKER follows
--     by AttackerFollowStuds. Equal distances keep the gap the same from B1 to B3 and into the launcher,
--     so the string stays in range without a gap-closing lunge (the thing SwingLunge's Basic entry was
--     removed for).
--   * Blocked: both are pushed APART. The defender slides back further than on a hit, and the attacker
--     rebounds a little, so a blocked string separates and has to be walked back into.
--   * Clash (a Trade -- DefenseConstants.Clash): both are pushed apart by the SAME distance, since neither
--     won the exchange. The mirrored outcome of a mutual clash pushes the same two bodies the same way, and
--     a client push replaces rather than adds (KnockbackClient.Push), so it is never applied twice.
-- Distances in studs. The client holds a linear decay over DamageConstants.Knockback.HoldSeconds, so the
-- speed is 2 * studs / HoldSeconds (about 13 studs/s for 1.2). That is well under Knockback.Audit's
-- MinHorizontalVelocity, so a push is never audited as a knockback.
-- Never applied to an air-combo move or an air-held body (the air combo owns both), to a grab, or to a
-- move whose own authored knockback already launched the defender.
DamageConstants.Spacing = {
	Enabled = true,
	Hit = { DefenderStuds = 1.2, AttackerFollowStuds = 1.2 },
	Blocked = { DefenderStuds = 1.8, AttackerStuds = 0.7 },
	Clash = { Studs = 1.4 },
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
