--!strict
--[[
	CombatStateBadge.lua

	Owns: the HUD's visual indicator for CombatState.inCombatUntil (see that field's own header in
	Server/Combat/CombatTypes.lua) -- the first real consumer of what was, until now, a purely
	read-only server-side signal nothing rendered or gated on. Renders from ClientState.InCombat
	only, which Bootstrap() wires to the server's Combat_InCombatChanged remote (fire-on-transition,
	same shape as ComboStateChanged) -- never computed here, per ui-ux-philosophy.md's HUD sync rule.

	Visual approach: a compact pill above the hotbar that mechanically unfolds into view the instant
	combat starts and folds back away the instant it ends, rather than a color swap on an
	always-present element -- docs/ui-ux-philosophy.md's Animation Philosophy lists "mechanical
	unfolding" as preferred motion, and this is a genuinely optional, event-driven presence (unlike
	Health/Posture, which are always meaningful). Height (not the Visible property) is what's
	animated so the collapse itself reads as the "controlled entrance/exit" the doc's Notification
	Design section calls for, without relying on UIListLayout's undocumented handling of
	Visible = false children.

	Accessibility (ui-ux-philosophy.md's Accessibility section: never color alone): the badge's
	own existence/absence is the primary cue, backed by a distinct glyph silhouette (a blade, not
	reused from any vital's Cross/Spark/Diamond/Ring) and the unfold/fold motion -- color is a third,
	reinforcing signal, not the only one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type CombatStateBadgeProps = {
	InCombat: UsedAs<boolean>,
	LayoutOrder: number?,
}

local BADGE_HEIGHT = 26
local GLYPH_SIZE = 14
local GLYPH_THICKNESS = 3
-- The gap this badge leaves before the next item in the Hotbar's own vertical UIListLayout
-- (HUD/init.lua) -- baked in here, not left to that UIListLayout's own Padding, specifically so it
-- collapses to true zero together with the badge's height when folded. UIListLayout applies its
-- Padding BETWEEN list items regardless of either item's actual size, so a Padding-based gap alone
-- left a fixed sliver of dead space above the bar row even at Size.Y = 0 (2026-07-24 in-game
-- screenshot review: "more open space at top than bottom" of the vitals row) -- HUD/init.lua's own
-- list Padding is 0 for this reason; this is the only source of that gap now.
local GAP_TO_NEXT = Tokens.Space.XS

-- Unfold/fold spring -- reuses the same "controlled entrance" preset StatusBanner/
-- PostureBreakBanner already use for their own one-shot fade-ins, so this reads as the same family
-- of motion rather than a one-off timing.
local UNFOLD_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local UNFOLD_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

-- A single blade silhouette (a diagonal bar with a short crossguard near one end) -- reads as
-- "combat" without needing an image asset, and is deliberately not the Cross/Spark/Diamond/Ring
-- glyphs VitalIcon.lua already owns, so this badge is never mistaken for a fifth vital.
local function BladeGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_SIZE),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "Frame" {
				Name = "Edge",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_THICKNESS, GLYPH_SIZE),
				Rotation = 45,
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			},
			scope:New "Frame" {
				Name = "Guard",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.32, 0.68),
				Rotation = 45,
				Size = UDim2.fromOffset(GLYPH_SIZE * 0.45, GLYPH_THICKNESS),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			},
		},
	} :: Frame
end

local function CombatStateBadge(scope: Scope, props: CombatStateBadgeProps): Frame
	-- The real, unsmoothed boolean -- nothing gameplay-decision-relevant reads this badge, but it's
	-- kept separate from the decorative spring below anyway so the two concerns (what's true vs. how
	-- it's presented) never get tangled, matching every other meter in this framework.
	local unfoldTarget = scope:Computed(function(use)
		return if use(props.InCombat) then 1 else 0
	end)
	local unfold = scope:Spring(unfoldTarget, UNFOLD_SPRING_SPEED, UNFOLD_SPRING_DAMPING)

	local contentTransparency = scope:Computed(function(use)
		return 1 - use(unfold)
	end)

	return scope:New "Frame" {
		Name = "CombatStateBadgeSlot",
		LayoutOrder = props.LayoutOrder,
		-- Reactive, not a plain Enum.AutomaticSize.X -- gated on the real props.InCombat boolean
		-- (not the smoothed `unfold` spring) so this reserves zero width in the Hotbar's own
		-- AutomaticSize.XY layout the instant combat ends, not just zero height. AutomaticSize.X
		-- unconditionally reserving the full "IN COMBAT" pill's width even while folded away
		-- (height 0, ClipsDescendants-hidden) was a pre-existing bug this file's own header missed --
		-- it only ever designed HEIGHT as the animated dimension, but width was silently along for
		-- the ride the whole time, which is what made the Hotbar panel auto-size wider than its own
		-- visible bar content and look off-center (2026-07-24 in-game screenshot review). Gating on
		-- the raw boolean rather than the spring means width snaps rather than smoothly animates,
		-- which matches the header's original intent exactly -- it never claimed width should
		-- animate, only height.
		AutomaticSize = scope:Computed(function(use)
			return if use(props.InCombat) then Enum.AutomaticSize.X else Enum.AutomaticSize.None
		end),
		-- (BADGE_HEIGHT + GAP_TO_NEXT), not just BADGE_HEIGHT -- see GAP_TO_NEXT's own header. The
		-- Panel below stays a fixed BADGE_HEIGHT tall and top-anchored within this slot (no
		-- AnchorPoint/Position override), so the extra GAP_TO_NEXT naturally renders as blank space
		-- below the pill, not as a shift of the pill itself.
		Size = scope:Computed(function(use)
			return UDim2.fromOffset(0, (BADGE_HEIGHT + GAP_TO_NEXT) * use(unfold))
		end),
		BackgroundTransparency = 1,
		ClipsDescendants = true,

		[Children] = Panel(scope, {
			Name = "CombatStateBadge",
			Size = UDim2.fromOffset(0, BADGE_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Elevated = true,
			BorderColor3 = Tokens.Color.AccentPrimary,
			BorderThickness = 1.5,
			BorderTransparency = contentTransparency,

			Children = {
				scope:New "UIPadding" {
					PaddingLeft = UDim.new(0, Tokens.Space.S),
					PaddingRight = UDim.new(0, Tokens.Space.S),
				},
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

					[Children] = BladeGlyph(scope, Tokens.Color.AccentPrimary),
				},
				Label(scope, {
					Text = "IN COMBAT",
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

return CombatStateBadge
