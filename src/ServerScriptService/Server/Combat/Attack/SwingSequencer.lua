--!strict
--[[
	SwingSequencer.lua

	Owns: per-combatant "which move does the next press throw" -- the string position, the weapon it
	is a string OF, and the one rule that tips a completed Basic string into a Finisher.

	THROW-BASED, NOT LANDING-BASED, and this is the older half of a split this codebase has made
	before. The deleted CombatTypes.lua carried two separate counters on purpose: basicSwingIndex
	advanced on every swing THROWN (so the animation string cycled even while missing) and
	basicComboLanded advanced only on hits that CONNECTED (so the finisher could not be earned by
	flailing at air). Those are this module and ComboEscalation respectively, and keeping them apart
	is the whole reason a whiffed string still looks like a string while a whiffed string still earns
	nothing.

	So: this module advances on every ACCEPTED throw regardless of outcome, and lapses on its own
	after AttackConstants.Sequence.ResetSeconds of no throw. It never learns whether anything landed.
	It asks ComboEscalation exactly one question -- "how deep is this attacker's landed combo" -- and
	only to decide the finisher, which is the single place the two counters legitimately meet.

	NO KNOWLEDGE OF HOW MANY STAGES A STRING HAS. The stage count is discovered by probing
	AttackCatalog for consecutive MoveIds rather than read from Constants.Combat.Weapons, so widening
	a string is a data edit in one place and this module never drifts from it. The probe is memoised
	because the stage ARRAYS are fixed at file scope -- DefaultMoveRegistry.ApplyEdit mutates a
	stage's fields in place and never adds or removes one -- so a count, unlike a move's contents,
	genuinely cannot change at runtime. (This is the one thing here that is cached, and the comment
	is the justification AttackCatalog's own "NO CACHE, deliberately" header would otherwise
	contradict.)

	PURE OF THE CLOCK. Time comes from the caller on every entry point, never from os.clock() here --
	the same rule DefenseStateMachine, GuardMeter and ComboEscalation all keep, and what lets the
	whole module be driven on a synthetic clock by its spec with nothing sleeping.

	Does not own: whether a throw is allowed (AttackRequestSystem gates it through DefenseSystem/
	DamageSystem), what a move IS (AttackCatalog and the Move Creation System behind it), landed-combo
	escalation (ComboEscalation), or anything about contact (HitboxEngine).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local AttackCatalog = require(script.Parent.Parent.AttackCatalog)

type AttackKind = AttackTypes.AttackKind
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
	-- AttackConstants.Sequence.ChainDelaySeconds. The deliberate beat between links.
	--
	-- Always <= LapsesAt by construction (ChainDelaySeconds is far smaller than ResetSeconds), so
	-- there is never a window where the string is unusable but not yet lapsed.
	ChainReadyAt: number,
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

local function finisherMoveId(weaponId: WeaponId): string
	return `default:{weaponId}:Finisher`
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
	-- ChainReadyAt deliberately untouched, same as SwapWeapon/SetWeapon: sheathing must not be a way
	-- to skip the beat you still owe for the swing you just threw.
end

export type Resolution = {
	MoveId: string,
	-- Always set for a weapon-stage resolution (Resolve refuses outright with no weapon in hand).
	-- Optional only because an Art thrown from a Hotbar slot is a move a combatant can legitimately
	-- throw empty-handed -- see AttackRequestSystem's resolveFromEquippedArt.
	WeaponId: WeaponId?,
	-- 0 for the Finisher, matching DefaultMoveRegistry's own stageIndex sentinel.
	StageIndex: number,
	IsFinisher: boolean,
}

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
function SwingSequencer.Resolve(model: Model, category: AttackKind, comboStage: number, now: number): Resolution?
	local record = recordFor(model)
	local weaponId = record.WeaponId
	if not weaponId then
		-- Empty-handed: an empty roster, or a weapon deleted out from under this combatant. Nothing to
		-- swing, and the caller's existing "no authored string" path already means exactly that.
		return nil
	end

	local count = stageCountFor(weaponId, category)
	if count <= 0 then
		return nil
	end

	local current = if stringIsLive(record, category, now) then record.StageIndex else 0
	local nextStage = current + 1

	if nextStage > count then
		-- The string is complete. Landing all of it earns the Finisher; merely throwing all of it
		-- wraps back to the top. THIS is the one place the throw-based counter this module owns and
		-- the landing-based one ComboEscalation owns are allowed to meet -- see the file header.
		if
			category == "Basic"
			and comboStage >= AttackConstants.Finisher.MinComboStage
			and AttackCatalog.Has(finisherMoveId(weaponId))
		then
			return {
				MoveId = finisherMoveId(weaponId),
				WeaponId = weaponId,
				StageIndex = 0,
				IsFinisher = true,
			}
		end
		nextStage = 1
	end

	return {
		MoveId = stageMoveId(weaponId, category, nextStage),
		WeaponId = weaponId,
		StageIndex = nextStage,
		IsFinisher = false,
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
	record.Category = category
	record.StageIndex = if resolution.IsFinisher then 0 else resolution.StageIndex
	-- Guarded rather than trusted: a NaN or negative commitment would produce a deadline that every
	-- comparison fails, which reads in play as "the string never continues" with nothing logged.
	local safeCommitment = if typeof(commitmentSeconds) == "number" and commitmentSeconds == commitmentSeconds
		then math.max(commitmentSeconds, 0)
		else 0
	local commitmentEndsAt = now + safeCommitment
	record.LapsesAt = commitmentEndsAt + AttackConstants.Sequence.ResetSeconds
	record.ChainReadyAt = commitmentEndsAt + AttackConstants.Sequence.ChainDelaySeconds
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
function SwingSequencer.ChainDelayRemaining(model: Model, now: number): number
	local record = records[model]
	if not record then
		return 0
	end
	return math.max(record.ChainReadyAt - now, 0)
end

-- The string position only, for a HUD or a spec. Returns 0 when no string is in progress.
function SwingSequencer.GetStageIndex(model: Model, category: AttackKind, now: number): number
	local record = records[model]
	if not record then
		return 0
	end
	return if stringIsLive(record, category, now) then record.StageIndex else 0
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
