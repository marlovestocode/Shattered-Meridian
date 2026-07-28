--!strict
--[[
	Panel.lua

	Owns: the base surface container every HUD/menu panel is built from -- background, border,
	and corner radius, all pulled from Tokens.lua. Applying the token set consistently here is
	what keeps every surface reading as the same visual family (docs/ui-ux-philosophy.md).

	CornerAccent (optional): the tactical corner-bracket treatment from
	docs/design/frames/hotbar-frame.svg -- four L-shaped forged-steel brackets with a rivet chip at
	each elbow, built via Components/CornerBracket.lua (no image asset; see VitalIcon.lua's header
	for why this repo doesn't guess at rbxassetids). This is docs/ui-ux-philosophy.md's Shape
	Language ("weapon-like geometry," "borders communicate importance... brighter edge highlight")
	applied as an additive overlay on a rectangular panel, distinct from Chamfered below. Off by
	default so existing panels (Menus' Root frame, etc.) are unaffected. When both CornerAccent and
	Chamfered are requested on the same panel (the Hotbar does this), Chamfered wins whenever it's
	actually available -- a bracket accent anchored at a now-nonexistent rectangular corner would
	float over the chamfer's cut void -- and CornerAccent becomes the graceful-degradation path for
	the (rare) case the chamfered textures fail to generate, so the panel still gets SOME corner
	treatment rather than reverting all the way to a bare rectangle. Corner accents render in an
	overlay layer so a caller's content UIListLayout never tries to arrange the decorative pieces.

	Chamfered (optional): the true cut-corner panel *shape* docs/ui-ux-philosophy.md's Shape
	Language section calls for and its Implementation Notes previously flagged as blocked on
	"EditableMesh/EditableImage... neither of which exists in this repo yet" -- see
	Client/UI/ChamferedSurface.lua's header for why that's no longer true and how the shape is
	generated. Off by default (existing panels keep today's sharp-rectangle UICorner+UIStroke look);
	the Hotbar opts in. When ChamferedSurface.IsAvailable() is false at mount time (see that
	module's Deployment gate), this panel silently renders its ordinary UICorner+UIStroke path (plus
	CornerAccent's brackets, if also requested) instead -- BorderThickness has no effect in chamfered
	mode since the stroke's pixel width is baked into the texture, not a live property.

	Lattice (optional): the redesign's hex-lattice surface texture (Components/LatticeOverlay.lua),
	layered above the fill and below Content. Off by default. Inert until a real texture id exists
	(docs/design/intro-redesign-handoff.md Phase F item 22, "icon art -- not started") --
	LatticeOverlay.lua renders nothing without one, so requesting Lattice today is a no-op, not a
	broken image; every caller lights up automatically the moment LATTICE_TEXTURE_ID below is filled
	in.

	BorderColor3/BorderTransparency default to Tokens.Border.Standard's real Color+Transparency
	(not the deprecated pre-composited Tokens.Color.BorderSubtle) -- see that token's own comment in
	Tokens.lua for why the real Tint is the correct default for a panel that might use a
	BackgroundColor3 other than plain Surface (Elevated, or a caller override).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local CornerBracket = require(script.Parent.CornerBracket)
local LatticeOverlay = require(script.Parent.LatticeOverlay)

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
	-- See file header. Defaults to off.
	Chamfered: boolean?,
	-- See file header. Defaults to off.
	Lattice: boolean?,
	-- CornerAccent's own arm length in pixels. Defaults to this file's original 12px (every existing
	-- CornerAccent caller -- BugReport/Announcement/DevMenu/PostureBreakBanner/HUD -- keeps its
	-- current look unchanged); the redesign's own brackets want 16px
	-- (docs/design/intro-redesign-figma-spec.md section 3.3), so a caller opting into the new look
	-- passes 16 explicitly rather than this default silently growing every bracket in the game.
	BracketArmLength: number?,
	Children: UsedAs<{ Instance }>?,
}

local BRACKET_ARM_LENGTH = 12
local BRACKET_ARM_THICKNESS = 2
local BRACKET_RIVET_SIZE = 5
local BRACKET_RIVET_INSET = 9

-- See PanelProps.Lattice/this file's own header. Fill in once a real hex-lattice texture is
-- uploaded; every Lattice=true caller then renders it with no other code change.
local LATTICE_TEXTURE_ID: string? = nil

local function Panel(scope: Scope, props: PanelProps): Frame
	local fillColor = props.BackgroundColor3
		or (if props.Elevated then Tokens.Color.SurfaceElevated else Tokens.Color.Surface)
	local borderTint = Tokens.Border.Standard
	local borderColor = props.BorderColor3 or borderTint.Color
	local borderTransparency = props.BorderTransparency or borderTint.Transparency

	local chamferedFill: ImageLabel? = nil
	local chamferedStroke: ImageLabel? = nil
	if props.Chamfered then
		chamferedFill = ChamferedSurface.Fill(scope, {
			FillColor = fillColor,
			ZIndex = 0,
		})
		if chamferedFill then
			chamferedStroke = ChamferedSurface.Stroke(scope, {
				Color = borderColor,
				Transparency = borderTransparency,
				ZIndex = 1,
			})
		end
	end
	local isChamfered = chamferedFill ~= nil

	local shellChildren: { Instance } = {}
	if isChamfered then
		table.insert(shellChildren, chamferedFill :: Instance)
		if chamferedStroke then
			table.insert(shellChildren, chamferedStroke :: Instance)
		end
	else
		table.insert(
			shellChildren,
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			}
		)
		table.insert(
			shellChildren,
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = props.BorderThickness or 1,
				Transparency = borderTransparency,
			}
		)
	end

	-- See file header on CornerAccent -- it's the fallback corner treatment, so it only renders when
	-- Chamfered wasn't requested at all, or was requested but the textures weren't available.
	local cornerAccents: { Instance } = {}
	if props.CornerAccent and not isChamfered then
		cornerAccents = CornerBracket.BuildAll(scope, {
			ArmLength = props.BracketArmLength or BRACKET_ARM_LENGTH,
			ArmThickness = BRACKET_ARM_THICKNESS,
			RivetSize = BRACKET_RIVET_SIZE,
			RivetInset = BRACKET_RIVET_INSET,
			Color = Tokens.Color.AccentPrimary,
		})
	end

	-- See PanelProps.Lattice/this file's own header -- inert (empty array) until LATTICE_TEXTURE_ID
	-- is filled in, same "empty-array-not-nil" convention cornerAccents above already follows so a
	-- disabled/unavailable optional layer never punches a nil hole in the Children array below.
	local latticeChildren: { Instance } = {}
	if props.Lattice then
		local overlay = LatticeOverlay(scope, {
			TextureId = LATTICE_TEXTURE_ID,
			-- Strictly above the fill (chamfered fill is ZIndex 0; the sharp-rect fill is this
			-- Frame's own background, always painted first regardless of ZIndex) and strictly below
			-- Content (ZIndex 2 below) -- ties with the chamfered stroke's ZIndex 1 are harmless
			-- since a 1px edge outline and a full-surface texture don't visually compete.
			ZIndex = 1,
		})
		if overlay then
			table.insert(latticeChildren, overlay)
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
		BackgroundColor3 = fillColor,
		-- Chamfered mode paints its own fill via an ImageLabel child instead (see shellChildren
		-- above), so this Frame's own background must stay fully transparent -- otherwise its plain
		-- rectangular corners would show through underneath the chamfered silhouette's cut corners.
		BackgroundTransparency = if isChamfered then 1 else 0,
		BorderSizePixel = 0,

		[Children] = {
			shellChildren,
			latticeChildren,
			scope:New "Frame" {
				Name = "Content",
				Size = contentSize,
				AutomaticSize = contentAutomaticSize,
				BackgroundTransparency = 1,
				-- 2, not 1 -- strictly above the Lattice overlay's ZIndex 1 (see that block's own
				-- comment above), a bump from this file's original value that changes nothing for
				-- any existing panel (nothing else in this tree sits between 1 and 5).
				ZIndex = 2,

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
