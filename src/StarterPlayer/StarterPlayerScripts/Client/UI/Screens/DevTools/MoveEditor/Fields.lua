--!strict
--[[
	MoveEditor/Fields.lua

	Owns: binding the shared form primitives (NumericField, Toggle, Dropdown, TextField, StatRow) to the
	open draft -- the one place a field learns how to read its value off a MoveDefinition and how to
	write an edit back. The tab modules are then just lists of `Fields.Number(...)` calls.

	EVERY EDIT GOES THROUGH ONE FUNCTION, the `Edit` a tab is handed: it clones the draft
	(MoveTypes.Clone), lets the field mutate the clone, and publishes it. A field never mutates the draft
	it was shown -- that object is also what the browser, the plots and the dirty check are reading, and
	mutating it in place would change their answers without telling any of them.

	TEXT COMMITS ON FOCUS LOST, numbers and toggles on change. A name typed character by character would
	otherwise send a Preview per keystroke and re-sort the browser under the cursor; a number dragged is
	already throttled by NumericField itself.

	Does not own: which fields exist or what they are called (the tab modules), the bounds (Constants
	.MoveEditor.Limits and the runtime tables it defers to), or the primitives' own look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local NumericFieldModule = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Move = MoveTypes.MoveDefinition

export type Edit = (mutate: (Move) -> ()) -> ()

-- What every tab is handed.
export type FormContext = {
	Draft: Fusion.Value<Move?>,
	-- Whether the open move is a Default (weapon-built) move -- the tabs hide what it may not change.
	IsDefault: UsedAs<boolean>,
	-- The server's entry for the open move, for the few inputs that act on a server-computed fact (the
	-- Timing tab's clip match). nil until the server has answered for a brand-new move.
	Entry: UsedAs<MoveEditorTypes.MoveEntry?>,
	Edit: Edit,
}

local Fields = {}

local STAT_ROW_HEIGHT = 24

type Range = { Min: number, Max: number }

export type NumberSpec = {
	Label: string,
	Get: (Move) -> number,
	Set: (Move, number) -> (),
	Range: Range,
	Steps: { number },
	Decimals: number?,
	Unit: string?,
	Hint: string?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

function Fields.Number(scope: Scope, context: FormContext, spec: NumberSpec): Frame
	return NumericFieldModule.Mount(scope, {
		Label = spec.Label,
		Value = scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then spec.Get(move) else spec.Range.Min
		end),
		Min = spec.Range.Min,
		Max = spec.Range.Max,
		Steps = spec.Steps,
		Decimals = spec.Decimals,
		Unit = spec.Unit,
		Hint = spec.Hint,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,
		OnChanged = function(value: number)
			context.Edit(function(move)
				spec.Set(move, value)
			end)
		end,
	})
end

export type ToggleSpec = {
	Label: string,
	Get: (Move) -> boolean,
	Set: (Move, boolean) -> (),
	Hint: string?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

function Fields.Toggle(scope: Scope, context: FormContext, spec: ToggleSpec): Frame
	return Toggle(scope, {
		Label = spec.Label,
		Value = scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then spec.Get(move) else false
		end),
		Hint = spec.Hint,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,
		OnChanged = function(value: boolean)
			context.Edit(function(move)
				spec.Set(move, value)
			end)
		end,
	})
end

export type ChoiceSpec = {
	Label: string,
	Options: { DropdownModule.DropdownOption },
	Get: (Move) -> string,
	Set: (Move, string) -> (),
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- Dropdown has no Visible of its own, so a conditional choice is wrapped in a holder that does.
function Fields.Choice(scope: Scope, context: FormContext, spec: ChoiceSpec): Frame
	return scope:New "Frame" {
		Name = `Choice_{spec.Label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,

		[Fusion.Children] = DropdownModule.Mount(scope, {
			Label = spec.Label,
			Options = spec.Options,
			Value = scope:Computed(function(use)
				local move = use(context.Draft)
				return if move then spec.Get(move) else ""
			end),
			OnChanged = function(value: string)
				context.Edit(function(move)
					spec.Set(move, value)
				end)
			end,
		}),
	} :: Frame
end

export type TextSpec = {
	Label: string,
	Get: (Move) -> string,
	Set: (Move, string) -> (),
	Placeholder: string?,
	MaxLength: number,
	Multiline: boolean?,
	Hint: string?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- A labelled text box that follows the draft while unfocused and commits on focus lost -- see this
-- file's header.
function Fields.Text(scope: Scope, context: FormContext, spec: TextSpec): Frame
	local text = scope:Value("")
	-- Re-seeded whenever the draft's value for this field changes from outside (a new selection, a
	-- revert, the server normalising what was typed). Typing only writes `text`, never the draft, so
	-- this never fights the cursor.
	scope
		:Observer(scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then spec.Get(move) else ""
		end))
		:onBind(function()
			local move = peek(context.Draft)
			text:set(if move then spec.Get(move) else "")
		end)

	local children: { Instance } = {
		Label(scope, {
			Text = spec.Label,
			Scale = "Body",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
			LayoutOrder = 1,
		}),
		TextField(scope, {
			Text = text,
			PlaceholderText = spec.Placeholder,
			MaxLength = spec.MaxLength,
			Multiline = spec.Multiline,
			Size = UDim2.new(1, 0, 0, if spec.Multiline then 72 else Tokens.Control.StepButtonSize),
			LayoutOrder = 2,
			OnFocusLost = function(value: string)
				local move = peek(context.Draft)
				if move and spec.Get(move) ~= value then
					context.Edit(function(target)
						spec.Set(target, value)
					end)
				end
			end,
		}),
	}
	if spec.Hint then
		table.insert(
			children,
			Label(scope, {
				Text = spec.Hint,
				Scale = "Detail",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 3,
			})
		)
	end

	return Stack.New(scope, {
		Name = `Text_{spec.Label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,
		Children = children,
	})
end

-- A read-only fact about the move, for what a Default move shows but may not change.
function Fields.Fact(
	scope: Scope,
	caption: string,
	value: UsedAs<string>,
	layoutOrder: number,
	visible: UsedAs<boolean>?
): Frame
	return StatRow(scope, {
		Caption = caption,
		Value = value,
		Size = UDim2.new(1, 0, 0, STAT_ROW_HEIGHT),
		LayoutOrder = layoutOrder,
		Visible = visible,
	})
end

-- A group's bronze heading.
function Fields.Heading(scope: Scope, text: string, layoutOrder: number, visible: UsedAs<boolean>?): Frame
	return SectionHeading(scope, {
		Text = text,
		LayoutOrder = layoutOrder,
		Visible = visible,
	})
end

-- One wrapped sentence of context under a heading.
function Fields.Prose(scope: Scope, text: UsedAs<string>, layoutOrder: number, visible: UsedAs<boolean>?): Frame
	return Label(scope, {
		Text = text,
		Scale = "Detail",
		Color = Tokens.Color.TextSecondary,
		Size = UDim2.fromScale(1, 0),
		AutoHeight = true,
		TextWrapped = true,
		LineHeight = Tokens.Leading.Prose,
		LayoutOrder = layoutOrder,
		Visible = visible,
	}) :: any
end

-- One tab's scrolling page. Every tab is mounted up front and toggles its own Visible, so a tab keeps
-- its scroll position across a switch (the same idiom Screens/Menus uses).
function Fields.Page(scope: Scope, name: string, visible: UsedAs<boolean>, children: { Instance }): ScrollingFrame
	local content: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.M),
		},
		scope:New "UIPadding" {
			-- Clears the scroll bar on the right, and lets the last field breathe above the band.
			PaddingRight = UDim.new(0, Tokens.Space.M),
			PaddingBottom = UDim.new(0, Tokens.Space.XL),
		},
	}
	for _, child in children do
		table.insert(content, child)
	end
	return ScrollArea(scope, {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		Visible = visible,
		Children = content,
	})
end

-- Two cells side by side, for fields that belong together (X beside Y). Each cell takes half.
function Fields.Pair(
	scope: Scope,
	layoutOrder: number,
	left: Instance,
	right: Instance,
	visible: UsedAs<boolean>?
): Frame
	local function cell(order: number, child: Instance): Frame
		return scope:New "Frame" {
			Name = "Cell",
			Size = UDim2.new(0.5, -Tokens.Space.M / 2, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			[Fusion.Children] = child,
		} :: Frame
	end
	return Stack.Row(scope, {
		Name = "Pair",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.M,
		AlignY = Enum.VerticalAlignment.Top,
		Visible = visible,
		LayoutOrder = layoutOrder,
		Children = { cell(1, left), cell(2, right) },
	})
end

return Fields
