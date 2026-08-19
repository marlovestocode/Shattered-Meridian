--!strict
--[[
	ScrollArea.lua

	Owns: the ScrollingFrame shell every scrollable list in this UI shares -- ScrollingDirection,
	AutomaticCanvasSize, CanvasSize, and the scrollbar's own look (3px, no track, Tokens.Border.
	Standard's tint). That scrollbar spec is docs/design/intro-redesign-figma-spec.md section 7's --
	before this existed it was hand-retyped at 14 call sites (ArtsTab/CharacterTab/EmotesTab/
	BountyTab/KeybindsTab/GameplayTab/DevMenu's Sidebar+ContentArea/MoveEditor's Sidebar+
	PropertyEditor+MoveList/LiveConsole), which meant a design change to it was a 14-file diff with
	no compiler help.

	Deliberately does NOT own the inner UIListLayout/UIPadding -- those vary for real reasons across
	callers (padding amount, HorizontalAlignment, whether right padding exists at all to clear the
	scrollbar) and belong to each caller's own Children, the same way Panel.lua doesn't own what a
	caller puts in ITS Children either. This component only collapses the part that was genuinely
	byte-for-byte identical everywhere: 9 exact 8-line matches plus 5 more at a one-line offset, per
	the structure audit that found this duplication (2026-08-19).

	BackgroundTransparency/BackgroundColor3 default to fully transparent (every caller but one wants
	a see-through scroll area layered over its own panel background) but are overridable -- Client/UI/
	Screens/LiveConsole/init.lua's log list is the one exception, an opaque framed panel in its own
	right.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ScrollAreaProps = {
	Name: string?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
	-- Defaults to fully transparent -- see file header.
	BackgroundColor3: UsedAs<Color3>?,
	BackgroundTransparency: UsedAs<number>?,
	Children: UsedAs<{ Instance }>?,
}

local function ScrollArea(scope: Scope, props: ScrollAreaProps): ScrollingFrame
	return scope:New "ScrollingFrame" {
		Name = props.Name or "ScrollArea",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundColor3 = props.BackgroundColor3,
		BackgroundTransparency = if props.BackgroundTransparency ~= nil then props.BackgroundTransparency else 1,
		BorderSizePixel = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.fromScale(0, 0),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Border.Standard.Color,
		ScrollBarImageTransparency = Tokens.Border.Standard.Transparency,

		[Children] = props.Children,
	} :: ScrollingFrame
end

return ScrollArea
