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

	SECTIONS AND LAZINESS (2026-10-01). A tab is a run of Fields.Section groups: a foldable bronze heading
	with a one-line SUMMARY of what is inside (so a folded group still answers "what is this set to"), whose
	body is BUILT the first time it is both visible and open -- not at mount. Fields.Lazy is the same idea
	for a whole page: init.lua mounts each tab inside one, so a tab nobody visits never builds its fields,
	and a realm's six effect slots cost nothing until the realm has six effects. Built once, a body is
	kept (toggling Visible), so a scroll position or a half-typed field survives a fold or a tab switch.

	CHIPS, NOT DROPDOWNS, for a short closed set an author picks by sight (the fifteen hitbox shapes, a
	realm's three, a spread pattern): every option is on screen, one press picks it, and nothing expands
	600px over the fields below. Dropdowns stay for the long lists (fifteen rule kinds). Segmented is the
	same chip, filling a row, for the one choice that reshapes the whole editor (the move type bar).

	CHANGED FIELDS (2026-10-07). Every bound field (Number, Toggle, Choice, Chips, Text, the pickers) reads its
	value off the draft AND off the context's Saved move with the same Get, and while the two differ a bronze
	dot sits in the gutter to its left. Pressing the dot writes the saved value back through the field's own
	Set -- one ordinary edit, so it previews and undoes like any other. There is no per-field "reset to
	DEFAULT" (NumericField's header says why: no single source of defaults); the SAVED move is a single
	source, which is what makes this one possible. A never-saved move has no Saved and shows no dots.

	HINTS ARE ON DEMAND (2026-10-07). A field's hint is still built under it, but drawn only while the form's
	"Show hints" switch is on (context.Hints). Otherwise the help strip under the form shows the hint of the
	one field under the pointer, the gamepad selection or the focused text box (context.RegisterHelp), so a
	page reads as its controls and the prose is one glance away.

	Does not own: which fields exist or what they are called (the tab modules), the bounds (Constants
	.MoveEditor.Limits and the runtime tables it defers to), or the primitives' own look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local ArmedButton = require(script.Parent.Parent.Parent.Parent.Components.ArmedButton)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local DropdownModule = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local NumericFieldModule = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local Selection = require(script.Parent.Parent.Parent.Parent.Components.Selection)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Parent.Parent.Components.TextField)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)

local Copy = require(script.Parent.Copy)

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
	-- The open move as it is SAVED (what a restart would load), or nil when it never was. Every bound field
	-- compares its own value against this one and marks itself when they differ (see CHANGED FIELDS).
	Saved: UsedAs<Move?>,
	-- Every move the editor knows, for the pickers that name another move by id.
	Entries: UsedAs<{ MoveEditorTypes.MoveEntry }>,
	-- The form's "Show hints" switch: true draws every field's hint under it; false leaves the hints to
	-- the help strip, which shows the one field under the pointer or the gamepad selection.
	Hints: UsedAs<boolean>,
	-- Registers `holder` (a field's outer frame) with the help strip: hovering it, selecting a control
	-- inside it or focusing a text box inside it shows `title` and `hint` there.
	RegisterHelp: (holder: GuiObject, title: string, hint: UsedAs<string>?) -> (),
	-- Plays an asset id on this client: "Sound" through a local Sound, "Animation" on your own character.
	PreviewAsset: (kind: string, id: string) -> (),
}

local Fields = {}

local STAT_ROW_HEIGHT = 24
-- SectionHeading's own height, so a fold heading sits exactly where a plain one would.
local FOLD_HEIGHT = 24

type Range = { Min: number, Max: number }

export type NumberSpec = {
	Label: string,
	Get: (Move) -> number,
	Set: (Move, number) -> (),
	Range: Range,
	Steps: { number },
	Decimals: number?,
	Unit: string?,
	-- May be a state object: one field can mean two things (a swing's Windup, a realm's) -- NumericField.Hint.
	Hint: UsedAs<string>?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- Changed fields ------------------------------------------------------------------------------------------

-- The gutter a field's changed-dot sits in, left of the field (Fields.Page pads its content by this much).
local GUTTER = 14
local DOT_SIZE = 6

local function sameValue(a: any, b: any): boolean
	if typeof(a) == "number" and typeof(b) == "number" then
		return math.abs(a - b) < 1e-4
	end
	return a == b
end

export type Tracking = {
	-- The help strip's title for this field.
	Title: string,
	Hint: UsedAs<string>?,
	-- The field's own read and write; nil for a field with no value of its own (it gets no dot).
	Get: ((Move) -> any)?,
	Set: ((Move, any) -> ())?,
	LayoutOrder: number?,
	Visible: UsedAs<boolean>?,
}

-- Wraps a built field in its holder: the changed-dot in the gutter and the help-strip registration (see
-- this file's header). The holder takes over the field's LayoutOrder and Visible, so the field keeps its own
-- conditions and the holder is what its parent lays out.
local function tracked(scope: Scope, context: FormContext, field: GuiObject, tracking: Tracking): Frame
	local children: { Instance } = { field }
	local get, set = tracking.Get, tracking.Set
	if get and set then
		local changed = scope:Computed(function(use): boolean
			local saved = use(context.Saved)
			local move = use(context.Draft)
			if saved == nil or move == nil then
				return false
			end
			return not sameValue(get(move), get(saved))
		end)
		local engagement = Selection.New(scope)
		local dot = scope:New "TextButton" {
			Name = "Changed",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromOffset(-GUTTER / 2, 2),
			Size = UDim2.fromOffset(GUTTER, 18),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			Visible = changed,
			ZIndex = 2,
			[Fusion.OnEvent "MouseEnter"] = engagement.OnPointerEnter,
			[Fusion.OnEvent "MouseLeave"] = engagement.OnPointerLeave,
			[Fusion.OnEvent "SelectionGained"] = engagement.OnSelectionGained,
			[Fusion.OnEvent "SelectionLost"] = engagement.OnSelectionLost,
			[Fusion.OnEvent "Activated"] = function()
				local saved = peek(context.Saved)
				if saved == nil then
					return
				end
				local value = get(saved)
				context.Edit(function(move)
					set(move, value)
				end)
			end,
			[Fusion.Children] = scope:New "Frame" {
				Name = "Dot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = scope:Computed(function(use)
					local size = if use(engagement.Active) then DOT_SIZE + 4 else DOT_SIZE
					return UDim2.fromOffset(size, size)
				end),
				BackgroundColor3 = Tokens.Color.AccentSecondary,
				BorderSizePixel = 0,
				[Fusion.Children] = scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
			},
		} :: TextButton
		table.insert(children, dot)
		context.RegisterHelp(dot, `{tracking.Title} -- changed`, Copy.Hints.ChangedDot)
	end
	local holder = scope:New "Frame" {
		Name = `Field_{tracking.Title}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = tracking.LayoutOrder,
		Visible = tracking.Visible,
		[Fusion.Children] = children,
	} :: Frame
	context.RegisterHelp(holder, tracking.Title, tracking.Hint)
	return holder
end
Fields.Tracked = tracked

-- Every Move Editor number is a COMPACT NumericField (2026-10-01): two lines instead of four, a full-row
-- slider, and a value snapped to the field's own Decimals -- see that component's header.
function Fields.Number(scope: Scope, context: FormContext, spec: NumberSpec): Frame
	return tracked(scope, context, Fields.RawNumber(scope, context, spec), {
		Title = spec.Label,
		Hint = spec.Hint,
		Get = spec.Get,
		Set = spec.Set :: any,
		LayoutOrder = spec.LayoutOrder,
		Visible = spec.Visible,
	})
end

-- The NumericField alone, untracked -- for a caller that tracks a group of them itself.
function Fields.RawNumber(scope: Scope, context: FormContext, spec: NumberSpec): Frame
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
		HintVisible = context.Hints,
		Compact = true,
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
	local toggle = Toggle(scope, {
		Label = spec.Label,
		Value = scope:Computed(function(use)
			local move = use(context.Draft)
			return if move then spec.Get(move) else false
		end),
		Hint = spec.Hint,
		HintVisible = context.Hints,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,
		OnChanged = function(value: boolean)
			context.Edit(function(move)
				spec.Set(move, value)
			end)
		end,
	})
	return tracked(scope, context, toggle, {
		Title = spec.Label,
		Hint = spec.Hint,
		Get = spec.Get,
		Set = spec.Set :: any,
		LayoutOrder = spec.LayoutOrder,
		Visible = spec.Visible,
	})
end

export type ChoiceSpec = {
	Label: string,
	Options: { DropdownModule.DropdownOption },
	Get: (Move) -> string,
	Set: (Move, string) -> (),
	-- Drawn under the dropdown while hints are shown, and on the help strip.
	Hint: UsedAs<string>?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- Dropdown has no Visible of its own; the tracking holder carries it.
function Fields.Choice(scope: Scope, context: FormContext, spec: ChoiceSpec): Frame
	local parts: { Instance } = {
		DropdownModule.Mount(scope, {
			Label = spec.Label,
			Options = spec.Options,
			LayoutOrder = 1,
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
	}
	if spec.Hint then
		table.insert(parts, Fields.Hint(scope, context, spec.Hint, 2))
	end
	local inner = Stack.New(scope, {
		Name = `Choice_{spec.Label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Children = parts,
	})
	return tracked(scope, context, inner, {
		Title = spec.Label,
		Hint = spec.Hint,
		Get = spec.Get,
		Set = spec.Set :: any,
		LayoutOrder = spec.LayoutOrder,
		Visible = spec.Visible,
	})
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
	-- A small button at the box's right end, handed what the box holds now (typed, not yet committed) --
	-- an asset's preview ("Play").
	Action: { Text: string, Run: (current: string) -> () }?,
	-- Extra rows under the box (a colour's palette, a category's suggestions), laid out with it.
	Extra: { Instance }?,
}

-- A hint line: drawn while the form's hints are shown (and `visible`, if given), and otherwise left to the
-- help strip -- see this file's header.
function Fields.Hint(
	scope: Scope,
	context: FormContext,
	text: UsedAs<string>,
	layoutOrder: number,
	visible: UsedAs<boolean>?
): Frame
	return Label(scope, {
		Text = text,
		Scale = "Detail",
		Color = Tokens.Color.TextSecondary,
		Size = UDim2.fromScale(1, 0),
		AutoHeight = true,
		TextWrapped = true,
		LineHeight = Tokens.Leading.Prose,
		LayoutOrder = layoutOrder,
		Visible = scope:Computed(function(use)
			return use(context.Hints) == true and (visible == nil or use(visible) == true)
		end),
	}) :: any
end

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
	}
	local boxHeight = if spec.Multiline then 72 else Tokens.Control.StepButtonSize
	local box = TextField(scope, {
		Text = text,
		PlaceholderText = spec.Placeholder,
		MaxLength = spec.MaxLength,
		Multiline = spec.Multiline,
		Size = UDim2.new(1, 0, 0, boxHeight),
		LayoutOrder = 1,
		OnFocusLost = function(value: string)
			local move = peek(context.Draft)
			if move and spec.Get(move) ~= value then
				context.Edit(function(target)
					spec.Set(target, value)
				end)
			end
		end,
	})
	local action = spec.Action
	if action then
		table.insert(
			children,
			Stack.Row(scope, {
				Name = "Box",
				Size = UDim2.new(1, 0, 0, boxHeight),
				Gap = Tokens.Space.XS,
				LayoutOrder = 2,
				Children = {
					Stack.Fill(scope, box),
					Button(scope, {
						Text = action.Text,
						Size = UDim2.new(0, 64, 1, 0),
						LayoutOrder = 2,
						OnActivated = function()
							action.Run(peek(text))
						end,
					}),
				},
			})
		)
	else
		box.LayoutOrder = 2
		table.insert(children, box)
	end
	for index, extra in spec.Extra or {} do
		(extra :: any).LayoutOrder = 2 + index
		table.insert(children, extra)
	end
	if spec.Hint then
		table.insert(children, Fields.Hint(scope, context, spec.Hint, 20))
	end

	local field = Stack.New(scope, {
		Name = `Text_{spec.Label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Children = children,
	})
	return tracked(scope, context, field, {
		Title = spec.Label,
		Hint = spec.Hint,
		Get = spec.Get,
		Set = spec.Set :: any,
		LayoutOrder = spec.LayoutOrder,
		Visible = spec.Visible,
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
			-- Clears the scroll bar on the right, and lets the last field breathe above the band. The left
			-- pad is the gutter each field's changed-dot sits in (see CHANGED FIELDS).
			PaddingLeft = UDim.new(0, GUTTER),
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

export type ArmedButtonSpec = {
	Idle: string,
	-- What the button says while armed ("Delete? Again").
	Armed: string,
	LayoutOrder: number,
	Size: UDim2?,
	Disabled: UsedAs<boolean>?,
	Visible: UsedAs<boolean>?,
	OnConfirm: () -> (),
}

-- A button for an irreversible action: the first press ARMS it (its text says so), a second press inside
-- Constants.MoveEditor.ConfirmWindowSeconds commits, and the window lapsing disarms it. The mechanism is
-- Components/ArmedButton (promoted out of here when the admin panel became its second caller); this
-- only fixes the window and the half-width default every Move Editor call site wants.
function Fields.ArmedButton(scope: Scope, spec: ArmedButtonSpec): Frame
	return ArmedButton(scope, {
		Idle = spec.Idle,
		Armed = spec.Armed,
		WindowSeconds = Constants.MoveEditor.ConfirmWindowSeconds,
		Size = spec.Size or UDim2.new(0.5, -Tokens.Space.S / 2, 0, Tokens.Control.StepButtonSize),
		LayoutOrder = spec.LayoutOrder,
		Disabled = spec.Disabled,
		Visible = spec.Visible,
		OnConfirm = spec.OnConfirm,
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

-- Laziness -------------------------------------------------------------------------------------------------

-- Calls `build` once, the first time `wanted` is true, and hands its result to `into`. The result is kept
-- from then on -- a body is never rebuilt, only shown and hidden -- see this file's header.
local function buildOnce(
	scope: Scope,
	wanted: Fusion.Computed<boolean>,
	build: () -> { Instance }
): Fusion.Value<{ Instance }>
	local content = scope:Value({} :: { Instance })
	local built = false
	scope:Observer(wanted):onBind(function()
		if built or not peek(wanted) then
			return
		end
		built = true
		content:set(build())
	end)
	return content
end

export type LazySpec = {
	Name: string,
	Visible: UsedAs<boolean>,
	-- Defaults to filling the parent (a page holder).
	Size: UDim2?,
	LayoutOrder: number?,
	Build: () -> { Instance },
}

-- A frame whose contents are built the first time it is shown. For a whole tab page (init.lua) or anything
-- else expensive that most sessions never open.
function Fields.Lazy(scope: Scope, spec: LazySpec): Frame
	local wanted = scope:Computed(function(use): boolean
		return use(spec.Visible)
	end)
	return scope:New "Frame" {
		Name = spec.Name,
		Size = spec.Size or UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = wanted,
		LayoutOrder = spec.LayoutOrder,
		[Fusion.Children] = buildOnce(scope, wanted, spec.Build),
	} :: Frame
end

-- A section heading's right-hand side: the fold state's fixed slot, and the share of the row the summary may
-- take (the bronze title keeps the rest).
local SECTION_STATE_WIDTH = 44
local SECTION_SUMMARY_SHARE = 0.68

export type SectionSpec = {
	Title: string,
	-- What the group is set to, at a glance, opposite the title ("Box  ·  4 x 5 x 5"). Shown folded or not.
	Summary: UsedAs<string>?,
	LayoutOrder: number,
	Visible: UsedAs<boolean>?,
	-- Starts folded: for a page of many optional groups, where an author opens the one they came for.
	StartClosed: boolean?,
	-- The fields. Called once, the first time the section is visible and open.
	Build: () -> { Instance },
}

-- A foldable, lazily built group of fields -- see this file's header. The fields inside keep their own
-- LayoutOrder (they are laid out in the section's body, not the page) and their own Visible conditions.
function Fields.Section(scope: Scope, spec: SectionSpec): Frame
	local open = scope:Value(spec.StartClosed ~= true)
	local engagement = Selection.New(scope)
	local visible: UsedAs<boolean> = if spec.Visible == nil then true else spec.Visible
	local wanted = scope:Computed(function(use): boolean
		return use(visible) == true and use(open) == true
	end)
	local summary = spec.Summary

	local headingParts: { Instance } = {
		SectionHeading(scope, {
			Text = spec.Title,
			Size = UDim2.fromScale(1, 1),
		}),
		-- The summary and the fold state are two labels, not one Note: a long summary truncates on its
		-- own and never pushes "Show" out of sight.
		Label(scope, {
			Text = if summary == nil then "" else summary,
			Scale = "NumeralSmall",
			Color = Tokens.Color.TextSecondary,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -SECTION_STATE_WIDTH, 0.5, 0),
			Size = UDim2.new(SECTION_SUMMARY_SHARE, -SECTION_STATE_WIDTH, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
		Label(scope, {
			Text = scope:Computed(function(use)
				return if use(open) then "Hide" else "Show"
			end),
			Scale = "NumeralSmall",
			Color = scope:Computed(function(use)
				return if use(engagement.Active) then Tokens.Color.TextPrimary else Tokens.Color.AccentSecondary
			end),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.new(0, SECTION_STATE_WIDTH - Tokens.Space.S, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	}
	local heading = scope:New "TextButton" {
		Name = "Heading",
		Size = UDim2.new(1, 0, 0, FOLD_HEIGHT),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = 1,

		[Fusion.OnEvent "SelectionGained"] = engagement.OnSelectionGained,
		[Fusion.OnEvent "SelectionLost"] = engagement.OnSelectionLost,
		[Fusion.OnEvent "MouseEnter"] = engagement.OnPointerEnter,
		[Fusion.OnEvent "MouseLeave"] = engagement.OnPointerLeave,
		[Fusion.OnEvent "Activated"] = function()
			open:set(not peek(open))
		end,

		[Fusion.Children] = headingParts,
	} :: TextButton

	local parts: { Instance } = {
		heading,
		Stack.New(scope, {
			Name = "Body",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.M,
			Visible = open,
			LayoutOrder = 2,
			Children = buildOnce(scope, wanted, spec.Build),
		}),
	}
	return Stack.New(scope, {
		Name = `Section_{spec.Title}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.S,
		Visible = visible,
		LayoutOrder = spec.LayoutOrder,
		Children = parts,
	})
end

-- Chips ---------------------------------------------------------------------------------------------------

export type Option = { Value: string, Text: string }

local CHIP_HEIGHT = 28
local CHIP_MIN_WIDTH = 52
-- An estimate of the chip font's average advance. A chip is sized from its text once, at mount (the text is
-- static); a few pixels of slack either way is the whole cost of not measuring.
local CHIP_CHAR_WIDTH = 7.4
local CHIP_PADDING = 22

local function chipWidth(text: string): number
	return math.max(CHIP_MIN_WIDTH, math.ceil(utf8.len(text) or #text) * CHIP_CHAR_WIDTH + CHIP_PADDING)
end

-- A labelled, wrapping run of chips. `selected` says which value is lit (nil lights none); `onPick` is told
-- the value pressed. With `describe`, the chip under the pointer (or the gamepad selection) says what it is
-- on a line under the row -- the preset rows' tooltip, kept in the flow rather than floating, so it can
-- never be clipped by the page or painted over by the next chip.
local function chipRow(
	scope: Scope,
	context: FormContext,
	label: string?,
	options: { Option },
	selected: Fusion.Computed<string>?,
	onPick: (string) -> (),
	hint: UsedAs<string>?,
	visible: UsedAs<boolean>?,
	layoutOrder: number,
	describe: { [string]: string }?
): Frame
	local hovered = scope:Value(nil :: string?)
	local chips: { Instance } = {}
	for index, option in options do
		local chip = Tab(scope, {
			Text = option.Text,
			Size = UDim2.fromOffset(chipWidth(option.Text), CHIP_HEIGHT),
			LayoutOrder = index,
			Selected = if selected
				then scope:Computed(function(use)
					return use(selected) == option.Value
				end)
				else false,
			OnActivated = function()
				onPick(option.Value)
			end,
		})
		if describe then
			local function enter()
				hovered:set(option.Value)
			end
			local function leave()
				if peek(hovered) == option.Value then
					hovered:set(nil)
				end
			end
			table.insert(scope, chip.MouseEnter:Connect(enter))
			table.insert(scope, chip.MouseLeave:Connect(leave))
			table.insert(scope, chip.SelectionGained:Connect(enter))
			table.insert(scope, chip.SelectionLost:Connect(leave))
		end
		table.insert(chips, chip)
	end

	local children: { Instance } = {}
	if label then
		table.insert(
			children,
			Label(scope, {
				Text = label,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
				LayoutOrder = 1,
			})
		)
	end
	table.insert(
		children,
		Stack.Row(scope, {
			Name = "Chips",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			Wraps = true,
			LayoutOrder = 2,
			Children = chips,
		})
	)
	if describe then
		table.insert(
			children,
			Label(scope, {
				Text = scope:Computed(function(use)
					local value = use(hovered)
					return if value then describe[value] or value else ""
				end),
				Scale = "Detail",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.fromScale(1, 0),
				AutoHeight = true,
				TextWrapped = true,
				LineHeight = Tokens.Leading.Prose,
				LayoutOrder = 3,
				Visible = scope:Computed(function(use)
					return use(hovered) ~= nil
				end),
			})
		)
	end
	if hint then
		table.insert(children, Fields.Hint(scope, context, hint, 4))
	end

	return Stack.New(scope, {
		Name = `Chips_{label or "Row"}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Visible = visible,
		LayoutOrder = layoutOrder,
		Children = children,
	})
end

export type ChipsSpec = {
	Label: string?,
	Options: { Option },
	Get: (Move) -> string,
	Set: (Move, string) -> (),
	Hint: UsedAs<string>?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- One choice from a short closed set, every option on screen -- see this file's header.
function Fields.Chips(scope: Scope, context: FormContext, spec: ChipsSpec): Frame
	local current = scope:Computed(function(use): string
		local move = use(context.Draft)
		return if move then spec.Get(move) else ""
	end)
	local row = chipRow(scope, context, spec.Label, spec.Options, current, function(value: string)
		if peek(current) == value then
			return
		end
		context.Edit(function(move)
			spec.Set(move, value)
		end)
	end, spec.Hint, nil, 1)
	return tracked(scope, context, row, {
		Title = spec.Label or "Choice",
		Hint = spec.Hint,
		Get = spec.Get,
		Set = spec.Set :: any,
		LayoutOrder = spec.LayoutOrder,
		Visible = spec.Visible,
	})
end

export type ActionChipsSpec = {
	Label: string?,
	Options: { Option },
	-- Applies the option pressed to the clone the edit hands it.
	Apply: (Move, string) -> (),
	Hint: UsedAs<string>?,
	-- What each option is, by value, shown under the row while the pointer is on its chip.
	Describe: { [string]: string }?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- A run of chips that each DO something rather than select something -- the "Start from" presets. Nothing
-- stays lit: a preset is a starting point an author then edits away from.
function Fields.ActionChips(scope: Scope, context: FormContext, spec: ActionChipsSpec): Frame
	local row = chipRow(scope, context, spec.Label, spec.Options, nil, function(value: string)
		context.Edit(function(move)
			spec.Apply(move, value)
		end)
	end, spec.Hint, spec.Visible, spec.LayoutOrder, spec.Describe)
	context.RegisterHelp(row, spec.Label or "Presets", spec.Hint)
	return row
end

export type SegmentedSpec = {
	Options: { Option },
	Value: UsedAs<string>,
	OnChanged: (string) -> (),
	LayoutOrder: number,
	Visible: UsedAs<boolean>?,
}

-- One choice that fills a row, its options sharing the width -- the move type bar (init.lua). Option text is
-- static (it is set in tracked caps, which reads it once).
function Fields.Segmented(scope: Scope, spec: SegmentedSpec): Frame
	local segments: { Instance } = {}
	for index, option in spec.Options do
		table.insert(
			segments,
			Stack.Fill(
				scope,
				Tab(scope, {
					Text = option.Text,
					TrackedCaps = true,
					Size = UDim2.fromScale(0, 1),
					LayoutOrder = index,
					Selected = scope:Computed(function(use)
						return use(spec.Value) == option.Value
					end),
					OnActivated = function()
						spec.OnChanged(option.Value)
					end,
				})
			)
		)
	end
	return Stack.Row(scope, {
		Name = "Segmented",
		Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
		Gap = Tokens.Space.XS,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,
		Children = segments,
	})
end

export type ButtonRowSpec = {
	Label: string,
	Buttons: { { Text: string, OnActivated: () -> () } },
	Hint: string?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

local ROW_BUTTON_WIDTH = 58

-- A caption and a run of small action buttons on one line ("Scale  x0.5 x0.8 x1.25 x2").
function Fields.ButtonRow(scope: Scope, context: FormContext, spec: ButtonRowSpec): Frame
	local cells: { Instance } = {
		Stack.Fill(
			scope,
			Label(scope, {
				Text = spec.Label,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.fromScale(0, 1),
				LayoutOrder = 0,
			})
		),
	}
	for index, entry in spec.Buttons do
		table.insert(
			cells,
			Button(scope, {
				Text = entry.Text,
				Size = UDim2.fromOffset(ROW_BUTTON_WIDTH, CHIP_HEIGHT),
				LayoutOrder = index,
				OnActivated = entry.OnActivated,
			})
		)
	end
	local row = Stack.Row(scope, {
		Name = "Buttons",
		Size = UDim2.new(1, 0, 0, CHIP_HEIGHT),
		Gap = Tokens.Space.XS,
		AlignY = Enum.VerticalAlignment.Center,
		LayoutOrder = 1,
		Children = cells,
	})
	local children: { Instance } = { row }
	if spec.Hint then
		table.insert(children, Fields.Hint(scope, context, spec.Hint, 2))
	end
	local built = Stack.New(scope, {
		Name = `ButtonRow_{spec.Label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Visible = spec.Visible,
		LayoutOrder = spec.LayoutOrder,
		Children = children,
	})
	context.RegisterHelp(built, spec.Label, spec.Hint)
	return built
end

-- A plain vertical group, for fields that must move or hide together inside a page or a section (a
-- dropdown and the hint under it; a list of slots). No heading: Fields.Section is the group with one.
function Fields.Pile(scope: Scope, layoutOrder: number, visible: UsedAs<boolean>?, children: { Instance }): Frame
	return Stack.New(scope, {
		Name = "Pile",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.M,
		Visible = visible,
		LayoutOrder = layoutOrder,
		Children = children,
	})
end

-- Option lists from a value list and optional display text per value. The values are any closed set of
-- strings (a list typed as a union of literals is not a `{ string }` to the checker, hence `any`).
function Fields.OptionsOf(values: { any }, text: { [string]: string }?): { Option }
	local result: { Option } = {}
	for _, raw in values do
		local value: string = raw
		table.insert(result, { Value = value, Text = if text and text[value] then text[value] else value })
	end
	return result
end

-- Pickers ------------------------------------------------------------------------------------------------

local PICKER_ROWS = 8

export type MovePickerSpec = {
	Label: string,
	-- The id the field holds; "" is "none".
	Get: (Move) -> string,
	Set: (Move, string) -> (),
	-- Which moves may be named (an art, a projectile move, a realm); nil offers every move.
	Accepts: ((MoveEditorTypes.MoveEntry) -> boolean)?,
	-- What "" means for this field, shown on the button and as the clear option ("The realm's own strike").
	BlankText: string?,
	Hint: UsedAs<string>?,
	Visible: UsedAs<boolean>?,
	LayoutOrder: number,
}

-- Names another move, picked from the move list rather than typed: a button saying which move it holds now,
-- which opens a search over every move the field accepts (never the open move itself). An id that names
-- nothing the editor knows is shown as that id, in the warning colour, so an old record's typo is visible.
function Fields.MovePicker(scope: Scope, context: FormContext, spec: MovePickerSpec): Frame
	local open = scope:Value(false)
	local query = scope:Value("")
	local blankText = spec.BlankText or "None"

	local function entryById(id: string): MoveEditorTypes.MoveEntry?
		for _, entry in peek(context.Entries) do
			if entry.Move.MoveId == id then
				return entry
			end
		end
		return nil
	end

	local current = scope:Computed(function(use): string
		local move = use(context.Draft)
		return if move then spec.Get(move) else ""
	end)
	local currentText = scope:Computed(function(use): string
		local id = use(current)
		if id == "" then
			return blankText
		end
		use(context.Entries)
		local entry = entryById(id)
		return if entry then `{entry.Move.DisplayName}   ·   {id}` else `{id}   ·   not found`
	end)
	local missing = scope:Computed(function(use): boolean
		local id = use(current)
		use(context.Entries)
		return id ~= "" and entryById(id) == nil
	end)

	local results = scope:Computed(function(use): { MoveEditorTypes.MoveEntry }
		if not use(open) then
			return {}
		end
		local needle = string.lower(use(query))
		local self = use(context.Draft)
		local selfId = if self then self.MoveId else ""
		local found: { MoveEditorTypes.MoveEntry } = {}
		for _, entry in use(context.Entries) do
			local move = entry.Move
			if move.MoveId == selfId or (spec.Accepts and not spec.Accepts(entry)) then
				continue
			end
			if
				needle == ""
				or string.find(string.lower(move.DisplayName), needle, 1, true)
				or string.find(string.lower(move.MoveId), needle, 1, true)
			then
				table.insert(found, entry)
				if #found >= PICKER_ROWS then
					break
				end
			end
		end
		return found
	end)

	local function pick(id: string): ()
		open:set(false)
		query:set("")
		if peek(current) == id then
			return
		end
		context.Edit(function(move)
			spec.Set(move, id)
		end)
	end

	local rows = scope:ForPairs(results, function(_use, inner: Scope, index: number, entry: MoveEditorTypes.MoveEntry)
		return index,
			Button(inner, {
				Text = `{entry.Move.DisplayName}   ·   {entry.Move.MoveId}   ·   {entry.Group}`,
				Size = UDim2.new(1, 0, 0, CHIP_HEIGHT),
				LayoutOrder = index,
				OnActivated = function()
					pick(entry.Move.MoveId)
				end,
			})
	end)
	local nothing = scope:Computed(function(use)
		return use(open) and #use(results) == 0
	end)

	local children: { Instance } = {
		Label(scope, {
			Text = spec.Label,
			Scale = "Body",
			Color = Tokens.Color.TextSecondary,
			Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
			LayoutOrder = 1,
		}),
		Stack.Row(scope, {
			Name = "Current",
			Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
			Gap = Tokens.Space.XS,
			LayoutOrder = 2,
			Children = {
				Stack.Fill(
					scope,
					Tab(scope, {
						Text = currentText,
						Selected = open,
						Size = UDim2.fromScale(0, 1),
						OnActivated = function()
							open:set(not peek(open))
						end,
					})
				),
				Button(scope, {
					Text = "Clear",
					Size = UDim2.new(0, 64, 1, 0),
					LayoutOrder = 2,
					Disabled = scope:Computed(function(use)
						return use(current) == ""
					end),
					OnActivated = function()
						pick("")
					end,
				}),
			},
		}),
		Label(scope, {
			Text = "That id names no move the editor knows -- pick one, or clear it.",
			Scale = "Detail",
			Color = Tokens.Color.Warning,
			Size = UDim2.fromScale(1, 0),
			AutoHeight = true,
			TextWrapped = true,
			LayoutOrder = 3,
			Visible = missing,
		}),
		Stack.New(scope, {
			Name = "Search",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Gap = Tokens.Space.XS,
			LayoutOrder = 4,
			Visible = open,
			Children = {
				TextField(scope, {
					Text = query,
					PlaceholderText = "Search by name or id",
					MaxLength = 40,
					Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
					LayoutOrder = 0,
				}),
				Button(scope, {
					Text = blankText,
					Size = UDim2.new(1, 0, 0, CHIP_HEIGHT),
					LayoutOrder = 1,
					OnActivated = function()
						pick("")
					end,
				}),
				Stack.New(scope, {
					Name = "Results",
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					Gap = Tokens.Space.XS,
					LayoutOrder = 2,
					Children = { rows :: any },
				}),
				Label(scope, {
					Text = "No move matches.",
					Scale = "Detail",
					Color = Tokens.Color.TextDisabled,
					Size = UDim2.new(1, 0, 0, CHIP_HEIGHT),
					LayoutOrder = 3,
					Visible = nothing,
				}),
			},
		}),
	}
	if spec.Hint then
		table.insert(children, Fields.Hint(scope, context, spec.Hint, 5))
	end

	local field = Stack.New(scope, {
		Name = `Picker_{spec.Label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Children = children,
	})
	return tracked(scope, context, field, {
		Title = spec.Label,
		Hint = spec.Hint,
		Get = spec.Get,
		Set = spec.Set :: any,
		LayoutOrder = spec.LayoutOrder,
		Visible = spec.Visible,
	})
end

-- A wrapping run of chips offering values a free-text field already holds elsewhere (a category other moves
-- use): pressing one sets it. `values` is live; the chip that matches the field's own value is lit. Meant
-- as a Fields.Text spec's Extra.
function Fields.Suggestions(
	scope: Scope,
	context: FormContext,
	values: UsedAs<{ string }>,
	get: (Move) -> string,
	set: (Move, string) -> ()
): Frame
	local current = scope:Computed(function(use): string
		local move = use(context.Draft)
		return if move then get(move) else ""
	end)
	local chips = scope:ForPairs(values, function(_use, inner: Scope, index: number, value: string)
		return index,
			Tab(inner, {
				Text = value,
				Size = UDim2.fromOffset(chipWidth(value), CHIP_HEIGHT - 4),
				LayoutOrder = index,
				Selected = inner:Computed(function(use)
					return use(current) == value
				end),
				OnActivated = function()
					if peek(current) ~= value then
						context.Edit(function(move)
							set(move, value)
						end)
					end
				end,
			})
	end)
	return Stack.Row(scope, {
		Name = "Suggestions",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Wraps = true,
		Visible = scope:Computed(function(use)
			return #use(values) > 0
		end),
		Children = { chips :: any },
	})
end

-- The palette a colour field offers beside its text box: the game's own accents and a few plain tones.
local PALETTE: { { Name: string, Hex: string } } = {
	{ Name = "White", Hex = "#FFFFFF" },
	{ Name = "Ash", Hex = "#9E96B0" },
	{ Name = "Void", Hex = "#141020" },
	{ Name = "Crimson", Hex = "#C43038" },
	{ Name = "Ember", Hex = "#E2643A" },
	{ Name = "Gold", Hex = "#C79522" },
	{ Name = "Bronze", Hex = "#C4A46E" },
	{ Name = "Jade", Hex = "#508870" },
	{ Name = "Frost", Hex = "#A3E0EB" },
	{ Name = "Azure", Hex = "#4A86E8" },
	{ Name = "Violet", Hex = "#9A88C8" },
	{ Name = "Magenta", Hex = "#B4489C" },
}
local SWATCH = 22

local function sameColor(a: Color3, b: Color3): boolean
	local function byte(x: number): number
		return math.floor(x * 255 + 0.5)
	end
	return byte(a.R) == byte(b.R) and byte(a.G) == byte(b.G) and byte(a.B) == byte(b.B)
end

-- "#RRGGBB" (or "RRGGBB") as a Color3, or nil for anything else -- blank, "None", a typo.
function Fields.ParseHex(text: string): Color3?
	local hex = string.match(text, "^%s*#?(%x%x%x%x%x%x)%s*$")
	if not hex then
		return nil
	end
	return Color3.fromRGB(
		tonumber(string.sub(hex, 1, 2), 16) :: number,
		tonumber(string.sub(hex, 3, 4), 16) :: number,
		tonumber(string.sub(hex, 5, 6), 16) :: number
	)
end

-- A colour field's Extra (see Fields.Text): a swatch of what the field holds now, then one press per palette
-- tone, then Default (blank) and -- where the field allows it -- None.
function Fields.Palette(
	scope: Scope,
	context: FormContext,
	get: (Move) -> string,
	set: (Move, string) -> (),
	allowNone: boolean
): Frame
	local current = scope:Computed(function(use): string
		local move = use(context.Draft)
		return if move then get(move) else ""
	end)
	local parsed = scope:Computed(function(use): Color3?
		return Fields.ParseHex(use(current))
	end)
	local function write(value: string)
		if peek(current) ~= value then
			context.Edit(function(move)
				set(move, value)
			end)
		end
	end

	local cells: { Instance } = {
		-- The swatch: the colour itself, or a word for "no colour of its own".
		scope:New "Frame" {
			Name = "Swatch",
			Size = UDim2.fromOffset(SWATCH * 2, SWATCH),
			LayoutOrder = 0,
			BackgroundColor3 = scope:Computed(function(use)
				return use(parsed) or Tokens.Color.Surface
			end),
			BorderSizePixel = 0,
			[Fusion.Children] = {
				scope:New "UIStroke" {
					Color = Tokens.Border.Lit.Color,
					Transparency = Tokens.Border.Lit.Transparency,
					Thickness = 1,
				},
				Label(scope, {
					Text = scope:Computed(function(use)
						if use(parsed) then
							return ""
						end
						local text = use(current)
						return if string.lower(text) == "none" then "none" elseif text == "" then "default" else "?"
					end),
					Scale = "NumeralSmall",
					Color = Tokens.Color.TextDisabled,
					Size = UDim2.fromScale(1, 1),
					TextXAlignment = Enum.TextXAlignment.Center,
				}),
			},
		},
	}
	for index, tone in PALETTE do
		local engagement = Selection.New(scope)
		local color = Fields.ParseHex(tone.Hex) :: Color3
		table.insert(
			cells,
			scope:New "TextButton" {
				Name = `Tone_{tone.Name}`,
				Size = UDim2.fromOffset(SWATCH, SWATCH),
				LayoutOrder = index,
				AutoButtonColor = false,
				Text = "",
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				[Fusion.OnEvent "MouseEnter"] = engagement.OnPointerEnter,
				[Fusion.OnEvent "MouseLeave"] = engagement.OnPointerLeave,
				[Fusion.OnEvent "SelectionGained"] = engagement.OnSelectionGained,
				[Fusion.OnEvent "SelectionLost"] = engagement.OnSelectionLost,
				[Fusion.OnEvent "Activated"] = function()
					write(tone.Hex)
				end,
				[Fusion.Children] = scope:New "UIStroke" {
					Color = Tokens.Color.TextPrimary,
					Thickness = scope:Computed(function(use)
						local held = use(parsed)
						local lit = held ~= nil and sameColor(held, color)
						return if lit then 2 elseif use(engagement.Active) then 1 else 0
					end),
				},
			}
		)
	end
	table.insert(
		cells,
		Tab(scope, {
			Text = "Default",
			Size = UDim2.fromOffset(chipWidth("Default"), SWATCH),
			LayoutOrder = 50,
			Selected = scope:Computed(function(use)
				return use(current) == ""
			end),
			OnActivated = function()
				write("")
			end,
		})
	)
	if allowNone then
		table.insert(
			cells,
			Tab(scope, {
				Text = "None",
				Size = UDim2.fromOffset(chipWidth("None"), SWATCH),
				LayoutOrder = 51,
				Selected = scope:Computed(function(use)
					return string.lower(use(current)) == "none"
				end),
				OnActivated = function()
					write("None")
				end,
			})
		)
	end
	return Stack.Row(scope, {
		Name = "Palette",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		Wraps = true,
		AlignY = Enum.VerticalAlignment.Center,
		Children = cells,
	})
end

return Fields
