--!strict
-- A compact readiness rail for the two intentional gaps between parry attempts. It fills toward
-- readiness and disappears at zero remaining time, keeping the hotbar quiet while parry is usable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type Props = {
	Visible: UsedAs<boolean>,
	Fraction: UsedAs<number>,
	RemainingSeconds: UsedAs<number>,
}

local function ParryTimer(scope: Scope, props: Props): Frame
	local label = scope:Computed(function(use): string
		return string.format("PARRY  %.1fs", math.ceil(use(props.RemainingSeconds) * 10) / 10)
	end)

	return scope:New "Frame" {
		Name = "ParryTimer",
		LayoutOrder = 4,
		Size = UDim2.fromOffset(168, 16),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = props.Visible,

		[Children] = {
			Label(scope, {
				Text = label,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextSecondary,
				Position = UDim2.fromOffset(0, 0),
				Size = UDim2.new(1, 0, 0, 10),
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			scope:New "Frame" {
				Name = "Track",
				Position = UDim2.new(0, 0, 1, -4),
				Size = UDim2.new(1, 0, 0, 3),
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,

				[Children] = {
					scope:New "UIStroke" {
						Color = Tokens.Border.Hairline.Color,
						Transparency = Tokens.Border.Hairline.Transparency,
					},
					scope:New "Frame" {
						Name = "ReadyFill",
						Size = scope:Computed(function(use)
							return UDim2.fromScale(math.clamp(use(props.Fraction), 0, 1), 1)
						end),
						BackgroundColor3 = Tokens.Color.AccentPrimary,
						BorderSizePixel = 0,
					},
				},
			},
		},
	} :: Frame
end

return ParryTimer
