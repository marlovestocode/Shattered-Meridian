--!strict
--[[
	Panel.lua

	Owns: the base surface container every HUD/menu panel is built from -- background, border,
	and corner radius, all pulled from Tokens.lua. Applying the token set consistently here is
	what keeps every surface reading as the same visual family (docs/ui-ux-philosophy.md).

	CornerAccent (optional): the tactical corner-bracket treatment from
	docs/design/frames/hotbar-frame.svg -- four L-shaped forged-steel brackets with a rivet chip at
	each elbow, built entirely from Frame geometry (no image asset; see VitalIcon.lua's header for
	why this repo doesn't guess at rbxassetids). This is docs/ui-ux-philosophy.md's Shape Language
	("weapon-like geometry," "borders communicate importance... brighter edge highlight") applied
	as an additive overlay rather than an actual cut-corner silhouette -- true angular/hexagonal
	panel *shapes* still need the polygon geometry or image assets called out as a known gap in
	that doc's Implementation Notes. Off by default so existing panels (Menus' Root frame, etc.)
	are unaffected; the Hotbar opts in explicitly. Corner accents render in an overlay layer so a
	caller's content UIListLayout never tries to arrange the decorative bracket pieces.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Geometry = require(script.Parent.Parent.Geometry)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type PanelProps = {
	Name: string?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	-- Lets a panel size itself from its content (e.g. a UIListLayout + UIPadding among Children)
	-- instead of a hand-computed Size -- omit for the common case of an explicitly-sized panel.
	AutomaticSize: Enum.AutomaticSize?,
	LayoutOrder: UsedAs<number>?,
	BackgroundColor3: UsedAs<Color3>?,
	-- Omit for the common case of an always-shown panel. Combat feedback surfaces (e.g.
	-- PostureBreakBanner) that only exist while driven by a real display state use this to stay
	-- out of the tree entirely rather than rendering an empty shell.
	Visible: UsedAs<boolean>?,
	-- Overrides for this panel's single border UIStroke -- docs/ui-ux-philosophy.md's Borders
	-- section ("higher importance: brighter edge highlight") anticipates per-panel border
	-- emphasis. A panel gets exactly one UIStroke (Roblox doesn't support layering more than one
	-- on the same object predictably), so a caller that needs a themed border customizes this one
	-- instead of adding its own via Children.
	BorderColor3: UsedAs<Color3>?,
	BorderThickness: UsedAs<number>?,
	BorderTransparency: UsedAs<number>?,
	Elevated: boolean?,
	-- See file header. Defaults to off.
	CornerAccent: boolean?,
	Children: UsedAs<{ Instance }>?,
}

local BRACKET_ARM_LENGTH = 12
local BRACKET_ARM_THICKNESS = 2
local BRACKET_RIVET_SIZE = 5
local BRACKET_RIVET_INSET = 9

-- One L-shaped bracket (two arms + a rivet chip at the elbow), pinned to a single corner of its
-- parent via the same AnchorPoint-at-that-corner trick used throughout this UI framework --
-- anchoring a frame's own corner to a parent corner point makes the frame extend inward
-- automatically, with no per-corner sign-flipping math needed for the arms themselves.
local function CornerBracket(scope: Scope, corner: Vector2): { Instance }
	-- The rivet sits inward along the diagonal from the corner -- which direction "inward" is
	-- does depend on which corner this is, so this is the one place sign matters.
	local insetX = if corner.X == 0 then BRACKET_RIVET_INSET else -BRACKET_RIVET_INSET
	local insetY = if corner.Y == 0 then BRACKET_RIVET_INSET else -BRACKET_RIVET_INSET

	return {
		scope:New "Frame" {
			Name = "BracketArmHorizontal",
			AnchorPoint = corner,
			Position = UDim2.fromScale(corner.X, corner.Y),
			Size = UDim2.fromOffset(BRACKET_ARM_LENGTH, BRACKET_ARM_THICKNESS),
			BackgroundColor3 = Tokens.Color.BorderAccent,
			BorderSizePixel = 0,
			ZIndex = 5,
		},
		scope:New "Frame" {
			Name = "BracketArmVertical",
			AnchorPoint = corner,
			Position = UDim2.fromScale(corner.X, corner.Y),
			Size = UDim2.fromOffset(BRACKET_ARM_THICKNESS, BRACKET_ARM_LENGTH),
			BackgroundColor3 = Tokens.Color.BorderAccent,
			BorderSizePixel = 0,
			ZIndex = 5,
		},
		scope:New "Frame" {
			Name = "BracketRivet",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(corner.X, insetX, corner.Y, insetY),
			Size = UDim2.fromOffset(BRACKET_RIVET_SIZE, BRACKET_RIVET_SIZE),
			Rotation = 45,
			BackgroundColor3 = Tokens.Color.BorderAccent,
			BorderSizePixel = 0,
			ZIndex = 5,
		},
	}
end

local function Panel(scope: Scope, props: PanelProps): Frame
	local cornerAccents: { Instance } = {}
	if props.CornerAccent then
		for _, corner in ipairs(Geometry.CORNERS) do
			for _, piece in ipairs(CornerBracket(scope, corner)) do
				table.insert(cornerAccents, piece)
			end
		end
	end

	local contentAutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None
	-- Content's starting Size on each axis must stay Scale-relative to the outer Frame on any axis
	-- AutomaticSize *isn't* driving, or that axis renders at literal 0 instead of the outer Frame's
	-- actual resolved size (e.g. a full-width, auto-HEIGHT-only sub-panel -- AutomaticSize.Y with
	-- Size = UDim2.new(1, 0, 0, 0) -- would otherwise get a zero-width Content no matter what the
	-- outer Frame's width resolves to, since only Y is auto-sized). XY keeps the original
	-- fromOffset(0, 0) behavior (both axes are auto-sized from content regardless of starting size).
	local contentSize = if contentAutomaticSize == Enum.AutomaticSize.XY
		then UDim2.fromOffset(0, 0)
		elseif contentAutomaticSize == Enum.AutomaticSize.Y then UDim2.fromScale(1, 0)
		elseif contentAutomaticSize == Enum.AutomaticSize.X then UDim2.fromScale(0, 1)
		else UDim2.fromScale(1, 1)

	return scope:New "Frame" {
		Name = props.Name or "Panel",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size,
		AutomaticSize = props.AutomaticSize,
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundColor3 = props.BackgroundColor3
			or (if props.Elevated then Tokens.Color.SurfaceElevated else Tokens.Color.Surface),
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.CornerRadius,
			},
			scope:New "UIStroke" {
				Color = props.BorderColor3 or Tokens.Color.BorderSubtle,
				Thickness = props.BorderThickness or 1,
				Transparency = props.BorderTransparency or 0,
			},
			scope:New "Frame" {
				Name = "Content",
				Size = contentSize,
				AutomaticSize = contentAutomaticSize,
				BackgroundTransparency = 1,
				ZIndex = 1,

				[Children] = props.Children,
			},
			scope:New "Frame" {
				Name = "AccentOverlay",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				ZIndex = 5,

				[Children] = cornerAccents,
			},
		},
	} :: Frame
end

return Panel
