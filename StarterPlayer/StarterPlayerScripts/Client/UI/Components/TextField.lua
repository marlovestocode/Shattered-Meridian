--!strict
--[[
	TextField.lua

	Owns: the text-input primitive -- no TextBox component existed anywhere in this codebase before
	this (BugReport's description field is the first user). Two-way bound to a caller-OWNED
	Fusion.Value<string> (not a one-way UsedAs<T> like every other component prop in this file) via
	Fusion's OnChange "Text" special key, so a live character counter elsewhere on the same screen
	can track input as it's typed, matching Button.lua/Tab.lua's sharp-bordered visual family
	(background/border pulled from Tokens.lua, focus reads the same "brighter edge highlight" the
	rest of this UI already uses for emphasis).

	Gamepad note: this is a plain Roblox TextBox -- once GuiService.SelectedObject/NextSelection*
	focus reaches it and the player presses their platform's "activate" button, Roblox's own native
	controller behavior opens the on-screen keyboard. Nothing here can or needs to trigger that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TextFieldProps = {
	-- Caller-owned Value, two-way bound -- unlike every other component's UsedAs<T> props, this
	-- component both reads AND writes into it (via OnChange "Text"), so callers must pass a real
	-- Fusion.Value<string>, not a Computed.
	Text: Fusion.Value<string>,
	PlaceholderText: string?,
	Multiline: boolean?,
	-- Enforced by truncating both the instance's own Text and props.Text on overflow -- see the
	-- OnChange handler below.
	MaxLength: number?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
}

local function TextField(scope: Scope, props: TextFieldProps): TextBox
	local isFocused = scope:Value(false)

	local borderColor = scope:Computed(function(use)
		return if use(isFocused) then Tokens.Color.BorderAccent else Tokens.Color.BorderSubtle
	end)

	local multiline = props.Multiline == true

	return scope:New "TextBox" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Color.Surface,
		BorderSizePixel = 0,
		Text = props.Text,
		PlaceholderText = props.PlaceholderText,
		PlaceholderColor3 = Tokens.Color.TextDisabled,
		Font = Tokens.Type.Body.Font,
		TextSize = Tokens.Type.Body.Size,
		TextColor3 = Tokens.Color.TextPrimary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = if multiline then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		TextWrapped = multiline,
		MultiLine = multiline,
		ClearTextOnFocus = false,

		[OnEvent "Focused"] = function()
			isFocused:set(true)
		end,
		[OnEvent "FocusLost"] = function()
			isFocused:set(false)
		end,
		[OnChange "Text"] = function(newText: string)
			local maxLength = props.MaxLength
			if maxLength and #newText > maxLength then
				-- Setting props.Text below to a value SHORTER than what the player just typed (e.g.
				-- an over-long paste) relies on this TextBox's own `Text = props.Text` binding above
				-- to push the truncated value back down onto the instance -- Fusion's normal
				-- Value->Instance sync, not anything special-cased here.
				props.Text:set(string.sub(newText, 1, maxLength))
				return
			end
			props.Text:set(newText)
		end,

		[Children] = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UICorner" {
				CornerRadius = Tokens.CornerRadius,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
			},
		},
	} :: TextBox
end

return TextField
