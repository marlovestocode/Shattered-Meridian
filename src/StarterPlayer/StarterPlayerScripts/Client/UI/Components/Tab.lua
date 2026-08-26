--!strict
--[[
	Tab.lua

	Owns: a selectable chip/tab button -- same sharp-bordered visual family as Button.lua and
	Panel.lua, but keyed off a persistent, caller-driven Selected prop instead of Button.lua's
	transient hover/press-only state. Reused widely across DevMenu/ContentArea.lua: the Spawn/Admin/
	Tuning/Reports tab strip, the Godmode/Flight/Collide/Frozen/Invisible/Spectate admin toggles
	(whose Selected reflects the *actual* replicated Humanoid attribute, not a locally-guessed toggle
	-- see DevMenuClient.lua's watchTarget), the ability-preview state buttons, and the bug-report
	triage status buttons.

	Selected gets Tokens.Color.SurfaceElevated + Tokens.Border.Accent (the "40% accent edge on a
	selected/active surface" tint, docs/ui-ux-philosophy.md's "borders communicate importance:
	brighter edge highlight"); unselected stays Tokens.Color.Surface + Tokens.Border.Standard,
	matching every other panel/button's resting state.

	TrackedCaps (optional, default off): renders Text through Components/TrackedLabel.lua instead of
	this TextButton's own Text property -- "tracked caps on tab and section headers"
	(docs/design/intro-redesign-handoff.md Phase F). Deliberately NOT the default for every call
	site, unlike Button.lua's Variant split: most of the Tab call sites above (Godmode/Flight/
	Frozen/... toggle buttons, ability-preview state, triage status) pass genuinely LIVE text that
	changes at runtime (e.g. "Godmode: ON"/"Godmode: OFF"), and TrackedLabel can only ever render a
	string ONCE at construction (see that file's own header) -- turning tracked caps on everywhere
	would silently freeze those buttons' text at whatever it read on mount. Only the actual 4-way tab
	strip (ContentArea.lua's tabButton, real static names) opts in.

	Variant (default "Boxed") is the shape, not the styling. "Boxed" is everything described above:
	a bordered chip that reads as an object you can press, which is right for a toggle or a chip in a
	free-flowing row. "Underline" is the character menu's own top-level tab strip -- no border at all,
	the four tabs butt against each other edge to edge across the full panel width, and the ONLY
	selection cue is a bronze rule along the bottom edge plus the elevated fill behind the active one.
	A boxed chip cannot express that: four bordered chips in a row draw eight vertical hairlines
	through a band that is supposed to read as one continuous strip under the header. Strictly
	additive -- omitting Variant renders this file's original chip byte-for-byte.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Selection = require(script.Parent.Selection)
local TrackedLabel = require(script.Parent.TrackedLabel)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TabProps = {
	Text: UsedAs<string>,
	Selected: UsedAs<boolean>,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	OnActivated: (() -> ())?,
	-- See file header. Text is peek'd ONCE if this is true -- only pass it for a call site with
	-- genuinely static text.
	TrackedCaps: boolean?,
	-- See file header. Defaults to "Boxed".
	Variant: ("Boxed" | "Underline")?,
	-- "Underline" only: the color of the selected tab's bottom rule. Defaults to the bronze accent.
	UnderlineColor: UsedAs<Color3>?,
}

local UNDERLINE_THICKNESS = 3
-- The seam between two neighbouring underline tabs. They butt against each other with no gap, so
-- without this the strip reads as one wide band with four words in it rather than as four targets.
local SEPARATOR_TINT = Tokens.Border.Hairline

local function Tab(scope: Scope, props: TabProps): TextButton
	-- Pointer-over AND gamepad-selection, OR-ed into the single boolean every visual Computed
	-- below already reads as `isHovering` -- see Components/Selection.lua for why the two stay
	-- separate rather than both writing one Value.
	local engagement = Selection.New(scope)
	local isHovering = engagement.Active
	local trackedCaps = props.TrackedCaps == true
	local underlined = props.Variant == "Underline"

	local backgroundColor = scope:Computed(function(use)
		if use(props.Selected) or use(isHovering) then
			return Tokens.Color.SurfaceElevated
		end
		return Tokens.Color.Surface
	end)

	local borderColor = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Border.Accent.Color else Tokens.Border.Standard.Color
	end)
	local borderTransparency = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Border.Accent.Transparency else Tokens.Border.Standard.Transparency
	end)

	local textColor = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)

	local children: { Instance } = {
		scope:New "UICorner" {
			CornerRadius = Tokens.Radius.Sharp,
		},
	}
	if underlined then
		-- The rule stays mounted at both states and only changes transparency, rather than being
		-- built conditionally: it has to be able to appear and disappear as Selected changes AFTER
		-- construction, which a build-time branch on a Fusion state object cannot do (a state object
		-- is always truthy -- the same trap ArtsTab.lua's own header documents for Panel's Elevated).
		table.insert(
			children,
			scope:New "Frame" {
				Name = "Underline",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, UNDERLINE_THICKNESS),
				BackgroundColor3 = props.UnderlineColor or Tokens.Color.AccentSecondary,
				BackgroundTransparency = scope:Computed(function(use)
					if use(props.Selected) then
						return 0
					end
					-- A half-lit rule under the cursor: the strip answers before the click, which is the
					-- whole difference between a row of labels and a row of controls.
					return if use(isHovering) then 0.55 else 1
				end),
				BorderSizePixel = 0,
			}
		)
		table.insert(
			children,
			scope:New "Frame" {
				Name = "Separator",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				-- Short of full height on purpose: a seam that stops before the band edges reads as a
				-- division between two items, where a full-height one reads as a table gridline.
				Size = UDim2.new(0, 1, 0.5, 0),
				BackgroundColor3 = SEPARATOR_TINT.Color,
				BackgroundTransparency = SEPARATOR_TINT.Transparency,
				BorderSizePixel = 0,
			}
		)
	else
		table.insert(
			children,
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
				Transparency = borderTransparency,
			}
		)
	end
	if trackedCaps then
		table.insert(
			children,
			TrackedLabel(scope, {
				-- Peek'd once -- see file header.
				Text = string.upper(peek(props.Text)),
				Scale = "Action",
				Color = textColor,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
			})
		)
	end

	return scope:New "TextButton" {
		Size = props.Size or UDim2.fromOffset(120, Tokens.Control.StepButtonSize),
		LayoutOrder = props.LayoutOrder,
		AutoButtonColor = false,
		BackgroundColor3 = backgroundColor,
		-- Underline tabs sit on the strip's own Surface band, so an unselected one paints nothing at
		-- all and lets that band show through; the elevated fill is itself part of the selection cue.
		BackgroundTransparency = if underlined
			then scope:Computed(function(use)
				return if use(props.Selected) or use(isHovering) then 0 else 1
			end)
			else nil,
		BorderSizePixel = 0,
		-- Under TrackedCaps this stays set (for gamepad/screen-reader nav, ActionIcon.lua's
		-- convention) but invisible -- the TrackedLabel child renders the visible copy instead.
		Text = if trackedCaps then string.upper(peek(props.Text)) else props.Text,
		TextTransparency = if trackedCaps then 1 else nil,
		FontFace = Tokens.Type.Body.Face,
		TextSize = Tokens.Type.Body.Size,
		TextColor3 = textColor,

		[OnEvent "SelectionGained"] = function()
			engagement.Selected:set(true)
		end,
		[OnEvent "SelectionLost"] = function()
			engagement.Selected:set(false)
		end,
		[OnEvent "MouseEnter"] = function()
			engagement.PointerOver:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			engagement.PointerOver:set(false)
		end,
		[OnEvent "Activated"] = function()
			if props.OnActivated then
				props.OnActivated()
			end
		end,

		[Children] = children,
	} :: TextButton
end

return Tab
