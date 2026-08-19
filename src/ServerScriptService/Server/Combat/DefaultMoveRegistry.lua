--!strict
--[[
	DefaultMoveRegistry.lua

	Owns: LIVE, IN-MEMORY, full-field tuning of every hand-authored attack (both weapons' Basic/Heavy/
	Finisher stages, plus the standalone DashPunch/DashHit/AirSlam attacks) -- the Move Editor's
	"Default" moves. Formerly HitboxTuning.lua, which scoped this to timing (and, for standalones,
	forward offset) only; renamed and widened so every real HitboxAttackDefinition field an admin
	could plausibly want to hand-tune (Shape/Size/Radius/Offset/WindupSeconds/ActiveSeconds/
	RecoverySeconds/Cooldown/Damage/PostureDamage/ArcDegrees/MaxTargets) is reachable through the SAME
	Sidebar/PropertyEditor UI a hand-authored custom move uses (Client/UI/Screens/MoveEditor/), instead
	of the old DevMenu Tuning tab's narrow +-delta stepper rows. That old UI is gone; this module's own
	job -- mutate the real CombatConstants tables live, by reference -- is unchanged.

	A "Default" move is presented to the UI as a MoveTypes.MoveDefinition projection (synthetic MoveId,
	e.g. "default:Primary:Basic:1" / "default:DashPunch"; Category = "Default", the reserved sentinel
	documented in MoveTypes.lua's own header) purely so it can flow through the Move Editor's existing
	Sidebar/PropertyEditor/PreviewViewport components and MoveRegistryManager.Validate's clamping
	logic. It is NOT stored in MoveRegistryManager's own registry -- see this file's own List/
	ApplyEdit/Reset below, which read/write CombatConstants.Weapons[...].Stages/DashPunch/DashHit/
	AirSlam directly, by reference, exactly as this module's HitboxTuning.lua predecessor did.
	CombatSystem.lua's selectAttackDefinition/commitAndThrowAttack/handleDashRequest/
	handleAirSlamRequest and HitboxResolver.lua's Update all read those exact tables live, every
	Heartbeat/throw, with zero knowledge this module or the Move Editor even exist -- so a mutation
	here takes effect on the very next swing, and even on an already in-flight one (see the
	predecessor's own header for the one asymmetry worth knowing: CombatSystem's own commitment-lock
	fields ARE snapshotted as plain numbers at throw time, so a mid-swing edit changes when a hitbox
	samples/ends but not when the attacker can act again for that one already-thrown swing). UNLIKE
	its HitboxTuning.lua predecessor, an edit here CAN be made durable across a restart -- see
	MoveEditorSystem.lua's SaveDefaultMove/loadDefaultMoveOverrides for the DataStore-backed override
	record this module itself stays unaware of (ApplyEdit/Reset only ever touch the live
	CombatConstants tables; persistence is entirely MoveEditorSystem's concern, same ownership split as
	MoveRegistryManager/MoveEditorSystem's own custom-move Save).

	AnimationId is always "" on the returned projection and never written anywhere -- a Default move's
	animation is driven entirely by CombatAnimator.lua's existing DebugName-trailing-digit inference
	(Shared/CombatDebugNames.lua), never by MoveDefinition.AnimationId; DebugName itself is NEVER
	touched by ApplyEdit/Reset, only the fields listed above. Movement/Knockback/Grab/Projectile stay
	nil on every projection -- those four sub-tables are consumed ONLY by the rebuilt combat stack's own
	custom-move path (a live CombatConstants.Weapons stage has no field for any of them), so they'd be
	silently inert for a Default move; the Move Editor UI hides those nav sections entirely for
	Category == "Default" rather than exposing dead controls.

	Captures every attack's ORIGINAL mutable-field values once, lazily, the first time any public
	function here runs (guaranteed to be well after CombatConstants.lua has fully loaded, and -- now
	that MoveEditorSystem.lua's loadDefaultMoveOverrides calls List() before applying any saved
	override -- guaranteed to run BEFORE an override is ever applied, so a captured default is always
	the true CombatConstants.lua file value, never a previously-persisted override) so Reset can restore known-good
	values without a full Studio restart. Reset always reverts to THIS captured value and nothing else
	-- MoveEditorSystem.lua's own ResetDefaultMove handler is responsible for also clearing that move's
	DataStore override record, so a Reset a fresh boot won't silently re-apply.

	Does not own: authorization or rate-limiting (MoveEditorSystem.lua's job, identical to every other
	admin action), or deciding what a "reasonable" value is beyond basic sanity clamping -- ApplyEdit
	delegates that entirely to MoveRegistryManager.Validate, the same allow-list/clamp gate a
	hand-authored custom move's UpdateDraft/SaveMove already passes through, rather than duplicating a
	second copy of the same clamp table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Types = require(ReplicatedStorage.Shared.Types)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)

local MoveRegistryManager = require(script.Parent.MoveRegistryManager)

local DefaultMoveRegistry = {}

-- Local, not a Shared/Types.lua export -- these two closed unions (StandaloneName here,
-- WeaponStageCategory below) existed as Types.StandaloneAttackName/Types.HitboxStageCategory only
-- for this module's predecessor and DevMenuSystem.lua's now-removed handlers; keeping them alive in
-- Shared/Types.lua purely for this module's own internal enumeration isn't worth the cross-module
-- dependency.
type StandaloneName = "DashPunch" | "DashHit" | "AirSlam"
local STANDALONE_ATTACK_NAMES: { StandaloneName } = { "DashPunch", "DashHit", "AirSlam" }

-- "Finisher" is a single stage (not an array), addressed with stageIndex 0 -- see
-- weaponStageMoveId/enumerateDescriptors below, mirroring HitboxTuning.lua's own resolveStageTable
-- sentinel convention.
type WeaponStageCategory = "Basic" | "Heavy" | "Finisher"

-- One entry per live-tunable attack -- Definition is the LIVE Constants table object (by reference,
-- never copied), MoveId/DisplayName are derived purely from this attack's fixed position in the
-- (weaponId, category, stageIndex)/standalone-name scheme below, never stored or read back from
-- anywhere mutable. The descriptor LIST is cached (see enumerateDescriptors) once this module's
-- structural shape (which Stages arrays exist, how many entries each has) is established at boot --
-- each Definition entry is still the live Constants table BY REFERENCE, and ApplyEdit/Reset always
-- mutate that referenced table in place (applySnapshot never replaces it), so a cached descriptor's
-- Definition is always resolved against whatever Constants.lua actually holds right now regardless of
-- when the list itself was built.
type Descriptor = {
	MoveId: string,
	DisplayName: string,
	Definition: Types.HitboxAttackDefinition,
}

local function weaponStageMoveId(weaponId: Types.WeaponId, category: WeaponStageCategory, stageIndex: number): string
	if category == "Finisher" then
		return "default:" .. weaponId .. ":Finisher"
	end
	return "default:" .. weaponId .. ":" .. category .. ":" .. tostring(stageIndex)
end

local function weaponStageDisplayName(
	weaponId: Types.WeaponId,
	category: WeaponStageCategory,
	stageIndex: number
): string
	if category == "Finisher" then
		return weaponId .. " Finisher"
	end
	return weaponId .. " " .. category .. " " .. tostring(stageIndex)
end

local function standaloneMoveId(name: StandaloneName): string
	return "default:" .. name
end

local function resolveStandaloneDefinition(name: StandaloneName): Types.HitboxAttackDefinition
	if name == "DashPunch" then
		return CombatConstants.DashPunch
	elseif name == "DashHit" then
		return CombatConstants.DashHit
	end
	return CombatConstants.AirSlam
end

-- Every tunable attack, in a stable display order (Primary before Secondary, Basic before Heavy
-- before Finisher, array order within each, then DashPunch/DashHit/AirSlam) -- the one enumeration
-- every other function in this module (capture, resolve, list) is built from, so the order can never
-- drift between them.
--
-- Cached after the first build: this used to be rebuilt from scratch on every call on the theory that
-- a couple dozen entries is cheap, back when the only caller was an admin UI. It is now also the inner
-- loop of AttackCatalog.Get (findDescriptor scans this list), called per landed hit and per buffered
-- input replay every Heartbeat -- see AttackCatalog.lua's own header for that path. Caching is safe
-- because the list's SHAPE (which MoveIds exist, which live Constants table each one points at) is
-- fixed at boot -- CombatConstants.Weapons.*.Stages arrays are never resized or replaced at runtime,
-- only mutated in place (see Descriptor's own header) -- so nothing here ever needs invalidating.
local cachedDescriptors: { Descriptor }? = nil

local function enumerateDescriptors(): { Descriptor }
	if cachedDescriptors then
		return cachedDescriptors
	end
	local result: { Descriptor } = {}
	for _, weaponId in ipairs({ "Primary", "Secondary" } :: { Types.WeaponId }) do
		local weapon = if weaponId == "Primary"
			then CombatConstants.Weapons.Primary
			else CombatConstants.Weapons.Secondary
		for index, definition in ipairs(weapon.Stages.Basic) do
			table.insert(result, {
				MoveId = weaponStageMoveId(weaponId, "Basic", index),
				DisplayName = weaponStageDisplayName(weaponId, "Basic", index),
				Definition = definition,
			})
		end
		for index, definition in ipairs(weapon.Stages.Heavy) do
			table.insert(result, {
				MoveId = weaponStageMoveId(weaponId, "Heavy", index),
				DisplayName = weaponStageDisplayName(weaponId, "Heavy", index),
				Definition = definition,
			})
		end
		-- Finisher is a single stage, not an array -- stageIndex 0 marks it, mirroring the sentinel
		-- HitboxTuning.lua's own resolveStageTable used to interpret.
		table.insert(result, {
			MoveId = weaponStageMoveId(weaponId, "Finisher", 0),
			DisplayName = weaponStageDisplayName(weaponId, "Finisher", 0),
			Definition = weapon.Stages.Finisher,
		})
	end
	for _, name in ipairs(STANDALONE_ATTACK_NAMES) do
		table.insert(result, {
			MoveId = standaloneMoveId(name),
			DisplayName = name,
			Definition = resolveStandaloneDefinition(name),
		})
	end
	cachedDescriptors = result
	return result
end

local function findDescriptor(moveId: string): Descriptor?
	for _, descriptor in ipairs(enumerateDescriptors()) do
		if descriptor.MoveId == moveId then
			return descriptor
		end
	end
	return nil
end

-- The 13 fields this module actually reads/writes -- everything else on a Default move's projection
-- (MoveId/DisplayName/Category/Author/CreatedAt/UpdatedAt/AnimationId/Animations/Movement/Knockback/
-- Projectile/ObjectStun) is either derived fresh every call or permanently nil/empty -- see this
-- file's own header.
--
-- Dimensions joined the list when the Move Editor gained its twelve-shape vocabulary: a hand-authored
-- Constants attack has none (it's Box-shaped, described by Size), but an admin retuning one INTO a
-- Cone or an Arc needs somewhere for those measurements to live on the live table, and
-- HitboxResolver reads exactly this field for any non-Box/Sphere shape. Writing nil back on Reset is
-- therefore what actually restores the original Box.
type MutableSnapshot = {
	Shape: Types.HitboxShapeId?,
	Size: Vector3?,
	Radius: number?,
	Dimensions: Types.HitboxDimensions?,
	Offset: CFrame,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	Cooldown: number,
	Damage: number,
	PostureDamage: number,
	ArcDegrees: number?,
	MaxTargets: number?,
}

local function snapshotOf(definition: Types.HitboxAttackDefinition): MutableSnapshot
	return {
		Shape = definition.Shape,
		Size = definition.Size,
		Radius = definition.Radius,
		Dimensions = definition.Dimensions,
		Offset = definition.Offset,
		WindupSeconds = definition.WindupSeconds,
		ActiveSeconds = definition.ActiveSeconds,
		RecoverySeconds = definition.RecoverySeconds,
		Cooldown = definition.Cooldown,
		Damage = definition.Damage,
		PostureDamage = definition.PostureDamage,
		ArcDegrees = definition.ArcDegrees,
		MaxTargets = definition.MaxTargets,
	}
end

local function applySnapshot(definition: Types.HitboxAttackDefinition, snapshot: MutableSnapshot): ()
	definition.Shape = snapshot.Shape
	definition.Size = snapshot.Size
	definition.Radius = snapshot.Radius
	definition.Dimensions = snapshot.Dimensions
	definition.Offset = snapshot.Offset
	definition.WindupSeconds = snapshot.WindupSeconds
	definition.ActiveSeconds = snapshot.ActiveSeconds
	definition.RecoverySeconds = snapshot.RecoverySeconds
	definition.Cooldown = snapshot.Cooldown
	definition.Damage = snapshot.Damage
	definition.PostureDamage = snapshot.PostureDamage
	definition.ArcDegrees = snapshot.ArcDegrees
	definition.MaxTargets = snapshot.MaxTargets
end

-- Original mutable-field values per MoveId, captured once (see ensureDefaultsCaptured) so Reset can
-- restore them -- see this file's header for why no other persistence exists.
local defaultsByMoveId: { [string]: MutableSnapshot } = {}
local capturedOnce = false

-- The authored Offset ROTATION, in degrees, per MoveId -- kept here rather than on the live
-- Types.HitboxAttackDefinition because that struct only carries the composed Offset CFrame, and
-- recovering three clean Euler angles back out of a matrix is lossy at the poles (the same reason
-- MoveDefinition.OffsetRotation exists alongside MoveDefinition.Offset at all). Absent means zero,
-- which is correct for every hand-authored Constants attack -- all of their Offsets are pure
-- translations -- so Reset simply clears the entry.
local rotationByMoveId: { [string]: Vector3 } = {}

local function ensureDefaultsCaptured(): ()
	if capturedOnce then
		return
	end
	capturedOnce = true
	for _, descriptor in ipairs(enumerateDescriptors()) do
		defaultsByMoveId[descriptor.MoveId] = snapshotOf(descriptor.Definition)
	end
end

-- Projects a live HitboxAttackDefinition into the MoveTypes.MoveDefinition shape the Move Editor UI
-- consumes -- see this file's header for why AnimationId/Movement/Knockback/Projectile are always
-- "" / nil regardless of the live definition's own (always-nil, for a hand-authored attack) state.
local function toMoveDefinition(
	moveId: string,
	displayName: string,
	definition: Types.HitboxAttackDefinition
): MoveTypes.MoveDefinition
	-- Box is the implicit default for a hand-authored Constants.lua definition -- see
	-- Types.HitboxAttackDefinition.Shape's own comment, mirrored here rather than leaving Shape
	-- nil on the projection (MoveDefinition.Shape is non-optional).
	local shape: Types.HitboxShapeId = definition.Shape or "Box"

	-- Same v1 -> v2 geometry bridge MoveRegistryManager.Validate does for a stored custom move: use
	-- the live Dimensions if an admin has already retuned this attack into one of the new shapes,
	-- otherwise reconstruct the Box/Sphere measurements from the Size/Radius the Constants table
	-- actually holds, so the editor opens showing the attack's REAL dimensions rather than this
	-- shape's generic defaults.
	local dimensions: MoveTypes.MoveDimensions
	if definition.Dimensions then
		dimensions = HitboxShapes.Sanitize(shape, definition.Dimensions)
	elseif definition.Size then
		local size = definition.Size :: Vector3
		dimensions = HitboxShapes.Sanitize(shape, { Width = size.X, Height = size.Y, Depth = size.Z })
	elseif definition.Radius then
		dimensions = HitboxShapes.Sanitize(shape, { Radius = definition.Radius })
	else
		dimensions = HitboxShapes.DefaultDimensions(shape)
	end

	return {
		MoveId = moveId,
		DisplayName = displayName,
		Category = MoveTypes.DefaultCategory,
		Author = "System",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = shape,
		Dimensions = dimensions,
		Size = definition.Size,
		Radius = definition.Radius,
		Offset = definition.Offset,
		OffsetRotation = rotationByMoveId[moveId] or Vector3.zero,
		WindupSeconds = definition.WindupSeconds,
		ActiveSeconds = definition.ActiveSeconds,
		RecoverySeconds = definition.RecoverySeconds,
		Cooldown = definition.Cooldown,
		Damage = definition.Damage,
		PostureDamage = definition.PostureDamage,
		ArcDegrees = definition.ArcDegrees,
		MaxTargets = definition.MaxTargets,
		AnimationId = "",
		-- Always empty, never populated: a Default move's animation comes entirely from
		-- CombatAnimator's DebugName inference, so an authored timeline would be silently inert --
		-- the same reasoning that keeps AnimationId "" here. The editor hides the Animation section
		-- for Category == "Default" rather than exposing controls that do nothing.
		Animations = {},
		Movement = nil,
		Knockback = nil,
		-- Same "consumed only by the Move Creation System's own throw path" reasoning as
		-- Movement/Knockback/Projectile above -- a Default move's live Constants table has no field for
		-- this either, so it would be silently inert. See MoveTypes.lua's own header.
		Grab = nil,
		Projectile = nil,
		ObjectStun = nil,
	}
end

-- Every Default move as a MoveDefinition projection, in the stable order enumerateDescriptors
-- establishes -- MoveEditorSystem.ListDefaultMoves' entire job is forwarding this.
function DefaultMoveRegistry.List(): { MoveTypes.MoveDefinition }
	ensureDefaultsCaptured()
	local result: { MoveTypes.MoveDefinition } = {}
	for _, descriptor in ipairs(enumerateDescriptors()) do
		table.insert(result, toMoveDefinition(descriptor.MoveId, descriptor.DisplayName, descriptor.Definition))
	end
	return result
end

function DefaultMoveRegistry.Get(moveId: string): MoveTypes.MoveDefinition?
	ensureDefaultsCaptured()
	local descriptor = findDescriptor(moveId)
	if not descriptor then
		return nil
	end
	return toMoveDefinition(descriptor.MoveId, descriptor.DisplayName, descriptor.Definition)
end

-- Validates `candidate` through MoveRegistryManager.Validate (the SAME allow-list/clamp gate a
-- hand-authored custom move's UpdateDraft/SaveMove already passes through -- the wire shape is
-- identical, see that function's own header for the OffsetX/Y/Z decomposition it expects), then
-- writes ONLY the 12 mutable fields listed in this file's header back onto the LIVE
-- Types.HitboxAttackDefinition table BY REFERENCE (never replacing the table object itself, same
-- mutation style as this module's HitboxTuning.lua predecessor) -- `moveId` (not whatever MoveId the
-- candidate itself carries) is the sole authority for WHICH live table gets mutated, the same "server
-- owns identity" boundary MoveEditorSystem.stampTrustedMetadata enforces for a custom move. DebugName
-- is never touched. Returns the refreshed projection, or (nil, reason) on an invalid moveId/candidate.
function DefaultMoveRegistry.ApplyEdit(moveId: string, candidate: unknown): (MoveTypes.MoveDefinition?, string?)
	ensureDefaultsCaptured()
	local descriptor = findDescriptor(moveId)
	if not descriptor then
		return nil, "InvalidMoveId"
	end
	-- allowReservedCategory = true: this candidate IS a Default move and legitimately carries the
	-- reserved sentinel Category (the client round-trips the whole draft back, sentinel included).
	-- Every client-authored path leaves that parameter false -- see Validate's own header.
	local validated, reason = MoveRegistryManager.Validate(candidate, true)
	if not validated then
		return nil, reason
	end
	rotationByMoveId[moveId] = validated.OffsetRotation
	applySnapshot(descriptor.Definition, {
		Shape = validated.Shape,
		Size = validated.Size,
		Radius = validated.Radius,
		-- Only meaningful for the ten shapes HitboxResolver resolves through Dimensions -- Box and
		-- Sphere keep using the derived Size/Radius above and their original exact query, so writing
		-- Dimensions for them would be dead weight on the live Constants table.
		Dimensions = if validated.Shape == "Box" or validated.Shape == "Sphere" then nil else validated.Dimensions,
		Offset = validated.Offset,
		WindupSeconds = validated.WindupSeconds,
		ActiveSeconds = validated.ActiveSeconds,
		RecoverySeconds = validated.RecoverySeconds,
		Cooldown = validated.Cooldown,
		Damage = validated.Damage,
		PostureDamage = validated.PostureDamage,
		ArcDegrees = validated.ArcDegrees,
		MaxTargets = validated.MaxTargets,
	})
	return toMoveDefinition(descriptor.MoveId, descriptor.DisplayName, descriptor.Definition), nil
end

-- Restores ONE Default move's 12 mutable fields to their captured file defaults. Returns the restored
-- projection, or nil for an unknown moveId.
function DefaultMoveRegistry.Reset(moveId: string): MoveTypes.MoveDefinition?
	ensureDefaultsCaptured()
	local descriptor = findDescriptor(moveId)
	if not descriptor then
		return nil
	end
	local defaults = defaultsByMoveId[moveId]
	if not defaults then
		return nil
	end
	-- Clearing the entry is what restores "no rotation" -- see rotationByMoveId's own header for why
	-- absent, not zero, is the stored representation of an untouched attack.
	rotationByMoveId[moveId] = nil
	applySnapshot(descriptor.Definition, defaults)
	return toMoveDefinition(descriptor.MoveId, descriptor.DisplayName, descriptor.Definition)
end

return DefaultMoveRegistry
