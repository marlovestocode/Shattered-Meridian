--!strict
--[[
	Bar.lua

	Owns: the generic horizontal progress-bar primitive shared by every non-hotbar meter in the
	game -- ability/cooldown, Meridian XP, and any other linear meter once that HUD element exists.
	The central hotbar's Health/Qi/Posture vitals use the icon-tile form factor owned by
	VitalIcon.lua instead (docs/ui-ux-philosophy.md); this remains the primitive for a classic
	bar-shaped meter elsewhere. One implementation, one place to get the accessibility rule right, per
	docs/ui-ux-philosophy.md's Design tokens section ("this is the UI equivalent of Constants.lua").

	Critical state accessibility: docs/ui-ux-philosophy.md requires that "color choices for critical
	state ... must not rely on color alone -- pair with shape, position, or motion cues." This
	component bakes that in at the primitive level via the CriticalBelow prop -- a border-stroke
	cue that appears in addition to the color shift, not instead of it -- so every screen built on
	top of Bar gets the accessibility rule for free instead of having to remember it per instance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Meter = require(script.Parent.Parent.Meter)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type BarProps = {
	Value: UsedAs<number>,
	Max: UsedAs<number>,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	FillColor: UsedAs<Color3>?,
	-- Fraction (0-1) below which the bar is considered critical, e.g. 0.25 for "below 25%".
	-- Omit for bars that don't have a meaningful critical state (a cooldown bar, say).
	CriticalBelow: number?,
}

local function Bar(scope: Scope, props: BarProps): Frame
	local meter = Meter.Compute(scope, props)
	local fraction = meter.Fraction
	local isCritical = meter.IsCritical
	local fillColor = meter.FillColor

	return scope:New "Frame" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromOffset(200, 18),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.CornerRadius,
			},
			-- Non-color critical cue: a stroke that only appears under threshold, so the signal
			-- survives for colorblind players even if the fill-color shift doesn't read.
			scope:New "UIStroke" {
				Color = Tokens.Color.Danger,
				Thickness = scope:Computed(function(use)
					return if use(isCritical) then 2 else 0
				end),
			},
			scope:New "Frame" {
				Name = "Fill",
				Size = scope:Computed(function(use)
					return UDim2.fromScale(use(fraction), 1)
				end),
				BackgroundColor3 = fillColor,
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.CornerRadius,
				},
			},
		},
	} :: Frame
end

return Bar
