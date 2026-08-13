--!strict
--[[
	NumericField.lua

	Owns: a labeled numeric row offering THREE independent ways to reach the same value, because a
	single input affordance is wrong for at least one of the three things authors actually do with
	these fields:

	  1. STEP buttons -- "-"/"+" at one or more magnitudes (e.g. both a coarse and a fine step,
	     "-1"/"-0.1" ... "+0.1"/"+1"). Right for nudging a value you are already close to.
	  2. TYPED ENTRY -- click the readout and it becomes a text box; type an exact number, press
	     Enter or click away, and it commits (clamped). Right for "I want exactly 12.5", which
	     stepping to is absurd and dragging to is impossible.
	  3. A CLICK BAR -- click anywhere along the track and it jumps straight to that point in the
	     Min..Max range. Right for exploring ("how big does this actually need to be?") where the
	     number matters less than landing roughly in the right zone fast. Click-only, not drag-to-
	     scrub -- see the track's own comment below for why continuous dragging was removed.

	All three write through the SAME commit path (clamped to Min/Max, then props.OnChanged), so no
	route can produce a value the others couldn't, and none of them can produce an out-of-range one.
	The bar is opt-out (Slider = false) for the handful of fields where jumping around the range is
	meaningless.

	Generalizes two pre-existing, near-identical shapes that were never unified: Stepper.lua's own
	single-Step clamp control (Attributes screen), and Screens/DevMenu/ContentArea.lua's hand-rolled
	hitboxTimingRow (a Label plus four step buttons at fixed +-0.1/+-0.01 deltas) -- both of those
	files' own headers flag this exact unification as a deliberately-deferred follow-up.

	Steps are given as POSITIVE magnitudes only (e.g. {0.01, 0.1}); this component renders a "-"
	button and a "+" button for each, largest magnitude outermost on both sides of the centered
	readout -- the same visual convention hitboxTimingRow already established (-0.1, -0.01, [value],
	+0.01, +0.1), just generalized to any list of magnitudes instead of exactly two.

	Does not disable a step button when it would clamp to the same value at a bound (unlike
	Stepper.lua's own canDecrement/canIncrement) -- Min/Max here are fixed per-field constants, not
	a live UsedAs<number> a caller can move mid-session the way the Attributes screen's race-
	dependent floor does, so the bound math Stepper.lua needs isn't load-bearing here; committing a
	clamped-to-the-same-value press is a harmless no-op.

	`Hint` (optional, additive) puts one or two sentences of explanation under the control -- the
	field-level counterpart to Section.lua's group-level `description`, added when the Move Editor's
	explanation pass found that its ~40 numeric fields had a name and a unit but nothing anywhere
	saying what any of them actually did.

	There is deliberately NO per-field "reset to default" affordance, though it is the obvious
	companion to a Hint. This codebase has no single source of truth for a field's default: they live
	in three already-divergent places (MoveEditorClient.defaultDraft, MoveRegistryManager's own
	server-side clamp/default tables which are not replicated, and each PropertyEditor `fieldValue`
	call's third argument, which is a DISPLAY fallback for "nothing selected" rather than an
	authoring default). A `Default: number?` prop would make every call site hand-type a fourth copy
	with nothing keeping the four in agreement. The default belongs in the Hint sentence instead
	("... Default 0.20s"), where it costs no state and cannot drift silently.

	The stepper+readout Row sits on Tokens.Wash.Inset -- that token's own comment already names "a
	stepper button's face" as one of its intended uses, so this is that use, not a new one -- with a
	thin Border.Standard outline, reading as one contained field control instead of three buttons and
	a label floating loose next to each other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Button = require(script.Parent.Button)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type NumericFieldProps = {
	Label: string,
	Value: UsedAs<number>,
	Min: number,
	Max: number,
	-- Positive magnitudes only -- see file header for the left/right button ordering this produces.
	-- An empty list renders no step buttons at all, which is the right shape for a field whose
	-- useful values span orders of magnitude (a slider plus typed entry, no meaningful nudge size).
	Steps: { number },
	-- Display precision (decimal places). Defaults to 2, wide enough for both a damage integer
	-- ("5.00" reads oddly but is still correct) and a sub-second timing value ("0.31").
	Decimals: number?,
	-- Optional short unit shown right-aligned on the label row ("studs", "degrees", "seconds").
	-- Purely a readout -- never parsed, never part of the committed value.
	Unit: string?,
	-- Defaults to true. Set false for a field where sweeping the full Min..Max range continuously
	-- has no meaning, so the track would just be a control that never gets used.
	Slider: boolean?,
	OnChanged: (newValue: number) -> (),
	LayoutOrder: UsedAs<number>?,
	-- Defaults to true. For a field that only applies under some other condition (Radius only when
	-- the shape is round, Movement's sub-fields only when a move actually grants a lunge) -- hides
	-- the row entirely rather than disabling it, since an inapplicable field has no value to show at
	-- all.
	Visible: UsedAs<boolean>?,
	-- One or two sentences under the whole control saying what this number MEANS and what moving it
	-- DOES -- the field-level counterpart to Section.lua's own group-level `description`. Wrapped,
	-- Detail scale, TextSecondary, at LayoutOrder 4 (below the slider).
	--
	-- nil renders NOTHING -- no empty row, no reserved height -- so every pre-existing call site is
	-- byte-for-byte unchanged. Static string rather than UsedAs<string>: a field's explanation is a
	-- fact about the field, not about its current value, so nothing here should ever be reactive.
	--
	-- Where the text itself lives is the caller's business, but the Move Editor keeps every one of
	-- its hints in Screens/MoveEditor/Copy.lua rather than inline, so the prose is editable in one
	-- place -- see that module's own header.
	--
	-- LAYOUT RULE: within a single horizontal row of these (PropertyEditor.lua's `numericRow`),
	-- either every field carries a Hint or none does. The row's cells are AutomaticSize.Y and
	-- top-aligned, so one hinted field beside an unhinted one leaves the short cell's control
	-- floating against a taller neighbour.
	Hint: string?,
}

-- Narrower than this file's original 44 -- a full NumericField (up to 4 step buttons + a value
-- readout) needs to fit inside a 2-column numericRow cell in PropertyEditor.lua's content pane, and
-- 44 left only a ~6px margin there (confirmed too tight in Studio -- buttons overlapped the next
-- field). 40 gives a ~32px margin instead while still fitting every step label this file renders
-- ("-0.01" being the longest).
local STEP_BUTTON_WIDTH = 40
local VALUE_WIDTH = 66
local TRACK_HEIGHT = 6
local HANDLE_SIZE = 12

local function formatValue(value: number, decimals: number): string
	return string.format("%." .. decimals .. "f", value)
end

local NumericFieldModule = {}

function NumericFieldModule.Mount(scope: Scope, props: NumericFieldProps): Frame
	local decimals = props.Decimals or 2
	local range = math.max(props.Max - props.Min, 1e-6)

	-- The single funnel every one of the three input routes writes through -- see file header.
	local function commit(candidate: number): ()
		if candidate ~= candidate then
			-- NaN, which only typed entry can produce (tonumber("nan")). Silently ignored rather
			-- than clamped: math.clamp would pass it straight through and hand the caller a NaN.
			return
		end
		props.OnChanged(math.clamp(candidate, props.Min, props.Max))
	end

	local valueText = scope:Computed(function(use)
		return formatValue(use(props.Value), decimals)
	end)

	--
	-- Typed entry. The readout and the text box are BOTH mounted up front and Visible-toggled --
	-- the same "mount both, toggle Visible" idiom used across this UI for a control with two
	-- presentations -- rather than created on demand, so entering and leaving edit mode can't drop
	-- focus mid-transition.
	--
	local isEditing = scope:Value(false)
	local editText = scope:Value("")

	local function beginEditing(): ()
		-- Seeded with the current value so the box opens showing what it is replacing, and a
		-- click-away with no typing commits the identical number rather than clearing the field.
		editText:set(formatValue(peek(props.Value), decimals))
		isEditing:set(true)
	end

	local function finishEditing(): ()
		isEditing:set(false)
		local typed = tonumber(peek(editText))
		if typed then
			commit(typed)
		end
		-- A non-numeric entry simply reverts: the readout re-renders from props.Value, which never
		-- changed. No error state, because there is nothing an author can do about it except type a
		-- number, which the reverted display already invites.
	end

	local valueReadout = scope:New "TextButton" {
		Name = "Value",
		Size = UDim2.fromOffset(VALUE_WIDTH, Tokens.Control.StepButtonSize),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = valueText,
		FontFace = Tokens.Type.NumeralLarge.Face,
		TextSize = Tokens.Type.NumeralLarge.Size,
		TextColor3 = Tokens.Color.AccentPrimaryBright,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 0, -- overwritten below, once the step count is known
		Visible = scope:Computed(function(use)
			return not use(isEditing)
		end),

		[OnEvent "Activated"] = beginEditing,
	} :: TextButton

	local valueInput = scope:New "TextBox" {
		Name = "ValueInput",
		Size = UDim2.fromOffset(VALUE_WIDTH, Tokens.Control.StepButtonSize),
		BackgroundColor3 = Tokens.Color.Surface,
		BorderSizePixel = 0,
		Text = editText,
		FontFace = Tokens.Type.NumeralLarge.Face,
		TextSize = Tokens.Type.NumeralLarge.Size,
		TextColor3 = Tokens.Color.TextPrimary,
		TextXAlignment = Enum.TextXAlignment.Center,
		-- Typing replaces rather than appends: an author clicking a number to change it almost never
		-- wants to edit its digits in place.
		ClearTextOnFocus = true,
		LayoutOrder = 0, -- overwritten below, alongside valueReadout's
		Visible = isEditing,

		[OnChange "Text"] = function(newText: string)
			editText:set(newText)
		end,
		-- Covers Enter, Tab, and clicking away alike -- Roblox fires FocusLost for all three, so
		-- there is no separate "submitted" path to keep in sync with this one.
		[OnEvent "FocusLost"] = function()
			finishEditing()
		end,

		[Children] = {
			scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			scope:New "UIStroke" { Color = Tokens.Color.AccentPrimary, Thickness = 1 },
		},
	} :: TextBox

	-- Roblox does not focus a TextBox that was Visible = false at the moment CaptureFocus is called,
	-- and the Visible flip above only lands on the next render step -- so focus is deferred by one
	-- Observer tick rather than requested inline in beginEditing.
	scope:Observer(isEditing):onChange(function()
		if peek(isEditing) then
			valueInput:CaptureFocus()
		end
	end)

	local function stepButton(delta: number, order: number): TextButton
		local sign = if delta < 0 then "-" else "+"
		return Button(scope, {
			Text = sign .. formatValue(math.abs(delta), decimals),
			Size = UDim2.fromOffset(STEP_BUTTON_WIDTH, Tokens.Control.StepButtonSize),
			LayoutOrder = order,
			OnActivated = function()
				commit(peek(props.Value) + delta)
			end,
		})
	end

	local rowChildren: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	-- Largest magnitude outermost -- see file header. Steps sorted descending for the left side...
	local descendingSteps = table.clone(props.Steps)
	table.sort(descendingSteps, function(a, b)
		return a > b
	end)
	for order, magnitude in ipairs(descendingSteps) do
		table.insert(rowChildren, stepButton(-magnitude, order))
	end

	-- Both presentations of the readout occupy the SAME layout slot -- only one is ever Visible, and
	-- a hidden child still holds its place in a UIListLayout unless it is also zero-sized, so giving
	-- them one shared LayoutOrder is what keeps the row from reflowing when edit mode toggles.
	valueReadout.LayoutOrder = #descendingSteps + 1
	valueInput.LayoutOrder = #descendingSteps + 1
	table.insert(rowChildren, valueReadout)
	table.insert(rowChildren, valueInput)

	-- ...ascending for the right side, so the smallest magnitude sits nearest the readout on both
	-- sides.
	local ascendingSteps = table.clone(props.Steps)
	table.sort(ascendingSteps, function(a, b)
		return a < b
	end)
	for order, magnitude in ipairs(ascendingSteps) do
		table.insert(rowChildren, stepButton(magnitude, #descendingSteps + 2 + order))
	end

	--
	-- Click bar. The track is the input surface (not the handle): clicking anywhere on it jumps
	-- straight to that value -- an author wants the value under their cursor, not a handle they
	-- first have to grab. Deliberately click-only, NOT drag-to-scrub: an earlier version tracked
	-- InputChanged during a held-down drag and re-committed on every single pixel of mouse movement,
	-- which meant every field wired to a live server round-trip (MoveEditorClient's UpdateDraft, the
	-- flight tuner, etc.) re-fired dozens of times a second while dragging -- felt laggy/stuttery and
	-- was reported as such. One InputBegan sample per click/tap is both cheaper and, per that report,
	-- the actually-preferred interaction: a click bar, not a scrub slider.
	--
	local sliderEnabled = props.Slider ~= false
	local fillScale = scope:Computed(function(use)
		return math.clamp((use(props.Value) - props.Min) / range, 0, 1)
	end)

	local track: Frame? = nil

	local function commitFromPointer(pointerX: number): ()
		local trackFrame = track
		if not trackFrame then
			return
		end
		local width = trackFrame.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local alpha = math.clamp((pointerX - trackFrame.AbsolutePosition.X) / width, 0, 1)
		commit(props.Min + range * alpha)
	end

	if sliderEnabled then
		track = scope:New "Frame" {
			Name = "SliderTrack",
			Size = UDim2.new(1, 0, 0, TRACK_HEIGHT),
			BackgroundColor3 = Tokens.Wash.TrackBase.Color,
			BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
			BorderSizePixel = 0,
			LayoutOrder = 3,
			-- Without this the click falls through to whatever is behind the panel -- the same reason
			-- Screens/MoveEditor/PreviewViewport.lua's own ViewportFrame sets it.
			Active = true,

			[OnEvent "InputBegan"] = function(input: InputObject)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					commitFromPointer(input.Position.X)
				end
			end,

			[Children] = {
				scope:New "UICorner" { CornerRadius = Tokens.Radius.Hairline },
				scope:New "Frame" {
					Name = "Fill",
					Size = scope:Computed(function(use)
						return UDim2.fromScale(use(fillScale), 1)
					end),
					BackgroundColor3 = Tokens.Color.AccentPrimary,
					BorderSizePixel = 0,

					[Children] = scope:New "UICorner" { CornerRadius = Tokens.Radius.Hairline },
				},
				scope:New "Frame" {
					Name = "Handle",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = scope:Computed(function(use)
						return UDim2.fromScale(use(fillScale), 0.5)
					end),
					Size = UDim2.fromOffset(HANDLE_SIZE, HANDLE_SIZE),
					BackgroundColor3 = Tokens.Color.AccentPrimaryBright,
					BorderSizePixel = 0,
					-- Purely a position readout: every pointer event is handled by the track above,
					-- so the handle must not swallow the click that lands on top of it.
					Active = false,

					[Children] = scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
				},
			},
		} :: Frame
	end

	-- Built as a nullable local and spliced into [Children] below, the same shape `track` above
	-- already uses -- a nil entry in a Children array is simply skipped, so there is no empty row or
	-- reserved height for a field that doesn't carry one.
	local hint: Instance? = nil
	if props.Hint then
		hint = Label(scope, {
			Text = props.Hint :: string,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 4,
		})
	end

	return scope:New "Frame" {
		Name = "NumericField",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = if props.Visible == nil then true else props.Visible,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "LabelRow",
				Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = props.Label,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
						Size = UDim2.fromScale(1, 1),
					}),
					Label(scope, {
						Text = props.Unit or "",
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(1, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
			scope:New "Frame" {
				Name = "Row",
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
					scope:New "UIStroke" {
						Color = Tokens.Border.Standard.Color,
						Thickness = 1,
						Transparency = Tokens.Border.Standard.Transparency,
					},
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, Tokens.Space.XS),
						PaddingBottom = UDim.new(0, Tokens.Space.XS),
						PaddingLeft = UDim.new(0, Tokens.Space.XS),
						PaddingRight = UDim.new(0, Tokens.Space.XS),
					},
					table.unpack(rowChildren),
				},
			},
			track,
			hint,
		},
	} :: Frame
end

return NumericFieldModule
