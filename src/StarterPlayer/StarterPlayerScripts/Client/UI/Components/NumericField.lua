--!strict
--[[
	NumericField.lua

	Owns: a labeled numeric row offering FOUR independent ways to reach the same value, because a
	single input affordance is wrong for at least one of the things authors actually do with these
	fields:

	  1. STEP buttons -- "-"/"+" at one or more magnitudes (e.g. both a coarse and a fine step,
	     "-1"/"-0.1" ... "+0.1"/"+1"). Right for nudging a value you are already close to.
	  2. TYPED ENTRY -- click the readout and it becomes a text box; type an exact number, press
	     Enter or click away, and it commits (clamped). Right for "I want exactly 12.5", which
	     stepping to is absurd and dragging to is impossible. Up/Down arrows nudge the box's own
	     text by the finest step while it is open, so a typed value can be tuned without retyping;
	     Escape abandons the entry, and is the only route here that discards a typed number.
	  3. THE SCROLL WHEEL, over the control. The same nudge as a step button without moving the
	     pointer onto one -- which matters because these rows are stacked twenty deep in a form.
	  4. THE BAR -- click anywhere along the track to jump straight to that point in the Min..Max
	     range, or hold and drag to sweep it. Right for exploring ("how big does this actually need
	     to be?") where the number matters less than landing roughly in the right zone fast.

	All four write through the SAME commit path (clamped to Min/Max, then props.OnChanged), so no
	route can produce a value the others couldn't, and none of them can produce an out-of-range one.
	The bar is opt-out (Slider = false) for the handful of fields where jumping around the range is
	meaningless.

	MODIFIERS, on the two INCREMENTAL routes (step buttons, wheel): Shift multiplies the step by 10,
	Alt divides it by 10. Not on typed entry or the bar, because both of those name an ABSOLUTE value
	rather than a delta and there is nothing meaningful to scale -- except that Alt held AT THE MOMENT
	a drag begins does change the bar, into a fine relative sweep (see beginScrub). The step buttons'
	printed labels do NOT change while a modifier is held: making four labels reactive to two keys
	would cost a live input listener per field, on a screen that mounts ~40 of them, to restate a
	convention the editor's own shortcut overlay already lists.

	DRAG-TO-SCRUB IS BACK, THROTTLED, and the throttle is the whole point. An earlier version tracked
	InputChanged during a held drag and called props.OnChanged on every single pointer event, which
	meant every field wired to a live consumer (the Move Editor's whole-draft clone and re-render, the
	flight tuner) re-ran dozens of times a second -- it felt laggy and stuttery and was removed. What
	it was missing is that the two rates are not the same rate: the LOCAL readout wants every event,
	so the number under the cursor stays glued to it, while the COMMIT wants a fraction of that. So a
	drag now paints from its own scrubValue (every event, no clone, no commit) and calls commit at
	most every SCRUB_COMMIT_INTERVAL -- plus always once more on release, since the sample an author
	let go on is the one that must not be dropped.

	Generalizes two pre-existing, near-identical shapes that were never unified: Stepper.lua's own
	single-Step clamp control (Attributes screen), and Screens/DevTools/DevMenu/ContentArea.lua's hand-rolled
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

	COMPACT (2026-10-01, `Compact = true`) is the same four routes in half the height, for a form that
	stacks forty of these. One line carries the label, its unit and the value (which is still the click-to-
	type readout); one line carries the step buttons and a slider that takes every pixel they leave:

	    Spread angle                                          degrees   30
	    [-30][-5] ━━━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ [+5][+30]

	Beyond the saving in height, the bar is a real slider rather than a 6px strip: its hit area is the full
	row (a track you could not miss), its handle grows while it is held, and it takes the gamepad -- a
	selected slider moves by its finest step on DPad left/right, the same nudge the wheel gives a mouse.
	Every value it commits is SNAPPED to the field's own Decimals, so what the readout says is what is
	stored (a drag across a 400-wide range otherwise stores 37.2314 under a readout of 37). The default
	layout is untouched, and does not snap: its other callers (the flight tuner, the Dev Menu) keep
	exactly what they had.

	The stepper+readout Row sits on Tokens.Wash.Inset -- that token's own comment already names "a
	stepper button's face" as one of its intended uses, so this is that use, not a new one -- with a
	thin Border.Standard outline, reading as one contained field control instead of three buttons and
	a label floating loose next to each other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Button = require(script.Parent.Button)
local Inset = require(script.Parent.Inset)
local Selection = require(script.Parent.Selection)
local Stack = require(script.Parent.Stack)

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
	-- its hints in Screens/DevTools/MoveEditor/Copy.lua rather than inline, so the prose is editable in one
	-- place -- see that module's own header.
	--
	-- LAYOUT RULE: within a single horizontal row of these (the Move Editor's Fields.Pair), either
	-- every field carries a Hint or none does. The row's cells are AutomaticSize.Y and
	-- top-aligned, so one hinted field beside an unhinted one leaves the short cell's control
	-- floating against a taller neighbour.
	Hint: string?,
	-- The two-line layout described in the header, with snapped values. Off by default.
	Compact: boolean?,
}

-- COMPACT layout metrics.
local COMPACT_ROW_HEIGHT = 22
local COMPACT_CONTROL_HEIGHT = 24
local COMPACT_VALUE_WIDTH = 76
local COMPACT_STEP_WIDTH = 42
local COMPACT_RAIL_HEIGHT = 4
local COMPACT_HANDLE_SIZE = 14
local COMPACT_HANDLE_HOT_SIZE = 18
-- How far the rail is inset from each end of the track's hit area, so the handle at either extreme is
-- still wholly inside it.
local COMPACT_TRACK_INSET = COMPACT_HANDLE_HOT_SIZE / 2

-- Narrower than this file's original 44 -- a full NumericField (up to 4 step buttons + a value
-- readout) needs to fit inside a half-width cell of a form pane (the Move Editor's Fields.Pair), and
-- 44 left only a ~6px margin there (confirmed too tight in Studio -- buttons overlapped the next
-- field). 40 gives a ~32px margin instead while still fitting every step label this file renders
-- ("-0.01" being the longest).
local STEP_BUTTON_WIDTH = 40
local VALUE_WIDTH = 66
local TRACK_HEIGHT = 6
local HANDLE_SIZE = 12

-- Shift multiplies an incremental step by this, Alt divides by it. 10 rather than a per-field prop:
-- every Steps list in this codebase is already authored in powers of ten ({0.05, 0.2} being the one
-- exception, where x10 still lands somewhere useful), and a per-field override would be a fourth
-- number per call site with nothing keeping it honest.
local MODIFIER_FACTOR = 10

-- Ceiling on how often a drag calls props.OnChanged -- see the file header on why this exists and
-- why the LOCAL readout is deliberately not throttled with it. 20/second is well under the rate an
-- unthrottled drag produced and still far above the rate at which a human perceives a value as
-- lagging their hand, which the local readout is covering anyway.
local SCRUB_COMMIT_INTERVAL = 1 / 20

-- How much finer an Alt-held drag is than a normal one -- a full sweep of the track covers a tenth
-- of the range instead of all of it. The reason this mode exists at all is fields like Projectile
-- Speed (5..2000): one pixel of an absolute drag there is ~7 studs/second, so the bar cannot express
-- a small adjustment no matter how carefully it is dragged.
local FINE_SCRUB_FACTOR = 10

local function formatValue(value: number, decimals: number): string
	return string.format("%." .. decimals .. "f", value)
end

local NumericFieldModule = {}

function NumericFieldModule.Mount(scope: Scope, props: NumericFieldProps): Frame
	local decimals = props.Decimals or 2
	local range = math.max(props.Max - props.Min, 1e-6)
	local compact = props.Compact == true

	-- The single funnel every one of the three input routes writes through -- see file header.
	local function commit(candidate: number): ()
		if candidate ~= candidate then
			-- NaN, which only typed entry can produce (tonumber("nan")). Silently ignored rather
			-- than clamped: math.clamp would pass it straight through and hand the caller a NaN.
			return
		end
		local value = math.clamp(candidate, props.Min, props.Max)
		if compact then
			-- Snapped to what the readout shows. Through the formatter, not floor(x / q) * q, which hands
			-- back 0.30000000000000004 for a 0.3.
			value = math.clamp(tonumber(formatValue(value, decimals)) or value, props.Min, props.Max)
		end
		props.OnChanged(value)
	end

	-- Read at the moment of the press/scroll rather than tracked as state -- the input event already
	-- tells us exactly when to ask, so there is nothing to keep in sync. Holding BOTH cancels out
	-- rather than compounding: there is no defensible answer to "coarse and fine at once", and
	-- silently picking one would make a slipped finger change the step by 100x.
	local function modifierScale(): number
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local alt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
		if shift == alt then
			return 1
		end
		return if shift then MODIFIER_FACTOR else 1 / MODIFIER_FACTOR
	end

	-- The FINEST authored step, which is what the wheel and the typed-entry arrow keys nudge by. Not
	-- Steps[1]: that list's order is a RENDERING convention (largest magnitude outermost), not a
	-- priority. nil when a field authors no steps at all -- which the Steps prop explicitly allows for
	-- a field whose useful values span orders of magnitude -- so those fields simply have no wheel and
	-- no arrow nudge, rather than being given an invented step size.
	local nudgeStep: number? = nil
	for _, magnitude in ipairs(props.Steps) do
		if nudgeStep == nil or magnitude < nudgeStep then
			nudgeStep = magnitude
		end
	end

	-- Non-nil only while a drag is in progress, and it OVERRIDES props.Value everywhere the value is
	-- displayed -- see the file header. This is what lets the readout and handle follow the pointer at
	-- full event rate while the commit behind them runs at SCRUB_COMMIT_INTERVAL.
	local scrubValue: Fusion.Value<number?> = scope:Value(nil)
	local function displayedValue(use: Fusion.Use): number
		local base = use(props.Value)
		local scrubbing = use(scrubValue)
		return if scrubbing ~= nil then scrubbing else base
	end

	local valueText = scope:Computed(function(use)
		return formatValue(displayedValue(use), decimals)
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

	-- Set by cancelEditing so the FocusLost that follows knows not to commit. A flag rather than
	-- disconnecting the handler, because releasing focus is what FIRES FocusLost -- there is no
	-- ordering in which the handler could be removed first.
	local editCancelled = false

	local function finishEditing(): ()
		isEditing:set(false)
		if editCancelled then
			editCancelled = false
			return
		end
		local typed = tonumber(peek(editText))
		if typed then
			commit(typed)
		end
		-- A non-numeric entry simply reverts: the readout re-renders from props.Value, which never
		-- changed. No error state, because there is nothing an author can do about it except type a
		-- number, which the reverted display already invites.
	end

	local valueFont = if compact then Tokens.Type.Numeral else Tokens.Type.NumeralLarge
	local valueSize = if compact
		then UDim2.fromOffset(COMPACT_VALUE_WIDTH, COMPACT_ROW_HEIGHT)
		else UDim2.fromOffset(VALUE_WIDTH, Tokens.Control.StepButtonSize)
	local valueReadout = scope:New "TextButton" {
		Name = "Value",
		Size = valueSize,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = valueText,
		FontFace = valueFont.Face,
		TextSize = valueFont.Size,
		TextColor3 = Tokens.Color.AccentPrimaryBright,
		TextXAlignment = if compact then Enum.TextXAlignment.Right else Enum.TextXAlignment.Center,
		LayoutOrder = 0, -- overwritten below, once the step count is known
		Visible = scope:Computed(function(use)
			return not use(isEditing)
		end),

		[OnEvent "Activated"] = beginEditing,
	} :: TextButton

	local valueInput = scope:New "TextBox" {
		Name = "ValueInput",
		Size = valueSize,
		BackgroundColor3 = Tokens.Color.Surface,
		BorderSizePixel = 0,
		Text = editText,
		FontFace = valueFont.Face,
		TextSize = valueFont.Size,
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

	-- Escape abandons the entry: the readout re-renders from props.Value, which never changed. This
	-- is the ONLY route that discards a typed number -- Enter, Tab and clicking away all commit --
	-- and it lives here rather than in whatever screen hosts the field because the half-typed text is
	-- this component's own state, which nothing outside it can even see is open.
	local function cancelEditing(): ()
		editCancelled = true
		valueInput:ReleaseFocus(false)
	end

	-- Up/Down while the box is open edit the BOX'S TEXT, not the committed value: the author is
	-- mid-entry, and committing under them would fight whatever they were about to type. Enter or a
	-- click away commits, exactly as it does for anything else typed in here.
	local function nudgeEditText(direction: number): ()
		local magnitude = nudgeStep
		if magnitude == nil then
			return
		end
		-- ClearTextOnFocus wipes the seeded text the moment the box takes focus, so an untouched box
		-- reads "" and tonumber gives nil -- fall back to the value the box is standing in for.
		local current = tonumber(peek(editText)) or peek(props.Value)
		local stepped = current + magnitude * direction * modifierScale()
		editText:set(formatValue(math.clamp(stepped, props.Min, props.Max), decimals))
	end

	-- Live only while the box is open. A form mounts ~40 of these rows, so a listener per row held for
	-- the whole session would run 40 handlers on every keypress in the game to serve the one row that
	-- is actually being typed into.
	local editKeyConnection: RBXScriptConnection? = nil
	local function disconnectEditKeys(): ()
		if editKeyConnection then
			editKeyConnection:Disconnect()
			editKeyConnection = nil
		end
	end
	-- Registered on the scope ONCE (the function, not the connection) rather than per edit session --
	-- the scope outlives every individual edit, and re-registering would grow its task list forever.
	table.insert(scope, disconnectEditKeys)

	-- Roblox does not focus a TextBox that was Visible = false at the moment CaptureFocus is called,
	-- and the Visible flip above only lands on the next render step -- so focus is deferred by one
	-- Observer tick rather than requested inline in beginEditing.
	scope:Observer(isEditing):onChange(function()
		if not peek(isEditing) then
			disconnectEditKeys()
			return
		end
		valueInput:CaptureFocus()
		disconnectEditKeys()
		editKeyConnection = UserInputService.InputBegan:Connect(function(input: InputObject)
			-- gameProcessed is deliberately NOT checked: it is true for every key that lands while a
			-- TextBox holds focus (the box is what processed it), so checking it would mean this never
			-- fires at all -- which is the exact situation it is here to serve.
			if input.KeyCode == Enum.KeyCode.Up then
				nudgeEditText(1)
			elseif input.KeyCode == Enum.KeyCode.Down then
				nudgeEditText(-1)
			elseif input.KeyCode == Enum.KeyCode.Escape then
				cancelEditing()
			end
		end)
	end)

	local function stepButton(delta: number, order: number): TextButton
		local sign = if delta < 0 then "-" else "+"
		if compact then
			-- A bare TextButton rather than Components/Button: forty of these rows carry four each, and
			-- Button's full hover/press/variant machinery is a lot of instances to sit idle. It still shows
			-- the pointer-or-gamepad engagement Selection exists for.
			local engagement = Selection.New(scope)
			return scope:New "TextButton" {
				Name = if delta < 0 then "StepDown" else "StepUp",
				Size = UDim2.fromOffset(COMPACT_STEP_WIDTH, COMPACT_CONTROL_HEIGHT),
				LayoutOrder = order,
				AutoButtonColor = false,
				BorderSizePixel = 0,
				BackgroundColor3 = Tokens.Color.AccentPrimary,
				BackgroundTransparency = scope:Computed(function(use)
					return if use(engagement.Active) then 0.72 else 0.92
				end),
				Text = sign .. formatValue(math.abs(delta), decimals),
				FontFace = Tokens.Type.NumeralSmall.Face,
				TextSize = Tokens.Type.NumeralSmall.Size,
				TextColor3 = Tokens.Color.TextPrimary,

				[OnEvent "SelectionGained"] = engagement.OnSelectionGained,
				[OnEvent "SelectionLost"] = engagement.OnSelectionLost,
				[OnEvent "MouseEnter"] = engagement.OnPointerEnter,
				[OnEvent "MouseLeave"] = engagement.OnPointerLeave,
				[OnEvent "Activated"] = function()
					commit(peek(props.Value) + delta * modifierScale())
				end,

				[Children] = scope:New "UICorner" { CornerRadius = Tokens.Radius.Hairline },
			} :: TextButton
		end
		return Button(scope, {
			Text = sign .. formatValue(math.abs(delta), decimals),
			Size = UDim2.fromOffset(STEP_BUTTON_WIDTH, Tokens.Control.StepButtonSize),
			LayoutOrder = order,
			OnActivated = function()
				commit(peek(props.Value) + delta * modifierScale())
			end,
		})
	end

	-- Largest magnitude outermost -- see file header. Steps sorted descending for the left side, ascending
	-- for the right, so the smallest magnitude sits nearest the readout on both sides.
	local descendingSteps = table.clone(props.Steps)
	table.sort(descendingSteps, function(a, b)
		return a > b
	end)
	local ascendingSteps = table.clone(props.Steps)
	table.sort(ascendingSteps, function(a, b)
		return a < b
	end)

	-- The stacked layout's one-row cluster. A compact field arranges the same pieces itself (below), so it
	-- builds none of this: the step buttons would otherwise exist twice.
	local rowChildren: { Instance } = {}
	if not compact then
		table.insert(
			rowChildren,
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}
		)
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

		for order, magnitude in ipairs(ascendingSteps) do
			table.insert(rowChildren, stepButton(magnitude, #descendingSteps + 2 + order))
		end
	end

	--
	-- The bar. The TRACK is the input surface, not the handle: clicking anywhere on it jumps straight
	-- to that value -- an author wants the value under their cursor, not a handle they first have to
	-- grab -- and holding then sweeps from there. See the file header on why the drag commits on a
	-- throttle while the readout does not.
	--
	local sliderEnabled = props.Slider ~= false
	local fillScale = scope:Computed(function(use)
		return math.clamp((displayedValue(use) - props.Min) / range, 0, 1)
	end)

	local track: Frame? = nil

	-- Everything one in-progress drag owns. Connected on grab, dropped on release -- NOT held open
	-- for the session: a mounted form has ~40 of these, and 40 live UserInputService.InputChanged
	-- handlers would run on every pointer move whether anything was being dragged or not.
	local scrubConnections: { RBXScriptConnection } = {}
	local scrubLastCommit = 0
	-- The most recent sample the throttle did NOT commit, so release can flush it -- see endScrub.
	local scrubPending: number? = nil
	-- Non-nil only for a FINE drag (Alt held at the moment of the grab), holding where the pointer
	-- was and what the value was at that instant, since a fine drag is relative to both.
	local scrubAnchor: { PointerX: number, Value: number }? = nil

	local function disconnectScrub(): ()
		for _, connection in ipairs(scrubConnections) do
			connection:Disconnect()
		end
		table.clear(scrubConnections)
	end
	-- The function, once, rather than each drag's connections: the scope outlives every drag.
	table.insert(scope, disconnectScrub)

	local function valueFromPointer(pointerX: number): number?
		local trackFrame = track
		if not trackFrame then
			return nil
		end
		-- The rail's own span: the whole track, less the inset a compact track keeps clear for its handle.
		local inset = if compact then COMPACT_TRACK_INSET else 0
		local width = trackFrame.AbsoluteSize.X - inset * 2
		if width <= 0 then
			return nil
		end
		local anchor = scrubAnchor
		if anchor then
			-- Fine drag: relative to the grab, at a tenth of the sensitivity. Deliberately NOT clamped
			-- to the pointer staying over the track -- the whole point is small movements, and a fine
			-- drag can legitimately run off the end of a short track without having reached a bound.
			local delta = (pointerX - anchor.PointerX) / width * range / FINE_SCRUB_FACTOR
			return math.clamp(anchor.Value + delta, props.Min, props.Max)
		end
		local alpha = math.clamp((pointerX - trackFrame.AbsolutePosition.X - inset) / width, 0, 1)
		return props.Min + range * alpha
	end

	-- X only, and that is load-bearing: a GuiObject's AbsolutePosition excludes the top GUI inset
	-- while an InputObject's Position includes it, so the two disagree on Y by 36px. Every value here
	-- is horizontal, so the mismatch cannot reach the number -- but it is why this must never grow a
	-- Y term without converting one of the two first.
	local function sampleScrub(pointerX: number): ()
		local sampled = valueFromPointer(pointerX)
		if sampled == nil then
			return
		end
		scrubValue:set(sampled)
		local now = os.clock()
		if now - scrubLastCommit >= SCRUB_COMMIT_INTERVAL then
			scrubLastCommit = now
			scrubPending = nil
			commit(sampled)
		else
			scrubPending = sampled
		end
	end

	local function endScrub(): ()
		disconnectScrub()
		scrubAnchor = nil
		local pending = scrubPending
		scrubPending = nil
		if pending ~= nil then
			-- The throttle can only ever drop the LAST sample, which is the one that matters most: the
			-- value the author actually let go on. Committed unconditionally, interval or not.
			commit(pending)
		end
		scrubValue:set(nil)
	end

	local function beginScrub(pointerX: number): ()
		-- Defensive: a swallowed InputEnded (alt-tab mid-drag, say) must never leave two drags live
		-- fighting over the same field.
		disconnectScrub()
		-- Sampled ONCE, here, rather than per pointer event: a drag that changed sensitivity halfway
		-- through would jump, because the two modes measure from different origins.
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
			scrubAnchor = { PointerX = pointerX, Value = peek(props.Value) }
		else
			scrubAnchor = nil
		end
		-- Zeroed so the grab itself always commits: a plain click on the bar must still jump straight
		-- to that value, which is the interaction this control had before it could be dragged at all.
		scrubLastCommit = 0
		sampleScrub(pointerX)

		-- Listened for on UserInputService rather than on the track, so a drag survives the pointer
		-- leaving a 6px-tall strip -- which it does almost immediately, and which under a track-only
		-- listener would silently strand the drag with no release event.
		table.insert(
			scrubConnections,
			UserInputService.InputChanged:Connect(function(input: InputObject)
				if
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				then
					sampleScrub(input.Position.X)
				end
			end)
		)
		table.insert(
			scrubConnections,
			UserInputService.InputEnded:Connect(function(input: InputObject)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					endScrub()
				end
			end)
		)
	end

	-- The compact slider: a full-height hit area (nothing to miss), a thin rail and a handle that grows
	-- while the pointer or the pad is on it. Gamepad: while selected, DPad left/right nudges by the
	-- finest step -- the connection lives only as long as the selection.
	local function buildCompactTrack(): Frame
		local engagement = Selection.New(scope)
		local hot = scope:Computed(function(use): boolean
			return use(engagement.Active) or use(scrubValue) ~= nil
		end)

		local padConnection: RBXScriptConnection? = nil
		local function disconnectPad(): ()
			if padConnection then
				padConnection:Disconnect()
				padConnection = nil
			end
		end
		table.insert(scope, disconnectPad)
		scope:Observer(engagement.Selected):onChange(function()
			disconnectPad()
			if not peek(engagement.Selected) then
				return
			end
			padConnection = UserInputService.InputBegan:Connect(function(input: InputObject)
				local direction = if input.KeyCode == Enum.KeyCode.DPadLeft
					then -1
					elseif input.KeyCode == Enum.KeyCode.DPadRight then 1
					else 0
				if direction ~= 0 then
					commit(peek(props.Value) + (nudgeStep or range / 100) * direction)
				end
			end)
		end)

		return scope:New "Frame" {
			Name = "SliderTrack",
			Size = UDim2.fromOffset(0, COMPACT_CONTROL_HEIGHT),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			LayoutOrder = 100,
			-- Without this the click falls through to whatever is behind the panel.
			Active = true,
			Selectable = true,

			[OnEvent "SelectionGained"] = engagement.OnSelectionGained,
			[OnEvent "SelectionLost"] = engagement.OnSelectionLost,
			[OnEvent "MouseEnter"] = engagement.OnPointerEnter,
			[OnEvent "MouseLeave"] = engagement.OnPointerLeave,
			[OnEvent "InputBegan"] = function(input: InputObject)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					beginScrub(input.Position.X)
				end
			end,

			[Children] = {
				scope:New "UIPadding" {
					PaddingLeft = UDim.new(0, COMPACT_TRACK_INSET),
					PaddingRight = UDim.new(0, COMPACT_TRACK_INSET),
				},
				scope:New "Frame" {
					Name = "Rail",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.new(1, 0, 0, COMPACT_RAIL_HEIGHT),
					BackgroundColor3 = Tokens.Wash.TrackBase.Color,
					BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
					BorderSizePixel = 0,

					[Children] = scope:New "UICorner" { CornerRadius = Tokens.Radius.Hairline },
				},
				scope:New "Frame" {
					Name = "Fill",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = scope:Computed(function(use)
						return UDim2.new(use(fillScale), 0, 0, COMPACT_RAIL_HEIGHT)
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
					Size = scope:Computed(function(use)
						local diameter = if use(hot) then COMPACT_HANDLE_HOT_SIZE else COMPACT_HANDLE_SIZE
						return UDim2.fromOffset(diameter, diameter)
					end),
					BackgroundColor3 = scope:Computed(function(use)
						return if use(hot) then Tokens.Color.AccentPrimaryBright else Tokens.Color.AccentPrimary
					end),
					BorderSizePixel = 0,
					-- Purely a position readout: the track takes every pointer event.
					Active = false,

					[Children] = scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
				},
			},
		} :: Frame
	end

	if sliderEnabled and compact then
		track = buildCompactTrack()
	elseif sliderEnabled then
		track = scope:New "Frame" {
			Name = "SliderTrack",
			Size = UDim2.new(1, 0, 0, TRACK_HEIGHT),
			BackgroundColor3 = Tokens.Wash.TrackBase.Color,
			BackgroundTransparency = Tokens.Wash.TrackBase.Transparency,
			BorderSizePixel = 0,
			LayoutOrder = 3,
			-- Without this the click falls through to whatever is behind the panel.
			Active = true,

			[OnEvent "InputBegan"] = function(input: InputObject)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					beginScrub(input.Position.X)
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

	if compact then
		-- The two lines (see the header): [label ... unit value] over [steps  slider  steps]. The readout and
		-- its text box share one slot, as in the stacked layout, so entering edit mode never reflows.
		local controls: { Instance } = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
		}
		for order, magnitude in ipairs(descendingSteps) do
			table.insert(controls, stepButton(-magnitude, order))
		end
		if track then
			table.insert(controls, Stack.Fill(scope, track))
		end
		for order, magnitude in ipairs(ascendingSteps) do
			table.insert(controls, stepButton(magnitude, 200 + order))
		end
		-- The wheel nudges from anywhere on the control row, as it does on the stacked row.
		local controlRow = scope:New "Frame" {
			Name = "Controls",
			Size = UDim2.new(1, 0, 0, COMPACT_CONTROL_HEIGHT),
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			Active = true,

			[OnEvent "InputChanged"] = function(input: InputObject)
				local magnitude = nudgeStep
				if input.UserInputType ~= Enum.UserInputType.MouseWheel or magnitude == nil then
					return
				end
				commit(peek(props.Value) + magnitude * math.sign(input.Position.Z) * modifierScale())
			end,

			[Children] = controls,
		} :: Frame

		valueReadout.LayoutOrder = 2
		valueInput.LayoutOrder = 2
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
					Padding = UDim.new(0, 2),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				scope:New "Frame" {
					Name = "Header",
					Size = UDim2.new(1, 0, 0, COMPACT_ROW_HEIGHT),
					BackgroundTransparency = 1,
					LayoutOrder = 1,

					[Children] = {
						Label(scope, {
							Text = props.Label,
							Scale = "Body",
							Color = Tokens.Color.TextPrimary,
							Size = UDim2.new(1, -COMPACT_VALUE_WIDTH - 90, 1, 0),
						}),
						scope:New "Frame" {
							Name = "Readout",
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.fromScale(1, 0.5),
							Size = UDim2.fromOffset(0, COMPACT_ROW_HEIGHT),
							AutomaticSize = Enum.AutomaticSize.X,
							BackgroundTransparency = 1,

							[Children] = {
								scope:New "UIListLayout" {
									FillDirection = Enum.FillDirection.Horizontal,
									HorizontalAlignment = Enum.HorizontalAlignment.Right,
									VerticalAlignment = Enum.VerticalAlignment.Center,
									Padding = UDim.new(0, Tokens.Space.XS),
									SortOrder = Enum.SortOrder.LayoutOrder,
								},
								scope:New "TextLabel" {
									Name = "Unit",
									Size = UDim2.fromOffset(0, COMPACT_ROW_HEIGHT),
									AutomaticSize = Enum.AutomaticSize.X,
									BackgroundTransparency = 1,
									LayoutOrder = 1,
									Text = props.Unit or "",
									FontFace = Tokens.Type.Detail.Face,
									TextSize = Tokens.Type.Detail.Size,
									TextColor3 = Tokens.Color.TextDisabled,
								},
								valueReadout,
								valueInput,
							},
						},
					},
				},
				controlRow,
				hint,
			},
		} :: Frame
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
				-- Same reason the track sets it: without it the pointer is not considered to be over this
				-- Frame at all and the wheel event never arrives. The step buttons and the readout are
				-- children and still get their own clicks first.
				Active = true,

				-- The scroll wheel, anywhere over the control -- one nudge per detent at the finest
				-- authored step. Position.Z is Roblox's wheel axis: +1 for a scroll up, -1 for down.
				[OnEvent "InputChanged"] = function(input: InputObject)
					if input.UserInputType ~= Enum.UserInputType.MouseWheel then
						return
					end
					local magnitude = nudgeStep
					if magnitude == nil then
						return
					end
					commit(peek(props.Value) + magnitude * math.sign(input.Position.Z) * modifierScale())
				end,

				[Children] = {
					scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
					scope:New "UIStroke" {
						Color = Tokens.Border.Standard.Color,
						Thickness = 1,
						Transparency = Tokens.Border.Standard.Transparency,
					},
					Inset(scope, Tokens.Space.XS),
					table.unpack(rowChildren),
				},
			},
			track,
			hint,
		},
	} :: Frame
end

return NumericFieldModule
