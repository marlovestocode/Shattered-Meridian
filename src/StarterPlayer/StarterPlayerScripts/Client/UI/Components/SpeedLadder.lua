--!strict
--[[
	SpeedLadder.lua

	Owns: the engine telegraph readout -- one rung per entry in BlimpConstants.SpeedStates, drawn as a
	horizontal run of blocks with the currently-commanded rung lit and named, plus a live needle
	showing where the ship's ACTUAL speed has got to relative to that command.

	WHY NOT Components/SegmentMeter.lua, WHICH IS ALSO A RUN OF BLOCKS. That component answers "how far
	along a ladder am I" for a ladder with a bottom and a top and no meaningful middle -- tier progress.
	This one has a middle that is the most important rung on it (All Stop), rungs on BOTH sides of it
	that mean opposite directions of travel, one lit rung rather than a filled prefix, and a second,
	continuous quantity overlaid on the same track. Fill-to-here and select-one-of are different
	readouts that happen to share a silhouette, and SegmentMeter's own header already declines the
	inverse case for the same reason.

	THE COMMANDED RUNG AND THE ACTUAL SPEED ARE DRAWN TOGETHER, ON PURPOSE, AND THAT IS THE WHOLE
	POINT OF THE COMPONENT. A blimp takes about two and a half seconds to answer a rung and far longer
	to shed the speed again; a gauge that showed only the command would be a readout of what the pilot
	pressed, which they already know, and a gauge that showed only the speed would never explain why it
	was changing. The gap between the lit block and the needle IS the ship's mass, made visible -- it is
	the one place a pilot can watch the lag they are flying through instead of just feeling it.

	ASTERN RUNGS ARE TINTED DIFFERENTLY FROM AHEAD RUNGS, and that is a legibility requirement rather
	than decoration: a ladder whose two halves look identical asks a pilot to count blocks from the
	middle to work out which way their ship is about to go, at exactly the moment they are least able
	to. The rung's own LABEL (handed in by the caller, straight off the server's snapshot) is the
	non-color cue docs/ui-ux-philosophy.md's Critical States rule requires -- color is third here, as
	it is everywhere else in this codebase.

	Does not own: the rungs themselves (Shared/Blimp/BlimpConstants.SpeedStates, read through
	Shared/Blimp/BlimpSpeedLadder.lua so this component and the server agree on the count), which rung
	is commanded (the server -- Screens/BlimpHelm/init.lua relays it), or what the ship is actually
	doing (measured locally off the hull's own physics -- see Client/Camera/BlimpCamera.GetMotion).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BlimpSpeedLadder = require(ReplicatedStorage.Shared.Blimp.BlimpSpeedLadder)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type SpeedLadderProps = {
	-- 1-based, straight off BlimpTypes.HelmUpdatedPayload.SpeedIndex.
	CommandedIndex: UsedAs<number>,
	-- The rung's own word, also straight off the payload -- never re-derived from the index here, so
	-- a hull with a bespoke ladder cannot end up labelled with a rung this client guessed.
	CommandedLabel: UsedAs<string>,
	-- The hull's real forward speed as a signed fraction of cruise, -1..1. Drives the needle only.
	ActualFraction: UsedAs<number>,
	-- Dimmed and captioned differently when the local player is a passenger rather than the pilot.
	Interactive: UsedAs<boolean>,
	LayoutOrder: number?,
}

-- Sized for a corner console rather than for a full panel -- see Components/KeyHint.lua's own note
-- on why every metric on this surface is the smallest that still reads.
local RUNG_GAP = 2
local TRACK_HEIGHT = 8
local NEEDLE_WIDTH = 2
local HEIGHT = 28

-- Resolved once at module load, not per render: the ladder cannot change length at runtime, and this
-- is the count every geometry expression below divides by.
local RUNG_COUNT = BlimpSpeedLadder.Count()
local NEUTRAL_INDEX = BlimpSpeedLadder.NeutralIndex()

local function SpeedLadder(scope: Scope, props: SpeedLadderProps): Frame
	local rungs: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, RUNG_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		},
	}

	for index = 1, RUNG_COUNT do
		local rung = BlimpSpeedLadder.At(index)
		-- The three registers this palette already has for exactly this distinction: astern is the
		-- "something is happening you should look at" color, All Stop is neutral chrome, ahead is the
		-- bronze "committed" accent SegmentMeter's own filled blocks use.
		local litColor = if rung.Throttle < 0
			then Tokens.Color.Danger
			elseif index == NEUTRAL_INDEX then Tokens.Color.TextSecondary
			else Tokens.Color.AccentSecondary

		local isLit = scope:Computed(function(use)
			return use(props.CommandedIndex) == index
		end)

		table.insert(
			rungs,
			scope:New "Frame" {
				Name = `Rung_{rung.Id}`,
				LayoutOrder = index,
				-- Each rung takes an equal share of the track minus the gaps between them. Written as
				-- a scale so the ladder survives being dropped into a panel of any width, and computed
				-- against RUNG_COUNT rather than a hardcoded eighth so adding a rung to the constants
				-- table needs no change here.
				Size = UDim2.new(1 / RUNG_COUNT, -RUNG_GAP, 0, TRACK_HEIGHT),
				BackgroundColor3 = litColor,
				BackgroundTransparency = scope:Computed(function(use)
					if not use(props.Interactive) then
						return if use(isLit) then 0.45 else 0.88
					end
					-- An unlit rung is still drawn, faintly: the ladder has to read as a ladder with
					-- one rung chosen, not as a single floating block whose position means nothing.
					return if use(isLit) then 0 else 0.82
				end),
				BorderSizePixel = 0,

				[Children] = {
					scope:New "UICorner" { CornerRadius = UDim.new(0, 2) },
				},
			}
		)
	end

	return scope:New "Frame" {
		Name = "SpeedLadder",
		Size = UDim2.new(1, 0, 0, HEIGHT),
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			scope:New "Frame" {
				Name = "Track",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, TRACK_HEIGHT),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "Frame" {
						Name = "Rungs",
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						[Children] = rungs,
					},

					-- The needle. A sibling of the rung run rather than a child of it, because a
					-- UIListLayout positions EVERY GuiObject child it can see and would sweep this
					-- into the run as a ninth rung -- the exact bug Components/Layer.lua exists to
					-- prevent, here avoided by keeping the two in separate frames rather than by
					-- reaching for Layer to overlay one element.
					scope:New "Frame" {
						Name = "Needle",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Size = UDim2.new(0, NEEDLE_WIDTH, 1, 6),
						BackgroundColor3 = Tokens.Color.TextPrimary,
						BorderSizePixel = 0,
						Position = scope:Computed(function(use)
							-- The signed -1..1 speed fraction mapped onto the track, with All Stop
							-- sitting where the neutral RUNG is rather than at the geometric middle
							-- -- the ladder is not symmetric (there are more ahead rungs than astern
							-- ones) and a needle centred on the track would read zero speed as
							-- slightly ahead.
							local neutralCentre = (NEUTRAL_INDEX - 0.5) / RUNG_COUNT
							local fraction = math.clamp(use(props.ActualFraction), -1, 1)
							local span = if fraction >= 0 then 1 - neutralCentre else neutralCentre
							return UDim2.fromScale(neutralCentre + fraction * span, 0.5)
						end),
						Visible = props.Interactive,
					},
				},
			},

			Label(scope, {
				Text = props.CommandedLabel,
				-- Reactive (the rung's own word, off the server's snapshot), so it cannot be a TrackedLabel
				-- and therefore cannot name one of Tokens.Type's tracked caps steps -- see
				-- Components/KeyHint.lua's cap for the full version of that argument.
				Scale = "Detail",
				Color = scope:Computed(function(use)
					return if use(props.Interactive) then Tokens.Color.TextPrimary else Tokens.Color.TextDisabled
				end),
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + 2),
			}),
		},
	}
end

return SpeedLadder
