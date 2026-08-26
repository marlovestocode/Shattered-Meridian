--!strict
--[[
	Inset.lua

	Owns: padding, as one expression instead of four.

	A UIPadding is four separate UDim properties, and this UI writes one on almost every container --
	which meant six lines of boilerplate per inset, and four independent places for a typo to hide:

		scope:New "UIPadding" {
			PaddingTop = UDim.new(0, Tokens.Space.L),
			PaddingBottom = UDim.new(0, Tokens.Space.L),
			PaddingLeft = UDim.new(0, Tokens.Space.L),
			PaddingRight = UDim.new(0, Tokens.Space.L),
		}

		Inset(scope, Tokens.Space.L)              -- all four
		Inset(scope, { X = 20 })                  -- a band's horizontal inset only
		Inset(scope, { X = 16, Top = 12, Bottom = 16 })

	RETURNS A UIPadding, NOT A FRAME, and that is the whole design. Padding is a modifier on a
	container that already exists -- it belongs in that container's Children beside its layout, the
	same way UICorner and UIStroke do. Wrapping it in a Frame would add an instance per inset and,
	worse, would put a second box between a Stack and its children for a layout to have opinions
	about. Components/Stack.lua deliberately does not own padding for the same reason.

	Every value is a plain pixel number, expected to be a Tokens.Space step. No scale-based padding:
	a percentage inset makes the gutter grow with the panel, which is exactly what the redesign's
	fixed 16/20px chrome does not do.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

type Scope = Fusion.Scope<typeof(Fusion)>

-- A single number insets all four sides. The table form sets sides individually, where X/Y are
-- shorthand for a matched pair and a named side beats the axis it belongs to (so
-- `{ X = 16, Right = 0 }` is 16 left, 0 right -- the specific one wins, which is the only reading
-- that makes the shorthand worth having).
export type InsetSpec = number | {
	Top: number?,
	Bottom: number?,
	Left: number?,
	Right: number?,
	X: number?,
	Y: number?,
}

local function resolve(spec: InsetSpec): (number, number, number, number)
	if typeof(spec) == "number" then
		return spec, spec, spec, spec
	end
	local sides = spec :: { Top: number?, Bottom: number?, Left: number?, Right: number?, X: number?, Y: number? }
	local x = sides.X or 0
	local y = sides.Y or 0
	return sides.Top or y, sides.Bottom or y, sides.Left or x, sides.Right or x
end

local function Inset(scope: Scope, spec: InsetSpec): UIPadding
	local top, bottom, left, right = resolve(spec)
	return scope:New "UIPadding" {
		PaddingTop = UDim.new(0, top),
		PaddingBottom = UDim.new(0, bottom),
		PaddingLeft = UDim.new(0, left),
		PaddingRight = UDim.new(0, right),
	} :: UIPadding
end

return Inset
