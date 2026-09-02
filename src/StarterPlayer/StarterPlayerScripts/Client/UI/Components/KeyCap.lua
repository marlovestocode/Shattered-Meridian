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

	PASS `Action` RATHER THAN `Key` AND THE CAP STOPS LYING ON A PAD. Handing in a literal string, or
	a KeybindManager.Get read done at the call site, produces a cap that shows a KEYBOARD key to a
	player holding a controller -- which is what every legend in this game did before this prop
	existed: Screens/HUD/init.lua rendered live keyboard bindings only, Screens/HUD/ArmamentIsland.lua
	read Constants.Keybinds.Defaults directly and ignored rebinds outright, and Screens/BlimpHelm
	hardcoded the literal strings "W"/"S"/"A". With `Action`, the glyph comes from Client/Input/Glyph.
	lua, which answers for whichever device the player is holding RIGHT NOW and recomputes on both a
	device switch and a rebind. One prop, and every one of those surfaces is fixed at once.

	THERE IS A THIRD WAY TO NAME A CAP, AND IT IS FOR THE KEYS NO ACTION OWNS. `Binding` takes a
	Client/Input/Glyph.lua Binding -- a KeyCode per device, optionally with an action as a per-device
	fallback -- and exists because a real class of control in this game is deliberately NOT a
	Types.KeybindAction: the blimp helm's throttle/rudder/all-stop (BlimpConstants.Controls) and the
	furnace's unload key are contextual, read only while the player is standing somewhere specific, and
	invisible to a rebind screen with no notion of "while piloting". Before this prop those caps had no
	honest option -- `Action` cannot name them and `Key` draws one device's key at every player -- so
	the helm legend showed "W" to somebody holding a controller. The fallback is what lets ONE binding
	carry a control that is a bound action on one device and a contextual key on the other, which the
	helm's release is.

	A GLYPH-DRIVEN CAP MOUNTS TWO GLYPH CHILDREN, a Label and an ImageLabel, and toggles Visible
	between them; a Key-driven cap mounts only the Label it always did. This is deliberate, and the
	asymmetry is the point. Glyph.lua returns a DISCRIMINATED result -- an engine button image for a
	gamepad KeyCode, text otherwise -- and which one applies changes at runtime when the player sets
	the controller down. Fusion's child set is structural, so a cap that could ever need either has to
	hold both; a cap handed a literal string can never need the image and does not pay for one. A
	UIListLayout skips invisible children, so the hidden one contributes nothing to the cap's
	AutomaticSize.X width either.

	Does not own: what any key is bound to, or what pressing it does. Even with `Action`, this file
	resolves nothing itself -- Glyph.lua owns the device question and KeybindManager.lua owns the
	binding, exactly as they did before this cap could ask them. Every glyph is still reactive,
	because a cap naming a rebindable action has to change when the player rebinds it without the
	panel around it being torn down and rebuilt.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Glyph = require(script.Parent.Parent.Parent.Input.Glyph)

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
	-- Reactive -- see this file's header on rebinding. Optional ONLY because `Action` or `Binding`
	-- below can supply it instead; exactly one of the three must be given, and passing more than one
	-- is a caller bug the assert below names rather than resolving by silent precedence.
	Key: UsedAs<string>?,
	-- The rebindable action this cap stands for. Preferred over `Key` for anything a player can
	-- actually press -- see this file's header for the four surfaces that lied on a pad without it.
	-- `Key` stays right for a cap that names something that is NOT a Types.KeybindAction (a literal
	-- the engine owns, like Roblox's own non-rebindable jump).
	Action: Types.KeybindAction?,
	-- The third way to name a cap, for a control that is NOT a Types.KeybindAction but still has to be
	-- drawn for the right device -- the blimp helm's throttle and rudder, the furnace's unload key. A
	-- Client/Input/Glyph.lua Binding names the KeyCode for each device directly (and may carry an
	-- action as a per-device fallback, which is how the helm's release is the live Interact bind on a
	-- keyboard and a plain ButtonX on a pad). Resolves through the same Glyph path `Action` does, so
	-- it gets the same image-or-text answer and the same redraw on a device switch.
	--
	-- `Key` is still right for a cap naming something with no per-device answer at all -- a literal the
	-- engine owns, spelled the same way everywhere.
	Binding: Glyph.Binding?,
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

-- Total pixels taken off the cap height to size a button glyph -- one per side, so a round face-button
-- image sits inside the well instead of touching its border on both edges.
local GLYPH_INSET = 2

-- Horizontal padding for an IMAGE glyph, where Space.XS is the padding for a text one -- see the
-- UIPadding below for why the two differ. Half of GLYPH_INSET, so the margin around a button image is
-- the same on all four sides.
local IMAGE_SIDE_PADDING = GLYPH_INSET // 2

local function KeyCap(scope: Scope, props: KeyCapProps): Frame
	local named = (if props.Key ~= nil then 1 else 0)
		+ (if props.Action ~= nil then 1 else 0)
		+ (if props.Binding ~= nil then 1 else 0)
	assert(
		named == 1,
		"KeyCap needs exactly one of Key, Action or Binding -- see this file's header on which to reach for"
	)

	local isActive: UsedAs<boolean> = props.Active or false
	local tone: KeyCapTone = props.Tone or "Quiet"

	-- nil for a Key-driven cap, which is what keeps it from mounting an ImageLabel it can never use.
	-- The two Glyph-driven forms differ only in what they ask that module -- an action or a per-device
	-- binding -- and produce the same reactive result, so everything below this line is shared.
	local glyph: Fusion.Computed<Glyph.Glyph>? = if props.Action ~= nil
		then Glyph.For(scope, props.Action :: Types.KeybindAction)
		elseif props.Binding ~= nil then Glyph.ForBinding(scope, props.Binding :: Glyph.Binding)
		else nil

	-- The text the cap draws. A Key-driven cap draws what it was handed; a glyph-driven cap draws
	-- the glyph's text and falls silent (an empty string, so the Label collapses) on the frames the
	-- image is showing instead.
	local text: UsedAs<string> = if glyph ~= nil
		then scope:Computed(function(use)
			local resolved = use(glyph :: Fusion.Computed<Glyph.Glyph>)
			return if resolved.Kind == "Text" then resolved.Value else ""
		end)
		else props.Key :: UsedAs<string>

	-- Which of the two horizontal paddings this cap is currently wearing -- see the UIPadding below.
	-- A Key-driven cap can never show an image, so it takes the text padding as a constant and mounts
	-- no Computed at all.
	local imageSidePadding: UsedAs<UDim> = if glyph ~= nil
		then scope:Computed(function(use)
			local resolved = use(glyph :: Fusion.Computed<Glyph.Glyph>)
			return UDim.new(0, if resolved.Kind == "Image" then IMAGE_SIDE_PADDING else Tokens.Space.XS)
		end)
		else UDim.new(0, Tokens.Space.XS)

	local glyphColor = scope:Computed(function(use)
		return if use(isActive) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextPrimary
	end)

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
		-- A CAP WITH NOTHING TO SAY DOES NOT DRAW AN EMPTY WELL. Only reachable through `Binding`, and
		-- only for a control the CURRENT device folds into an input another cap on the same row already
		-- names -- see Client/Input/Glyph.ResolveBinding for why that answer is empty rather than
		-- "Unbound". The helm legend's rudder row is the case: two keys on a keyboard, one thumbstick
		-- on a pad, and drawing that stick twice side by side would say the player needs two of them.
		-- A UIListLayout skips invisible children, so the hidden cap costs the row no width either.
		Visible = if glyph ~= nil
			then scope:Computed(function(use)
				local resolved = use(glyph :: Fusion.Computed<Glyph.Glyph>)
				return resolved.Kind == "Image" or resolved.Value ~= ""
			end)
			else nil,
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
			--
			-- AN IMAGE GLYPH GETS LESS OF IT THAN A TEXT ONE, AND THAT KEEPS A CAP COLUMN'S ARITHMETIC
			-- TRUE ON A PAD. Space.XS is tuned for a LETTER, which is drawn tight to its own bounding
			-- box and needs room to read as a key rather than as a character. A button image is not:
			-- it is already inset from the well by GLYPH_INSET vertically and carries its own margin
			-- inside the asset, so the same 4px on each side made an image cap 8px wider than the
			-- MinWidth its caller sized a fixed column against. Screens/BlimpHelm is where that showed
			-- up -- its KEY_COLUMN_WIDTH is measured as two 17px caps plus a gap, and a row of two
			-- gamepad glyphs ran 8px under the description beside it. At half GLYPH_INSET an image cap
			-- measures 1 + (Height - 2) + 1, which is two pixels UNDER the 17px default MinWidth and so
			-- renders at exactly that minimum -- the column arithmetic holds, and every other caller's
			-- image caps get NARROWER (never wider), which no fixed column can be broken by.
			scope:New("UIPadding")({
				PaddingLeft = imageSidePadding,
				PaddingRight = imageSidePadding,
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
			-- The engine's own button glyph, mounted ONLY for a glyph-driven cap -- see the header.
			-- Tinted with the same Computed the text uses, so "this is currently engaged" stays a hue
			-- change on a pad exactly as it is on a keyboard; the DesignSystem glyphs
			-- UserInputService:GetImageForKeyCode returns are white silhouettes authored to be tinted.
			if glyph ~= nil
				then scope:New("ImageLabel")({
					Name = "Glyph",
					BackgroundTransparency = 1,
					-- Square, and one pixel inside the cap's well on each side, so a round face-button
					-- glyph sits in the cap rather than straining against its border.
					Size = UDim2.fromOffset(
						(props.Height or DEFAULT_HEIGHT) - GLYPH_INSET,
						(props.Height or DEFAULT_HEIGHT) - GLYPH_INSET
					),
					-- Fit, not Stretch: these glyphs are not all square, and a squashed ButtonR1 is
					-- unreadable at 15 pixels.
					ScaleType = Enum.ScaleType.Fit,
					Image = scope:Computed(function(use)
						local resolved = use(glyph :: Fusion.Computed<Glyph.Glyph>)
						return if resolved.Kind == "Image" then resolved.Value else ""
					end),
					ImageColor3 = glyphColor,
					Visible = scope:Computed(function(use)
						return use(glyph :: Fusion.Computed<Glyph.Glyph>).Kind == "Image"
					end),
				})
				else nil,
			Label(scope, {
				Text = text,
				-- A glyph-driven cap hides the Label outright on the frames the image is showing,
				-- rather than leaving an empty one in the run -- a UIListLayout arranges every VISIBLE
				-- child, so an empty-but-visible Label would still contribute its own padding to the
				-- cap's AutomaticSize.X width.
				Visible = if glyph ~= nil
					then scope:Computed(function(use)
						return use(glyph :: Fusion.Computed<Glyph.Glyph>).Kind == "Text"
					end)
					else nil,
				-- Mono, like every other glyph-in-a-box in this UI: a keycap is a fixed-advance
				-- character sitting in a fixed-width well, which is what the numeral face is for.
				--
				-- Deliberately NOT one of Tokens.Type's tracked caps steps (Abbrev/Chip), even though a
				-- key cap is exactly the sort of short caps token those exist for. Those belong to
				-- Components/TrackedLabel.lua, whose Text cannot be reactive -- and this cap's must be
				-- (see the header). Label.lua's scale union excludes those steps so that mistake is a
				-- compile error rather than tracking silently dropped in a screenshot.
				Scale = "NumeralSmall",
				Color = glyphColor,
				AutoWidth = true,
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		},
	}) :: Frame
end

return KeyCap
