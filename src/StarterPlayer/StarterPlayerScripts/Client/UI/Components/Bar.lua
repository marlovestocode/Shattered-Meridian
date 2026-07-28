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

	FillColorSecondary/Glow (docs/design/intro-redesign-figma-spec.md section 5's stat-track fill,
	`linear-gradient(90deg, <color>55, <color>)` + `box-shadow 0 0 <n>px <color>NN`) are both opt-in
	and default off, so every pre-redesign caller keeps today's flat, glow-less fill unchanged. NOT
	added: a TickCount prop for the spec's 9 per-row tick marks -- the redesign cut both the points
	dial and the tick marks (user decision, 2026-07-25: the ticks implied a 10-step scale over a real
	5-20 range that corresponds to nothing), so a TickCount prop would have no caller in this
	codebase; adding it anyway would be exactly the speculative, never-exercised surface this file's
	own restraint is meant to avoid. Re-add it deliberately if a future design brings ticks back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Meter = require(script.Parent.Parent.Meter)
local Glow = require(script.Parent.Glow)

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
	-- Second gradient stop for the fill. The gradient runs FillColorSecondary (left) -> FillColor
	-- (right) with a built-in alpha ramp from the spec's own "55" hex suffix (~33% opacity) up to
	-- fully opaque, so passing the SAME Color3 as FillColor reproduces the spec's single-hue alpha
	-- ramp exactly; a genuinely different Color3 blends two hues instead. Also swaps to Danger under
	-- CriticalBelow, same as the flat-fill path, so the gradient never quietly drops the
	-- color-is-not-the-only-cue rule this file's header commits to.
	FillColorSecondary: Color3?,
	-- Soft glow around the filled portion (Components/Glow.lua), tracking the fill's own color and
	-- width live.
	Glow: boolean?,
}

-- The spec's own "55" hex alpha suffix on the gradient's low (left) end; the high end is the plain
-- "<color>" stop, fully opaque.
local GRADIENT_START_TRANSPARENCY = 1 - (0x55 / 0xFF)
local GLOW_SPREAD = 6 -- matches the spec's own "0 0 6px" bar-glow radius.
local GLOW_TRANSPARENCY = 0.7 -- between the spec's "44"/"55" hex alpha suffixes on different bars.

local function Bar(scope: Scope, props: BarProps): Frame
	local meter = Meter.Compute(scope, props)
	local fraction = meter.Fraction
	local isCritical = meter.IsCritical
	local fillColor = meter.FillColor

	local fillSize = scope:Computed(function(use)
		return UDim2.fromScale(use(fraction), 1)
	end)

	local fillChildren: { Instance } = {
		scope:New "UICorner" {
			CornerRadius = Tokens.Radius.Sharp,
		},
	}
	if props.FillColorSecondary then
		local secondary = props.FillColorSecondary :: Color3
		table.insert(
			fillChildren,
			scope:New "UIGradient" {
				Color = scope:Computed(function(use)
					local leadingStop = if use(isCritical) then Tokens.Color.Danger else secondary
					return ColorSequence.new({
						ColorSequenceKeypoint.new(0, leadingStop),
						ColorSequenceKeypoint.new(1, use(fillColor)),
					})
				end),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, GRADIENT_START_TRANSPARENCY),
					NumberSequenceKeypoint.new(1, 0),
				}),
			}
		)
	end

	local children: { Instance } = {
		scope:New "UICorner" {
			CornerRadius = Tokens.Radius.Sharp,
		},
		-- Non-color critical cue: a stroke that only appears under threshold, so the signal
		-- survives for colorblind players even if the fill-color shift doesn't read.
		scope:New "UIStroke" {
			Color = Tokens.Color.Danger,
			Thickness = scope:Computed(function(use)
				return if use(isCritical) then 2 else 0
			end),
		},
	}
	if props.Glow then
		-- ZIndex 1, strictly below Fill's own ZIndex 2 below -- Roblox renders same-ZIndex siblings
		-- in an unspecified order, so this glow needs an explicit lower value rather than relying on
		-- insertion order to stay behind the fill it's glowing.
		table.insert(
			children,
			Glow(scope, {
				Color = fillColor,
				Size = fillSize,
				ZIndex = 1,
				Spread = GLOW_SPREAD,
				Transparency = GLOW_TRANSPARENCY,
			})
		)
	end
	table.insert(
		children,
		scope:New "Frame" {
			Name = "Fill",
			Size = fillSize,
			ZIndex = 2,
			BackgroundColor3 = fillColor,
			BorderSizePixel = 0,

			[Children] = fillChildren,
		}
	)

	return scope:New "Frame" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromOffset(200, 18),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,

		[Children] = children,
	} :: Frame
end

return Bar
