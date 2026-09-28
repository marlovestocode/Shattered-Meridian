--!strict
--[[
	KillFeedRow.lua

	Owns: one line of the kill feed (Screens/DeathFeed's TopRight tile) -- who slew whom, and whether
	the local player was in it.

	WORDS, NOT A GLYPH. "A slew B" rather than "A > B" or an arrow: the arrow characters are not in
	every font this UI renders with, and a verb reads correctly in the world's own register. When the
	local player is one of the two, their name becomes "You"/"you" -- the fastest thing to read in a
	list of strangers.

	INVOLVEMENT IS A BORDER AND A WORD, never colour alone (ui-ux-philosophy.md): bronze edge for a
	kill the local player made (the same bronze as the progression it earned them), the Danger edge for
	their own death, no edge for everyone else's fight.

	Does not own: which deaths become rows, how long they stay, or how many (Screens/DeathFeed and
	DeathConstants.KillFeed) -- this renders one already-decided entry.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Inset = require(script.Parent.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type Involvement = "Killer" | "Victim" | "None"

export type KillFeedEntry = {
	KillerName: string,
	VictimName: string,
	Involvement: Involvement,
	-- Newer rows get a higher Order; the row renders above older ones.
	Order: number,
}

local ROW_HEIGHT = 24

local function textFor(entry: KillFeedEntry): string
	if entry.Involvement == "Killer" then
		return `You slew {entry.VictimName}`
	elseif entry.Involvement == "Victim" then
		return `{entry.KillerName} slew you`
	end
	return `{entry.KillerName} slew {entry.VictimName}`
end

local function KillFeedRow(scope: Scope, entry: KillFeedEntry): Frame
	local edge: Color3? = if entry.Involvement == "Killer"
		then Tokens.Color.AccentSecondary
		elseif entry.Involvement == "Victim" then Tokens.Color.Danger
		else nil

	local children: { Instance } = {
		scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
		Inset(scope, { X = Tokens.Space.S }),
		Label(scope, {
			Text = textFor(entry),
			Scale = "Detail",
			Color = if entry.Involvement == "None" then Tokens.Color.TextSecondary else Tokens.Color.TextPrimary,
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	}
	if edge then
		table.insert(
			children,
			scope:New "UIStroke" {
				Color = edge,
				Thickness = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}
		)
	end

	return scope:New "Frame" {
		Name = "KillFeedRow",
		-- Newest first: UIListLayout sorts ascending, so the newest (highest Order) gets the lowest value.
		LayoutOrder = -entry.Order,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Tokens.Color.Surface,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,

		[Children] = children,
	} :: Frame
end

return KillFeedRow
