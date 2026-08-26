--!strict
--[[
	WheelHub.lua

	Owns: the medallion at the centre of the emote wheel and the readout printed on it -- the
	category eyebrow, the emote's name, the rule under it and the description. Split out of
	init.lua (where it was two bare Labels floating over the gameplay behind them) because it is a
	real surface with real state, not a caption: it has a plate, a border that answers the selection,
	and a second thing to say when nothing is selected at all.

	TEXT SWAPS INSTANTLY; ONLY THE CHROME EASES. Deliberate, and the one place this screen departs
	from "everything fades" -- docs/ui-ux-philosophy.md's Combat Text rule is "prioritize visibility,
	speed of recognition, contrast... should never require reading effort", and a name that
	cross-fades while the player is sweeping the cursor across eight slots is a name being read
	through its own transition. So the plate's stroke and fill ease on a spring and the words do not.

	THE NO-SELECTION STATE IS A REAL STATE, NOT AN EMPTY ONE. The cursor sitting inside this
	medallion's own radius means "nothing chosen" (WheelSelection.GetSelectedIndex's dead zone -- the
	circle this file draws IS that radius, handed to both from init.lua), and releasing there cancels.
	That is a thing the player has to be told, so the hub prints the instruction rather than going
	blank -- an empty medallion would read as a bug, and a wheel that is silently armed to fire
	whatever the cursor drifted nearest is the behaviour the dead zone exists to remove.

	Does not own: the dial the medallion sits in (WheelDial.lua draws the boundary ring at this same
	radius), the slots (WheelSegment.lua), or which emote is selected (init.lua computes it from the
	shared SelectedIndex and hands the definition in).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local WheelCategory = require(script.Parent.WheelCategory)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type WheelHubProps = {
	-- nil means the cursor is inside the dead zone -- see this file's header. Not "no emotes exist".
	Emote: UsedAs<Types.EmoteDefinition?>,
	Radius: number,
	ZIndex: number?,
}

-- What the medallion says while nothing is selected. Instruction, not decoration: this is the only
-- place the wheel tells a first-time player that the centre is a cancel and the rim is a commit.
local IDLE_EYEBROW = "EMOTE WHEEL"
local IDLE_NAME = "Select an Emote"
local IDLE_DESCRIPTION = "Aim outward to choose. Release to perform."

-- Horizontal breathing room between the text column and the plate's own curved edge. Larger than a
-- rectangular panel's inset would be, because the boundary here curves away from the text at the top
-- and bottom of the column rather than running parallel to it.
local CONTENT_INSET = 24
local CONTENT_GAP = 6

local RULE_WIDTH = 34
local RULE_HEIGHT = 1

local PLATE_FILL_RESTING = 0.34
local PLATE_FILL_SELECTED = 0.2
local INNER_RING_INSET = 7

local function WheelHub(scope: Scope, props: WheelHubProps): Frame
	local radius = props.Radius
	local contentWidth = radius * 2 - CONTENT_INSET * 2

	local hasSelection = scope:Computed(function(use)
		return use(props.Emote) ~= nil
	end)

	local selectedProgress = scope:Spring(
		scope:Computed(function(use)
			return if use(hasSelection) then 1 else 0
		end),
		Tokens.Motion.StateSpring.Speed,
		Tokens.Motion.StateSpring.Damping
	)

	local eyebrowText = scope:Computed(function(use)
		local definition = use(props.Emote)
		return if definition then WheelCategory.Label(definition.Category) else IDLE_EYEBROW
	end)

	local eyebrowColor = scope:Computed(function(use)
		local definition = use(props.Emote)
		return if definition then WheelCategory.Tint(definition.Category) else Tokens.Color.TextDisabled
	end)

	local nameText = scope:Computed(function(use)
		local definition = use(props.Emote)
		return if definition then definition.DisplayName else IDLE_NAME
	end)

	local nameColor = scope:Computed(function(use)
		return if use(hasSelection) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextSecondary
	end)

	local descriptionText = scope:Computed(function(use)
		local definition = use(props.Emote)
		if not definition then
			return IDLE_DESCRIPTION
		end
		return definition.Description or ""
	end)

	local plateTransparency = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return PLATE_FILL_RESTING - progress * (PLATE_FILL_RESTING - PLATE_FILL_SELECTED)
	end)

	local strokeColor = scope:Computed(function(use)
		return Tokens.Border.Standard.Color:Lerp(Tokens.Color.AccentPrimaryBright, use(selectedProgress))
	end)

	local strokeTransparency = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return Tokens.Border.Standard.Transparency
			- progress * (Tokens.Border.Standard.Transparency - Tokens.Border.Lit.Transparency)
	end)

	local ruleColor = scope:Computed(function(use)
		local definition = use(props.Emote)
		return if definition then WheelCategory.Tint(definition.Category) else Tokens.Border.Standard.Color
	end)

	local ruleTransparency = scope:Computed(function(use)
		return 0.75 - use(selectedProgress) * 0.35
	end)

	return scope:New "Frame" {
		Name = "WheelHub",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(radius * 2, radius * 2),
		BackgroundColor3 = Tokens.Color.Surface,
		BackgroundTransparency = plateTransparency,
		BorderSizePixel = 0,
		ZIndex = props.ZIndex or 5,

		[Children] = {
			scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
			scope:New "UIStroke" {
				Color = strokeColor,
				Transparency = strokeTransparency,
				Thickness = 1,
			},

			-- The second, inner circle. A single ring reads as a coaster; two concentric rings at
			-- different weights read as a machined bezel, which is the register the philosophy's
			-- "ancient but refined" line asks for -- and it costs one Frame.
			scope:New "Frame" {
				Name = "Bezel",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset((radius - INNER_RING_INSET) * 2, (radius - INNER_RING_INSET) * 2),
				BackgroundTransparency = 1,
				ZIndex = (props.ZIndex or 5) + 1,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
					scope:New "UIStroke" {
						Color = Tokens.Border.Hairline.Color,
						Transparency = Tokens.Border.Hairline.Transparency,
						Thickness = 1,
					},
				},
			},

			-- The text column. Fixed width, automatic height, centred on the plate -- so a
			-- one-line description and a two-line one both stay optically centred without either
			-- being given a hand-counted height (Components/Label.lua's AutoHeight contract).
			scope:New "Frame" {
				Name = "Readout",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(contentWidth, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				ZIndex = (props.ZIndex or 5) + 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, CONTENT_GAP),
					},

					Label(scope, {
						Text = eyebrowText,
						Scale = "Detail",
						Color = eyebrowColor,
						Size = UDim2.fromOffset(contentWidth, 0),
						AutoHeight = true,
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 1,
					}),

					Label(scope, {
						Text = nameText,
						Scale = "CardTitle",
						Color = nameColor,
						Size = UDim2.fromOffset(contentWidth, 0),
						AutoHeight = true,
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 2,
					}),

					scope:New "Frame" {
						Name = "Rule",
						Size = UDim2.fromOffset(RULE_WIDTH, RULE_HEIGHT),
						BackgroundColor3 = ruleColor,
						BackgroundTransparency = ruleTransparency,
						BorderSizePixel = 0,
						LayoutOrder = 3,
					},

					Label(scope, {
						Text = descriptionText,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromOffset(contentWidth, 0),
						AutoHeight = true,
						TextWrapped = true,
						LineHeight = Tokens.Leading.Prose,
						TextXAlignment = Enum.TextXAlignment.Center,
						LayoutOrder = 4,
					}),
				},
			},
		},
	} :: Frame
end

return WheelHub
