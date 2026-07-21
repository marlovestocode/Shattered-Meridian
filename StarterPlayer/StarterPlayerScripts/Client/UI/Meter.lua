--!strict
--[[
	Meter.lua

	Owns: the fraction/isCritical/fillColor Fusion Computed logic shared by every meter primitive
	(Bar.lua's horizontal fill, VitalIcon.lua's icon-tile fill) -- clamp value/max into 0-1, compare
	against an optional CriticalBelow threshold, and pick Tokens.Color.Danger vs. the caller's own
	FillColor. This is accessibility-relevant color/threshold logic (docs/ui-ux-philosophy.md's
	Critical States rule: "must not rely on color alone") that should have exactly one
	implementation, not two independently-maintained copies that can drift apart.

	Does not own: how a meter renders (fill Size/Position, stroke thickness/color, glyph) -- each
	caller still owns its own visual composition; this only computes the three reactive values every
	meter needs to drive it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type MeterProps = {
	Value: UsedAs<number>,
	Max: UsedAs<number>,
	FillColor: UsedAs<Color3>?,
	-- Fraction (0-1) below which the meter is considered critical, e.g. 0.25 for "below 25%". Omit
	-- for a meter with no meaningful critical state (a cooldown bar, say).
	CriticalBelow: number?,
}

local Meter = {}

-- Fraction: value/max clamped to 0-1, 0 whenever max <= 0 (never divides by zero).
-- IsCritical: false when CriticalBelow is omitted; otherwise true once Fraction drops below it.
-- FillColor: Tokens.Color.Danger while critical, else the caller's own FillColor (defaulting to
-- Tokens.Color.BorderAccent).
function Meter.Compute(scope: Scope, props: MeterProps)
	local fraction = scope:Computed(function(use)
		local max = use(props.Max)
		if max <= 0 then
			return 0
		end
		return math.clamp(use(props.Value) / max, 0, 1)
	end)

	local isCritical = scope:Computed(function(use)
		local threshold = props.CriticalBelow
		if threshold == nil then
			return false
		end
		return use(fraction) < threshold
	end)

	local fillColor = scope:Computed(function(use)
		if use(isCritical) then
			return Tokens.Color.Danger
		end
		return use(props.FillColor or Tokens.Color.BorderAccent)
	end)

	return {
		Fraction = fraction,
		IsCritical = isCritical,
		FillColor = fillColor,
	}
end

return Meter
