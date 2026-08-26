--!strict
--[[
	WheelDial.lua

	Owns: the emote wheel's INSTRUMENT -- everything drawn on the circle itself rather than on a slot:
	the dark glass disc the wheel sits on, its rim, the graduation ladder around that rim, and the
	needle that tracks the player's cursor. WheelSegment.lua draws the slots; this draws the thing the
	slots sit on.

	WHY A GRADUATED DIAL AND NOT A PIE OF WEDGES. A filled wedge per sector is what most radial menus
	do, and Roblox cannot draw one: there is no vector path primitive, so a wedge means an uploaded
	image per segment count, which is an asset pipeline this feature does not have (and which would
	silently break the moment EmoteConstants.LoadoutSize changes -- see that constant's own header).
	A tick ladder needs no assets, reads as "a precise combat interface built from ancient knowledge"
	(docs/ui-ux-philosophy.md's Core Identity) rather than as a phone app's colour wheel, and -- the
	part that actually matters -- it stays correct at ANY segment count, because each tick resolves
	its own sector through the same nearest-centre rule WheelSelection.GetSelectedIndex resolves the
	cursor through. The lit band is therefore not an approximation of the selectable sector; it IS the
	selectable sector, drawn.

	COST, AND WHY THE COUNT IS A CONSTANT. The ladder is a fixed number of marks regardless of how
	many emotes are in the loadout -- a compass rose, not a per-slot decoration. That is what keeps the
	instance count fixed (built once at mount, never rebuilt when the loadout length changes) and what
	lets 8, 12, 6, 4 and 3 segments all land their sector seams exactly on a mark, which is the real
	constraint on the number: it has to be divisible by every segment count the wheel supports.

	IT WAS 72 (one mark every 5 degrees) AND IS NOW 24 (one every 15), because 72 rotated,
	semi-transparent Frames turned out to be the wheel's dominant render cost while it is open -- and
	they are composited through the CanvasGroup in init.lua, so every one of them is paid for twice.
	Players reported the frame drop; the owner's call (2026-08-26) was to thin the ladder rather than
	give up the entrance the CanvasGroup buys.

	NOTHING THE PARAGRAPH ABOVE PROMISES WAS GIVEN UP TO DO IT. 24 is still divisible by 3, 4, 6, 8 and
	12, so all five supported segment counts still land their seams exactly on a mark -- the property
	72 was chosen for is a property of divisibility, not of density, and 24 is simply the smallest
	number that still has it. What IS given up is visual density: the ladder reads as a coarser
	instrument up close. TICK_COUNT is one constant and any multiple of 12 (24, 36, 48, 72) restores
	as much of that as you want to pay for.

	Each mark carries three Computeds reading only (SelectedIndex, SegmentCount), so a sector change
	now costs ~72 trivial re-evaluations rather than ~216, and an idle frame still costs exactly zero
	-- the same "the alive cue costs nothing at rest" property Screens/HUD/init.lua's own header sets
	as the bar for this UI.

	THE NEEDLE IS THE ONLY THING HERE THAT MOVES PER FRAME, and it is one Instance: a 0-size pivot
	Frame whose Rotation is a spring chasing the live cursor angle, with the beam parented under it.
	It is fed an UNWRAPPED angle (WheelSelection.UnwrapAngle, applied by EmoteWheelClient.lua before
	the value ever reaches this module) precisely because a spring would otherwise sweep the long way
	round the circle every time the cursor crosses 12 o'clock -- see that function's own header.

	Does not own: any slot tile (WheelSegment.lua), the centre readout (WheelHub.lua), the layout
	radii (init.lua owns those numbers and passes them in), or any input/selection decision
	(EmoteWheelClient.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Glow = require(script.Parent.Parent.Parent.Components.Glow)
local WheelSelection = require(script.Parent.WheelSelection)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type WheelDialProps = {
	-- The live loadout length, never EmoteConstants.LoadoutSize -- see WheelSelection.lua's header.
	SegmentCount: UsedAs<number>,
	SelectedIndex: UsedAs<number?>,
	-- Radians, clockwise from "up", ALREADY unwrapped by the caller (may sit far outside [0, TAU)).
	CursorAngle: UsedAs<number>,
	-- 0 closed, 1 open. Drives the graduation's entrance sweep only; the whole screen's fade/scale is
	-- init.lua's, not this module's.
	OpenProgress: UsedAs<number>,
	RimRadius: number,
	HubRadius: number,
	ZIndex: number?,
}

-- One mark every 15 degrees. See this file's header for why this is a constant rather than a
-- multiple of the segment count, why it came down from 72, and why 24 is the smallest value that
-- keeps every seam landing on a mark.
local TICK_COUNT = 24

local TICK_WIDTH = 2
-- Distance from the rim inward to where every mark's OUTER end sits. Marks are anchored at that outer
-- end and grow inward, so a lengthening mark keeps the ladder's outer edge perfectly flush -- which
-- is the difference between a machined dial and a ring of loose dashes.
local TICK_RIM_INSET = 5
local TICK_LENGTH_MINOR = 7
local TICK_LENGTH_MAJOR = 15
local TICK_LENGTH_MINOR_LIT = 13
local TICK_LENGTH_MAJOR_LIT = 20

local TICK_TRANSPARENCY_MINOR = 0.72
local TICK_TRANSPARENCY_MAJOR = 0.45
local TICK_TRANSPARENCY_LIT = 0.15

-- How far the graduation is rotated back at rest, unwinding to 0 as the wheel opens -- the
-- "mechanical unfolding" docs/ui-ux-philosophy.md's Animation Philosophy names, and the only reason
-- a perfectly circular ring can be seen to animate at all.
local ENTRY_SWEEP_DEGREES = 9

local NEEDLE_WIDTH = 3
-- The needle's own fade-in/out when a selection appears/disappears. Its own spring rather than the
-- open spring: the needle comes and goes while the wheel is already open (the player passing back
-- through the hub's dead zone), which has nothing to do with the screen entering.
local NEEDLE_FADE_SPEED = 22
local NEEDLE_FADE_DAMPING = 1
local NEEDLE_GRADIENT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.35),
	NumberSequenceKeypoint.new(0.6, 0.72),
	NumberSequenceKeypoint.new(1, 1),
})

local DISC_TRANSPARENCY = 0.42
local DISC_SHEEN = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.55),
	NumberSequenceKeypoint.new(1, 0),
})

local function centered(offset: Vector2): UDim2
	return UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(offset.X, offset.Y)
end

export type RingFill = { Color: Color3, Transparency: number }

-- A circle: a square Frame whose UICorner radius is half its own side. Used for both the disc and the
-- hub's dead-zone boundary, which are the same shape at different sizes and weights.
local function ring(
	scope: Scope,
	name: string,
	radius: number,
	zIndex: number,
	stroke: Tokens.Tint,
	fill: RingFill?
): Frame
	local ringChildren: { Instance } = {
		scope:New "UICorner" { CornerRadius = UDim.new(0.5, 0) },
		scope:New "UIStroke" {
			Color = stroke.Color,
			Transparency = stroke.Transparency,
			Thickness = 1,
		},
	}

	if fill then
		table.insert(
			ringChildren,
			scope:New "UIGradient" {
				Rotation = 90,
				Transparency = DISC_SHEEN,
				Color = ColorSequence.new(Tokens.Color.SurfaceElevated, Tokens.Color.Background),
			}
		)
	end

	return scope:New "Frame" {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(radius * 2, radius * 2),
		BackgroundColor3 = if fill then fill.Color else Tokens.Color.Background,
		BackgroundTransparency = if fill then fill.Transparency else 1,
		BorderSizePixel = 0,
		ZIndex = zIndex,

		[Children] = ringChildren,
	} :: Frame
end

local function WheelDial(scope: Scope, props: WheelDialProps): Frame
	local rimRadius = props.RimRadius
	local hubRadius = props.HubRadius

	local ticks: { Instance } = {}
	for index = 1, TICK_COUNT do
		local angle = (index - 1) * (WheelSelection.TAU / TICK_COUNT)
		local direction = Vector2.new(math.sin(angle), -math.cos(angle))
		local anchorOffset = direction * (rimRadius - TICK_RIM_INSET)

		local isMajor = scope:Computed(function(use)
			local count = use(props.SegmentCount)
			if count <= 0 then
				return false
			end
			-- A boundary mark is the one nearest each seam between two sectors. Measured against half
			-- a mark's spacing so exactly one mark claims each seam at any segment count, including
			-- the counts whose seams do not land on a mark at all.
			local anglePerSegment = WheelSelection.TAU / count
			local offsetFromSeam = (angle + anglePerSegment * 0.5) % anglePerSegment
			local distance = math.min(offsetFromSeam, anglePerSegment - offsetFromSeam)
			return distance < (WheelSelection.TAU / TICK_COUNT) * 0.5
		end)

		local isLit = scope:Computed(function(use)
			local selected = use(props.SelectedIndex)
			if not selected then
				return false
			end
			local count = use(props.SegmentCount)
			if count <= 0 then
				return false
			end
			local anglePerSegment = WheelSelection.TAU / count
			local sector = math.floor(angle / anglePerSegment + 0.5) % count + 1
			return sector == selected
		end)

		table.insert(
			ticks,
			scope:New "Frame" {
				Name = "Tick" .. index,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = centered(anchorOffset),
				Rotation = math.deg(angle),
				BorderSizePixel = 0,

				Size = scope:Computed(function(use)
					local major = use(isMajor)
					local lit = use(isLit)
					local length = if lit
						then (if major then TICK_LENGTH_MAJOR_LIT else TICK_LENGTH_MINOR_LIT)
						else (if major then TICK_LENGTH_MAJOR else TICK_LENGTH_MINOR)
					return UDim2.fromOffset(TICK_WIDTH, length)
				end),

				BackgroundColor3 = scope:Computed(function(use)
					if use(isLit) then
						return Tokens.Color.AccentPrimaryBright
					end
					return if use(isMajor) then Tokens.Color.AccentSecondary else Tokens.Border.Standard.Color
				end),

				BackgroundTransparency = scope:Computed(function(use)
					if use(isLit) then
						return TICK_TRANSPARENCY_LIT
					end
					return if use(isMajor) then TICK_TRANSPARENCY_MAJOR else TICK_TRANSPARENCY_MINOR
				end),
			}
		)
	end

	local needleFade = scope:Spring(
		scope:Computed(function(use)
			return if use(props.SelectedIndex) then 1 else 0
		end),
		NEEDLE_FADE_SPEED,
		NEEDLE_FADE_DAMPING
	)

	local needleRotation = scope:Spring(
		scope:Computed(function(use)
			return math.deg(use(props.CursorAngle))
		end),
		Tokens.Motion.FollowSpring.Speed,
		Tokens.Motion.FollowSpring.Damping
	)

	local sweep = scope:Computed(function(use)
		return (use(props.OpenProgress) - 1) * ENTRY_SWEEP_DEGREES
	end)

	local needleTransparency = scope:Computed(function(use)
		return 1 - use(needleFade)
	end)

	return scope:New "Frame" {
		Name = "WheelDial",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		ZIndex = props.ZIndex or 1,

		[Children] = {
			-- The atmospheric halo the philosophy's "subtle atmospheric glow" asks for. Concentric
			-- strokes, not a blur (Roblox has neither) -- Components/Glow.lua is this UI's one
			-- sanctioned substitute, and it takes a circular corner radius happily.
			Glow(scope, {
				Color = Tokens.Color.AccentPrimary,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(rimRadius * 2, rimRadius * 2),
				CornerRadius = UDim.new(0.5, 0),
				Rings = 5,
				Spread = 26,
				Transparency = 0.86,
				ZIndex = 0,
			}),

			ring(scope, "Disc", rimRadius, 1, Tokens.Border.Standard, {
				Color = Tokens.Color.Background,
				Transparency = DISC_TRANSPARENCY,
			}),

			-- The dead-zone boundary, drawn. The radius here and the radius EmoteWheelClient.lua
			-- refuses to select inside are the same number (init.lua owns it and hands it to both), so
			-- the affordance and the behaviour cannot drift -- see WheelSelection.lua's dead-zone
			-- header.
			ring(scope, "HubBoundary", hubRadius, 2, Tokens.Border.Hairline, nil),

			scope:New "Frame" {
				Name = "NeedlePivot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(0, 0),
				BackgroundTransparency = 1,
				Rotation = needleRotation,
				ZIndex = 3,

				[Children] = scope:New "Frame" {
					Name = "Needle",
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.fromOffset(0, -hubRadius),
					Size = UDim2.fromOffset(NEEDLE_WIDTH, rimRadius - hubRadius),
					BackgroundColor3 = Tokens.Color.AccentPrimaryBright,
					BackgroundTransparency = needleTransparency,
					BorderSizePixel = 0,

					[Children] = scope:New "UIGradient" {
						Rotation = 90,
						Transparency = NEEDLE_GRADIENT,
					},
				},
			},

			scope:New "Frame" {
				Name = "Graduation",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(0, 0),
				BackgroundTransparency = 1,
				Rotation = sweep,
				ZIndex = 4,

				[Children] = ticks,
			},
		},
	} :: Frame
end

return WheelDial
