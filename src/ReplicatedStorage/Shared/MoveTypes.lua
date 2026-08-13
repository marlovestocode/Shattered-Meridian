--!strict
--[[
	MoveTypes.lua

	Owns: the authored-move schema for the Move Creation System (an in-game, admin-gated move
	editor -- Server/Combat/MoveRegistryManager.lua, Server/Systems/MoveEditorSystem.lua,
	Client/UI/Screens/MoveEditor/). Kept as its own file rather than folded into Types.lua because
	it's a large, self-contained, additive schema with no existing consumer outside this feature --
	the same reasoning that already earned QiConstants.lua its own file.

	MoveDefinition is a strict superset of Types.HitboxAttackDefinition: every timing/damage/arc
	field that struct has is reproduced here BY NAME, never re-derived or renamed, so
	ToHitboxAttackDefinition (below) is a pure, lossless narrowing projection.
	HitboxResolver/HitResolution/DummyCombat/BotCombat never see a MoveDefinition directly, only
	the projected HitboxAttackDefinition -- this module is the only place that needs to know the
	wider authored shape exists.

	Does not own: validation (MoveRegistryManager.Validate), persistence (MoveEditorSystem's
	encode/decode), the shape geometry itself (Shared/HitboxShapes.lua), the animation scheduling
	model (Shared/AnimationTimeline.lua), or RemoteFunction wiring -- this file is types and the one
	pure projection function only.

	THREE sub-schemas were added on top of the original v1 shape, each delegating its own semantics
	to a dedicated shared module rather than growing this file:

	  * Geometry. Shape is now HitboxShapes.ShapeId (twelve shapes, not two) and the measurements
	    live in a single flat Dimensions bag rather than a Size/Radius pair. Size/Radius are STILL
	    populated for Box/Sphere respectively -- derived from Dimensions by
	    MoveRegistryManager.Validate, never separately authored -- specifically so every consumer
	    that predates this (HitboxResolver's exact Box/Sphere query paths, the debug renderer, the
	    projectile visual) keeps working on the two original shapes with byte-identical behaviour.
	    OffsetRotation additionally lets an author aim the volume, which v1 explicitly could not do.

	  * Animation. Animations is an ORDERED clip list (AnimationTimeline.Clip) with per-clip start/
	    stop/speed/weight/fade/loop/blend/interrupt control. The original single AnimationId field
	    is retained and still honoured: a move carrying an AnimationId but an empty Animations list
	    is projected onto a one-clip timeline by Validate (AnimationTimeline.FromLegacyAnimationId),
	    so nothing authored before the timeline existed changes behaviour or needs migrating.

	  * ObjectStun. An optional, heavily-configurable reaction to the move knocking a target INTO
	    world geometry -- see MoveObjectStun's own header for the detection/causation model and
	    Server/Combat/ObjectStunResolver.lua for the runtime that implements it.

	Category == "Default" is a RESERVED SENTINEL, not an ordinary free-form author tag (see
	MoveDefinition.Category's own comment for the normal case). It marks a move projected by
	Server/Combat/DefaultMoveRegistry.lua from a hand-authored Constants.lua attack (every weapon
	Basic/Heavy/Finisher stage, plus DashPunch/DashHit/AirSlam) rather than an admin-created one
	living in MoveRegistryManager's registry -- the ONE flag every consumer (PropertyEditor.lua,
	Sidebar.lua, MoveList.lua, MoveEditorClient.lua, MoveEditorSystem.lua) checks to tell a Default
	move apart from a custom one. A Default move: is never persisted to DataStore and never appears in
	MoveRegistryManager.List/Get; can never be deleted (only reset to its captured original values);
	ignores AnimationId/Animations entirely (its animation comes from CombatAnimator.lua's existing
	DebugName-trailing-digit inference); and always has Movement/Knockback/Projectile/ObjectStun == nil
	(those are consumed only by CombatSystem.ThrowCustomMove's own code path, so they would be
	silently inert on a Default move). No admin-created move may be given this Category:
	doing so produces a move that LOOKS like a Default move to every UI consumer above without being
	backed by a live Constants table -- filtered into MoveList's Default tab, its optional sections
	hidden, its Delete action gone, its saves routed to the Default handler, i.e. unreachable and
	undeletable. MoveRegistryManager.Validate now REJECTS it with "ReservedCategory" for every
	client-submitted candidate (see that function's own allowReservedCategory parameter for why the
	check is opt-in per caller rather than unconditional). The sentinel string itself is
	MoveTypes.DefaultCategory below -- compare against that rather than re-typing the literal.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)

local MoveTypes = {}

-- The reserved Category sentinel, named once here (see this file's header for the full contract).
-- Before this constant existed the literal "Default" was hand-typed in nine places across
-- Sidebar.lua, PropertyEditor.lua, MoveList.lua, MoveEditorClient.lua and DefaultMoveRegistry.lua,
-- every one of them a plain string equality -- so a single typo in any of them would silently
-- mis-file a move into the wrong list tab with no error raised anywhere, which is precisely the
-- failure this sentinel exists to prevent.
MoveTypes.DefaultCategory = "Default"

-- Re-exported so a consumer that only cares about moves (PropertyEditor, MoveEditorClient) can
-- reference the shape/dimension/clip types through this one module rather than requiring three.
export type MoveShape = HitboxShapes.ShapeId
export type MoveDimensions = HitboxShapes.Dimensions
export type MoveAnimationClip = AnimationTimeline.Clip

-- v1's only movement-authoring primitive: a fixed-speed forward lunge, reusing the Dash-burst
-- SHAPE (a WalkSpeed override for a fixed window) via Movement.ApplyCustomMoveLunge -- not
-- Dash's own state fields. See Movement.lua's ComputeDesiredWalkSpeed for why this is its own
-- priority tier rather than writing WalkSpeed directly.
export type MoveMovementGrant = {
	LungeDistanceStuds: number,
	LungeDurationSeconds: number,
}

-- v1's only knockback-authoring primitive -- a simpler, move-data-driven sibling of the
-- Uppercut/Downslam/Normal FinisherVariant knockback profiles, applied via the same
-- RagdollController.LaunchAndRagdoll call. RagdollSeconds = 0 is legal (a pure knock with no
-- ragdoll lockout), matching Finisher.Normal's own 0-ragdoll convention.
export type MoveKnockback = {
	UpVelocity: number,
	HorizontalVelocity: number,
	RagdollSeconds: number,
	-- Optional, nil/false for every move authored before this field existed. When true, this move's
	-- hit unlocks aerial-combo continuation exactly like DashPunch does -- see AirCombo.Apply's own
	-- header for the DashPunch-or-StartsAirCombo launcher condition. Only meaningful alongside a
	-- populated Knockback (this field lives on that sub-table rather than a parallel top-level one
	-- for exactly that reason) -- AirCombo.Apply owns 100% of the physical launch/hold treatment for
	-- a StartsAirCombo hit (its own Constants.Combat.AirCombo-tuned numbers, not this Knockback's own
	-- UpVelocity/HorizontalVelocity), the same way it already does for DashPunch.
	StartsAirCombo: boolean?,
}

-- v1's only ranged-authoring primitive. Presence (not Shape) is what makes a move a projectile --
-- Shape/Dimensions still pick the traveling hitbox's own geometry exactly as they do for a
-- stationary melee move, this sub-table only adds how fast and how far it travels. Reuses the
-- move's own WindupSeconds (telegraph before it launches) and ActiveSeconds (capped by MaxRange/
-- Speed -- whichever limit is reached first ends the flight) rather than inventing a parallel
-- timing model -- see HitboxResolver.StartProjectile's own header for the full scheduling
-- reasoning. MaxTargets (already on MoveDefinition) doubles as pierce count: 1 (the sensible
-- default for a "normal" projectile) means it expires on its first hit; a higher value lets it
-- punch through multiple targets before disappearing.
export type MoveProjectileConfig = {
	Speed: number, -- studs per second
	MaxRange: number, -- studs
}

-- The Object Stun schema itself lives in Types.lua, not here, and these three are pure aliases.
-- Unlike Movement/Knockback/Projectile above (which are authored here and projected onto
-- HitboxAttackDefinition by hand), an ObjectStun config is consumed by a SERVER module that never
-- requires this file -- Server/Combat/ObjectStunResolver.lua works off the projected
-- HitboxAttackDefinition, exactly as HitboxResolver does -- so Types.lua is where the definition
-- has to live for both sides to name the same type. Aliased back through here so a Move Editor
-- consumer still finds every part of the authored-move schema on one module. See
-- Types.ObjectStunConfig for the full field-by-field documentation and the causation model.
export type MoveObjectStunSurfaces = Types.ObjectStunSurfaces
export type MoveObjectStunFollowUp = Types.ObjectStunFollowUp
export type MoveObjectStun = Types.ObjectStunConfig

-- Declares a move to BE an art: which tree it sits in, what it costs, and what earns it. Absent on
-- an ordinary move (an M1 combo stage, a test move, an admin experiment), which is why every field
-- here is required once the block is present -- a half-authored art is a worse outcome than no art,
-- since it would appear in a tree the player can see and then behave unpredictably.
--
-- This is the entire Move-Creation-System-to-ArtSystem seam. See ArtConstants.lua's header for why
-- an art is a move rather than a parallel ability object; MoveRegistryManager.Validate clamps every
-- number below against ArtConstants.Limits.
export type MoveArtBinding = {
	-- Which ArtConstants.ArtTrees entry this art belongs to. Validated against the live roster, so a
	-- tree that is deleted from that table takes its arts out of the catalogue rather than leaving
	-- them orphaned in a tree nothing can render.
	TreeId: string,
	-- Depth in the tree. Node 1 is an entry form and is never gated behind a prerequisite regardless
	-- of what was authored (ArtSystem enforces that, so no tree can be authored unreachable).
	Node: number,
	-- Qi spent per use, through QiSystem.Spend. 0 is legal.
	QiCost: number,
	-- Minimum TierSystem tier before this can be unlocked.
	RequiredTier: number,
	-- ArtId that must be mastered to ArtConstants.MasteryToUnlockNext first. nil for an entry form.
	-- An art's own ArtId is its MoveId -- there is no second identity to keep in sync, which is the
	-- point of building arts on moves.
	Prerequisite: string?,
}

export type MoveDefinition = {
	-- Stable identity -- the DataStore key and the routing key CombatSystem.ThrowCustomMove
	-- resolves against. Author-assigned once at creation (a slug derived from DisplayName plus a
	-- short random suffix), immutable thereafter: Save never changes MoveId, only fields.
	MoveId: string,
	DisplayName: string,
	-- Free-form author tag ("Primary Combo", "Signature", "Experimental") -- v1 has no closed
	-- taxonomy; purely a list-UI grouping/filter aid, never read by combat logic.
	Category: string,
	Author: string, -- Player.Name at CreatedAt, display-only.
	CreatedAt: number, -- os.time(), Unix seconds -- DataStore-safe, cross-session comparable.
	UpdatedAt: number,

	-- Hitbox geometry ---------------------------------------------------------------------------
	Shape: MoveShape,
	-- Every measurement for every shape, always fully populated -- see HitboxShapes.Dimensions'
	-- own header for why one flat bag rather than a per-shape variant. Which fields a given shape
	-- actually reads is HitboxShapes.FieldsFor(Shape).
	Dimensions: MoveDimensions,
	-- DERIVED from Dimensions by MoveRegistryManager.Validate, never separately authored: Size is
	-- set for Shape == "Box" only, Radius for Shape == "Sphere" only, both nil for every other
	-- shape. They exist purely so the pre-existing exact-query paths (HitboxResolver's
	-- GetPartBoundsInBox/GetPartBoundsInRadius, the debug part, the projectile visual) keep
	-- consuming the two original shapes exactly as they always have -- see this file's header.
	Size: Vector3?,
	Radius: number?,
	-- Root-relative, same convention as HitboxAttackDefinition.Offset. Carries BOTH the translation
	-- and (unlike v1) the rotation authored in OffsetRotation -- Validate builds it from the flat
	-- wire numbers so the "the client never hands us a raw CFrame" invariant still holds.
	Offset: CFrame,
	-- Pitch/Yaw/Roll in DEGREES, kept alongside Offset rather than only baked into it: degrees are
	-- what the editor's fields show and what the DataStore record stores, and recovering three
	-- clean angles back out of a CFrame is lossy at the poles.
	OffsetRotation: Vector3,

	-- Timing (identical semantics to HitboxAttackDefinition).
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	Cooldown: number,

	-- Damage/posture (identical semantics).
	Damage: number,
	PostureDamage: number,
	ArcDegrees: number?,
	MaxTargets: number?,

	-- Animation ---------------------------------------------------------------------------------
	-- The original single-clip field, retained: "" = no clip authored, the same convention
	-- Constants.Combat.AnimationIds already uses for wired-but-unauthored slots -- never nil.
	-- Still the source a legacy move's timeline is derived from (see this file's header):
	-- CombatSystem.ThrowCustomMove projects it through AnimationTimeline.FromLegacyAnimationId
	-- whenever Animations below is empty, so it reaches the client as a one-clip
	-- AttackStartedPayload.Animations list rather than being sent on the wire directly.
	AnimationId: string,
	-- The full authored timeline. Empty is legal and normal (a move with only an AnimationId, or no
	-- animation at all) -- see AnimationTimeline.Resolve, which treats an empty list as an empty
	-- schedule rather than an error.
	Animations: { MoveAnimationClip },

	-- Optional sub-systems ----------------------------------------------------------------------
	-- nil = no effect (a pure stationary hitbox, identical to today's weapon-stage behavior).
	Movement: MoveMovementGrant?,
	Knockback: MoveKnockback?,
	-- nil = an ordinary body-relative melee hitbox (v1's original behavior, unchanged). Present =
	-- a traveling projectile -- see MoveProjectileConfig's own header.
	Projectile: MoveProjectileConfig?,
	-- nil (or present with Enabled == false) = this move never reacts to its target hitting
	-- anything. See MoveObjectStun's own header.
	ObjectStun: MoveObjectStun?,
	-- nil = an ordinary move, exactly as every move behaved before ArtSystem existed. Present = this
	-- move is an art in a tree. See MoveArtBinding's own header.
	Art: MoveArtBinding?,
}

-- RemoteFunction result shapes for the Move Creation System's own remotes (Server/Systems/
-- MoveEditorSystem.lua, Constants.MoveEditor.RemoteNames) -- kept here rather than in Types.lua for
-- the same "large, self-contained, additive schema, no consumer outside this feature" reason this
-- file's own header gives for MoveDefinition itself.
export type MoveEditorListResult = {
	Success: boolean,
	Reason: string?,
	Moves: { MoveDefinition }?,
}

export type MoveEditorMoveResult = {
	Success: boolean,
	Reason: string?,
	Move: MoveDefinition?,
}

export type MoveEditorActionResult = {
	Success: boolean,
	Reason: string?,
}

-- Deep copy of a MoveDefinition, written as an EXPLICIT field list rather than a recursive walk of
-- whatever the source table happens to hold -- the same defensive posture defaultConfig in
-- ObjectStunEditor.lua already takes for its own record, and for the same reason: a copy that
-- mirrors the schema can only ever produce a valid MoveDefinition, while a generic deep-copy would
-- faithfully reproduce junk a malformed source was carrying.
--
-- Every nested table is cloned to the depth the schema actually nests: Dimensions, each Animations
-- clip, Movement/Knockback/Projectile, and ObjectStun -> Surfaces and ObjectStun -> FollowUp ->
-- Dimensions (the one three-level path in this shape). Offset is a CFrame and OffsetRotation a
-- Vector3 -- both immutable Roblox datatypes, so they are assigned, not copied.
--
-- Exists because a shallow table.clone is the wrong tool at every call site that was using one.
-- PropertyEditor.lua's applyChange cloned only the top level and then had TEN hand-written
-- `d.Knockback = table.clone(d.Knockback)` lines scattered through its OnChanged handlers to make up
-- the difference -- correct today, one forgotten line away from a bug where editing a draft reaches
-- back and mutates the previous draft object still held in MovesDisplay's cache. This centralises
-- that into one function that cannot be forgotten at the eleventh call site, and is what makes
-- "duplicate a move" safe (a shallow copy would leave the duplicate's sub-tables aliasing the
-- original's, so editing the copy would silently corrupt the source).
function MoveTypes.Clone(move: MoveDefinition): MoveDefinition
	local animations: { MoveAnimationClip } = table.create(#move.Animations)
	for index, clip in ipairs(move.Animations) do
		animations[index] = table.clone(clip)
	end

	local objectStun: MoveObjectStun? = nil
	if move.ObjectStun then
		objectStun = table.clone(move.ObjectStun)
		local stun = objectStun :: MoveObjectStun
		stun.Surfaces = table.clone(move.ObjectStun.Surfaces)
		if move.ObjectStun.FollowUp then
			local followUp = table.clone(move.ObjectStun.FollowUp)
			followUp.Dimensions = table.clone(move.ObjectStun.FollowUp.Dimensions)
			if move.ObjectStun.FollowUp.Knockback then
				followUp.Knockback = table.clone(move.ObjectStun.FollowUp.Knockback)
			end
			stun.FollowUp = followUp
		end
	end

	return {
		MoveId = move.MoveId,
		DisplayName = move.DisplayName,
		Category = move.Category,
		Author = move.Author,
		CreatedAt = move.CreatedAt,
		UpdatedAt = move.UpdatedAt,

		Shape = move.Shape,
		Dimensions = table.clone(move.Dimensions),
		Size = move.Size,
		Radius = move.Radius,
		Offset = move.Offset,
		OffsetRotation = move.OffsetRotation,

		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Cooldown = move.Cooldown,

		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		ArcDegrees = move.ArcDegrees,
		MaxTargets = move.MaxTargets,

		AnimationId = move.AnimationId,
		Animations = animations,

		Movement = if move.Movement then table.clone(move.Movement) else nil,
		Knockback = if move.Knockback then table.clone(move.Knockback) else nil,
		Projectile = if move.Projectile then table.clone(move.Projectile) else nil,
		ObjectStun = objectStun,
		-- Flat table.clone is correct here and not an oversight: MoveArtBinding nests nothing, unlike
		-- ObjectStun (which needs the explicit deep walk above for Surfaces and FollowUp.Dimensions).
		Art = if move.Art then table.clone(move.Art) else nil,
	}
end

-- Formats one number for Fingerprint. "%.6g" deliberately, not "%s": Lua's default number
-- formatting differs between an integer-valued float and an integer, and six significant figures is
-- already three past the editor's own two-decimal display precision while staying well short of the
-- float noise that would make two visually identical drafts digest differently.
local function digestNumber(value: number): string
	return string.format("%.6g", value)
end

-- Appends a deterministic digest of `value` to `out`. Table keys are visited in sorted order at
-- EVERY level, which is the entire point: Lua's `pairs` order is unspecified and genuinely can
-- differ between two structurally identical tables, so an unsorted walk would report a move as
-- changed purely because its fields were rebuilt in a different order.
local function digestValue(out: { string }, value: unknown): ()
	local valueType = typeof(value)
	if valueType == "number" then
		table.insert(out, digestNumber(value :: number))
	elseif valueType == "string" then
		table.insert(out, "'" .. (value :: string) .. "'")
	elseif valueType == "boolean" then
		table.insert(out, if value then "T" else "F")
	elseif valueType == "nil" then
		table.insert(out, "~")
	elseif valueType == "Vector3" then
		local vector = value :: Vector3
		table.insert(out, `V({digestNumber(vector.X)},{digestNumber(vector.Y)},{digestNumber(vector.Z)})`)
	elseif valueType == "Color3" then
		local color = value :: Color3
		table.insert(out, `C({digestNumber(color.R)},{digestNumber(color.G)},{digestNumber(color.B)})`)
	elseif valueType == "CFrame" then
		-- Only the TRANSLATION. A CFrame's rotation half is already represented by the move's own
		-- OffsetRotation field (degrees, which is what the editor edits and the DataStore stores), so
		-- digesting all twelve components would double-count it -- and would make the digest sensitive
		-- to float drift in a rotation matrix that Validate rebuilds from those degrees on every round
		-- trip anyway.
		local cframe = value :: CFrame
		table.insert(out, `P({digestNumber(cframe.X)},{digestNumber(cframe.Y)},{digestNumber(cframe.Z)})`)
	elseif valueType == "table" then
		local source = value :: { [string]: unknown }
		local keys: { string } = {}
		for key in pairs(source) do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		table.insert(out, "{")
		for _, key in ipairs(keys) do
			table.insert(out, key .. "=")
			digestValue(out, (source :: any)[key])
		end
		table.insert(out, "}")
	else
		table.insert(out, tostring(value))
	end
end

-- A deterministic string digest of every AUTHORED field of a move, for answering "has this draft
-- changed since it was last saved or loaded?"
--
-- A digest rather than a structural deep-equal because of how it is used: the Move Editor holds
-- exactly one saved snapshot and re-compares against it on every keystroke, so one string comparison
-- per edit beats a full recursive walk, and the retained snapshot is a short string instead of a
-- whole second MoveDefinition kept alive for the session.
--
-- DELIBERATELY EXCLUDES MoveId, Author, CreatedAt and UpdatedAt. All four are stamped server-side on
-- every single round trip (MoveEditorSystem.stampTrustedMetadata sets UpdatedAt = os.time()
-- unconditionally, even for an UpdateDraft that changed nothing), and the client reconciles that
-- response back into its own draft -- so including UpdatedAt alone would mark every draft
-- permanently dirty within one debounce window of opening it, which is worse than having no dirty
-- tracking at all. Size/Radius are excluded for a related reason: both are DERIVED from Dimensions
-- by Validate rather than authored, so they carry no information Dimensions doesn't already.
function MoveTypes.Fingerprint(move: MoveDefinition): string
	local out: { string } = {}
	digestValue(out, {
		DisplayName = move.DisplayName,
		Category = move.Category,

		Shape = move.Shape,
		Dimensions = move.Dimensions,
		Offset = move.Offset,
		OffsetRotation = move.OffsetRotation,

		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Cooldown = move.Cooldown,

		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		ArcDegrees = move.ArcDegrees,
		MaxTargets = move.MaxTargets,

		AnimationId = move.AnimationId,
		-- An ARRAY, so order matters and must not be sorted away -- digestValue sorts keys, and for a
		-- sequence those keys are "1", "2", ... which sort lexicographically. That is wrong at ten
		-- clips ("10" sorts before "2"), so the list is flattened here into an explicitly-ordered map
		-- keyed by a zero-padded index instead of handed to digestValue as a bare array.
		Animations = (function()
			local ordered: { [string]: unknown } = {}
			for index, clip in ipairs(move.Animations) do
				ordered[string.format("%04d", index)] = clip
			end
			return ordered
		end)(),

		Movement = move.Movement,
		Knockback = move.Knockback,
		Projectile = move.Projectile,
		ObjectStun = move.ObjectStun,
	})
	return table.concat(out)
end

-- The lossless projection every combat-side caller (HitboxResolver, HitResolution, DummyCombat,
-- BotCombat, CombatSystem's throwStandaloneAttack) actually consumes. DebugName is always
-- move.MoveId -- never separately authored -- so every log/feedback site stays traceable back to
-- a real move.
--
-- Dimensions/ObjectStun ride along the same way Shape/Radius/Knockback/Projectile already do:
-- straight field-for-field, no reshaping, so the projection stays something you can verify by
-- reading rather than by tracing. Animations deliberately does NOT -- an animation timeline is
-- purely presentational and reaches the client through AttackStartedPayload instead, keeping
-- HitboxAttackDefinition (a server-side geometry/damage struct) free of client concerns.
function MoveTypes.ToHitboxAttackDefinition(move: MoveDefinition): Types.HitboxAttackDefinition
	return {
		DebugName = move.MoveId,
		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Size = move.Size,
		Offset = move.Offset,
		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		Cooldown = move.Cooldown,
		ArcDegrees = move.ArcDegrees,
		MaxTargets = move.MaxTargets,
		Shape = move.Shape,
		Radius = move.Radius,
		Dimensions = move.Dimensions,
		Knockback = move.Knockback,
		Projectile = move.Projectile,
		ObjectStun = move.ObjectStun,
	}
end

-- The same projection for an Object Stun follow-up, which is thrown through the exact same
-- swing pipeline as any other attack and therefore needs the exact same struct. DebugName is
-- suffixed rather than reusing the parent's, so a follow-up's own hits are distinguishable in
-- combat logs and in the editor's test-fire readout from the launcher that set them up.
--
-- Never carries ObjectStun of its own: a follow-up that could itself object-stun would let one
-- authored move recurse indefinitely (slam, follow up, slam again...). One level of chaining is
-- what the feature is for; unbounded chaining is a hang.
function MoveTypes.FollowUpToHitboxAttackDefinition(
	moveId: string,
	followUp: MoveObjectStunFollowUp
): Types.HitboxAttackDefinition
	return {
		DebugName = moveId .. ":FollowUp",
		WindupSeconds = followUp.WindupSeconds,
		ActiveSeconds = followUp.ActiveSeconds,
		RecoverySeconds = followUp.RecoverySeconds,
		Size = if followUp.Shape == "Box"
			then Vector3.new(followUp.Dimensions.Width, followUp.Dimensions.Height, followUp.Dimensions.Depth)
			else nil,
		Offset = followUp.Offset,
		Damage = followUp.Damage,
		PostureDamage = followUp.PostureDamage,
		-- A follow-up is scheduled by the resolver, not gated by a cooldown of its own -- the parent
		-- move's Cooldown (and the object stun's own CooldownSeconds) already bound how often this
		-- can happen. Reported as the parent's so nothing downstream reads a zero here.
		Cooldown = 0,
		-- Deliberately no arc check: the attacker may have just been teleported to face a pinned
		-- victim, and an arc measured from a facing that changed this frame reads as a spurious
		-- miss. The follow-up's own tight hitbox is the constraint.
		ArcDegrees = nil,
		MaxTargets = followUp.MaxTargets,
		Shape = followUp.Shape,
		Radius = if followUp.Shape == "Sphere" then followUp.Dimensions.Radius else nil,
		Dimensions = followUp.Dimensions,
		Knockback = followUp.Knockback,
		Projectile = nil,
		ObjectStun = nil,
	}
end

return MoveTypes
