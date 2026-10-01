--!strict
--[[
	MoveEditor/HitboxTab.lua

	Owns: the Hitbox tab -- how the move DELIVERS its hit. Its move type first (Melee or Projectile); for a
	melee move, the volume's shape and measurements, how many targets one swing may take; for a projectile
	move, the volley, how it flies, what meets it and what a parry does to it; for both, where it sits
	relative to its anchor (a melee volume's placement, a projectile's spawn point).

	THE MOVE TYPE IS THE PROJECTILE BLOCK. Choosing Projectile seeds MoveTypes' Projectile block from
	ProjectileTypes.Defaults (and drops a Grab, which a projectile move may not carry -- Validate refuses
	the pair); choosing Melee removes it. There is no second field to fall out of step with the block. The
	melee volume's own fields are kept while hidden, so switching back restores them.

	ONLY THE MEASUREMENTS THE SHAPE READS ARE SHOWN. HitboxTypes.FieldsFor is the engine's own statement
	of which fields each shape reads (a Cone reads Length and AngleDegrees, nothing else); a field the
	shape ignores is hidden rather than left editable, because an editable number that does nothing is
	the exact thing this rebuild exists to remove. Switching shape keeps the hidden values, so switching
	back restores them. The projectile groups follow the same rule: Spread angle only for a pattern that
	fans, Spacing only for one that lines up, Max bounces only when shots bounce, the reflection numbers
	only when a parry reflects.

	THE PROJECTILE GROUPS FOLD (Fields.Fold) -- PROJECTILE, MOVEMENT, COLLISION, PARRY -- because together
	they are long and an author works one at a time. VFX and SFX are not here: a projectile move plays its
	clip, trail and hit feedback through the same paths every move does.

	A Default move shows its anchor as a fact: the weapon decides it (Blade vs body box), not the stage.
	It is always melee, so it never shows the move type.

	PLACEMENT ends with the in-world tools -- "Place in world" (Place mode: drag the volume with handles
	on your own character) and "Show on my character" -- here, beside the offset and rotation fields they
	edit, rather than in the readout: they are a way of TYPING those numbers, by hand in the world. For a
	projectile they place its spawn sphere.
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

local SHAPE_OPTIONS = {}
for _, shape in MoveTypes.Shapes do
	table.insert(SHAPE_OPTIONS, { Value = shape, Text = shape })
end

local ANCHOR_OPTIONS = {
	{ Value = "Root", Text = "Root (the body)" },
	{ Value = "RightHand", Text = "Right hand" },
	{ Value = "LeftHand", Text = "Left hand" },
	{ Value = "Weapon", Text = "Weapon (its blade)" },
}

local MOVE_TYPE_OPTIONS = {
	{ Value = "Melee", Text = "Melee -- the volume rides the body" },
	{ Value = "Projectile", Text = "Projectile -- launches a volley" },
}

-- Display text for every projectile option, keyed by the option itself; the ORDER is ProjectileTypes'
-- own list, so an option added there is offered here with its raw name until it is given words.
local OPTION_TEXT: { [string]: string } = {
	Single = "Single -- one shot",
	Fan = "Fan -- spread across an arc",
	Horizontal = "Row -- side by side",
	Vertical = "Column -- stacked",
	Radial = "Ring -- around the aim",
	Facing = "Where the body faces",
	Anchor = "Where the anchor points",
	Target = "At the target",
	Destroy = "Destroy",
	Bounce = "Bounce off",
	Continue = "Pass through",
	Aim = "Closest to its heading",
	Nearest = "Nearest",
	ParryOne = "Parry one -- the shot parried",
	ParryAll = "Parry all -- the whole volley",
	CannotParry = "Cannot be parried -- blocked instead",
	ExistingParry = "Existing parry -- shot ends, thrower staggered",
	Reflect = "Reflect",
	Reverse = "Reverse direction",
	ToOwner = "Back at the thrower",
	ParrierFacing = "Where the parrier faces",
	Mirror = "Mirrored off the guard",
}

local function optionsOf(values: { string }): { { Value: string, Text: string } }
	local options = {}
	for _, value in values do
		table.insert(options, { Value = value, Text = OPTION_TEXT[value] or value })
	end
	return options
end

-- Per dimension: its label, unit and step sizes. The order is the order they are shown in.
local DIMENSIONS = {
	{ Field = "Width", Label = "Width", Unit = "studs", Steps = { 0.5, 2 } },
	{ Field = "Height", Label = "Height", Unit = "studs", Steps = { 0.5, 2 } },
	{ Field = "Length", Label = "Length", Unit = "studs", Steps = { 0.5, 2 } },
	{ Field = "Radius", Label = "Radius", Unit = "studs", Steps = { 0.25, 1 } },
	{ Field = "InnerRadius", Label = "Inner radius", Unit = "studs", Steps = { 0.25, 1 } },
	{ Field = "AngleDegrees", Label = "Angle", Unit = "degrees", Steps = { 5, 30 } },
}

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

-- The in-world tools at the end of PLACEMENT (see this file's header).
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
	local shapeFields = scope:Computed(function(use)
		local move = use(context.Draft)
		return if move then HitboxTypes.FieldsFor(move.Shape) else {}
	end)

	-- A Computed that is true while `gate` is and the open move's projectile block satisfies `test`.
	local function whenSpec(gate: UsedAs<boolean>, test: ((Spec) -> boolean)?): Fusion.Computed<boolean>
		return scope:Computed(function(use): boolean
			if not use(gate) then
				return false
			end
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
		shown: UsedAs<boolean>,
		hint: string?
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

	local function specChoice(
		field: string,
		label: string,
		values: { string },
		layoutOrder: number,
		shown: UsedAs<boolean>
	): Frame
		return Fields.Choice(scope, context, {
			Label = label,
			Options = optionsOf(values),
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
		shown: UsedAs<boolean>,
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

	local customProjectile = scope:Computed(function(use)
		return use(isCustom) and use(isProjectile)
	end)

	local children: { Instance } = {
		-- MOVE TYPE ---------------------------------------------------------------------------------
		Fields.Heading(scope, "MOVE TYPE", -3, isCustom),
		Fields.Choice(scope, context, {
			Label = "Move type",
			Options = MOVE_TYPE_OPTIONS,
			LayoutOrder = -2,
			Visible = isCustom,
			Get = function(move: Move)
				return if move.Projectile then "Projectile" else "Melee"
			end,
			Set = function(move: Move, value: string)
				if value == "Projectile" then
					if move.Projectile == nil then
						move.Projectile = ProjectileTypes.Defaults()
					end
					move.Grab = nil
				else
					move.Projectile = nil
				end
			end,
		}),
		Fields.Prose(scope, Copy.Hints.MoveType, -1, isCustom),

		-- VOLUME (melee) ------------------------------------------------------------------------------
		Fields.Heading(scope, "VOLUME", 1, isMelee),
		Fields.Choice(scope, context, {
			Label = "Shape",
			Options = SHAPE_OPTIONS,
			LayoutOrder = 2,
			Visible = isMelee,
			Get = function(move)
				return move.Shape
			end,
			Set = function(move, value)
				move.Shape = value :: MoveTypes.MoveShape
			end,
		}),
	}

	for index, dimension in DIMENSIONS do
		table.insert(
			children,
			Fields.Number(scope, context, {
				Label = dimension.Label,
				Unit = dimension.Unit,
				Range = LIMITS.Dimensions[dimension.Field],
				Steps = dimension.Steps,
				Decimals = if dimension.Field == "AngleDegrees" then 0 else 2,
				LayoutOrder = 2 + index,
				Visible = scope:Computed(function(use)
					return use(isMelee) and table.find(use(shapeFields), dimension.Field) ~= nil
				end),
				Get = function(move)
					return (move.Dimensions :: any)[dimension.Field]
				end,
				Set = function(move, value)
					(move.Dimensions :: any)[dimension.Field] = value
				end,
			})
		)
	end

	-- PROJECTILE (fold) ---------------------------------------------------------------------------------
	local projectileHeading, projectileOpen = Fields.Fold(scope, "PROJECTILE", 10, customProjectile)
	table.insert(children, projectileHeading)
	table.insert(
		children,
		specChoice("SpreadPattern", "Spread pattern", ProjectileTypes.SpreadPatterns, 11, whenSpec(projectileOpen))
	)
	table.insert(
		children,
		specNumber(
			"Count",
			"Count",
			"shots",
			{ 1 },
			0,
			12,
			whenSpec(projectileOpen, function(spec)
				return spec.SpreadPattern ~= "Single"
			end)
		)
	)
	table.insert(
		children,
		specNumber(
			"SpreadAngle",
			"Spread angle",
			"degrees",
			{ 5, 30 },
			0,
			13,
			whenSpec(projectileOpen, function(spec)
				return spec.SpreadPattern == "Fan" or spec.SpreadPattern == "Radial"
			end),
			Copy.Hints.SpreadAngle
		)
	)
	table.insert(
		children,
		specNumber(
			"Spacing",
			"Spacing",
			"studs apart",
			{ 0.25, 1 },
			2,
			14,
			whenSpec(projectileOpen, function(spec)
				return spec.SpreadPattern == "Horizontal" or spec.SpreadPattern == "Vertical"
			end)
		)
	)
	table.insert(children, specNumber("Speed", "Speed", "studs/s", { 5, 25 }, 0, 15, whenSpec(projectileOpen)))
	table.insert(
		children,
		specNumber("LifetimeSeconds", "Lifetime", "seconds", { 0.1, 0.5 }, 2, 16, whenSpec(projectileOpen))
	)
	table.insert(children, specNumber("MaxRange", "Max range", "studs", { 5, 50 }, 0, 17, whenSpec(projectileOpen)))
	table.insert(
		children,
		specNumber(
			"Size",
			"Size",
			"studs radius",
			{ 0.1, 0.5 },
			2,
			18,
			whenSpec(projectileOpen),
			Copy.Hints.ProjectileSize
		)
	)

	-- PLACEMENT (melee) / SPAWN (projectile) --------------------------------------------------------
	table.insert(children, Fields.Heading(scope, "PLACEMENT", 20, isMelee))
	table.insert(children, Fields.Heading(scope, "SPAWN", 20, isProjectile))
	table.insert(
		children,
		Fields.Choice(scope, context, {
			Label = "Anchor",
			Options = ANCHOR_OPTIONS,
			LayoutOrder = 21,
			Visible = isCustom,
			Get = function(move)
				return move.AttachmentPart
			end,
			Set = function(move, value)
				move.AttachmentPart = value :: MoveTypes.MoveAttachmentPoint
			end,
		})
	)
	table.insert(
		children,
		Fields.Prose(
			scope,
			scope:Computed(function(use)
				return if use(isProjectile) then Copy.Hints.SpawnPoint else Copy.Hints.Anchor
			end),
			22,
			isCustom
		)
	)
	table.insert(
		children,
		Fields.Fact(
			scope,
			"Anchor  (set by the weapon)",
			scope:Computed(function(use)
				local move = use(context.Draft)
				return if move then move.AttachmentPart else "-"
			end),
			23,
			context.IsDefault
		)
	)

	for index, axis in OFFSET_AXES do
		table.insert(
			children,
			Fields.Number(scope, context, {
				Label = `Offset {axis.Axis}  ·  {axis.Label}`,
				Unit = "studs",
				Range = LIMITS.OffsetStuds,
				Steps = { 0.25, 1 },
				LayoutOrder = 23 + index,
				Get = function(move)
					return (move.Offset.Position :: any)[axis.Axis]
				end,
				Set = function(move, value)
					setOffset(move, axis.Axis, value)
				end,
			})
		)
	end

	table.insert(children, specChoice("SpawnDirection", "Fires", ProjectileTypes.SpawnDirections, 30, customProjectile))
	for index, component in { "Yaw", "Pitch", "Roll" } do
		table.insert(
			children,
			Fields.Number(scope, context, {
				Label = component,
				Unit = "degrees",
				Range = LIMITS.RotationDegrees,
				Steps = { 5, 45 },
				Decimals = 0,
				LayoutOrder = 30 + index,
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
		children,
		Button(scope, {
			Text = "Place in world",
			Variant = "Secondary",
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			LayoutOrder = 36,
			OnActivated = world.OnPlace,
		})
	)
	table.insert(
		children,
		Toggle(scope, {
			Label = "Show on my character",
			Hint = "Draws the volume where the engine anchors it, live -- only you see it.",
			Value = world.ShowOnCharacter,
			LayoutOrder = 37,
			OnChanged = function(on: boolean)
				world.ShowOnCharacter:set(on)
			end,
		})
	)

	-- TARGETS (melee) -------------------------------------------------------------------------------
	table.insert(children, Fields.Heading(scope, "TARGETS", 40, isMelee))
	table.insert(
		children,
		Fields.Toggle(scope, context, {
			Label = "Limit targets per swing",
			LayoutOrder = 41,
			Hint = Copy.Hints.MaxTargets,
			Visible = isMelee,
			Get = function(move)
				return move.MaxTargets ~= nil
			end,
			Set = function(move, on)
				move.MaxTargets = if on then 1 else nil
			end,
		})
	)
	table.insert(
		children,
		Fields.Number(scope, context, {
			Label = "Max targets",
			Range = LIMITS.MaxTargets,
			Steps = { 1 },
			Decimals = 0,
			LayoutOrder = 42,
			Visible = scope:Computed(function(use)
				local move = use(context.Draft)
				return move ~= nil and move.MaxTargets ~= nil and use(isMelee)
			end),
			Get = function(move)
				return move.MaxTargets or 1
			end,
			Set = function(move, value)
				move.MaxTargets = math.floor(value + 0.5)
			end,
		})
	)
	table.insert(
		children,
		Fields.Toggle(scope, context, {
			Label = "Lock movement while winding up",
			LayoutOrder = 43,
			Hint = Copy.Hints.LocksWindup,
			Visible = isCustom,
			Get = function(move)
				return move.LocksWindup == true
			end,
			Set = function(move, on)
				move.LocksWindup = on
			end,
		})
	)
	table.insert(
		children,
		Fields.Toggle(scope, context, {
			Label = "Lock movement while active",
			LayoutOrder = 44,
			Hint = Copy.Hints.LocksMovement,
			Visible = isCustom,
			Get = function(move)
				return move.LocksMovement
			end,
			Set = function(move, on)
				move.LocksMovement = on
			end,
		})
	)

	-- MOVEMENT (fold) -----------------------------------------------------------------------------------
	local movementHeading, movementOpen = Fields.Fold(scope, "MOVEMENT", 50, customProjectile)
	table.insert(children, movementHeading)
	table.insert(
		children,
		specNumber("Gravity", "Gravity", "studs/s² down", { 1, 10 }, 1, 51, whenSpec(movementOpen), Copy.Hints.Gravity)
	)
	table.insert(
		children,
		specNumber(
			"Acceleration",
			"Acceleration",
			"studs/s² along its heading",
			{ 1, 10 },
			1,
			52,
			whenSpec(movementOpen)
		)
	)
	table.insert(children, specToggle("Homing", "Homing", 53, whenSpec(movementOpen), Copy.Hints.Homing))
	local homes = whenSpec(movementOpen, function(spec)
		return spec.Homing
	end)
	-- Range, cone and selection also decide who "the target" is for a volley fired At the target.
	local targets = whenSpec(movementOpen, function(spec)
		return spec.Homing or spec.SpawnDirection == "Target"
	end)
	table.insert(children, specNumber("HomingStrength", "Homing strength", "degrees/s turn", { 15, 90 }, 0, 54, homes))
	table.insert(
		children,
		specNumber("HomingMaxAngle", "Max homing angle", "degrees off heading", { 5, 30 }, 0, 55, targets)
	)
	table.insert(children, specNumber("HomingRange", "Homing range", "studs", { 5, 25 }, 0, 56, targets))
	table.insert(
		children,
		specChoice("TargetSelection", "Target selection", ProjectileTypes.TargetSelections, 57, targets)
	)

	-- COLLISION (fold) ----------------------------------------------------------------------------------
	local collisionHeading, collisionOpen = Fields.Fold(scope, "COLLISION", 60, customProjectile)
	table.insert(children, collisionHeading)
	table.insert(
		children,
		specChoice("CollisionBehavior", "On walls", ProjectileTypes.CollisionBehaviors, 61, whenSpec(collisionOpen))
	)
	table.insert(
		children,
		specNumber(
			"MaxBounces",
			"Max bounces",
			nil,
			{ 1 },
			0,
			62,
			whenSpec(collisionOpen, function(spec)
				return spec.CollisionBehavior == "Bounce"
			end)
		)
	)
	table.insert(children, specToggle("Piercing", "Piercing", 63, whenSpec(collisionOpen), Copy.Hints.Piercing))
	table.insert(
		children,
		specNumber(
			"MaxPierces",
			"Max pierces",
			"targets passed through",
			{ 1 },
			0,
			64,
			whenSpec(collisionOpen, function(spec)
				return spec.Piercing
			end)
		)
	)
	table.insert(
		children,
		specToggle("CanHitOwner", "Can hit its thrower", 65, whenSpec(collisionOpen), Copy.Hints.CanHitOwner)
	)

	-- PARRY (fold) --------------------------------------------------------------------------------------
	local parryHeading, parryOpen = Fields.Fold(scope, "PARRY", 70, customProjectile)
	table.insert(children, parryHeading)
	table.insert(
		children,
		specChoice("ParryBehavior", "Parry behavior", ProjectileTypes.ParryBehaviors, 71, whenSpec(parryOpen))
	)
	local parryable = whenSpec(parryOpen, function(spec)
		return spec.ParryBehavior ~= "CannotParry"
	end)
	table.insert(children, specChoice("ParryResponse", "When parried", ProjectileTypes.ParryResponses, 72, parryable))
	table.insert(children, Fields.Prose(scope, Copy.Hints.ParryResponse, 73, parryable))
	local reflects = whenSpec(parryOpen, function(spec)
		return spec.ParryBehavior ~= "CannotParry" and spec.ParryResponse == "Reflect"
	end)
	table.insert(
		children,
		specChoice("ReflectionDirection", "Reflection direction", ProjectileTypes.ReflectionDirections, 74, reflects)
	)
	table.insert(
		children,
		specNumber("ReflectedDamageMultiplier", "Reflected damage", "×", { 0.05, 0.25 }, 2, 75, reflects)
	)
	table.insert(
		children,
		specNumber("ReflectedSpeedMultiplier", "Reflected speed", "×", { 0.05, 0.25 }, 2, 76, reflects)
	)

	return Fields.Page(scope, "HitboxTab", visible, children)
end

return HitboxTab
