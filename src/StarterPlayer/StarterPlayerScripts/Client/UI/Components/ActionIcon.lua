--!strict
--[[
	ActionIcon.lua

	Owns: the compact icon-tile action button used by the roster row's per-player moderation actions
	(Kick/Ban/Mute/Flag-Suspected-Cheater, plus an overflow "⋯") -- Button.lua's hover/press
	interaction model, composed with VitalIcon.lua's exact procedural Frame/UIStroke glyph technique
	(no SVG, no asset upload -- see that module's own header for why this repo never guesses at an
	rbxassetid), generalizing Tab.lua's persistent Selected concept to an icon-only control that also
	needs a SECOND, distinct Armed state.

	Two independent boolean props, not one:
	- Selected: a persistent "this is currently on" state (Mute/Flag-Suspected's own toggled-on
	  look) -- the same concept Tab.lua's Selected already covers, just on an icon instead of text.
	  Also changes the glyph's own STRUCTURE for Mute/FlagSuspected specifically (a slash across the
	  Mute glyph, a filled vs. outlined pennant for Flag) -- read once via `peek` at construction
	  time, which is safe because every real call site passes a plain per-row snapshot boolean
	  (display.Muted/display.SuspectedCheater) that causes the WHOLE roster row Instance to be
	  rebuilt by scope:ForPairs whenever it changes, not a live Value this Instance would need to
	  react to in place.
	- Armed: a transient "press again to confirm" state (Ban's two-press confirm window) -- a REAL
	  reactive per-row Value (Sidebar.lua's isBanArmed), unlike Selected above. Distinct from Selected
	  because Armed reads as urgency (bright/thick border) where Selected reads as steady-state
	  (accent fill) -- per docs/ui-ux-philosophy.md's Critical States section ("increased brightness...
	  never excessive flashing"), this uses the brightness/thickness route rather than an actual pulse
	  animation, the same static-but-emphasized treatment VitalIcon's own isCritical stroke uses.

	`Text` is never rendered visually (the glyph is) -- it sets the underlying TextButton's own
	`Text`/`Name` so Roblox's accessibility/screen-reader integration and gamepad-nav/inspection
	tooling both have a real label to announce/attach to. No existing component in this codebase
	established an accessibility-label convention before this one (Button.lua/Tab.lua only ever
	render real visible text, which already IS their accessible label) -- this is a fresh, minimal
	one for an icon-only control that has no visible text of its own to serve that purpose.

	That same `Text` also now feeds HoverLabel.lua (see that file's header), reusing the isHovering
	Value below instead of duplicating hover-tracking -- a sighted mouse user gets the accessible
	label on hover, the same content the accessibility tree already had. AbsolutePosition/
	AbsoluteSize are wired into HoverLabel via Fusion.Out so it can position itself above this tile
	and clamp against the viewport edges.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local HoverLabel = require(script.Parent.HoverLabel)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Out = Fusion.Out
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ActionIconGlyphKind = "Kick" | "Ban" | "Mute" | "FlagSuspected" | "Overflow"

export type ActionIconProps = {
	Glyph: ActionIconGlyphKind,
	-- Accessible label -- see this file's own header. Also becomes this Instance's Name.
	Text: string,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	Selected: UsedAs<boolean>?,
	Armed: UsedAs<boolean>?,
	OnActivated: (() -> ())?,
}

local TILE_SIZE = Tokens.Control.StepButtonSize
local GLYPH_SIZE = 18
local GLYPH_THICKNESS = 2

local function glyphFrame(scope: Scope, children: { Instance }): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_SIZE),
		BackgroundTransparency = 1,
		ZIndex = 3,
		[Children] = children,
	} :: Frame
end

-- Rightward chevron ("❯") -- two bars meeting at the tile's trailing edge, reading as "send this
-- player out."
local function KickGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	local armLength = GLYPH_SIZE * 0.55
	local function arm(rotation: number): Frame
		return scope:New "Frame" {
			Name = "Arm",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(armLength, GLYPH_THICKNESS),
			Rotation = rotation,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 3,
		} :: Frame
	end
	return glyphFrame(scope, { arm(45), arm(-45) })
end

-- A ring with a diagonal slash -- the universal "no" symbol.
local function BanGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return glyphFrame(scope, {
		scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
		scope:New "UIStroke" { Color = color, Thickness = GLYPH_THICKNESS },
		scope:New "Frame" {
			Name = "Slash",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1.15, 0, 0, GLYPH_THICKNESS),
			Rotation = 45,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 3,
		},
	})
end

-- A filled dot (speaker) -- Muted state adds a diagonal slash across it, the same "add one crossing
-- bar" idea BanGlyph already uses for its own "off" state.
local function MuteGlyph(scope: Scope, color: UsedAs<Color3>, muted: boolean): Frame
	local children: { Instance } = {
		scope:New "Frame" {
			Name = "Body",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(GLYPH_SIZE * 0.62, GLYPH_SIZE * 0.62),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 3,
			[Children] = scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
		},
	}
	if muted then
		table.insert(
			children,
			scope:New "Frame" {
				Name = "Slash",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_SIZE * 1.1, GLYPH_THICKNESS),
				Rotation = 45,
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				ZIndex = 4,
			}
		)
	end
	return glyphFrame(scope, children)
end

-- A pole + pennant -- outlined (UIStroke) when unflagged, filled solid when Flagged, the same
-- "outline vs. fill" state cue Button.lua's own Selected/hover treatment already uses elsewhere in
-- this UI.
local function FlagGlyph(scope: Scope, color: UsedAs<Color3>, flagged: boolean): Frame
	local flagWidth = GLYPH_SIZE * 0.55
	local flagHeight = GLYPH_SIZE * 0.4
	local flagChildren: { Instance } = {}
	if not flagged then
		table.insert(flagChildren, scope:New "UIStroke" { Color = color, Thickness = GLYPH_THICKNESS * 0.5 })
	end
	return glyphFrame(scope, {
		scope:New "Frame" {
			Name = "Pole",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0.28, 0.85),
			Size = UDim2.fromOffset(GLYPH_THICKNESS, GLYPH_SIZE * 0.9),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 3,
		},
		scope:New "Frame" {
			Name = "Flag",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0.28, 0.42),
			Size = UDim2.fromOffset(flagWidth, flagHeight),
			BackgroundColor3 = color,
			BackgroundTransparency = if flagged then 0 else 1,
			BorderSizePixel = 0,
			ZIndex = 3,
			[Children] = flagChildren,
		},
	})
end

-- Three dots ("⋯") -- the overflow popover trigger.
local function OverflowGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	local dotSize = GLYPH_SIZE * 0.22
	local function dot(x: number): Frame
		return scope:New "Frame" {
			Name = "Dot",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, 0.5),
			Size = UDim2.fromOffset(dotSize, dotSize),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 3,
			[Children] = scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
		} :: Frame
	end
	return glyphFrame(scope, { dot(0.2), dot(0.5), dot(0.8) })
end

local function ActionIcon(scope: Scope, props: ActionIconProps): TextButton
	local isHovering = scope:Value(false)
	local isPressing = scope:Value(false)
	-- Fed by [Out "AbsolutePosition"]/[Out "AbsoluteSize"] below -- see this file's header and
	-- HoverLabel.lua's for why the hover label needs these to position/clamp itself.
	local anchorPosition = scope:Value(Vector2.new(0, 0))
	local anchorSize = scope:Value(Vector2.new(0, 0))
	local selected: UsedAs<boolean> = if props.Selected == nil then false else props.Selected
	local armed: UsedAs<boolean> = if props.Armed == nil then false else props.Armed

	local backgroundColor = scope:Computed(function(use)
		if use(isPressing) then
			return Tokens.Color.AccentPrimary
		elseif use(armed) or use(selected) or use(isHovering) then
			return Tokens.Color.SurfaceElevated
		end
		return Tokens.Color.Surface
	end)

	local borderColor = scope:Computed(function(use)
		if use(armed) then
			return Tokens.Color.Danger
		elseif use(selected) then
			return Tokens.Color.AccentPrimary
		end
		return Tokens.Color.BorderSubtle
	end)

	local borderThickness = scope:Computed(function(use)
		return if use(armed) then 2 else 1
	end)

	local glyphColor = scope:Computed(function(use)
		return if use(armed) then Tokens.Color.Danger else Tokens.Color.TextPrimary
	end)

	local glyph: Frame
	if props.Glyph == "Kick" then
		glyph = KickGlyph(scope, glyphColor)
	elseif props.Glyph == "Ban" then
		glyph = BanGlyph(scope, glyphColor)
	elseif props.Glyph == "Mute" then
		glyph = MuteGlyph(scope, glyphColor, peek(selected))
	elseif props.Glyph == "FlagSuspected" then
		glyph = FlagGlyph(scope, glyphColor, peek(selected))
	else
		glyph = OverflowGlyph(scope, glyphColor)
	end

	return scope:New "TextButton" {
		Name = props.Text,
		Size = props.Size or UDim2.fromOffset(TILE_SIZE, TILE_SIZE),
		LayoutOrder = props.LayoutOrder,
		AutoButtonColor = false,
		BackgroundColor3 = backgroundColor,
		BorderSizePixel = 0,
		-- Invisible accessible label -- see this file's own header. The glyph above (ZIndex 3) draws
		-- over this Text, which stays fully transparent so it never visually duplicates the glyph.
		Text = props.Text,
		TextTransparency = 1,
		FontFace = Tokens.Type.Caption.Face,
		TextSize = Tokens.Type.Caption.Size,

		[Out "AbsolutePosition"] = anchorPosition,
		[Out "AbsoluteSize"] = anchorSize,

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
			if props.OnActivated then
				props.OnActivated()
			end
		end,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = borderThickness,
			},
			glyph,
			HoverLabel(scope, {
				Visible = isHovering,
				Text = props.Text,
				AnchorPosition = anchorPosition,
				AnchorSize = anchorSize,
			}),
		},
	} :: TextButton
end

return ActionIcon
