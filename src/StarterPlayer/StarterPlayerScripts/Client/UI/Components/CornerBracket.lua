--!strict
--[[
	CornerBracket.lua

	Owns: the tactical corner-bracket accent -- an L-shaped arm pair plus a diamond rivet chip at the
	elbow, anchored to one corner of its parent via the same "anchor a frame's own corner to a parent
	corner point" trick used throughout this UI framework (see Geometry.lua's header, LockOnReticle's
	ReticleTicks). Originally a private helper inside Panel.lua, built for docs/design/frames/
	hotbar-frame.svg's corner-bracket treatment; extracted here once AbilitySlot.lua needed the same
	vocabulary at a much smaller scale (see that file's header for why) -- Panel.lua's own constants
	(12px arms) would read as oversized on a 40px tile, so this takes its geometry as props instead of
	hardcoding Panel's numbers, letting each caller pick a scale that fits its own tile size.

	Pure Frame composition, same "no image asset needed" discipline as VitalIcon.lua's procedural
	glyphs -- see that file's header for why this repo doesn't guess at rbxassetids.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Geometry = require(script.Parent.Parent.Geometry)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type CornerBracketProps = {
	ArmLength: number,
	ArmThickness: number,
	-- Omit both for a plain L-shape with no rivet chip -- the redesign's own brackets
	-- (docs/design/intro-redesign-figma-spec.md section 3.3) are unornamented. RivetInset only means
	-- anything alongside a real RivetSize, so the two are optional together; the existing
	-- hotbar-frame.svg-derived brackets (Panel.lua's CornerAccent, AbilitySlot.lua) keep passing both.
	RivetSize: number?,
	RivetInset: number?,
	Color: UsedAs<Color3>,
	Transparency: UsedAs<number>?,
	ZIndex: number?,
}

local CornerBracket = {}

-- One corner's worth of pieces (two arms, plus a rivet if RivetSize is given). `corner` is one of
-- Geometry.CORNERS.
local function buildOne(scope: Scope, corner: Vector2, props: CornerBracketProps): { Instance }
	local transparency: UsedAs<number> = props.Transparency or 0
	local zIndex = props.ZIndex or 5

	local pieces: { Instance } = {
		scope:New "Frame" {
			Name = "BracketArmHorizontal",
			AnchorPoint = corner,
			Position = UDim2.fromScale(corner.X, corner.Y),
			Size = UDim2.fromOffset(props.ArmLength, props.ArmThickness),
			BackgroundColor3 = props.Color,
			BackgroundTransparency = transparency,
			BorderSizePixel = 0,
			ZIndex = zIndex,
		},
		scope:New "Frame" {
			Name = "BracketArmVertical",
			AnchorPoint = corner,
			Position = UDim2.fromScale(corner.X, corner.Y),
			Size = UDim2.fromOffset(props.ArmThickness, props.ArmLength),
			BackgroundColor3 = props.Color,
			BackgroundTransparency = transparency,
			BorderSizePixel = 0,
			ZIndex = zIndex,
		},
	}

	if props.RivetSize then
		-- The rivet sits inward along the diagonal from the corner -- which direction "inward" is
		-- depends on which corner this is, so this is the one place sign matters.
		local rivetInset = props.RivetInset or 0
		local insetX = if corner.X == 0 then rivetInset else -rivetInset
		local insetY = if corner.Y == 0 then rivetInset else -rivetInset
		table.insert(
			pieces,
			scope:New "Frame" {
				Name = "BracketRivet",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(corner.X, insetX, corner.Y, insetY),
				Size = UDim2.fromOffset(props.RivetSize, props.RivetSize),
				Rotation = 45,
				BackgroundColor3 = props.Color,
				BackgroundTransparency = transparency,
				BorderSizePixel = 0,
				ZIndex = zIndex,
			}
		)
	end

	return pieces
end

-- All four corners' pieces, flattened into one list -- the common case every current caller wants.
function CornerBracket.BuildAll(scope: Scope, props: CornerBracketProps): { Instance }
	local pieces: { Instance } = {}
	for _, corner in ipairs(Geometry.CORNERS) do
		for _, piece in ipairs(buildOne(scope, corner, props)) do
			table.insert(pieces, piece)
		end
	end
	return pieces
end

return CornerBracket
