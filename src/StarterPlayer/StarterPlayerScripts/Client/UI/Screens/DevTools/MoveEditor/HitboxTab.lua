--!strict
--[[
	MoveEditor/HitboxTab.lua

	Owns: the Hitbox tab -- the volume's shape and measurements, where it sits relative to its anchor,
	what it is anchored to, and how many targets one swing may take.

	ONLY THE MEASUREMENTS THE SHAPE READS ARE SHOWN. HitboxTypes.FieldsFor is the engine's own statement
	of which fields each shape reads (a Cone reads Length and AngleDegrees, nothing else); a field the
	shape ignores is hidden rather than left editable, because an editable number that does nothing is
	the exact thing this rebuild exists to remove. Switching shape keeps the hidden values, so switching
	back restores them.

	A Default move shows its anchor as a fact: the weapon decides it (Blade vs body box), not the stage.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Copy = require(script.Parent.Copy)
local Fields = require(script.Parent.Fields)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local LIMITS = Constants.MoveEditor.Limits

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

local function setOffset(move: MoveTypes.MoveDefinition, axis: string, value: number): ()
	local position = move.Offset.Position
	position = Vector3.new(
		if axis == "X" then value else position.X,
		if axis == "Y" then value else position.Y,
		if axis == "Z" then value else position.Z
	)
	move.Offset = MoveTypes.ComposeOffset(position, move.OffsetRotation)
end

-- Rotation is stored (pitch, yaw, roll) as the vector's (X, Y, Z) -- MoveTypes.ComposeOffset's order.
local function setRotation(move: MoveTypes.MoveDefinition, component: string, value: number): ()
	local rotation = move.OffsetRotation
	rotation = Vector3.new(
		if component == "Pitch" then value else rotation.X,
		if component == "Yaw" then value else rotation.Y,
		if component == "Roll" then value else rotation.Z
	)
	move.OffsetRotation = rotation
	move.Offset = MoveTypes.ComposeOffset(move.Offset.Position, rotation)
end

local function HitboxTab(scope: Scope, context: Fields.FormContext, visible: UsedAs<boolean>): ScrollingFrame
	local isCustom = scope:Computed(function(use)
		return not use(context.IsDefault)
	end)
	local shapeFields = scope:Computed(function(use)
		local move = use(context.Draft)
		return if move then HitboxTypes.FieldsFor(move.Shape) else {}
	end)

	local children: { Instance } = {
		Fields.Heading(scope, "VOLUME", 1),
		Fields.Choice(scope, context, {
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
					return table.find(use(shapeFields), dimension.Field) ~= nil
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

	table.insert(children, Fields.Heading(scope, "PLACEMENT", 20))
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
	table.insert(children, Fields.Prose(scope, Copy.Hints.Anchor, 22, isCustom))
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

	table.insert(children, Fields.Heading(scope, "TARGETS", 40))
	table.insert(
		children,
		Fields.Toggle(scope, context, {
			Label = "Limit targets per swing",
			LayoutOrder = 41,
			Hint = Copy.Hints.MaxTargets,
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
				return move ~= nil and move.MaxTargets ~= nil
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
			Label = "Lock movement while active",
			LayoutOrder = 43,
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

	return Fields.Page(scope, "HitboxTab", visible, children)
end

return HitboxTab
