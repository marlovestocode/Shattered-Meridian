--!strict
--[[
	KeyCap.lua

	Owns: one key drawn as a physical key -- a small bordered well holding a mono glyph. The thing a
	player's eye lands on when a legend says "press this."

	EXTRACTED, NOT INVENTED. Three surfaces had independently drawn this exact object before this
	file existed, and the third is what earned the extraction (the same bar Components/CornerBracket.
	lua cleared when it came out of Panel.lua):
	  * Components/KeyHint.lua's private `keyCap` -- the quiet register, an inset wash behind the
	    standard 18% panel edge, sized for a corner console's stacked legend.
	  * Screens/WeaponInventory/init.lua's private `keycap` -- the lit register, a Surface fill behind
	    the 32% emphasis edge, deliberately louder because that cap sits beside the one verb on the
	    tile the player is being asked to act on.
	  * Screens/HUD's sub-dock legend (Components/KeyLegend.lua), which wanted the quiet register at
	    the WeaponInventory cap's size -- i.e. a combination neither existing copy could give it
	    without a fourth hand-rolled cap.
	Those two registers are the whole reason this takes a `Tone` rather than baking one look: they are
	a real design distinction (how loudly is the player being asked to press this?), not drift, so the
	extraction preserves both instead of flattening them to whichever was written first.

	ACTIVE IS A HUE CHANGE, NOT A BRIGHTNESS CHANGE. A lit cap swaps to the accent wash AND the accent
	edge AND the bright accent glyph, so "this is currently engaged" survives docs/ui-ux-philosophy.md's
	Critical States rule (never color alone) when a caller pairs it with KeyHint's own ActiveText swap.
	Inherited verbatim from KeyHint's cap, which is where that behavior was designed.

	Does not own: what any key is bound to, or what pressing it does. Every glyph is handed in --
	reactive, because a cap naming a rebindable action has to change when the player rebinds it
	without the panel around it being torn down and rebuilt.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- The three registers, and the question that picks between them is WHAT IS BEHIND THE CAP, not how
-- important it is:
--   * "Quiet" (default) -- a cap on a panel. Its fill is a 2.4% white wash, which reads as a recessed
--     key against a dark surface and is invisible against anything else.
--   * "Lit" -- a cap on a panel that IS the call to action. One per surface at most, or the emphasis
--     stops meaning anything.
--   * "Overlay" -- a cap with NO panel behind it, sat directly over the game world. It needs a real
--     opaque-ish fill of its own, because the world behind it can be a bright daylit field as easily
--     as a dark interior, and a wash tuned for one is unreadable on the other. This is not a louder
--     Quiet: it is the same visual weight, carrying its own background instead of borrowing one.
export type KeyCapTone = "Quiet" | "Lit" | "Overlay"

export type KeyCapProps = {
	-- Reactive -- see this file's header on rebinding.
	Key: UsedAs<string>,
	Tone: KeyCapTone?,
	-- Omit for a cap with no state of its own.
	Active: UsedAs<boolean>?,
	-- The cap grows past this on its own via AutomaticSize.X for a multi-letter glyph ("SPACE",
	-- "SHIFT"), which is why it is a minimum rather than a size.
	MinWidth: number?,
	Height: number?,
	LayoutOrder: UsedAs<number>?,
	Name: string?,
}

-- KeyHint's original numbers: the smallest that still leaves a cap unmistakably a KEY rather than a
-- letter, sized for a corner console sat over live gameplay. Callers with more room (the weapon
-- panel, the hotbar legend) pass 21/19.
local DEFAULT_MIN_WIDTH = 17
local DEFAULT_HEIGHT = 15

-- Overlay's fill. Not fully opaque -- a solid black key over the world reads as a hole punched in the
-- screen rather than as part of the HUD -- but far enough from transparent that the glyph on it holds
-- up over a bright sky as well as over a dark interior.
local OVERLAY_FILL_TRANSPARENCY = 0.2

local function KeyCap(scope: Scope, props: KeyCapProps): Frame
	local isActive: UsedAs<boolean> = props.Active or false
	local tone: KeyCapTone = props.Tone or "Quiet"

	local restingFill: Tokens.Tint = if tone == "Lit"
		then { Color = Tokens.Color.Surface, Transparency = 0 }
		elseif tone == "Overlay" then { Color = Tokens.Color.Surface, Transparency = OVERLAY_FILL_TRANSPARENCY }
		else Tokens.Wash.Inset
	local restingBorder: Tokens.Tint = if tone == "Lit" then Tokens.Border.Lit else Tokens.Border.Standard

	return scope:New("Frame")({
		-- Named by position/purpose by the caller, never by the glyph: the glyph is reactive, and an
		-- Instance whose Name changed every time a player rebound a key would break every path anyone
		-- ever writes to it.
		Name = props.Name or "KeyCap",
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(props.MinWidth or DEFAULT_MIN_WIDTH, props.Height or DEFAULT_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = scope:Computed(function(use)
			return if use(isActive) then Tokens.Wash.AccentFill.Color else restingFill.Color
		end),
		BackgroundTransparency = scope:Computed(function(use)
			return if use(isActive) then Tokens.Wash.AccentFill.Transparency else restingFill.Transparency
		end),
		BorderSizePixel = 0,

		[Children] = {
			scope:New("UICorner")({ CornerRadius = Tokens.Radius.Hairline }),
			-- The cap's edge is what makes it read as a physical key rather than as a highlighted
			-- word. Brightened rather than recolored when active -- docs/ui-ux-philosophy.md's Borders
			-- section: "higher importance: brighter edge highlight".
			scope:New("UIStroke")({
				Color = scope:Computed(function(use)
					return if use(isActive) then Tokens.Border.Accent.Color else restingBorder.Color
				end),
				Transparency = scope:Computed(function(use)
					return if use(isActive) then Tokens.Border.Accent.Transparency else restingBorder.Transparency
				end),
				Thickness = 1,
			}),
			-- Symmetric horizontal padding is what lets AutomaticSize.X grow a multi-letter cap
			-- without the glyphs touching its own border.
			scope:New("UIPadding")({
				PaddingLeft = UDim.new(0, Tokens.Space.XS),
				PaddingRight = UDim.new(0, Tokens.Space.XS),
			}),
			-- Centres the glyph instead of stretching it. The obvious alternative -- a
			-- `UDim2.fromScale(1, 1)` label, which is what the two hand-rolled caps this component
			-- replaced both used -- cannot be used here: this cap is AutomaticSize.X, and a scale-1
			-- WIDTH inside an auto-width parent is a feedback loop (see Label.lua's AutoWidth prop for
			-- the full account, and for the screen-filling hotbar it produced). Nothing in this cap
			-- uses Scale on either axis now, so its width is exactly padding + glyph.
			scope:New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Label(scope, {
				Text = props.Key,
				-- Mono, like every other glyph-in-a-box in this UI: a keycap is a fixed-advance
				-- character sitting in a fixed-width well, which is what the numeral face is for.
				--
				-- Deliberately NOT one of Tokens.Type's tracked caps steps (Abbrev/Chip), even though a
				-- key cap is exactly the sort of short caps token those exist for. Those belong to
				-- Components/TrackedLabel.lua, whose Text cannot be reactive -- and this cap's must be
				-- (see the header). Label.lua's scale union excludes those steps so that mistake is a
				-- compile error rather than tracking silently dropped in a screenshot.
				Scale = "NumeralSmall",
				Color = scope:Computed(function(use)
					return if use(isActive) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextPrimary
				end),
				AutoWidth = true,
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	}) :: Frame
end

return KeyCap
