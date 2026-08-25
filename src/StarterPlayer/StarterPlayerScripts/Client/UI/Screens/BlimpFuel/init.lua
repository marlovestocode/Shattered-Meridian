--!strict
--[[
	BlimpFuel/init.lua

	Owns: the Driver's fuel gauge -- a small corner panel showing coal/water levels, estimated time
	remaining, and a status color for each, visible only while the local player is holding a fuel-
	gated blimp's helm. Client/Blimp/BlimpController.lua is the integration module that drives this
	screen's handle (SetVisible on mount/dismount, SetSnapshot on every FuelUpdated push) -- this file
	itself sends and receives nothing, per the "screen exposes state, client module drives it" split
	every other Screens/ handle in this codebase already follows (Screens/DeathFeed/init.lua,
	Screens/CombatFeedback/init.lua).

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
local Panel = require(script.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Components.Label)
local FuelGauge = require(script.Parent.Parent.Components.FuelGauge)
local Reveal = require(script.Parent.Parent.Components.Reveal)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type BlimpFuelHandle = {
	SetVisible: (visible: boolean) -> (),
	SetSnapshot: (payload: BlimpTypes.FuelUpdatedPayload) -> (),
}

local BlimpFuel = {}

-- Seconds-until-Minimum thresholds the whole screen buckets against -- see this file's own header.
local WARNING_SECONDS = 120
local CRITICAL_SECONDS = 30

local PANEL_WIDTH = 220

local function colorForSeconds(secondsRemaining: number): Color3
	if secondsRemaining < CRITICAL_SECONDS then
		return Tokens.Color.Danger
	elseif secondsRemaining < WARNING_SECONDS then
		return Tokens.Color.Warning
	end
	return Tokens.Color.Positive
end

local function wordForSeconds(secondsRemaining: number): string
	if secondsRemaining < CRITICAL_SECONDS then
		return "CRITICAL"
	elseif secondsRemaining < WARNING_SECONDS then
		return "LOW"
	end
	return "NOMINAL"
end

-- OFFLINE outright once the live value is already under its own Minimum -- the engine is gated
-- (Server/Blimp/BlimpFuel.IsDepleted's exact condition), which is a stronger fact than "running low,"
-- so it gets its own word and color rather than falling through to CRITICAL.
local function statusFor(value: number, minimum: number, secondsRemaining: number): (Color3, string)
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
	local coalStatusText = scope:Value("NOMINAL")

	local liveWater = scope:Value(0)
	local waterCapacity = scope:Value(1)
	local waterStatusColor = scope:Value(Tokens.Color.Positive)
	local waterStatusText = scope:Value("NOMINAL")

	local timeRemainingText = scope:Value("--:--")
	local timeRemainingColor = scope:Value(Tokens.Color.Positive)

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
			timeRemainingColor:set(Tokens.Color.Danger)
			timeRemainingText:set("GROUNDED")
		else
			local combinedSeconds = math.min(coalSeconds, waterSeconds)
			timeRemainingColor:set(colorForSeconds(combinedSeconds))
			timeRemainingText:set(formatSeconds(combinedSeconds))
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
		Elevated = true,
		CornerAccent = true,

		Children = {
			reveal.Scale,
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
				PaddingTop = UDim.new(0, Tokens.Space.S),
				PaddingBottom = UDim.new(0, Tokens.Space.S),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "FURNACE",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 1,
			}),
			FuelGauge(scope, {
				Caption = "Coal",
				Value = liveCoal,
				Capacity = coalCapacity,
				StatusColor = coalStatusColor,
				StatusText = coalStatusText,
				LayoutOrder = 2,
			}),
			FuelGauge(scope, {
				Caption = "Water",
				Value = liveWater,
				Capacity = waterCapacity,
				StatusColor = waterStatusColor,
				StatusText = waterStatusText,
				LayoutOrder = 3,
			}),
			scope:New "Frame" {
				Name = "TimeRemaining",
				LayoutOrder = 4,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + 2),
				BackgroundTransparency = 1,

				[Children] = {
					Label(scope, {
						Text = "TIME REMAINING",
						Scale = "Body",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(0, 0),
						Position = UDim2.fromScale(0, 0),
						Size = UDim2.fromScale(0.6, 1),
					}),
					Label(scope, {
						Text = timeRemainingText,
						Scale = "Numeral",
						Color = timeRemainingColor,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.4, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
		},
	})

	return {
		SetVisible = setVisible,
		SetSnapshot = setSnapshot,
	}, tile
end

return BlimpFuel
