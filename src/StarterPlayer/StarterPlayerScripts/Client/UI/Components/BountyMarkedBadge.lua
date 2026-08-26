--!strict
--[[
	BountyMarkedBadge.lua

	Owns: the hotbar warning shown to a player who is currently carrying a Notoriety bounty --
	"MARKED", plus what their head is worth. Renders from ClientState.BountyMarked/BountyReward,
	which Bootstrap() wires to BountySystem's Bounty_MarkedChanged remote (targeted at the marked
	player alone, never inferred from the global board) -- never computed here, per
	docs/ui-ux-philosophy.md's HUD sync rule.

	WHY THE TARGET IS TOLD AT ALL. A bounty the target can't see would be a purely punitive
	mechanic -- they'd just notice everyone attacking them and not know why. Telling them is what
	turns it into a decision: keep pushing the streak and get worth more, or break off and let it
	expire (BountyConstants.ExpirySeconds). docs/architecture/2026-08-audit.md section 7.3 asked for
	exactly this kind of in-the-moment legibility, against a system whose state was otherwise
	invisible while it was happening.

	Structurally a sibling of CombatStateBadge.lua: same unfolding pill above the hotbar, same
	height-animated collapse to true zero, same reactive AutomaticSize.X so a hidden badge reserves no
	width and can't push the centered hotbar off-center (that component's header documents the
	in-game bug that rule came from). Deliberately NOT extracted into a shared "UnfoldingPill" yet,
	even though this is the second caller: the two differ in more than content -- this one animates a
	live number and uses the Danger register, that one is static text on the accent -- so the shared
	part is the ~15 lines of collapse mechanics, not the component. A third pill earns the extraction.

	Danger, not the accent (ui-ux-philosophy.md's Critical States rule: color is never the only
	signal). The badge's own presence/absence is the primary cue, the word MARKED is the second, and
	the color is third -- the same layering CombatStateBadge documents for itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local Label = require(script.Parent.Label)
local Inset = require(script.Parent.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type BountyMarkedBadgeProps = {
	Marked: UsedAs<boolean>,
	-- Meridian XP this player's bounty currently pays whoever collects it. nil whenever Marked is
	-- false; the badge is collapsed at that point, so the value is never rendered in that state.
	Reward: UsedAs<number?>,
	LayoutOrder: number?,
}

local BADGE_HEIGHT = 26
local GLYPH_SIZE = 14
local GLYPH_THICKNESS = 3
-- Same reasoning as CombatStateBadge.GAP_TO_NEXT: baked into this badge's own animated height rather
-- than left to the Hotbar's UIListLayout Padding, so it collapses to true zero with the badge
-- instead of leaving a permanent sliver of dead space above the bar.
local GAP_TO_NEXT = Tokens.Space.XS

local UNFOLD_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local UNFOLD_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

-- A ring with a dot at its center -- a crosshair/target silhouette, deliberately distinct from
-- CombatStateBadge's blade and from every VitalIcon glyph, so "you are being hunted" is never
-- mistaken for "you are in combat" (which is also true at the time, and shown right beside it).
local function TargetGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_SIZE),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "Frame" {
				Name = "Ring",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_SIZE),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
					scope:New "UIStroke" { Color = color, Thickness = GLYPH_THICKNESS - 1 },
				},
			},
			scope:New "Frame" {
				Name = "Center",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_THICKNESS, GLYPH_THICKNESS),
				BackgroundColor3 = color,
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" { CornerRadius = UDim.new(1, 0) },
			},
		},
	} :: Frame
end

local function BountyMarkedBadge(scope: Scope, props: BountyMarkedBadgeProps): Frame
	local unfoldTarget = scope:Computed(function(use)
		return if use(props.Marked) then 1 else 0
	end)
	local unfold = scope:Spring(unfoldTarget, UNFOLD_SPRING_SPEED, UNFOLD_SPRING_DAMPING)

	local contentTransparency = scope:Computed(function(use)
		return 1 - use(unfold)
	end)

	-- Falls back to the bare word while a reward hasn't arrived (or has just been cleared mid-
	-- collapse) rather than rendering "MARKED - nil" or a fabricated 0.
	local badgeText = scope:Computed(function(use)
		local reward = use(props.Reward)
		if typeof(reward) ~= "number" then
			return "MARKED"
		end
		return `MARKED  {reward} XP`
	end)

	return scope:New "Frame" {
		Name = "BountyMarkedBadgeSlot",
		LayoutOrder = props.LayoutOrder,
		AutomaticSize = scope:Computed(function(use)
			return if use(props.Marked) then Enum.AutomaticSize.X else Enum.AutomaticSize.None
		end),
		Size = scope:Computed(function(use)
			return UDim2.fromOffset(0, (BADGE_HEIGHT + GAP_TO_NEXT) * use(unfold))
		end),
		BackgroundTransparency = 1,
		ClipsDescendants = true,

		[Children] = Panel(scope, {
			Name = "BountyMarkedBadge",
			Size = UDim2.fromOffset(0, BADGE_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Elevated = true,
			BorderColor3 = Tokens.Color.Danger,
			BorderThickness = 1.5,
			BorderTransparency = contentTransparency,

			Children = {
				Inset(scope, { X = Tokens.Space.S }),
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Tokens.Space.XS),
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				scope:New "Frame" {
					Name = "GlyphSlot",
					LayoutOrder = 1,
					Size = UDim2.fromOffset(GLYPH_SIZE, BADGE_HEIGHT),
					BackgroundTransparency = 1,

					[Children] = TargetGlyph(scope, Tokens.Color.Danger),
				},
				Label(scope, {
					Text = badgeText,
					Scale = "Detail",
					Color = Tokens.Color.TextPrimary,
					TextTransparency = contentTransparency,
					LayoutOrder = 2,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
			},
		}) :: Frame,
	} :: Frame
end

return BountyMarkedBadge
