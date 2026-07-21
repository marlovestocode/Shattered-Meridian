--!strict
--[[
	Tab.lua

	Owns: a selectable chip/tab button -- same sharp-bordered visual family as Button.lua and
	Panel.lua, but keyed off a persistent, caller-driven Selected prop instead of Button.lua's
	transient hover/press-only state. Two call sites in DevMenu/init.lua: the Spawn/Admin/Tuning tab
	strip, and the Godmode/Flight admin toggles (whose Selected reflects the *actual* replicated
	Humanoid attribute, not a locally-guessed toggle -- see DevMenuClient.lua's watchTarget). General
	enough for a future Menus.lua tab strip, but built for these actual call sites, not a speculative
	one.

	Selected gets Tokens.Color.SurfaceElevated + a BorderAccent stroke (docs/ui-ux-philosophy.md's
	"borders communicate importance: brighter edge highlight"); unselected stays Tokens.Color.Surface
	+ BorderSubtle, matching every other panel/button's resting state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TabProps = {
	Text: UsedAs<string>,
	Selected: UsedAs<boolean>,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	OnActivated: (() -> ())?,
}

local function Tab(scope: Scope, props: TabProps): TextButton
	local isHovering = scope:Value(false)

	local backgroundColor = scope:Computed(function(use)
		if use(props.Selected) or use(isHovering) then
			return Tokens.Color.SurfaceElevated
		end
		return Tokens.Color.Surface
	end)

	local borderColor = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Color.BorderAccent else Tokens.Color.BorderSubtle
	end)

	local textColor = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)

	return scope:New "TextButton" {
		Size = props.Size or UDim2.fromOffset(120, Tokens.Control.StepButtonSize),
		LayoutOrder = props.LayoutOrder,
		AutoButtonColor = false,
		BackgroundColor3 = backgroundColor,
		BorderSizePixel = 0,
		Text = props.Text,
		Font = Tokens.Type.Body.Font,
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

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.CornerRadius,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
			},
		},
	} :: TextButton
end

return Tab
