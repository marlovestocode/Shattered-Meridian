--!strict
--[[
	SectionHeading.lua

	Owns: the tracked-caps bronze eyebrow that opens each block of the character menu -- ATTRIBUTES,
	DERIVED STATS, MERIDIAN TIER, MASTERED ARTS, ACTIVE BOUNTIES -- together with the small
	right-aligned note that so often sits opposite it ("3 / 5 slots", "0 points unspent").

	NOT Components/Section.lua. That one is a bordered CARD with a title, a description and a body:
	it draws chrome and owns the thing under it. This draws no chrome at all -- it is one line of
	type over content that stands on its own, which is how the whole menu register works (the
	separation between blocks is whitespace and an occasional Divider, never a nested box). Nesting
	Section cards inside the menu's own panel would double the border count on every block, the
	same reason BountyTab.lua's header gives for not wrapping itself in a second Panel.

	Bronze, not violet, and that is a semantic choice rather than decoration: Tokens.Color.
	AccentSecondary is this palette's "committed / permanent" register (see its comment in
	Tokens.lua), and a section name is the one piece of type on screen that is never going to change.
	Violet is reserved for things the player can act on.

	Text is a plain string because it renders through Components/TrackedLabel.lua, which reads its
	string once at construction -- every heading in this UI is a fixed noun. The NOTE beside it is
	reactive, since that is exactly the half that counts something.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local TrackedLabel = require(script.Parent.TrackedLabel)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type SectionHeadingProps = {
	-- Static -- see file header.
	Text: string,
	-- The small right-aligned count/qualifier. Omit for a heading that stands alone.
	Note: UsedAs<string>?,
	NoteColor: UsedAs<Color3>?,
	-- Defaults to the bronze accent. Override only for a heading that genuinely belongs to a
	-- different register (a danger-colored one over a warning block, say).
	Color: UsedAs<Color3>?,
	-- An already-built instance to place at the right edge INSTEAD of Note -- a StatusTag, typically.
	-- Note and Accessory are mutually exclusive at the call site; passing both is a caller bug that
	-- shows up immediately as two overlapping right-aligned objects rather than being silently
	-- resolved here in favour of one.
	Accessory: Instance?,
	LayoutOrder: UsedAs<number>?,
	Size: UsedAs<UDim2>?,
	Visible: UsedAs<boolean>?,
}

local HEIGHT = 24

local function SectionHeading(scope: Scope, props: SectionHeadingProps): Frame
	local children: { Instance } = {
		TrackedLabel(scope, {
			Text = string.upper(props.Text),
			Scale = "Eyebrow",
			Color = props.Color or Tokens.Color.AccentSecondary,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
		}),
	}

	if props.Note then
		table.insert(
			children,
			Label(scope, {
				Text = props.Note,
				Scale = "NumeralSmall",
				Color = props.NoteColor or Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromScale(0.5, 1),
				TextXAlignment = Enum.TextXAlignment.Right,
			})
		)
	end

	if props.Accessory then
		-- Wrapped in a right-anchored, content-sized holder rather than having its own AnchorPoint/
		-- Position written here: the accessory belongs to whichever component built it, and reaching
		-- into another component's instance to reposition it is how two files end up disagreeing
		-- about who owns a property.
		table.insert(
			children,
			scope:New "Frame" {
				Name = "Accessory",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(0, HEIGHT),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Right,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					props.Accessory,
				},
			}
		)
	end

	return scope:New "Frame" {
		Name = `SectionHeading_{props.Text}`,
		Size = props.Size or UDim2.new(1, 0, 0, HEIGHT),
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = children,
	} :: Frame
end

return SectionHeading
