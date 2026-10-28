--!strict
--[[
	RagdollTypes.lua

	Owns: the authored RAGDOLL block a move may carry (MoveTypes.MoveDefinition.Ragdoll) -- what a landed hit
	from that move does to the body as a physical thing: when it goes limp, how hard and which way it is
	thrown, how it spins, how floppy and heavy it is, and how long until it gets back up. Plus the schema
	every reader of the block agrees on: Fields (the one field list), Limits, Defaults, Copy, Validate,
	Presets and Summary.

	ONE FIELD LIST, THREE READERS. Validate, Copy and the Move Editor's RAGDOLL section are all driven from
	Fields below -- the ProjectileTypes arrangement -- so a field added here is validated, persisted, copied
	and offered in the editor with no second edit, and the editor can never offer a field the server drops.
	Each field also carries its own editor label, unit, step sizes and decimals for the same reason.

	THE BLOCK IS THE SWITCH. A move carrying it ragdolls (on the outcomes its Trigger names); a move without it
	never does, except on a lethal hit when RagdollConstants.Death is on. Absent is not "zeroed": it is the
	MoveTypes convention every optional block keeps.

	VALUES ARE THE TRUE PHYSICAL ONES. Push / Lift are studs per second, Tumble / Twist radians per second,
	GravityScale a multiple of Workspace.Gravity, Bounce the parts' Elasticity -- what the author types is
	what the rig is given (clamped only by Limits and RagdollConstants.Limits), never a 0..10 "feel" number
	something later maps to physics.

	Does not own: when a ragdoll is admitted or how the impulse is composed (Shared/Ragdoll/RagdollRules.lua),
	the runtime that builds and drives the rig (Server/Combat/Ragdoll/RagdollSystem.lua), or any tuning that is
	not per move (Shared/Ragdoll/RagdollConstants.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

local RagdollTypes = {}

-- Which contacts put the body down.
--   Hit         any landed hit (Clean, Backstab, GuardBroken)
--   Lethal      only the hit that kills -- a finisher's flourish
--   Airborne    only a landed hit on a body already off the ground -- a juggle ender
--   GuardBreak  only the hit that breaks a guard
--   Backstab    only a hit from behind
export type Trigger = "Hit" | "Lethal" | "Airborne" | "GuardBreak" | "Backstab"

RagdollTypes.Triggers = { "Hit", "Lethal", "Airborne", "GuardBreak", "Backstab" } :: { Trigger }

RagdollTypes.TriggerLabels = {
	Hit = "On hit",
	Lethal = "On kill",
	Airborne = "On air hit",
	GuardBreak = "On guard break",
	Backstab = "On backstab",
} :: { [Trigger]: string }

export type RagdollSpec = {
	Trigger: Trigger,
	-- Seconds the body stays limp at the least. Recovery cannot start before this.
	DurationSeconds: number,
	-- Seconds it may stay limp at most, settled or not (a body that never comes to rest -- a slope, a fall).
	MaxSeconds: number,
	-- After DurationSeconds: true waits for the body to come to rest before getting up (a launch spends much
	-- of its window still in the air); false gets up the moment DurationSeconds is spent.
	RecoverOnSettle: boolean,
	-- How much of the move's own knockback launch (MoveTypes.MoveKnockback, already resolved by DamageSystem)
	-- carries into the throw. 0 ignores it, 1 is the launch as authored.
	KnockbackScale: number,
	-- Studs/s away from the attacker (along a shot's flight for a projectile), and straight up. Added on top of
	-- the scaled knockback. Negative Push pulls toward the attacker; negative Lift slams down.
	Push: number,
	Lift: number,
	-- Radians/s. Tumble spins the body head-over-heels about the axis across the throw (positive: head goes
	-- back, a backflip away from the hit); Twist spins it about the vertical (positive: counter-clockwise from
	-- above).
	Tumble: number,
	Twist: number,
	-- 0 is a limp body (wide joint cones, little friction), 1 a stiff one (narrow cones, high friction) that
	-- still falls but holds its shape.
	Stiffness: number,
	-- The limbs' Elasticity while limp, and their friction with what they land on.
	Bounce: number,
	Friction: number,
	-- Multiple of Workspace.Gravity the body falls under while limp. Below 1 floats, above 1 slams.
	GravityScale: number,
	-- Seconds the get-up takes: the body is righted and its joints drawn back to the rest pose over this
	-- long before the motors take it again, so control comes back on a standing body, not a sprawled one.
	GetUpSeconds: number,
}

type FieldKind = "Number" | "Enum" | "Boolean"

export type Field = {
	Name: string,
	Kind: FieldKind,
	Default: any,
	-- Enum only.
	Options: { string }?,
	-- Editor presentation, read by the Move Editor's RAGDOLL section and nothing else.
	Label: string,
	Unit: string?,
	Steps: { number }?,
	Decimals: number?,
}

-- THE schema. Order is the order the editor shows the fields in.
RagdollTypes.Fields = {
	{ Name = "Trigger", Kind = "Enum", Default = "Hit", Options = RagdollTypes.Triggers, Label = "Goes limp" },
	{
		Name = "DurationSeconds",
		Kind = "Number",
		Default = 1.4,
		Label = "Down for at least",
		Unit = "seconds",
		Steps = { 0.1, 0.5 },
		Decimals = 2,
	},
	{
		Name = "MaxSeconds",
		Kind = "Number",
		Default = 3.5,
		Label = "Down for at most",
		Unit = "seconds",
		Steps = { 0.1, 0.5 },
		Decimals = 2,
	},
	{ Name = "RecoverOnSettle", Kind = "Boolean", Default = true, Label = "Wait until it comes to rest" },
	{
		Name = "KnockbackScale",
		Kind = "Number",
		Default = 1,
		Label = "Knockback carried",
		Unit = "x the move's launch",
		Steps = { 0.05, 0.25 },
		Decimals = 2,
	},
	{
		Name = "Push",
		Kind = "Number",
		Default = 35,
		Label = "Throw",
		Unit = "studs/s away",
		Steps = { 1, 10 },
		Decimals = 0,
	},
	{
		Name = "Lift",
		Kind = "Number",
		Default = 25,
		Label = "Lift",
		Unit = "studs/s up",
		Steps = { 1, 10 },
		Decimals = 0,
	},
	{
		Name = "Tumble",
		Kind = "Number",
		Default = 8,
		Label = "Tumble",
		Unit = "rad/s, + flips back",
		Steps = { 0.5, 2 },
		Decimals = 1,
	},
	{
		Name = "Twist",
		Kind = "Number",
		Default = 0,
		Label = "Twist",
		Unit = "rad/s about up",
		Steps = { 0.5, 2 },
		Decimals = 1,
	},
	{
		Name = "Stiffness",
		Kind = "Number",
		Default = 0.3,
		Label = "Stiffness",
		Unit = "0 limp .. 1 rigid",
		Steps = { 0.05, 0.2 },
		Decimals = 2,
	},
	{
		Name = "Bounce",
		Kind = "Number",
		Default = 0.1,
		Label = "Bounce",
		Unit = "elasticity",
		Steps = { 0.05, 0.2 },
		Decimals = 2,
	},
	{
		Name = "Friction",
		Kind = "Number",
		Default = 0.7,
		Label = "Friction",
		Unit = "with the ground",
		Steps = { 0.05, 0.2 },
		Decimals = 2,
	},
	{
		Name = "GravityScale",
		Kind = "Number",
		Default = 1,
		Label = "Weight",
		Unit = "x gravity",
		Steps = { 0.05, 0.25 },
		Decimals = 2,
	},
	{
		Name = "GetUpSeconds",
		Kind = "Number",
		Default = 0.4,
		Label = "Get up over",
		Unit = "seconds",
		Steps = { 0.05, 0.2 },
		Decimals = 2,
	},
} :: { Field }

-- The authoring bounds, keyed by field name: Validate's clamp and the editor's field range alike.
RagdollTypes.Limits = {
	DurationSeconds = { Min = 0.2, Max = 6 },
	MaxSeconds = { Min = 0.3, Max = 10 },
	KnockbackScale = { Min = 0, Max = 3 },
	Push = { Min = -80, Max = 220 },
	Lift = { Min = -140, Max = 160 },
	Tumble = { Min = -40, Max = 40 },
	Twist = { Min = -40, Max = 40 },
	Stiffness = { Min = 0, Max = 1 },
	Bounce = { Min = 0, Max = 1 },
	Friction = { Min = 0, Max = 2 },
	GravityScale = { Min = 0.2, Max = 3 },
	GetUpSeconds = { Min = 0.1, Max = 1.5 },
} :: { [string]: { Min: number, Max: number } }

-- A fresh spec at every default -- what the editor seeds a newly ragdolling move with.
function RagdollTypes.Defaults(): RagdollSpec
	local spec = {} :: any
	for _, field in RagdollTypes.Fields do
		spec[field.Name] = field.Default
	end
	return spec :: RagdollSpec
end

-- A field-by-field copy through the schema list, never a table.clone (MoveTypes.Clone's reasoning: junk riding
-- on a malformed source is not reproduced). Every field is a number, a string or a boolean, so this copy is
-- also the block's flat wire / DataStore encoding.
function RagdollTypes.Copy(spec: RagdollSpec): RagdollSpec
	local copy = {} :: any
	for _, field in RagdollTypes.Fields do
		copy[field.Name] = (spec :: any)[field.Name]
	end
	return copy :: RagdollSpec
end

-- The gate for an untrusted block -- a client draft, a DataStore record, a source file. Strict on identity,
-- lenient on numbers (the split MoveRegistryManager.Validate keeps for every block): a value of the wrong type
-- or a trigger that does not exist rejects the block ("InvalidRagdoll"); a number out of range is clamped. An
-- ABSENT field takes its default, so a record saved before a field existed keeps loading.
function RagdollTypes.Validate(raw: unknown): (RagdollSpec?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidRagdoll"
	end
	local source = raw :: { [string]: unknown }
	local spec = {} :: any
	for _, field in RagdollTypes.Fields do
		local value = source[field.Name]
		if value == nil then
			spec[field.Name] = field.Default
		elseif field.Kind == "Number" then
			local range = RagdollTypes.Limits[field.Name]
			local clamped = Sanitize.ClampNumber(value, range.Min, range.Max)
			if clamped == nil then
				return nil, "InvalidRagdoll"
			end
			spec[field.Name] = clamped
		elseif field.Kind == "Enum" then
			if typeof(value) ~= "string" or table.find(field.Options :: { string }, value :: string) == nil then
				return nil, "InvalidRagdoll"
			end
			spec[field.Name] = value
		else
			if typeof(value) ~= "boolean" then
				return nil, "InvalidRagdoll"
			end
			spec[field.Name] = value
		end
	end
	-- Normalised rather than refused: a ceiling below the floor has exactly one reading.
	if spec.MaxSeconds < spec.DurationSeconds then
		spec.MaxSeconds = spec.DurationSeconds
	end
	return spec :: RagdollSpec, nil
end

-- Starting points the editor offers: each sets the fields that make its shape and leaves the rest (Trigger
-- included, unless the preset is about WHEN) as the author had them.
export type Preset = { Id: string, Label: string, Note: string, Values: { [string]: any } }

RagdollTypes.Presets = {
	{
		Id = "Crumple",
		Label = "Crumple",
		Note = "Folds where it stands -- a heavy stagger, no flight.",
		Values = {
			DurationSeconds = 0.9,
			KnockbackScale = 0.4,
			Push = 8,
			Lift = 0,
			Tumble = 0,
			Twist = 0,
			Stiffness = 0.5,
			GravityScale = 1.3,
		},
	},
	{
		Id = "Launch",
		Label = "Launch",
		Note = "Thrown up and back, one clean backflip.",
		Values = {
			DurationSeconds = 1.6,
			Push = 60,
			Lift = 40,
			Tumble = 9,
			Twist = 0,
			Stiffness = 0.25,
			GravityScale = 1,
		},
	},
	{
		Id = "Spiral",
		Label = "Spiral",
		Note = "Corkscrews away -- high, light, spinning about its own spine.",
		Values = { DurationSeconds = 1.8, Push = 40, Lift = 55, Tumble = 4, Twist = 18, GravityScale = 0.7 },
	},
	{
		Id = "Slam",
		Label = "Slam",
		Note = "Driven into the floor face first, with a bounce.",
		Values = { DurationSeconds = 1.2, Push = 15, Lift = -80, Tumble = -10, GravityScale = 2.2, Bounce = 0.3 },
	},
	{
		Id = "Float",
		Label = "Float",
		Note = "Drifts up and hangs -- for a realm or an art that defies weight.",
		Values = { DurationSeconds = 2.4, MaxSeconds = 4, Push = 20, Lift = 70, Tumble = 3, GravityScale = 0.35 },
	},
	{
		Id = "Execution",
		Label = "Execution",
		Note = "Only the killing blow: the body is hurled and stays down.",
		Values = { Trigger = "Lethal", DurationSeconds = 3, Push = 80, Lift = 45, Tumble = 10, Stiffness = 0.15 },
	},
} :: { Preset }

function RagdollTypes.PresetById(id: string): Preset?
	for _, preset in RagdollTypes.Presets do
		if preset.Id == id then
			return preset
		end
	end
	return nil
end

-- Lays a preset's values over `spec`, in place. Only schema fields are written.
function RagdollTypes.ApplyPreset(spec: RagdollSpec, preset: Preset): ()
	for _, field in RagdollTypes.Fields do
		local value = preset.Values[field.Name]
		if value ~= nil then
			(spec :: any)[field.Name] = value
		end
	end
	if spec.MaxSeconds < spec.DurationSeconds then
		spec.MaxSeconds = spec.DurationSeconds
	end
end

-- One line for a folded section's heading ("On hit  ·  1.4s  ·  35 push  ·  25 lift").
function RagdollTypes.Summary(spec: RagdollSpec?): string
	if spec == nil then
		return "Off"
	end
	return string.format(
		"%s  ·  %gs  ·  %g push  ·  %g lift",
		RagdollTypes.TriggerLabels[spec.Trigger] or spec.Trigger,
		spec.DurationSeconds,
		spec.Push,
		spec.Lift
	)
end

return RagdollTypes
