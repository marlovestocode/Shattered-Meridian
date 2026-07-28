--!strict
--[[
	LatticeOverlay.lua

	Owns: the hex-lattice texture overlay behind every "creator" panel (docs/design/
	intro-redesign-figma-spec.md section 3.2) -- a 60x69px tiled hexagon-outline pattern at 2.5%
	opacity. Real texture only: a 60x69 tile over an 800x640 panel is ~780 repeats, so approximating
	the hexagon outline with Frames (the way CornerBracket/Divider approximate their own straight-line
	geometry) is explicitly the wrong call here -- see the redesign handoff's own note under this
	component's Phase A entry.

	Renders NOTHING (returns nil, not a placeholder Frame) when TextureId is omitted, same convention
	as VitalIcon.lua's IconAssetId / ChamferedSurface.Fill's own availability check: this repo never
	guesses at an rbxassetid, and there is no cheap procedural fallback for this one (unlike a vital's
	glyph). A caller must check the return value before inserting it into its own Children, the same
	way Panel.lua already checks ChamferedSurface.Fill's return.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type LatticeOverlayProps = {
	-- A real uploaded texture (docs/design/icons/ convention) tiling the 60x69 hexagon-outline
	-- pattern. No id yet exists in this repo -- see this file's header on why nothing renders without
	-- one, rather than an approximation.
	TextureId: string?,
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	ZIndex: number?,
	Color: UsedAs<Color3>?,
}

-- The design's own tile dimensions (docs/design/intro-redesign-figma-spec.md section 3.2) -- a fixed
-- property of the source pattern, not a general spacing value, so it lives here rather than in
-- Tokens.
local TILE_SIZE = UDim2.fromOffset(60, 69)
local OPACITY = 0.025

local function LatticeOverlay(scope: Scope, props: LatticeOverlayProps): ImageLabel?
	if not props.TextureId then
		return nil
	end

	return scope:New "ImageLabel" {
		Name = "LatticeOverlay",
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		ZIndex = props.ZIndex,
		BackgroundTransparency = 1,
		Image = props.TextureId,
		ImageColor3 = props.Color or Tokens.Color.AccentPrimary,
		ImageTransparency = 1 - OPACITY,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = TILE_SIZE,
	} :: ImageLabel
end

return LatticeOverlay
