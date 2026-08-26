--!strict
--[[
	WheelSegment.lua

	Owns: a single slot on the radial emote wheel -- the tile at one point on the circle, carrying its
	slot numeral, its category mark, the bound emote's name, and everything that changes about all of
	those while the slot is Selected. Chrome follows this UI's established chamfered-tile vocabulary
	exactly (AbilitySlot.lua/Panel.lua): Client/UI/ChamferedSurface.lua's true cut-corner fill+stroke
	when ChamferedSurface.IsAvailable(), falling back to plain UICorner+UIStroke otherwise -- never
	assumed available (see that module's own Deployment gate).

	THE TILE MOVES OUTWARD, IT DOES NOT ONLY GROW. A selected slot slides along its own radial axis,
	away from the hub, on top of the scale change. That is what makes eight tiles read as eight
	positions on a dial rather than eight cards that happen to be arranged in a circle: the motion is
	along the axis the player's own cursor is travelling, so the tile appears to answer the gesture.
	It is why this component takes a base OFFSET (a Vector2 from the wheel's centre) instead of a
	finished Position -- the push has to compose with the placement, and only the component knows how
	far through its own selection spring it currently is.

	THE ENTRANCE STAGGERS WITHOUT A SINGLE TIMER. Each tile blooms outward from 0.72 of its resting
	radius as the wheel opens, and later slots start later -- but there is no task.delay chain and no
	per-tile tween here. The whole stagger is one Computed over the shared OpenProgress spring: slot
	n's own progress is that value shifted by n/count and renormalised, so the offset falls out of the
	one value that was already animating, and reverses for free on close. Nothing to cancel if the
	player releases the key mid-open, which is the failure mode a delay chain would have.

	Every emote in Shared/Emotes/EmoteDefinitions.lua ships with Icon = "" today (this codebase never
	fabricates a plausible-looking asset id -- see that file's own header), so no per-emote art is
	drawn: IconAssetId stays the branch point for a future real Types.EmoteDefinition.Icon (mirroring
	AbilitySlot.lua's own IconAssetId contract), and until one exists the tile shows the CATEGORY mark
	instead -- real authored data, drawn procedurally, no asset required. See WheelCategory.lua.

	Selected is a UsedAs<boolean> the caller (init.lua's ForPairs loop) recomputes per-segment from
	the wheel's single shared SelectedIndex Value -- only the one segment whose own boolean actually
	flips re-tweens (a Fusion Computed/Spring only re-fires when the value it's fed changes), so
	moving the mouse across the wheel never touches the other 7 segments' own Instances or springs.
	The expand/brighten transition itself rides a single scope:Spring seeded from Tokens.Motion.
	StateSpring -- the exact "edge highlight easing in/out on a state change" preset AbilitySlot.lua's
	own header already documents this token for.

	Does not own: where on the circle this tile's base offset sits (WheelSelection.GetSegmentPosition,
	computed by the caller and passed in), or deciding which segment is selected (EmoteWheelClient.lua,
	via WheelSelection.GetSelectedIndex).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.Parent.ChamferedSurface)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Glow = require(script.Parent.Parent.Parent.Components.Glow)
local WheelCategory = require(script.Parent.WheelCategory)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type WheelSegmentProps = {
	Emote: Types.EmoteDefinition,
	-- 1-based loadout slot. Printed on the tile because it is the slot a player rebinds in the
	-- Emotes menu, not a decoration -- the number on the tile and the number in the loadout are the
	-- same number.
	SlotIndex: number,
	Selected: UsedAs<boolean>,
	Size: UDim2,
	-- Screen-space offset from the wheel's centre, from WheelSelection.GetSegmentPosition. Reactive
	-- because the loadout length can change while the wheel is mounted.
	BaseOffset: UsedAs<Vector2>,
	-- The wheel's shared 0..1 open spring. See this file's header on the stagger.
	OpenProgress: UsedAs<number>,
	EntranceOrder: number,
	EntranceCount: number,
	-- Reserved for a future real Types.EmoteDefinition.Icon -- see file header. Omitted by every
	-- caller today (every current emote's Icon is ""), so this renders the category mark instead of
	-- an ImageLabel, the same "no fabricated glyph" contract AbilitySlot.lua's own IconAssetId
	-- documents.
	IconAssetId: string?,
	ZIndex: number?,
}

local STATE_SPRING_SPEED = Tokens.Motion.StateSpring.Speed
local STATE_SPRING_DAMPING = Tokens.Motion.StateSpring.Damping

-- How much a selected segment grows over its resting scale, and how far it slides outward along its
-- own radius. Both restrained per docs/ui-ux-philosophy.md's Animation Philosophy ("controlled...
-- not excessive"), and the push is the larger signal of the two on purpose -- see file header.
local SELECTED_SCALE_BOOST = 0.1
local SELECTED_PUSH_PIXELS = 14

-- Where a tile starts its entrance, as a fraction of its resting radius, and how much of the open
-- spring's travel is spent staggering rather than moving. 0.4 leaves 0.6 of the curve for each
-- individual tile's own bloom, which keeps the last slot's arrival inside the same settle the first
-- slot's is.
local ENTRANCE_RADIUS_FRACTION = 0.72
local ENTRANCE_SCALE_FLOOR = 0.86
local ENTRANCE_STAGGER_WINDOW = 0.4

-- Dark, translucent tile fill rather than a fully opaque one -- the wheel sits directly over live
-- gameplay, and a solid tile would read as a heavier modal than a quick-select radial wants to.
-- Resting a touch more transparent than selected, so the highlighted segment reads as "more present"
-- the same way its brighter border/text already do.
local FILL_TRANSPARENCY_RESTING = 0.25
local FILL_TRANSPARENCY_SELECTED = 0.08

-- The tile's text sits over the game world wherever the fill is translucent, so it carries its own
-- dark stroke -- the same reasoning Components/KeyLegend.lua's own header records for a caption with
-- no panel behind it.
local TEXT_STROKE_TRANSPARENCY = 0.55

local MARK_SIZE = 22
local MARK_PIP_SIZE = 6
local NUMERAL_INSET = 9

-- The bar that fills in along the tile's lower edge as it is selected -- a second, non-colour signal
-- that this is the slot that will fire, per the philosophy's "colour is never the only signal" rule.
local COMMIT_RULE_WIDTH = 56
local COMMIT_RULE_HEIGHT = 2
local COMMIT_RULE_INSET = 10

local function WheelSegment(scope: Scope, props: WheelSegmentProps): Frame
	local isChamfered = ChamferedSurface.IsAvailable()
	local zIndex = props.ZIndex or 3
	local tint = WheelCategory.Tint(props.Emote.Category)

	local selectedProgress = scope:Spring(
		scope:Computed(function(use)
			return if use(props.Selected) then 1 else 0
		end),
		STATE_SPRING_SPEED,
		STATE_SPRING_DAMPING
	)

	-- This tile's own share of the shared open spring -- see file header. EntranceCount <= 1 has no
	-- stagger to apply, and dividing by it would be a divide-by-zero on the renormalisation below.
	local entranceProgress = scope:Computed(function(use)
		local open = use(props.OpenProgress)
		if props.EntranceCount <= 1 then
			return math.clamp(open, 0, 1)
		end
		local start = ((props.EntranceOrder - 1) / props.EntranceCount) * ENTRANCE_STAGGER_WINDOW
		return math.clamp((open - start) / (1 - ENTRANCE_STAGGER_WINDOW), 0, 1)
	end)

	local position = scope:Computed(function(use)
		local offset = use(props.BaseOffset)
		local distance = offset.Magnitude
		if distance == 0 then
			return UDim2.fromScale(0.5, 0.5)
		end
		local entrance = use(entranceProgress)
		local radius = distance * (ENTRANCE_RADIUS_FRACTION + (1 - ENTRANCE_RADIUS_FRACTION) * entrance)
			+ SELECTED_PUSH_PIXELS * use(selectedProgress)
		local placed = offset.Unit * radius
		return UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(placed.X, placed.Y)
	end)

	local scaleMultiplier = scope:Computed(function(use)
		local entrance = ENTRANCE_SCALE_FLOOR + (1 - ENTRANCE_SCALE_FLOOR) * use(entranceProgress)
		return entrance * (1 + use(selectedProgress) * SELECTED_SCALE_BOOST)
	end)

	local backgroundColor = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
	end)

	local backgroundTransparency = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return FILL_TRANSPARENCY_RESTING - progress * (FILL_TRANSPARENCY_RESTING - FILL_TRANSPARENCY_SELECTED)
	end)

	-- Resting edge is the shared translucent-violet panel border; selected lerps toward the category's
	-- own tint rather than a single accent, so the tile that is about to fire says WHAT it is as well
	-- as THAT it is chosen.
	local strokeColor = scope:Computed(function(use)
		return Tokens.Border.Standard.Color:Lerp(tint, use(selectedProgress))
	end)

	local strokeTransparency = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return Tokens.Border.Standard.Transparency
			- progress * (Tokens.Border.Standard.Transparency - Tokens.Border.Lit.Transparency)
	end)

	local textColor = scope:Computed(function(use)
		return Tokens.Color.TextPrimary:Lerp(Tokens.Color.AccentPrimaryBright, use(selectedProgress))
	end)

	local numeralTransparency = scope:Computed(function(use)
		return 0.5 - use(selectedProgress) * 0.5
	end)

	local glowTransparency = scope:Computed(function(use)
		return 1 - use(selectedProgress) * 0.22
	end)

	local commitRuleSize = scope:Computed(function(use)
		return UDim2.fromOffset(COMMIT_RULE_WIDTH * use(selectedProgress), COMMIT_RULE_HEIGHT)
	end)

	local shellChildren: { Instance } = {}
	if isChamfered then
		local fill = ChamferedSurface.Fill(scope, {
			FillColor = backgroundColor,
			FillTransparency = backgroundTransparency,
			ZIndex = zIndex,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = strokeColor,
			Transparency = strokeTransparency,
			Weight = "Thick",
			ZIndex = zIndex + 1,
		})
		if fill and stroke then
			table.insert(shellChildren, fill)
			table.insert(shellChildren, stroke)
		else
			isChamfered = false
		end
	end

	if not isChamfered then
		table.insert(
			shellChildren,
			scope:New "Frame" {
				Name = "Fill",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = backgroundColor,
				BackgroundTransparency = backgroundTransparency,
				BorderSizePixel = 0,
				ZIndex = zIndex,

				[Children] = {
					scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
					scope:New "UIStroke" {
						Color = strokeColor,
						Thickness = 2,
						Transparency = strokeTransparency,
					},
				},
			}
		)
	end

	-- The emblem: a real icon the day one exists, the category mark until then. Both occupy the same
	-- well, so the tile's proportions do not change when art lands.
	local emblem: Instance
	if props.IconAssetId ~= nil then
		emblem = scope:New "ImageLabel" {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.38),
			Size = UDim2.fromOffset(MARK_SIZE + 8, MARK_SIZE + 8),
			BackgroundTransparency = 1,
			Image = props.IconAssetId,
			ImageColor3 = tint,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = zIndex + 2,
		} :: ImageLabel
	else
		emblem = scope:New "Frame" {
			Name = "CategoryMark",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.38),
			Size = UDim2.fromOffset(MARK_SIZE, MARK_SIZE),
			Rotation = 45,
			BackgroundTransparency = 1,
			ZIndex = zIndex + 2,

			[Children] = {
				scope:New "UIStroke" {
					Color = tint,
					Transparency = 0.35,
					Thickness = 1,
				},
				scope:New "Frame" {
					Name = "Pip",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(MARK_PIP_SIZE, MARK_PIP_SIZE),
					BackgroundColor3 = tint,
					BackgroundTransparency = scope:Computed(function(use)
						return 0.45 - use(selectedProgress) * 0.45
					end),
					BorderSizePixel = 0,
					ZIndex = zIndex + 3,
				},
			},
		}
	end

	return scope:New "Frame" {
		Name = "WheelSegment_" .. props.Emote.Id,
		Size = props.Size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = zIndex,

		[Children] = {
			scope:New "UIScale" {
				Scale = scaleMultiplier,
			},

			-- Invisible at rest (Transparency 1) and never re-evaluated on an idle frame, so the
			-- halo costs nothing until a selection spring actually moves -- the same zero-idle-cost
			-- contract Screens/HUD/init.lua's own header sets for the dock's cues.
			Glow(scope, {
				Color = tint,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				CornerRadius = Tokens.Radius.Sharp,
				Rings = 3,
				Spread = 16,
				Transparency = glowTransparency,
				ZIndex = zIndex - 1,
			}),

			shellChildren,
			emblem,

			Label(scope, {
				Text = tostring(props.SlotIndex),
				Scale = "NumeralSmall",
				Color = Tokens.Color.AccentSecondary,
				TextTransparency = numeralTransparency,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(NUMERAL_INSET, NUMERAL_INSET - 2),
				AutoWidth = true,
				ZIndex = zIndex + 2,
			}),

			Label(scope, {
				Text = props.Emote.DisplayName,
				Scale = "Body",
				Color = textColor,
				StrokeColor3 = Tokens.Color.Background,
				StrokeTransparency = TEXT_STROKE_TRANSPARENCY,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.76),
				Size = UDim2.fromScale(0.86, 0.32),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = true,
				ZIndex = zIndex + 2,
			}),

			scope:New "Frame" {
				Name = "CommitRule",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -COMMIT_RULE_INSET),
				Size = commitRuleSize,
				BackgroundColor3 = tint,
				BackgroundTransparency = 0.1,
				BorderSizePixel = 0,
				ZIndex = zIndex + 2,
			},
		},
	} :: Frame
end

return WheelSegment
