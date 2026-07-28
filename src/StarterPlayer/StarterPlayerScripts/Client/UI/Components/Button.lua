--!strict
--[[
	Button.lua

	Owns: the interactive button primitive -- background/border/hover/press treatment per
	Tokens.lua, sharp-edged per the locked Aesthetic direction.

	Hover/press are purely visual, scope-local Fusion state; they never touch ClientState or
	anything gameplay-relevant. Buttons only ever *request* -- matching
	luau-coding-standards.md's client/server split rule ("a client module should never contain a
	function named ApplyDamage -- it should contain RequestAttack"). What OnActivated does with
	that request is the caller's responsibility, not this component's.

	Variant (docs/design/intro-redesign-figma-spec.md section 6) is strictly additive -- omitting it
	(every pre-redesign call site: DevMenu/BugReport/Announcement/...) renders this file's ORIGINAL
	background/text treatment byte-for-byte, including the plain (untracked, mixed-case) Text
	property. Only a caller that explicitly passes "Primary" or "Secondary" gets the redesign's
	tracked-caps look; nothing moves without an explicit Variant (user decision, 2026-07-25 -- this
	component has no way to smoke-test itself in Studio this session, so the blast radius on existing
	buttons is kept at zero).
	- "Primary": accent fill, Surface-colored text (not white -- the text IS the dark surface color
	  sitting on the bright fill), a Glow (Components/Glow.lua) at its own defaults (already tuned to
	  this exact button's spec, see that file's header). Press does NOT turn the background
	  AccentPrimary the way the legacy path does -- it's already AccentPrimary at rest, so that cue
	  would be invisible here. Press instead thickens the border (1px -> 2px), the same
	  brightness/thickness-over-color-alone language ActionIcon's Armed state and Bar's critical
	  stroke already use elsewhere in this UI.
	- "Secondary": no fill, a bordered outline (Tokens.Border.Standard, brightening to .Lit on hover
	  and AccentPrimary on press) with TextSecondary/TextPrimary copy -- the BACK button's treatment.

	Primary/Secondary render their visible text through Components/TrackedLabel.lua (tracked caps)
	instead of this TextButton's own Text property, which is left blank under a Variant -- an earlier
	version kept it set-but-transparent for gamepad/screen-reader nav (ActionIcon.lua's convention),
	but a same-caption native Text still visibly double-rendered against TrackedLabel's own, WIDER,
	letter-spaced run (both centered on the same point) the instant TextTransparency wasn't perfectly
	opaque in practice -- confirmed live in Studio, 2026-07-27. Blank avoids that outright; a future
	pass wanting gamepad/screen-reader text back under a Variant needs a mechanism that doesn't
	re-render the same caption a second time (e.g. reading it off the TrackedLabel's own glyphs).
	Per TrackedLabel's own header this means the text is read ONCE via peek at construction time, not
	reactively -- every current Primary/Secondary caller (onboarding's Continue/Confirm/Back) passes
	static copy. A future caller that needs LIVE button text under a Variant should stay on the legacy
	(Variant = nil) path instead, or extend this file deliberately.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local TrackedLabel = require(script.Parent.TrackedLabel)
local Glow = require(script.Parent.Glow)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ButtonProps = {
	Text: UsedAs<string>,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	Disabled: UsedAs<boolean>?,
	-- See file header. Omit for this file's original, unchanged rendering.
	Variant: ("Primary" | "Secondary")?,
	OnActivated: (() -> ())?,
}

local function Button(scope: Scope, props: ButtonProps): TextButton
	local isHovering = scope:Value(false)
	local isPressing = scope:Value(false)
	local disabled: UsedAs<boolean> = if props.Disabled == nil then false else props.Disabled
	local variant = props.Variant

	local isActive = scope:Computed(function(use)
		return not use(disabled)
	end)

	local backgroundColor = scope:Computed(function(use)
		if variant == "Primary" then
			return if use(disabled) then Tokens.Wash.Inset.Color else Tokens.Color.AccentPrimary
		elseif variant == "Secondary" then
			return Tokens.Color.Background -- never actually painted -- backgroundTransparency is 1.
		end
		-- Legacy (see file header): original behavior, unchanged.
		if use(disabled) then
			return Tokens.Color.Surface
		elseif use(isPressing) then
			return Tokens.Color.AccentPrimary
		elseif use(isHovering) then
			return Tokens.Color.SurfaceElevated
		end
		return Tokens.Color.Surface
	end)

	local backgroundTransparency = scope:Computed(function(use)
		if variant == "Secondary" then
			return 1
		elseif variant == "Primary" then
			return if use(disabled) then Tokens.Wash.Inset.Transparency else 0
		end
		return 0
	end)

	local textColor = scope:Computed(function(use)
		if use(disabled) then
			return Tokens.Color.TextDisabled
		end
		if variant == "Primary" then
			-- The design's own callout: text is the SURFACE color, not white -- it reads as dark
			-- text sitting on the bright accent fill, not as a light-on-dark label.
			return Tokens.Color.Surface
		elseif variant == "Secondary" then
			return if use(isPressing) or use(isHovering) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
		end
		return Tokens.Color.TextPrimary
	end)

	local borderColor = scope:Computed(function(use)
		if variant == "Primary" then
			return if use(disabled) then Tokens.Border.Standard.Color else Tokens.Color.AccentPrimary
		end
		-- Secondary.
		if use(disabled) then
			return Tokens.Border.Hairline.Color
		elseif use(isPressing) then
			return Tokens.Color.AccentPrimary
		elseif use(isHovering) then
			return Tokens.Border.Lit.Color
		end
		return Tokens.Border.Standard.Color
	end)
	local borderTransparency = scope:Computed(function(use)
		if variant == "Primary" then
			return if use(disabled) then Tokens.Border.Standard.Transparency else 0
		end
		return if use(disabled) then Tokens.Border.Hairline.Transparency else 0
	end)
	local borderThickness = scope:Computed(function(use)
		if variant == "Primary" then
			-- See file header: Primary's press cue is border thickness, not background color --
			-- the background is already AccentPrimary at rest.
			return if use(isPressing) then 2 else 1
		end
		return 1
	end)

	local children: { Instance } = {
		scope:New "UICorner" {
			CornerRadius = Tokens.Radius.Sharp,
		},
	}

	if variant == "Primary" then
		-- Primary's only hover cue -- background/border/text are all already at their brightest,
		-- fully-opaque resting value for this variant (the fill IS AccentPrimary at rest; Tokens.
		-- Color.AccentPrimaryBright is reserved for text-on-dark use, never a fill, per its own
		-- comment in Tokens.lua, so it isn't a candidate here either), so hover brightens the
		-- existing halo instead of introducing a second fill color. Press keeps its own separate
		-- cue (border 1px -> 2px, above) -- the two states read as distinct kinds of feedback rather
		-- than fighting over the same signal.
		local glowTransparency = scope:Computed(function(use)
			return if use(isHovering) then 0.65 else 0.8
		end)
		table.insert(
			children,
			Glow(scope, {
				Color = Tokens.Color.AccentPrimary,
				Visible = isActive,
				Transparency = glowTransparency,
				ZIndex = 0,
			})
		)
	end

	if variant then
		table.insert(
			children,
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = borderThickness,
				Transparency = borderTransparency,
			}
		)
		table.insert(
			children,
			TrackedLabel(scope, {
				-- Peek'd once, not reactive -- see file header.
				Text = string.upper(peek(props.Text)),
				Scale = "Action",
				Color = textColor,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				ZIndex = 2,
			})
		)
	end

	return scope:New "TextButton" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromOffset(160, Tokens.Control.RowHeight),
		LayoutOrder = props.LayoutOrder,
		AutoButtonColor = false,
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
		-- Under a Variant, this native Text is left BLANK -- the TrackedLabel child above renders the
		-- visible copy instead. A same-caption-but-transparent Text here (the original approach) still
		-- double-rendered: the native Text draws centered at this TextButton's own (untracked) glyph
		-- widths while the TrackedLabel draws its own, WIDER, letter-spaced run centered on top of it,
		-- so even at TextTransparency 1 the two run's differing layouts visibly fought each other the
		-- instant transparency wasn't perfectly opaque in practice. Blank avoids the conflict outright.
		Text = if variant then "" else props.Text,
		FontFace = if variant then Tokens.Type.Action.Face else Tokens.Type.Body.Face,
		TextSize = if variant then Tokens.Type.Action.Size else Tokens.Type.Body.Size,
		TextColor3 = textColor,
		Active = isActive,

		[OnEvent "MouseEnter"] = function()
			isHovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovering:set(false)
			isPressing:set(false)
		end,
		[OnEvent "MouseButton1Down"] = function()
			isPressing:set(true)
		end,
		[OnEvent "MouseButton1Up"] = function()
			isPressing:set(false)
		end,
		[OnEvent "Activated"] = function()
			if not peek(disabled) and props.OnActivated then
				props.OnActivated()
			end
		end,

		[Children] = children,
	} :: TextButton
end

return Button
