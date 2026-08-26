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

	IT DRAWS NOTHING. This file owns the fuel STATE and hands it to
	Screens/BlimpHelm/FurnacePlate.lua, which is one half of a joint with the helm console and
	therefore lives beside the chrome it has to match. Exactly the split Screens/WeaponInventory has
	with Screens/HUD/ArmamentIsland: the state module stays where the remote-driven handle is, the
	plate lives with the surface it is bolted to, and NEITHER REQUIRES THE OTHER -- FurnaceState below
	is matched structurally, the way Luau types work.

	It used to own a corner panel of its own, and the joint is why it does not any more (owner,
	2026-08-25). The two blimp instruments are read in one glance and now render as one assembly in
	the bottom-right corner, so the geometry of the seam between them has exactly one owner. See
	FurnacePlate's header for the five rules that joint keeps.

	IT WORE THE MENU REGISTER UNTIL THE SAME PASS, and that is not a stylistic difference either way:
	docs/ui-ux-philosophy.md's Shape Language puts the cut-corner silhouette on combat surfaces and
	the sharp rect on menu surfaces and says using one on the other "is the wrong register". What
	changed, all of it now in FurnacePlate:

	  * CHAMFERED, with bronze UN-RIVETTED brackets braced into the cut, over a violet AccentPrimary
	    edge at the dock's own 0.3 -- the helm's material, prop for prop, because they share an edge.
	  * ONE RECESSED WELL (Components/ModuleWell.lua) holding both gauges, instead of three loose
	    bands with nothing arbitrating between them.
	  * THE ENDURANCE READOUT MOVED INTO THE HEADER AS A PAINTED CHIP, which is the one change that
	    is information design rather than skin. See the next block.
	  * PROSE TYPE BECAME LABEL TYPE. Every row was set in Body -- the resource names, the status
	    words, "TIME REMAINING" -- so a caption, a warning and a number all arrived at the same weight
	    and the eye had nothing to sort them by.

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
	around, and the reason the two share a width exactly. The rework spends fewer vertical pixels than
	it replaced despite gaining a well: Components/FuelGauge.lua's own header has where the 34px came
	from.

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

	Does not own: any pixels (Screens/BlimpHelm/FurnacePlate.lua), the fuel simulation
	(Server/Blimp/BlimpFuel.lua), the mount/dismount decision of when to call SetVisible
	(Client/Blimp/BlimpController.lua), or the per-resource meter primitive (Components/Bar.lua, via
	Components/FuelGauge.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local Tokens = require(script.Parent.Parent.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>

export type BlimpFuelHandle = {
	SetVisible: (visible: boolean) -> (),
	SetSnapshot: (payload: BlimpTypes.FuelUpdatedPayload) -> (),
}

-- WHAT THE PLATE NEEDS FROM THIS SCREEN, AND NOTHING MORE. Declared here as well as in
-- Screens/BlimpHelm/FurnacePlate.lua and matched STRUCTURALLY rather than imported, so neither
-- module requires the other -- the same arrangement Screens/WeaponInventory's ArmamentState has with
-- Screens/HUD/ArmamentIsland. Every field is already computed by the Heartbeat below; this type only
-- names which of them leave the file.
export type FurnaceState = {
	-- Whether the furnace belongs on screen at all. The plate's own entrance rides this.
	Present: Fusion.UsedAs<boolean>,
	Coal: Fusion.UsedAs<number>,
	CoalCapacity: Fusion.UsedAs<number>,
	CoalStatusColor: Fusion.UsedAs<Color3>,
	-- nil when nothing is wrong -- see wordForSeconds.
	CoalStatusText: Fusion.UsedAs<string?>,
	Water: Fusion.UsedAs<number>,
	WaterCapacity: Fusion.UsedAs<number>,
	WaterStatusColor: Fusion.UsedAs<Color3>,
	WaterStatusText: Fusion.UsedAs<string?>,
	-- The header chip: a countdown, GROUNDED, or IDLE.
	EnduranceText: Fusion.UsedAs<string>,
	EnduranceColor: Fusion.UsedAs<Color3>,
}

local BlimpFuel = {}

-- Seconds-until-Minimum thresholds the whole screen buckets against -- see this file's own header.
local WARNING_SECONDS = 120
local CRITICAL_SECONDS = 30

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

-- Returns the handle Client/Blimp/BlimpController.lua drives, and the state
-- Screens/BlimpHelm/FurnacePlate.lua renders on the plate it bolts to the console's top edge.
-- UI/init.lua mounts this BEFORE the helm for that reason and no other -- the same ordering, for the
-- same reason, that Screens/WeaponInventory has ahead of Screens/HUD.
function BlimpFuel.Mount(scope: Scope): (BlimpFuelHandle, FurnaceState)
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

	-- NO Reveal, AND NO PANEL AT ALL. This screen used to build its own tile and wear the shared
	-- ambient-tile entrance; the plate that replaced it enters as a DRAWER out of the helm console's
	-- top edge instead (Screens/BlimpHelm/FurnacePlate.lua), which is the entrance a bolted-on surface
	-- has to have -- Reveal scales a tile in place, and a thing being pushed out of another thing does
	-- not.
	return {
		SetVisible = setVisible,
		SetSnapshot = setSnapshot,
	}, {
		Present = visible,
		Coal = liveCoal,
		CoalCapacity = coalCapacity,
		CoalStatusColor = coalStatusColor,
		CoalStatusText = coalStatusText,
		Water = liveWater,
		WaterCapacity = waterCapacity,
		WaterStatusColor = waterStatusColor,
		WaterStatusText = waterStatusText,
		EnduranceText = enduranceText,
		EnduranceColor = enduranceColor,
	}
end

return BlimpFuel
