--!strict
--[[
	HitboxEditor.lua

	Owns: the Move Editor's Hitbox section content -- the shape picker, the shape's own description,
	and the measurement fields that shape actually uses.

	The whole problem this file solves is that twelve shapes read twelve different subsets of the
	eight Dimensions fields, and the panel has to stay reactive while an author flips between them.
	Two ways to do that: re-mount the field list on every shape change, or mount all eight once and
	drive their visibility and ORDER off the current shape. This does the latter, for the same
	reasons the rest of this screen already prefers Visible-toggling to re-mounting -- a re-mount
	drops focus mid-edit (fatal now that NumericField supports typed entry) and discards each field's
	own local state -- with one addition: LayoutOrder is reactive too, so each field also takes the
	position HitboxShapes.FieldsFor lists it in for the CURRENT shape, rather than every shape being
	stuck with one global field order that reads wrong for most of them.

	Nothing here enumerates shapes or their fields: the picker's options, each shape's description,
	which fields it uses, their order, and every field's own Min/Max/Steps/Decimals all come from
	Shared/HitboxShapes.lua -- the same module the server resolves hits with and the preview draws
	from. Adding a thirteenth shape adds nothing to this file.

	Does not own: the offset/rotation fields (PropertyEditor.lua's own Offset section), the preview
	rendering (PreviewViewport.lua), or any validation -- MoveRegistryManager.Validate re-clamps
	every value server-side against the exact same HitboxShapes bounds these fields are built from.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Dropdown = require(script.Parent.Parent.Parent.Components.Dropdown)
local NumericField = require(script.Parent.Parent.Parent.Components.NumericField)
local DraftBinding = require(script.Parent.DraftBinding)

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveDefinition = MoveTypes.MoveDefinition
type DraftContext = DraftBinding.DraftContext

-- LayoutOrder parked on any field the current shape doesn't use. Above every real slot, so a hidden
-- field can never wedge itself between two visible ones if a layout pass runs while it's still
-- collapsing.
local UNUSED_FIELD_ORDER = 99

local HitboxEditorModule = {}

-- Returns the section's content children, not a wrapping panel -- PropertyEditor.lua's own
-- sectionContent helper supplies the Section/card chrome, exactly as it does for the sections it
-- still builds inline.
function HitboxEditorModule.Build(scope: Scope, context: DraftContext): { Instance }
	local currentShape = DraftBinding.Field(context, scope, function(draft): string
		return draft.Shape
	end, "Box")

	local shapeOptions: { { Value: string, Text: string } } = {}
	for _, spec in ipairs(HitboxShapes.ListShapes()) do
		table.insert(shapeOptions, { Value = spec.Id, Text = spec.DisplayName })
	end

	local children: { Instance } = {
		Dropdown.Mount(scope, {
			Label = "Shape",
			Options = shapeOptions,
			Value = currentShape,
			LayoutOrder = 3,
			OnChanged = function(newShape: string)
				if not HitboxShapes.IsShapeId(newShape) then
					return
				end
				local shape = newShape :: HitboxShapes.ShapeId
				DraftBinding.Apply(context, function(draft)
					draft.Shape = shape
					-- Re-sanitized against the NEW shape rather than replaced with its defaults: the
					-- author's existing numbers are kept wherever they're still legal, so flipping
					-- Box -> Slice -> Box gets the original box back instead of a reset one. The one
					-- thing that does change is any value outside the new shape's own bounds, which
					-- HitboxShapes.Sanitize clamps (and its InnerRadius-inside-Radius invariant,
					-- which it repairs).
					draft.Dimensions = HitboxShapes.Sanitize(shape, draft.Dimensions)
					-- Kept in step with what MoveRegistryManager.Validate will derive server-side, so
					-- the local draft and the reconciled one agree the moment the round trip lands
					-- rather than the preview flickering between two geometries.
					if shape == "Box" then
						draft.Size =
							Vector3.new(draft.Dimensions.Width, draft.Dimensions.Height, draft.Dimensions.Depth)
						draft.Radius = nil
					elseif shape == "Sphere" then
						draft.Size = nil
						draft.Radius = draft.Dimensions.Radius
					else
						draft.Size = nil
						draft.Radius = nil
					end
				end)
			end,
		}),
		Label(scope, {
			Text = scope:Computed(function(use)
				return HitboxShapes.GetSpec(use(currentShape) :: HitboxShapes.ShapeId).Summary
			end),
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			TextWrapped = true,
			LineHeight = Tokens.Leading.Prose,
			-- Fixed height, DELIBERATELY, even though Label.lua now has an AutoHeight mode and the
			-- other seven wrapped-prose labels across this editor were swept onto it. This one's Text
			-- is a live Computed (the summary changes with the shape picker above), and an
			-- AutomaticSize.Y label whose text changes inside a ScrollingFrame with
			-- AutomaticCanvasSize makes the canvas re-measure and jump under the cursor. 44px is three
			-- lines at Detail size, which fits the longest Summary HitboxShapes authors -- so re-check
			-- this number if a longer one is ever added.
			Size = UDim2.new(1, 0, 0, 44),
			LayoutOrder = 4,
		}),
	}

	-- One NumericField per Dimensions field, all eight mounted once. Each one's Visible and
	-- LayoutOrder are Computed against the CURRENT shape's field list -- see this file's header.
	local fieldOrder: { HitboxShapes.DimensionField } = {
		"Width",
		"Height",
		"Depth",
		"Length",
		"Thickness",
		"Radius",
		"InnerRadius",
		"AngleDegrees",
	}

	for _, field in ipairs(fieldOrder) do
		local spec = HitboxShapes.GetFieldSpec(field)

		local isUsed = scope:Computed(function(use)
			return HitboxShapes.UsesField(use(currentShape) :: HitboxShapes.ShapeId, field)
		end)
		local layoutOrder = scope:Computed(function(use)
			local shape = use(currentShape) :: HitboxShapes.ShapeId
			for index, candidate in ipairs(HitboxShapes.FieldsFor(shape)) do
				if candidate == field then
					-- +10 keeps every dimension field below the picker and its description above.
					return index + 10
				end
			end
			return UNUSED_FIELD_ORDER
		end)

		table.insert(
			children,
			NumericField.Mount(scope, {
				Label = spec.Label,
				Unit = spec.Unit,
				Value = DraftBinding.Field(context, scope, function(draft): number
					return draft.Dimensions[field]
				end, spec.Default),
				Min = spec.Min,
				Max = spec.Max,
				Steps = spec.Steps,
				Decimals = spec.Decimals,
				Visible = isUsed,
				LayoutOrder = layoutOrder,
				OnChanged = function(value: number)
					DraftBinding.Apply(context, function(draft)
						-- Sub-table, so it is cloned before being written to -- see DraftBinding.Apply's
						-- own header for what mutating it in place would corrupt.
						local dimensions = table.clone(draft.Dimensions)
						dimensions[field] = value
						draft.Dimensions = HitboxShapes.Sanitize(draft.Shape, dimensions)
						-- Same "stay in step with what the server will derive" reasoning as the shape
						-- picker above.
						if draft.Shape == "Box" then
							draft.Size =
								Vector3.new(draft.Dimensions.Width, draft.Dimensions.Height, draft.Dimensions.Depth)
						elseif draft.Shape == "Sphere" then
							draft.Radius = draft.Dimensions.Radius
						end
					end)
				end,
			})
		)
	end

	return children
end

return HitboxEditorModule
