--!strict
--[[
	BlimpFuel/init.lua

	Owns: the Driver's furnace instrument -- a small corner panel showing coal/water levels, how long
	the hull can keep flying, and a status colour for each, visible only while the local player is
	holding a fuel-gated blimp's helm. Client/Blimp/BlimpController.lua is the integration module that
	drives this screen's handle (SetVisible on mount/dismount, SetSnapshot on every FuelUpdated push)
	-- this file itself sends and receives nothing, per the "screen exposes state, client module
	drives it" split every other Screens/ handle in this codebase already follows
	(Screens/DeathFeed/init.lua, Screens/CombatFeedback/init.lua).

	IT WEARS THE HOTBAR DOCK'S MATERIAL AND ITS GROUPING GRAMMAR (reworked 2026-08-25, at the owner's
	request). Everything visual here is now Screens/HUD/init.lua's and Screens/BlimpHelm/init.lua's,
	prop for prop, and the reason is the one that governed the helm's own rework: this is the same
	KIND of surface as those two -- an always-on instrument sat over live gameplay, which
	docs/ui-ux-philosophy.md's Shape Language calls a combat surface.

	It was wearing the MENU register instead, and that is not a stylistic difference either way: that
	doc puts the cut-corner silhouette on combat surfaces and the sharp rect on menu surfaces and says
	using one on the other "is the wrong register". What changed:

	  * CHAMFERED, not a sharp rectangle, with bronze UN-RIVETTED brackets braced into the cut
	    (BracketInset) over a violet AccentPrimary edge at the dock's own 0.3. Elevated = false: that
	    step means "this sits above the panel behind it" and there is no panel behind this one.
	  * ONE RECESSED WELL (Components/ModuleWell.lua) holding both gauges, instead of three loose
	    bands with nothing arbitrating between them. The container carries the grouping -- see that
	    component's header, and note that this screen is the third call site that promoted it.
	  * THE ENDURANCE READOUT MOVED INTO THE HEADER AS A PAINTED CHIP, which is the one change here
	    that is information design rather than skin. See the next block.
	  * PROSE TYPE BECAME LABEL TYPE. Every row was set in Body -- the resource names, the status
	    words, "TIME REMAINING" -- so a caption, a warning and a number all arrived at the same weight
	    and the eye had nothing to sort them by. Captions are Micro, statuses are Chip, numbers are
	    NumeralSmall mono.

	THE MOST USEFUL NUMBER ON THE PANEL WAS AT THE BOTTOM, IN THE SMALLEST TYPE. "Time remaining" is
	what a pilot actually flies by -- coal and water are the inputs, minutes-until-grounded is the
	decision -- and it was the last line, in prose, indistinguishable from the two captions above it.
	It is now the header chip, which is structurally the same place the helm console puts its hull
	mode: the panel's caption on the left, the one fact you would keep if you could only keep one on
	the right, as a StatusTag rather than as coloured text.

	A CHIP RATHER THAN A COLOURED WORD, because GROUNDED is a critical state and the doc's Critical
	States rule is that colour is never the only signal. StatusTag gives it a fill and a solid leading
	edge in the same hue, so the state has a SHAPE that reads before the word does and survives a
	player who cannot separate red from bronze.

	IDLE IS A STATE THIS PANEL DID NOT USED TO HAVE. A hull that is not thrusting burns nothing, so
	secondsUntilMinimum is infinite and the old readout printed "--:--" -- a placeholder where a
	number goes, which reads as a fault rather than as the correct answer. The chip says IDLE in the
	disabled hue instead: the furnace is banked, nothing is being consumed, and there is no countdown
	because there is nothing counting down.

	IT IS SIZED LIKE A MINIMAP, NOT LIKE A MENU -- the same constraint the helm console is fitted
	around, and the reason its sibling instrument shares its 220px width exactly. The rework spends
	fewer vertical pixels than it replaced despite gaining a well: Components/FuelGauge.lua's own
	header has where the 34px came from.

	RENDERS A SERVER-PUSHED SNAPSHOT AND TICKS LOCALLY, exactly like Screens/HUD/init.lua's own
	ability-cooldown countdown (`cooldownSeconds`/`cooldownEndsAt` + a gated Heartbeat) -- the server
	does NOT push 60Hz updates (see BlimpConstants.Network.RemoteNames.FuelUpdated's own comment), so
	this screen's Heartbeat extrapolates the live Coal/Water level between snapshots using the known
	burn rate the snapshot itself carries, the same way that screen's ticker counts a cooldown down
	from a server-given total instead of being pushed one every frame.

	STATUS COLOR IS TIME-BASED, NOT A FLAT FRACTION OF CAPACITY -- this is what makes "estimated time
	remaining" and "dynamic color for status and level" the same computation instead of two. Each
	resource's own seconds-until-it-crosses-its-own-Minimum (Server/Blimp/BlimpFuel.SecondsUntilMinimum's
	client-side mirror, computed against the locally-extrapolated live value) buckets into Healthy
	(> 120s), Warning (30-120s), or Critical (< 30s) -- or OFFLINE outright once the live value is
	already under its own Minimum, the same "operating reserve, not a depletion floor" distinction
	Shared/Blimp/BlimpConstants.Fuel's own header describes. Components/FuelGauge.lua renders whatever
	color/word this file hands it; it has no notion of time itself.

	Does not own: the fuel simulation (Server/Blimp/BlimpFuel.lua), the mount/dismount decision of when
	to call SetVisible (Client/Blimp/BlimpController.lua), or the per-resource meter primitive
	(Components/Bar.lua, via Components/FuelGauge.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local Tokens = require(script.Parent.Parent.Tokens)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Components.Inset)
local StatusTag = require(script.Parent.Parent.Components.StatusTag)
local ModuleWell = require(script.Parent.Parent.Components.ModuleWell)
local FuelGauge = require(script.Parent.Parent.Components.FuelGauge)
local Reveal = require(script.Parent.Parent.Components.Reveal)

type Scope = Fusion.Scope<typeof(Fusion)>

export type BlimpFuelHandle = {
	SetVisible: (visible: boolean) -> (),
	SetSnapshot: (payload: BlimpTypes.FuelUpdatedPayload) -> (),
}

local BlimpFuel = {}

-- Seconds-until-Minimum thresholds the whole screen buckets against -- see this file's own header.
local WARNING_SECONDS = 120
local CRITICAL_SECONDS = 30

-- THE HELM CONSOLE'S WIDTH, EXACTLY, and that is the point rather than a coincidence. These two are
-- a matched pair of flight instruments -- mounted together, read in the same glance, framing the
-- dock from opposite bottom corners -- and two instruments of different widths on one screen read as
-- two unrelated panels that happen to be up at the same time. See Screens/BlimpHelm's PANEL_WIDTH
-- for what the number itself is measured against; the 180px content column inside the well is the
-- same one every width constant in Components/FuelGauge.lua is measured against.
local PANEL_WIDTH = 220
-- Clears CHAMFER_PX (8) on the horizontal, where the cut actually eats into the content box. The
-- vertical can sit at the chamfer line because the cut is a CORNER -- BlimpHelm's identical pair of
-- constants has the full reasoning.
local PANEL_INSET_X = Tokens.Space.M
local PANEL_INSET_Y = Tokens.Space.S
-- Matches Components/StatusTag.lua's own fixed HEIGHT, so the endurance chip sets the header band's
-- height rather than being vertically clipped by a band sized for a bare label.
local HEADER_HEIGHT = 24

local function colorForSeconds(secondsRemaining: number): Color3
	if secondsRemaining < CRITICAL_SECONDS then
		return Tokens.Color.Danger
	elseif secondsRemaining < WARNING_SECONDS then
		return Tokens.Color.Warning
	end
	return Tokens.Color.Positive
end

-- nil FOR HEALTHY, RATHER THAN "NOMINAL". This used to return a word in every case, so both gauges
-- permanently displayed a reassurance nobody needs and a real warning had to be noticed as a word
-- CHANGING rather than as a word appearing. Presence is the primary cue; see Components/FuelGauge's
-- StatusText prop and docs/ui-ux-philosophy.md's Critical States rule.
local function wordForSeconds(secondsRemaining: number): string?
	if secondsRemaining < CRITICAL_SECONDS then
		return "CRITICAL"
	elseif secondsRemaining < WARNING_SECONDS then
		return "LOW"
	end
	return nil
end

-- OFFLINE outright once the live value is already under its own Minimum -- the engine is gated
-- (Server/Blimp/BlimpFuel.IsDepleted's exact condition), which is a stronger fact than "running low,"
-- so it gets its own word and color rather than falling through to CRITICAL.
local function statusFor(value: number, minimum: number, secondsRemaining: number): (Color3, string?)
	if value < minimum then
		return Tokens.Color.Danger, "OFFLINE"
	end
	return colorForSeconds(secondsRemaining), wordForSeconds(secondsRemaining)
end

local function secondsUntilMinimum(
	liveValue: number,
	minimum: number,
	burnPerSecond: number,
	thrusting: boolean
): number
	if not thrusting or burnPerSecond <= 0 then
		return math.huge
	end
	return math.max(0, liveValue - minimum) / burnPerSecond
end

local function formatSeconds(secondsRemaining: number): string
	if secondsRemaining == math.huge then
		return "--:--"
	end
	local whole = math.floor(secondsRemaining)
	return string.format("%d:%02d", whole // 60, whole % 60)
end

-- Returns its handle AND its tile, unparented -- UI/init.lua hands it to Shell/Regions.lua's
-- TopRight, where it stacks under the kill feed instead of sharing its exact coordinates. The two
-- were byte-identical before this; see Regions.lua's header.
function BlimpFuel.Mount(scope: Scope): (BlimpFuelHandle, Frame)
	local visible = scope:Value(false)

	local liveCoal = scope:Value(0)
	local coalCapacity = scope:Value(1)
	local coalStatusColor = scope:Value(Tokens.Color.Positive)
	-- Nilable, and starting nil: a gauge with nothing wrong with it says nothing. See wordForSeconds.
	local coalStatusText: Fusion.Value<string?> = scope:Value(nil :: string?)

	local liveWater = scope:Value(0)
	local waterCapacity = scope:Value(1)
	local waterStatusColor = scope:Value(Tokens.Color.Positive)
	local waterStatusText: Fusion.Value<string?> = scope:Value(nil :: string?)

	-- The header chip. IDLE rather than a countdown at rest -- a hull that is not thrusting burns
	-- nothing, so there is no time to count down and the old "--:--" was a placeholder standing where
	-- a number goes. See this file's header.
	local enduranceText = scope:Value("IDLE")
	local enduranceColor = scope:Value(Tokens.Color.TextDisabled)

	-- Plain mirrors, not Fusion Values -- the Heartbeat below reads these every frame, and re-deriving
	-- them from a Fusion Value would mean an unnecessary `Fusion.peek` per field per frame for state
	-- nothing else ever renders directly. Same "plain mirror beside the reactive Values" split
	-- Screens/HUD/init.lua's own boundMoveIds/cooldownTotals already use for the identical reason.
	local latest: BlimpTypes.FuelUpdatedPayload? = nil
	local receivedAt = 0

	local function setVisible(newVisible: boolean): ()
		visible:set(newVisible)
	end

	local function setSnapshot(payload: BlimpTypes.FuelUpdatedPayload): ()
		latest = payload
		receivedAt = os.clock()
	end

	-- Gated on `visible` first, same posture as HUD.lua's own cooldown ticker's `next(cooldownEndsAt)`
	-- early-out: this costs nothing at all while no fuel-gated blimp is being piloted, which is the
	-- overwhelming majority of any given session.
	RunService.Heartbeat:Connect(function()
		local snapshot = latest
		if not snapshot or not Fusion.peek(visible) then
			return
		end

		local elapsed = if snapshot.Thrusting then os.clock() - receivedAt else 0
		local extrapolatedCoal = math.max(0, snapshot.Coal - snapshot.CoalBurnPerSecond * elapsed)
		local extrapolatedWater = math.max(0, snapshot.Water - snapshot.WaterBurnPerSecond * elapsed)

		liveCoal:set(extrapolatedCoal)
		coalCapacity:set(snapshot.CoalCapacity)
		liveWater:set(extrapolatedWater)
		waterCapacity:set(snapshot.WaterCapacity)

		local coalSeconds =
			secondsUntilMinimum(extrapolatedCoal, snapshot.CoalMinimum, snapshot.CoalBurnPerSecond, snapshot.Thrusting)
		local waterSeconds = secondsUntilMinimum(
			extrapolatedWater,
			snapshot.WaterMinimum,
			snapshot.WaterBurnPerSecond,
			snapshot.Thrusting
		)

		local coalColor, coalText = statusFor(extrapolatedCoal, snapshot.CoalMinimum, coalSeconds)
		coalStatusColor:set(coalColor)
		coalStatusText:set(coalText)

		local waterColor, waterText = statusFor(extrapolatedWater, snapshot.WaterMinimum, waterSeconds)
		waterStatusColor:set(waterColor)
		waterStatusText:set(waterText)

		-- The hull is grounded the instant EITHER pool is under its own Minimum -- see
		-- BlimpConstants.Fuel's own header. The combined readout says so outright rather than showing a
		-- countdown to a line already crossed.
		if extrapolatedCoal < snapshot.CoalMinimum or extrapolatedWater < snapshot.WaterMinimum then
			enduranceColor:set(Tokens.Color.Danger)
			enduranceText:set("GROUNDED")
		elseif not snapshot.Thrusting then
			-- Banked, not broken. secondsUntilMinimum is infinite here by construction, and printing
			-- its "--:--" beside two healthy gauges read as a fault rather than as "nothing is being
			-- burned right now".
			enduranceColor:set(Tokens.Color.TextDisabled)
			enduranceText:set("IDLE")
		else
			local combinedSeconds = math.min(coalSeconds, waterSeconds)
			enduranceColor:set(colorForSeconds(combinedSeconds))
			enduranceText:set(formatSeconds(combinedSeconds))
		end
	end)

	-- AN ENTRANCE THIS GAUGE NEVER HAD. It used to pop -- `visible` straight onto the Panel, so
	-- boarding a blimp made a fully-formed panel exist in the corner between two frames. Phase 5 of
	-- docs/architecture/2026-08-25-hud-shell-plan.md gives all four ambient tiles the same arrival;
	-- see Components/Reveal.lua for what it can and cannot animate on a region-laid-out tile.
	local reveal = Reveal(scope, { Visible = visible })

	local tile = Panel(scope, {
		Name = "BlimpFuelPanel",
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		-- Reveal's guard, not `visible`: the tile has to outlive the close edge by the length of the
		-- exit. `visible` is still the fact -- this screen decides when the gauge belongs on screen,
		-- and Reveal only decides how long it takes to get there and back.
		Visible = reveal.Mounted,
		-- THE DOCK'S OWN MATERIAL, PROP FOR PROP -- Screens/HUD/init.lua's HotbarDock and the helm
		-- console beside it. See this file's header for why a furnace gauge is a combat surface by
		-- docs/ui-ux-philosophy.md's Shape Language and was wearing the menu register.
		--
		-- Elevated = false with it: SurfaceElevated is the "this sits above the panel behind it" step,
		-- and there is no panel behind this one. Both the dock and the helm made the same call.
		Elevated = false,
		Chamfered = true,
		-- CHAMFER AND BRACKETS TOGETHER, which BracketInset is what makes legal -- pulling each elbow
		-- in by the cut's own depth so the arms brace it instead of floating over the diagonal.
		-- Bronze and un-rivetted for the dock's reason: bronze reads as the frame's own forged metal,
		-- where violet would put four more "interactive" marks on a panel with nothing to press. The
		-- rivetted violet diamonds this panel used to wear were the loudest thing on it.
		CornerAccent = true,
		CornerAccentColor = Tokens.Color.AccentSecondary,
		CornerAccentRivets = false,
		BracketArmLength = 10,
		BracketInset = ChamferedSurface.CHAMFER_PX,
		-- The same violet edge the dock carries, at the same softened opacity, so the three surfaces
		-- read as cut from one material rather than as panels that happen to share a palette.
		BorderColor3 = Tokens.Color.AccentPrimary,
		BorderTransparency = 0.3,
		-- NOT SurfaceTexture. It is incompatible with AutomaticSize -- see Panel.lua's own prop note
		-- and the measurement in Screens/WeaponInventory -- and this panel is content-sized.

		Children = {
			reveal.Scale,
			-- Six lines of UIPadding replaced by the one call this codebase has for it, and the
			-- horizontal step went up to clear the chamfer. See PANEL_INSET_X.
			Inset(scope, { X = PANEL_INSET_X, Y = PANEL_INSET_Y }),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				-- Space.S rather than the loose gap this panel used to run between four loose bands:
				-- what it separates now is a header and one well, and a gap that reads as generous
				-- between two objects read as slack between four.
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			-- BAND 1: what the surface is, and the one number you would keep if you could keep only
			-- one. Bare rather than in a well -- the dock's arrangement too, where the TierBadge is a
			-- plate sitting directly on the panel while the vitals and slots are wells. The identity
			-- element is what the surface IS; a well around it would be grouping it with nothing.
			Stack.Row(scope, {
				Name = "Header",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				Gap = Tokens.Space.S,
				AlignY = Enum.VerticalAlignment.Center,

				Children = {
					-- Fill, not a hand-picked scale split: the chip takes its natural width and the
					-- caption takes what is left, so a six-glyph GROUNDED and a five-glyph 12:04 both
					-- fit without anyone maintaining two fractions that have to add to one.
					Stack.Fill(
						scope,
						Label(scope, {
							Text = "FURNACE",
							-- Micro, not Detail. This is a caption NAMING the surface, which is the
							-- caps step the dock's own module captions use; Detail is prose type and
							-- set this label at the same weight as the numbers underneath it.
							Scale = "Micro",
							Color = Tokens.Color.TextDisabled,
							Size = UDim2.new(1, 0, 0, Tokens.Type.Micro.Size + 2),
							LayoutOrder = 1,
						})
					),
					-- THE ENDURANCE READOUT, AS A PAINTED CHIP. It was the bottom row of the panel in
					-- prose type; it is the panel's primary indicator and now sits where the helm
					-- console puts its hull mode. Tracked is left off deliberately: enduranceText is
					-- reactive and that prop routes through TrackedLabel, which reads its string once
					-- and would freeze the chip on whatever the clock said at mount.
					StatusTag(scope, {
						Label = enduranceText,
						Color = enduranceColor,
						LayoutOrder = 2,
					}),
				},
			}),

			-- BAND 2: the two stores, in one well. ONE well holding both rather than one each,
			-- because they are two halves of a single reading -- the hull is grounded the instant
			-- EITHER crosses its own Minimum (BlimpConstants.Fuel's header), so coal and water are
			-- not independent gauges that happen to sit together, they are one furnace's inputs.
			-- Two wells would draw a box between them and invite reading either on its own.
			ModuleWell(scope, {
				Name = "Stores",
				LayoutOrder = 2,
				-- Space.S between the two gauges, where the rows INSIDE one gauge are XS apart. That
				-- difference is the only thing telling the eye which bar belongs to which caption,
				-- now that the dividers are gone.
				Gap = Tokens.Space.S,

				Children = {
					FuelGauge(scope, {
						Caption = "Coal",
						Value = liveCoal,
						Capacity = coalCapacity,
						StatusColor = coalStatusColor,
						StatusText = coalStatusText,
						LayoutOrder = 1,
					}),
					FuelGauge(scope, {
						Caption = "Water",
						Value = liveWater,
						Capacity = waterCapacity,
						StatusColor = waterStatusColor,
						StatusText = waterStatusText,
						LayoutOrder = 2,
					}),
				},
			}),
		},
	})

	return {
		SetVisible = setVisible,
		SetSnapshot = setSnapshot,
	}, tile
end

return BlimpFuel
