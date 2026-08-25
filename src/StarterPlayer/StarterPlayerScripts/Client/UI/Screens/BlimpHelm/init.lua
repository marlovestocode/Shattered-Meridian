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

	IT IS SIZED LIKE A MINIMAP, NOT LIKE A MENU. Everything on it is the smallest step that still reads
	-- Chip caps, Micro descriptions, an eight-pixel ladder track, three-letter telemetry captions --
	because this sits over live gameplay for the length of a flight and docs/ui-ux-philosophy.md's HUD
	rule is "minimal, informative, out of the player's way". A console that eats a sixth of the screen
	fails the third of those however well it reads on its own. The first pass at this was menu-sized, and
	a menu is a thing you open; this is a thing you glance at.

	THE CONTROL LEGEND IS A TWO-COLUMN GRID, NOT A SIX-ROW LIST -- the second reason this reads as a
	minimap rather than a menu. Every helm row whose keys are narrow (two letters or one) pairs with
	another one on the same line; only "SPACE / SHIFT" (the widest cap run on the panel) still gets a
	full-width row of its own, because packing it into a half-width column would truncate either the
	caps or "Climb / dive" and this codebase does not ship rows that clip. The section heading that used
	to sit above the legend ("Controls"/"Aboard") is gone too -- a divider already marks the band and a
	dense grid of key caps does not need a label explaining that it is a legend.

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
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Divider = require(script.Parent.Parent.Components.Divider)
local KeyHint = require(script.Parent.Parent.Components.KeyHint)
local TrackedLabel = require(script.Parent.Parent.Components.TrackedLabel)
local SpeedLadder = require(script.Parent.Parent.Components.SpeedLadder)

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

local PANEL_WIDTH = 196
-- Wide enough for the widest cap run in the legend (SPACE + SHIFT, two Chip-scale caps and a gap) so
-- every description starts on one flush left edge -- see Components/KeyHint.lua's header on why this
-- is the caller's number to own rather than something that component measures for itself. Only the
-- full-width "Climb / dive" row and the always-visible release row use this; the paired grid rows use
-- their own, narrower column -- see GRID_KEY_COLUMN_WIDTH.
local KEY_COLUMN_WIDTH = 80
-- The grid rows only ever carry one or two single-letter caps (W/S, A/D, X, G), so their column can be
-- much narrower than the full-width rows' -- see helmGridRow.
local GRID_KEY_COLUMN_WIDTH = 40
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

-- 0..360 to the eight-point compass. Sixteen points would be more precise and less readable at a
-- glance, which is the wrong trade for a number sitting next to its own exact degrees.
local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local function compassPoint(degrees: number): string
	-- +0.5 before flooring is what makes the SECTOR centred on each cardinal rather than starting at
	-- it: without it, due north reads as N but one degree west of north reads as NW.
	local sector = math.floor((degrees % 360) / 45 + 0.5) % 8
	return COMPASS[sector + 1]
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

	-- This spring used to drive BOTH the panel's position and a 2% content scale. It now drives only
	-- the scale and the exit tail-guard below: a region tile's Position belongs to its region's
	-- UIListLayout, which overwrites it every layout pass, so the 14px slide could not have survived
	-- the migration whatever this file wanted. Components/Reveal.lua (Phase 5 of the HUD shell plan)
	-- restores an entrance offset for all five ambient tiles at once, in a form a laid-out tile can
	-- actually animate. Damped at 1 (critical), which is what kept it a slide rather than the bounce
	-- docs/ui-ux-philosophy.md's Animation Philosophy section rules out.
	local entrance = scope:Spring(
		scope:Computed(function(use)
			return if use(visible) then 0 else 1
		end),
		22,
		1
	)

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

	-- A full-width control row only the pilot sees -- today just "Climb / dive", the one row too wide
	-- to join helmGridRow's pairs below. Hidden rather than dimmed: a disabled control is worth showing
	-- when the player could earn it, and a passenger cannot -- they would have to walk to the wheel, at
	-- which point the row appears. Greying it would be teaching a passenger a key that does nothing for
	-- them, and the panel would carry a dead line on every ride as a passenger.
	local function helmRow(
		order: number,
		keys: { UsedAs<string> },
		text: string,
		activeText: string?,
		active: UsedAs<boolean>?
	): Frame
		return KeyHint(scope, {
			Keys = keys,
			Text = text,
			ActiveText = activeText,
			Active = active,
			KeyColumnWidth = KEY_COLUMN_WIDTH,
			Visible = interactive,
			LayoutOrder = order,
		})
	end

	-- Two pilot-only rows sharing one line -- see this file's header on why the grid exists and why
	-- "SPACE / SHIFT" is the one row that does not join it. The wrapping Frame, not either KeyHint, is
	-- what Visible is set on: both cells are always helm-only together, so hiding the row rather than
	-- each cell is what keeps a passenger from being left with an empty seventeen-pixel gap where the
	-- row used to be.
	local function helmGridRow(
		order: number,
		leftKeys: { UsedAs<string> },
		leftText: string,
		rightKeys: { UsedAs<string> },
		rightText: string,
		rightActiveText: string?,
		rightActive: UsedAs<boolean>?
	): Frame
		return scope:New "Frame" {
			Name = "HelmGridRow",
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, GRID_ROW_HEIGHT),
			BackgroundTransparency = 1,
			Visible = interactive,

			[Children] = {
				scope:New "Frame" {
					Name = "Left",
					Size = UDim2.new(0.5, -Tokens.Space.XS, 1, 0),
					BackgroundTransparency = 1,
					[Children] = KeyHint(scope, {
						Keys = leftKeys,
						Text = leftText,
						KeyColumnWidth = GRID_KEY_COLUMN_WIDTH,
					}),
				},
				scope:New "Frame" {
					Name = "Right",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.new(0.5, -Tokens.Space.XS, 1, 0),
					BackgroundTransparency = 1,
					[Children] = KeyHint(scope, {
						Keys = rightKeys,
						Text = rightText,
						ActiveText = rightActiveText,
						Active = rightActive,
						KeyColumnWidth = GRID_KEY_COLUMN_WIDTH,
					}),
				},
			},
		} :: Frame
	end

	local tile = Panel(scope, {
		Name = "BlimpHelmPanel",
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		-- Kept in the tree through the whole exit so the spring has something to animate, and only
		-- actually removed once it has finished leaving.
		Visible = scope:Computed(function(use)
			return use(visible) or use(entrance) < 0.99
		end),
		Elevated = true,
		CornerAccent = true,
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
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.S),
				PaddingRight = UDim.new(0, Tokens.Space.S),
				PaddingTop = UDim.new(0, Tokens.Space.XS),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			-- A whisper of scale on the entrance spring, well under anything that reads as a "pop".
			-- Now the ONLY motion on this panel's entrance -- it used to be the accent on a 14px
			-- slide, and it carries the arrival alone until Reveal.lua (Phase 5) gives the slide back
			-- in a form a laid-out tile can animate. Lands inside the Panel's own Content wrapper (see
			-- Panel.lua's Scale prop, which is the OTHER behaviour -- that one grows the frame
			-- itself), which is right here: the chrome holds still while its contents arrive.
			scope:New "UIScale" {
				Scale = scope:Computed(function(use)
					return 1 - use(entrance) * 0.02
				end),
			},

			-- Band 1: who you are, and what the ship is doing.
			scope:New "Frame" {
				Name = "Header",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + 4),
				BackgroundTransparency = 1,

				[Children] = {
					Label(scope, {
						Text = roleText,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(0.52, 1),
					}),
					Label(scope, {
						Text = modeText,
						Scale = "Detail",
						Color = modeColor,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.48, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
			Divider.Plain(scope, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 1) }),

			-- Band 2: the control legend. Above the telegraph deliberately -- it is what teaches
			-- the reading of the band below it, and a legend under the gauge it explains is a
			-- footnote. Terse because the column they live in is barely a hundred pixels wide. Each
			-- names the CONTROL rather than explaining it -- the ladder below already shows what
			-- the telegraph does, and a console this size is a reminder, not a tutorial.
			helmGridRow(3, { "W", "S" }, "Telegraph", { "A", "D" }, "Rudder"),
			helmGridRow(4, { "X" }, "All stop", { "G" }, "Autopilot", "Autopilot on", autopilot),
			helmRow(5, { "SPACE", "SHIFT" }, "Climb / dive"),
			-- The one row a passenger keeps, so it is the one row never hidden.
			KeyHint(scope, {
				-- The only reactive cap on the panel -- see KeyHint's Keys prop. Every other key
				-- here is a raw contextual key no rebind screen can reach; this one shares the
				-- Interact action with the prompt that started the mount, so it follows a rebind.
				Keys = { releaseKey },
				Text = "Let go",
				KeyColumnWidth = KEY_COLUMN_WIDTH,
				LayoutOrder = 6,
			}),

			Divider.Plain(scope, { LayoutOrder = 7, Size = UDim2.new(1, 0, 0, 1) }),

			-- Band 3: the telegraph itself. NO heading of its own, unlike the legend above it -- the
			-- ladder already names its own rung underneath ("HALF AHEAD"), so a second label reading
			-- ENGINE TELEGRAPH would be a caption on a thing that captions itself, and twenty-four
			-- pixels is a real fraction of a console this size.
			SpeedLadder(scope, {
				CommandedIndex = commandedIndex,
				CommandedLabel = commandedLabel,
				ActualFraction = actualFraction,
				Interactive = interactive,
				LayoutOrder = 8,
			}),

			-- Band 4: what the ship is actually doing, measured locally.
			scope:New "Frame" {
				Name = "Telemetry",
				LayoutOrder = 9,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Micro.Size + Tokens.Type.NumeralSmall.Size + 4),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					-- Three letters each, not words. At a third of a two-hundred-pixel panel "ALTITUDE"
					-- does not fit its own column, and a caption that truncates is worse than one that
					-- was always an abbreviation.
					readout("SPD", speedText, 1),
					readout("ALT", altitudeText, 2),
					readout("HDG", headingText, 3),
				},
			},
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
