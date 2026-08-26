--!strict
--[[
	WeaponRoster.lua

	Owns: WHICH WEAPONS EXIST, and what each one hits for. One entry per model in Workspace.Weapons --
	the id is that model's own Name ("Cutlass", "Flambert", ...) -- each carrying its own full set of
	Basic/Heavy/Finisher hitbox definitions, built at boot and thereafter owned by this module.

	A PLAYER HOLDS EXACTLY ONE OF THESE AT A TIME. SwingSequencer keeps that one id per combatant and
	swaps through Order() below; every swing resolves against the stages of whichever weapon is in
	hand. There is no dual-wield, no per-slot loadout, and no "Primary/Secondary" pair any more -- that
	closed two-weapon union is exactly what this module replaced (see Types.WeaponId's own header).

	ADDING A WEAPON IS A STUDIO ACTION, NOT A CODE CHANGE -- the entire point:

	  1. Put the model in Workspace.Weapons. Its Name is its weapon id, shown in-game and used
	     everywhere. Shared/Combat/WeaponModelRegistry.lua reads the SAME folder for the equippable
	     Tool, so one model feeds both the look and the numbers.
	  2. Optionally set any of the Attributes in ATTRIBUTE_NAMES below on that model to make it hit
	     differently from the house default -- Damage, PostureDamage, Reach, Speed. Set none and it
	     fights exactly like the baseline sword, which is a real answer for a reskin.
	  3. Optionally give it a "<Name>HitboxValues" child carrying the Attributes in
	     HITBOX_ATTRIBUTE_NAMES -- Mode, Size, Offset, ScaleWithWeaponReach, SpawnDelay -- to shape its
	     swing volume. Unlike step 2's four, these are absolute rather than multipliers, and they may
	     equally sit on the model itself. Set none and it swings the house box.
	  4. That is all. It appears in the swap cycle at next boot.

	WHY ATTRIBUTES RATHER THAN A LUA TABLE PER WEAPON: the same reason Shared/Blimp/BlimpConstants.lua
	puts per-hull tuning on the Model. Whoever builds the sword is the person who knows how heavy it
	should feel, and they are already in Studio with it selected -- making them open a Luau file (and
	making every new weapon a diff) is how a roster stops growing. The house defaults live in
	CombatConstants.Weapons.Baseline, so an unattributed weapon is never undefined, just ordinary.

	SCALED FROM ONE BASELINE, NOT AUTHORED PER WEAPON. Every weapon's stages start as a deep copy of
	CombatConstants.Weapons.Baseline.Stages -- the playtest-confirmed timings (see that table's own
	WindupSeconds comments) -- and the four Attributes then scale them: Damage/PostureDamage scale the
	per-hit numbers, Reach scales hitbox Size/Offset, Speed divides every Windup/Active/Recovery/
	Cooldown. DEEP copies, so tuning one weapon in the Move Editor can never move another's numbers,
	and so the baseline itself is never mutated by a weapon that scales off it.

	Does not own: the equippable Tool (WeaponModelRegistry -- same folder, different question), which
	weapon a given combatant currently holds (SwingSequencer's per-model record), or the MoveIds the
	stages get registered under (Server/Combat/DefaultMoveRegistry.lua enumerates this roster to build
	them).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponAssets = require(ReplicatedStorage.Shared.Combat.WeaponAssets)

type WeaponId = Types.WeaponId
type HitboxAttackDefinition = Types.HitboxAttackDefinition

local logger = Logger.scope("WeaponRoster")

local WeaponRoster = {}

-- The one fixed folder -- the same one WeaponModelRegistry reads, deliberately: a weapon is ONE model
-- that answers both "what does it look like" and "what does it hit for".

-- The name (or name SUFFIX -- see findHitboxValues) of the object a weapon hangs its hitbox
-- Attributes on. Any ClassName works; the shipped Cutlass uses a StringValue purely because it is the
-- cheapest thing in the insert menu that holds Attributes. Nothing ever reads its Value.
local HITBOX_VALUES_NAME = "HitboxValues"

-- Sanity bounds for the hitbox Attributes, mirroring HitboxTypes.FIELD_BOUNDS so a value clamped here
-- is one the engine's own sanitiser would have clamped a beat later anyway -- doing it at this end is
-- what lets the warning name the WEAPON that carries the typo. Generous on purpose: this is a "no NaN,
-- no negative, nothing absurd" guard, not a balance pass.
local MIN_SIZE_STUDS = 0.1
local MAX_SIZE_STUDS = 512
local MAX_OFFSET_STUDS = 512

-- Two seconds is already longer than any full swing timeline in the game (the slowest, Heavy, totals
-- ~1.37s), so a SpawnDelay past it is a typo -- someone entering milliseconds, most likely. Clamped
-- rather than rejected: a swing that comes out late is diagnosable, one that silently ignored the
-- delay entirely is not.
local MAX_SPAWN_DELAY_SECONDS = 2

-- Every per-weapon knob, and the whole vocabulary a builder needs. All four are multipliers against
-- CombatConstants.Weapons.Baseline (1 = exactly the baseline), so they read the same way regardless of
-- what the baseline's absolute numbers are retuned to later.
local ATTRIBUTE_NAMES = {
	-- Scales Damage on every stage. A heavy, slow weapon earns its tempo back here.
	Damage = "WeaponDamage",
	-- Scales PostureDamage on every stage -- how fast this weapon breaks a guard, independently of how
	-- much health it takes. Separate from Damage because "chips guard hard, hurts little" is a real
	-- weapon identity (CombatConstants' own Secondary was tuned exactly that way).
	PostureDamage = "WeaponPostureDamage",
	-- Scales hitbox Size and its paired Offset together, so a longer weapon reaches further without
	-- its box drifting off the swing -- see applyReach for why those two must move as a pair.
	Reach = "WeaponReach",
	-- DIVIDES every duration (windup, active, recovery, cooldown): 1.2 is a weapon that swings 20%
	-- faster, not one whose swings last 20% longer. Phrased as speed rather than duration because
	-- "faster" is the property a builder is actually reaching for.
	Speed = "WeaponSpeed",
}

-- THE PER-WEAPON SWING HITBOX, read off the weapon's own build rather than scaled off the baseline
-- like the four multipliers above -- these are ABSOLUTE values, because "this weapon's swing is a
-- 8x8x8 box four studs out" is a shape a builder judges by looking at the model, not a ratio against
-- a house sword they cannot see.
--
-- WHERE THEY LIVE. On a value object named "<anything>HitboxValues" anywhere inside the weapon (the
-- convention the Cutlass ships with: Weapons/Cutlass/Cutlass/CutlassHitboxValues), falling back to
-- the weapon model ITSELF if there is no such object -- so a builder can equally just put these five
-- Attributes straight on the model beside WeaponDamage and friends. Every one of them is optional and
-- falls back to CombatConstants.Weapons.SwingHitbox, so a weapon with no hitbox values at all swings
-- the house box exactly as it did before this existed.
--
-- WHY A VALUE OBJECT IS SUPPORTED AT ALL rather than insisting on the model: five hitbox Attributes
-- sitting beside the four combat multipliers on one Model is a property panel nobody can scan. A
-- named child groups them, and it is a place to hang a comment for the next builder.
local HITBOX_ATTRIBUTE_NAMES = {
	-- "BodyBox" or "Blade" -- see CombatConstants.Weapons.SwingHitbox.Mode. Per weapon, so a weapon
	-- with a real modelled blade can keep blade-anchored geometry while the rest use the body box.
	Mode = "Mode",
	-- Vector3 of studs: X wide, Y tall, Z reach. Used verbatim in BodyBox mode.
	Size = "Size",
	-- Vector3, NOT a CFrame -- Roblox Attributes cannot hold a CFrame, so this is a translation only
	-- and is converted to one once, here. -Z is forward. Rotating a swing box is not something any
	-- weapon has needed; author it in CombatConstants if one ever does.
	Offset = "Offset",
	-- Whether this weapon's WeaponReach still scales its box. Per weapon because "reach is geometric"
	-- and "reach is a damage flavour" are both defensible and a roster can hold some of each.
	ScaleWithWeaponReach = "ScaleWithWeaponReach",
	-- Seconds of EXTRA delay before the hitbox goes live, on top of the stage's own WindupSeconds.
	-- Additive, not a replacement: WindupSeconds is the house timing for the swing ANIMATION, this is
	-- the builder saying "this particular weapon connects later in its arc than the house sword does."
	-- Applied at the very end of the chain (Server/Combat/AttackCatalog.Get) rather than baked into
	-- WindupSeconds here, specifically so a clip's own AttackM<n> marker cannot silently discard it --
	-- see that function's own comment, and AttackWindows.lua's header for what the marker does.
	SpawnDelay = "SpawnDelay",
}

-- The resolved, validated, FROZEN per-weapon hitbox config. One of these per weapon, built once in
-- Start and thereafter only ever read -- nothing in combat calls GetAttribute on a swing path.
export type SwingHitboxConfig = {
	Mode: "BodyBox" | "Blade",
	Size: Vector3,
	-- Already a CFrame: the Vector3 Attribute is converted exactly once per weapon at boot rather than
	-- once per stage per boot, and never again at runtime.
	Offset: CFrame,
	ScaleWithWeaponReach: boolean,
	SpawnDelaySeconds: number,
}

export type WeaponEntry = {
	Id: WeaponId,
	-- The Workspace.Weapons child this was built from. Held for provenance/logging only -- nothing in
	-- combat reads geometry off it (WeaponModelRegistry clones it for the visual, separately).
	Model: Instance,
	Stages: {
		Basic: { HitboxAttackDefinition },
		Heavy: { HitboxAttackDefinition },
		Finisher: HitboxAttackDefinition,
	},
	-- This weapon's resolved swing geometry. Already baked into every Stages entry above (Size/Offset)
	-- -- carried here as well because two consumers need the config itself rather than its effect:
	-- DefaultMoveRegistry reads Mode to pick the swing's anchor, and SpawnDelaySeconds is deliberately
	-- NOT baked into any stage's WindupSeconds (see HITBOX_ATTRIBUTE_NAMES.SpawnDelay).
	SwingHitbox: SwingHitboxConfig,
}

local started = false
local entriesById: { [WeaponId]: WeaponEntry } = {}
-- Explicit, stable order -- Workspace:GetChildren() has no guaranteed ordering, so the swap cycle is
-- sorted by Name. Alphabetical is arbitrary but it is at least the SAME arbitrary order every boot,
-- which is what stops "press swap twice" meaning something different from one session to the next.
local orderedIds: { WeaponId } = {}

-- A positive, finite multiplier from an Attribute, or `fallback`. Anything else is logged and ignored
-- rather than honoured -- an Attribute is a text field somebody types into, and a weapon with Speed 0
-- would divide every duration by zero and produce a swing that never ends, with no error anywhere.
-- Same shape and same reasoning as BlimpTagging.lua's own positiveOverride.
local function multiplier(model: Instance, attributeName: string): number
	local raw = model:GetAttribute(attributeName)
	if raw == nil then
		return 1
	end
	if typeof(raw) ~= "number" then
		logger:warn("Ignoring non-number weapon Attribute", {
			weapon = model.Name,
			attribute = attributeName,
		})
		return 1
	end
	local value = raw :: number
	if value ~= value or value <= 0 or value == math.huge then
		logger:warn("Ignoring non-positive weapon Attribute", {
			weapon = model.Name,
			attribute = attributeName,
			value = value,
		})
		return 1
	end
	return value
end

-- Size and Offset scale TOGETHER or the hitbox stops matching the swing -- true for every stage's own
-- Size/Offset numbers, and in the shipped CombatConstants.Weapons.SwingHitbox.Mode == "BodyBox" those
-- numbers ARE the live hitbox: the swing is a root-anchored box, so scaling them here is what makes a
-- long weapon out-reach a short one. That is exactly why it is now opt-in. SwingHitbox.ScaleWithWeaponReach
-- defaults false so every weapon swings the one volume a player learns once, and WeaponReach stays a
-- damage/speed-flavoured distinction rather than a geometric one -- read that constant's own header
-- before flipping it.
--
-- In "Blade" mode the flag is inert and both are scaled unconditionally, as they always were: neither
-- drives combat there (the engine reads the equipped weapon's own Blade part instead --
-- HitboxTypes.AttackDefinition.SizeFromAttachmentPart), and scaling them anyway keeps the Move Editor's
-- preview numbers proportionate for whoever opens one of these moves to look at it. SizeMultiplier is
-- the scale that reaches the actual swing in THAT mode -- see its own header on
-- Types.HitboxAttackDefinition for the full chain -- and is applied either way, since it is read only
-- when SizeFromAttachmentPart is set.
local function applyReach(definition: HitboxAttackDefinition, hitbox: SwingHitboxConfig, reach: number): ()
	definition.SizeMultiplier = (definition.SizeMultiplier or 1) * reach
	if reach == 1 then
		return
	end
	if hitbox.Mode ~= "Blade" and not hitbox.ScaleWithWeaponReach then
		return
	end
	if definition.Size then
		local size = definition.Size :: Vector3
		-- X and Z only: Y is how tall the swing arc is, which is a property of the human throwing it
		-- rather than of the blade, and scaling it would let a long weapon hit over a wall.
		definition.Size = Vector3.new(size.X * reach, size.Y, size.Z * reach)
	end
	if definition.Radius then
		definition.Radius = (definition.Radius :: number) * reach
	end
	local offset = definition.Offset
	definition.Offset = offset - offset.Position + (offset.Position * reach)
end

local function applySpeed(definition: HitboxAttackDefinition, speed: number): ()
	if speed == 1 then
		return
	end
	definition.WindupSeconds /= speed
	definition.ActiveSeconds /= speed
	definition.RecoverySeconds /= speed
	definition.Cooldown /= speed
end

-- Per-weapon hitbox config resolution -------------------------------------------------------------
--
-- Every reader below follows `multiplier`'s contract exactly: an Attribute is a text field somebody
-- types into, so a wrong TYPE or an out-of-range value is logged and ignored rather than honoured, and
-- the house default stands. Never an error -- a typo'd Size on one weapon must not take the boot down.

-- The value object holding this weapon's hitbox Attributes, or nil to read them off the model itself.
--
-- SEARCHED AT ANY DEPTH, and by SUFFIX. The Cutlass ships its object two levels down
-- (Weapons/Cutlass/Cutlass/CutlassHitboxValues) because that is where the actual weapon model sits
-- inside its container, and it is named for the weapon rather than generically. Insisting on a direct
-- child named exactly "HitboxValues" would be the same silent-fallback trap Handle already had to be
-- rescued from in WeaponModelRegistry.wrapModel: the config would simply not apply, with nothing
-- anywhere reporting it. An exact "HitboxValues" wins over a suffixed one so a builder can always
-- override unambiguously; ties beyond that are resolved by GetDescendants order and warned about,
-- because two of these means one of them is being silently ignored.
local function findHitboxValues(model: Instance): Instance?
	local exact: Instance? = nil
	local suffixed: Instance? = nil
	local suffixedCount = 0
	for _, descendant in model:GetDescendants() do
		local name = descendant.Name
		if name == HITBOX_VALUES_NAME then
			if exact == nil then
				exact = descendant
			end
		elseif #name > #HITBOX_VALUES_NAME and string.sub(name, -#HITBOX_VALUES_NAME) == HITBOX_VALUES_NAME then
			suffixedCount += 1
			if suffixed == nil then
				suffixed = descendant
			end
		end
	end
	if exact then
		return exact
	end
	if suffixedCount > 1 then
		logger:warn("Weapon has several *HitboxValues objects; using the first found", {
			weapon = model.Name,
			count = suffixedCount,
			using = (suffixed :: Instance):GetFullName(),
		})
	end
	return suffixed
end

local function readMode(source: Instance, weaponName: string, fallback: "BodyBox" | "Blade"): "BodyBox" | "Blade"
	local raw = source:GetAttribute(HITBOX_ATTRIBUTE_NAMES.Mode)
	if raw == nil then
		return fallback
	end
	if raw == "BodyBox" or raw == "Blade" then
		return raw :: "BodyBox" | "Blade"
	end
	logger:warn("Ignoring unrecognised swing hitbox Mode", {
		weapon = weaponName,
		value = tostring(raw),
		expected = "BodyBox or Blade",
	})
	return fallback
end

-- A finite Vector3 Attribute with every component inside `min`..`max`, or `fallback`.
--
-- Component-wise clamping rather than rejecting the whole vector: a Size of (8, 8, 900) is a builder
-- who meant something on two axes and fat-fingered the third, and clamping the one axis keeps the
-- other two. The bounds themselves mirror HitboxTypes.FIELD_BOUNDS, which is what the engine's own
-- sanitiser would clamp to a beat later anyway -- doing it here is what makes the log name the WEAPON.
local function readVector3(
	source: Instance,
	weaponName: string,
	attributeName: string,
	min: number,
	max: number,
	fallback: Vector3
): Vector3
	local raw = source:GetAttribute(attributeName)
	if raw == nil then
		return fallback
	end
	if typeof(raw) ~= "Vector3" then
		logger:warn("Ignoring non-Vector3 swing hitbox Attribute", {
			weapon = weaponName,
			attribute = attributeName,
			got = typeof(raw),
		})
		return fallback
	end
	local value = raw :: Vector3
	-- Spelled as "not (n >= min)" so a NaN component fails rather than passes -- every comparison
	-- against NaN is false, so the direct form would wave it through. Same reasoning, and the same
	-- spelling, as HitboxTypes.sanitizeNumber; a NaN that reaches the geometry does not error, it makes
	-- every containment test silently return false and the weapon simply never hits anything.
	local function axis(n: number, label: string): number
		if n ~= n then
			logger:warn("Swing hitbox Attribute has a NaN component; using the default for that axis", {
				weapon = weaponName,
				attribute = attributeName,
				axis = label,
			})
			return 0
		end
		return math.clamp(n, min, max)
	end
	local clamped = Vector3.new(axis(value.X, "X"), axis(value.Y, "Y"), axis(value.Z, "Z"))
	if clamped ~= value then
		logger:warn("Clamped swing hitbox Attribute", {
			weapon = weaponName,
			attribute = attributeName,
			authored = tostring(value),
			used = tostring(clamped),
			bounds = `{min}..{max}`,
		})
	end
	return clamped
end

local function readBoolean(source: Instance, weaponName: string, attributeName: string, fallback: boolean): boolean
	local raw = source:GetAttribute(attributeName)
	if raw == nil then
		return fallback
	end
	if typeof(raw) ~= "boolean" then
		logger:warn("Ignoring non-boolean swing hitbox Attribute", {
			weapon = weaponName,
			attribute = attributeName,
			got = typeof(raw),
		})
		return fallback
	end
	return raw :: boolean
end

local function readSpawnDelay(source: Instance, weaponName: string, fallback: number): number
	local raw = source:GetAttribute(HITBOX_ATTRIBUTE_NAMES.SpawnDelay)
	if raw == nil then
		return fallback
	end
	if typeof(raw) ~= "number" then
		logger:warn("Ignoring non-number SpawnDelay", { weapon = weaponName, got = typeof(raw) })
		return fallback
	end
	local value = raw :: number
	if value ~= value then
		logger:warn("Ignoring NaN SpawnDelay", { weapon = weaponName })
		return fallback
	end
	local clamped = math.clamp(value, 0, MAX_SPAWN_DELAY_SECONDS)
	if clamped ~= value then
		logger:warn("Clamped SpawnDelay", {
			weapon = weaponName,
			authored = value,
			used = clamped,
			max = MAX_SPAWN_DELAY_SECONDS,
		})
	end
	return clamped
end

-- This weapon's whole hitbox config, resolved once. Frozen, because it is handed out by reference
-- through WeaponRoster.SwingHitbox and shared with DefaultMoveRegistry's cached descriptors -- a
-- consumer that mutated it would silently retune the weapon for everyone, which is exactly the
-- shared-table hazard buildStage's deep copies exist to avoid on the stage tables next door.
local function resolveSwingHitbox(model: Instance): SwingHitboxConfig
	local house = CombatConstants.Weapons.SwingHitbox
	local source = findHitboxValues(model) or model
	local name = model.Name
	return table.freeze({
		Mode = readMode(source, name, house.Mode),
		Size = readVector3(source, name, HITBOX_ATTRIBUTE_NAMES.Size, MIN_SIZE_STUDS, MAX_SIZE_STUDS, house.Size),
		-- Vector3 in, CFrame out -- the one conversion, done once per weapon. house.Offset is already a
		-- CFrame (it is authored in Luau, where that is expressible), so the fallback skips the trip.
		Offset = (function(): CFrame
			local raw = source:GetAttribute(HITBOX_ATTRIBUTE_NAMES.Offset)
			if raw == nil then
				return house.Offset
			end
			local translation = readVector3(
				source,
				name,
				HITBOX_ATTRIBUTE_NAMES.Offset,
				-MAX_OFFSET_STUDS,
				MAX_OFFSET_STUDS,
				house.Offset.Position
			)
			return CFrame.new(translation)
		end)(),
		ScaleWithWeaponReach = readBoolean(
			source,
			name,
			HITBOX_ATTRIBUTE_NAMES.ScaleWithWeaponReach,
			house.ScaleWithWeaponReach
		),
		SpawnDelaySeconds = readSpawnDelay(source, name, house.SpawnDelaySeconds),
	})
end

-- One baseline stage, deep-copied and scaled for this weapon. A COPY every time, never the baseline
-- table itself -- DefaultMoveRegistry hands these out by reference for live Move Editor tuning, so a
-- shared table would make retuning one weapon silently retune every weapon built from the same
-- baseline (and permanently corrupt the baseline for the next weapon built after it).
local function buildStage(
	source: HitboxAttackDefinition,
	hitbox: SwingHitboxConfig,
	scale: {
		Damage: number,
		PostureDamage: number,
		Reach: number,
		Speed: number,
	}
): HitboxAttackDefinition
	local copy: HitboxAttackDefinition = {
		DebugName = source.DebugName,
		Shape = source.Shape,
		Size = source.Size,
		Radius = source.Radius,
		Dimensions = source.Dimensions,
		Offset = source.Offset,
		WindupSeconds = source.WindupSeconds,
		ActiveSeconds = source.ActiveSeconds,
		RecoverySeconds = source.RecoverySeconds,
		Cooldown = source.Cooldown,
		Damage = source.Damage * scale.Damage,
		PostureDamage = source.PostureDamage * scale.PostureDamage,
		ArcDegrees = source.ArcDegrees,
		MaxTargets = source.MaxTargets,
		SizeMultiplier = source.SizeMultiplier,
	}
	-- THE PER-WEAPON BOX REPLACES THE BASELINE'S, before reach scales it. In "Blade" mode both fields
	-- are vestigial (the engine sizes the swing off the weapon's own Blade part), so stamping them is
	-- harmless there and keeps the Move Editor's preview showing this weapon's authored numbers either
	-- way. Vector3 and CFrame are both immutable, so every stage sharing the one config's values is a
	-- share of two constants, not an aliasing hazard -- unlike the surrounding table, which is deep
	-- copied for exactly that reason.
	copy.Size = hitbox.Size
	copy.Offset = hitbox.Offset
	applyReach(copy, hitbox, scale.Reach)
	applySpeed(copy, scale.Speed)
	-- SpawnDelaySeconds is deliberately NOT folded into copy.WindupSeconds here. See
	-- HITBOX_ATTRIBUTE_NAMES.SpawnDelay: a clip's own AttackM<n> marker overwrites WindupSeconds
	-- wholesale in AttackCatalog.Get, so a delay baked in at this end would vanish the moment an
	-- animator marked the clip -- silently, and only for the weapons whose clips happened to have one.
	return copy
end

local function buildEntry(model: Instance): WeaponEntry
	-- ONCE PER WEAPON, AT BOOT. Every GetAttribute this module will ever perform for this weapon
	-- happens inside this call; from here on the config is a frozen table and every consumer -- the
	-- swing path included -- is a plain field read.
	local hitbox = resolveSwingHitbox(model)
	local scale = {
		Damage = multiplier(model, ATTRIBUTE_NAMES.Damage),
		PostureDamage = multiplier(model, ATTRIBUTE_NAMES.PostureDamage),
		Reach = multiplier(model, ATTRIBUTE_NAMES.Reach),
		Speed = multiplier(model, ATTRIBUTE_NAMES.Speed),
	}

	local baseline = CombatConstants.Weapons.Baseline.Stages
	local basic: { HitboxAttackDefinition } = {}
	for _, stage in baseline.Basic do
		table.insert(basic, buildStage(stage, hitbox, scale))
	end
	local heavy: { HitboxAttackDefinition } = {}
	for _, stage in baseline.Heavy do
		table.insert(heavy, buildStage(stage, hitbox, scale))
	end

	return {
		Id = model.Name,
		Model = model,
		Stages = {
			Basic = basic,
			Heavy = heavy,
			Finisher = buildStage(baseline.Finisher, hitbox, scale),
		},
		SwingHitbox = hitbox,
	}
end

-- Workspace.Weapons itself, or nil if nobody has made it yet -- a game with no weapon folder simply
-- has no weapons rather than erroring at boot.

-- Reads Workspace.Weapons once and freezes the result for the session.
--
-- ONCE, NOT LIVE, and this is the one place this module deliberately differs from
-- WeaponModelRegistry's live ChildAdded/ChildRemoved tracking next door. A weapon's MODEL can be
-- hot-swapped harmlessly -- the next equip just clones something else. Its STAGES cannot: they are
-- handed to DefaultMoveRegistry by reference at boot, registered into AttackCatalog under fixed
-- MoveIds, and referenced by every in-flight swing. Rebuilding them under a live server would leave
-- swings mid-flight pointing at orphaned tables, so the roster is fixed at boot and a newly-added
-- weapon needs a restart to become swingable. Idempotent.
function WeaponRoster.Start(): ()
	if started then
		return
	end
	started = true

	local container = WeaponAssets.Container(logger)
	if not container then
		logger:warn("Workspace.Weapons folder not found; no weapons will be available")
		return
	end

	local models = container:GetChildren()
	table.sort(models, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)

	for _, model in models do
		local id = model.Name
		if entriesById[id] then
			logger:warn("Two Workspace.Weapons children share the same Name; keeping the first", { name = id })
			continue
		end
		entriesById[id] = buildEntry(model)
		table.insert(orderedIds, id)
	end

	logger:info("Weapon roster built", { count = #orderedIds, weapons = table.concat(orderedIds, ", ") })
end

-- Every weapon id, in swap order. A fresh table per call -- callers (SwingSequencer's cycle, the Move
-- Editor's list) must not be able to reorder the roster by mutating what they were handed.
function WeaponRoster.Order(): { WeaponId }
	return table.clone(orderedIds)
end

function WeaponRoster.Has(weaponId: WeaponId): boolean
	return entriesById[weaponId] ~= nil
end

function WeaponRoster.Get(weaponId: WeaponId): WeaponEntry?
	return entriesById[weaponId]
end

-- This weapon's resolved swing hitbox config, or the house default for an id the roster doesn't know.
--
-- O(1) and allocation-free: the config was resolved and frozen once in Start, and the house fallback
-- is the live CombatConstants table. Safe to call on a hot path, though nothing currently needs to --
-- DefaultMoveRegistry reads it once per descriptor at boot and the values are baked in from there.
--
-- Falls back rather than returning nil so a caller never has to branch: an unknown weapon is a
-- combatant holding something the roster was built without (deleted out from under them mid-session),
-- and "swings the house box" is a better answer there than "has no hitbox at all."
function WeaponRoster.SwingHitbox(weaponId: WeaponId): SwingHitboxConfig
	local entry = entriesById[weaponId]
	if entry then
		return entry.SwingHitbox
	end
	return CombatConstants.Weapons.SwingHitbox
end

-- What a combatant with no other information starts holding: the first weapon in the roster, or nil
-- for an empty one. nil is a real answer -- a game with no weapons in Workspace.Weapons has nothing
-- to hand anybody, and every caller already has to handle "this combatant has no weapon" for the
-- window before the roster is built.
function WeaponRoster.Default(): WeaponId?
	return orderedIds[1]
end

-- The weapon after `weaponId` in the roster, wrapping at the end -- the whole of what a swap does.
-- Falls back to the default for an id the roster doesn't know (a weapon deleted out from under a
-- player mid-session), so a swap always produces something valid rather than stranding them.
function WeaponRoster.Next(weaponId: WeaponId): WeaponId?
	local index = table.find(orderedIds, weaponId)
	if not index then
		return WeaponRoster.Default()
	end
	return orderedIds[(index % #orderedIds) + 1]
end

-- Spec-only, mirrors every other module's Reset.
function WeaponRoster.Reset(): ()
	table.clear(entriesById)
	table.clear(orderedIds)
	started = false
end

return WeaponRoster
