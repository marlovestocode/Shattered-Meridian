--!strict
--[[
	Toggle.lua

	Owns: a real on/off switch -- this codebase's first. Built to replace an enable/disable pattern
	the old Move Editor used (a full-width Button whose Text swaps between "+ Add X"/"- Remove X"),
	which reads like a legacy HTML form control rather than a modern settings toggle.

	A rectangular track + rectangular sliding knob, not a rounded pill -- Tokens.Radius.Sharp is the
	only radius this codebase's chrome uses (docs/ui-ux-philosophy.md's "avoid perfect rounded
	rectangles" Shape Language), so a pill-shaped switch would be the one rounded control in the
	entire UI. A sharp-edged switch reads as a small mechanical lever/breaker instead, consistent
	with that language.

	On-state color reuses Button.lua's own Primary-variant logic exactly: the fill is
	Tokens.Color.AccentPrimary, and the knob sitting on it is Tokens.Color.Surface (the dark surface
	color, not white) -- "the knob IS the surface color on the bright fill," the same reasoning
	Button.lua's own header gives for Primary's text treatment, so this reads as the same design
	family rather than a new one-off control.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Selection = require(script.Parent.Selection)
local Label = require(script.Parent.Label)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ToggleProps = {
	-- Optional inline label rendered to the left of the switch, vertically centered on the same row
	-- (the shape every current call site wants -- "Enable Forward Lunge" beside the switch itself).
	-- Omit for a bare switch with no row chrome.
	Label: string?,
	Value: UsedAs<boolean>,
	OnChanged: (boolean) -> (),
	LayoutOrder: UsedAs<number>?,
	Disabled: UsedAs<boolean>?,
	-- Defaults to true. For a toggle that only applies under some other condition (Knockback's own
	-- "Starts Aerial Combo", which is meaningless until Knockback itself is on). Before this existed
	-- every such caller wrapped this component in a bare Frame purely to have something to bind a
	-- Visible to.
	Visible: UsedAs<boolean>?,
	-- One or two sentences under the switch saying what turning it ON actually does -- the same
	-- field-level explanation NumericField.lua's own Hint provides, for the control where it matters
	-- most: a toggle's consequence ("this move now travels instead of swinging") is far less
	-- guessable from its label than a number's is.
	--
	-- Present => this component returns an auto-height wrapper Frame containing the original
	-- fixed-height switch row plus the hint beneath it. Absent => it returns exactly the fixed-height
	-- row it always has, byte for byte, so no existing caller's layout moves. Same "opt-in changes
	-- the shape, the default path is untouched" structure `Label` above and Section.lua's own `icon`
	-- parameter already use.
	Hint: string?,
}

local TRACK_SIZE = Vector2.new(44, 22)
local KNOB_SIZE = 18
local KNOB_INSET = 2

local function Toggle(scope: Scope, props: ToggleProps): Frame
	-- Pointer-over AND gamepad-selection, OR-ed into the single boolean every visual Computed
	-- below already reads as `isHovering` -- see Components/Selection.lua for why the two stay
	-- separate rather than both writing one Value.
	local engagement = Selection.New(scope)
	local isHovering = engagement.Active
	local disabled: UsedAs<boolean> = if props.Disabled == nil then false else props.Disabled

	local knobPosition = scope:Computed(function(use)
		local x = if use(props.Value) then TRACK_SIZE.X - KNOB_SIZE - KNOB_INSET else KNOB_INSET
		return UDim2.new(0, x, 0.5, 0)
	end)
	local trackColor = scope:Computed(function(use)
		if use(props.Value) then
			return Tokens.Color.AccentPrimary
		end
		return Tokens.Wash.TrackBase.Color
	end)
	local trackTransparency = scope:Computed(function(use)
		return if use(props.Value) then 0 else Tokens.Wash.TrackBase.Transparency
	end)
	local trackBorderColor = scope:Computed(function(use)
		if use(props.Value) then
			return Tokens.Color.AccentPrimary
		end
		return if use(isHovering) then Tokens.Border.Lit.Color else Tokens.Border.Standard.Color
	end)
	local trackBorderTransparency = scope:Computed(function(use)
		if use(props.Value) then
			return 0
		end
		return if use(isHovering) then Tokens.Border.Lit.Transparency else Tokens.Border.Standard.Transparency
	end)
	local knobColor = scope:Computed(function(use)
		if use(disabled) then
			return Tokens.Color.TextDisabled
		end
		return if use(props.Value) then Tokens.Color.Surface else Tokens.Color.TextSecondary
	end)

	local track = scope:New "TextButton" {
		Name = "Track",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(TRACK_SIZE.X, TRACK_SIZE.Y),
		BackgroundColor3 = trackColor,
		BackgroundTransparency = trackTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Active = scope:Computed(function(use)
			return not use(disabled)
		end),

		[OnEvent "SelectionGained"] = engagement.OnSelectionGained,
		[OnEvent "SelectionLost"] = engagement.OnSelectionLost,
		[OnEvent "MouseEnter"] = engagement.OnPointerEnter,
		[OnEvent "MouseLeave"] = engagement.OnPointerLeave,
		[OnEvent "Activated"] = function()
			if not peek(disabled) then
				props.OnChanged(not peek(props.Value))
			end
		end,

		[Children] = {
			scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			scope:New "UIStroke" {
				Color = trackBorderColor,
				Thickness = 1,
				Transparency = trackBorderTransparency,
			},
			scope:New "Frame" {
				Name = "Knob",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = knobPosition,
				Size = UDim2.fromOffset(KNOB_SIZE, KNOB_SIZE),
				BackgroundColor3 = knobColor,
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			},
		},
	} :: TextButton

	-- Always a Frame wrapper, even with no Label, so this component has one honest return type
	-- instead of sometimes handing back a bare TextButton -- the bare case is just a wrapper sized
	-- exactly to the track, so it costs nothing layout-wise.
	local rowChildren: { Instance } = { track }
	if props.Label then
		table.insert(
			rowChildren,
			Label(scope, {
				Text = props.Label :: string,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(1, -(TRACK_SIZE.X + Tokens.Space.S), 1, 0),
			})
		)
	end

	local visible: UsedAs<boolean> = if props.Visible == nil then true else props.Visible

	-- The switch row itself, unchanged. When there is no Hint this IS the returned instance and
	-- carries the caller's LayoutOrder/Visible directly; when there IS one it becomes a child of the
	-- wrapper below, which takes those two over so the hint travels with the row.
	local row = scope:New "Frame" {
		Name = "Toggle",
		Size = if props.Label
			then UDim2.new(1, 0, 0, Tokens.Control.RowHeight)
			else UDim2.fromOffset(TRACK_SIZE.X, TRACK_SIZE.Y),
		BackgroundTransparency = 1,
		LayoutOrder = if props.Hint then 1 else props.LayoutOrder,
		Visible = if props.Hint then nil else visible,

		[Children] = rowChildren,
	} :: Frame

	if not props.Hint then
		return row
	end

	return scope:New "Frame" {
		Name = "ToggleWithHint",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		Visible = visible,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			row,
			Label(scope, {
				Text = props.Hint :: string,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				LayoutOrder = 2,
			}),
		},
	} :: Frame
end

return Toggle
