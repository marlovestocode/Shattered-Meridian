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
local Inset = require(script.Parent.Inset)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local peek = Fusion.peek

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
	-- Optional: fires when focus leaves this field, with the field's current text -- for a caller
	-- (the Move Editor's PropertyEditor) that wants to commit an edit once the admin is done typing
	-- rather than on every keystroke (the two-way Text binding above already updates live for local
	-- display; this is only for callers that also need a "done editing" moment).
	--
	-- `enterPressed` and `cause` are Roblox's own FocusLost arguments, forwarded rather than dropped:
	-- "the author pressed Enter", "the author clicked away" and "the author pressed Escape" are three
	-- different intentions, and a caller that treats an abandoned entry as a commit silently saves
	-- something nobody asked for. `cause` is nil when focus was released programmatically
	-- (TextBox:ReleaseFocus) rather than by an input. Callers that only need the text ignore both.
	OnFocusLost: ((text: string, enterPressed: boolean, cause: InputObject?) -> ())?,
}

local function TextField(scope: Scope, props: TextFieldProps): TextBox
	local isFocused = scope:Value(false)

	local borderColor = scope:Computed(function(use)
		return if use(isFocused) then Tokens.Color.AccentPrimary else Tokens.Border.Standard.Color
	end)

	-- Focused draws the accent fully opaque (unchanged); resting uses Tokens.Border.Standard's own
	-- translucency instead of assuming opaque, since Standard.Color alone at full opacity would read
	-- as a bright violet outline rather than the intended quiet, unfocused edge.
	local borderTransparency = scope:Computed(function(use)
		return if use(isFocused) then 0 else Tokens.Border.Standard.Transparency
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
		FontFace = Tokens.Type.Body.Face,
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
		[OnEvent "FocusLost"] = function(enterPressed: boolean, cause: InputObject?)
			isFocused:set(false)
			if props.OnFocusLost then
				props.OnFocusLost(peek(props.Text), enterPressed, cause)
			end
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
			Inset(scope, Tokens.Space.S),
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
				Transparency = borderTransparency,
			},
		},
	} :: TextBox
end

return TextField
