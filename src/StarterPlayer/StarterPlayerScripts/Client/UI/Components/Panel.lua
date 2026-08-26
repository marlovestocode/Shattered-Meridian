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
	default so existing panels (Menus' Root frame, etc.) are unaffected. Corner accents render in an
	overlay layer so a caller's content UIListLayout never tries to arrange the decorative pieces.

	CORNERACCENT + CHAMFERED ON ONE PANEL used to be mutually exclusive, and now is not -- but only
	when the caller says how. The original rule was that Chamfered wins whenever it is available,
	because a bracket anchored at a now-nonexistent rectangular corner floats over the chamfer's cut
	void; CornerAccent then survived purely as the graceful-degradation path for the rare case the
	textures fail to generate. That rule was right about the geometry and wrong about the conclusion:
	the answer is to move the bracket, not to drop it. BracketInset (Components/CornerBracket.lua's own
	Inset, see that file's header) pulls each elbow in along both axes, and at
	ChamferedSurface.CHAMFER_PX it lands exactly where the diagonal cut ends and the straight edge
	begins -- so each arm runs ALONG a real edge and the pair braces the cut instead of ignoring it.
	Pass BracketInset and you get both treatments; omit it and the original either/or is unchanged,
	which is what keeps every pre-existing CornerAccent caller rendering byte-for-byte as before.

	Chamfered (optional): the true cut-corner panel *shape* docs/ui-ux-philosophy.md's Shape
	Language section calls for and its Implementation Notes previously flagged as blocked on
	"EditableMesh/EditableImage... neither of which exists in this repo yet" -- see
	Client/UI/ChamferedSurface.lua's header for why that's no longer true and how the shape is
	generated. Off by default (existing panels keep today's sharp-rectangle UICorner+UIStroke look);
	the Hotbar opts in. When ChamferedSurface.IsAvailable() is false at mount time (see that
	module's Deployment gate), this panel silently renders its ordinary UICorner+UIStroke path (plus
	CornerAccent's brackets, if also requested) instead -- BorderThickness has no effect in chamfered
	mode since the stroke's pixel width is baked into the texture, not a live property.

	SurfaceTexture (optional): the decorative surface grain (Components/MeridianField.lua), layered
	above the fill and below Content. Off by default. REPLACES the old `Lattice` prop, which drew
	Components/LatticeOverlay.lua's hex tile -- that component could only render a real uploaded
	texture, no id was ever uploaded, so every caller that asked for it silently got nothing. The
	replacement is procedural (Frames + UIGradients), so it renders on the first mount and needs no
	upload step; see MeridianField.lua's own header for why the motif changed as well as the
	mechanism.

	BorderColor3/BorderTransparency default to Tokens.Border.Standard's real Color+Transparency pair
	-- the correct default for a panel that might use a BackgroundColor3 other than plain Surface
	(Elevated, or a caller override), since a Tint composites correctly over any surface.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local CornerBracket = require(script.Parent.CornerBracket)
local MeridianField = require(script.Parent.MeridianField)

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
	-- Uniformly scales this panel AND everything inside it, applied at the ROOT frame (so the panel's
	-- own rendered size grows too, unlike a UIScale a caller could put in Children -- those land
	-- inside the inner Content wrapper and would scale the contents right out of an unchanged frame).
	-- Omit for a panel that renders at its literal pixel size. See ModalScreen.lua's AutoScale.
	Scale: UsedAs<number>?,
	-- Makes this panel CONSUME mouse input that lands on it, so Roblox reports the click as already
	-- handled (UserInputService gameProcessedEvent) instead of letting it fall through to whatever is
	-- listening for a swing. Off by default -- a HUD panel must NOT eat clicks meant for the world --
	-- and set by Components/ModalScreen.lua for every top-level modal; see that file header.
	Active: UsedAs<boolean>?,
	Elevated: boolean?,
	-- See file header. Defaults to off.
	CornerAccent: boolean?,
	-- See file header. Defaults to off.
	Chamfered: boolean?,
	-- See file header. Defaults to off.
	--
	-- INCOMPATIBLE WITH AutomaticSize -- do not set both. Measured 2026-08-25, because the hotbar
	-- dock set both and rendered at full screen height. Roblox's AutomaticSize measures a child's
	-- SUBTREE, and `ClipsDescendants` does not stop it. The precise rule, from an isolated probe:
	--   * a Scale-sized decoration layer with no GuiObject children of its own is SAFE (the engine
	--     resolves it against the content-derived size -- no feedback). That is why the chamfered
	--     fill/stroke, which are leaf ImageLabels, have always been fine here.
	--   * a Scale-sized layer containing a Scale-sized GuiObject is NOT: the grandchild resolves
	--     against the enclosing host instead, the parent grows to match, and it latches there. Scale
	--     on one axis only inflates that axis, which is why the dock's width looked correct and its
	--     height did not.
	--   * offset-sized grandchildren are safe as long as they are smaller than the real content.
	-- MeridianField is the second kind (a full-size bloom plus ten full-height threads), so a panel
	-- that wants both a surface grain and content-driven sizing has to give the panel an explicit
	-- Size. See MeridianField.lua's own header.
	SurfaceTexture: boolean?,
	-- SurfaceTexture's opacity dial, 0-1 (see MeridianField.lua's Intensity). Only meaningful
	-- alongside SurfaceTexture; defaults to the field's own authored strength.
	SurfaceTextureIntensity: number?,
	-- CornerAccent's own color. Defaults to this file's original Tokens.Color.AccentPrimary, so
	-- every pre-existing CornerAccent caller keeps its violet brackets; the character menu passes
	-- bronze.
	CornerAccentColor: UsedAs<Color3>?,
	-- Whether CornerAccent's brackets carry the hotbar-frame.svg rivet chip at each elbow. Defaults
	-- to true (the original look, kept by BugReport/Announcement/DevMenu/PostureBreakBanner/HUD);
	-- the redesign's own brackets are unornamented, so those callers pass false.
	CornerAccentRivets: boolean?,
	-- CornerAccent's own arm length in pixels. Defaults to this file's original 12px (every existing
	-- CornerAccent caller -- BugReport/Announcement/DevMenu/PostureBreakBanner/HUD -- keeps its
	-- current look unchanged); the redesign's own brackets want 16px
	-- (docs/design/intro-redesign-figma-spec.md section 3.3), so a caller opting into the new look
	-- passes 16 explicitly rather than this default silently growing every bracket in the game.
	BracketArmLength: number?,
	-- Pixels each bracket's elbow is pulled in from its corner. Required to combine CornerAccent with
	-- Chamfered -- see this file's header. Defaults to 0 (flush to the corner), the original look.
	BracketInset: number?,
	-- EXTRA pixels down on the TOP pair only, added to BracketInset. For a panel that is the lower
	-- half of an assembly, whose top corners are therefore NOT the assembly's corners -- see
	-- CornerBracket.lua's own TopInset note. Screens/BlimpHelm passes its seam depth so its top elbows
	-- mark the start of its own section rather than the joint the furnace plate sinks into above it.
	BracketTopInset: number?,
	-- The same, for a panel joined along its LEFT edge -- Screens/HUD's dock, which the armament
	-- island sinks into. See CornerBracket.lua's LeftInset.
	BracketLeftInset: number?,
	Children: UsedAs<{ Instance }>?,
}

local BRACKET_ARM_LENGTH = 12
local BRACKET_ARM_THICKNESS = 2
local BRACKET_RIVET_SIZE = 5
local BRACKET_RIVET_INSET = 9

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
	if props.Scale ~= nil then
		table.insert(
			shellChildren,
			scope:New "UIScale" {
				Scale = props.Scale,
			}
		)
	end
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

	-- See file header on CornerAccent. Without a BracketInset it is still the FALLBACK corner
	-- treatment and only renders when the chamfer isn't in play; with one, the brackets are inset far
	-- enough to brace the cut rather than float over it, so both treatments render together.
	local cornerAccents: { Instance } = {}
	if props.CornerAccent and (not isChamfered or props.BracketInset ~= nil) then
		local wantsRivets = props.CornerAccentRivets ~= false
		cornerAccents = CornerBracket.BuildAll(scope, {
			ArmLength = props.BracketArmLength or BRACKET_ARM_LENGTH,
			ArmThickness = BRACKET_ARM_THICKNESS,
			-- Passed as nil rather than 0 when the caller opts out: CornerBracket treats a missing
			-- RivetSize as "plain L, no chip" and would happily build a zero-sized Frame for a 0.
			RivetSize = if wantsRivets then BRACKET_RIVET_SIZE else nil,
			RivetInset = if wantsRivets then BRACKET_RIVET_INSET else nil,
			Inset = props.BracketInset,
			TopInset = props.BracketTopInset,
			LeftInset = props.BracketLeftInset,
			Color = props.CornerAccentColor or Tokens.Color.AccentPrimary,
		})
	end

	-- Same "empty-array-not-nil" convention cornerAccents above already follows, so a layer the
	-- caller didn't ask for never punches a nil hole in the Children array below.
	local textureChildren: { Instance } = {}
	if props.SurfaceTexture then
		table.insert(
			textureChildren,
			MeridianField(scope, {
				-- Strictly above the fill (chamfered fill is ZIndex 0; the sharp-rect fill is this
				-- Frame's own background, always painted first regardless of ZIndex) and strictly
				-- below Content (ZIndex 2 below) -- ties with the chamfered stroke's ZIndex 1 are
				-- harmless since a 1px edge outline and a full-surface texture don't visually compete.
				ZIndex = 1,
				Intensity = props.SurfaceTextureIntensity,
			})
		)
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
		Active = props.Active,
		BackgroundColor3 = fillColor,
		-- Chamfered mode paints its own fill via an ImageLabel child instead (see shellChildren
		-- above), so this Frame's own background must stay fully transparent -- otherwise its plain
		-- rectangular corners would show through underneath the chamfered silhouette's cut corners.
		BackgroundTransparency = if isChamfered then 1 else 0,
		BorderSizePixel = 0,

		[Children] = {
			shellChildren,
			textureChildren,
			scope:New "Frame" {
				Name = "Content",
				Size = contentSize,
				AutomaticSize = contentAutomaticSize,
				BackgroundTransparency = 1,
				-- 2, not 1 -- strictly above the surface texture's ZIndex 1 (see that block's own
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
