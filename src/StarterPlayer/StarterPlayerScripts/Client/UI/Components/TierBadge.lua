--!strict
--[[
	TierBadge.lua

	Owns: the hotbar's tier readout -- the numeral, the tier's name, and a thin meter showing how far
	into the current tier the player's Meridian XP has carried them. This is the "Level and character
	information" surface docs/ui-ux-philosophy.md's Player Status Display section listed under "Not
	built yet, and why: TierSystem/PlayerDataSystem are still empty Init()s, so there's no real
	tier/name to show yet." TierSystem now exists and replicates both, so the reason that entry gave
	for its own absence no longer holds -- update that doc's status list rather than leaving it
	claiming this can't be built.

	Renders from ClientState only (Tier/TierName/TierFloorXP/TierNextXP/MeridianXP), never computed
	or guessed here, per that doc's HUD sync rule. The one arithmetic this file does -- XP into the
	tier over the tier's own span -- is presentation over two numbers the server already sent, which
	Types.TierUpdatePayload's own header calls out as the deliberate split: the server owns tier
	IDENTITY, the client fills a bar with it. That is what lets the meter move on every kill instead
	of only when a tier changes.

	MAX TIER renders a full, static meter rather than an empty one or a hidden one. TierNextXP is nil
	at the top of the ladder (TierSystem.GetTierWindow's header on why nil, not a fabricated number),
	and "full" is the honest read of a tier with nothing left to earn -- an empty bar would say the
	opposite of what's true, and hiding the meter would make the badge change shape at exactly the
	moment a player most wants to look at it.

	PROMOTION PULSE follows ParryReadyGlint's split exactly: this component takes a 0..1 intensity
	and eases it, and the CONSUMER owns the one-shot drive (HUD/init.lua observes
	ClientState.TierPromotion and pulses this). Keeping the drive out here means the badge stays a
	pure "value in, presentation out" component with no timers of its own, and the one place that
	knows a promotion happened is the one place ClientState hands that fact to.

	FIXED WIDTH, deliberately -- not AutomaticSize.X. Tier names vary in length ("Sealed Vein" vs.
	"Immortal Meridian"), and this badge sits inside the Hotbar's own AutomaticSize.XY panel, which is
	anchored dead center. An auto-sizing badge would resize the whole hotbar and slide every vital and
	ability slot sideways the instant a player ranked up -- the exact class of layout jump
	CombatStateBadge.lua's own header already documents fighting (its reactive AutomaticSize.X exists
	because unconditional auto-width made the hotbar render off-center).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)
local Label = require(script.Parent.Label)
local Bar = require(script.Parent.Bar)
local VitalIcon = require(script.Parent.VitalIcon)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type TierBadgeProps = {
	Tier: UsedAs<number>,
	TierName: UsedAs<string>,
	-- Cumulative XP at which this tier began, and at which the next begins -- nil for TierNextXP at
	-- the top of the ladder (see this file's header on how that renders).
	TierFloorXP: UsedAs<number>,
	TierNextXP: UsedAs<number?>,
	MeridianXP: UsedAs<number>,
	-- 0 = resting, 1 = full promotion flare. One-shot drive owned by the consumer, eased here --
	-- same split ParryReadyGlint.lua uses for its own one-shot cue.
	PromotionPulse: UsedAs<number>,
	LayoutOrder: number?,
}

-- Matches VitalIcon.TILE_SIZE exactly rather than restating 52 -- this badge sits on the same row as
-- the vitals tiles and has to share their height, so it reads off the real constant the same way
-- HUD/init.lua's own Divider does.
local BADGE_HEIGHT = VitalIcon.TILE_SIZE
-- Sized to hold the longest name in TierConstants.Tiers ("Immortal Meridian") at the Detail scale
-- without truncating. A name longer than that truncates rather than resizing the badge -- see this
-- file's header on why the width is fixed, and prefer a shorter tier name over widening this.
local BADGE_WIDTH = 112
local METER_HEIGHT = 3

-- Reuses the vitals' own fill spring so the tier meter catches up at the same pace the Health/Qi/
-- Posture gauges do -- three meters on one bar moving at three different speeds reads as three
-- unrelated widgets.
local PULSE_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local PULSE_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

-- Tier numerals are Roman -- the "this is a rank in the world" register, deliberately distinct from
-- the Arabic numerals every vital gauge and damage number already uses, so a glance never confuses
-- a tier with a resource amount. Indexed by tier rather than computed: TierConstants.Tiers has nine
-- entries and a general integer-to-Roman routine would be more code than the values it produces.
-- Anything outside the table falls back to the plain number -- a ladder that grows past X still
-- renders something true rather than nothing (and this file is where you'd add XI when it does).
local ROMAN_NUMERALS = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

local function romanFor(tier: number): string
	if typeof(tier) ~= "number" or tier ~= tier then
		return "-"
	end
	return ROMAN_NUMERALS[math.floor(tier)] or tostring(math.floor(tier))
end

local function TierBadge(scope: Scope, props: TierBadgeProps): Frame
	-- XP earned INTO the current tier, and the tier's full span. Both clamped so a mid-flight state
	-- (a MeridianXP update that arrives a frame before its matching tier update, which is genuinely
	-- possible -- they're two separate remotes fired back to back) can only ever render a full or
	-- empty bar, never a negative fill or one past 100%.
	local meterValue = scope:Computed(function(use)
		local nextXp = use(props.TierNextXP)
		if nextXp == nil then
			return 1
		end
		local span = nextXp - use(props.TierFloorXP)
		if span <= 0 then
			return 1
		end
		return math.clamp(use(props.MeridianXP) - use(props.TierFloorXP), 0, span)
	end)

	local meterMax = scope:Computed(function(use)
		local nextXp = use(props.TierNextXP)
		if nextXp == nil then
			return 1
		end
		local span = nextXp - use(props.TierFloorXP)
		return if span > 0 then span else 1
	end)

	local pulse = scope:Spring(
		scope:Computed(function(use)
			return use(props.PromotionPulse)
		end),
		PULSE_SPRING_SPEED,
		PULSE_SPRING_DAMPING
	)

	-- The flare is carried by the badge's own border brightening and thickening, not by a new overlay
	-- instance: a Panel gets exactly one UIStroke (Panel.lua's own header), and driving the one it
	-- already has costs nothing at rest. Accessibility (ui-ux-philosophy.md: never color alone) --
	-- the numeral and name change at the same moment, which is the primary cue; this is reinforcement.
	local borderColor = scope:Computed(function(use)
		return Tokens.Color.AccentPrimary:Lerp(Tokens.Color.AccentPrimaryBright, use(pulse))
	end)
	local borderThickness = scope:Computed(function(use)
		return 1 + (use(pulse) * 1.5)
	end)
	local borderTransparency = scope:Computed(function(use)
		return 0.3 - (use(pulse) * 0.3)
	end)

	return Panel(scope, {
		Name = "TierBadge",
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(BADGE_WIDTH, BADGE_HEIGHT),
		Elevated = true,
		BorderColor3 = borderColor,
		BorderThickness = borderThickness,
		BorderTransparency = borderTransparency,

		Children = {
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.S),
				PaddingTop = UDim.new(0, Tokens.Space.XS),
				PaddingBottom = UDim.new(0, Tokens.Space.XS),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 1),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			-- Numeral and name on one row: the numeral is the compact identity, the name is what
			-- makes it mean something. Neither alone is enough -- "VI" says nothing to a new player
			-- and "Radiant Circuit" doesn't say how far up the ladder it sits.
			scope:New "Frame" {
				Name = "Identity",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 20),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Bottom,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Label(scope, {
						Text = scope:Computed(function(use)
							return romanFor(use(props.Tier))
						end),
						Scale = "NumeralLarge",
						Color = scope:Computed(function(use)
							return Tokens.Color.TextPrimary:Lerp(Tokens.Color.AccentPrimaryBright, use(pulse))
						end),
						LayoutOrder = 1,
					}),
					Label(scope, {
						-- TIER, not the tier's own name -- the word that tells a player what the
						-- numeral beside it counts. The name gets its own line below, where it has
						-- room to be read.
						Text = "TIER",
						Scale = "Detail",
						Color = Tokens.Color.TextDisabled,
						LayoutOrder = 2,
					}),
				},
			},

			Label(scope, {
				Text = props.TierName,
				Scale = "Detail",
				Color = scope:Computed(function(use)
					return Tokens.Color.TextSecondary:Lerp(Tokens.Color.AccentPrimaryBright, use(pulse))
				end),
				Size = UDim2.new(1, 0, 0, 12),
				LayoutOrder = 2,
			}),

			-- No CriticalBelow: an early-tier meter is not a warning state. Low Health means danger;
			-- low progress into a tier just means "recently promoted," and coloring it Danger would
			-- teach the player to read their own advancement as a problem.
			Bar(scope, {
				Value = meterValue,
				Max = meterMax,
				Size = UDim2.new(1, 0, 0, METER_HEIGHT),
				FillColor = Tokens.Color.AccentPrimary,
				FillColorSecondary = Tokens.Color.AccentPrimary,
				LayoutOrder = 3,
			}),
		},
	}) :: Frame
end

return TierBadge
