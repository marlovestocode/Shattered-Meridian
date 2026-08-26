--!strict
--[[
	MoveRegistryManager.lua

	Owns: the LIVE, IN-MEMORY registry of Move Creation System moves (MoveTypes.MoveDefinition),
	keyed by MoveId. The "Manager" half of this codebase's Manager/System pairing (mirrors
	BloodlineManager/BloodlineSystem) -- Server/Systems/MoveEditorSystem.lua is the "System" half
	that owns authorization, RemoteFunctions, and DataStore persistence on top of this module.

	Validate is the ONE gate every untrusted MoveDefinition-shaped table passes through before it
	can ever reach HitboxResolver/CombatSystem -- both a client-authored SaveMove/UpdateDraft
	request and a DataStore-loaded record at boot go through this exact same function, the same way
	PlayerDataSystem.DecodeProfile treats a DataStore read as no more trustworthy than a network
	payload. A structural error (wrong type, an unknown Shape, a missing required field) is a hard
	reject -- this is actively-edited admin data, a clear rejection is more useful than a silent
	substitution. An in-range numeric error is clamped instead (same philosophy the retired
	HitboxTuning.lua's CLAMP_MIN/MAX constants documented: not a balance opinion, just a floor
	against a value that would read as broken).

	Three sub-schemas delegate their own normalization rather than reimplementing it here, because
	each has a module that already owns those semantics and is unit-tested on its own:

	  * Geometry   -> HitboxShapes.Sanitize (per-field clamps from HitboxShapes.FIELD_SPECS, plus
	                  the one cross-field invariant, InnerRadius strictly inside Radius).
	  * Animations -> AnimationTimeline.Sanitize (per-clip clamps, clip cap, id normalization).
	  * Object Stun -> validateObjectStun below, clamping against Constants.MoveEditor.ObjectStun
	                  .Limits, which is the SAME table the editor renders its own field bounds from.

	Those three are all NORMALIZING rather than rejecting: a malformed clip or dimension falls back
	to a sane default instead of failing the whole move. That's a deliberate split from the top-level
	fields' hard-reject rule -- a bad MoveId or Shape means the request is fundamentally not a move
	and the admin needs to know, whereas a bad FadeInSeconds on clip 3 is a value error inside an
	otherwise-coherent move, exactly the case the existing clamp philosophy already covers.

	BACKWARDS COMPATIBILITY is Validate's job, not a migration pass: a v1 record (Size/Radius but no
	Dimensions, AnimationId but no Animations, no ObjectStun) is reconstructed into a full v2
	MoveDefinition here, so it loads and behaves identically to before -- see dimensionsFromCandidate
	and the Animations block below. Nothing rewrites stored records; the next Save simply writes the
	v2 shape.

	Upsert/Delete mutate the in-memory table ONLY -- no DataStore I/O here, which is what makes an
	edit "take effect immediately" for MoveEditorSystem's UpdateDraft path.

	Does not own: authorization, rate-limiting, RemoteFunctions, or DataStore reads/writes --
	MoveEditorSystem.lua owns all of that, including stamping Author/CreatedAt/UpdatedAt from
	trusted server context onto a client-submitted candidate before it ever reaches Validate here.
	Keeping persistence out of this module means it stays trivially unit-testable: construct a
	MoveDefinition table literal, call Validate/Upsert/Get/ToHitboxAttackDefinition, assert -- no
	DataStore mocking needed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)

local MoveRegistryManager = {}

-- Sanity floors/ceilings for every clamped numeric field: wide enough to cover any real authored
-- move, just closed enough that this registry can never hand back a definition that would break
-- HitboxResolver's timing math or spawn a wildly broken volume.
--
-- Note what is NOT here any more: the per-axis size/radius clamps. Those moved to
-- HitboxShapes.FIELD_SPECS when Dimensions replaced the Size/Radius pair, so the twelve shapes and
-- the editor's own field bounds read from one table instead of two that could drift. The derived
-- Size/Radius this module still produces for Box/Sphere therefore inherit those same bounds.
local CLAMP_MIN_SECONDS = 0.01
local CLAMP_MAX_SECONDS = 45
local CLAMP_MIN_OFFSET_STUDS = -5
local CLAMP_MAX_OFFSET_STUDS = 10
local CLAMP_MIN_DAMAGE = 0
local CLAMP_MAX_DAMAGE = 200
local CLAMP_MIN_ARC_DEGREES = 1
local CLAMP_MAX_ARC_DEGREES = 360
local CLAMP_MIN_MAX_TARGETS = 1
local CLAMP_MAX_MAX_TARGETS = 50
local CLAMP_MIN_LUNGE_DISTANCE_STUDS = 0
local CLAMP_MAX_LUNGE_DISTANCE_STUDS = 30
local CLAMP_MIN_LUNGE_DURATION_SECONDS = 0.05
local CLAMP_MAX_LUNGE_DURATION_SECONDS = 3
local CLAMP_MIN_KNOCKBACK_VELOCITY = 0
local CLAMP_MAX_KNOCKBACK_VELOCITY = 150
local CLAMP_MIN_RAGDOLL_SECONDS = 0
local CLAMP_MAX_RAGDOLL_SECONDS = 5
-- Grab -- read from GrabConstants.Limits rather than re-typed here, the same "one place the editor's
-- own field bounds and the server's own clamp agree on a range" reasoning
-- Constants.MoveEditor.ObjectStun.Limits already established for validateObjectStun.
local GRAB_LIMITS = GrabConstants.Limits
-- A slow thrown-weapon feel through a fast arrow/bolt feel -- wide enough to cover either, still
-- closed enough that a projectile can never be authored effectively-instant (Speed too high) or
-- effectively-stationary (Speed too low, reads as broken rather than "a very slow projectile").
local CLAMP_MIN_PROJECTILE_SPEED = 5
local CLAMP_MAX_PROJECTILE_SPEED = 1999
local CLAMP_MIN_PROJECTILE_RANGE = 5
local CLAMP_MAX_PROJECTILE_RANGE = 1999
-- Full turn either way on each axis. Wider than strictly necessary (180 covers every distinct
-- orientation) but an author dragging a rotation field past 180 expects it to keep going rather
-- than stick, and a redundant orientation is harmless.
local CLAMP_MIN_ROTATION_DEGREES = -360
local CLAMP_MAX_ROTATION_DEGREES = 360
-- Free-text authored strings that reach a DataStore record. Bounded so one move can never blow the
-- per-key size budget with a pathological paste.
local MAX_ASSET_ID_LENGTH = 120
local MAX_TAG_LENGTH = 64

local ObjectStunConfig = Constants.MoveEditor.ObjectStun

local moves: { [string]: MoveTypes.MoveDefinition } = {}

local function isNonEmptyString(value: unknown): boolean
	return typeof(value) == "string" and (value :: string) ~= ""
end

local function clampedNumber(value: unknown, min: number, max: number): number?
	if typeof(value) ~= "number" then
		return nil
	end
	local number = value :: number
	if number ~= number then
		-- NaN passes typeof but survives math.clamp -- treated as "not a number was supplied",
		-- which for a required field is a hard reject and for an optional one is a fallback.
		return nil
	end
	return math.clamp(number, min, max)
end

-- Clamps against one of Constants.MoveEditor.ObjectStun.Limits' {Min, Max} pairs, falling back to
-- `fallback` for anything non-numeric. Normalizing, never rejecting -- see this file's header on
-- why the Object Stun block follows the clamp rule rather than the hard-reject rule.
local function clampLimit(value: unknown, limit: { Min: number, Max: number }, fallback: number): number
	local clamped = clampedNumber(value, limit.Min, limit.Max)
	if clamped == nil then
		return math.clamp(fallback, limit.Min, limit.Max)
	end
	return clamped
end

local function boundedString(value: unknown, maxLength: number): string
	if typeof(value) ~= "string" then
		return ""
	end
	local text = value :: string
	if #text > maxLength then
		return text:sub(1, maxLength)
	end
	return text
end

local function readBoolean(value: unknown, fallback: boolean): boolean
	if typeof(value) == "boolean" then
		return value :: boolean
	end
	return fallback
end

-- Validates+clamps the optional MoveMovementGrant sub-table. A present-but-malformed Movement is a
-- hard reject (the author clearly intended to author one); an absent Movement is valid (nil).
local function validateMovement(raw: unknown): (MoveTypes.MoveMovementGrant?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidMovement"
	end
	local candidate = raw :: { [string]: unknown }
	local lungeDistance =
		clampedNumber(candidate.LungeDistanceStuds, CLAMP_MIN_LUNGE_DISTANCE_STUDS, CLAMP_MAX_LUNGE_DISTANCE_STUDS)
	local lungeDuration = clampedNumber(
		candidate.LungeDurationSeconds,
		CLAMP_MIN_LUNGE_DURATION_SECONDS,
		CLAMP_MAX_LUNGE_DURATION_SECONDS
	)
	if lungeDistance == nil or lungeDuration == nil then
		return nil, "InvalidMovement"
	end
	return { LungeDistanceStuds = lungeDistance, LungeDurationSeconds = lungeDuration }, nil
end

-- Same reasoning as validateMovement above, for the optional MoveKnockback sub-table.
local function validateKnockback(raw: unknown): (MoveTypes.MoveKnockback?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidKnockback"
	end
	local candidate = raw :: { [string]: unknown }
	local upVelocity = clampedNumber(candidate.UpVelocity, CLAMP_MIN_KNOCKBACK_VELOCITY, CLAMP_MAX_KNOCKBACK_VELOCITY)
	local horizontalVelocity =
		clampedNumber(candidate.HorizontalVelocity, CLAMP_MIN_KNOCKBACK_VELOCITY, CLAMP_MAX_KNOCKBACK_VELOCITY)
	local ragdollSeconds = clampedNumber(candidate.RagdollSeconds, CLAMP_MIN_RAGDOLL_SECONDS, CLAMP_MAX_RAGDOLL_SECONDS)
	if upVelocity == nil or horizontalVelocity == nil or ragdollSeconds == nil then
		return nil, "InvalidKnockback"
	end
	-- Optional -- absent (nil) on every Knockback authored before this field existed, defaults to
	-- false rather than a hard reject. Present-but-wrong-type is still a hard reject, same as every
	-- other field here -- the author clearly intended to author a value.
	local startsAirCombo = false
	if candidate.StartsAirCombo ~= nil then
		if typeof(candidate.StartsAirCombo) ~= "boolean" then
			return nil, "InvalidKnockback"
		end
		startsAirCombo = candidate.StartsAirCombo :: boolean
	end
	return {
		UpVelocity = upVelocity,
		HorizontalVelocity = horizontalVelocity,
		RagdollSeconds = ragdollSeconds,
		StartsAirCombo = startsAirCombo,
	},
		nil
end

-- Same reasoning as validateMovement/validateKnockback above, for the optional MoveGrabConfig
-- sub-table -- EXCEPT for AttachOffset, which is never taken from `raw` at all. See
-- MoveGrabConfig.AttachOffset's own header (MoveTypes.lua): it is not an author-editable field, so
-- there is no client-submitted value to trust OR clamp -- this always writes
-- GrabConstants.Defaults.AttachOffset, the same "the server decides what the numbers mean" posture
-- the move's own top-level Offset already takes for its translation, just total here rather than
-- partial since no legitimate candidate should ever disagree with this default.
-- Long enough for a real paragraph of intent, short enough that a pasted essay cannot bloat every
-- DataStore read of this move. Truncation is silent because the editor's own field caps input at
-- the same number, so the only way to reach this is a hand-crafted payload.
local MAX_DESCRIPTION_LENGTH = 400

local function readDescription(raw: unknown): string
	if typeof(raw) ~= "string" then
		return ""
	end
	return string.sub(raw :: string, 1, MAX_DESCRIPTION_LENGTH)
end

local function validateGrab(raw: unknown): (MoveTypes.MoveGrabConfig?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidGrab"
	end
	local candidate = raw :: { [string]: unknown }
	local holdSeconds = clampedNumber(candidate.HoldSeconds, GRAB_LIMITS.HoldSeconds.Min, GRAB_LIMITS.HoldSeconds.Max)
	local throwUpVelocity =
		clampedNumber(candidate.ThrowUpVelocity, GRAB_LIMITS.ThrowUpVelocity.Min, GRAB_LIMITS.ThrowUpVelocity.Max)
	local throwHorizontalVelocity = clampedNumber(
		candidate.ThrowHorizontalVelocity,
		GRAB_LIMITS.ThrowHorizontalVelocity.Min,
		GRAB_LIMITS.ThrowHorizontalVelocity.Max
	)
	local throwImpactDamage =
		clampedNumber(candidate.ThrowImpactDamage, GRAB_LIMITS.ThrowImpactDamage.Min, GRAB_LIMITS.ThrowImpactDamage.Max)
	local throwSelfDamage =
		clampedNumber(candidate.ThrowSelfDamage, GRAB_LIMITS.ThrowSelfDamage.Min, GRAB_LIMITS.ThrowSelfDamage.Max)
	if
		holdSeconds == nil
		or throwUpVelocity == nil
		or throwHorizontalVelocity == nil
		or throwImpactDamage == nil
		or throwSelfDamage == nil
	then
		return nil, "InvalidGrab"
	end
	return {
		AttachOffset = GrabConstants.Defaults.AttachOffset,
		HoldSeconds = holdSeconds,
		ThrowUpVelocity = throwUpVelocity,
		ThrowHorizontalVelocity = throwHorizontalVelocity,
		ThrowImpactDamage = throwImpactDamage,
		ThrowSelfDamage = throwSelfDamage,
	},
		nil
end

-- Same reasoning as validateMovement/validateKnockback above, for the optional
-- MoveProjectileConfig sub-table.
local function validateProjectile(raw: unknown): (MoveTypes.MoveProjectileConfig?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidProjectile"
	end
	local candidate = raw :: { [string]: unknown }
	local speed = clampedNumber(candidate.Speed, CLAMP_MIN_PROJECTILE_SPEED, CLAMP_MAX_PROJECTILE_SPEED)
	local maxRange = clampedNumber(candidate.MaxRange, CLAMP_MIN_PROJECTILE_RANGE, CLAMP_MAX_PROJECTILE_RANGE)
	if speed == nil or maxRange == nil then
		return nil, "InvalidProjectile"
	end
	return { Speed = speed, MaxRange = maxRange }, nil
end

-- Builds the (translation + rotation) Offset CFrame from the FLAT wire numbers a candidate carries,
-- never from a client-supplied CFrame. v1 enforced "no rotation" by construction here; v2 allows
-- rotation but keeps the same principle -- the client proposes six numbers, this function decides
-- what CFrame they mean, so a hand-crafted payload can't smuggle in a scale/shear component.
--
-- fromEulerAnglesYXZ (yaw, then pitch, then roll) rather than CFrame.Angles' XYZ order: yaw-first
-- is what "turn it to face this way, then tilt it" means to someone typing degrees into three
-- fields, and it keeps yaw independent of pitch, which XYZ order does not.
local function buildOffset(x: number, y: number, z: number, rotation: Vector3): CFrame
	return CFrame.new(x, y, z)
		* CFrame.fromEulerAnglesYXZ(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
end

-- Reads the three flat OffsetRotation wire numbers into a clamped degrees Vector3. Absent is legal
-- and means "no rotation" -- exactly what every v1 record and every pre-rotation client sends.
local function readRotation(raw: { [string]: unknown }, prefix: string): Vector3
	local function axis(suffix: string): number
		return clampedNumber(raw[prefix .. suffix], CLAMP_MIN_ROTATION_DEGREES, CLAMP_MAX_ROTATION_DEGREES) or 0
	end
	return Vector3.new(axis("X"), axis("Y"), axis("Z"))
end

-- The v1 -> v2 geometry bridge, and the one geometry check that stays a HARD REJECT.
--
-- A candidate carrying a real Dimensions table (every v2 client, every v2 record) uses it directly.
-- Otherwise it is reconstructed from whatever the v1 shape had -- Size's three axes for a Box,
-- Radius for a Sphere -- so an old record produces exactly the volume it always did rather than
-- silently snapping to this shape's defaults.
--
-- A candidate with NEITHER is rejected ("MissingDimensions"), which is the direct successor to v1's
-- own MissingSize/MissingRadius rejections and preserves their intent: a move whose geometry can't
-- be determined at all is not a coherent move, and quietly substituting a 4x4x4 box would hand back
-- a hitbox the author never authored. That is a different case from an out-of-RANGE dimension,
-- which HitboxShapes.Sanitize clamps -- see this file's header on where that line sits.
local function dimensionsFromCandidate(
	shape: HitboxShapes.ShapeId,
	raw: { [string]: unknown }
): (HitboxShapes.Dimensions?, string?)
	if typeof(raw.Dimensions) == "table" then
		return HitboxShapes.Sanitize(shape, raw.Dimensions), nil
	end

	if shape == "Box" and typeof(raw.Size) == "Vector3" then
		local size = raw.Size :: Vector3
		return HitboxShapes.Sanitize(shape, { Width = size.X, Height = size.Y, Depth = size.Z }), nil
	end
	if shape == "Sphere" and typeof(raw.Radius) == "number" then
		return HitboxShapes.Sanitize(shape, { Radius = raw.Radius :: number }), nil
	end

	return nil, "MissingDimensions"
end

-- Derives the two legacy geometry fields from Dimensions. Populated for exactly the two shapes
-- whose bounding box IS their volume, and nil for every other -- see MoveDefinition.Size/Radius'
-- own header and Types.HitboxAttackDefinition.Shape's, which together are why widening the shape
-- vocabulary could not regress a single existing attack.
local function deriveLegacyGeometry(
	shape: HitboxShapes.ShapeId,
	dimensions: HitboxShapes.Dimensions
): (Vector3?, number?)
	if shape == "Box" then
		return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Depth), nil
	elseif shape == "Sphere" then
		return nil, dimensions.Radius
	end
	return nil, nil
end

-- The optional Object Stun follow-up. Normalizing like its parent (see this file's header): a
-- malformed field falls back to Constants.MoveEditor.ObjectStun.FollowUpDefaults rather than
-- failing the move, EXCEPT for a present-but-malformed Knockback, which reuses validateKnockback's
-- own hard-reject contract so a follow-up's knockback behaves exactly like a move's does.
local function validateFollowUp(raw: unknown): (Types.ObjectStunFollowUp?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidObjectStunFollowUp"
	end
	local candidate = raw :: { [string]: unknown }
	local limits = ObjectStunConfig.Limits
	local defaults = ObjectStunConfig.FollowUpDefaults

	local shape: HitboxShapes.ShapeId = if HitboxShapes.IsShapeId(candidate.Shape)
		then candidate.Shape :: HitboxShapes.ShapeId
		else defaults.Shape :: HitboxShapes.ShapeId
	-- Unlike the parent move's own geometry, a follow-up with no dimensions falls back to this
	-- shape's defaults rather than rejecting: a follow-up is an OPTIONAL sub-block being switched on
	-- for the first time, so "the author hasn't told us the size yet" is a normal intermediate
	-- state, not a malformed move. The parent move can never be in that state -- it always has a
	-- hitbox.
	local dimensions = dimensionsFromCandidate(shape, candidate) or HitboxShapes.DefaultDimensions(shape)

	local offsetX = clampedNumber(candidate.OffsetX, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS) or defaults.OffsetX
	local offsetY = clampedNumber(candidate.OffsetY, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS) or defaults.OffsetY
	local offsetZ = clampedNumber(candidate.OffsetZ, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS) or defaults.OffsetZ
	local rotation = readRotation(candidate, "OffsetRotation")

	local knockback, knockbackError = validateKnockback(candidate.Knockback)
	if knockbackError then
		return nil, knockbackError
	end

	return {
		Enabled = readBoolean(candidate.Enabled, false),
		DelaySeconds = clampLimit(candidate.DelaySeconds, limits.FollowUpDelaySeconds, defaults.DelaySeconds),
		AnimationId = boundedString(candidate.AnimationId, MAX_ASSET_ID_LENGTH),

		WindupSeconds = clampedNumber(candidate.WindupSeconds, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
			or defaults.WindupSeconds,
		ActiveSeconds = clampedNumber(candidate.ActiveSeconds, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
			or defaults.ActiveSeconds,
		RecoverySeconds = clampedNumber(candidate.RecoverySeconds, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
			or defaults.RecoverySeconds,
		Damage = clampedNumber(candidate.Damage, CLAMP_MIN_DAMAGE, CLAMP_MAX_DAMAGE) or defaults.Damage,
		PostureDamage = clampedNumber(candidate.PostureDamage, CLAMP_MIN_DAMAGE, CLAMP_MAX_DAMAGE)
			or defaults.PostureDamage,
		MaxTargets = math.floor(clampLimit(candidate.MaxTargets, limits.FollowUpMaxTargets, defaults.MaxTargets)),

		Shape = shape,
		Dimensions = dimensions,
		Offset = buildOffset(offsetX, offsetY, offsetZ, rotation),
		OffsetRotation = rotation,

		TeleportAttacker = readBoolean(candidate.TeleportAttacker, defaults.TeleportAttacker),
		TeleportDistanceStuds = clampLimit(
			candidate.TeleportDistanceStuds,
			limits.FollowUpTeleportDistanceStuds,
			defaults.TeleportDistanceStuds
		),

		Knockback = knockback,
	},
		nil
end

-- The optional Object Stun block. Absent is valid (nil, the overwhelmingly common case). Present
-- but not a table is a hard reject -- the author clearly intended to author one -- and every field
-- inside is then clamped against Constants.MoveEditor.ObjectStun.Limits, the same table the
-- editor's own fields are bounded by.
-- The Move-Creation-System-to-ArtSystem seam (MoveTypes.MoveArtBinding). nil in, nil out: a move
-- with no Art block is an ordinary move and always has been, so every pre-existing move and every
-- v1 DataStore record validates unchanged.
--
-- Present, and it is validated STRICTLY on identity but LENIENTLY on numbers -- the same split
-- validateObjectStun uses. TreeId must name a real ArtConstants.ArtTrees entry (a typo'd tree would
-- put the art in a tree nothing renders, which is worse than a save failure the author can see),
-- while Node/QiCost/RequiredTier are clamped into ArtConstants.Limits rather than rejected, so a
-- designer nudging a field past its bound in the editor gets a sane art instead of a blocked save.
--
-- Prerequisite is rejected when it points at the move's own id: an art that requires itself can
-- never be unlocked, and that is a typo worth surfacing loudly rather than silently dropping. A
-- prerequisite naming some OTHER art is NOT checked for existence here -- ordering is not
-- guaranteed (the prerequisite may be authored after its dependant, or live in a record that loads
-- later), so that check belongs to ArtTreeManager reading the whole registry at once.
local function validateArt(raw: unknown, moveId: string): (MoveTypes.MoveArtBinding?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidArt"
	end
	local candidate = raw :: { [string]: unknown }

	if not isNonEmptyString(candidate.TreeId) then
		return nil, "InvalidArtTreeId"
	end
	local treeId = candidate.TreeId :: string
	local treeExists = false
	for _, tree in ipairs(ArtConstants.ArtTrees) do
		if tree.TreeId == treeId then
			treeExists = true
			break
		end
	end
	if not treeExists then
		return nil, "UnknownArtTree"
	end

	local prerequisite: string? = nil
	if candidate.Prerequisite ~= nil then
		if not isNonEmptyString(candidate.Prerequisite) then
			return nil, "InvalidArtPrerequisite"
		end
		if candidate.Prerequisite == moveId then
			return nil, "SelfReferentialArtPrerequisite"
		end
		prerequisite = candidate.Prerequisite :: string
	end

	local limits = ArtConstants.Limits
	return {
		TreeId = treeId,
		Node = clampLimit(candidate.Node, limits.Node, limits.Node.Min),
		QiCost = clampLimit(candidate.QiCost, limits.QiCost, limits.QiCost.Min),
		RequiredTier = clampLimit(candidate.RequiredTier, limits.RequiredTier, limits.RequiredTier.Min),
		Prerequisite = prerequisite,
	},
		nil
end

local function validateObjectStun(raw: unknown): (Types.ObjectStunConfig?, string?)
	if raw == nil then
		return nil, nil
	end
	if typeof(raw) ~= "table" then
		return nil, "InvalidObjectStun"
	end
	local candidate = raw :: { [string]: unknown }
	local limits = ObjectStunConfig.Limits
	local defaults = ObjectStunConfig.Defaults

	local rawSurfaces: { [string]: unknown } = if typeof(candidate.Surfaces) == "table"
		then candidate.Surfaces :: { [string]: unknown }
		else {}
	local surfaces: Types.ObjectStunSurfaces = {
		Walls = readBoolean(rawSurfaces.Walls, defaults.Surfaces.Walls),
		Floors = readBoolean(rawSurfaces.Floors, defaults.Surfaces.Floors),
		Ceilings = readBoolean(rawSurfaces.Ceilings, defaults.Surfaces.Ceilings),
		Props = readBoolean(rawSurfaces.Props, defaults.Surfaces.Props),
	}

	local followUp, followUpError = validateFollowUp(candidate.FollowUp)
	if followUpError then
		return nil, followUpError
	end

	local effectColor = if typeof(candidate.EffectColor) == "Color3"
		then candidate.EffectColor :: Color3
		else defaults.EffectColor

	return {
		Enabled = readBoolean(candidate.Enabled, false),

		Surfaces = surfaces,
		RequireAnchored = readBoolean(candidate.RequireAnchored, defaults.RequireAnchored),
		RequirePartTag = boundedString(candidate.RequirePartTag, MAX_TAG_LENGTH),
		MinSurfaceExtentStuds = clampLimit(
			candidate.MinSurfaceExtentStuds,
			limits.MinSurfaceExtentStuds,
			defaults.MinSurfaceExtentStuds
		),
		ProbeDistanceStuds = clampLimit(
			candidate.ProbeDistanceStuds,
			limits.ProbeDistanceStuds,
			defaults.ProbeDistanceStuds
		),
		RequiredClearanceStuds = clampLimit(
			candidate.RequiredClearanceStuds,
			limits.RequiredClearanceStuds,
			defaults.RequiredClearanceStuds
		),
		MinTravelStuds = clampLimit(candidate.MinTravelStuds, limits.MinTravelStuds, defaults.MinTravelStuds),
		MinImpactSpeed = clampLimit(candidate.MinImpactSpeed, limits.MinImpactSpeed, defaults.MinImpactSpeed),
		MaxImpactAngleDegrees = clampLimit(
			candidate.MaxImpactAngleDegrees,
			limits.MaxImpactAngleDegrees,
			defaults.MaxImpactAngleDegrees
		),
		MaxTravelSeconds = clampLimit(candidate.MaxTravelSeconds, limits.MaxTravelSeconds, defaults.MaxTravelSeconds),

		StunSeconds = clampLimit(candidate.StunSeconds, limits.StunSeconds, defaults.StunSeconds),
		RagdollSeconds = clampLimit(candidate.RagdollSeconds, limits.RagdollSeconds, defaults.RagdollSeconds),
		BonusDamage = clampLimit(candidate.BonusDamage, limits.BonusDamage, defaults.BonusDamage),
		BonusPostureDamage = clampLimit(
			candidate.BonusPostureDamage,
			limits.BonusPostureDamage,
			defaults.BonusPostureDamage
		),
		ReboundVelocity = clampLimit(candidate.ReboundVelocity, limits.ReboundVelocity, defaults.ReboundVelocity),
		PinSeconds = clampLimit(candidate.PinSeconds, limits.PinSeconds, defaults.PinSeconds),
		VictimAnimationId = boundedString(candidate.VictimAnimationId, MAX_ASSET_ID_LENGTH),
		AttackerAnimationId = boundedString(candidate.AttackerAnimationId, MAX_ASSET_ID_LENGTH),
		SoundId = boundedString(candidate.SoundId, MAX_ASSET_ID_LENGTH),
		EffectColor = effectColor,
		CameraShakeScale = clampLimit(candidate.CameraShakeScale, limits.CameraShakeScale, defaults.CameraShakeScale),

		CooldownSeconds = clampLimit(candidate.CooldownSeconds, limits.CooldownSeconds, defaults.CooldownSeconds),
		MaxTriggersPerMove = math.floor(
			clampLimit(candidate.MaxTriggersPerMove, limits.MaxTriggersPerMove, defaults.MaxTriggersPerMove)
		),

		FollowUp = followUp,
	},
		nil
end

-- The one strict allow-list gate every MoveDefinition-shaped table passes through -- see this
-- file's header. `candidate` is `unknown` deliberately: it may be a raw client RemoteFunction
-- argument, a DataStore-decoded record, or (in a test) a hand-written table literal -- Validate
-- treats all three identically.
--
-- The wire/storage representation of Offset is NOT a raw CFrame -- a candidate carries
-- OffsetX/OffsetY/OffsetZ plus OffsetRotationX/Y/Z plain numbers instead, which this function
-- converts into a real CFrame itself (buildOffset). That keeps "the server decides what the
-- author's numbers mean" an invariant enforced by construction rather than trusting a
-- client-constructed CFrame -- see MoveDefinition.Offset's own header.
-- `allowReservedCategory` (optional, default false): whether Category may be the reserved
-- MoveTypes.DefaultCategory sentinel. Exactly ONE caller passes true -- Server/Combat/
-- DefaultMoveRegistry.ApplyEdit, whose candidate genuinely IS a Default move and legitimately
-- carries it. Every client-submitted path (MoveEditorSystem's handleUpdateDraft/handleSaveMove)
-- leaves it false, which is what closes the hole MoveTypes.lua's own header documents: a custom move
-- claiming "Default" would be filtered into MoveList's Default tab, have its Movement/Knockback/
-- Projectile/ObjectStun nav items and section content hidden, lose its Delete action entirely, and
-- route its saves to SaveDefaultMove -- an unreachable, undeletable move.
--
-- A parameter rather than an unconditional check specifically BECAUSE of that one caller: rejecting
-- the sentinel outright would break Default-move editing, since ApplyEdit runs a real Default move's
-- candidate through this exact function on every edit.
function MoveRegistryManager.Validate(
	candidate: unknown,
	allowReservedCategory: boolean?
): (MoveTypes.MoveDefinition?, string?)
	if typeof(candidate) ~= "table" then
		return nil, "InvalidShape"
	end
	local raw = candidate :: { [string]: unknown }

	if not isNonEmptyString(raw.MoveId) then
		return nil, "InvalidMoveId"
	end
	if typeof(raw.DisplayName) ~= "string" then
		return nil, "InvalidDisplayName"
	end
	if typeof(raw.Category) ~= "string" then
		return nil, "InvalidCategory"
	end
	-- Exact-match, deliberately not case-insensitive: DefaultMoveRegistry writes exactly this string
	-- and every UI consumer filters on `== MoveTypes.DefaultCategory`, so a lowercase "default" is an
	-- ordinary harmless author tag rather than something to reject.
	if raw.Category == MoveTypes.DefaultCategory and allowReservedCategory ~= true then
		return nil, "ReservedCategory"
	end
	if not isNonEmptyString(raw.Author) then
		return nil, "InvalidAuthor"
	end
	if typeof(raw.CreatedAt) ~= "number" then
		return nil, "InvalidCreatedAt"
	end
	if typeof(raw.UpdatedAt) ~= "number" then
		return nil, "InvalidUpdatedAt"
	end

	-- Membership is checked against HitboxShapes' own runtime registry, never a literal list here --
	-- see Types.HitboxShapeId's header on which of the two copies is authoritative.
	if not HitboxShapes.IsShapeId(raw.Shape) then
		return nil, "InvalidShapeField"
	end
	local shape = raw.Shape :: HitboxShapes.ShapeId

	local dimensions, dimensionsError = dimensionsFromCandidate(shape, raw)
	if dimensions == nil then
		return nil, dimensionsError
	end
	local size, radius = deriveLegacyGeometry(shape, dimensions)

	local offsetX = clampedNumber(raw.OffsetX, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS)
	local offsetY = clampedNumber(raw.OffsetY, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS)
	local offsetZ = clampedNumber(raw.OffsetZ, CLAMP_MIN_OFFSET_STUDS, CLAMP_MAX_OFFSET_STUDS)
	if offsetX == nil or offsetY == nil or offsetZ == nil then
		return nil, "InvalidOffset"
	end
	local offsetRotation = readRotation(raw, "OffsetRotation")

	local windupSeconds = clampedNumber(raw.WindupSeconds, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	local activeSeconds = clampedNumber(raw.ActiveSeconds, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	local recoverySeconds = clampedNumber(raw.RecoverySeconds, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	local cooldown = clampedNumber(raw.Cooldown, CLAMP_MIN_SECONDS, CLAMP_MAX_SECONDS)
	if windupSeconds == nil or activeSeconds == nil or recoverySeconds == nil or cooldown == nil then
		return nil, "InvalidTiming"
	end

	local damage = clampedNumber(raw.Damage, CLAMP_MIN_DAMAGE, CLAMP_MAX_DAMAGE)
	local postureDamage = clampedNumber(raw.PostureDamage, CLAMP_MIN_DAMAGE, CLAMP_MAX_DAMAGE)
	if damage == nil or postureDamage == nil then
		return nil, "InvalidDamage"
	end

	local arcDegrees: number? = nil
	if raw.ArcDegrees ~= nil then
		arcDegrees = clampedNumber(raw.ArcDegrees, CLAMP_MIN_ARC_DEGREES, CLAMP_MAX_ARC_DEGREES)
		if arcDegrees == nil then
			return nil, "InvalidArcDegrees"
		end
	end

	local maxTargets: number? = nil
	if raw.MaxTargets ~= nil then
		local clamped = clampedNumber(raw.MaxTargets, CLAMP_MIN_MAX_TARGETS, CLAMP_MAX_MAX_TARGETS)
		if clamped == nil then
			return nil, "InvalidMaxTargets"
		end
		maxTargets = math.floor(clamped)
	end

	if typeof(raw.AnimationId) ~= "string" then
		return nil, "InvalidAnimationId"
	end
	local animationId = boundedString(raw.AnimationId, MAX_ASSET_ID_LENGTH)

	-- An empty (or absent) Animations list with a non-empty AnimationId is exactly what every v1
	-- record and every pre-timeline client looks like -- projected onto a one-clip timeline so the
	-- move plays identically to how it always did, with no migration pass anywhere. An author who
	-- then edits the timeline in the editor is editing that same reconstructed clip.
	local animations = AnimationTimeline.Sanitize(raw.Animations)
	if #animations == 0 and animationId ~= "" then
		animations = AnimationTimeline.FromLegacyAnimationId(animationId)
	end

	local movement, movementError = validateMovement(raw.Movement)
	if movementError then
		return nil, movementError
	end
	local knockback, knockbackError = validateKnockback(raw.Knockback)
	if knockbackError then
		return nil, knockbackError
	end
	local grab, grabError = validateGrab(raw.Grab)
	if grabError then
		return nil, grabError
	end
	local projectile, projectileError = validateProjectile(raw.Projectile)
	if projectileError then
		return nil, projectileError
	end
	local objectStun, objectStunError = validateObjectStun(raw.ObjectStun)
	if objectStunError then
		return nil, objectStunError
	end
	local art, artError = validateArt(raw.Art, raw.MoveId :: string)
	if artError then
		return nil, artError
	end

	local validated: MoveTypes.MoveDefinition = {
		MoveId = raw.MoveId :: string,
		DisplayName = raw.DisplayName :: string,
		-- TRUNCATED, never rejected, and absent is legal. Description is a note an author writes for
		-- themselves -- the "in-range values clamp, structural errors reject" split this file follows
		-- everywhere else puts an over-long one squarely on the clamp side, and every record persisted
		-- before this field existed has to keep validating unchanged.
		Description = readDescription(raw.Description),
		Category = raw.Category :: string,
		Author = raw.Author :: string,
		CreatedAt = raw.CreatedAt :: number,
		UpdatedAt = raw.UpdatedAt :: number,
		Shape = shape,
		Dimensions = dimensions,
		Size = size,
		Radius = radius,
		Offset = buildOffset(offsetX, offsetY, offsetZ, offsetRotation),
		OffsetRotation = offsetRotation,
		WindupSeconds = windupSeconds,
		ActiveSeconds = activeSeconds,
		RecoverySeconds = recoverySeconds,
		Cooldown = cooldown,
		Damage = damage,
		PostureDamage = postureDamage,
		ArcDegrees = arcDegrees,
		MaxTargets = maxTargets,
		AnimationId = animationId,
		Animations = animations,
		Movement = movement,
		Knockback = knockback,
		Grab = grab,
		Projectile = projectile,
		ObjectStun = objectStun,
		Art = art,
	}
	return validated, nil
end

-- Deep copy for a caller to freely mutate without corrupting the registry -- the same "return a
-- copy, never the live table" contract as PlayerDataSystem.GetProfile.
--
-- Delegates to Shared/MoveTypes.Clone rather than doing it here, which is not just deduplication:
-- the local copyMove this replaced was BUILT ON table.clone(move), so every field it did not name
-- explicitly came through ALIASED. That was correct when it was written and had quietly stopped
-- being correct -- Slam and Art were added to MoveDefinition afterwards, neither was ever added
-- here, and both were being handed out sharing the registry's own tables. An editor mutating a
-- returned move's Art binding was reaching back into the live registry.
--
-- MoveTypes.Clone cannot acquire that failure mode: it enumerates the schema explicitly, so a new
-- field is DROPPED (loudly, on the next read) rather than aliased (silently, forever). That is the
-- whole argument for keeping one clone rather than two, and this module already required MoveTypes.
local function copyMove(move: MoveTypes.MoveDefinition): MoveTypes.MoveDefinition
	return MoveTypes.Clone(move)
end

function MoveRegistryManager.Init(): ()
	moves = {}
end

function MoveRegistryManager.List(): { MoveTypes.MoveDefinition }
	local result = {}
	for _, move in pairs(moves) do
		table.insert(result, copyMove(move))
	end
	return result
end

function MoveRegistryManager.Get(moveId: string): MoveTypes.MoveDefinition?
	local move = moves[moveId]
	if not move then
		return nil
	end
	return copyMove(move)
end

-- In-memory write only -- see this file's header for why this is what makes an edit "take effect
-- immediately" without any DataStore round trip. `validated` must already have passed Validate;
-- this function trusts its caller (MoveEditorSystem) on that, matching Upsert-after-Validate being
-- two separate steps everywhere else conforming data flows in this codebase (e.g.
-- PlayerDataSystem.Transform trusting its own mutator).
function MoveRegistryManager.Upsert(validated: MoveTypes.MoveDefinition): ()
	moves[validated.MoveId] = copyMove(validated)
end

function MoveRegistryManager.Delete(moveId: string): ()
	moves[moveId] = nil
end

-- Server-generated (never client-chosen) so two admins creating a move at the same moment can
-- never collide -- derived from DisplayName purely for readability in logs/DataStore keys, with a
-- random numeric suffix disambiguating it, retried against the live registry until unique.
function MoveRegistryManager.GenerateMoveId(displayName: string): string
	local base = displayName:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if base == "" then
		base = "move"
	end
	local candidate: string
	repeat
		candidate = base .. "-" .. tostring(math.random(1000, 9999))
	until moves[candidate] == nil
	return candidate
end

-- The lossless projection every combat-side caller actually consumes -- delegates to
-- MoveTypes.ToHitboxAttackDefinition (the single source of truth for the projection) so this
-- module's public API still reads as "everything you need lives here" for CombatSystem.lua.
function MoveRegistryManager.ToHitboxAttackDefinition(move: MoveTypes.MoveDefinition): Types.HitboxAttackDefinition
	return MoveTypes.ToHitboxAttackDefinition(move)
end

return MoveRegistryManager
