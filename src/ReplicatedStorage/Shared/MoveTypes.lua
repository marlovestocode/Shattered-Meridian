--!strict
--[[
	MoveTypes.lua

	Owns: the authored-move schema -- what a move IS to the Move Editor, the move registries and the
	combat stack's catalogue -- plus the handful of pure functions every one of them needs to agree on:
	Clone, Fingerprint, ToWire (the one flat encoding, used both on the wire and in the DataStore) and
	ToEngineAttackDefinition (the projection AttackCatalog hands HitboxEngine and the damage layer).

	ENGINE-NATIVE, AND THAT IS THE WHOLE REBUILD (2026-09-29). The previous schema was a superset of the
	DELETED combat system's struct: twelve shapes of which the engine understands seven (the other five
	were projected onto a Box and a warning), an eight-field dimension bag with two names for one
	measurement (HitboxShapes' Depth is the engine's Length), a multi-clip animation timeline nothing
	played, and Projectile / Movement / ObjectStun / Slam / ArcDegrees / Knockback.RagdollSeconds blocks
	whose runtimes were all deleted. Every one of them was authored, validated, persisted and shown in
	the editor, and did nothing. What is left is exactly what a live system reads:

	  * Shape / Dimensions / AttachmentPart / LocksMovement are HitboxTypes' own vocabulary, so the
	    projection is a copy, never an approximation.
	  * Timing, Damage / PostureDamage / MaxTargets, PowerLevel (GuardMeter.DrainFor) and Feintable
	    (AttackRequestSystem.Feint).
	  * AnimationId -- the one clip AttackCatalog syncs the swing to (Shared/Attack/AttackWindows.lua).
	  * Knockback (Shared/Damage/Knockback.lua, AirComboSystem's launcher test), Grab (GrabSystem) and
	    Art (ArtSystem / ArtTreeManager -- an art IS a move with this block on it).

	A record persisted under the old schema still loads: Server/Systems/Support/MoveRecordCodec.lua
	upgrades it into this shape before validation, keeping every field that still means something and
	dropping the rest. That upgrade is the only place the old vocabulary is still spoken.

	PROJECTED-ONLY FIELDS. SizeMultiplier, SpawnDelaySeconds, WeaponSpeed and Tempo describe the WEAPON
	a Default move belongs to, not the move; DefaultMoveRegistry stamps them on every read and nothing
	authors them. They ride on the definition because AttackCatalog needs them beside the timing they
	modify, and they are deliberately absent from ToWire and Fingerprint.

	Does not own: validation and clamping (Server/Combat/MoveRegistryManager.Validate, against
	Constants.MoveEditor.Limits), persistence (MoveRecordCodec + MoveEditorSystem), which move a MoveId
	resolves to (AttackCatalog), or the geometry math (Shared/HitboxEngine/HitboxGeometry.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

local MoveTypes = {}

-- Weight class -----------------------------------------------------------------------------------------

-- A custom move that authors no PowerLevel weighs this much. Bounds are both Validate's clamp and the
-- editor field's range.
MoveTypes.DefaultPowerLevel = 1
MoveTypes.PowerLevelLimits = { Min = 1, Max = 4 }

-- What a weapon string's Default moves project with, by stage. A blocked launcher drains like a heavy:
-- it is the string's committed payoff. Air hits are never blocked (an air-held guard does nothing), so
-- their weight only ever reaches hitbox scaling, where it is inert.
MoveTypes.PowerLevelByStage = {
	Basic = 1,
	Heavy = 2,
	Finisher = 2,
	Launcher = 2,
	Air = 1,
	AirFinisher = 2,
}

-- Both ground strings may be feinted (user call, 2026-09-28: right-click during an attack has to do
-- something). A Finisher is the string's committed payoff, and an air beat's DELAY is already its bait
-- (AirComboConstants.Timing) -- a feint on top would make the victim's one read unwinnable.
MoveTypes.FeintableByStage = {
	Basic = true,
	Heavy = true,
	Finisher = false,
	Launcher = false,
	Air = false,
	AirFinisher = false,
}

function MoveTypes.PowerLevelOf(move: { PowerLevel: number? }): number
	local level = move.PowerLevel
	if typeof(level) ~= "number" or level ~= level then
		return MoveTypes.DefaultPowerLevel
	end
	return math.clamp(level, MoveTypes.PowerLevelLimits.Min, MoveTypes.PowerLevelLimits.Max)
end

function MoveTypes.IsFeintable(move: { Feintable: boolean? }): boolean
	return move.Feintable == true
end

-- Schema ------------------------------------------------------------------------------------------------

export type MoveShape = HitboxTypes.ShapeKind
export type MoveDimensions = HitboxTypes.Dimensions
export type MoveAttachmentPoint = HitboxTypes.AttachmentPoint

-- Every shape, in the order the editor offers them. The engine's IsShapeKind is the authority on
-- membership; this list is only the presentation order, and MoveTypes.spec pins the two together.
MoveTypes.Shapes = { "Box", "Sphere", "Capsule", "Cylinder", "Cone", "Beam", "Arc" } :: { MoveShape }
MoveTypes.AttachmentPoints = { "Root", "RightHand", "LeftHand", "Weapon" } :: { MoveAttachmentPoint }

-- The velocity a landed hit hands its target (Shared/Damage/Knockback.lua), along the attacker's facing.
-- StartsAirCombo marks the hit as a launcher: AirComboSystem opens an air string off it the same way it
-- does off a weapon's own Launcher stage.
export type MoveKnockback = {
	UpVelocity: number,
	HorizontalVelocity: number,
	StartsAirCombo: boolean?,
}

-- "Hold, then throw" instead of an ordinary knockback -- see Server/Combat/Grab/GrabSystem.lua. The
-- attach offset is NOT authored: Validate always writes GrabConstants.Defaults.AttachOffset, and ToWire
-- never sends one, so there is no client-supplied CFrame to trust.
export type MoveGrabConfig = {
	AttachOffset: CFrame,
	HoldSeconds: number,
	ThrowUpVelocity: number,
	ThrowHorizontalVelocity: number,
	ThrowImpactDamage: number,
	ThrowSelfDamage: number,
}

-- Declares a move to BE an art: which tree, what it costs, what earns it. Every field is required once
-- the block is present -- a half-authored art would appear in a tree a player can see and then behave
-- unpredictably. See ArtConstants.lua's header for why an art is a move rather than a parallel object.
export type MoveArtBinding = {
	TreeId: string,
	-- Depth in the tree. Node 1 is an entry form and is never gated behind a prerequisite.
	Node: number,
	QiCost: number,
	RequiredTier: number,
	-- The ArtId (== MoveId) that must be mastered first. nil for an entry form.
	Prerequisite: string?,
}

export type MoveDefinition = {
	-- Identity. MoveId is server-assigned once and immutable; Author/CreatedAt/UpdatedAt are stamped from
	-- trusted server context on every write (MoveEditorSystem), never taken from a client.
	MoveId: string,
	DisplayName: string,
	-- The author's note about what the move is FOR. Nothing in combat reads it; it is on the record
	-- because six months later a deliberately ugly windup is otherwise indistinguishable from an
	-- accidental one.
	Description: string,
	-- Free-form grouping tag for the editor's browser ("Signature", "Experimental"). Never read by combat.
	Category: string,
	Author: string,
	CreatedAt: number,
	UpdatedAt: number,

	-- Hitbox -- HitboxTypes' vocabulary, copied straight onto the engine definition.
	Shape: MoveShape,
	Dimensions: MoveDimensions,
	-- Built by Validate from six flat wire numbers (translation, then yaw/pitch/roll in degrees) -- the
	-- client never hands the server a CFrame. OffsetRotation keeps the degrees, because recovering clean
	-- angles back out of a matrix is lossy at the poles and degrees are what the editor shows.
	Offset: CFrame,
	OffsetRotation: Vector3,
	-- Which part the volume is anchored to, resolved live every sample. "Weapon" also sizes a Box off the
	-- equipped weapon's own Blade part (HitboxTypes.AttackDefinition.SizeFromAttachmentPart).
	AttachmentPart: MoveAttachmentPoint,
	-- Root control is locked for the Active window (HitboxEngineConstants.RootControlLockedAttribute).
	LocksMovement: boolean,

	-- Timing, in seconds. AttackCatalog re-derives the effective timeline from the move's clip; these
	-- are what the author typed.
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	Cooldown: number,

	-- What a landed hit costs.
	Damage: number,
	PostureDamage: number,
	-- nil = every target the volume contains, once each.
	MaxTargets: number?,
	-- Weight class. nil means DefaultPowerLevel; read through PowerLevelOf.
	PowerLevel: number?,
	-- Whether a swing may be cancelled early in its windup. nil means false; read through IsFeintable.
	Feintable: boolean?,

	-- "" = no clip authored. A Default move always carries "" and resolves its clip through
	-- Shared/Attack/AttackAnimations.lua instead.
	AnimationId: string,

	Knockback: MoveKnockback?,
	Grab: MoveGrabConfig?,
	Art: MoveArtBinding?,

	-- Projected-only (see this file's header). Never authored, never on the wire, never persisted.
	SizeMultiplier: number?,
	SpawnDelaySeconds: number?,
	WeaponSpeed: number?,
	Tempo: number?,
}

-- What the damage layer needs from a move and the engine does not: the price of a landed hit and what it
-- does to the target. Defined here, where it is produced, so this schema never depends on the damage
-- layer.
export type DamageProfile = {
	Damage: number,
	PostureDamage: number,
	Knockback: MoveKnockback?,
	Grab: MoveGrabConfig?,
}

-- Copying -----------------------------------------------------------------------------------------------

-- An explicit field list rather than a recursive walk: a copy that mirrors the schema can only produce
-- a valid MoveDefinition, where a generic deep copy faithfully reproduces whatever junk a malformed
-- source carried. It also means a field added to the schema and forgotten here is DROPPED (visibly, on
-- the next read) rather than aliased (silently, forever) -- the failure an earlier table.clone-based copy
-- in MoveRegistryManager actually had.
--
-- Offset/OffsetRotation/AttachOffset are immutable Roblox value types and are assigned, not copied.
function MoveTypes.Clone(move: MoveDefinition): MoveDefinition
	return {
		MoveId = move.MoveId,
		DisplayName = move.DisplayName,
		Description = move.Description,
		Category = move.Category,
		Author = move.Author,
		CreatedAt = move.CreatedAt,
		UpdatedAt = move.UpdatedAt,

		Shape = move.Shape,
		Dimensions = table.clone(move.Dimensions),
		Offset = move.Offset,
		OffsetRotation = move.OffsetRotation,
		AttachmentPart = move.AttachmentPart,
		LocksMovement = move.LocksMovement,

		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Cooldown = move.Cooldown,

		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		MaxTargets = move.MaxTargets,
		PowerLevel = move.PowerLevel,
		Feintable = move.Feintable,

		AnimationId = move.AnimationId,

		-- All three nest nothing but value types, so a flat clone is a deep one.
		Knockback = if move.Knockback then table.clone(move.Knockback) else nil,
		Grab = if move.Grab then table.clone(move.Grab) else nil,
		Art = if move.Art then table.clone(move.Art) else nil,

		SizeMultiplier = move.SizeMultiplier,
		SpawnDelaySeconds = move.SpawnDelaySeconds,
		WeaponSpeed = move.WeaponSpeed,
		Tempo = move.Tempo,
	}
end

-- The wire / storage encoding ---------------------------------------------------------------------------

-- The flat shape a move takes on the way INTO the server -- a client's draft and a DataStore record are
-- both this, and Validate accepts exactly this. One encoder for both is the point: the previous design
-- had a client encoder and a separate DataStore encoder, and the DataStore one twice silently forgot a
-- newly added field (Art, then Grab) while the client one sent it, so a move worked live and vanished on
-- the next boot.
--
-- Flat for two reasons. JSON (the DataStore) carries no Roblox value types. And the server must decide
-- what the author's numbers MEAN: it rebuilds Offset from six plain numbers, so a crafted payload cannot
-- hand it a CFrame with a scale or shear baked in.
--
-- Identity and projected-only fields are deliberately absent: the server stamps identity itself, and a
-- projected field is not the author's to set.
export type MoveWire = { [string]: any }

function MoveTypes.ToWire(move: MoveDefinition): MoveWire
	local offset = move.Offset.Position
	local wire: MoveWire = {
		MoveId = move.MoveId,
		DisplayName = move.DisplayName,
		Description = move.Description,
		Category = move.Category,

		Shape = move.Shape,
		Dimensions = table.clone(move.Dimensions),
		OffsetX = offset.X,
		OffsetY = offset.Y,
		OffsetZ = offset.Z,
		OffsetYaw = move.OffsetRotation.Y,
		OffsetPitch = move.OffsetRotation.X,
		OffsetRoll = move.OffsetRotation.Z,
		AttachmentPart = move.AttachmentPart,
		LocksMovement = move.LocksMovement,

		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		Cooldown = move.Cooldown,

		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		MaxTargets = move.MaxTargets,
		PowerLevel = move.PowerLevel,
		Feintable = move.Feintable,

		AnimationId = move.AnimationId,
	}
	if move.Knockback then
		wire.Knockback = {
			UpVelocity = move.Knockback.UpVelocity,
			HorizontalVelocity = move.Knockback.HorizontalVelocity,
			StartsAirCombo = move.Knockback.StartsAirCombo == true,
		}
	end
	if move.Grab then
		wire.Grab = {
			HoldSeconds = move.Grab.HoldSeconds,
			ThrowUpVelocity = move.Grab.ThrowUpVelocity,
			ThrowHorizontalVelocity = move.Grab.ThrowHorizontalVelocity,
			ThrowImpactDamage = move.Grab.ThrowImpactDamage,
			ThrowSelfDamage = move.Grab.ThrowSelfDamage,
		}
	end
	if move.Art then
		wire.Art = {
			TreeId = move.Art.TreeId,
			Node = move.Art.Node,
			QiCost = move.Art.QiCost,
			RequiredTier = move.Art.RequiredTier,
			Prerequisite = move.Art.Prerequisite,
		}
	end
	return wire
end

-- Builds the Offset CFrame from its translation and Euler degrees. Yaw first, then pitch, then roll:
-- "turn it to face this way, then tilt it" is what someone typing three angles means, and YXZ keeps yaw
-- independent of pitch where XYZ does not. Shared so the editor's preview and the server's Validate can
-- never compose the same six numbers into two different volumes.
function MoveTypes.ComposeOffset(position: Vector3, rotationDegrees: Vector3): CFrame
	return CFrame.new(position)
		* CFrame.fromEulerAnglesYXZ(
			math.rad(rotationDegrees.X),
			math.rad(rotationDegrees.Y),
			math.rad(rotationDegrees.Z)
		)
end

-- Dirty tracking --------------------------------------------------------------------------------------

local function digestNumber(value: number): string
	-- Six significant figures: three past the editor's display precision, well short of the float noise
	-- that would make two visually identical drafts digest differently.
	return string.format("%.6g", value)
end

-- Whether a table is a contiguous 1..n array, which is digested in index order rather than sorted-key
-- order (sorting "1", "2", "10" lexicographically would report a reorder as no change).
local function isArray(value: { [any]: unknown }): boolean
	local count = 0
	for _ in pairs(value) do
		count += 1
	end
	return count == #value
end

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
	elseif valueType == "table" then
		local source = value :: { [any]: unknown }
		table.insert(out, "{")
		if isArray(source) then
			for _, entry in ipairs(source :: { unknown }) do
				digestValue(out, entry)
			end
		else
			-- Sorted at every level: pairs order is unspecified, and two structurally identical tables
			-- built in a different order must digest identically.
			local keys: { string } = {}
			for key in pairs(source) do
				table.insert(keys, tostring(key))
			end
			table.sort(keys)
			for _, key in ipairs(keys) do
				table.insert(out, key .. "=")
				digestValue(out, (source :: any)[key])
			end
		end
		table.insert(out, "}")
	else
		table.insert(out, tostring(value))
	end
end

-- Exposed so Client/UI/Screens/DevTools/KitEditor/Types.lua fingerprints a kit draft with the same walk.
-- Only ever compared within one session, never persisted, so the algorithm has no stored format to keep.
function MoveTypes.DigestValue(out: { string }, value: unknown): ()
	digestValue(out, value)
end

-- A deterministic digest of every AUTHORED field -- "has this draft changed since it was loaded or
-- saved?" -- compared against one retained string per move rather than a second MoveDefinition.
--
-- Digests the wire encoding, which is by construction exactly the authored set: identity stamps
-- (Author/CreatedAt/UpdatedAt, re-stamped on every server round trip, which would mark every draft dirty
-- within one debounce) and projected-only fields are already absent from it. MoveId is removed as well
-- so a brand-new draft does not read as changed the moment the server assigns it an id.
function MoveTypes.Fingerprint(move: MoveDefinition): string
	local wire = MoveTypes.ToWire(move)
	wire.MoveId = nil
	local out: { string } = {}
	digestValue(out, wire)
	return table.concat(out)
end

-- The engine projection ----------------------------------------------------------------------------------

-- A move's hitbox is the same size at every combo stage and power level: nothing authors a growth curve,
-- and PowerLevel's job is guard drain (GuardMeter.DrainFor), not volume. One shared read-only table.
local FLAT_SCALING: HitboxTypes.ScalingProfile = table.freeze({
	ComboStageMultipliers = table.freeze({ 1 }),
	PowerMultiplierPerUnit = 0,
	MaxScaleMultiplier = 1,
	ChargeSeconds = 0,
	ChargedScaleMultiplier = 1,
}) :: any

-- The pair the combat stack runs on: the geometry HitboxEngine resolves, and the numbers the damage layer
-- applies. Lossless -- the schema is the engine's vocabulary, so there is nothing to approximate and
-- nothing to report. Pure: AttackCatalog owns resolving the id and retiming against the clip.
function MoveTypes.ToEngineAttackDefinition(move: MoveDefinition): (HitboxTypes.AttackDefinition, DamageProfile)
	local definition: HitboxTypes.AttackDefinition = {
		-- Always the MoveId: HitReport.DebugName is what the damage layer looks the attack back up by.
		DebugName = move.MoveId,
		Shape = move.Shape,
		BaseDimensions = table.clone(move.Dimensions),
		Scaling = FLAT_SCALING,
		Offset = move.Offset,
		AttachmentPart = move.AttachmentPart,
		WindupSeconds = move.WindupSeconds,
		ActiveSeconds = move.ActiveSeconds,
		RecoverySeconds = move.RecoverySeconds,
		MaxTargetsPerSwing = move.MaxTargets,
		LocksMovement = move.LocksMovement,
		-- A weapon-anchored swing IS the blade: a Box takes the equipped weapon's own part size (inert for
		-- every other shape -- the engine only reads it for Box).
		SizeFromAttachmentPart = move.AttachmentPart == "Weapon",
		SizeMultiplier = move.SizeMultiplier,
	}
	local profile: DamageProfile = {
		Damage = move.Damage,
		PostureDamage = move.PostureDamage,
		Knockback = move.Knockback,
		Grab = move.Grab,
	}
	return definition, profile
end

return MoveTypes
