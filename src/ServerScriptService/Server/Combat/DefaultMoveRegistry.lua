--!strict
--[[
	DefaultMoveRegistry.lua

	Owns: every move the game ships with rather than an admin authored -- each roster weapon's Basic/
	Heavy/Finisher stages and air-combo moves, plus the standalone DashPunch/DashHit -- presented as
	MoveTypes.MoveDefinitions, and the OVERRIDE LAYER the Move Editor tunes them through.

	PROJECTION PLUS OVERRIDE, NOT MUTATION (2026-09-29). This module used to retune a Default move by
	writing into the live CombatConstants / WeaponRoster stage table by reference, capture every table's
	original values at boot so Reset had something to restore, and keep a side table of rotations because
	the stage table had nowhere to put them. Every read then re-projected that mutated table. It worked,
	but it made the stage tables two things at once -- authored constants AND mutable editor state -- and
	it is why the old stage type grew a twelve-shape Dimensions bag nothing hand-authored ever used.

	Now the stage tables are never written. A Default move is:

	    built projection (fresh from the weapon-built stage table)  +  optional override (editor-owned)

	Get returns the two composed; Reset forgets the override and the move is its built self again, with
	nothing to restore because nothing was changed. The override holds exactly the fields an admin may
	retune (OVERRIDABLE below) and is itself a validated MoveDefinition's worth of values.

	WHAT A DEFAULT MOVE MAY NOT CHANGE, and why: its id and name (fixed by its place in the roster), its
	anchor, clip and projected weapon fields (properties of the weapon, not the stage), its weight class
	and feintability (properties of the stage -- MoveTypes.PowerLevelByStage/FeintableByStage), and
	Knockback/Grab/Art (a stage has none, and the damage layer applies a weapon string's launch through
	its own constants).

	Persistence is MoveEditorSystem's: it writes an override record per move and replays it through
	ApplyEdit at boot. This module is memory-only, like MoveRegistryManager.

	ORDERING DEPENDENCY: WeaponRoster.Start() must have run before the first call here, or the roster is
	empty and the cached descriptor list has no weapon moves in it. Main.server boots it before the combat
	stack for exactly that reason.

	Does not own: authorization or persistence (MoveEditorSystem), the clamp rules (MoveRegistryManager
	.Validate, which every override passes through), or resolving a MoveId across custom and Default
	moves (AttackCatalog).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)

local MoveRegistryManager = require(script.Parent.MoveRegistryManager)

local DefaultMoveRegistry = {}

-- The browser group every standalone attack files under.
DefaultMoveRegistry.StandaloneGroup = "Standalone"

type StageCategory = "Basic" | "Heavy" | "Finisher" | "Launcher" | "Air" | "AirFinisher"

type Descriptor = {
	MoveId: string,
	DisplayName: string,
	-- The weapon-built stage table, read on every projection and never written.
	Definition: Types.HitboxAttackDefinition,
	-- "Weapon" for a stage of a Blade-mode weapon, "Root" for the body box and for standalones -- see
	-- weaponAnchor below.
	AttachmentPart: MoveTypes.MoveAttachmentPoint,
	-- Properties of the WEAPON this stage belongs to, nil for a standalone.
	SpawnDelaySeconds: number?,
	WeaponSpeed: number?,
	WeaponId: Types.WeaponId?,
	Stage: StageCategory?,
}

-- The fields an override may carry -- see this file's header for everything else.
export type Override = {
	Shape: MoveTypes.MoveShape,
	Dimensions: MoveTypes.MoveDimensions,
	Offset: CFrame,
	OffsetRotation: Vector3,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	Cooldown: number,
	Damage: number,
	PostureDamage: number,
	MaxTargets: number?,
}

-- The descriptor list and its index, built once. Safe to cache for the session: the roster is built at
-- boot and never resized, and a descriptor's Definition is a reference to a table that is never replaced.
local cachedDescriptors: { Descriptor }? = nil
local descriptorById: { [string]: Descriptor } = {}

local overrides: { [string]: Override } = {}

-- A Blade-mode weapon's swings are anchored to the weapon (and a Box takes the blade's size); a BodyBox
-- weapon swings a root-anchored box. Read per weapon, so a roster can mix the two.
local function weaponAnchor(weaponId: Types.WeaponId): MoveTypes.MoveAttachmentPoint
	return if WeaponRoster.SwingHitbox(weaponId).Mode == "Blade" then "Weapon" else "Root"
end

local function enumerateDescriptors(): { Descriptor }
	if cachedDescriptors then
		return cachedDescriptors
	end
	local result: { Descriptor } = {}

	for _, weaponId in WeaponRoster.Order() do
		local weapon = WeaponRoster.Get(weaponId)
		if not weapon then
			continue
		end
		local anchor = weaponAnchor(weaponId)
		local spawnDelay = WeaponRoster.SwingHitbox(weaponId).SpawnDelaySeconds
		local speed = WeaponRoster.Speed(weaponId)
		local function add(
			moveId: string,
			displayName: string,
			definition: Types.HitboxAttackDefinition,
			stage: StageCategory
		)
			table.insert(result, {
				MoveId = moveId,
				DisplayName = displayName,
				Definition = definition,
				AttachmentPart = anchor,
				SpawnDelaySeconds = spawnDelay,
				WeaponSpeed = speed,
				WeaponId = weaponId,
				Stage = stage,
			})
		end

		for index, definition in ipairs(weapon.Stages.Basic) do
			add(`default:{weaponId}:Basic:{index}`, `{weaponId} Basic {index}`, definition, "Basic")
		end
		for index, definition in ipairs(weapon.Stages.Heavy) do
			add(`default:{weaponId}:Heavy:{index}`, `{weaponId} Heavy {index}`, definition, "Heavy")
		end
		add(`default:{weaponId}:Finisher`, `{weaponId} Finisher`, weapon.Stages.Finisher, "Finisher")
		-- The air combo's ids are AirComboMoves', the one definition SwingSequencer resolves against.
		add(AirComboMoves.LauncherId(weaponId), `{weaponId} Launcher`, weapon.Stages.Launcher, "Launcher")
		for beat, definition in ipairs(weapon.Stages.Air) do
			add(AirComboMoves.AirId(weaponId, beat), `{weaponId} Air {beat}`, definition, "Air")
		end
		for _, kind in AirComboMoves.FinisherKinds do
			add(
				AirComboMoves.FinisherId(weaponId, kind),
				`{weaponId} Air {kind}`,
				weapon.Stages.AirFinisher[kind],
				"AirFinisher"
			)
		end
	end

	-- Fist/body attacks: no weapon, so no weapon anchor, spawn delay or speed.
	table.insert(result, {
		MoveId = "default:DashPunch",
		DisplayName = "DashPunch",
		Definition = CombatConstants.DashPunch,
		AttachmentPart = "Root",
	})
	table.insert(result, {
		MoveId = "default:DashHit",
		DisplayName = "DashHit",
		Definition = CombatConstants.DashHit,
		AttachmentPart = "Root",
	})

	table.clear(descriptorById)
	for _, descriptor in ipairs(result) do
		descriptorById[descriptor.MoveId] = descriptor
	end
	cachedDescriptors = result
	return result
end

local function findDescriptor(moveId: string): Descriptor?
	enumerateDescriptors()
	return descriptorById[moveId]
end

-- The move as the weapon built it. A hand-authored stage is a Box described by its Size (see
-- Types.HitboxAttackDefinition); the dimensions the Box does not read keep the engine's defaults so the
-- bag is always fully populated.
local function project(descriptor: Descriptor): MoveTypes.MoveDefinition
	local definition = descriptor.Definition
	local dimensions = HitboxTypes.DefaultDimensions()
	dimensions.Width = definition.Size.X
	dimensions.Height = definition.Size.Y
	dimensions.Length = definition.Size.Z

	local stage = descriptor.Stage
	return {
		MoveId = descriptor.MoveId,
		DisplayName = descriptor.DisplayName,
		Description = "",
		Category = "",
		Author = "System",
		CreatedAt = 0,
		UpdatedAt = 0,

		Shape = "Box",
		Dimensions = dimensions,
		-- A stage's Offset is a pure translation; its rotation is therefore zero.
		Offset = definition.Offset,
		OffsetRotation = Vector3.zero,
		AttachmentPart = descriptor.AttachmentPart,
		LocksMovement = false,

		WindupSeconds = definition.WindupSeconds,
		ActiveSeconds = definition.ActiveSeconds,
		RecoverySeconds = definition.RecoverySeconds,
		Cooldown = definition.Cooldown,

		Damage = definition.Damage,
		PostureDamage = definition.PostureDamage,
		MaxTargets = definition.MaxTargets,
		-- By stage, never authored. A standalone takes the Basic weight and is never feintable.
		PowerLevel = MoveTypes.PowerLevelByStage[stage or "Basic"],
		Feintable = if stage then MoveTypes.FeintableByStage[stage] == true else false,

		-- Always blank: a Default move's clip is Shared/Attack/AttackAnimations', resolved by AttackCatalog.
		AnimationId = "",

		SizeMultiplier = definition.SizeMultiplier,
		SpawnDelaySeconds = descriptor.SpawnDelaySeconds,
		WeaponSpeed = descriptor.WeaponSpeed,
		-- The string's pace (AttackConstants.Tempo), read at projection time so a tempo edit is never
		-- shadowed by the cached descriptor. A standalone is not a link in a string and keeps 1.
		Tempo = if stage then AttackConstants.TempoFor(descriptor.WeaponId, stage) else nil,
	}
end

local function applyOverride(move: MoveTypes.MoveDefinition, override: Override): ()
	move.Shape = override.Shape
	move.Dimensions = table.clone(override.Dimensions)
	move.Offset = override.Offset
	move.OffsetRotation = override.OffsetRotation
	move.WindupSeconds = override.WindupSeconds
	move.ActiveSeconds = override.ActiveSeconds
	move.RecoverySeconds = override.RecoverySeconds
	move.Cooldown = override.Cooldown
	move.Damage = override.Damage
	move.PostureDamage = override.PostureDamage
	move.MaxTargets = override.MaxTargets
end

local function resolve(descriptor: Descriptor): MoveTypes.MoveDefinition
	local move = project(descriptor)
	local override = overrides[descriptor.MoveId]
	if override then
		applyOverride(move, override)
	end
	return move
end

-- Every Default move, overrides applied, in roster order (weapon, then Basic -> Heavy -> Finisher ->
-- air, then the standalones).
function DefaultMoveRegistry.List(): { MoveTypes.MoveDefinition }
	local result: { MoveTypes.MoveDefinition } = {}
	for _, descriptor in ipairs(enumerateDescriptors()) do
		table.insert(result, resolve(descriptor))
	end
	return result
end

-- The move as combat will throw it -- override applied. A fresh table every call; the caller may keep it.
function DefaultMoveRegistry.Get(moveId: string): MoveTypes.MoveDefinition?
	local descriptor = findDescriptor(moveId)
	return if descriptor then resolve(descriptor) else nil
end

-- The move as its weapon built it, ignoring any override -- what Reset returns to.
function DefaultMoveRegistry.GetBuilt(moveId: string): MoveTypes.MoveDefinition?
	local descriptor = findDescriptor(moveId)
	return if descriptor then project(descriptor) else nil
end

function DefaultMoveRegistry.IsOverridden(moveId: string): boolean
	return overrides[moveId] ~= nil
end

-- The browser group for a Default move: its weapon id, or StandaloneGroup. nil for an unknown id.
function DefaultMoveRegistry.GroupOf(moveId: string): string?
	local descriptor = findDescriptor(moveId)
	if not descriptor then
		return nil
	end
	return descriptor.WeaponId or DefaultMoveRegistry.StandaloneGroup
end

-- Validates a wire-shaped candidate and installs the overridable part of it. Identity comes from the
-- move itself, never the candidate -- `moveId` alone decides which move is tuned, whatever MoveId,
-- name or author the payload claims. Returns the resolved move, or (nil, reason).
function DefaultMoveRegistry.ApplyEdit(moveId: string, candidate: unknown): (MoveTypes.MoveDefinition?, string?)
	local descriptor = findDescriptor(moveId)
	if not descriptor then
		return nil, "MoveNotFound"
	end
	if typeof(candidate) ~= "table" then
		return nil, "InvalidShape"
	end
	local stamped = table.clone(candidate :: { [string]: unknown })
	stamped.MoveId = moveId
	stamped.DisplayName = descriptor.DisplayName
	stamped.Author = "System"
	stamped.CreatedAt = 0
	stamped.UpdatedAt = 0
	-- Not a Default move's to change, so not the candidate's to smuggle in either: Validate would accept
	-- them, and applyOverride would then silently drop them, which is worse than never reading them.
	stamped.AttachmentPart = descriptor.AttachmentPart
	stamped.Knockback = nil
	stamped.Grab = nil
	stamped.Art = nil

	local validated, reason = MoveRegistryManager.Validate(stamped)
	if not validated then
		return nil, reason
	end
	overrides[moveId] = {
		Shape = validated.Shape,
		Dimensions = validated.Dimensions,
		Offset = validated.Offset,
		OffsetRotation = validated.OffsetRotation,
		WindupSeconds = validated.WindupSeconds,
		ActiveSeconds = validated.ActiveSeconds,
		RecoverySeconds = validated.RecoverySeconds,
		Cooldown = validated.Cooldown,
		Damage = validated.Damage,
		PostureDamage = validated.PostureDamage,
		MaxTargets = validated.MaxTargets,
	}
	return resolve(descriptor), nil
end

-- Forgets the override. Returns the move as built, or nil for an unknown id.
function DefaultMoveRegistry.Reset(moveId: string): MoveTypes.MoveDefinition?
	local descriptor = findDescriptor(moveId)
	if not descriptor then
		return nil
	end
	overrides[moveId] = nil
	return project(descriptor)
end

-- Spec-only: drops the cached descriptor list (built from whichever roster a previous case stood up) and
-- every override. Production never needs it -- the roster is fixed at boot.
function DefaultMoveRegistry.ResetCache(): ()
	cachedDescriptors = nil
	table.clear(descriptorById)
	table.clear(overrides)
end

return DefaultMoveRegistry
