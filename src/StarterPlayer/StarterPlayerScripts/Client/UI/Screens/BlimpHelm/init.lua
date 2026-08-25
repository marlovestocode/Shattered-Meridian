--!strict
--[[
	BlimpHelm/init.lua

	Owns: the ship's own console -- one bottom-left panel carrying, top to bottom, who you are and what
	the ship is doing, the control legend, the engine telegraph, and a live speed/altitude/heading row.
	Shown to EVERYONE aboard a blimp, pilot and passenger alike.

	THE CONTROLS ARE A SECTION OF THIS PANEL, NOT A PANEL OF THEIR OWN. They were briefly their own
	surface in the opposite corner, and that was wrong for a reason worth keeping written down: the
	legend and the telegraph are the same conversation. "G engages autopilot" and "AUTOPILOT" on the
	mode badge are two halves of one fact, and putting them at opposite ends of the screen makes the
	player's eye do the joining. One panel, banded -- role, controls, telegraph, telemetry -- is the
	shape the character menu already uses for the same reason, and it is what docs/ui-ux-philosophy.md
	means by "high contrast information hierarchy" rather than by two competing surfaces.

	THE SIBLING OF Screens/BlimpFuel/init.lua, AND THE AUDIENCE IS THE DIFFERENCE. That panel is the
	pilot's own instrument: a number only the person who can do something about it needs. This one is
	the SHIP's state, and a passenger who cannot see it has no way to tell a deliberate landing from
	the pilot having died at the wheel. So this mounts for a Handhold as well as a Helm -- with the
	telegraph dimmed, its needle hidden, and the three helm-only control rows absent rather than greyed.

	IT WEARS THE HOTBAR DOCK'S MATERIAL AND ITS GROUPING GRAMMAR (reworked 2026-08-25, at the owner's
	request, against docs/ui-ux-philosophy.md). Everything visual here is now Screens/HUD/init.lua's,
	prop for prop, and the reason is that they are the same KIND of surface: two always-on instruments
	sat over live gameplay, which that doc's Shape Language calls a combat surface.

	  * CHAMFERED, not a sharp rectangle. The doc puts the cut-corner silhouette on combat surfaces and
	    the sharp rect on MENU surfaces and says using one register's treatment on the other's "is the
	    wrong register -- not a stylistic choice either way." This console was wearing the menu register
	    while never being a thing you open.
	  * BRONZE, UN-RIVETTED BRACKETS braced into the cut (BracketInset), over a violet AccentPrimary
	    edge at the dock's own 0.3 -- so the two surfaces read as cut from one material.
	  * TWO RECESSED WELLS instead of two full-width rules. The dock reached this conclusion first: the
	    container carries the grouping, so the line between two containers does not have to. See the
	    `well` helper below, including why it is not a shared component yet.
	  * THE MODE IS A PAINTED CHIP (Components/StatusTag.lua), not coloured text. NO FUEL is a critical
	    state, and the doc's Critical States rule is that colour is never the only signal.
	  * THE LEGEND IS SET IN LABEL TYPE, NOT PROSE TYPE, and every row shares one description edge.
	    See KEY_COLUMN_WIDTH and Components/KeyHint.lua's Chip note for the measurements behind both.

	IT IS STILL SIZED LIKE A MINIMAP, NOT LIKE A MENU, and that survived the rework as the constraint
	everything else was fitted around. Everything on it is the smallest step that still reads -- Chip
	caps, Chip descriptions, an eight-pixel ladder track, three-letter telemetry captions -- because
	this sits over live gameplay for the length of a flight and docs/ui-ux-philosophy.md's HUD rule is
	"minimal, informative, out of the player's way". A console that eats a sixth of the screen fails the
	third of those however well it reads on its own. The first pass at this was menu-sized, and a menu is
	a thing you open; this is a thing you glance at.

	THE TWO NESTED WELLS COST 24px OF WIDTH AND NOTHING ELSE -- see PANEL_WIDTH. The text column inside
	them is still the 180px every width constant in this file was measured against, which is what kept
	the rework from turning into a re-tuning of the legend.

	THE CONTROL LEGEND IS A TWO-COLUMN GRID, NOT AN EIGHT-ROW LIST -- the second reason this reads as a
	minimap rather than a menu. Every row pairs two controls on one line, and as of 2026-08-25 EVERY row
	does, with no exception: "SPACE / SHIFT -> Climb / dive" used to be a full-width row of its own
	because two wide caps and that description could not share a half-width cell, and the price of that
	one exception was a SECOND key column twice the width of the grid's -- so the panel had two
	different description edges, neither flush with the other, and Components/KeyHint.lua's stated
	guarantee ("every hint in a stack shares one cap-column width") was not true of its only caller.
	Splitting it into "SPACE -> Climb" and "SHIFT -> Dive" removed the exception, which removed the
	second column, which is what made one flush edge possible. It reads better besides: two caps and two
	words on one line asked the player to infer that the first meant the first.

	THE SECTION HEADING that used to sit above the legend ("Controls"/"Aboard") is gone -- the well
	already marks the band, and a dense grid of key caps does not need a label explaining that it is a
	legend.

	NOTHING IN THE LEGEND CLIPS, AND THAT IS MEASURED RATHER THAN ASSUMED. Before the rework it did:
	"Telegraph" is 47px at the old Detail step against 38px of cell, so it ran under the next cell's
	caps, and the autopilot row's active swap ("Autopilot on", 58px) overflowed by twenty. The rows are
	set in Chip now, the shared column is 37, and the widest description on the panel measures 30
	against 47px of space. See KEY_COLUMN_WIDTH for the arithmetic and where the numbers came from.

	RESPONSIVE MEANS SIZED BY CONTENT, NOT BY A COUNTED ALLOWANCE. The frame is AutomaticSize.Y over a
	UIListLayout, so collapsing the helm rows for a passenger shrinks the panel to fit rather than
	leaving a hole -- the same reason Components/Stack.lua's header gives for never hand-summing a
	container's height. Nothing here knows how tall a KeyHint is, which is what makes changing one safe.

	SAME "SCREEN EXPOSES STATE, CLIENT MODULE DRIVES IT" SPLIT every other Screens/ handle follows:
	this file sends and receives nothing. Client/Blimp/BlimpController.lua calls SetVisible/SetKind/
	SetReleaseKey on mount edges, SetHelmState on every HelmUpdated push, and SetTelemetry once a frame.

	THE DISCRETE HALF IS PUSHED AND THE CONTINUOUS HALF IS MEASURED LOCALLY, which is the whole reason
	this panel costs almost nothing to run. Mode, rung and autopilot arrive on an edge from the server
	(see BlimpConstants.Network.RemoteNames.HelmUpdated). Speed, altitude and heading are read off the
	hull's own replicated physics by Client/Camera/BlimpCamera.lua -- which is already reading them
	every frame to drive the camera -- and handed straight here. Nothing continuous ever touches the
	wire. Compare Screens/BlimpFuel, which has to EXTRAPOLATE its live number between snapshots off a
	known burn rate precisely because fuel is not something a client can see for itself.

	IT FILTERS ITS OWN WRITES. SetTelemetry is called at frame rate but only pushes a Fusion Value when
	the DISPLAYED (rounded) value actually changed -- a speed of 78.3 and 78.4 render the same string,
	and setting a Value to a number that produces identical text still walks every Computed downstream
	of it. Same "plain mirrors beside the reactive Values" split Screens/HUD and Screens/BlimpFuel both
	already use, applied to the write side rather than the read side.

	Does not own: the ladder's own geometry or rung colors (Components/SpeedLadder.lua), the legend row
	primitive (Components/KeyHint.lua), what any key IS (Client/Blimp/BlimpController.lua -- and see
	its header on why the helm keys are deliberately raw rather than rebindable KeybindActions), the
	rungs themselves (Shared/Blimp/BlimpConstants.SpeedStates), the flight modes
	(Server/Blimp/BlimpFlightMode.lua), or the decision of when to show any of it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Inset = require(script.Parent.Parent.Components.Inset)
local Stack = require(script.Parent.Parent.Components.Stack)
local KeyHint = require(script.Parent.Parent.Components.KeyHint)
local StatusTag = require(script.Parent.Parent.Components.StatusTag)
local TrackedLabel = require(script.Parent.Parent.Components.TrackedLabel)
local SpeedLadder = require(script.Parent.Parent.Components.SpeedLadder)
local Reveal = require(script.Parent.Parent.Components.Reveal)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type BlimpHelmHandle = {
	SetVisible: (visible: boolean) -> (),
	-- nil means "not aboard"; "Helm" gets the live telegraph and every control row, "Handhold" gets a
	-- dimmed ladder and only the row a passenger can actually use.
	SetKind: (kind: BlimpTypes.StationKind?) -> (),
	SetHelmState: (payload: BlimpTypes.HelmUpdatedPayload) -> (),
	-- The live Interact bind's display name -- the one key on this panel that IS rebindable.
	SetReleaseKey: (keyName: string) -> (),
	-- Called once per rendered frame while aboard. `speed` is signed forward studs/second, `fraction`
	-- is that over cruise (-1..1), `altitude` is world Y, `headingDegrees` is a 0..360 bearing.
	SetTelemetry: (speed: number, fraction: number, altitude: number, headingDegrees: number) -> (),
}

local BlimpHelm = {}

-- THE CONTENT COLUMN IS STILL 180, WHICH IS WHY THE PANEL GREW. Everything inside a well is laid out
-- against the same 180px this console has always had -- 220 minus the panel's own 12px sides minus
-- each well's 8px sides. That is deliberate rather than arithmetic that happened to work out: every
-- width constant below (KEY_COLUMN_WIDTH, the grid cells, the telemetry thirds) is measured against
-- 180, and re-deriving them for a narrower column is how a legend row starts clipping. So the two
-- nested containers are paid for in panel width, not out of the text.
--
-- 24px is the whole cost of the redesign and it is the one number worth vetoing on a screenshot: this
-- file's header calls the console minimap-sized on purpose, and 220 is 11% of a 1080p screen's width
-- against 196's 10%. The alternative was shrinking the text column, and this codebase does not ship
-- rows that clip.
local PANEL_WIDTH = 220
-- Clears CHAMFER_PX (8) on the horizontal, where the cut actually eats into the content box. The
-- vertical can sit at the chamfer line because the cut is a CORNER: by the time content starts at
-- x = 12 the top edge is already past the diagonal.
local PANEL_INSET_X = Tokens.Space.M
local PANEL_INSET_Y = Tokens.Space.S
-- Matches Components/StatusTag.lua's own fixed HEIGHT, so the mode chip sets the header band's height
-- rather than being vertically clipped by a band sized for the bare label it replaced.
local HEADER_HEIGHT = 24
-- ONE KEY COLUMN FOR EVERY ROW IN THE LEGEND, WHICH IS THE WHOLE FIX. This panel used to run two --
-- 40 for the paired grid rows and 80 for the two full-width ones -- so its descriptions had two
-- different left edges and neither was flush with the other. Components/KeyHint.lua's header says the
-- shared column "is the whole point of the layout" and that "every hint in a stack shares one
-- cap-column width"; this file was the one caller and it was not doing that.
--
-- 37 IS MEASURED, NOT CHOSEN: a rendered KeyCap is 17px for any single glyph (its MinWidth) and the
-- widest run here is two of them either side of KeyHint's own 3px CAP_GAP -- 17 + 3 + 17. SPACE and
-- SHIFT measure 36 and 35, so each still fits the same column on its own, which is what let the
-- climb/dive row join the grid rather than needing a column twice as wide for the whole panel.
local KEY_COLUMN_WIDTH = 37
-- Each grid cell is half the well's 180px content column less half of the gutter between them, so
-- the two cells are 88 wide with 4 between. A description therefore gets 88 - (37 + 4) = 47px, and
-- the widest one on this panel ("Autopilot") measures 30 at Chip. Every row clears with room; before
-- this it was 38px of column holding a 47px word, which is what ran "Telegraph" under the A/D caps.
local GRID_COLUMN_GUTTER = Tokens.Space.XS
-- Matches Components/KeyHint.lua's own private ROW_HEIGHT -- duplicated here (not exported) because a
-- grid row's two half-width wrappers need an explicit height to lay the two KeyHints out side by side
-- rather than one full width each.
local GRID_ROW_HEIGHT = 17
-- The word and color for each BlimpTypes.HullMode. A table rather than an if-chain because it is
-- exhaustive over a closed union and a missing arm should be visible as a missing row, not as a
-- fallthrough -- and because the day a sixth mode is added, this is the one place that has to notice.
local MODE_TEXT: { [string]: string } = {
	Moored = "HELM CLEAR",
	Piloted = "MANUAL",
	Autopilot = "AUTOPILOT",
	Landing = "AUTO-LANDING",
	Grounded = "GROUNDED",
}

local MODE_COLOR: { [string]: Color3 } = {
	Moored = Tokens.Color.TextDisabled,
	Piloted = Tokens.Color.TextSecondary,
	-- The "live / interactive" register -- something is actively flying this ship and it is not a
	-- person, which is the single most useful thing this panel says.
	Autopilot = Tokens.Color.AccentPrimary,
	Landing = Tokens.Color.Warning,
	Grounded = Tokens.Color.TextDisabled,
}

-- NOT A BlimpTypes.HullMode, AND THAT IS THE WHOLE REASON IT HAS TO LIVE HERE. Reported 2026-08-25:
-- pressing G at the wheel lit the autopilot legend row but left this chip reading MANUAL, so the
-- panel's primary indicator said nothing had happened.
--
-- It is not a server bug. Server/Blimp/BlimpFlightMode.Step resolves `HasPilot` BEFORE
-- `AutopilotArmed`, so a hull whose pilot is still holding the wheel is Piloted whatever the latch
-- says -- which is correct, and is the documented feature: autopilot "holds the rung while the helm
-- is empty AND somebody is still on the ship", and your rudder keeps working until you walk away.
--
-- So "armed, but I am still the one flying" is a real state with no HullMode of its own, and the
-- payload carries it as a SEPARATE boolean beside Mode. The panel had both facts and was showing only
-- one of them in the chip while leaking the other into the legend. Resolved in setHelmState.
--
-- A distinct word rather than borrowing "AUTOPILOT": at the wheel the ship is NOT flying itself yet,
-- and a chip that claimed otherwise would be lying about which of you has the rudder. It takes the
-- Autopilot colour, so arming it changes the chip's hue as well as its word -- the confirmation the
-- press was missing -- and stepping away then swaps the word alone, which is the smaller change
-- because it is the smaller event.
local AUTOPILOT_ARMED_TEXT = "AUTO ARMED"

-- 0..360 to the eight-point compass. Sixteen points would be more precise and less readable at a
-- glance, which is the wrong trade for a number sitting next to its own exact degrees.
local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local function compassPoint(degrees: number): string
	-- +0.5 before flooring is what makes the SECTOR centred on each cardinal rather than starting at
	-- it: without it, due north reads as N but one degree west of north reads as NW.
	local sector = math.floor((degrees % 360) / 45 + 0.5) % 8
	return COMPASS[sector + 1]
end

-- THE DOCK'S MODULE WELL, IN A COLUMN INSTEAD OF A ROW -- a recessed group box holding one cluster of
-- readouts. Screens/HUD/init.lua's own `moduleGroup` is the identical shape (same RailScrim fill, same
-- hairline stroke, same Radius.Hairline corner) laid out horizontally, and this console adopting it is
-- most of what "look like the hotbar" means: the two surfaces now group their contents with the same
-- object rather than each inventing a grouping of its own.
--
-- IT IS WHAT LET THE TWO FULL-WIDTH DIVIDERS GO. This panel used to band itself with Divider.Plain
-- rules, which is the treatment the dock ITSELF abandoned -- see moduleGroup's own comment: "the
-- container carries the grouping, so the line between two containers doesn't have to." A rule plus a
-- well is the grouping stated twice, and on a console this size the two rules were 2 of its ~200
-- vertical pixels spent saying something the wells already say.
--
-- DELIBERATELY NOT A SHARED COMPONENT YET, and the bar is the reason rather than an oversight.
-- CLAUDE.md's rule for promoting one is three independently hand-written call sites; this is the
-- second. (Tokens.Wash.RailScrim has two other readers -- Screens/EmoteWheel's full-screen scrim and
-- Screens/Onboarding/StepRail's rail band -- but neither is this SHAPE, they only share the wash, so
-- neither counts toward it.) The third caller is what collapses these into Components/ModuleWell.lua;
-- until then the tokens are the contract, and naming them here is what keeps the two from drifting.
--
-- The UICorner/UIStroke/UIPadding are safe among a Stack's Children precisely because none of them is
-- a GuiObject -- a UIListLayout arranges GuiObject children only, which is the distinction
-- Components/Layer.lua's header is about.
local function well(scope: Scope, name: string, layoutOrder: number, gap: number, children: { any }): Frame
	return Stack.New(scope, {
		Name = name,
		LayoutOrder = layoutOrder,
		-- Full width of whatever column it is dropped in, height from its own contents -- so a
		-- passenger, whose legend collapses to a single row, gets a shorter well rather than a
		-- part-empty one. Same reason this file's header gives for the panel's own AutomaticSize.
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = gap,
		BackgroundColor3 = Tokens.Wash.RailScrim.Color,
		BackgroundTransparency = Tokens.Wash.RailScrim.Transparency,

		Children = {
			scope:New("UICorner")({
				CornerRadius = Tokens.Radius.Hairline,
			}),
			scope:New("UIStroke")({
				Color = Tokens.Border.Hairline.Color,
				Transparency = Tokens.Border.Hairline.Transparency,
				Thickness = 1,
			}),
			Inset(scope, { X = Tokens.Space.S, Y = Tokens.Space.XS }),
			children,
		},
	})
end

-- Returns its handle AND its tile, unparented -- UI/init.lua hands it to Shell/Regions.lua's
-- BottomLeft at order 20, so it stacks ABOVE the weapon rack instead of underneath it. The two used
-- to share a coordinate; see Regions.lua's header for the pair of comments that said they could not.
function BlimpHelm.Mount(scope: Scope): (BlimpHelmHandle, Frame)
	local visible = scope:Value(false)
	local interactive = scope:Value(false)
	local roleText = scope:Value("ABOARD")
	local releaseKey = scope:Value("E")
	local autopilot = scope:Value(false)

	local commandedIndex = scope:Value(1)
	local commandedLabel = scope:Value("ALL STOP")
	local actualFraction = scope:Value(0)

	local modeText = scope:Value(MODE_TEXT.Moored)
	local modeColor = scope:Value(MODE_COLOR.Moored)

	local speedText = scope:Value("0")
	local altitudeText = scope:Value("0")
	local headingText = scope:Value("--")

	-- THE ENTRANCE IS Components/Reveal.lua's NOW, and this file no longer owns a spring at all. What
	-- used to be here was a hand-rolled 0..1 spring driving a 14px Position slide, a 2% content scale
	-- and an exit tail-guard; the slide died in the region migration (a tile's Position belongs to its
	-- region's UIListLayout, which overwrites it every layout pass) and the other two were the same
	-- two things three other ambient tiles either hand-rolled differently or went without. Reveal's
	-- own header has the full account, including why it does not try to give the slide back.
	--
	-- The tuning below is unchanged because Reveal ADOPTED this panel's numbers as the shared ones --
	-- speed 22, critically damped -- so nothing about how this console arrives has changed.
	local reveal = Reveal(scope, { Visible = visible })

	-- Plain mirrors of the last DISPLAYED values, so a frame that would render identical text writes
	-- no Fusion Value at all -- see this file's header.
	local lastSpeed = math.huge
	local lastAltitude = math.huge
	local lastHeading = math.huge
	local lastFraction = math.huge

	local function setVisible(newVisible: boolean): ()
		visible:set(newVisible)
	end

	local function setKind(kind: BlimpTypes.StationKind?): ()
		interactive:set(kind == "Helm")
		roleText:set(if kind == "Helm" then "AT THE HELM" elseif kind == "Handhold" then "PASSENGER" else "ABOARD")
	end

	local function setReleaseKey(keyName: string): ()
		releaseKey:set(keyName)
	end

	local function setHelmState(payload: BlimpTypes.HelmUpdatedPayload): ()
		commandedIndex:set(payload.SpeedIndex)
		commandedLabel:set(payload.SpeedLabel)
		autopilot:set(payload.Autopilot == true)

		-- Depletion outranks the mode word. A pilot whose telegraph reads FLANK while the ship sits
		-- still is looking at two facts that contradict each other, and this panel's job at that
		-- moment is to say which one is winning -- see BlimpTypes.HelmUpdatedPayload.Depleted.
		if payload.Depleted then
			modeText:set("NO FUEL")
			modeColor:set(Tokens.Color.Danger)
			return
		end

		-- THE CHIP IS RESOLVED FROM BOTH FACTS, NOT FROM Mode ALONE -- see AUTOPILOT_ARMED_TEXT for
		-- the report this fixes and why the server is right to keep them separate. Ordered under the
		-- Depleted check on purpose: a hull that has run dry is not flying itself either, whatever the
		-- latch says, and "NO FUEL" is the fact the pilot can actually act on.
		if payload.Mode == "Piloted" and payload.Autopilot then
			modeText:set(AUTOPILOT_ARMED_TEXT)
			modeColor:set(MODE_COLOR.Autopilot)
			return
		end

		modeText:set(MODE_TEXT[payload.Mode] or payload.Mode)
		modeColor:set(MODE_COLOR[payload.Mode] or Tokens.Color.TextSecondary)
	end

	local function setTelemetry(speed: number, fraction: number, altitude: number, headingDegrees: number): ()
		local roundedSpeed = math.floor(math.abs(speed) + 0.5)
		if roundedSpeed ~= lastSpeed then
			lastSpeed = roundedSpeed
			speedText:set(tostring(roundedSpeed))
		end

		local roundedAltitude = math.floor(altitude + 0.5)
		if roundedAltitude ~= lastAltitude then
			lastAltitude = roundedAltitude
			altitudeText:set(tostring(roundedAltitude))
		end

		local roundedHeading = math.floor(headingDegrees + 0.5) % 360
		if roundedHeading ~= lastHeading then
			lastHeading = roundedHeading
			headingText:set(`{roundedHeading}° {compassPoint(roundedHeading)}`)
		end

		-- The needle is the one continuous thing on the panel that is not text, so it is quantized to
		-- a hundredth rather than to a whole unit -- fine enough that the sweep still looks smooth,
		-- coarse enough that a hull holding a steady speed stops writing entirely.
		local quantized = math.floor(math.clamp(fraction, -1, 1) * 100 + 0.5) / 100
		if quantized ~= lastFraction then
			lastFraction = quantized
			actualFraction:set(quantized)
		end
	end

	local function readout(caption: string, value: UsedAs<string>, order: number): Frame
		return scope:New "Frame" {
			Name = `Readout_{caption}`,
			LayoutOrder = order,
			Size = UDim2.fromScale(1 / 3, 1),
			BackgroundTransparency = 1,

			[Children] = {
				-- A TrackedLabel, unlike everything else on this panel, and it is the one place that is
				-- correct: these three captions are STATIC strings, which is what that component requires,
				-- and Micro is a tracked step -- so rendering it through a plain Label would silently drop
				-- the letter-spacing that makes a three-letter caps abbreviation legible at 12 pixels.
				TrackedLabel(scope, {
					Text = caption,
					Scale = "Micro",
					Color = Tokens.Color.TextDisabled,
					Size = UDim2.new(1, 0, 0, Tokens.Type.Micro.Size + 2),
					Position = UDim2.fromOffset(0, 0),
				}),
				Label(scope, {
					Text = value,
					Scale = "NumeralSmall",
					Color = Tokens.Color.TextPrimary,
					Size = UDim2.new(1, 0, 0, Tokens.Type.NumeralSmall.Size + 2),
					Position = UDim2.fromOffset(0, Tokens.Type.Micro.Size + 2),
				}),
			},
		} :: Frame
	end

	-- ONE ROW SHAPE FOR THE WHOLE LEGEND, replacing the helmRow/helmGridRow pair this panel used to
	-- carry. Those two existed only because "SPACE / SHIFT" would not fit a half-width cell, and the
	-- price was two different key columns and therefore two different description edges -- see
	-- KEY_COLUMN_WIDTH. Splitting that row into its two keys (below) removed the exception, and with
	-- the exception gone there is no second row shape to keep.
	--
	-- `visible` is a parameter rather than always `interactive` because the release row is the one
	-- line a passenger keeps. It is set on the wrapping Frame, not on either KeyHint: a row's two
	-- cells are always helm-only together, so hiding the row rather than each cell is what keeps a
	-- passenger from being left with an empty seventeen-pixel gap where the row used to be.
	--
	-- Hidden rather than dimmed, for the pilot-only rows: a disabled control is worth showing when the
	-- player could earn it, and a passenger cannot -- they would have to walk to the wheel, at which
	-- point the row appears. Greying it would be teaching a passenger a key that does nothing for them,
	-- and the panel would carry three dead lines on every ride as a passenger.
	local function legendRow(
		spec: {
			Order: number,
			Visible: UsedAs<boolean>,
			LeftKeys: { UsedAs<string> },
			LeftText: string,
			-- Omitted for a row that fills only its left cell. The release row is the one such row today,
			-- and it renders as a half-width hint rather than as a full-width one so that its description
			-- starts on the same edge as every other row's.
			RightKeys: { UsedAs<string> }?,
			RightText: string?,
			RightActiveText: string?,
			RightActive: UsedAs<boolean>?,
		}
	): Frame
		local cells: { Instance } = {
			scope:New "Frame" {
				Name = "Left",
				Size = UDim2.new(0.5, -GRID_COLUMN_GUTTER / 2, 1, 0),
				BackgroundTransparency = 1,
				[Children] = KeyHint(scope, {
					Keys = spec.LeftKeys,
					Text = spec.LeftText,
					KeyColumnWidth = KEY_COLUMN_WIDTH,
				}),
			},
		}

		if spec.RightKeys and spec.RightText then
			table.insert(
				cells,
				scope:New "Frame" {
					Name = "Right",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.new(0.5, -GRID_COLUMN_GUTTER / 2, 1, 0),
					BackgroundTransparency = 1,
					[Children] = KeyHint(scope, {
						Keys = spec.RightKeys,
						Text = spec.RightText,
						ActiveText = spec.RightActiveText,
						Active = spec.RightActive,
						KeyColumnWidth = KEY_COLUMN_WIDTH,
					}),
				}
			)
		end

		return scope:New "Frame" {
			Name = "LegendRow",
			LayoutOrder = spec.Order,
			Size = UDim2.new(1, 0, 0, GRID_ROW_HEIGHT),
			BackgroundTransparency = 1,
			Visible = spec.Visible,

			[Children] = cells,
		} :: Frame
	end

	local tile = Panel(scope, {
		Name = "BlimpHelmPanel",
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		-- Kept in the tree through the whole exit so the spring has something to animate, and only
		-- actually removed once it has finished leaving. Reveal owns that guard now; this used to be
		-- a hand-written `visible or entrance < 0.99` here.
		Visible = reveal.Mounted,
		-- THE DOCK'S OWN MATERIAL, PROP FOR PROP -- Screens/HUD/init.lua's HotbarDock. This console is
		-- a combat surface by docs/ui-ux-philosophy.md's Shape Language (it sits over live gameplay
		-- for the length of a flight), and that section puts the cut-corner silhouette on combat
		-- surfaces and the sharp rect on MENU ones, then says using one register's treatment on the
		-- other's surface "is the wrong register -- not a stylistic choice either way." This panel was
		-- a sharp rect with violet rivetted brackets, which is the menu register, worn by a thing that
		-- is never opened.
		--
		-- Elevated = false with it: SurfaceElevated is the "this sits above the panel behind it" step,
		-- and there is no panel behind this one. The dock made the same call for the same reason.
		Elevated = false,
		Chamfered = true,
		-- CHAMFER AND BRACKETS TOGETHER, which BracketInset is what makes legal -- pulling each elbow
		-- in by the cut's own depth so the arms brace it instead of floating over the diagonal. Bronze
		-- and un-rivetted for the dock's reason: bronze reads as the frame's own forged metal, where
		-- violet would put four more "interactive" elements on a panel whose only live thing is the
		-- needle.
		CornerAccent = true,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,
		BracketArmLength = 10,
		BracketInset = ChamferedSurface.CHAMFER_PX,
		-- The same violet edge the dock carries, at the same softened opacity, so the two surfaces
		-- read as cut from one material rather than as two panels that happen to share a palette.
		BorderColor3 = Tokens.Color.AccentPrimary,
		BorderTransparency = 0.3,
		-- NOT SurfaceTexture, and this is why the console used to be a column of empty panel roughly
		-- four times taller than anything drawn in it. MeridianField.lua's root Frame is
		-- Size = Scale(1, 1) and Panel.lua parents it as a DIRECT sibling of Content inside the very
		-- Frame this panel sets AutomaticSize.Y on -- so the frame sizes itself from a child that is
		-- defined as 100% of the frame, and resolves to roughly the viewport height instead of the
		-- content height. Screens/WeaponInventory/init.lua has the full measurement (a bare
		-- AutomaticSize.Y panel with SurfaceTexture and 40px of content resolved to Y = 852) and hit
		-- exactly this; it is not repeated here.
		--
		-- That file's note claims it is "the only SurfaceTexture caller that is also AutomaticSize".
		-- It was not -- this panel was the second, and went unnoticed because a helm console is only
		-- on screen while piloting and nothing sat beside it to make the empty space obvious. The
		-- other two callers (Components/ScreenFrame.lua, Screens/Onboarding/CreatorFrame.lua) are
		-- both handed a fixed Size and are genuinely unaffected.
		--
		-- Fixing Panel/MeridianField's AutomaticSize interaction properly is still the real follow-up.
		-- This call site just stops opting into the broken combination, same as the other one did.

		Children = {
			-- Six lines of UIPadding replaced by the one call this codebase has for it -- and the
			-- horizontal step went up to clear the chamfer, see PANEL_INSET_X.
			Inset(scope, { X = PANEL_INSET_X, Y = PANEL_INSET_Y }),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				-- Space.S rather than XS, because what this now separates is two WELLS and a header
				-- rather than eight loose rows. A gap that reads as generous between three objects is
				-- the same gap that read as slack between eight.
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			-- A whisper of scale on the entrance spring, well under anything that reads as a "pop", and
			-- the only motion on this panel's arrival. Built by Components/Reveal.lua and parented
			-- here rather than applied for us, because WHICH frame gets scaled is this file's call:
			-- inside the Panel's own Content wrapper, so the chrome holds still while its contents
			-- arrive. (Panel.lua's own Scale prop is the OTHER behaviour -- that one grows the frame.)
			reveal.Scale,

			-- BAND 1: who you are, and what the ship is doing. Bare rather than in a well, and that
			-- is the dock's arrangement too -- its TierBadge is a plate sitting directly on the
			-- panel while the vitals and slots are wells. The identity element is what the surface
			-- IS; a well around it would be grouping it with nothing.
			Stack.Row(scope, {
				Name = "Header",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				Gap = Tokens.Space.S,
				AlignY = Enum.VerticalAlignment.Center,

				Children = {
					-- FILL, NOT A HAND-PICKED 0.52/0.48 SPLIT. The old pair of scale widths was two
					-- guesses that had to add to one and stay ahead of the longest string either
					-- side could hold -- "AUTO-LANDING" against 48% of 180px is 86 pixels for 12
					-- Chip glyphs, which is exactly the sort of number that is fine until a sixth
					-- flight mode is added. The chip takes its natural width and the role takes what
					-- is left, which is what Stack.Fill is for (see its header: it works under ANY
					-- UIListLayout, not only a Stack's).
					Stack.Fill(
						scope,
						Label(scope, {
							Text = roleText,
							-- Micro, not Detail: this is a caption naming the surface, and the
							-- caps step is what the dock's own module captions use. It cannot be a
							-- TrackedLabel -- roleText is reactive and that component reads its
							-- string once (see its header) -- so it gets Micro's face and size
							-- without Micro's tracking, which is the same trade every reactive
							-- caps label in this codebase makes.
							Scale = "Micro",
							Color = Tokens.Color.TextDisabled,
							Size = UDim2.new(1, 0, 0, Tokens.Type.Micro.Size + 2),
							LayoutOrder = 1,
						})
					),
					-- THE MODE IS A PAINTED CHIP NOW, NOT COLOURED TEXT. It was a right-aligned
					-- Label whose only signal was its own colour -- which docs/ui-ux-philosophy.md's
					-- Critical States rule forbids relying on ("Color is never the only signal"),
					-- and NO FUEL is precisely a critical state. StatusTag gives it a fill and a
					-- solid leading edge in the same hue, so the state has a SHAPE that reads before
					-- the word does and survives a player who cannot separate red from bronze.
					--
					-- Tracked is left off deliberately: modeText is reactive, and that prop routes
					-- through TrackedLabel, which would freeze the chip on whatever mode the ship
					-- happened to be in at mount.
					StatusTag(scope, {
						Label = modeText,
						Color = modeColor,
						LayoutOrder = 2,
					}),
				},
			}),

			-- BAND 2: the control legend, in a well. Above the telegraph deliberately -- it is what
			-- teaches the reading of the band below it, and a legend under the gauge it explains is
			-- a footnote. Terse because the column they live in is barely a hundred pixels wide.
			-- Each names the CONTROL rather than explaining it -- the ladder below already shows
			-- what the telegraph does, and a console this size is a reminder, not a tutorial.
			--
			-- The two Divider.Plain rules that used to band this panel are gone; the wells carry the
			-- grouping now. See `well` above for why that is the dock's own conclusion rather than a
			-- preference.
			-- Space.XS between rows, which is what the panel's own list layout used to give them when
			-- they were direct children of it. Preserved rather than re-chosen: KeyHint's 17px row
			-- carries a 15px cap, so flush rows would leave two pixels between one key and the next
			-- and the legend would read as a single block rather than four lines.
			well(scope, "Controls", 2, Tokens.Space.XS, {
				legendRow({
					Order = 1,
					Visible = interactive,
					LeftKeys = { "W", "S" },
					-- "Throttle", not "Telegraph" (owner, 2026-08-25). The ladder below IS an engine
					-- telegraph and the codebase calls it one throughout -- Components/SpeedLadder,
					-- BlimpConstants.Input.TelegraphRepeat*, BlimpSpeedStage -- but that is the
					-- machinery's name for itself, and a legend is read by a player who has never seen
					-- a ship's engine order telegraph. The rung words on the gauge (ALL STOP, HALF
					-- AHEAD, FLANK) carry the nautical register; the key that moves them says what it
					-- does. This is the only player-facing use of the word, so nothing else moved.
					LeftText = "Throttle",
					RightKeys = { "A", "D" },
					RightText = "Rudder",
				}),
				legendRow({
					Order = 2,
					Visible = interactive,
					LeftKeys = { "X" },
					LeftText = "All stop",
					RightKeys = { "G" },
					RightText = "Autopilot",
					-- "Engaged", not the old "Autopilot on". Two reasons and either would settle it.
					-- Width: the swap text has to fit the same 47px cell as the resting text, and
					-- "Autopilot on" measures 58 at Chip -- it was overflowing by 11 even before the
					-- column was tightened. Sense: the row already says AUTOPILOT beside the G cap, so
					-- repeating the word to state that it is on spends the widest string on the panel
					-- restating its own label.
					RightActiveText = "Engaged",
					RightActive = autopilot,
				}),
				-- ONE KEY PER ACTION, which is what let this row join the grid. It was
				-- "SPACE / SHIFT -> Climb / dive", the one row too wide for a half-width cell and
				-- therefore the reason the panel ran a second, doubled key column at all. It also
				-- asked the reader to do the pairing themselves -- two caps, two words, and an
				-- implied "the first one means the first one". Split, each cap names its own action,
				-- every row in the legend is the same shape, and the widest cap here (SPACE, 36px)
				-- still clears the shared 37px column on its own.
				legendRow({
					Order = 3,
					Visible = interactive,
					LeftKeys = { "SPACE" },
					LeftText = "Climb",
					RightKeys = { "SHIFT" },
					RightText = "Dive",
				}),
				-- The one row a passenger keeps, so it is the one row never hidden -- and the reason
				-- this well is never empty, so it never renders as a bare recessed box. A half-width
				-- row with no right cell rather than a full-width hint: its description lands on the
				-- same edge as the four above it, where a full-width one put "Let go" 65px out into
				-- open panel with nothing under it.
				legendRow({
					Order = 4,
					Visible = true,
					-- The only reactive cap on the panel -- see KeyHint's Keys prop. Every other key
					-- here is a raw contextual key no rebind screen can reach; this one shares the
					-- Interact action with the prompt that started the mount, so it follows a rebind.
					LeftKeys = { releaseKey },
					LeftText = "Let go",
				}),
			}),

			-- BAND 3: the instruments -- what was commanded, then what the ship is actually doing.
			-- ONE well holding both, rather than one each, because they are two halves of a single
			-- reading: the gap between the lit rung and the needle IS the ship's mass (SpeedLadder's
			-- own header), and the telemetry underneath is that lag arriving as numbers. Two wells
			-- would draw a box between a cause and its effect. It also keeps this panel at the
			-- dock's own count of two.
			--
			-- NO HEADING on either half. The ladder already names its own rung underneath ("HALF
			-- AHEAD") and the readouts caption themselves, so an ENGINE TELEGRAPH label would be a
			-- caption on a thing that captions itself -- and twenty-four pixels is a real fraction
			-- of a console this size.
			well(scope, "Instruments", 3, Tokens.Space.XS, {
				SpeedLadder(scope, {
					CommandedIndex = commandedIndex,
					CommandedLabel = commandedLabel,
					ActualFraction = actualFraction,
					Interactive = interactive,
					LayoutOrder = 1,
				}),

				-- The second half of the instrument cluster: what the ship is actually doing,
				-- measured locally. NO internal seams between the three, which is the dock's rule
				-- rather than an omission -- its Vitals well holds three VitalIcons separated by a
				-- gap and nothing else, and rules are spent only BETWEEN wells. Three thirds with
				-- their own captions already read as three columns.
				scope:New "Frame" {
					Name = "Telemetry",
					LayoutOrder = 2,
					Size = UDim2.new(1, 0, 0, Tokens.Type.Micro.Size + Tokens.Type.NumeralSmall.Size + 4),
					BackgroundTransparency = 1,

					[Children] = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Horizontal,
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						-- Three letters each, not words. At a third of a two-hundred-pixel panel
						-- "ALTITUDE" does not fit its own column, and a caption that truncates is
						-- worse than one that was always an abbreviation.
						readout("SPD", speedText, 1),
						readout("ALT", altitudeText, 2),
						readout("HDG", headingText, 3),
					},
				},
			}),
		},
	})

	return {
		SetVisible = setVisible,
		SetKind = setKind,
		SetHelmState = setHelmState,
		SetReleaseKey = setReleaseKey,
		SetTelemetry = setTelemetry,
	},
		tile
end

return BlimpHelm
