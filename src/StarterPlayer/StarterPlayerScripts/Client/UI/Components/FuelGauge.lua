--!strict
--[[
	FuelGauge.lua

	Owns: one resource's line inside the furnace instrument (Screens/BlimpFuel/init.lua) -- a caption,
	the raw "N / Capacity" numerals, an optional status word, and a Bar.lua fill under all three.
	Used twice by that screen (Coal, Water), the same "one small component, two callers" shape
	VitalPill.lua already gets 3x in CharacterTab.

	================================================================================================
	TWO ROWS, NOT THREE, AND THE ROW THAT WENT WAS THE EMPTY ONE
	================================================================================================

	This used to be 46px of three stacked full-width rows: caption left / status right, then the bar,
	then the numerals as `0` pinned hard left and `/ 500` pinned hard right. On a 196px panel that
	last row was two short strings with roughly 150 pixels of nothing between them -- the numerator
	and its own denominator, placed as far apart as the panel physically allowed. It read as a form
	with missing fields rather than as an instrument.

	The line is now caption, numerals and status on ONE row, in that reading order, with the bar
	under it: "coal, this much of this much, and it is offline." 29px instead of 46, and the two
	gauges together give the panel back 34 pixels it was spending on air.

	THE NUMERALS ARE ONE STRING, NOT TWO LABELS. `340 / 500` is a single fact and was only ever split
	so the two halves could be pushed to opposite edges. Rendering it as one right-aligned mono run
	also means the slash stays put while the value's digit count changes, which a two-label split
	could not promise.

	================================================================================================
	THE STATUS WORD IS ABSENT WHEN THERE IS NOTHING TO SAY
	================================================================================================

	It used to read NOMINAL whenever nothing was wrong, on both gauges, permanently. That is three
	simultaneous restatements of "fine" on a panel whose whole job is to be glanceable, and it meant
	the arrival of a real warning had to be noticed as a WORD CHANGING rather than as a word
	appearing.

	StatusText is nilable now, and the caller passes nil for nominal. Presence is the primary cue,
	the word is the second, colour is third -- the exact layering Components/BountyMarkedBadge.lua's
	header documents for itself, and what docs/ui-ux-philosophy.md's Critical States rule ("colour is
	never the only signal") actually asks for. Nothing is lost by staying silent while healthy: an
	absent warning is not a state a player has to be told about, and the bar's own fill still carries
	the continuous reading.

	COLOR IS COMPUTED BY THE CALLER, NOT HERE. Screens/BlimpFuel/init.lua buckets each resource's own
	seconds-until-its-own-Minimum into a three-tier color (see that file's header) and hands the
	result straight to StatusColor -- this component has no notion of burn rate, Minimum, or time at
	all. Bar.lua's own CriticalBelow/single-threshold Danger stroke is deliberately NOT wired up: the
	caller's time-based bucket already supersedes it with something more meaningful than a flat
	fraction-of-capacity, and wiring both would leave two independent, occasionally-disagreeing
	opinions about the same gauge.

	STILL A Bar, NOT A SegmentMeter, and that is a rule rather than a preference. SegmentMeter.lua's
	own header draws the line: a continuous draining quantity is Bar's, a countable ladder is
	SegmentMeter's, and "using this for a vital would quantize a number the player needs exactly."
	Fuel drains continuously and the pilot flies off its exact level.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Stack = require(script.Parent.Stack)
local Bar = require(script.Parent.Bar)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type FuelGaugeProps = {
	Caption: string,
	Value: UsedAs<number>,
	Capacity: UsedAs<number>,
	StatusColor: UsedAs<Color3>,
	-- nil = nothing is wrong = show nothing. See this file's header before giving it a "healthy"
	-- word to display.
	StatusText: UsedAs<string?>,
	LayoutOrder: number?,
}

-- The caption column. "WATER" is the longer of the two words this component is ever handed, and it
-- measures 42px at Micro (12px bold, 2px tracking); 46 clears it with a pixel to spare on each side.
-- Fixed rather than automatic so COAL and WATER share one numeral edge -- two gauges whose numbers
-- start at different x is the thing that makes a stacked pair read as two unrelated rows.
local CAPTION_WIDTH = 46
-- The numerals column, and the one width on this row that can be computed EXACTLY rather than
-- estimated: NumeralSmall is a MONO face, so every glyph is the same 7.2px advance at 12px and the
-- widest string these ever hold ("500 / 500", 9 glyphs) is 65. 68 gives it three pixels of slack.
--
-- THE TWO FIXED COLUMNS ARE THE TWO WITH KNOWN MAXIMA, AND THE STATUS WORD TAKES THE REMAINDER --
-- that is the whole of this row's layout and it is deliberate. A status word appears and disappears,
-- so a column that sized itself to it would shove the number sideways every time the ship got into
-- trouble; but its width is also the one here that CANNOT be computed (a proportional bold face, and
-- the vocabulary may grow), so pinning it would be exactly the hand-summed arithmetic
-- Screens/BlimpHelm's own KEY_COLUMN_WIDTH note calls out as fine until somebody adds a longer
-- string. Filling leaves the word 172 - 46 - 68 = 58px, which clears "CRITICAL" -- the longest the
-- caller produces, ~58 at Chip -- and makes the alarm the only thing that gives if a future word is
-- wider.
--
-- IT NEEDS A SCREENSHOT AND NO TEST HERE CAN REPLACE ONE. The headless place has no real font
-- metrics: it reports "CRITICAL" at 27px, roughly half its true width, so a clipping check run in
-- this harness would pass on every string it will ever be given.
local READING_WIDTH = 68
local ROW_GAP = Tokens.Space.XS

local ROW_HEIGHT = 15
local BAR_HEIGHT = 6

local function FuelGauge(scope: Scope, props: FuelGaugeProps): Frame
	-- Floored, not rounded -- the same "459.7 displayed as 460 beside a full ceiling reads as full
	-- when the player is one hit from empty" reasoning VitalPill.lua's own valueText already follows.
	local readingText = scope:Computed(function(use): string
		return `{math.floor(use(props.Value))} / {math.floor(use(props.Capacity))}`
	end)

	local statusText = scope:Computed(function(use): string
		return use(props.StatusText) or ""
	end)

	return Stack.New(scope, {
		Name = `FuelGauge_{props.Caption}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = props.LayoutOrder,
		Gap = Tokens.Space.XS,

		Children = {
			Stack.Row(scope, {
				Name = "Reading",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				Gap = ROW_GAP,
				AlignY = Enum.VerticalAlignment.Center,

				Children = {
					-- Micro, the dock's own caption step, rather than the Body this row used to be set
					-- in. A resource name is a LABEL on an instrument, not prose, and Body put it at
					-- the same weight and size as the number it labels.
					Label(scope, {
						Text = string.upper(props.Caption),
						Scale = "Micro",
						Color = Tokens.Color.TextDisabled,
						Size = UDim2.fromOffset(CAPTION_WIDTH, ROW_HEIGHT),
						LayoutOrder = 1,
					}),
					Label(scope, {
						Text = readingText,
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextPrimary,
						Size = UDim2.fromOffset(READING_WIDTH, ROW_HEIGHT),
						LayoutOrder = 2,
					}),
					-- The remainder, right-aligned. See READING_WIDTH for why the ALARM is the
					-- flexible one of the three columns rather than the number.
					Stack.Fill(
						scope,
						Label(scope, {
							Text = statusText,
							Scale = "Chip",
							Color = props.StatusColor,
							Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
							TextXAlignment = Enum.TextXAlignment.Right,
							LayoutOrder = 3,
						})
					),
				},
			}),
			Bar(scope, {
				LayoutOrder = 2,
				Value = props.Value,
				Max = props.Capacity,
				FillColor = props.StatusColor,
				-- Six, down from eight. The bar is one of two on a panel that also has to hold a
				-- header band; at this width a six-pixel track still reads its fraction clearly and
				-- the pair costs four fewer pixels of a budget measured in tens.
				Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
			}),
		},
	})
end

return FuelGauge
