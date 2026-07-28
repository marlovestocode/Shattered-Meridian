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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
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
}

local function Tab(scope: Scope, props: TabProps): TextButton
	local isHovering = scope:Value(false)
	local trackedCaps = props.TrackedCaps == true

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
		scope:New "UIStroke" {
			Color = borderColor,
			Thickness = 1,
			Transparency = borderTransparency,
		},
	}
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
		BorderSizePixel = 0,
		-- Under TrackedCaps this stays set (for gamepad/screen-reader nav, ActionIcon.lua's
		-- convention) but invisible -- the TrackedLabel child renders the visible copy instead.
		Text = if trackedCaps then string.upper(peek(props.Text)) else props.Text,
		TextTransparency = if trackedCaps then 1 else nil,
		FontFace = Tokens.Type.Body.Face,
		TextSize = Tokens.Type.Body.Size,
		TextColor3 = textColor,

		[OnEvent "MouseEnter"] = function()
			isHovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovering:set(false)
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
