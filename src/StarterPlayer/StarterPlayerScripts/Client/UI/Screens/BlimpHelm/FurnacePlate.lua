--!strict
--[[
	BlimpHelm/FurnacePlate.lua

	Owns: the furnace readout BOLTED TO THE HELM CONSOLE'S TOP EDGE -- the plate, the joint, the
	entrance, and the three facts on it (how much coal, how much water, and how long either of them
	leaves the hull flying).

	LIVES UNDER Screens/BlimpHelm/ RATHER THAN UNDER Screens/BlimpFuel/, AND THAT IS THE WHOLE POINT.
	This is not a panel that happens to sit above the console; it is one half of a JOINT, and a joint
	has exactly one owner. Screens/BlimpHelm/init.lua owns the console's plate, its chamfer, its
	bronze brackets and its violet edge -- so the surface that has to share an edge with it is written
	beside those props rather than in another folder restating them from memory. It is the same
	arrangement, for the same reason, that Screens/HUD/ArmamentIsland.lua has with the hotbar dock;
	that file's header records what the previous, separately-owned version drifted into.

	Screens/BlimpFuel/init.lua still owns the STATE -- the extrapolating Heartbeat, the time-based
	status buckets, and the SetVisible/SetSnapshot handle Client/Blimp/BlimpController.lua drives --
	and hands it here as a FurnaceState. This file requires nothing from BlimpFuel and BlimpFuel
	requires nothing from here; the type is matched structurally, which is how Luau types work.

	THE SEAM, WHICH IS THE ONLY REASON ANY OF THE GEOMETRY BELOW IS SHAPED THE WAY IT IS. Five rules,
	rotated ninety degrees from the dock's: that joint is vertical and side-by-side, this one is
	horizontal and stacked.

	  1. NEGATIVE GAP -- the plate sinks SEAM_OVERLAP into the console. This began as a butt joint at
	     gap zero, which is what the dock does, and it was visibly wrong here for a reason that does
	     not apply there: BOTH of these surfaces are chamfered, so a plate clipped flat at the seam
	     ends its full width while the console's top edge is two chamfer depths narrower. See
	     SEAM_OVERLAP for the two square ears that produced, and why sinking by exactly the chamfer
	     depth costs no content.
	  2. THE PLATE DRAWS NO EDGE ON THAT SIDE. It is built PLATE_HEIGHT tall -- FURNACE_HEIGHT plus
	     BLEED -- inside a clipping slot. Everything in the bleed is cut off at the seam and never
	     renders: the plate's bottom stroke, its two bottom chamfer cuts, and its two bottom corner
	     brackets. Two panels each keeping their own border at a join is exactly what makes it read as
	     two panels touching, and no amount of closing the gap fixes it. With rule 1's sink the two
	     fills then MERGE, so there is no rule left at the join and the bead is the only mark -- the
	     dock keeps a shared rule at its own seam because its island stops at that edge rather than
	     crossing it.
	  3. ONE WIDTH, SO THE EDGES ARE CONTINUOUS. PLATE_WIDTH is the console's, so the two left edges
	     form one unbroken line and the two right edges form another. This is the single strongest
	     "one object" cue available.
	  4. THE SAME CONTENT BASELINE. The X inset below is Tokens.Space.M -- the console's own -- so
	     both surfaces' contents sit on the same interior columns rather than merely inside boxes of
	     the same width.
	  5. BRONZE AT THE ASSEMBLY'S OUTER CORNERS ONLY. The plate keeps the console's bracket treatment
	     prop for prop, but only its TOP pair ever renders (the bottom pair is in the bleed). So the
	     combined object has four bracketed corners, the way one panel does, and nothing marking the
	     interior.
	The visible fastener -- one bronze bead straddling the seam -- belongs to the console rather than
	to this file, because half of it sits on the console. See Screens/BlimpHelm/init.lua.

	THE ENTRANCE IS A DRAWER, NOT A WIPE, and it is why this plate no longer wears Components/Reveal.
	The slot's HEIGHT springs (a laid-out or pinned child's Position is a property a layout owns, but
	nothing overwrites a Size), and the plate is anchored to the slot's TOP edge -- so as the slot
	grows, the plate's leading edge travels upward and the plate translates with it. Anchoring it to
	the stationary bottom edge instead would keep the plate still and reveal it through a moving
	window, which reads as a wipe rather than as a thing being pushed up out of the console. The plate
	never reflows: its own Size is a fixed offset on both axes, so the gauges are laid out exactly
	once no matter how many frames the spring takes.

	BLEED IS COMPUTED, NOT TYPED, and the overshoot is why. Tokens.Motion.IslandSpring is deliberately
	under-damped (see its own comment), so the slot passes FURNACE_HEIGHT before settling -- which
	briefly shows MORE of the plate than its rest height. Empty plate is exactly what should be there;
	a half-clipped bronze bracket is not. So BLEED clears the bracket zone plus the spring's own
	analytic peak overshoot, and retuning the damping moves it automatically instead of silently
	exposing a corner treatment mid-flight.

	IT BORROWS THE DOCK'S ISLAND SPRING RATHER THAN THE CONSOLE'S OWN ENTRANCE, and that is the right
	borrow: Tokens.Motion.IslandSpring exists for "a panel being shoved out of another panel", which
	is precisely this, and its 5% overshoot is what makes the plate read as having been pushed rather
	than as having been resized. The console's Reveal is for a whole tile arriving on its own.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.Parent.ChamferedSurface)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)
local StatusTag = require(script.Parent.Parent.Parent.Components.StatusTag)
local ModuleWell = require(script.Parent.Parent.Parent.Components.ModuleWell)
local FuelGauge = require(script.Parent.Parent.Parent.Components.FuelGauge)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- What the plate needs from whoever owns the fuel state, and nothing more. Declared here because
-- this file is the consumer; Screens/BlimpFuel/init.lua matches it structurally rather than
-- importing it, so neither module requires the other.
export type FurnaceState = {
	Present: UsedAs<boolean>,
	Coal: UsedAs<number>,
	CoalCapacity: UsedAs<number>,
	CoalStatusColor: UsedAs<Color3>,
	CoalStatusText: UsedAs<string?>,
	Water: UsedAs<number>,
	WaterCapacity: UsedAs<number>,
	WaterStatusColor: UsedAs<Color3>,
	WaterStatusText: UsedAs<string?>,
	EnduranceText: UsedAs<string>,
	EnduranceColor: UsedAs<Color3>,
}

export type Plate = {
	-- The pinned, clipping slot. Screens/BlimpHelm parents this into the console stack; it positions
	-- itself against that stack's own box, which is the console's.
	Content: GuiObject,
	-- The 0..1+ entrance spring, so the console can fade its seam bead in on the same value rather
	-- than running a second one that can disagree with this one about how far out the plate is.
	Presence: UsedAs<number>,
}

-- THE CONSOLE'S WIDTH, and the one number in this file that describes a surface it does not own.
-- Restated as a literal rather than imported because Screens/BlimpHelm/init.lua requires THIS file --
-- the arrow runs one way, as it does between the dock and its island. What makes the literal safe is
-- that Tests/UI/BlimpFuelPanel.spec.lua asserts the plate and the console measure the same width in
-- a real layout pass: change one and the suite fails loudly instead of the seam quietly developing a
-- step in it.
local PLATE_WIDTH = 220

-- The plate's own content height, fixed on both axes so a springing slot can never reflow what is
-- inside it. 114 = the Y inset twice (16), the header band (24), the list gap (8) and the stores
-- well (66). Measured in this repo's harness, not summed from the source.
local FURNACE_HEIGHT = 114

-- Clears CHAMFER_PX (8) on the horizontal, where the cut actually eats into the content box, and
-- matches the console's own inset so rule 4 above holds.
local PLATE_INSET_X = Tokens.Space.M
local PLATE_INSET_Y = Tokens.Space.S
-- Matches Components/StatusTag.lua's own fixed HEIGHT, so the endurance chip sets the header band's
-- height rather than being vertically clipped by a band sized for a bare label.
local HEADER_HEIGHT = 24

-- CornerBracket geometry, restated as the region of the plate a bracket can occupy: BracketInset in
-- from the corner, then BracketArmLength along the edge.
local BRACKET_ARM_LENGTH = 10
local BRACKET_INSET = ChamferedSurface.CHAMFER_PX
local BRACKET_ZONE = BRACKET_INSET + BRACKET_ARM_LENGTH

-- A second-order step response overshoots by exp(-pi*z / sqrt(1 - z^2)) -- the standard result, and
-- the same one Tokens.Motion.IslandSpring's own comment quotes to justify its damping. At z = 0.68
-- that is about 5.4%, so the slot peaks near 120px before settling to 114.
local DAMPING = Tokens.Motion.IslandSpring.Damping
local PEAK_OVERSHOOT = math.exp(-math.pi * DAMPING / math.sqrt(1 - DAMPING * DAMPING))

-- Everything past the seam. Tall enough that the plate's bottom chrome stays outside the slot at the
-- spring's peak, with a Tokens.Space.M cushion so a small retune does not land exactly on the
-- boundary.
local BLEED = math.ceil(FURNACE_HEIGHT * PEAK_OVERSHOOT) + BRACKET_ZONE + Tokens.Space.M
local PLATE_HEIGHT = FURNACE_HEIGHT + BLEED

-- HOW FAR THE PLATE SITS INTO THE CONSOLE, AND THE REASON THE JOINT NEEDED IT (owner, 2026-08-25:
-- "a little boxy on the connection section"). A butt joint at gap zero is the right idea and was the
-- wrong number here, because BOTH surfaces are chamfered: the plate is clipped flat at the seam and
-- so ends its full 220px wide, while the console'"'"'s top edge is only 220 - 2 * CHAMFER_PX = 204 wide
-- between its own two cut corners. The extra 8px at each end had nothing under it -- two little
-- square ears on an assembly whose whole silhouette is cut corners.
--
-- Sinking the plate by exactly the chamfer depth puts its clipped bottom BELOW the line where the
-- console'"'"'s cuts finish, so the plate covers those two voids and the assembly'"'"'s left and right edges
-- run straight through the joint. It costs nothing: PLATE_INSET_Y is Tokens.Space.S, which is also 8,
-- so what sinks into the console is exactly the plate'"'"'s own bottom padding and no content moves.
--
-- IT ALSO TAKES THE SHARED RULE AWAY, and that is the trade. Screens/HUD'"'"'s dock keeps a visible rule
-- at its own seam because its island stops at the dock'"'"'s edge rather than crossing it; here the two
-- fills merge and the bead is the only mark left. That is the same conclusion by the same rule ARM
-- the dock states -- "a point joins, a line divides" -- carried one step further, and it is the more
-- "one object" of the two readings.
local SEAM_OVERLAP = ChamferedSurface.CHAMFER_PX

local FurnacePlate = {}

-- Exposed because the CONSOLE draws the shared rule and the bead at exactly this depth -- half of
-- each sits on the console, so both belong to it (Screens/BlimpHelm/init.lua), and neither can be
-- placed without knowing how far the plate sinks.
FurnacePlate.SEAM_OVERLAP = SEAM_OVERLAP

function FurnacePlate.Build(scope: Scope, state: FurnaceState): Plate
	local presence = scope:Spring(
		scope:Computed(function(use): number
			return if use(state.Present) then 1 else 0
		end),
		Tokens.Motion.IslandSpring.Speed,
		Tokens.Motion.IslandSpring.Damping
	)

	-- Kept in the tree through the whole exit so the spring has something to animate, the same guard
	-- Components/Reveal.lua gives every ambient tile. Unlike the armament island this one is genuinely
	-- reachable: a pilot steps off the wheel and the furnace goes while the console stays.
	local alive = scope:Computed(function(use): boolean
		return use(state.Present) or use(presence) > 0.01
	end)

	-- The overlap is part of the travel, not an offset applied after it: the slot has to reach
	-- FURNACE_HEIGHT + SEAM_OVERLAP for the plate'"'"'s content to land where it did before the sink,
	-- and springing the whole distance is what keeps the drawer'"'"'s leading edge moving at one rate.
	local slotHeight = scope:Computed(function(use): number
		return math.max(0, math.round(use(presence) * (FURNACE_HEIGHT + SEAM_OVERLAP)))
	end)

	local plate = Panel(scope, {
		Name = "FurnacePlate",
		-- Fixed on BOTH axes. The height carries the bleed past the seam (see this file's header);
		-- the width is the console's, so the two plates' left and right edges are one line each.
		-- Nothing here is AutomaticSize and nothing here is Scale-sized, which is what keeps the
		-- springing slot from ever reflowing the contents -- and what keeps this out of the
		-- AutomaticSize inflation trap Components/Panel.lua's SurfaceTexture note measures.
		Size = UDim2.fromOffset(PLATE_WIDTH, PLATE_HEIGHT),
		-- THE CONSOLE'S MATERIAL, PROP FOR PROP -- Screens/BlimpHelm/init.lua's own panel. Not a
		-- family resemblance: at a shared seam, any difference in silhouette, bracket colour, arm
		-- length or edge opacity is visible AS a difference along the join, which is the one place
		-- two surfaces cannot afford to disagree.
		Elevated = false,
		Chamfered = true,
		CornerAccent = true,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,
		BracketArmLength = BRACKET_ARM_LENGTH,
		BracketInset = BRACKET_INSET,
		BorderColor3 = Tokens.Color.AccentPrimary,
		BorderTransparency = 0.3,

		Children = {
			-- Anchored to the TOP of the plate rather than filling it: the bleed is dead space below
			-- the content, and a UIListLayout that could see it would centre the gauges into the part
			-- of the plate that gets clipped.
			scope:New "Frame" {
				Name = "Content",
				Size = UDim2.fromOffset(PLATE_WIDTH, FURNACE_HEIGHT),
				Position = UDim2.fromOffset(0, 0),
				BackgroundTransparency = 1,

				[Children] = {
					Inset(scope, { X = PLATE_INSET_X, Y = PLATE_INSET_Y }),
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					-- BAND 1: what the surface is, and the one number you would keep if you could keep
					-- only one. Bare rather than in a well -- the console's own header band is too,
					-- and so is the dock's tier plate. The identity element is what the surface IS; a
					-- well around it would be grouping it with nothing.
					Stack.Row(scope, {
						Name = "Header",
						LayoutOrder = 1,
						Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
						Gap = Tokens.Space.S,
						AlignY = Enum.VerticalAlignment.Center,

						Children = {
							Stack.Fill(
								scope,
								Label(scope, {
									Text = "FURNACE",
									-- Micro, the caps step the dock's and the console's module captions
									-- both use. Not a TrackedLabel: this string is static and could be
									-- one, but the console's own role caption is not, and a seam is the
									-- wrong place to introduce a second caption treatment.
									Scale = "Micro",
									Color = Tokens.Color.TextDisabled,
									Size = UDim2.new(1, 0, 0, Tokens.Type.Micro.Size + 2),
									LayoutOrder = 1,
								})
							),
							-- THE ENDURANCE READOUT, AS A PAINTED CHIP, in the same position on the
							-- same band as the console's hull-mode chip directly below it. Tracked is
							-- left off deliberately: the text is reactive and that prop routes through
							-- TrackedLabel, which reads its string once and would freeze the chip on
							-- whatever the clock said at mount.
							StatusTag(scope, {
								Label = state.EnduranceText,
								Color = state.EnduranceColor,
								LayoutOrder = 2,
							}),
						},
					}),

					-- BAND 2: the two stores, in ONE well. One rather than one each, because they are
					-- two halves of a single reading -- the hull is grounded the instant EITHER
					-- crosses its own Minimum (BlimpConstants.Fuel's header), so coal and water are
					-- not independent gauges that happen to sit together, they are one furnace's
					-- inputs. Two wells would draw a box between them and invite reading either alone.
					ModuleWell(scope, {
						Name = "Stores",
						LayoutOrder = 2,
						-- Space.S between the two gauges, where the rows INSIDE one gauge are XS
						-- apart. That difference is the only thing telling the eye which bar belongs
						-- to which caption, now that the dividers are gone.
						Gap = Tokens.Space.S,

						Children = {
							FuelGauge(scope, {
								Caption = "Coal",
								Value = state.Coal,
								Capacity = state.CoalCapacity,
								StatusColor = state.CoalStatusColor,
								StatusText = state.CoalStatusText,
								LayoutOrder = 1,
							}),
							FuelGauge(scope, {
								Caption = "Water",
								Value = state.Water,
								Capacity = state.WaterCapacity,
								StatusColor = state.WaterStatusColor,
								StatusText = state.WaterStatusText,
								LayoutOrder = 2,
							}),
						},
					}),
				},
			},
		},
	})

	-- THE SLOT: a plain clipping frame whose only jobs are to be the height the spring says and to
	-- cut the plate's bottom chrome off at the seam. Deliberately NOT a Panel -- it has no chrome of
	-- its own; the plate inside carries all of it, and a second bordered surface here would draw a
	-- box around a box.
	--
	-- PINNED, NOT LAID OUT, and that is what makes the console's position safe rather than merely
	-- correct. AnchorPoint (0.5, 1) with Position (0.5, 0, 0, 0) puts its BOTTOM edge exactly on the
	-- stack's top edge -- which is the console's, since the console is the only thing sizing that
	-- stack -- and its centre on the console's. Because nothing lays it out, there is no arithmetic
	-- anywhere that could move the console as this height changes.
	return {
		Content = scope:New "Frame" {
			Name = "FurnaceSlot",
			AnchorPoint = Vector2.new(0.5, 1),
			-- SEAM_OVERLAP below the stack'"'"'s top edge, not on it -- see that constant for the two
			-- square ears this removes.
			Position = UDim2.new(0.5, 0, 0, SEAM_OVERLAP),
			Size = scope:Computed(function(use): UDim2
				return UDim2.fromOffset(PLATE_WIDTH, use(slotHeight))
			end),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Visible = alive,

			[Children] = plate,
		} :: Frame,
		Presence = presence,
	}
end

return FurnacePlate
