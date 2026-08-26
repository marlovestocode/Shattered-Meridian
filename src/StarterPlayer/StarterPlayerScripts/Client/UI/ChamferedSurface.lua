--!strict
--[[
	ChamferedSurface.lua

	Owns: the shared runtime-generated chamfered/cut-corner tile geometry docs/ui-ux-philosophy.md's
	Shape Language section calls for ("angular corners... slanted corners... weapon-like geometry...
	avoid perfect rounded rectangles") -- previously flagged in that doc's Implementation Notes as
	needing "EditableMesh/EditableImage or commissioned image assets, neither of which exists in this
	repo yet." EditableImage *does* exist and is exactly the right tool here: a texture generated
	entirely at runtime in Lua, no asset upload, no Studio round-trip -- the same "no rbxassetid
	guessing" discipline VitalIcon.lua/AbilitySlot.lua's own headers already hold this repo to for
	every other image, just applied to a shape instead of a raster icon.

	Technique: two small (48x48) alpha-masked textures, baked ONCE at first use and cached for the
	whole client session -- Fill (a flat chamfered-rect silhouette) and Stroke (that silhouette's
	outline band, in Thin/Thick pixel-width variants sharing the exact same outer edge). Both are
	authored as solid WHITE with only alpha carrying shape information, so every caller tints them
	per-instance via ImageColor3/ImageTransparency -- the same modulation VitalIcon.lua's own
	IconAssetId branch already uses -- which is what makes "one generated texture, reused everywhere"
	actually work: a caller's fill color (Surface/SurfaceElevated/Background) and its border color
	(Tokens.Border.Standard/AccentPrimary) are never the same token, and a solid-white source means whichever
	color a caller tints toward is exactly the color that renders, regardless of Roblox's precise
	UIGradient/ImageColor3 compositing order.

	Fill and Stroke are deliberately SEPARATE textures rather than one texture with the border baked
	in: baking both into one texture would force fill and border to share a single ImageColor3 tint,
	which no real caller here wants (every Panel/AbilitySlot/VitalIcon surface uses two different
	tokens for its fill vs. its border).

	Applied via Enum.ScaleType.Slice + a fixed SLICE_CENTER, so the SAME baked texture stretches
	cleanly to the Hotbar panel (~300px+), a 52px VitalIcon tile, or a 40px AbilitySlot tile without
	ever regenerating. CHAMFER_PX is a fixed pixel size (not a percentage) for exactly that reason: a
	percentage chamfer would look proportionally different at each of those three sizes, a fixed-pixel
	one reads as the same cut everywhere, which is the point.

	Anti-aliased in software: each mask pixel's alpha comes from a signed-distance evaluation against
	the shape's four straight edges and four 45-degree corner-cut lines (the standard technique for an
	SDF of a convex polygon -- near a convex shape's own boundary, distance to the boundary equals the
	minimum of the per-edge half-plane distances, which is exactly what chamferDistance computes),
	clamped to a 1px blend band. This is what keeps the corner cut reading as a deliberately drawn
	edge instead of a jagged stairstep at these small tile sizes.

	Deployment gate -- read before shipping: AssetService:CreateEditableImage requires the
	experience's owner to be ID-verified and to enable "Allow Mesh/Image APIs" in Studio's Game
	Settings > Security -- a one-time, account/place-level toggle, NOT a per-player requirement.
	CONFIRMED 2026-07-23 via live Output log that this gate also blocks Studio Play-mode testing, not
	just a published build (Roblox's own runtime error: "EditableImage is not accessible. Go to the
	Security Tab in Experience Settings to enable this API.") -- an earlier draft of this comment
	claimed Studio/run-in-roblox were unaffected; that was never independently verified and turned out
	to be wrong. Every entry point below is pcall-guarded end to end regardless: if generation fails or
	the API is unavailable for any reason, IsAvailable() reports false and every caller
	(Panel.lua/AbilitySlot.lua/VitalIcon.lua) falls back to its prior UICorner+UIStroke sharp-rect
	treatment automatically -- this module can never be the reason the HUD fails to render, but until
	the toggle is enabled (Experience Settings > Security in the Creator Dashboard, or Studio's Game
	Settings > Security), NO environment will render the real chamfer, Studio included.

	Generated once for the whole UI package (module-level memoized on first call, from whichever
	component mounts first), never per-component-instance and never per-frame -- see this file's
	Deployment gate paragraph above and ui-ux-philosophy.md's Framework section on why a shared
	runtime asset like this is a singleton, not a per-caller cost.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local logger = Logger.scope("ChamferedSurface")

local ChamferedSurface = {}

-- Authored resolution of every baked mask -- small on purpose, since this is a 9-sliced silhouette,
-- not a photograph; the entire point is that one small texture stretches to any final size.
local TEXTURE_SIZE = 48
-- The corner cut itself, in source-texture pixels -- see this file's header on why fixed-pixel, not
-- a percentage. Within docs/ui-ux-philosophy.md's implied 6-10px "reads as a cut, not a bevel" range.
local CHAMFER_PX = 8
-- How much of each edge stays pinned (never stretched) by ScaleType.Slice. Only needs to comfortably
-- clear CHAMFER_PX plus the ~1px AA blend -- extra margin beyond that is invisible (it's flat fill/
-- stroke pixels indistinguishable from the stretched middle), so this is sized for the smallest
-- consumer (AbilitySlot's 40px tile: 40 - 2*16 = 8px of stretchable middle remains, still positive)
-- rather than trimmed to the theoretical minimum.
local SLICE_INSET = 16
local STROKE_THIN_PX = 1
local STROKE_THICK_PX = 2

ChamferedSurface.CHAMFER_PX = CHAMFER_PX
ChamferedSurface.SLICE_CENTER =
	Rect.new(SLICE_INSET, SLICE_INSET, TEXTURE_SIZE - SLICE_INSET, TEXTURE_SIZE - SLICE_INSET)

export type StrokeWeight = "Thin" | "Thick"

local SQRT2 = math.sqrt(2)

-- Signed distance (in source-texture pixels) from (x, y) to the nearest edge of a `size` x `size`
-- square with each corner cut at 45 degrees, `chamfer` pixels in from each edge. Positive = inside.
local function chamferDistance(x: number, y: number, size: number, chamfer: number): number
	local distLeft = x
	local distRight = size - x
	local distTop = y
	local distBottom = size - y
	local distTopLeft = (distLeft + distTop - chamfer) / SQRT2
	local distTopRight = (distRight + distTop - chamfer) / SQRT2
	local distBottomLeft = (distLeft + distBottom - chamfer) / SQRT2
	local distBottomRight = (distRight + distBottom - chamfer) / SQRT2
	return math.min(
		distLeft,
		distRight,
		distTop,
		distBottom,
		distTopLeft,
		distTopRight,
		distBottomLeft,
		distBottomRight
	)
end

local function coverage(distance: number): number
	return math.clamp(distance + 0.5, 0, 1)
end

-- Builds one RGBA8 pixel buffer (row-major, top-left origin -- see EditableImage:WritePixelsBuffer):
-- solid white, alpha = the chamfered silhouette (strokeWidth == nil) or that silhouette's outline
-- band, strokeWidth pixels wide, following the same outer edge (strokeWidth ~= nil).
local function buildMaskBuffer(strokeWidth: number?): buffer
	local pixelBuffer = buffer.create(TEXTURE_SIZE * TEXTURE_SIZE * 4)
	for row = 0, TEXTURE_SIZE - 1 do
		for column = 0, TEXTURE_SIZE - 1 do
			local distance = chamferDistance(column + 0.5, row + 0.5, TEXTURE_SIZE, CHAMFER_PX)
			local alpha: number
			if strokeWidth then
				alpha = coverage(distance) - coverage(distance - strokeWidth)
			else
				alpha = coverage(distance)
			end

			local index = (row * TEXTURE_SIZE + column) * 4
			buffer.writeu8(pixelBuffer, index, 255)
			buffer.writeu8(pixelBuffer, index + 1, 255)
			buffer.writeu8(pixelBuffer, index + 2, 255)
			buffer.writeu8(pixelBuffer, index + 3, math.round(math.clamp(alpha, 0, 1) * 255))
		end
	end
	return pixelBuffer
end

local function tryBakeMask(strokeWidth: number?): EditableImage?
	local ok, imageOrError = pcall(function(): EditableImage?
		local editableImage = AssetService:CreateEditableImage({ Size = Vector2.new(TEXTURE_SIZE, TEXTURE_SIZE) })
		if not editableImage then
			return nil
		end
		editableImage:WritePixelsBuffer(
			Vector2.zero,
			Vector2.new(TEXTURE_SIZE, TEXTURE_SIZE),
			buildMaskBuffer(strokeWidth)
		)
		return editableImage
	end)

	if ok then
		return imageOrError :: EditableImage?
	end

	logger:warn("EditableImage bake failed", { reason = tostring(imageOrError) })
	return nil
end

type MaskCache = {
	Fill: Content?,
	StrokeThin: Content?,
	StrokeThick: Content?,
	-- Strong references to the raw EditableImage instances behind Fill/StrokeThin/StrokeThick above,
	-- held for the whole client session (same lifetime as this cache) -- a 2026-07-23 architecture
	-- review flagged that nothing else in this module keeps these alive once Content.fromObject() is
	-- taken, and Content's own ownership semantics over its source instance aren't something this
	-- file can verify without a live session. Cheap, unconditional insurance against a delayed
	-- "texture goes blank after working" failure mode, independent of whatever Content actually does
	-- internally. Colocated on this cache table (rather than a separate module-level local) so it's
	-- naturally read by the same `return maskCache` every ensureGenerated() call already does.
	RawImages: { EditableImage },
}

local maskCache: MaskCache = { Fill = nil, StrokeThin = nil, StrokeThick = nil, RawImages = {} }
local generationAttempted = false

-- Populated together or not at all -- see IsAvailable()'s header. Callers that read StrokeThick after
-- confirming StrokeThin is present may treat it as non-optional; this is the one place that invariant
-- is established.
local function ensureGenerated(): MaskCache
	if generationAttempted then
		return maskCache
	end
	generationAttempted = true

	local fillImage = tryBakeMask(nil)
	local strokeThinImage = tryBakeMask(STROKE_THIN_PX)
	local strokeThickImage = tryBakeMask(STROKE_THICK_PX)

	if not (fillImage and strokeThinImage and strokeThickImage) then
		logger:warn("Chamfered surface unavailable -- callers fall back to UICorner+UIStroke")
		if fillImage then
			fillImage:Destroy()
		end
		if strokeThinImage then
			strokeThinImage:Destroy()
		end
		if strokeThickImage then
			strokeThickImage:Destroy()
		end
		return maskCache
	end

	table.insert(maskCache.RawImages, fillImage)
	table.insert(maskCache.RawImages, strokeThinImage)
	table.insert(maskCache.RawImages, strokeThickImage)

	maskCache.Fill = Content.fromObject(fillImage)
	maskCache.StrokeThin = Content.fromObject(strokeThinImage)
	maskCache.StrokeThick = Content.fromObject(strokeThickImage)
	return maskCache
end

-- Whether the baked textures are ready to use. Callers check this ONCE per component instantiation
-- (it's a fixed environment capability that can't change mid-session, not something to re-derive
-- reactively) and pick their Chamfered-vs-legacy rendering path from the plain boolean result, the
-- same way VitalIcon.lua already captures `Muted` as a plain boolean rather than a reactive one.
function ChamferedSurface.IsAvailable(): boolean
	return ensureGenerated().Fill ~= nil
end

-- EVERY LAYER, OR NONE -- returns the baked layers in order, or nil if ANY of them came back nil.
--
-- IsAvailable() said the masks are ready, so a nil out of Fill/Stroke afterwards is not the ordinary
-- "this environment has no chamfer" case; it is one layer of a multi-layer surface missing. Rendering
-- the rest reads as a bug (a tile with no fill, a plate with no stroke) rather than as the plain-rect
-- fallback, so the whole set is discarded and the caller drops to its legacy path instead.
--
-- A function rather than four hand-written `if a and b and c then` blocks because that is exactly what
-- the four surfaces doing this had -- with the rule restated four times in four slightly different
-- comments, one of which no longer named the function it was talking about. The rule is one rule.
--
-- Returns a NEW array; callers assign it rather than appending to one they already hold, which is
-- what makes "or none" mean none.
function ChamferedSurface.AllLayers(layers: { ImageLabel? }): { Instance }?
	local resolved: { Instance } = {}
	for _, layer in layers do
		if layer == nil then
			return nil
		end
		table.insert(resolved, layer :: Instance)
	end
	return resolved
end

export type ChamferedFillProps = {
	FillColor: UsedAs<Color3>,
	FillTransparency: UsedAs<number>?,
	Size: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Position: UsedAs<UDim2>?,
	-- Overlay content painted on top of this fill (e.g. a UIGradient sheen) -- follows this image's
	-- own alpha automatically since it's a real child of a real paintable GuiObject, unlike the
	-- corner-bracket accents this shape replaces, which never needed one. Fusion's [Children] key
	-- accepts a single Instance or an array interchangeably -- both current callers (AbilitySlot.lua/
	-- VitalIcon.lua) pass a single UIGradient, so this is typed to match rather than forcing a
	-- single-element table at every call site.
	Children: UsedAs<Instance | { Instance }>?,
	ZIndex: number?,
}

-- A chamfered-silhouette fill, 9-sliced to whatever Size it's given (defaults to filling its
-- parent). Returns nil when ChamferedSurface.IsAvailable() is false -- every caller must check
-- availability (directly or via a nil check on this return value) before relying on it.
function ChamferedSurface.Fill(scope: Scope, props: ChamferedFillProps): ImageLabel?
	local content = ensureGenerated().Fill
	if not content then
		return nil
	end

	return scope:New "ImageLabel" {
		Name = "ChamferedFill",
		Size = props.Size or UDim2.fromScale(1, 1),
		AnchorPoint = props.AnchorPoint,
		Position = props.Position,
		BackgroundTransparency = 1,
		ImageContent = content,
		ImageColor3 = props.FillColor,
		ImageTransparency = props.FillTransparency or 0,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = ChamferedSurface.SLICE_CENTER,
		ZIndex = props.ZIndex or 0,

		[Children] = props.Children,
	} :: ImageLabel
end

export type ChamferedStrokeProps = {
	Color: UsedAs<Color3>,
	Transparency: UsedAs<number>?,
	-- Which baked width to display -- a hard swap, not a regenerated texture, matching how
	-- AbilitySlot.lua/VitalIcon.lua already hard-switch their UIStroke.Thickness on state today (no
	-- existing caller springs thickness, only color/transparency).
	Weight: UsedAs<StrokeWeight>?,
	Size: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Position: UsedAs<UDim2>?,
	ZIndex: number?,
}

-- The same chamfered silhouette's outline band. Returns nil under the same conditions as Fill() --
-- callers should generally only call this after confirming Fill() itself succeeded (see this
-- module's header on the two masks being generated together).
function ChamferedSurface.Stroke(scope: Scope, props: ChamferedStrokeProps): ImageLabel?
	local masks = ensureGenerated()
	if not masks.StrokeThin then
		return nil
	end
	-- See ensureGenerated()'s comment: StrokeThin and StrokeThick are always populated together.
	local strokeThin = masks.StrokeThin :: Content
	local strokeThick = masks.StrokeThick :: Content

	local weight: UsedAs<StrokeWeight> = props.Weight or "Thin"
	local content = scope:Computed(function(use)
		if use(weight) == "Thick" then
			return strokeThick
		end
		return strokeThin
	end)

	return scope:New "ImageLabel" {
		Name = "ChamferedStroke",
		Size = props.Size or UDim2.fromScale(1, 1),
		AnchorPoint = props.AnchorPoint,
		Position = props.Position,
		BackgroundTransparency = 1,
		ImageContent = content,
		ImageColor3 = props.Color,
		ImageTransparency = props.Transparency or 0,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = ChamferedSurface.SLICE_CENTER,
		ZIndex = props.ZIndex or 0,
	} :: ImageLabel
end

return ChamferedSurface
