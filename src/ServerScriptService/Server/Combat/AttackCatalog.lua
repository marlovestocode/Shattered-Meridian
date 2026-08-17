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

	ONE MUTATION AFTER THE PROJECTION: Get overlays AttackWindows.WindupOverride onto the projected
	definition's WindupSeconds when a Basic-string move's clip has a usable animation marker cached --
	see that module's own header. Its cache lives in AttackWindows, not here, and for the opposite
	reason this file has none: markers are read from an immutable authored asset, not from something
	an admin can edit live, so there is nothing for it to go stale against.

	Does not own: what a move IS (MoveTypes/MoveRegistryManager), whether a combatant may throw one
	(DefenseSystem.CanAttack and the attack layer), what a landed hit does (DamageResolver), or where a
	move's WindupSeconds ultimately comes from (Shared/Attack/AttackWindows.lua for a Basic string with
	a marker, the authored Constants.lua/DataStore value otherwise).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackAnimations = require(ReplicatedStorage.Shared.Attack.AttackAnimations)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
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

	-- Marker-driven WindupSeconds override (Shared/Attack/AttackWindows.lua) -- fail-soft: only ever
	-- applies when a usable marker is already cached (AttackRequestSystem.Init's boot warm pass, or a
	-- Prefetch this same session already ran) AND the result keeps the swing's own total AT LEAST as
	-- long as its Cooldown. That bound is load-bearing, not belt-and-suspenders, and it guards the
	-- OPPOSITE direction from what it might look like: this table's own header requires
	-- Cooldown <= Windup+Active+Recovery so the swing's own end, not Cooldown, is the gate a player
	-- feels -- a marker that legitimately SHRINKS WindupSeconds (the expected case; hand-typed values
	-- run conservative) could push the new total below the untouched Cooldown, silently reintroducing
	-- dead time after the animation finishes where the move still can't be re-thrown. A bad marker
	-- degrades to "using the old hardcoded number" instead.
	local windupOverride = AttackWindows.WindupOverride(moveId, animationId)
	if windupOverride and windupOverride + definition.ActiveSeconds + definition.RecoverySeconds >= move.Cooldown then
		definition.WindupSeconds = windupOverride
	end

	return {
		MoveId = move.MoveId,
		Definition = definition,
		Profile = profile,
		Cooldown = move.Cooldown,
		AnimationId = animationId,
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
