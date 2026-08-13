--!strict
--[[
	WheelSegment.lua

	Owns: a single slot on the radial emote wheel -- the tile at one point on the circle, rendering
	the bound emote's DisplayName and swapping to a brighter/expanded look while Selected. Every
	emote in Shared/Emotes/EmoteDefinitions.lua ships with Icon = "" today (this codebase never
	fabricates a plausible-looking asset id -- see that file's own header), so this renders text-only
	now; the branch point for a future real icon is IconAssetId below, which stays nil until a real
	Types.EmoteDefinition.Icon exists to pass it (mirrors AbilitySlot.lua's own IconAssetId contract).

	Chrome follows this UI's established chamfered-tile vocabulary exactly (AbilitySlot.lua/Panel.lua):
	Client/UI/ChamferedSurface.lua's true cut-corner fill+stroke when ChamferedSurface.IsAvailable(),
	falling back to plain UICorner+UIStroke otherwise -- never assumed available (see that module's
	own Deployment gate).

	Selected is a UsedAs<boolean> the caller (init.lua's ForPairs loop) recomputes per-segment from
	the wheel's single shared SelectedIndex Value -- only the one segment whose own boolean actually
	flips re-tweens (a Fusion Computed/Spring only re-fires when the value it's fed changes), so
	moving the mouse across the wheel never touches the other 7 segments' own Instances or springs.
	The expand/brighten transition itself rides a single scope:Spring seeded from Tokens.Motion.
	StateSpring -- the exact "edge highlight easing in/out on a state change" preset AbilitySlot.lua's
	own header already documents this token for.

	Does not own: where on the circle this tile sits (WheelSelection.GetSegmentPosition, computed by
	the caller and passed in as Position/AnchorPoint), or deciding which segment is selected
	(EmoteWheelClient.lua, via WheelSelection.GetSelectedIndex).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.Parent.ChamferedSurface)
local Label = require(script.Parent.Parent.Parent.Components.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type WheelSegmentProps = {
	Emote: Types.EmoteDefinition,
	Selected: UsedAs<boolean>,
	Size: UsedAs<UDim2>,
	Position: UsedAs<UDim2>,
	AnchorPoint: UsedAs<Vector2>,
	-- Reserved for a future real Types.EmoteDefinition.Icon -- see file header. Omitted by every
	-- caller today (every current emote's Icon is ""), so this renders no ImageLabel until a real
	-- caller passes one, the same "no glyph substitute" contract AbilitySlot.lua's own IconAssetId
	-- documents.
	IconAssetId: string?,
}

local STATE_SPRING_SPEED = Tokens.Motion.StateSpring.Speed
local STATE_SPRING_DAMPING = Tokens.Motion.StateSpring.Damping

-- How much a selected segment grows over its resting scale -- restrained per docs/ui-ux-philosophy.
-- md's Animation Philosophy ("controlled... not excessive"), just enough to read as "this one is
-- about to fire" at a glance.
local SELECTED_SCALE_BOOST = 0.12

-- Dark, translucent tile fill (this feature's own design brief) rather than a fully opaque one --
-- the wheel sits directly over live gameplay, and a solid tile would read as a heavier modal than a
-- quick-select radial wants to. Resting a touch more transparent than selected, so the highlighted
-- segment reads as "more present" the same way its brighter border/text already do.
local FILL_TRANSPARENCY_RESTING = 0.35
local FILL_TRANSPARENCY_SELECTED = 0.15

local function WheelSegment(scope: Scope, props: WheelSegmentProps): Frame
	local isChamfered = ChamferedSurface.IsAvailable()

	local selectedProgress = scope:Spring(
		scope:Computed(function(use)
			return if use(props.Selected) then 1 else 0
		end),
		STATE_SPRING_SPEED,
		STATE_SPRING_DAMPING
	)

	local scaleMultiplier = scope:Computed(function(use)
		return 1 + use(selectedProgress) * SELECTED_SCALE_BOOST
	end)

	local backgroundColor = scope:Computed(function(use)
		return if use(props.Selected) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
	end)

	local backgroundTransparency = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return FILL_TRANSPARENCY_RESTING - progress * (FILL_TRANSPARENCY_RESTING - FILL_TRANSPARENCY_SELECTED)
	end)

	-- Tokens.Border.Standard.Color, not the deprecated Tokens.Color.BorderSubtle -- see that token's
	-- own header ("New code uses Tokens.Border.Standard... and Tokens.Color.AccentPrimary").
	local strokeColor = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return Tokens.Border.Standard.Color:Lerp(Tokens.Color.AccentPrimaryBright, progress)
	end)

	local strokeTransparency = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return Tokens.Border.Standard.Transparency
			- progress * (Tokens.Border.Standard.Transparency - Tokens.Border.Lit.Transparency)
	end)

	local textColor = scope:Computed(function(use)
		local progress = use(selectedProgress)
		return Tokens.Color.TextSecondary:Lerp(Tokens.Color.AccentPrimaryBright, progress)
	end)

	local shellChildren: { Instance } = {}
	if isChamfered then
		local fill = ChamferedSurface.Fill(scope, {
			FillColor = backgroundColor,
			FillTransparency = backgroundTransparency,
			ZIndex = 0,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = strokeColor,
			Transparency = strokeTransparency,
			Weight = "Thick",
			ZIndex = 2,
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
				ZIndex = 0,

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

	local iconChildren: { Instance } = {}
	if props.IconAssetId ~= nil then
		table.insert(
			iconChildren,
			scope:New "ImageLabel" {
				Name = "Icon",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0.12),
				Size = UDim2.fromScale(0.34, 0.34),
				BackgroundTransparency = 1,
				Image = props.IconAssetId,
				ScaleType = Enum.ScaleType.Fit,
				ZIndex = 3,
			} :: ImageLabel
		)
	end

	return scope:New "Frame" {
		Name = "WheelSegment_" .. props.Emote.Id,
		Size = props.Size,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIScale" {
				Scale = scaleMultiplier,
			},
			shellChildren,
			iconChildren,
			Label(scope, {
				Text = props.Emote.DisplayName,
				Scale = "Body",
				Color = textColor,
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, if #iconChildren > 0 then 0.92 else 0.7),
				Size = UDim2.fromScale(0.88, 0.3),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = true,
				ZIndex = 3,
			}),
		},
	} :: Frame
end

return WheelSegment
