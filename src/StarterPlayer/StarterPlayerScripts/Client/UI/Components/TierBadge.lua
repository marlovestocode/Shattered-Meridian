--!strict
--[[
	TierBadge.lua

	Owns: the hotbar dock's cultivation module -- the tier numeral on its own bronze plate, the tier's
	name, and a meter showing how far into the current tier the player's Meridian XP has carried them.
	This is the "Level and character information" surface docs/ui-ux-philosophy.md's Player Status
	Display section calls for.

	Renders from ClientState only (Tier/TierName/TierFloorXP/TierNextXP/MeridianXP), never computed or
	guessed here, per that doc's HUD sync rule. The one arithmetic this file does -- XP into the tier
	over the tier's own span -- is presentation over two numbers the server already sent, which
	Types.TierUpdatePayload's own header calls out as the deliberate split: the server owns tier
	IDENTITY, the client fills a bar with it. That is what lets the meter move on every kill instead of
	only when a tier changes.

	BRONZE, NOT VIOLET, and that is the whole reason this module reads as a different KIND of thing to
	the vitals beside it. Tokens.Color's own split is that AccentPrimary means "interactive / live /
	selected" and AccentSecondary means "committed / permanent / already spent" -- and a tier is the
	most committed thing on the dock. It moves a handful of times per account, not per exchange. The
	vitals are violet-edged and change every second; this is bronze and almost never changes, so a
	glance mid-fight can tell the two apart before reading either.

	MAX TIER renders a full meter and the word MAX rather than an empty bar, a hidden one, or a
	fabricated "100%". TierNextXP is nil at the top of the ladder (TierSystem.GetTierWindow's header on
	why nil, not a made-up number), and "full" is the honest read of a tier with nothing left to earn --
	an empty bar would say the opposite of what is true, and hiding the meter would make the badge
	change shape at exactly the moment a player most wants to look at it.

	PROMOTION PULSE follows ParryReadyGlint's split exactly: this component takes a 0..1 intensity and
	eases it, and the CONSUMER owns the one-shot drive (HUD/init.lua observes ClientState.TierPromotion
	and pulses this). Keeping the drive out here means the badge stays a pure "value in, presentation
	out" component with no timers of its own, and the one place that knows a promotion happened is the
	one place ClientState hands that fact to. (Contrast VitalIcon.lua, which DOES own its own damage
	cue -- because "this number just dropped" is visible in its own props, where "this was a promotion
	and not a login sync" is not.)

	FIXED WIDTH, deliberately -- not AutomaticSize.X. Tier names vary in length ("Sealed Vein" vs.
	"Immortal Meridian"), and this module sits inside the dock's own AutomaticSize.XY panel, which is
	anchored dead centre. An auto-sizing badge would resize the whole dock and slide every vital and
	ability slot sideways the instant a player ranked up -- a layout jump at the worst possible moment.
	COLUMN_WIDTH is sized to hold the longest name in TierConstants.Tiers at this file's own type step;
	a longer name truncates (Label.lua's default) rather than widening anything.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local Bar = require(script.Parent.Bar)
local Label = require(script.Parent.Label)
local Stack = require(script.Parent.Stack)

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
	-- 0 = resting, 1 = full promotion flare. One-shot drive owned by the consumer, eased here.
	PromotionPulse: UsedAs<number>,
	LayoutOrder: number?,
}

-- The numeral plate. The tallest thing on the dock by design -- it is the module a player's eye
-- should land on first when they are NOT fighting, which is exactly when they look at their rank.
local PLATE_SIZE = 64
local PLATE_GAP = Tokens.Space.L
-- Sized to hold "IMMORTAL MERIDIAN" at the mono step below without truncating, and to leave the meter
-- row (meter + gap + percent) room on one line. See this file's header on why it is fixed.
local COLUMN_WIDTH = 132
local METER_HEIGHT = 6
local PERCENT_WIDTH = 30
local NAME_HEIGHT = 14

-- The two rivet chips on the plate. This UI's existing corner-accent vocabulary (Components/
-- CornerBracket.lua's own rivet, which is a 45-degree square) at its smallest, on the diagonal only --
-- a full four-corner bracket set on a plate this size reads as busy, and the plate already has a
-- chamfered silhouette carrying the same "forged" language.
local RIVET_SIZE = 3
local RIVET_INSET = 6

-- The meter catches up at the same pace the vitals do -- three meters on one dock moving at three
-- different speeds reads as three unrelated widgets.
local FILL_SPRING_SPEED = Tokens.Motion.FillSpring.Speed
local FILL_SPRING_DAMPING = Tokens.Motion.FillSpring.Damping
local PULSE_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local PULSE_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

-- Tier numerals are Roman -- the "this is a rank in the world" register, deliberately distinct from
-- the Arabic numerals every vital gauge and damage number already uses, so a glance never confuses a
-- tier with a resource amount. Indexed by tier rather than computed: TierConstants.Tiers has nine
-- entries and a general integer-to-Roman routine would be more code than the values it produces.
-- Anything outside the table falls back to the plain number -- a ladder that grows past X still
-- renders something true rather than nothing (and this file is where you would add XI when it does).
local ROMAN_NUMERALS = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

local function romanFor(tier: number): string
	if typeof(tier) ~= "number" or tier ~= tier then
		return "-"
	end
	return ROMAN_NUMERALS[math.floor(tier)] or tostring(math.floor(tier))
end

-- One rivet chip, anchored on the plate's own diagonal.
local function rivet(scope: Scope, corner: Vector2, color: UsedAs<Color3>, transparency: UsedAs<number>): Frame
	local insetX = if corner.X == 0 then RIVET_INSET else -RIVET_INSET
	local insetY = if corner.Y == 0 then RIVET_INSET else -RIVET_INSET
	return scope:New "Frame" {
		Name = "PlateRivet",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(corner.X, insetX, corner.Y, insetY),
		Size = UDim2.fromOffset(RIVET_SIZE, RIVET_SIZE),
		Rotation = 45,
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		ZIndex = 4,
	} :: Frame
end

local function TierBadge(scope: Scope, props: TierBadgeProps): Frame
	-- XP earned INTO the current tier, and the tier's full span. Both clamped so a mid-flight state (a
	-- MeridianXP update that arrives a frame before its matching tier update, which is genuinely
	-- possible -- they are two separate remotes fired back to back) can only ever render a full or
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

	-- Sprung on the way IN to Bar rather than inside it: Bar.lua is the generic primitive and its fill
	-- is deliberately un-animated (a cooldown bar wants no smoothing at all), so smoothing belongs to
	-- the caller that wants it. This is what makes the meter creep on every kill instead of ticking.
	local smoothedValue = scope:Spring(meterValue, FILL_SPRING_SPEED, FILL_SPRING_DAMPING)

	local pulse = scope:Spring(
		scope:Computed(function(use)
			return use(props.PromotionPulse)
		end),
		PULSE_SPRING_SPEED,
		PULSE_SPRING_DAMPING
	)

	-- Everything the flare touches brightens from the same one number, so the plate, the numeral, the
	-- name and the rivets cannot fall out of phase. Accessibility (ui-ux-philosophy.md: never colour
	-- alone) -- the numeral and the name CHANGE at the same moment, which is the primary cue; this is
	-- reinforcement, not the signal.
	local plateColor = scope:Computed(function(use)
		return Tokens.Color.AccentSecondary:Lerp(Tokens.Color.TextPrimary, use(pulse))
	end)
	local plateStrokeTransparency = scope:Computed(function(use)
		return 0.4 - (use(pulse) * 0.4)
	end)
	local rivetTransparency = scope:Computed(function(use)
		return 0.55 - (use(pulse) * 0.55)
	end)

	local isChamfered = ChamferedSurface.IsAvailable()
	local plateChildren: { Instance } = {}

	if isChamfered then
		local fill = ChamferedSurface.Fill(scope, {
			FillColor = Tokens.Color.SurfaceElevated,
			ZIndex = 0,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = plateColor,
			Transparency = plateStrokeTransparency,
			Weight = scope:Computed(function(use)
				return if use(pulse) > 0.5 then "Thick" else "Thin"
			end),
			ZIndex = 3,
		})
		local layers = ChamferedSurface.AllLayers({ fill, stroke })
		if layers then
			plateChildren = layers
		else
			isChamfered = false
		end
	end

	if not isChamfered then
		table.insert(
			plateChildren,
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			}
		)
		table.insert(
			plateChildren,
			scope:New "UIStroke" {
				Color = plateColor,
				Transparency = plateStrokeTransparency,
				Thickness = scope:Computed(function(use)
					return 1 + (use(pulse) * 1.5)
				end),
			}
		)
	end

	table.insert(plateChildren, rivet(scope, Vector2.new(0, 0), plateColor, rivetTransparency))
	table.insert(plateChildren, rivet(scope, Vector2.new(1, 1), plateColor, rivetTransparency))
	table.insert(
		plateChildren,
		Label(scope, {
			Text = scope:Computed(function(use)
				return romanFor(use(props.Tier))
			end),
			-- The display serif, which is this UI's "this is a thing in the world" register -- the one
			-- place on the whole dock that is not mono or sans, because a rank is a proper noun.
			Scale = "Title",
			Color = plateColor,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 2,
		})
	)

	local plate = scope:New "Frame" {
		Name = "TierPlate",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(PLATE_SIZE, PLATE_SIZE),
		BackgroundColor3 = Tokens.Color.SurfaceElevated,
		-- Chamfered mode paints its own fill via an ImageLabel child instead, so this Frame's own
		-- background must stay fully transparent -- otherwise its plain rectangular corners would show
		-- through underneath the chamfered silhouette's cut corners.
		BackgroundTransparency = if isChamfered then 1 else 0,
		BorderSizePixel = 0,

		[Children] = plateChildren,
	} :: Frame

	local percentText = scope:Computed(function(use)
		if use(props.TierNextXP) == nil then
			-- Not "100%": the meter is full because there is no next tier, not because this one is
			-- nearly done. Saying MAX is the only reading of that which is actually true.
			return "MAX"
		end
		return string.format("%d%%", math.floor(use(meterValue) / use(meterMax) * 100))
	end)

	local column = Stack.New(scope, {
		Name = "TierReadout",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(COLUMN_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.S,
		AlignX = Enum.HorizontalAlignment.Left,

		Children = {
			Label(scope, {
				-- Uppercased here rather than expecting TierConstants to shout: casing is presentation,
				-- and the same name renders in sentence case in the character menu's identity rail.
				Text = scope:Computed(function(use)
					return use(props.TierName):upper()
				end),
				-- Mono caps, like every other small chrome token on this dock. Deliberately NOT one of
				-- Tokens.Type's tracked caps steps: those belong to Components/TrackedLabel.lua, whose
				-- Text cannot be reactive -- and this one has to change when a player is promoted.
				Scale = "NumeralSmall",
				Color = scope:Computed(function(use)
					return Tokens.Color.AccentSecondary:Lerp(Tokens.Color.TextPrimary, use(pulse))
				end),
				Size = UDim2.new(1, 0, 0, NAME_HEIGHT),
				LayoutOrder = 1,
			}),
			Stack.Row(scope, {
				Name = "MeterRow",
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, METER_HEIGHT),
				Gap = Tokens.Space.S,
				AlignY = Enum.VerticalAlignment.Center,

				Children = {
					-- No CriticalBelow: an early-tier meter is not a warning state. Low Health means
					-- danger; low progress into a tier just means "recently promoted", and colouring it
					-- Danger would teach the player to read their own advancement as a problem.
					Bar(scope, {
						Value = smoothedValue,
						Max = meterMax,
						Size = UDim2.new(1, -(PERCENT_WIDTH + Tokens.Space.S), 0, METER_HEIGHT),
						FillColor = Tokens.Color.AccentSecondary,
						-- Same hue at both stops, which is what Bar's own header says reproduces the
						-- design's single-hue alpha ramp rather than blending two colours.
						FillColorSecondary = Tokens.Color.AccentSecondary,
						Glow = true,
						LayoutOrder = 1,
					}),
					Label(scope, {
						Text = percentText,
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextDisabled,
						Size = UDim2.fromOffset(PERCENT_WIDTH, METER_HEIGHT + 6),
						TextXAlignment = Enum.TextXAlignment.Right,
						LayoutOrder = 2,
					}),
				},
			}),
		},
	})

	return Stack.Row(scope, {
		Name = "TierBadge",
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(PLATE_SIZE + PLATE_GAP + COLUMN_WIDTH, PLATE_SIZE),
		Gap = PLATE_GAP,
		AlignY = Enum.VerticalAlignment.Center,

		Children = { plate, column },
	})
end

return TierBadge
