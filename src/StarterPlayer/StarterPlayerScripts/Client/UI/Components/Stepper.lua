--!strict
--[[
	Stepper.lua

	Owns: the "-"/"+" numeric stepper -- two small icon buttons flanking a centred mono readout, used
	by the Attributes screen's per-stat rows (docs/design/intro-redesign-figma-spec.md section 5) and
	any future "nudge one integer within a fixed range" control that wants the same shape. Owns the
	clamp-to-[Min,Max]-by-Step math itself, so a caller only ever receives an already-legal candidate
	value in OnChanged -- the same "presentation-scoped convenience, never a substitute for real
	validation" contract RaceSelect.lua/Attributes.lua already hold themselves to; a caller with its
	own additional constraint (e.g. a shared points budget) is still free to reject or further clamp
	whatever OnChanged hands it.

	Does NOT own DevMenu's existing +-0.01/+-0.1 tuning steppers or its "<"/">" cycle steppers
	(Screens/DevTools/DevMenu/init.lua) -- those are hand-rolled, differently-shaped controls with their own
	Tokens.Control.StepButtonSize geometry, and folding them into this component is an explicitly
	separate follow-up per the redesign handoff, not an oversight.

	Glyphs are local Frame composition, matching VitalIcon.lua/ActionIcon.lua's established
	no-image-asset technique -- deliberately NOT added to ActionIcon's ActionIconGlyphKind registry,
	since a stepper button is a different control shape (no Selected/Armed states, a Disabled state
	ActionIcon has no concept of) wearing a superficially similar tile.

	Button size floors at Tokens.Control.TouchTargetSize (44) on a touch session -- the design's own
	28px (docs/design/intro-redesign-handoff.md's mobile pass: "28px steppers... fail on a phone").
	Read once at module load (see Tokens.lua's own IS_TOUCH note for why this is a stable per-session
	fact, not something tracked reactively); the glyph grows a proportional amount alongside it so it
	doesn't look lost in the larger tile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Selection = require(script.Parent.Selection)
local Label = require(script.Parent.Label)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type StepperProps = {
	Value: UsedAs<number>,
	-- UsedAs, not a plain number -- the Attributes screen's own floor is race-dependent
	-- (Constants.CharacterCreation.AttributeFloors), and a screen instance persists across a race
	-- change (Onboarding/init.lua mounts every stage once, toggling Visible rather than rebuilding),
	-- so a plain number captured once at construction would go stale the moment the player goes
	-- Back and picks a different race.
	Min: UsedAs<number>,
	Max: number,
	-- Defaults to 1 -- every current caller (the Attributes screen's whole-point stats) steps by
	-- whole integers; a fractional Step works too (the clamp math below is unit-agnostic).
	Step: number?,
	OnChanged: (newValue: number) -> (),
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
}

-- The design's own numbers (docs/design/intro-redesign-figma-spec.md section 5) -- component-local
-- geometry, not general spacing rhythm, so these live here rather than in Tokens.Space/Tokens.Control
-- (same precedent as VitalIcon.lua's TILE_SIZE/GLYPH_SIZE and ActionIcon.lua's own constants).
local IS_TOUCH = UserInputService.TouchEnabled
local BUTTON_SIZE = if IS_TOUCH then Tokens.Control.TouchTargetSize else 28
local GLYPH_SIZE = if IS_TOUCH then 12 else 9
local GLYPH_THICKNESS = 2
local READOUT_WIDTH = 36 -- "w-9" (Tailwind's 4px unit * 9)
local GAP = 10 -- "gap-2.5"

local function MinusGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_THICKNESS),
		BackgroundColor3 = color,
		BorderSizePixel = 0,

		[Children] = scope:New "UICorner" {
			CornerRadius = UDim.new(0.5, 0), -- "a 9x2 ROUNDED bar" per spec.
		},
	} :: Frame
end

local function PlusGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_SIZE),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "Frame" {
				Name = "Horizontal",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_THICKNESS),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			},
			scope:New "Frame" {
				Name = "Vertical",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_THICKNESS, GLYPH_SIZE),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			},
		},
	} :: Frame
end

-- One stepper button ("-" or "+"). `enabled` is a Computed<boolean> rather than a plain boolean
-- since it tracks Value against Min/Max live.
local function StepButton(
	scope: Scope,
	glyphRenderer: (Scope, UsedAs<Color3>) -> Frame,
	enabled: Fusion.Computed<boolean>,
	layoutOrder: number,
	onActivated: () -> ()
): TextButton
	-- Pointer-over AND gamepad-selection, OR-ed into the single boolean every visual Computed
	-- below already reads as `isHovering` -- see Components/Selection.lua for why the two stay
	-- separate rather than both writing one Value.
	local isPressing = scope:Value(false)
	local engagement = Selection.New(scope, isPressing)
	local isHovering = engagement.Active

	local borderColor = scope:Computed(function(use)
		if not use(enabled) then
			return Tokens.Border.Standard.Color
		end
		return if use(isPressing)
			then Tokens.Color.AccentPrimary
			elseif use(isHovering) then Tokens.Border.Lit.Color
			else Tokens.Border.Standard.Color
	end)
	-- "disabled:opacity-20" (docs/design/intro-redesign-figma-spec.md) has no single Roblox
	-- equivalent for a whole subtree (per the handoff's own substitution table) -- faded per-property
	-- instead, on both the border stroke below and the glyph color.
	local borderTransparency = scope:Computed(function(use)
		if not use(enabled) then
			return 0.8
		end
		return if use(isPressing) then 0 else Tokens.Border.Standard.Transparency
	end)
	local glyphColor = scope:Computed(function(use)
		if not use(enabled) then
			return Tokens.Color.TextDisabled
		end
		return if use(isPressing) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextSecondary
	end)

	return scope:New "TextButton" {
		Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE),
		LayoutOrder = layoutOrder,
		BackgroundColor3 = Tokens.Wash.Inset.Color,
		BackgroundTransparency = Tokens.Wash.Inset.Transparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Active = enabled,

		[OnEvent "SelectionGained"] = engagement.OnSelectionGained,
		[OnEvent "SelectionLost"] = engagement.OnSelectionLost,
		[OnEvent "MouseEnter"] = engagement.OnPointerEnter,
		[OnEvent "MouseLeave"] = engagement.OnPointerLeave,
		[OnEvent "MouseButton1Down"] = function()
			isPressing:set(true)
		end,
		[OnEvent "MouseButton1Up"] = function()
			isPressing:set(false)
		end,
		[OnEvent "Activated"] = function()
			if peek(enabled) then
				onActivated()
			end
		end,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Thickness = 1,
				Transparency = borderTransparency,
			},
			glyphRenderer(scope, glyphColor) :: Instance,
		},
	} :: TextButton
end

-- A table, not a bare function -- same shape as Components/VitalIcon.lua's own VitalIcon.new (and
-- Screens/Onboarding/StepRail.lua's identical StepRailModule), for the identical reason: a caller
-- laying out a "flex-1" neighbor beside a Stepper (Screens/Onboarding/Attributes.lua's stat rows)
-- needs this file's own rendered width to reserve the right amount of space, and must not re-guess
-- or duplicate the arithmetic to get it.
local StepperModule = {}
StepperModule.WIDTH = BUTTON_SIZE * 2 + READOUT_WIDTH + GAP * 2

function StepperModule.Mount(scope: Scope, props: StepperProps): Frame
	local step = props.Step or 1

	local canDecrement = scope:Computed(function(use)
		return use(props.Value) - step >= use(props.Min)
	end)
	local canIncrement = scope:Computed(function(use)
		return use(props.Value) + step <= props.Max
	end)

	local function commit(candidate: number): ()
		props.OnChanged(math.clamp(candidate, peek(props.Min), props.Max))
	end

	local valueText = scope:Computed(function(use)
		return tostring(use(props.Value))
	end)

	return scope:New "Frame" {
		Name = "Stepper",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			StepButton(scope, MinusGlyph, canDecrement, 1, function()
				commit(peek(props.Value) - step)
			end),
			Label(scope, {
				Text = valueText,
				Scale = "Numeral",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.fromOffset(READOUT_WIDTH, BUTTON_SIZE),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 2,
			}),
			StepButton(scope, PlusGlyph, canIncrement, 3, function()
				commit(peek(props.Value) + step)
			end),
		},
	} :: Frame
end

return StepperModule
