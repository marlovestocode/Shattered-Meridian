--!strict
--[[
	Button.lua

	Owns: the interactive button primitive -- background/border/hover/press treatment per
	Tokens.lua, sharp-edged per the locked Aesthetic direction.

	Hover/press are purely visual, scope-local Fusion state; they never touch ClientState or
	anything gameplay-relevant. Buttons only ever *request* -- matching
	luau-coding-standards.md's client/server split rule ("a client module should never contain a
	function named ApplyDamage -- it should contain RequestAttack"). What OnActivated does with
	that request is the caller's responsibility, not this component's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ButtonProps = {
	Text: UsedAs<string>,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	Disabled: UsedAs<boolean>?,
	OnActivated: (() -> ())?,
}

local function Button(scope: Scope, props: ButtonProps): TextButton
	local isHovering = scope:Value(false)
	local isPressing = scope:Value(false)
	local disabled: UsedAs<boolean> = if props.Disabled == nil then false else props.Disabled

	local backgroundColor = scope:Computed(function(use)
		if use(disabled) then
			return Tokens.Color.Surface
		elseif use(isPressing) then
			return Tokens.Color.BorderAccent
		elseif use(isHovering) then
			return Tokens.Color.SurfaceElevated
		end
		return Tokens.Color.Surface
	end)

	local textColor = scope:Computed(function(use)
		return if use(disabled) then Tokens.Color.TextDisabled else Tokens.Color.TextPrimary
	end)

	local isActive = scope:Computed(function(use)
		return not use(disabled)
	end)

	return scope:New "TextButton" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromOffset(160, Tokens.Control.RowHeight),
		LayoutOrder = props.LayoutOrder,
		AutoButtonColor = false,
		BackgroundColor3 = backgroundColor,
		BorderSizePixel = 0,
		Text = props.Text,
		Font = Tokens.Type.Body.Font,
		TextSize = Tokens.Type.Body.Size,
		TextColor3 = textColor,
		Active = isActive,

		[OnEvent "MouseEnter"] = function()
			isHovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovering:set(false)
			isPressing:set(false)
		end,
		[OnEvent "MouseButton1Down"] = function()
			isPressing:set(true)
		end,
		[OnEvent "MouseButton1Up"] = function()
			isPressing:set(false)
		end,
		[OnEvent "Activated"] = function()
			if not peek(disabled) and props.OnActivated then
				props.OnActivated()
			end
		end,

		[Children] = scope:New "UICorner" {
			CornerRadius = Tokens.CornerRadius,
		},
	} :: TextButton
end

return Button
