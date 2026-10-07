--!strict
--[[
	SwingSequencer.lua

	Owns: per-combatant "which move does the next press throw" -- the string position, the weapon it
	is a string OF, and the one rule that makes a completed Basic string's 4th press the air combo's
	LAUNCHER (Space + M1 after B3 -- docs/design/air-combat-and-evade.md B2).

	THE 4TH M1 IS THE LAUNCHER, AND NOTHING ELSE. The Basic string is three stages; a completed string used
	to tip its next press into the weapon's Finisher once the landed combo was deep enough. That tip is gone:
	the only 4th hit of an M1 string is Space + M1, and a plain M1 after B3 starts a fresh string at B1 once
	the end-of-string lockout has passed. (The Finisher MOVE is still catalogued -- the launcher and the
	Spike borrow its clip until their own are authored -- it is simply not thrown by an M1 any more.)

	THROW-BASED, NOT LANDING-BASED, and this is the older half of a split this codebase has made
	before. The deleted CombatTypes.lua carried two separate counters on purpose: basicSwingIndex
	advanced on every swing THROWN (so the animation string cycled even while missing) and
	basicComboLanded advanced only on hits that CONNECTED (so the launcher could not be earned by
	flailing at air). Those are this module and ComboEscalation respectively, and keeping them apart
	is the whole reason a whiffed string still looks like a string while a whiffed string still earns
	nothing.

	So: this module advances on every ACCEPTED throw regardless of outcome, and lapses on its own
	after AttackConstants.Sequence.ResetSeconds of no throw. It never learns whether anything landed.
	It asks ComboEscalation exactly one question -- "how deep is this attacker's landed combo" -- and
	only to decide the launcher, which is the single place the two counters legitimately meet.

	NO KNOWLEDGE OF HOW MANY STAGES A STRING HAS. The stage count is discovered by probing
	AttackCatalog for consecutive MoveIds rather than read from CombatConstants.Weapons, so widening
	a string is a data edit in one place and this module never drifts from it. The probe is memoised
	because the stage ARRAYS are fixed at file scope -- DefaultMoveRegistry.ApplyEdit mutates a
	stage's fields in place and never adds or removes one -- so a count, unlike a move's contents,
	genuinely cannot change at runtime. (This is the one thing here that is cached, and the comment
	is the justification AttackCatalog's own "NO CACHE, deliberately" header would otherwise
	contradict.)

	TWO THINGS DO NOT SPEND A STAGE (2026-09-29). An Art woven in mid-string holds the string's place
	(Weave), and a PARRIED swing hands its stage back once the stagger ends (RestoreParried). Both are
	here because both are "where is the string", and both leave the landed-combo half to the caller.

	PURE OF THE CLOCK. Time comes from the caller on every entry point, never from os.clock() here --
	the same rule DefenseStateMachine, GuardMeter and ComboEscalation all keep, and what lets the
	whole module be driven on a synthetic clock by its spec with nothing sleeping.

	Does not own: whether a throw is allowed (AttackRequestSystem gates it through DefenseSystem/
	DamageSystem), what a move IS (AttackCatalog and the Move Creation System behind it), landed-combo
	escalation (ComboEscalation), or anything about contact (HitboxEngine).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)
local AirComboTypes = require(ReplicatedStorage.Shared.AirCombo.AirComboTypes)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local AttackCatalog = require(script.Parent.Parent.AttackCatalog)

type AttackKind = AttackTypes.AttackKind
type MoveRole = AirComboTypes.MoveRole
type WeaponId = Types.WeaponId

-- Which stage of which string a combatant is on, and what they are holding. One record per model,
-- created on first use.
--
-- WeaponId outlives the string, which is why the record is not simply dropped when a string lapses:
-- a player who swapped weapons and then stood still for a minute is still holding that weapon.
-- Only a destroyed model drops its record -- see Sweep.
--
-- OPTIONAL because the roster can legitimately be empty (no models in Workspace.Weapons) -- see
-- WeaponRoster.Default. nil means "empty-handed", and Resolve reads it as "throw nothing" rather than
-- substituting a weapon nobody equipped.
type Record = {
	WeaponId: WeaponId?,
	-- Which string StageIndex belongs to. nil when no string is in progress.
	Category: AttackKind?,
	-- 0 means "nothing thrown yet, or the last throw was a Finisher" -- both resolve to stage 1 next.
	StageIndex: number,
	-- ABSOLUTE time the string lapses: when the last accepted throw's own commitment (windup + active
	-- + recovery) ends, plus AttackConstants.Sequence.ResetSeconds.
	--
	-- Stored as an absolute deadline rather than as "when did you last throw", so the grace period is
	-- measured from the moment the thrower got control back rather than from the moment they lost it.
	-- See ResetSeconds' own header for the concrete bug that distinction avoids -- a slow move can
	-- outlive a start-relative window and make its own next stage unreachable.
	LapsesAt: number,
	-- ABSOLUTE time the next stage of a string may be thrown: the same commitment end, plus
	-- AttackConstants.Sequence.ChainDelaySeconds. The deliberate beat between links. Also the time the
	-- launcher may follow a completed string -- see LockedUntil.
	--
	-- Always <= LapsesAt by construction (ChainDelaySeconds is far smaller than ResetSeconds), so
	-- there is never a window where the string is unusable but not yet lapsed.
	ChainReadyAt: number,
	-- ABSOLUTE time a completed string's END-OF-STRING LOCKOUT (EndOfStringCooldownSeconds) ends, or
	-- -math.huge when none is running. Separate from ChainReadyAt because the two presses that can follow a
	-- finished string owe different things: the LAUNCHER owes only the ordinary beat (it IS the string's
	-- 4th link, and a 0.5s pause before it would outrun the combo window it needs), while any other press
	-- -- a fresh string, a Heavy -- owes the lockout that stops a completed string being followed by a new
	-- one instantly.
	LockedUntil: number,
	-- What the string looked like just BEFORE the most recent throw, kept so a parry can hand it back
	-- (RestoreParried). nil once used, and after anything that ends the string on purpose (a swap, a
	-- sheathe, a feint), because restoring across those would bring back a string the player gave up.
	Undo: Undo?,
}

-- One throw's worth of undo. Keyed by MoveId so a parry reported for an OLDER swing can never rewind a
-- newer one. Category is nil when no string was live before the throw -- restoring that is "start at 1".
type Undo = {
	MoveId: string,
	Category: AttackKind?,
	StageIndex: number,
	LockedUntil: number,
}

local SwingSequencer = {}

local records: { [Model]: Record } = {}

-- The round-robin cursor Sweep below walks -- see Shared/AmortizedReclaim.lua.
local recordsReclaim = AmortizedReclaim.New()

-- Keyed "weaponId|category". See this file's header for why caching this is safe when caching a
-- move's contents would not be.
local stageCounts: { [string]: number } = {}

-- Ids ----------------------------------------------------------------------------------------------

-- The id scheme is DefaultMoveRegistry's, restated here rather than exported from there because this
-- module builds ids to PROBE for and that module builds them to describe what it already holds --
-- the coupling is to the naming convention, which is stable, not to that module's enumeration.
local function stageMoveId(weaponId: WeaponId, category: AttackKind, stageIndex: number): string
	return `default:{weaponId}:{category}:{stageIndex}`
end

-- How many stages this weapon's string has. Counts up from 1 until the catalogue stops resolving,
-- which is the definition of "the string ends here" that cannot go stale.
local function stageCountFor(weaponId: WeaponId, category: AttackKind): number
	local key = `{weaponId}|{category}`
	local cached = stageCounts[key]
	if cached ~= nil then
		return cached
	end

	local count = 0
	for stageIndex = 1, AttackConstants.Sequence.MaxStageProbe do
		if not AttackCatalog.Has(stageMoveId(weaponId, category, stageIndex)) then
			break
		end
		count = stageIndex
	end

	stageCounts[key] = count
	return count
end

export type StageMove = { MoveId: string, Kind: AttackKind, StageIndex: number }

-- Every ground-string stage this weapon can throw, Basic then Heavy, in stage order -- exactly the ids
-- Resolve probes for, built by the same two helpers. For the attack layer's prediction seed
-- (AttackRequestSystem.predictionSeedFor), which hands the client one template per stage.
function SwingSequencer.StageMoveIds(weaponId: WeaponId): { StageMove }
	local stages: { StageMove } = {}
	local function addAll(kind: AttackKind)
		for stageIndex = 1, stageCountFor(weaponId, kind) do
			table.insert(
				stages,
				{ MoveId = stageMoveId(weaponId, kind, stageIndex), Kind = kind, StageIndex = stageIndex }
			)
		end
	end
	addAll("Basic")
	addAll("Heavy")
	return stages
end

-- Records --------------------------------------------------------------------------------------------

local function recordFor(model: Model): Record
	local existing = records[model]
	if existing then
		return existing
	end
	local created: Record = {
		-- EMPTY-HANDED. A combatant holds nothing until something puts a weapon in their hand --
		-- Server/Combat/Weapon/WeaponInventorySystem.lua, when the player draws one they have picked
		-- up. This used to default to the roster's first weapon, which meant every fresh spawn came
		-- with a free sword already out and made the whole pickup/draw loop unreachable.
		WeaponId = nil,
		Category = nil,
		StageIndex = 0,
		LapsesAt = -math.huge,
		ChainReadyAt = -math.huge,
		LockedUntil = -math.huge,
	}
	records[model] = created
	return created
end

-- Whether the string a record holds is still live for `category` at `now`. Two ways it is not: the
-- deadline passed, or the player switched strings (which restarts the one they left -- see
-- AttackConstants.Sequence.ResetOnCategorySwitch).
local function stringIsLive(record: Record, category: AttackKind, now: number): boolean
	if record.Category == nil then
		return false
	end
	if now > record.LapsesAt then
		return false
	end
	if record.Category ~= category then
		return not AttackConstants.Sequence.ResetOnCategorySwitch
	end
	return true
end

-- The string as it stands at `now`, captured before a throw changes it. A string that has already lapsed
-- is captured as no string at all, so a restore can never bring back one that was dead before the throw.
local function snapshotFor(record: Record, moveId: string, now: number): Undo
	local live = record.Category ~= nil and now <= record.LapsesAt
	return {
		MoveId = moveId,
		Category = if live then record.Category else nil,
		StageIndex = if live then record.StageIndex else 0,
		LockedUntil = record.LockedUntil,
	}
end

local function safeSeconds(seconds: number): number
	-- Guarded rather than trusted: a NaN or negative commitment would produce a deadline that every
	-- comparison fails, which reads in play as "the string never continues" with nothing logged.
	return if typeof(seconds) == "number" and seconds == seconds then math.max(seconds, 0) else 0
end

-- Public ---------------------------------------------------------------------------------------------

-- What this combatant is currently holding -- exactly one weapon, or nil for an empty roster.
function SwingSequencer.GetWeapon(model: Model): WeaponId?
	return recordFor(model).WeaponId
end

-- Cycles to the next weapon in the roster (WeaponRoster.Order) and returns it.
--
-- The in-progress string is abandoned rather than carried across: stage 2 of one weapon's string is
-- not stage 2 of another's, and continuing the count into a different move set would throw a move the
-- player never worked up to. Cheaply done by clearing Category, which stringIsLive already reads as
-- "no string in progress" without a second flag.
function SwingSequencer.SwapWeapon(model: Model, now: number): WeaponId?
	local record = recordFor(model)
	local current = record.WeaponId
	local nextWeapon = if current then WeaponRoster.Next(current) else WeaponRoster.Default()
	if not nextWeapon then
		return nil
	end

	record.WeaponId = nextWeapon
	record.Category = nil
	record.StageIndex = 0
	record.LapsesAt = now
	record.Undo = nil
	-- Not cleared to `now`: a swap must not be a way to skip the beat you owe for the swing you just
	-- threw. Whatever chain delay was already running keeps running.
	return nextWeapon
end

-- Sets the weapon outright, for a caller that knows which one it wants (a loadout system, a spec).
-- Returns false for an id the roster doesn't know rather than accepting an arbitrary string -- with
-- WeaponId now an open type (see Types.WeaponId), this check is the ONLY thing standing between a
-- client-supplied string and a combatant claiming to hold a weapon that does not exist.
function SwingSequencer.SetWeapon(model: Model, weaponId: WeaponId, now: number): boolean
	if not WeaponRoster.Has(weaponId) then
		return false
	end
	local record = recordFor(model)
	if record.WeaponId == weaponId then
		return true
	end
	record.WeaponId = weaponId
	record.Category = nil
	record.StageIndex = 0
	record.LapsesAt = now
	record.Undo = nil
	-- Not cleared to `now`: a swap must not be a way to skip the beat you owe for the swing you just
	-- threw. Whatever chain delay was already running keeps running.
	return true
end

-- Puts this combatant's hands empty, abandoning any string in progress -- what sheathing is, and the
-- exact state a fresh record starts in. Resolve already refuses for a record with no weapon, so this
-- is the whole of "you cannot swing a sword you have put away": no gate, no flag, no second source of
-- truth about what is in someone's hand.
function SwingSequencer.ClearWeapon(model: Model, now: number): ()
	local record = recordFor(model)
	record.WeaponId = nil
	record.Category = nil
	record.StageIndex = 0
	record.LapsesAt = now
	record.Undo = nil
	-- ChainReadyAt deliberately untouched, same as SwapWeapon/SetWeapon: sheathing must not be a way
	-- to skip the beat you still owe for the swing you just threw.
end

export type Resolution = {
	MoveId: string,
	-- Always set for a weapon-stage resolution (Resolve refuses outright with no weapon in hand).
	-- Optional only because an Art thrown from a Hotbar slot is a move a combatant can legitimately
	-- throw empty-handed -- see AttackRequestSystem's resolveFromEquippedArt.
	WeaponId: WeaponId?,
	-- 0 for the Launcher and the air moves (neither is a stage of the ground string).
	StageIndex: number,
	-- The air combo (docs/design/air-combat-and-evade.md B2). Set when this press resolved to the Launcher
	-- branch, or to an air move / finisher inside a live combo. Either one ENDS the ground string (see
	-- Advance): stage 2 of a string is not stage 2 of an air string, and a launch is that string's payoff.
	IsLauncher: boolean?,
	AirRole: MoveRole?,
}

-- What a press brings with it beyond its kind. ModifierUp is Space held at the press (AttackRequest.
-- Modifier); AirRole is the air move AirComboSystem says this press means, present only while this
-- combatant is a live combo's attacker. Both optional so every existing caller keeps its meaning.
export type ResolveOptions = {
	ModifierUp: boolean?,
	AirRole: MoveRole?,
}

local function airMoveId(weaponId: WeaponId, role: MoveRole): string?
	if role.Role == "Air" and role.Beat then
		return AirComboMoves.AirId(weaponId, role.Beat)
	elseif role.Role == "Finisher" and role.Finisher then
		return AirComboMoves.FinisherId(weaponId, role.Finisher)
	end
	return nil
end

-- Which move the next `category` press means, WITHOUT committing to it.
--
-- Split from Advance below on purpose: a resolution is needed BEFORE the gates run (the catalogue
-- lookup, the per-move cooldown check and HitboxEngine.RequestAttack all need to know which move
-- this is), and a press that is then refused must not have moved the string on. Only an accepted
-- throw calls Advance.
--
-- `comboStage` is the attacker's landed-combo depth (ComboEscalation.GetStage), consulted for the
-- finisher and nothing else. Returns nil when the weapon has no authored string of this kind at all,
-- which callers must treat as "do not swing" rather than substituting anything.
function SwingSequencer.Resolve(
	model: Model,
	category: AttackKind,
	comboStage: number,
	now: number,
	options: ResolveOptions?
): Resolution?
	local record = recordFor(model)
	local weaponId = record.WeaponId
	if not weaponId then
		-- Empty-handed: an empty roster, or a weapon deleted out from under this combatant. Nothing to
		-- swing, and the caller's existing "no authored string" path already means exactly that.
		return nil
	end

	-- IN THE AIR, the air combo has already decided what this press means (AirComboMachine.ResolvePress);
	-- this only turns that into the weapon's own move. A weapon with no air moves authored throws nothing,
	-- the same "no authored string" answer as below.
	local airRole = options and options.AirRole
	if airRole then
		local moveId = airMoveId(weaponId, airRole)
		if not moveId or not AttackCatalog.Has(moveId) then
			return nil
		end
		return {
			MoveId = moveId,
			WeaponId = weaponId,
			StageIndex = 0,
			AirRole = airRole,
		}
	end

	-- THE LAUNCHER BRANCH (docs B2). Space + M1 mid-string throws the Launcher instead of the next Basic
	-- when the string has THROWN at least MinStringStage stages and the LANDED combo is at least
	-- MinComboStage -- the same throw-based and landing-based pair the Finisher reads, for the same reason.
	-- Anything short of that falls through to the ordinary next Basic: Space + M1 is never a dead input, and
	-- a forged modifier can only ask for a launcher the string has already earned.
	if
		AirComboConstants.Enabled
		and category == "Basic"
		and options ~= nil
		and options.ModifierUp == true
		and stringIsLive(record, category, now)
		and record.StageIndex >= AirComboConstants.Launcher.MinStringStage
		and comboStage >= AirComboConstants.Launcher.MinComboStage
		and AttackCatalog.Has(AirComboMoves.LauncherId(weaponId))
	then
		return {
			MoveId = AirComboMoves.LauncherId(weaponId),
			WeaponId = weaponId,
			StageIndex = 0,
			IsLauncher = true,
		}
	end

	local count = stageCountFor(weaponId, category)
	if count <= 0 then
		return nil
	end

	local current = if stringIsLive(record, category, now) then record.StageIndex else 0
	local nextStage = current + 1

	if nextStage > count then
		-- The string is complete. Its one 4th hit is the launcher, resolved above for Space + M1; any other
		-- press starts a fresh string at the top (after the end-of-string lockout -- ChainDelayRemaining).
		nextStage = 1
	end

	return {
		MoveId = stageMoveId(weaponId, category, nextStage),
		WeaponId = weaponId,
		StageIndex = nextStage,
	}
end

-- Commits a resolution that was actually thrown. Called only after HitboxEngine has accepted the
-- swing, so a refused press leaves the string exactly where it was.
--
-- `commitmentSeconds` is how long this swing occupies its thrower for -- windup + active + recovery,
-- straight off the definition the engine was just handed. The caller supplies it rather than this
-- module looking it up again, so the number the string's deadline is built from is provably the same
-- one the engine is running (a second AttackCatalog.Get could straddle a live Move Editor edit and
-- disagree with it).
--
-- A Finisher lands the record on StageIndex 0, which the next Resolve reads as "start again at 1" --
-- no special-cased reset path, the same "let the ordinary rule handle it" economy the rest of this
-- stack practices with its own timestamps.
function SwingSequencer.Advance(
	model: Model,
	category: AttackKind,
	resolution: Resolution,
	commitmentSeconds: number,
	now: number
): ()
	local record = recordFor(model)
	-- Kept for RestoreParried, EXCEPT for an air move. A parried air hit is the victim's one way out and
	-- ends the combo (docs/design/air-combat-and-evade.md B4), so there is no string to hand back. The
	-- launcher DOES keep one: it is still a ground swing, and a parried launcher leaves the string at B3.
	record.Undo = if resolution.AirRole == nil then snapshotFor(record, resolution.MoveId, now) else nil
	-- A launcher or an air move ends the ground string: the next ground press starts at stage 1 again. It
	-- still owes the ordinary beat between links, not the end-of-string lockout -- the first air press has
	-- to be throwable a moment after the launch lands.
	local airOrLauncher = resolution.IsLauncher == true or resolution.AirRole ~= nil
	record.Category = if airOrLauncher then nil else category
	record.StageIndex = if airOrLauncher then 0 else resolution.StageIndex
	local commitmentEndsAt = now + safeSeconds(commitmentSeconds)
	record.LapsesAt = commitmentEndsAt + AttackConstants.Sequence.ResetSeconds

	-- Every link owes the ordinary beat. The LAST link of a string also starts the end-of-string lockout,
	-- so a completed string cannot be followed by a fresh one instantly -- but on its own deadline
	-- (LockedUntil), because the launcher that may follow a completed Basic string is that string's 4th
	-- link and owes only the beat. ChainDelayRemaining is what tells the two apart.
	record.ChainReadyAt = commitmentEndsAt + AttackConstants.Sequence.ChainDelaySeconds
	local weaponId = resolution.WeaponId
	local endsString = not airOrLauncher
		and weaponId ~= nil
		and resolution.StageIndex >= stageCountFor(weaponId, category)
	if endsString then
		record.LockedUntil = commitmentEndsAt + AttackConstants.Sequence.EndOfStringCooldownSeconds
	elseif airOrLauncher then
		-- The launcher and the air string replace whatever lockout a completed string left behind: they
		-- ARE that string's continuation.
		record.LockedUntil = -math.huge
	end
end

-- Weaves an Art (a hotbar cast) into whatever string is live, WITHOUT spending or resetting it. Called
-- for every accepted hotbar throw, in place of Advance.
--
-- AN ART IS A LINK THAT HOLDS THE STRING'S PLACE. It is not a stage: B1, B2, an Art, then M1 throws B3, and
-- Space + M1 after that still launches. So the stage and category are left exactly where they were, and
-- only the clock moves:
--   * the string cannot lapse while the art is playing. LapsesAt moves to the art's own end plus the
--     ordinary ResetSeconds grace, the same grace any link gets. A long art used to outlast the grace
--     the M1 before it left, and dropped the player back to B1 for weaving it in.
--   * the next link owes the ordinary beat after the art (ChainReadyAt), so the hit after an art reads as
--     a distinct hit, the same as the hit after any other link. The art itself never waits on the beat.
--     AttackRequestSystem exempts hotbar presses from ChainDelayRemaining, and this does not change that.
--   * the end-of-string lockout (LockedUntil) is left alone. An art after B3 does not refund it, and it
--     does not start one.
--
-- WEAPON-AGNOSTIC BY CONSTRUCTION. Nothing here reads the weapon, so an art weaves into the string of
-- whatever is in hand, fists included, and a string started empty-handed is simply not live.
--
-- Kept for RestoreParried too: a parried art hands the string back exactly as it was, with the clock
-- restarted from the stagger's end.
function SwingSequencer.Weave(model: Model, moveId: string, commitmentSeconds: number, now: number): ()
	local record = recordFor(model)
	record.Undo = snapshotFor(record, moveId, now)
	local endsAt = now + safeSeconds(commitmentSeconds)
	if record.Category ~= nil and now <= record.LapsesAt then
		record.LapsesAt = math.max(record.LapsesAt, endsAt + AttackConstants.Sequence.ResetSeconds)
	end
	record.ChainReadyAt = math.max(record.ChainReadyAt, endsAt + AttackConstants.Sequence.ChainDelaySeconds)
end

-- Hands back the string as it was before the swing that was just PARRIED, and holds it live until the
-- attacker can act again. Returns whether anything was restored.
--
-- "WHEN WE GET PARRIED ON A CHAIN, OUR M1 CHAIN NEEDS TO STAY WHERE IT WAS" (user, 2026-09-29). The parried
-- swing never connected, so it does not spend its stage: B1 and B2 landed, B3 parried, and after the
-- stagger the next M1 is B3 again, with the launcher one press behind it. A parried launcher leaves the
-- string at B3, so Space + M1 tries the launcher again. The landed-combo depth the launcher also needs is
-- held by the caller alongside this call (DamageSystem.HoldCombo). This module never learns about landing.
--
-- `resumeAt` is when the attacker's stagger ends. The string gets the ordinary ResetSeconds grace from
-- THAT moment, because the time spent staggered is not dawdling. Without it the stagger (1.5-1.8s)
-- outlasted the grace the parried swing left, and the string lapsed while the attacker was locked out.
--
-- MATCHED BY MoveId, so a parry of an older swing can never rewind a newer one, and one throw restores at
-- most once. Air moves keep no undo (see Advance), so a parried air hit restores nothing.
--
-- A TRADE uses this too (AttackRequestSystem.KeepChainThroughTrade) and passes `readyAt`: the next link
-- may be thrown from then, replacing the beat the cut swing set. A stagger always outlasts what was left
-- of a parried swing, so a parry never needs it -- but a clash cuts BOTH swings at one instant, and
-- without it each side would wait out whatever was left of its own, turning an even exchange into
-- whoever threw the shorter move going first.
function SwingSequencer.RestoreParried(model: Model, moveId: string, resumeAt: number, readyAt: number?): boolean
	local record = records[model]
	local undo = record and record.Undo
	if not record or not undo or undo.MoveId ~= moveId then
		return false
	end
	record.Undo = nil
	record.Category = undo.Category
	record.StageIndex = undo.StageIndex
	record.LockedUntil = undo.LockedUntil
	record.LapsesAt = resumeAt + AttackConstants.Sequence.ResetSeconds
	if readyAt then
		record.ChainReadyAt = readyAt
	end
	return true
end

-- Abandons the string in progress after a swing was cut short (a feint), KEEPING the weapon: the next
-- press starts at stage 1, and the chain beat is rewritten to `readyAt` -- which may be EARLIER than
-- the beat Advance set, since the swing that owed it never finished. The one place a string's
-- deadline moves backwards, which is why it is its own function rather than a parameter on Advance.
function SwingSequencer.CancelString(model: Model, readyAt: number, now: number): ()
	local record = records[model]
	if not record then
		return
	end
	record.Category = nil
	record.StageIndex = 0
	record.LapsesAt = now
	record.ChainReadyAt = readyAt
	record.Undo = nil
end

-- Seconds until the next stage of a string may be thrown, 0 when it may be thrown now.
--
-- THE BEAT BETWEEN LINKS, and it is this module's to own rather than the request system's for the same
-- reason the stage counter is: it is a property of the string, not of any move in it, and it has to be
-- read from the same record that knows when the last link was thrown. AttackRequestSystem consults it
-- as one more gate and buffers the refusal, so a player pressing through the pause never feels it as a
-- dropped input -- see AttackConstants.Sequence.ChainDelaySeconds' own header.
--
-- Applies to BOTH strings from one record, deliberately: a player alternating Basic and Heavy presses
-- must not be able to interleave their way past a pause that exists to keep hits distinct. Switching
-- strings already restarts the stage counter; it does not refund the beat.
--
-- `resolution` is the press being judged. A completed string's end-of-string lockout binds every press
-- EXCEPT the launcher and the air string, which owe only the beat (see Record.LockedUntil). Omitted, the
-- lockout binds -- the conservative answer for a caller that has not resolved a press.
function SwingSequencer.ChainDelayRemaining(model: Model, now: number, resolution: Resolution?): number
	local record = records[model]
	if not record then
		return 0
	end
	local continuesString = resolution ~= nil and (resolution.IsLauncher == true or resolution.AirRole ~= nil)
	local readyAt = if continuesString then record.ChainReadyAt else math.max(record.ChainReadyAt, record.LockedUntil)
	return math.max(readyAt - now, 0)
end

-- The string position only, for a HUD or a spec. Returns 0 when no string is in progress.
function SwingSequencer.GetStageIndex(model: Model, category: AttackKind, now: number): number
	local record = records[model]
	if not record then
		return 0
	end
	return if stringIsLive(record, category, now) then record.StageIndex else 0
end

-- Which string is live at `now` and how far into it, or (nil, 0) when none is. For the client mirror
-- AttackRequestSystem sends after a parry, and for a spec.
function SwingSequencer.GetString(model: Model, now: number): (AttackKind?, number)
	local record = records[model]
	if not record or record.Category == nil or now > record.LapsesAt then
		return nil, 0
	end
	return record.Category, record.StageIndex
end

-- Drops one combatant's whole record, weapon included. For a character being removed -- a new life
-- starts on the default weapon with no string, which is the same state a first-time combatant has.
function SwingSequencer.Clear(model: Model): ()
	records[model] = nil
end

-- Reclaims records for models that no longer exist. Returns how many were dropped this call.
--
-- DELIBERATELY NOT AN EXPIRY SWEEP. A lapsed string is already handled by stringIsLive reading the
-- timestamp at resolve time, and dropping the record would take the WeaponId with it -- a player who
-- swapped weapons and then stood still would silently be handed Primary back. Only a destroyed model
-- loses its record.
--
-- AMORTISED, NOT EXHAUSTIVE, as of the reclaim pass: one call examines a fixed handful of records
-- rather than the whole table, so a destroyed model is reclaimed within a few frames rather than on
-- the very next one. Nothing observes the difference -- every read of `records` either finds a record
-- and timestamp-checks it, or builds a fresh one on demand -- which is precisely the property that
-- makes it safe here and NOT safe for a loop that does per-entry work. See
-- Shared/AmortizedReclaim.lua's own header for that distinction.
function SwingSequencer.Sweep(): number
	return recordsReclaim:Step(records)
end

-- Spec-only, so one case cannot serve another its state -- the same role HitboxEngine.Reset,
-- DefenseSystem.Reset and DamageSystem.Reset play for their own modules. Clears the memoised stage
-- counts too, since a spec may legitimately reshape the registry between cases.
function SwingSequencer.Reset(): ()
	table.clear(records)
	recordsReclaim:Reset()
	table.clear(stageCounts)
end

return SwingSequencer
