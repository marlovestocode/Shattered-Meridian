--!strict
--[[
	AttackCatalog.lua

	Owns: resolving a MoveId into the pair the rebuilt combat stack runs on -- the geometry
	HitboxEngine needs, and the damage numbers the layer above it applies.

	WHY THIS EXISTS AT ALL, and why it is a bridge rather than a table. The Move Creation System is a
	fully-built authoring pipeline: MoveRegistryManager, DefaultMoveRegistry, a DataStore, a live
	editor UI, a balance-graphing tool (Shared/MoveStats.lua), and the ArtSystem binding that makes an
	Art literally a MoveDefinition with an Art block on it (MoveTypes.MoveArtBinding's own header calls
	itself "the entire Move-Creation-System-to-ArtSystem seam"). All of it survived the combat teardown
	intact, and all of it was left with no combat consumer -- MoveTypes.ToHitboxAttackDefinition
	projects onto the DELETED system's schema, which the rebuilt engine does not understand.

	The alternative was a fresh hand-authored table mapping MoveId to engine-shaped attacks. It would
	have been smaller. It would also have duplicated a schema, a validation pass, and a persistence
	story that already exist and are already exercised by a real UI -- and, because an Art IS a move, it
	would have left the progression layer's entire ability system with no path to ever deal damage. So
	this module bridges instead, and the whole bridge is one projection function
	(MoveTypes.ToEngineAttackDefinition) plus the lookup order below.

	WHERE IT SITS. A sibling of HitboxEngine/ and Damage/, nested in neither, because neither owns it:
	the attack layer will read it to find out what to throw, and the damage layer reads it to find out
	what a landed hit costs. A catalogue owned by one consumer is one the other has to reach into.

	NO CACHE, deliberately. MoveRegistryManager.Upsert/Delete mutate the live in-memory registry
	synchronously, so anything cached here would need invalidating on both -- and a Get is already
	cheap (an in-memory table read plus a pure projection, against move counts that are "tens, not
	thousands" per MoveEditorSystem's own header). A cache would buy nothing and could serve a stale
	move after an edit, which is the one failure the Move Editor's whole "edits take effect immediately"
	design exists to avoid.

	ONE TIMELINE PASS AFTER THE PROJECTION: Get rebuilds the projected definition's timing against the
	move's own CLIP -- the hitbox opens when the move's delay runs out (authored WindupSeconds, or the
	clip's own Hit/AttackM<n> marker, plus the weapon's SpawnDelay), stays open for the authored
	ActiveSeconds, and the swing ends when the clip does (AttackConstants.Windows.SyncToClipLength).
	The clip's length and markers come from Shared/Attack/AttackWindows.lua's cache, and for the opposite
	reason this file has none: they are read from an immutable authored asset, not from something an
	admin can edit live, so there is nothing for them to go stale against.

	Does not own: what a move IS (MoveTypes/MoveRegistryManager), whether a combatant may throw one
	(DefenseSystem.CanAttack and the attack layer), what a landed hit does (DamageResolver), or reading
	a clip's length and markers (Shared/Attack/AttackWindows.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackAnimations = require(ReplicatedStorage.Shared.Attack.AttackAnimations)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local DefaultMoveRegistry = require(script.Parent.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.MoveRegistryManager)

type AttackCatalogEntry = DamageTypes.AttackCatalogEntry

local logger = Logger.scope("AttackCatalog")

local AttackCatalog = {}

-- Which projection warnings have already been reported. Keyed by move id AND the notes themselves, so
-- a move edited in the Move Editor into a DIFFERENT set of problems reports again while an unchanged
-- one stays quiet.
--
-- The dedupe is not an optimisation, it is a correctness property of the log: Get sits on the damage
-- layer's per-contact path, and several of the notes it can raise (an authored ArcDegrees, which every
-- hand-authored Default move carries) are true of perfectly ordinary moves. Without this, one warning
-- per landed hit would bury the log in a busy fight -- exactly the per-contact volume
-- DefenseConstants.Debug.Enabled exists to keep out by default. Once per distinct problem is what a
-- misauthored move actually warrants.
local reportedProjectionNotes: { [string]: boolean } = {}

-- Float slack for comparing an authored Cooldown against the authored timeline it was typed to match
-- (0.31 + 0.22 + 0.14 is not exactly 0.67 in binary).
local COOLDOWN_EPSILON = 1e-6

-- A warning raised at most once per distinct signature -- the same dedupe, and the same table, the
-- projection notes below use, for the same reason: Get sits on the per-contact path.
local function warnOnce(signature: string, message: string, data: { [string]: any }): ()
	if reportedProjectionNotes[signature] then
		return
	end
	reportedProjectionNotes[signature] = true
	logger:warn(message, data)
end

-- Resolves a MoveId to an authored move, custom moves taking precedence over Default ones.
--
-- THE ORDER MATTERS AND MIRRORS THE EDITOR'S OWN. MoveEditorSystem keeps List and ListDefaultMoves
-- separate, and a Default move is a live projection of a hand-authored Constants.Combat attack that an
-- admin may have retuned in place. A custom move sharing an id with a Default one is the admin's more
-- recent intent, so it wins -- and because DefaultMoveRegistry.Get rebuilds its projection fresh on
-- every call, a retuned Default is never stale here either.
local function resolveMove(moveId: string): MoveTypes.MoveDefinition?
	local custom = MoveRegistryManager.Get(moveId)
	if custom then
		return custom
	end
	return DefaultMoveRegistry.Get(moveId)
end

-- The catalogue's whole public surface: a MoveId in, everything the combat stack needs out.
--
-- Returns nil for an unknown id rather than a default attack. A missing move is a bug in whatever
-- asked for it -- a stale hotbar binding, an Art whose move was deleted -- and substituting a stand-in
-- attack would turn that bug into "this ability does the wrong thing," which is far harder to notice
-- than it doing nothing. Callers are expected to treat nil as "do not swing."
function AttackCatalog.Get(moveId: string): AttackCatalogEntry?
	if typeof(moveId) ~= "string" or moveId == "" then
		return nil
	end

	local move = resolveMove(moveId)
	if not move then
		if DamageConstants.Debug.Enabled and DamageConstants.Debug.LogCatalogMisses then
			logger:debug("No authored move for this id", { moveId = moveId })
		end
		return nil
	end

	local definition, profile, notes = MoveTypes.ToEngineAttackDefinition(move)

	-- Surfaced rather than swallowed: every note means an authored field did not survive the projection
	-- intact (a shape with no engine equivalent, a projectile with no path to be one). That is exactly
	-- the class of thing that otherwise reads as "this move has been subtly wrong for a month," which
	-- the parry plan's fail-closed rule exists to prevent. Deduped rather than gated on Debug.Enabled,
	-- so a real authoring mistake is loud even in production while a busy fight stays quiet -- see
	-- reportedProjectionNotes above.
	if #notes > 0 then
		local joined = table.concat(notes, "; ")
		local signature = `{moveId}|{joined}`
		if not reportedProjectionNotes[signature] then
			reportedProjectionNotes[signature] = true
			logger:warn("Move projected with corrections", { moveId = moveId, notes = joined })
		end
	end

	-- AUTHORED FIRST, CONFIGURED SECOND. A custom move authored in the Move Editor carries its own
	-- AnimationId and keeps it. A "Default" move structurally cannot -- DefaultMoveRegistry builds its
	-- projection fresh on every read with AnimationId hardcoded to "", and the editor hides the
	-- Animation section for that category entirely -- so the whole live move set falls through to
	-- Shared/Attack/AttackAnimations.lua, which exists to be the shelf those clips have nowhere else
	-- to sit on. Resolved here (rather than inline in the returned table below) because AttackWindows
	-- needs it too -- this is already the one place a MoveId becomes everything the combat stack knows
	-- about a move.
	local animationId = if move.AnimationId ~= "" then move.AnimationId else AttackAnimations.Get(move.MoveId)

	-- THE TIMELINE, built in three steps, in this order on purpose: WHEN THE HITBOX OPENS (the delay),
	-- HOW LONG IT STAYS OPEN (ActiveSeconds, authored, untouched), and WHEN THE SWING ENDS (the clip).
	--
	-- Everything a clip says is in CLIP time -- seconds at playback speed 1 -- while this move's own
	-- timings are already divided by its weapon's WeaponSpeed (WeaponRoster.applySpeed). The client
	-- plays the clip at that same speed (entry.PlaybackSpeed below), so every clip-derived number is
	-- divided by it here before it meets an authored one. Without that, a WeaponSpeed 1.6 weapon's
	-- hitbox opened at 0.19s against a clip that did not reach its strike until 0.31s.

	-- Taken before any of it is changed: step 3 needs the move's own authored total to tell a
	-- swing-length Cooldown from a real one.
	local authoredTotal = definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds

	-- 0. THE STRING'S TEMPO (AttackConstants.Tempo), before anything reads a clip: it is a playback
	-- multiplier on top of WeaponSpeed, so it has to be folded into playbackSpeed for every clip-derived
	-- number below to come out in the same (slowed) time the client plays the clip in. The authored
	-- windup and recovery stretch by it for a move with no clip data; the hit window never does -- see
	-- that constant's own header.
	local tempo = move.Tempo or 1
	if tempo ~= tempo or tempo <= 0 then
		tempo = 1
	end
	definition.WindupSeconds /= tempo
	definition.RecoverySeconds /= tempo
	-- A swing-length Cooldown stretches with the swing, capped at the stretched swing (the hit window
	-- did not stretch, so Cooldown / tempo alone could outlast it and reintroduce dead time); a real,
	-- longer cooldown is a gate, not a pace, and is left alone.
	local authoredCooldown = move.Cooldown
	if tempo ~= 1 and move.Cooldown <= authoredTotal + COOLDOWN_EPSILON then
		authoredCooldown = math.min(
			move.Cooldown / tempo,
			definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds
		)
	end
	authoredTotal = definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds

	local weaponSpeed = move.WeaponSpeed or 1
	if weaponSpeed ~= weaponSpeed or weaponSpeed <= 0 then
		weaponSpeed = 1
	end
	local playbackSpeed = weaponSpeed * tempo
	local clipLength = AttackWindows.ClipLength(animationId)
	local clipSeconds = if clipLength then clipLength / playbackSpeed else nil
	if clipSeconds and clipSeconds > HitboxEngineConstants.MaxSwingSeconds then
		-- The engine would expire the swing mid-clip as a runaway. Almost certainly the wrong asset
		-- (a looping idle pasted into an attack slot), so the authored timeline is the safer answer.
		warnOnce(`{moveId}|clip-too-long|{animationId}`, "Swing clip is longer than any swing may run -- not syncing", {
			moveId = moveId,
			clipSeconds = clipSeconds,
			maxSwingSeconds = HitboxEngineConstants.MaxSwingSeconds,
		})
		clipSeconds = nil
	end

	-- 1a. The marker-driven WindupSeconds override (Shared/Attack/AttackWindows.lua) -- a "Hit" marker
	-- on any attack clip, or an M1 clip's own AttackM<n>. Fail-soft: only ever applies when a usable
	-- marker is already cached (AttackRequestSystem.Init's boot warm pass, or a Request this same
	-- session already ran).
	--
	-- With the clip's length unknown, it additionally has to keep the swing's own total AT LEAST as
	-- long as its Cooldown. That bound guards the OPPOSITE direction from what it might look like:
	-- CombatConstants.Weapons' header requires Cooldown <= Windup+Active+Recovery so the swing's own
	-- end, not Cooldown, is the gate a player feels -- a marker that legitimately SHRINKS WindupSeconds
	-- could push the total below the untouched Cooldown, silently reintroducing dead time after the
	-- animation finishes where the move still can't be re-thrown. With the length KNOWN the bound is
	-- unnecessary: the total is the clip's, whatever the marker says, and step 3 clamps Cooldown to it.
	local windupOverride = AttackWindows.WindupOverride(moveId, animationId)
	if windupOverride then
		local overrideSeconds = windupOverride / playbackSpeed
		if
			clipSeconds
			or overrideSeconds + definition.ActiveSeconds + definition.RecoverySeconds >= authoredCooldown
		then
			definition.WindupSeconds = overrideSeconds
		end
	end

	-- 1b. THE WEAPON'S OWN SPAWN DELAY, added after the marker override, deliberately.
	--
	-- Both numbers answer "when does the hitbox go live", from different authorities: the marker says
	-- when the CLIP connects, and SpawnDelay is the builder saying this weapon's arc lands later than
	-- the house sword's. Applied before the override, a marked clip would silently discard the
	-- builder's value and an unmarked one would keep it -- the same move behaving two ways depending on
	-- whether an animator had touched the asset, which is precisely the "subtly wrong for a month"
	-- class this file's projection-notes warning exists to prevent. Applied after, "delay" means the
	-- same thing either way.
	--
	-- ADDITIVE, never a replacement: zero is the default and changes nothing. It lengthens only the
	-- windup: with the clip's length known, step 3 takes it back out of recovery (the clip does not get
	-- longer because the hitbox opens later); with it unknown, the swing's total grows by it, which
	-- only widens the Cooldown <= timeline margin in the safe direction.
	local spawnDelay = move.SpawnDelaySeconds
	if spawnDelay and spawnDelay > 0 then
		definition.WindupSeconds += spawnDelay
	end

	-- 2. ActiveSeconds is the authored hit window, and nothing here touches it.

	-- 3. THE SWING ENDS WHEN ITS CLIP DOES (AttackConstants.Windows.SyncToClipLength). Recovery is
	-- whatever the clip has left once the hitbox has closed, so Windup+Active+Recovery -- the engine's
	-- whole swing, the attacker's commitment lock, the string's chain beat and CombatBusyUntil, all of
	-- which AttackRequestSystem derives from those three -- is exactly the clip the player is watching.
	-- Unknown length (no clip, not fetched yet, unreadable) keeps the authored timeline untouched.
	local cooldown = authoredCooldown
	if clipSeconds then
		local struck = definition.WindupSeconds + definition.ActiveSeconds
		if struck > clipSeconds then
			-- The hitbox still opens on its delay and stays open for its full window -- that is the
			-- authored contract, and cutting it to fit would silently shrink the move's hit window. The
			-- swing simply ends with the hitbox, after the clip has already finished. Loud, because it
			-- means the clip and the move's numbers disagree about what this move is.
			warnOnce(
				`{moveId}|outlasts-clip|{animationId}`,
				"Hitbox closes after its clip ends -- clip is too short for this move's delay + active window",
				{
					moveId = moveId,
					clipSeconds = clipSeconds,
					windupSeconds = definition.WindupSeconds,
					activeSeconds = definition.ActiveSeconds,
				}
			)
		end
		definition.RecoverySeconds = math.max(clipSeconds - struck, 0)

		-- A SWING-LENGTH COOLDOWN FOLLOWS THE SWING; A REAL ONE DOES NOT. Every weapon stage authors its
		-- Cooldown at (or under) its own timeline, standing for "until this swing is over" -- so if the
		-- clip is shorter than the authored timeline, that Cooldown would outlast the animation and
		-- bring back exactly the dead time CombatConstants.Weapons' header forbids. A Cooldown authored
		-- LONGER than its swing (DashPunch's 4s, an Art's) is a deliberate gate and is kept as-is.
		if authoredCooldown <= authoredTotal + COOLDOWN_EPSILON then
			cooldown = math.min(authoredCooldown, struck + definition.RecoverySeconds)
		end
	end

	return {
		MoveId = move.MoveId,
		Definition = definition,
		Profile = profile,
		Cooldown = cooldown,
		AnimationId = animationId,
		PlaybackSpeed = playbackSpeed,
		PowerLevel = MoveTypes.PowerLevelOf(move),
		Feintable = MoveTypes.IsFeintable(move),
	}
end

-- Whether an id resolves at all, without paying for the projection. For a validation pass over a
-- hotbar or an Art tree, where the answer is "does this still exist" rather than "give me the attack."
function AttackCatalog.Has(moveId: string): boolean
	if typeof(moveId) ~= "string" or moveId == "" then
		return false
	end
	return resolveMove(moveId) ~= nil
end

-- Spec-only, so one case cannot serve another its suppressed warnings.
function AttackCatalog.Reset(): ()
	table.clear(reportedProjectionNotes)
end

return AttackCatalog
