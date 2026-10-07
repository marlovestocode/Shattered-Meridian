--!strict
--[[
	MoveEditor/HitboxTab.lua

	Owns: the Hitbox tab -- how a melee or projectile move DELIVERS its hit. Never shown for a domain
	expansion: a realm casts volumeless (MoveTypes' header) and has no volume to place, so its boundary has
	its own tab (DomainTab.Boundary). Which of the three a move is, is the move type bar's (init.lua), not
	this tab's -- the type reshapes the whole editor, not one group of it.

	SECTIONS (Fields.Section, each folded on its heading, each summarising itself while folded, each built
	the first time it is opened):
	    melee        VOLUME     "Start from" presets, the shape chips, the measurements that shape reads,
	                            a scale row
	                 PLACEMENT  the anchor, the offset and the rotation, and the in-world tools
	                 TARGETS    how many bodies one swing may take
	    projectile   BODY       weapon presets, the body's shape chips and its measurements, a scale row
	                 VOLLEY / FLIGHT / HOMING / COLLISION / PARRY
	                 SPAWN      the anchor, the offset, the direction it fires and the aim, the in-world tools

	The movement locks are not here any more: what the thrower is held to is the Timing tab's COMMITMENT.

	ONLY THE MEASUREMENTS THE SHAPE READS ARE SHOWN, and under the name that shape gives them. HitboxTypes
	.FieldsFor is the engine's own statement of which fields a shape reads (a Cone reads Length and
	AngleDegrees, nothing else); a field the shape ignores is hidden rather than left editable, because an
	editable number that does nothing is the exact thing this rebuild exists to remove. A Crescent's
	InnerRadius is its bite and a Cross's Radius is its bar's half-width, so those shapes get their own
	labels (SHAPE_LABELS) -- one field per distinct label, only one of which is ever visible. Switching shape
	keeps the hidden values, so switching back restores them. The projectile groups follow the same rule:
	Spread angle only for a pattern that fans, Spacing only for one that lines up, Max bounces only when
	shots bounce, the reflection numbers only when a parry reflects.

	A Default move shows its anchor as a fact: the weapon decides it (Blade vs body box), not the stage.
	It is always melee.

	PLACEMENT ends with the in-world tools -- "Place in world" (Place mode: drag the volume with handles
	on your own character) and "Show on my character" -- beside the offset and rotation fields they edit:
	they are a way of TYPING those numbers, by hand in the world. For a projectile they place its spawn.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition
type Spec = ProjectileTypes.ProjectileSpec

local LIMITS = Constants.MoveEditor.Limits
local PROJECTILE_LIMITS = ProjectileTypes.Limits

local SHAPE_OPTIONS = Fields.OptionsOf(MoveTypes.Shapes)

local ANCHOR_OPTIONS = {
	{ Value = "Root", Text = "Body" },
	{ Value = "RightHand", Text = "Right hand" },
	{ Value = "LeftHand", Text = "Left hand" },
	{ Value = "Weapon", Text = "Weapon" },
}

-- The "Start from" chips: each preset by its id; its Label and Note are the long form (HitboxTypes /
-- ProjectileTypes), said once in the section's hint rather than per chip.
local function presetOptions(presets: { { Id: string } }): { Fields.Option }
	local options = {}
	for _, preset in presets do
		table.insert(options, { Value = preset.Id, Text = preset.Id })
	end
	return options
end
local VOLUME_PRESET_OPTIONS = presetOptions(HitboxTypes.Presets :: any)
local BODY_PRESET_OPTIONS = presetOptions(ProjectileTypes.Presets :: any)

-- Display text for every projectile option, keyed by the option itself; the ORDER is ProjectileTypes'
-- own list, so an option added there is offered here with its raw name until it is given words.
-- Chip text, so short; the hint under each chip row is the long form.
local OPTION_TEXT: { [string]: string } = {
	Single = "Single",
	Fan = "Fan",
	Horizontal = "Row",
	Vertical = "Column",
	Radial = "Ring",
	Facing = "Body facing",
	Anchor = "Anchor facing",
	Target = "At target",
	Destroy = "Destroy",
	Bounce = "Bounce",
	Continue = "Pass through",
	Aim = "Closest to heading",
	Nearest = "Nearest",
	ParryOne = "Parry one",
	ParryAll = "Parry all",
	CannotParry = "Cannot parry",
	ExistingParry = "Existing parry",
	Reflect = "Reflect",
	Reverse = "Reverse",
	ToOwner = "At thrower",
	ParrierFacing = "Parrier facing",
	Mirror = "Mirror",
}

local function optionsOf(values: { any }): { Fields.Option }
	return Fields.OptionsOf(values, OPTION_TEXT)
end

-- Per dimension: its default label, unit and step sizes, in the order they are shown.
local DIMENSIONS = {
	{ Field = "Width", Label = "Width", Unit = "studs", Steps = { 0.5, 2 }, Short = "W" },
	{ Field = "Height", Label = "Height", Unit = "studs", Steps = { 0.5, 2 }, Short = "H" },
	{ Field = "Length", Label = "Length", Unit = "studs", Steps = { 0.5, 2 }, Short = "L" },
	{ Field = "Radius", Label = "Radius", Unit = "studs", Steps = { 0.25, 1 }, Short = "R" },
	{ Field = "InnerRadius", Label = "Inner radius", Unit = "studs", Steps = { 0.25, 1 }, Short = "r" },
	{ Field = "AngleDegrees", Label = "Angle", Unit = "degrees", Steps = { 5, 30 }, Short = "°" },
}

-- What a shape calls a measurement, where that is not the field's own name (HitboxTypes' SHAPE_FIELDS
-- comments are the long version). Shared by the melee volume and the projectile body.
local SHAPE_LABELS: { [string]: { [string]: string } } = {
	Arc = { AngleDegrees = "Sweep", Height = "Thickness" },
	Cone = { AngleDegrees = "Spread angle" },
	Frustum = { Radius = "Far radius", InnerRadius = "Near radius" },
	Pyramid = { Width = "Far width", Height = "Far height" },
	Wedge = { Width = "Far width" },
	Crescent = { Radius = "Outer radius", InnerRadius = "Bite radius", Length = "Bite offset", Height = "Thickness" },
	Cross = {
		Width = "Bar span (across)",
		Length = "Bar span (along)",
		Height = "Thickness",
		Radius = "Bar half-width",
	},
}

-- One measurement field per distinct label it goes by: { label, the shapes that read it under that label }.
type LabelGroup = { Label: string, Shapes: { [string]: boolean } }
local function labelGroups(field: string, defaultLabel: string, shapes: { any }): { LabelGroup }
	local groups: { LabelGroup } = {}
	local byLabel: { [string]: LabelGroup } = {}
	for _, raw in shapes do
		local shape: string = raw
		if table.find(HitboxTypes.FieldsFor(shape :: any), field) then
			local overrides = SHAPE_LABELS[shape]
			local label = if overrides and overrides[field] then overrides[field] else defaultLabel
			local existing = byLabel[label]
			local group: LabelGroup = if existing then existing else { Label = label, Shapes = {} }
			if not existing then
				byLabel[label] = group
				table.insert(groups, group)
			end
			group.Shapes[shape] = true
		end
	end
	return groups
end

-- "Box  ·  W 4  H 5  L 5" -- a shape and the measurements it reads, for a folded heading.
local function describeShape(shape: string, read: (field: string) -> number): string
	local parts = { shape }
	for _, dimension in DIMENSIONS do
		if table.find(HitboxTypes.FieldsFor(shape :: any), dimension.Field) then
			table.insert(parts, `{dimension.Short} {string.format("%g", read(dimension.Field))}`)
		end
	end
	return table.concat(parts, "  ")
end

local SCALE_FACTORS = { 0.5, 0.8, 1.25, 2 }

-- Placement axes: label, and which component of the offset / rotation it is.
local OFFSET_AXES = {
	{ Axis = "X", Label = "Right" },
	{ Axis = "Y", Label = "Up" },
	{ Axis = "Z", Label = "Back  (forward is minus)" },
}

local function setOffset(move: Move, axis: string, value: number): ()
	local position = move.Offset.Position
	position = Vector3.new(
		if axis == "X" then value else position.X,
		if axis == "Y" then value else position.Y,
		if axis == "Z" then value else position.Z
	)
	move.Offset = MoveTypes.ComposeOffset(position, move.OffsetRotation)
end

-- Rotation is stored (pitch, yaw, roll) as the vector's (X, Y, Z) -- MoveTypes.ComposeOffset's order.
local function setRotation(move: Move, component: string, value: number): ()
	local rotation = move.OffsetRotation
	rotation = Vector3.new(
		if component == "Pitch" then value else rotation.X,
		if component == "Yaw" then value else rotation.Y,
		if component == "Roll" then value else rotation.Z
	)
	move.OffsetRotation = rotation
	move.Offset = MoveTypes.ComposeOffset(move.Offset.Position, rotation)
end

-- The projectile body's measurements, by HitboxTypes' field name. Size IS the body's Radius.
local function bodyField(field: string): string
	return if field == "Radius" then "Size" else field
end

-- The in-world tools at the end of PLACEMENT / SPAWN (see this file's header).
export type WorldTools = {
	ShowOnCharacter: Fusion.Value<boolean>,
	OnPlace: () -> (),
}

local function HitboxTab(
	scope: Scope,
	context: Fields.FormContext,
	visible: UsedAs<boolean>,
	world: WorldTools
): ScrollingFrame
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	local isProjectile = scope:Computed(function(use)
		local move = use(context.Draft)
		return move ~= nil and move.Projectile ~= nil
	end)
	local isMelee = scope:Computed(function(use)
		return not use(isProjectile)
	end)
	local customProjectile = scope:Computed(function(use)
		return use(isCustom) and use(isProjectile)
	end)
	local function both(a: UsedAs<boolean>, b: UsedAs<boolean>): Fusion.Computed<boolean>
		return scope:Computed(function(use): boolean
			return use(a) == true and use(b) == true
		end)
	end
	local function summary(describe: (Move) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then describe(move) else ""
		end)
	end

	-- A Computed that is true while the open move's projectile block satisfies `test`.
	local function whenSpec(test: ((Spec) -> boolean)?): Fusion.Computed<boolean>
		return scope:Computed(function(use): boolean
			local move = use(context.Draft)
			local spec = if move then move.Projectile else nil
			return spec ~= nil and (test == nil or test(spec))
		end)
	end

	-- One projectile number, bound to its field and bounded by ProjectileTypes.Limits.
	local function specNumber(
		field: string,
		label: string,
		unit: string?,
		steps: { number },
		decimals: number,
		layoutOrder: number,
		shown: UsedAs<boolean>?,
		hint: UsedAs<string>?
	): Frame
		return Fields.Number(scope, context, {
			Label = label,
			Unit = unit,
			Range = PROJECTILE_LIMITS[field],
			Steps = steps,
			Decimals = decimals,
			Hint = hint,
			LayoutOrder = layoutOrder,
			Visible = shown,
			Get = function(move: Move)
				return if move.Projectile then (move.Projectile :: any)[field] else PROJECTILE_LIMITS[field].Min
			end,
			Set = function(move: Move, value: number)
				if move.Projectile then
					(move.Projectile :: any)[field] = value
				end
			end,
		})
	end

	local function specChips(
		field: string,
		label: string,
		values: { any },
		layoutOrder: number,
		shown: UsedAs<boolean>?,
		hint: string?
	): Frame
		return Fields.Chips(scope, context, {
			Label = label,
			Options = optionsOf(values),
			Hint = hint,
			LayoutOrder = layoutOrder,
			Visible = shown,
			Get = function(move: Move)
				return if move.Projectile then (move.Projectile :: any)[field] else values[1]
			end,
			Set = function(move: Move, value: string)
				if move.Projectile then
					(move.Projectile :: any)[field] = value
				end
			end,
		})
	end

	local function specToggle(
		field: string,
		label: string,
		layoutOrder: number,
		shown: UsedAs<boolean>?,
		hint: string?
	): Frame
		return Fields.Toggle(scope, context, {
			Label = label,
			Hint = hint,
			LayoutOrder = layoutOrder,
			Visible = shown,
			Get = function(move: Move)
				return move.Projectile ~= nil and (move.Projectile :: any)[field] == true
			end,
			Set = function(move: Move, on: boolean)
				if move.Projectile then
					(move.Projectile :: any)[field] = on
				end
			end,
		})
	end

	-- A shape's measurements: one field per (dimension, label) group, shown while the open shape is in it.
	-- `shapes` is the shape list on offer; `shapeOf`, `read`, `write` and `range` bind them to the volume or the
	-- body.
	local function measurementFields(
		shapes: { any },
		shapeOf: (Move) -> string?,
		read: (Move, string) -> number,
		write: (Move, string, number) -> (),
		range: (string) -> { Min: number, Max: number },
		firstOrder: number
	): { Instance }
		local fields: { Instance } = {}
		local order = firstOrder
		for _, dimension in DIMENSIONS do
			for _, group in labelGroups(dimension.Field, dimension.Label, shapes) do
				order += 1
				table.insert(
					fields,
					Fields.Number(scope, context, {
						Label = group.Label,
						Unit = dimension.Unit,
						Range = range(dimension.Field),
						Steps = dimension.Steps,
						Decimals = if dimension.Field == "AngleDegrees" then 0 else 2,
						LayoutOrder = order,
						Visible = scope:Computed(function(use)
							local move = use(context.Draft)
							local shape = if move then shapeOf(move) else nil
							return shape ~= nil and group.Shapes[shape] == true
						end),
						Get = function(move)
							return read(move, dimension.Field)
						end,
						Set = function(move, value)
							write(move, dimension.Field, value)
						end,
					})
				)
			end
		end
		return fields
	end

	-- "Scale  x0.5 x0.8 x1.25 x2": every measurement the shape reads but its angle, clamped.
	local function scaleRow(
		shapeOf: (Move) -> string?,
		read: (Move, string) -> number,
		write: (Move, string, number) -> (),
		range: (string) -> { Min: number, Max: number },
		layoutOrder: number,
		shown: UsedAs<boolean>?
	): Frame
		local buttons = {}
		for _, factor in SCALE_FACTORS do
			table.insert(buttons, {
				Text = `x{factor}`,
				OnActivated = function()
					context.Edit(function(move)
						local shape = shapeOf(move)
						if not shape then
							return
						end
						for _, field in HitboxTypes.FieldsFor(shape :: any) do
							if field ~= "AngleDegrees" then
								local bounds = range(field)
								write(move, field, math.clamp(read(move, field) * factor, bounds.Min, bounds.Max))
							end
						end
					end)
				end,
			})
		end
		return Fields.ButtonRow(scope, {
			Label = "Scale",
			Buttons = buttons,
			Hint = Copy.Hints.ScaleVolume,
			Visible = shown,
			LayoutOrder = layoutOrder,
		})
	end

	-- The melee volume's bindings.
	local function volumeShape(move: Move): string?
		return move.Shape
	end
	local function volumeRead(move: Move, field: string): number
		return (move.Dimensions :: any)[field]
	end
	local function volumeWrite(move: Move, field: string, value: number): ()
		(move.Dimensions :: any)[field] = value
	end
	local function volumeRange(field: string): { Min: number, Max: number }
		return LIMITS.Dimensions[field]
	end

	-- The projectile body's.
	local function bodyShape(move: Move): string?
		return if move.Projectile then move.Projectile.Shape else nil
	end
	local function bodyRead(move: Move, field: string): number
		return if move.Projectile then (move.Projectile :: any)[bodyField(field)] else 0
	end
	local function bodyWrite(move: Move, field: string, value: number): ()
		if move.Projectile then
			(move.Projectile :: any)[bodyField(field)] = value
		end
	end
	local function bodyRange(field: string): { Min: number, Max: number }
		return PROJECTILE_LIMITS[bodyField(field)]
	end

	-- PLACEMENT and SPAWN: the same anchor, offset and rotation, read as a volume's place or a volley's.
	local function placementBody(projectile: boolean): { Instance }
		local fields: { Instance } = {
			Fields.Chips(scope, context, {
				Label = "Anchor",
				Options = ANCHOR_OPTIONS,
				Hint = if projectile then Copy.Hints.SpawnPoint else Copy.Hints.Anchor,
				LayoutOrder = 1,
				Visible = isCustom,
				Get = function(move)
					return move.AttachmentPart
				end,
				Set = function(move, value)
					move.AttachmentPart = value :: MoveTypes.MoveAttachmentPoint
				end,
			}),
			Fields.Fact(
				scope,
				"Anchor  (set by the weapon)",
				summary(function(move)
					return move.AttachmentPart
				end),
				2,
				context.IsDefault
			),
		}
		for index, axis in OFFSET_AXES do
			table.insert(
				fields,
				Fields.Number(scope, context, {
					Label = `Offset {axis.Axis}  ·  {axis.Label}`,
					Unit = "studs",
					Range = LIMITS.OffsetStuds,
					Steps = { 0.25, 1 },
					LayoutOrder = 2 + index,
					Get = function(move)
						return (move.Offset.Position :: any)[axis.Axis]
					end,
					Set = function(move, value)
						setOffset(move, axis.Axis, value)
					end,
				})
			)
		end
		if projectile then
			table.insert(
				fields,
				specChips(
					"SpawnDirection",
					"Fires",
					ProjectileTypes.SpawnDirections,
					10,
					nil,
					Copy.Hints.SpawnDirection
				)
			)
		end
		for index, component in { "Yaw", "Pitch", "Roll" } do
			table.insert(
				fields,
				Fields.Number(scope, context, {
					Label = component,
					Unit = "degrees",
					Range = LIMITS.RotationDegrees,
					Steps = { 5, 45 },
					Decimals = 0,
					LayoutOrder = 10 + index,
					Get = function(move)
						local rotation = move.OffsetRotation
						return if component == "Pitch"
							then rotation.X
							elseif component == "Yaw" then rotation.Y
							else rotation.Z
					end,
					Set = function(move, value)
						setRotation(move, component, value)
					end,
				})
			)
		end
		table.insert(
			fields,
			Button(scope, {
				Text = "Place in world",
				Variant = "Secondary",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				LayoutOrder = 20,
				OnActivated = world.OnPlace,
			})
		)
		table.insert(
			fields,
			Toggle(scope, {
				Label = "Show on my character",
				Hint = "Draws the volume where the engine anchors it, live -- only you see it.",
				Value = world.ShowOnCharacter,
				LayoutOrder = 21,
				OnChanged = function(on: boolean)
					world.ShowOnCharacter:set(on)
				end,
			})
		)
		return fields
	end
	local function placementSummary(move: Move): string
		local position = move.Offset.Position
		return string.format("%s  ·  %g, %g, %g", move.AttachmentPart, position.X, position.Y, position.Z)
	end

	local children: { Instance } = {
		-- MELEE ---------------------------------------------------------------------------------------------
		Fields.Section(scope, {
			Title = "VOLUME",
			Summary = summary(function(move)
				return describeShape(move.Shape, function(field)
					return volumeRead(move, field)
				end)
			end),
			LayoutOrder = 1,
			Visible = isMelee,
			Build = function()
				local fields: { Instance } = {
					Fields.ActionChips(scope, context, {
						Label = "Start from",
						Options = VOLUME_PRESET_OPTIONS,
						Hint = Copy.Hints.ShapePresets,
						LayoutOrder = 1,
						Visible = isCustom,
						Apply = function(move, id)
							local preset = HitboxTypes.PresetById(id)
							if not preset then
								return
							end
							move.Shape = preset.Shape :: MoveTypes.MoveShape
							for field, value in preset.Dimensions do
								(move.Dimensions :: any)[field] = value
							end
							setOffset(move, "Z", preset.OffsetZ)
						end,
					}),
					Fields.Chips(scope, context, {
						Label = "Shape",
						Options = SHAPE_OPTIONS,
						LayoutOrder = 2,
						Get = function(move)
							return move.Shape
						end,
						Set = function(move, value)
							move.Shape = value :: MoveTypes.MoveShape
						end,
					}),
					scaleRow(volumeShape, volumeRead, volumeWrite, volumeRange, 100),
				}
				for _, field in
					measurementFields(MoveTypes.Shapes, volumeShape, volumeRead, volumeWrite, volumeRange, 10)
				do
					table.insert(fields, field)
				end
				return fields
			end,
		}),
		Fields.Section(scope, {
			Title = "PLACEMENT",
			Summary = summary(placementSummary),
			LayoutOrder = 2,
			Visible = isMelee,
			Build = function()
				return placementBody(false)
			end,
		}),
		Fields.Section(scope, {
			Title = "TARGETS",
			Summary = summary(function(move)
				return if move.MaxTargets then `at most {move.MaxTargets}` else "any number"
			end),
			LayoutOrder = 3,
			Visible = isMelee,
			Build = function()
				return {
					Fields.Toggle(scope, context, {
						Label = "Limit targets per swing",
						LayoutOrder = 1,
						Hint = Copy.Hints.MaxTargets,
						Get = function(move)
							return move.MaxTargets ~= nil
						end,
						Set = function(move, on)
							move.MaxTargets = if on then 1 else nil
						end,
					}),
					Fields.Number(scope, context, {
						Label = "Max targets",
						Range = LIMITS.MaxTargets,
						Steps = { 1 },
						Decimals = 0,
						LayoutOrder = 2,
						Visible = scope:Computed(function(use)
							local move = use(context.Draft)
							return move ~= nil and move.MaxTargets ~= nil
						end),
						Get = function(move)
							return move.MaxTargets or 1
						end,
						Set = function(move, value)
							move.MaxTargets = math.floor(value + 0.5)
						end,
					}),
				}
			end,
		}),

		-- PROJECTILE ----------------------------------------------------------------------------------------
		Fields.Section(scope, {
			Title = "BODY",
			Summary = summary(function(move)
				local spec = move.Projectile
				return if spec
					then describeShape(spec.Shape, function(field)
						return bodyRead(move, field)
					end)
					else ""
			end),
			LayoutOrder = 10,
			Visible = customProjectile,
			Build = function()
				local fields: { Instance } = {
					Fields.ActionChips(scope, context, {
						Label = "Start from",
						Options = BODY_PRESET_OPTIONS,
						Hint = Copy.Hints.BodyPresets,
						LayoutOrder = 1,
						Apply = function(move, id)
							local preset = ProjectileTypes.PresetById(id)
							if not preset or not move.Projectile then
								return
							end
							for field, value in preset.Values do
								(move.Projectile :: any)[field] = value
							end
						end,
					}),
					specChips("Shape", "Shape", ProjectileTypes.Shapes, 2, nil, Copy.Hints.ProjectileShape),
					scaleRow(bodyShape, bodyRead, bodyWrite, bodyRange, 100),
				}
				for _, field in measurementFields(ProjectileTypes.Shapes, bodyShape, bodyRead, bodyWrite, bodyRange, 10) do
					table.insert(fields, field)
				end
				return fields
			end,
		}),
		Fields.Section(scope, {
			Title = "VOLLEY",
			Summary = summary(function(move)
				local spec = move.Projectile
				if not spec then
					return ""
				end
				return if spec.SpreadPattern == "Single"
					then "one shot"
					else `{OPTION_TEXT[spec.SpreadPattern] or spec.SpreadPattern}  ·  {spec.Count} shots`
			end),
			LayoutOrder = 11,
			Visible = customProjectile,
			Build = function()
				return {
					specChips(
						"SpreadPattern",
						"Pattern",
						ProjectileTypes.SpreadPatterns,
						1,
						nil,
						Copy.Hints.SpreadPattern
					),
					specNumber(
						"Count",
						"Count",
						"shots",
						{ 1 },
						0,
						2,
						whenSpec(function(spec)
							return spec.SpreadPattern ~= "Single"
						end)
					),
					specNumber(
						"SpreadAngle",
						"Spread angle",
						"degrees",
						{ 5, 30 },
						0,
						3,
						whenSpec(function(spec)
							return spec.SpreadPattern == "Fan" or spec.SpreadPattern == "Radial"
						end),
						Copy.Hints.SpreadAngle
					),
					specNumber(
						"Spacing",
						"Spacing",
						"studs apart",
						{ 0.25, 1 },
						2,
						4,
						whenSpec(function(spec)
							return spec.SpreadPattern == "Horizontal" or spec.SpreadPattern == "Vertical"
						end)
					),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "FLIGHT",
			Summary = summary(function(move)
				local spec = move.Projectile
				return if spec
					then string.format(
						"%g studs/s  ·  %gs  ·  %g studs",
						spec.Speed,
						spec.LifetimeSeconds,
						spec.MaxRange
					)
					else ""
			end),
			LayoutOrder = 12,
			Visible = customProjectile,
			Build = function()
				return {
					specNumber("Speed", "Speed", "studs/s", { 5, 25 }, 0, 1),
					specNumber("LifetimeSeconds", "Lifetime", "seconds", { 0.1, 0.5 }, 2, 2),
					specNumber("MaxRange", "Max range", "studs", { 5, 50 }, 0, 3),
					specNumber("Gravity", "Gravity", "studs/s² down", { 1, 10 }, 1, 4, nil, Copy.Hints.Gravity),
					specNumber("Acceleration", "Acceleration", "studs/s² along its heading", { 1, 10 }, 1, 5),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "HOMING",
			Summary = summary(function(move)
				local spec = move.Projectile
				if not spec then
					return ""
				end
				return if spec.Homing then string.format("%g°/s turn", spec.HomingStrength) else "Off"
			end),
			LayoutOrder = 13,
			Visible = customProjectile,
			Build = function()
				local homes = whenSpec(function(spec)
					return spec.Homing
				end)
				-- Range, cone and selection also decide who "the target" is for a volley fired At the target.
				local targets = whenSpec(function(spec)
					return spec.Homing or spec.SpawnDirection == "Target"
				end)
				return {
					specToggle("Homing", "Homing", 1, nil, Copy.Hints.Homing),
					specNumber("HomingStrength", "Homing strength", "degrees/s turn", { 15, 90 }, 0, 2, homes),
					specNumber("HomingMaxAngle", "Max homing angle", "degrees off heading", { 5, 30 }, 0, 3, targets),
					specNumber("HomingRange", "Homing range", "studs", { 5, 25 }, 0, 4, targets),
					specChips(
						"TargetSelection",
						"Target selection",
						ProjectileTypes.TargetSelections,
						5,
						targets,
						Copy.Hints.TargetSelection
					),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "COLLISION",
			Summary = summary(function(move)
				local spec = move.Projectile
				if not spec then
					return ""
				end
				local line = `walls: {OPTION_TEXT[spec.CollisionBehavior] or spec.CollisionBehavior}`
				return if spec.Piercing then `{line}  ·  pierces {spec.MaxPierces}` else line
			end),
			LayoutOrder = 14,
			Visible = customProjectile,
			Build = function()
				return {
					specChips("CollisionBehavior", "On walls", ProjectileTypes.CollisionBehaviors, 1),
					specNumber(
						"MaxBounces",
						"Max bounces",
						nil,
						{ 1 },
						0,
						2,
						whenSpec(function(spec)
							return spec.CollisionBehavior == "Bounce"
						end)
					),
					specToggle("Piercing", "Piercing", 3, nil, Copy.Hints.Piercing),
					specNumber(
						"MaxPierces",
						"Max pierces",
						"targets passed through",
						{ 1 },
						0,
						4,
						whenSpec(function(spec)
							return spec.Piercing
						end)
					),
					specToggle("CanHitOwner", "Can hit its thrower", 5, nil, Copy.Hints.CanHitOwner),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "PARRY",
			Summary = summary(function(move)
				local spec = move.Projectile
				if not spec then
					return ""
				end
				local behavior = OPTION_TEXT[spec.ParryBehavior] or spec.ParryBehavior
				return if spec.ParryBehavior == "CannotParry"
					then behavior
					else `{behavior}  ·  {OPTION_TEXT[spec.ParryResponse] or spec.ParryResponse}`
			end),
			LayoutOrder = 15,
			Visible = customProjectile,
			Build = function()
				local parryable = whenSpec(function(spec)
					return spec.ParryBehavior ~= "CannotParry"
				end)
				local reflects = whenSpec(function(spec)
					return spec.ParryBehavior ~= "CannotParry" and spec.ParryResponse == "Reflect"
				end)
				return {
					specChips(
						"ParryBehavior",
						"Parry",
						ProjectileTypes.ParryBehaviors,
						1,
						nil,
						Copy.Hints.ParryBehavior
					),
					specChips(
						"ParryResponse",
						"When parried",
						ProjectileTypes.ParryResponses,
						2,
						parryable,
						Copy.Hints.ParryResponse
					),
					specChips(
						"ReflectionDirection",
						"Reflected toward",
						ProjectileTypes.ReflectionDirections,
						3,
						reflects
					),
					specNumber("ReflectedDamageMultiplier", "Reflected damage", "×", { 0.05, 0.25 }, 2, 4, reflects),
					specNumber("ReflectedSpeedMultiplier", "Reflected speed", "×", { 0.05, 0.25 }, 2, 5, reflects),
				}
			end,
		}),
		Fields.Section(scope, {
			Title = "SPAWN",
			Summary = summary(placementSummary),
			LayoutOrder = 16,
			Visible = both(isCustom, isProjectile),
			Build = function()
				return placementBody(true)
			end,
		}),
	}

	return Fields.Page(scope, "HitboxTab", visible, children)
end

return HitboxTab
