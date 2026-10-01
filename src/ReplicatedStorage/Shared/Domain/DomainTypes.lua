--!strict
--[[
	DomainTypes.lua

	Owns: the DOMAIN vocabulary -- what a domain IS to the Move Editor, the move registries and
	Server/Combat/Domain/DomainSystem.lua (DomainSpec), the three list entries it is built from (an
	Effect, a Rule, a ClashOverride), the option lists, the authorable bounds, and the ONE field list per
	record that every copy, encoding and validation walks (ProjectileTypes' arrangement).

	A DOMAIN IS A MOVE. The in-world name is an UNFURLING: a cultivator turns their own Meridian Particle
	inside out and, for a few seconds, the ground around them runs on their meridian's law instead of the
	world's -- a fragment of the unified Meridian the Shattering broke, restored under one person's will.
	Mechanically it is a move carrying this block (MoveDefinition.Domain), exactly as an art is a move with
	an Art binding and a projectile move is a move with a Projectile block. So the activation sequence
	needs nothing of its own: the move's swing IS it -- its clip is the activation animation, its windup is
	the tell, its Cooldown is the domain's cooldown, its Art binding's QiCost is the resource cost, and its
	Presentation block (the four Domain moments, MovePresentationTypes) is what the realm looks and sounds
	like. This block is only what a swing does not already say: how long the realm lasts, where its edge
	is, what it does to the people inside it, and what happens when it meets another.

	THE FRAMEWORK HAS NO DOMAINS IN IT. Nothing below names an ability. A domain's identity is its data:
	  * Effects -- periodic, delivered to the realm's members on a timer. Each is a KIND of delivery
	    through a system that already exists: Strike (the referenced move, delivered to every target as a
	    guaranteed homing shot through HitboxEngine, so DefenseSystem still decides block/parry and
	    DamageSystem prices it as that move), Volley (a PROJECTILE move's own volley, launched at every
	    target from the realm), Hitstun (DamageSystem.ExtendHitstun), GuardDrain (DefenseSystem.DrainGuard),
	    Pull/Push (the knockback path's own owner split) and OwnerCast (the owner throws the referenced
	    move through AttackRequestSystem.ThrowMove, every gate included).
	  * Rules -- continuous, for as long as someone is inside. Each is published as a Humanoid Attribute
	    (Shared/Domain/DomainRules.lua) that the layer it modifies ALREADY reads for the same kind of
	    question: damage dealt/taken, posture taken, hitstun taken (DamageSystem), guard/parry/evade
	    (DefenseSystem), cooldowns and sealed moves (AttackRequestSystem), speed and rooting (RunSystem),
	    parkour escapes (ParkourSystem and the client's own combat gate).
	  * Clash -- a priority, a default behaviour toward a weaker realm (Shared/Domain/DomainClash.lua), and
	    per-opponent overrides keyed by the other domain's MoveId.

	THE FIELD LISTS ARE THE SCHEMA. Copy, the wire encoding, Validate and the editor all iterate them, so a
	field added here is carried by every one of them at once. The same strict/lenient split as every block
	in MoveRegistryManager.Validate: a value of the wrong type, or an option that does not exist, rejects
	the whole block ("InvalidDomain"); a number out of range is clamped; an absent field takes its default,
	so a record saved before a field existed keeps loading.

	Where a field's meaning is not obvious from its name:
	  * Radius is the sphere's radius, the cylinder's radius, or the box's HALF-width. Height is the
	    cylinder's and the box's full height, centred on the realm's centre; a sphere ignores it.
	  * CenterForward places the centre that many studs along the owner's facing at the moment the realm
	    opens -- negative is behind. A FollowOwner realm keeps that offset as its owner moves.
	  * EntryRule/ExitRule are the boundary's two directions. "Barred" entry repels anyone who was not
	    inside when the realm was established; "Barred" exit holds everyone who was. The owner is never
	    held -- their own realm cannot trap them (CancelOnOwnerExit decides whether leaving ends it).
	  * BoundaryCollision raises a physical wall -- to EVERY body, both ways. It is the sealed realm; the
	    two rules above are the per-direction, per-person version enforced by the system.
	  * EntryGraceSeconds is how long a newcomer stands inside before any effect targets them; ExitLinger
	    Seconds is how long a leaver keeps the realm's rules (a slow that does not end the instant you
	    step over the line).
	  * An effect's Magnitude means what its Kind needs: Hitstun seconds, GuardDrain posture, Pull/Push
	    studs per second; Strike/Volley/OwnerCast ignore it (the referenced move prices itself).
	  * A rule's Value is a multiplier for the scale kinds (0.5 halves, 2 doubles) and is unread by the
	    flag kinds. SealMove names its move in MoveId.

	Does not own: running a domain (DomainSystem), the geometry (DomainGeometry), clash arbitration
	(DomainClash), the attribute seam (DomainRules), or the move schema around the block (MoveTypes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

local DomainTypes = {}

export type Shape = "Sphere" | "Cylinder" | "Box"
export type Anchor = "Fixed" | "FollowOwner"
export type BoundaryRule = "Open" | "Barred"
export type TargetFilter = "Enemies" | "Allies" | "Owner" | "OwnerAndAllies" | "EveryoneButOwner" | "Everyone"
export type TargetType = "Any" | "Players" | "NonPlayers"
export type EffectKind = "Strike" | "Volley" | "Hitstun" | "GuardDrain" | "Pull" | "Push" | "OwnerCast"
export type StrikeOrigin = "Above" | "Center" | "Owner" | "Ring"
export type RuleKind =
	"DamageDealt"
	| "DamageTaken"
	| "GuardDamageTaken"
	| "HitstunTaken"
	| "MoveSpeed"
	| "Cooldown"
	| "SealMove"
	| "SealArts"
	| "SealProjectiles"
	| "SealDomains"
	| "NoBlock"
	| "NoParry"
	| "NoEvade"
	| "NoParkour"
	| "Rooted"
export type ClashBehavior = "Coexist" | "Suppress" | "Erode" | "Dominate" | "Shatter"
export type TieBreak = "Older" | "Newer" | "Contest"

export type Effect = {
	Kind: EffectKind,
	-- "" when the kind references no move.
	MoveId: string,
	IntervalSeconds: number,
	FirstDelaySeconds: number,
	Affects: TargetFilter,
	TargetTypes: TargetType,
	MaxPerPulse: number,
	Magnitude: number,
	Origin: StrikeOrigin,
	OriginDistance: number,
	TravelSeconds: number,
	Parryable: boolean,
	StrikeSize: number,
}

export type Rule = {
	Kind: RuleKind,
	Value: number,
	MoveId: string,
	Affects: TargetFilter,
	TargetTypes: TargetType,
}

export type ClashOverride = {
	OpponentMoveId: string,
	Behavior: ClashBehavior,
}

export type DomainSpec = {
	-- Basic
	ActivationSeconds: number,
	ActiveSeconds: number,
	EndSeconds: number,
	UpkeepQiPerSecond: number,
	MaxTargets: number,
	-- Boundary
	Shape: Shape,
	Radius: number,
	Height: number,
	Anchor: Anchor,
	CenterForward: number,
	EntryRule: BoundaryRule,
	ExitRule: BoundaryRule,
	BoundaryCollision: boolean,
	ProjectilesEnter: boolean,
	ProjectilesLeave: boolean,
	EntryGraceSeconds: number,
	ExitLingerSeconds: number,
	-- Cancel conditions (the owner dying always ends it and is not a field)
	CancelOnOwnerHit: boolean,
	CancelOnOwnerExit: boolean,
	-- Clash
	Priority: number,
	ClashBehavior: ClashBehavior,
	TieBreak: TieBreak,
	ErodeRate: number,
	ContestScale: number,
	Interacts: boolean,
	-- Lists
	Effects: { Effect },
	Rules: { Rule },
	ClashOverrides: { ClashOverride },
}

-- Option lists, in the order the editor offers them.
DomainTypes.Shapes = { "Sphere", "Cylinder", "Box" } :: { Shape }
DomainTypes.Anchors = { "Fixed", "FollowOwner" } :: { Anchor }
DomainTypes.BoundaryRules = { "Open", "Barred" } :: { BoundaryRule }
DomainTypes.TargetFilters =
	{ "Enemies", "Allies", "Owner", "OwnerAndAllies", "EveryoneButOwner", "Everyone" } :: { TargetFilter }
DomainTypes.TargetTypes = { "Any", "Players", "NonPlayers" } :: { TargetType }
DomainTypes.EffectKinds = { "Strike", "Volley", "Hitstun", "GuardDrain", "Pull", "Push", "OwnerCast" } :: { EffectKind }
DomainTypes.StrikeOrigins = { "Above", "Center", "Owner", "Ring" } :: { StrikeOrigin }
DomainTypes.RuleKinds = {
	"DamageDealt",
	"DamageTaken",
	"GuardDamageTaken",
	"HitstunTaken",
	"MoveSpeed",
	"Cooldown",
	"SealMove",
	"SealArts",
	"SealProjectiles",
	"SealDomains",
	"NoBlock",
	"NoParry",
	"NoEvade",
	"NoParkour",
	"Rooted",
} :: { RuleKind }
DomainTypes.ClashBehaviors = { "Coexist", "Suppress", "Erode", "Dominate", "Shatter" } :: { ClashBehavior }
DomainTypes.TieBreaks = { "Contest", "Older", "Newer" } :: { TieBreak }

-- Which effect kinds deliver a referenced move (and so must name one), and which rule kinds are
-- multipliers rather than flags. Read by Validate, the runtime and the editor alike.
DomainTypes.EffectNeedsMove = {
	Strike = true,
	Volley = true,
	OwnerCast = true,
} :: { [string]: boolean }

DomainTypes.ScaleRules = {
	DamageDealt = true,
	DamageTaken = true,
	GuardDamageTaken = true,
	HitstunTaken = true,
	MoveSpeed = true,
	Cooldown = true,
} :: { [string]: boolean }

-- How many of each list entry a domain may carry. Bounded so one domain's pulses stay a fixed, small cost
-- per tick and one DataStore record stays well inside its budget.
DomainTypes.MaxEffects = 6
DomainTypes.MaxRules = 10
DomainTypes.MaxClashOverrides = 6
-- A move id as the registries mint them (slug + suffix) or DefaultMoveRegistry's "default:" scheme.
DomainTypes.MoveIdLength = 64

type Range = { Min: number, Max: number }

-- Authorable bounds, in Constants.MoveEditor.Limits' {Min, Max} shape: Validate clamps against them and
-- the editor renders its fields from them, so the two cannot disagree about a range.
DomainTypes.Limits = {
	ActivationSeconds = { Min = 0.2, Max = 6 },
	ActiveSeconds = { Min = 1, Max = 60 },
	EndSeconds = { Min = 0, Max = 5 },
	UpkeepQiPerSecond = { Min = 0, Max = 100 },
	MaxTargets = { Min = 1, Max = 32 },
	Radius = { Min = 4, Max = 120 },
	Height = { Min = 4, Max = 160 },
	CenterForward = { Min = -60, Max = 60 },
	EntryGraceSeconds = { Min = 0, Max = 5 },
	ExitLingerSeconds = { Min = 0, Max = 5 },
	Priority = { Min = 0, Max = 100 },
	ErodeRate = { Min = 0, Max = 5 },
	ContestScale = { Min = 0, Max = 1 },
	-- Effect
	IntervalSeconds = { Min = 0.25, Max = 20 },
	FirstDelaySeconds = { Min = 0, Max = 20 },
	MaxPerPulse = { Min = 1, Max = 32 },
	Magnitude = { Min = 0, Max = 200 },
	OriginDistance = { Min = 2, Max = 60 },
	TravelSeconds = { Min = 0.05, Max = 2 },
	StrikeSize = { Min = 0.2, Max = 8 },
	-- Rule
	Value = { Min = 0, Max = 5 },
} :: { [string]: Range }

type Field = {
	Name: string,
	Kind: "Number" | "Enum" | "Boolean" | "MoveId",
	Default: any,
	-- Number: rounded to a whole number after clamping.
	Integer: boolean?,
	-- Enum: the legal values.
	Options: { string }?,
}

-- THE schemas -- see this file's header. Order is the order a record is written out in, and the order
-- the editor lays its fields out in.
DomainTypes.Fields = {
	{ Name = "ActivationSeconds", Kind = "Number", Default = 1.2 },
	{ Name = "ActiveSeconds", Kind = "Number", Default = 12 },
	{ Name = "EndSeconds", Kind = "Number", Default = 1 },
	{ Name = "UpkeepQiPerSecond", Kind = "Number", Default = 0 },
	{ Name = "MaxTargets", Kind = "Number", Default = 12, Integer = true },
	{ Name = "Shape", Kind = "Enum", Default = "Sphere", Options = DomainTypes.Shapes },
	{ Name = "Radius", Kind = "Number", Default = 36 },
	{ Name = "Height", Kind = "Number", Default = 36 },
	{ Name = "Anchor", Kind = "Enum", Default = "Fixed", Options = DomainTypes.Anchors },
	{ Name = "CenterForward", Kind = "Number", Default = 0 },
	{ Name = "EntryRule", Kind = "Enum", Default = "Open", Options = DomainTypes.BoundaryRules },
	{ Name = "ExitRule", Kind = "Enum", Default = "Open", Options = DomainTypes.BoundaryRules },
	{ Name = "BoundaryCollision", Kind = "Boolean", Default = false },
	{ Name = "ProjectilesEnter", Kind = "Boolean", Default = true },
	{ Name = "ProjectilesLeave", Kind = "Boolean", Default = true },
	{ Name = "EntryGraceSeconds", Kind = "Number", Default = 0.5 },
	{ Name = "ExitLingerSeconds", Kind = "Number", Default = 0 },
	{ Name = "CancelOnOwnerHit", Kind = "Boolean", Default = true },
	{ Name = "CancelOnOwnerExit", Kind = "Boolean", Default = false },
	{ Name = "Priority", Kind = "Number", Default = 10, Integer = true },
	{ Name = "ClashBehavior", Kind = "Enum", Default = "Suppress", Options = DomainTypes.ClashBehaviors },
	{ Name = "TieBreak", Kind = "Enum", Default = "Contest", Options = DomainTypes.TieBreaks },
	{ Name = "ErodeRate", Kind = "Number", Default = 1 },
	{ Name = "ContestScale", Kind = "Number", Default = 0.5 },
	{ Name = "Interacts", Kind = "Boolean", Default = true },
} :: { Field }

DomainTypes.EffectFields = {
	{ Name = "Kind", Kind = "Enum", Default = "Strike", Options = DomainTypes.EffectKinds },
	{ Name = "MoveId", Kind = "MoveId", Default = "" },
	{ Name = "IntervalSeconds", Kind = "Number", Default = 2 },
	{ Name = "FirstDelaySeconds", Kind = "Number", Default = 0.5 },
	{ Name = "Affects", Kind = "Enum", Default = "Enemies", Options = DomainTypes.TargetFilters },
	{ Name = "TargetTypes", Kind = "Enum", Default = "Any", Options = DomainTypes.TargetTypes },
	{ Name = "MaxPerPulse", Kind = "Number", Default = 32, Integer = true },
	{ Name = "Magnitude", Kind = "Number", Default = 10 },
	{ Name = "Origin", Kind = "Enum", Default = "Above", Options = DomainTypes.StrikeOrigins },
	{ Name = "OriginDistance", Kind = "Number", Default = 12 },
	{ Name = "TravelSeconds", Kind = "Number", Default = 0.35 },
	{ Name = "Parryable", Kind = "Boolean", Default = true },
	{ Name = "StrikeSize", Kind = "Number", Default = 1.5 },
} :: { Field }

DomainTypes.RuleFields = {
	{ Name = "Kind", Kind = "Enum", Default = "DamageTaken", Options = DomainTypes.RuleKinds },
	{ Name = "Value", Kind = "Number", Default = 1 },
	{ Name = "MoveId", Kind = "MoveId", Default = "" },
	{ Name = "Affects", Kind = "Enum", Default = "Enemies", Options = DomainTypes.TargetFilters },
	{ Name = "TargetTypes", Kind = "Enum", Default = "Any", Options = DomainTypes.TargetTypes },
} :: { Field }

DomainTypes.ClashOverrideFields = {
	{ Name = "OpponentMoveId", Kind = "MoveId", Default = "" },
	{ Name = "Behavior", Kind = "Enum", Default = "Suppress", Options = DomainTypes.ClashBehaviors },
} :: { Field }

-- The wire -----------------------------------------------------------------------------------------------

-- What a client is told about one live realm (DomainConstants.Network.RemoteNames.State). Every time is on
-- the shared server clock (workspace:GetServerTimeNow()). Enough to draw the realm and predict its edge;
-- nothing that decides anything -- membership, rules and every effect stay the server's.
export type DomainView = {
	Id: string,
	Owner: Model?,
	MoveId: string,
	Shape: Shape,
	Radius: number,
	Height: number,
	-- A FollowOwner realm's centre is its owner's root plus Offset (fixed in world space); a Fixed realm's is
	-- Center.
	Center: Vector3,
	Offset: Vector3,
	Yaw: number,
	Anchor: Anchor,
	EntryRule: BoundaryRule,
	ExitRule: BoundaryRule,
	Phase: string,
	PhaseStartedAt: number,
	PhaseEndsAt: number,
	ActivationSeconds: number,
	EndSeconds: number,
	ClashState: string,
}

export type MessageKind = "Open" | "Phase" | "Clash" | "Pulse" | "Snapshot" | "Impulse"

export type DomainMessage = {
	Kind: MessageKind,
	-- Open
	Domain: DomainView?,
	-- Snapshot
	Domains: { DomainView }?,
	-- Phase / Clash / Pulse
	Id: string?,
	Phase: string?,
	PhaseStartedAt: number?,
	PhaseEndsAt: number?,
	Reason: string?,
	ClashState: string?,
	-- Pulse
	EffectIndex: number?,
	EffectKind: string?,
	Targets: { Model }?,
	-- Impulse (to one player only): the velocity their own client applies to their own body.
	Velocity: Vector3?,
}

-- Records ------------------------------------------------------------------------------------------------

local function defaultsOf(fields: { Field }): any
	local record = {} :: any
	for _, field in fields do
		record[field.Name] = field.Default
	end
	return record
end

local function copyOf(fields: { Field }, source: any): any
	local copy = {} :: any
	for _, field in fields do
		copy[field.Name] = source[field.Name]
	end
	return copy
end

-- One record through one field list. Returns the validated record, or nil on an identity error.
local function validateRecord(fields: { Field }, raw: unknown): any?
	if typeof(raw) ~= "table" then
		return nil
	end
	local source = raw :: { [string]: unknown }
	local record = {} :: any
	for _, field in fields do
		local value = source[field.Name]
		if value == nil then
			record[field.Name] = field.Default
		elseif field.Kind == "Number" then
			local range = DomainTypes.Limits[field.Name]
			local clamped = Sanitize.ClampNumber(value, range.Min, range.Max)
			if clamped == nil then
				return nil
			end
			record[field.Name] = if field.Integer then math.floor(clamped + 0.5) else clamped
		elseif field.Kind == "Enum" then
			if typeof(value) ~= "string" or table.find(field.Options :: { string }, value :: string) == nil then
				return nil
			end
			record[field.Name] = value
		elseif field.Kind == "MoveId" then
			if typeof(value) ~= "string" then
				return nil
			end
			-- Trimmed, never rewritten: a move id is an identity, and "fixing" one would silently point the
			-- entry at a different move.
			local trimmed = string.match(value :: string, "^%s*(.-)%s*$") or ""
			if #trimmed > DomainTypes.MoveIdLength or string.find(trimmed, "[^%w%-_:]") then
				return nil
			end
			record[field.Name] = trimmed
		else
			if typeof(value) ~= "boolean" then
				return nil
			end
			record[field.Name] = value
		end
	end
	return record
end

local function validateList(fields: { Field }, raw: unknown, maxCount: number): ({ any }?, boolean)
	if raw == nil then
		return {}, true
	end
	if typeof(raw) ~= "table" then
		return nil, false
	end
	local list: { any } = {}
	for index, entry in ipairs(raw :: { unknown }) do
		if index > maxCount then
			-- Past the cap is dropped, not refused: a longer list is a value error, the same "clamp numbers"
			-- leniency a single out-of-range field gets.
			break
		end
		local record = validateRecord(fields, entry)
		if record == nil then
			return nil, false
		end
		table.insert(list, record)
	end
	return list, true
end

-- Public --------------------------------------------------------------------------------------------------

function DomainTypes.Defaults(): DomainSpec
	local spec = defaultsOf(DomainTypes.Fields)
	spec.Effects = {}
	spec.Rules = {}
	spec.ClashOverrides = {}
	return spec :: DomainSpec
end

function DomainTypes.DefaultEffect(): Effect
	return defaultsOf(DomainTypes.EffectFields) :: Effect
end

function DomainTypes.DefaultRule(): Rule
	return defaultsOf(DomainTypes.RuleFields) :: Rule
end

function DomainTypes.DefaultClashOverride(): ClashOverride
	return defaultsOf(DomainTypes.ClashOverrideFields) :: ClashOverride
end

-- A field-by-field copy through the schema lists, never a table.clone: what comes out is exactly the
-- schema's fields (MoveTypes.Clone's reasoning). Every value in it is a number, a string or a boolean, so
-- this is also its flat wire/storage encoding.
function DomainTypes.Copy(spec: DomainSpec): DomainSpec
	local copy = copyOf(DomainTypes.Fields, spec)
	copy.Effects = {}
	for _, effect in spec.Effects do
		table.insert(copy.Effects, copyOf(DomainTypes.EffectFields, effect))
	end
	copy.Rules = {}
	for _, rule in spec.Rules do
		table.insert(copy.Rules, copyOf(DomainTypes.RuleFields, rule))
	end
	copy.ClashOverrides = {}
	for _, override in spec.ClashOverrides do
		table.insert(copy.ClashOverrides, copyOf(DomainTypes.ClashOverrideFields, override))
	end
	return copy :: DomainSpec
end

-- The gate for an untrusted block -- a client draft, a DataStore record, a source file. `ownMoveId` is the
-- move carrying the block, so an entry that references it can be refused: a realm whose effect is its own
-- move would re-open itself (OwnerCast) or price its strikes as the realm (Strike), neither of which an
-- author means.
--
-- Returns (spec, nil) or (nil, reasonCode). Reason codes are stable strings the editor turns into prose
-- (Client/UI/Screens/DevTools/MoveEditor/Copy.lua).
function DomainTypes.Validate(raw: unknown, ownMoveId: string?): (DomainSpec?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidDomain"
	end
	local source = raw :: { [string]: unknown }
	local spec = validateRecord(DomainTypes.Fields, source)
	if spec == nil then
		return nil, "InvalidDomain"
	end

	local effects, effectsOk = validateList(DomainTypes.EffectFields, source.Effects, DomainTypes.MaxEffects)
	if not effectsOk or effects == nil then
		return nil, "InvalidDomainEffect"
	end
	for _, effect in effects do
		if DomainTypes.EffectNeedsMove[effect.Kind] then
			if effect.MoveId == "" then
				return nil, "DomainEffectNeedsMove"
			end
			if ownMoveId ~= nil and effect.MoveId == ownMoveId then
				return nil, "DomainSelfReference"
			end
		end
	end

	local rules, rulesOk = validateList(DomainTypes.RuleFields, source.Rules, DomainTypes.MaxRules)
	if not rulesOk or rules == nil then
		return nil, "InvalidDomainRule"
	end
	for _, rule in rules do
		if rule.Kind == "SealMove" and rule.MoveId == "" then
			return nil, "DomainRuleNeedsMove"
		end
	end

	local overrides, overridesOk =
		validateList(DomainTypes.ClashOverrideFields, source.ClashOverrides, DomainTypes.MaxClashOverrides)
	if not overridesOk or overrides == nil then
		return nil, "InvalidDomainClash"
	end
	for _, override in overrides do
		if override.OpponentMoveId == "" then
			return nil, "InvalidDomainClash"
		end
	end

	spec.Effects = effects
	spec.Rules = rules
	spec.ClashOverrides = overrides
	return spec :: DomainSpec, nil
end

-- The behaviour this realm takes toward `opponentMoveId` when it wins a clash: its per-opponent override
-- if it has one, its default otherwise.
function DomainTypes.BehaviorToward(spec: DomainSpec, opponentMoveId: string): ClashBehavior
	for _, override in spec.ClashOverrides do
		if override.OpponentMoveId == opponentMoveId then
			return override.Behavior
		end
	end
	return spec.ClashBehavior
end

-- The realm's whole authored life, activation to fully gone. What a caller budgeting a domain's lifetime
-- (the lease on its rule attributes, a spec asserting a duration) reads rather than summing three fields.
function DomainTypes.TotalSeconds(spec: DomainSpec): number
	return spec.ActivationSeconds + spec.ActiveSeconds + spec.EndSeconds
end

return DomainTypes
